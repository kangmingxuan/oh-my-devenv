Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-BackupPath {
    param([string]$Path, [string]$RunDirectory)

    if ($Path -notmatch '^([A-Za-z]):[\\/]([^\\/].*)$') {
        throw "Expected an absolute local drive path, got '$Path'. UNC and device paths are unsupported."
    }
    $drive = $Matches[1].ToUpperInvariant()
    $parts = $Matches[2] -split '[\\/]'
    foreach ($part in $parts) {
        if (-not $part -or $part -match '[<>:"|?*\x00-\x1f]|[ .]$' -or
            $part -match '^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)') {
            throw "Unsupported backup path component '$part' in '$Path'."
        }
    }
    $root = [IO.Path]::GetFullPath($RunDirectory)
    $relative = ('drives', $drive) + $parts -join [IO.Path]::DirectorySeparatorChar
    $mapped = [IO.Path]::GetFullPath([IO.Path]::Combine($root, $relative))
    $prefix = [IO.Path]::TrimEndingDirectorySeparator($root) + [IO.Path]::DirectorySeparatorChar
    if (-not $mapped.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Backup path '$mapped' escapes '$root'."
    }
    $mapped
}

function Get-FileAttribute {
    param([string]$Path)

    try {
        [IO.File]::GetAttributes($Path)
    } catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] {
        $null
    }
}

function Resolve-RegularFile {
    param([string]$Path, [switch]$SkipDangling)

    $attributes = Get-FileAttribute -Path $Path
    if ($null -eq $attributes) {
        return
    }
    if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
        $target = [IO.File]::ResolveLinkTarget($Path, $true)
        if ($null -eq $target) {
            throw "Unsupported reparse point '$Path'."
        }
        $attributes = Get-FileAttribute -Path $target.FullName
        if ($null -eq $attributes) {
            if ($SkipDangling) {
                Write-LogSkip "Dangling link '$Path'."
                return
            }
            throw "Dangling link '$Path'."
        }
        if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Unsupported link target '$($target.FullName)' for '$Path'."
        }
        $Path = $target.FullName
    }
    if ($attributes -band [IO.FileAttributes]::Directory) {
        throw "Expected a file, found a directory at '$Path'."
    }
    [IO.FileInfo]::new($Path)
}

function New-BackupRun {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal backup allocation must succeed before any target change.')]
    param([string]$BackupRoot)

    [void][IO.Directory]::CreateDirectory($BackupRoot)
    $name = '{0:yyyyMMddTHHmmssfffZ}-{1}' -f (Get-Date -AsUTC), (New-Guid)
    $directory = Join-Path $BackupRoot $name
    # Directory.CreateDirectory also succeeds on an existing directory.
    (New-Item -Path $directory -ItemType Directory -ErrorAction Stop).FullName
}

function Copy-VerifiedFile {
    param([string]$Source, [string]$Destination)

    try {
        if ($null -ne (Get-FileAttribute -Path $Destination)) {
            throw 'The backup destination already exists.'
        }
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination))
        Copy-Item -LiteralPath $Source -Destination $Destination -ErrorAction Stop

        $sourceFile = [IO.FileInfo]::new($Source)
        $copy = [IO.FileInfo]::new($Destination)
        if ($copy.LastWriteTimeUtc -ne $sourceFile.LastWriteTimeUtc) {
            $copy.LastWriteTimeUtc = $sourceFile.LastWriteTimeUtc
        }
        if ($copy.Length -ne $sourceFile.Length -or
            (Get-FileHash -LiteralPath $Destination).Hash -ne (Get-FileHash -LiteralPath $Source).Hash) {
            throw 'The backup differs from the source.'
        }
    } catch {
        throw "Could not back up '$Source' to '$Destination'. $_"
    }
}

function Backup-ExistingFile {
    param([string[]]$Paths, [string]$BackupRoot, [switch]$BeforeUninstall, [switch]$PassThru)

    $purpose = if ($BeforeUninstall) { 'Pre-uninstall backup' } else { 'First-run backup' }
    $runDirectory = $null
    foreach ($path in $Paths) {
        try {
            # Validate the local-drive path before touching it.
            $null = Get-BackupPath -Path $path -RunDirectory $BackupRoot
            $file = Resolve-RegularFile -Path $path -SkipDangling:(-not $BeforeUninstall)
            if ($null -eq $file) {
                if ($BeforeUninstall) {
                    throw 'The uninstall candidate no longer exists.'
                }
                continue
            }
            if (-not $runDirectory) {
                $runDirectory = New-BackupRun -BackupRoot $BackupRoot
            }
            $destination = Get-BackupPath -Path $path -RunDirectory $runDirectory
            Copy-VerifiedFile -Source $file.FullName -Destination $destination
        } catch {
            throw "$purpose failed for '$path' under '$BackupRoot'. $_"
        }
    }
    if ($runDirectory) {
        if ($BeforeUninstall) {
            Write-LogOk backed-up "$runDirectory"
        } else {
            Write-LogWarn "${purpose} completed: $runDirectory"
        }
        if ($PassThru) {
            $runDirectory
        }
    } else {
        Write-LogSkip 'No pre-existing managed files to back up.'
    }
}
