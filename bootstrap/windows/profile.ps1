Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ManagedProfileLine {
    param([string]$Destination)

    $body = Join-Path $Destination '.config/oh-my-devenv/powershell/profile.ps1'
    $body = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($body)
    "if (Test-Path -LiteralPath '$body' -PathType Leaf) { . '$body' } # oh-my-devenv"
}

function Read-ProfileFile {
    param([string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $signature = [Convert]::ToHexString($bytes, 0, [Math]::Min(4, $bytes.Length))
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $preambleLength = 0
    if ($signature -match '^(FFFE0000|0000FEFF)') {
        throw "Unsupported UTF-32 profile '$Path'."
    }
    if ($signature.StartsWith('FFFE')) {
        $encoding = [Text.UnicodeEncoding]::new($false, $true, $true)
        $preambleLength = 2
    } elseif ($signature.StartsWith('FEFF')) {
        $encoding = [Text.UnicodeEncoding]::new($true, $true, $true)
        $preambleLength = 2
    } elseif ($signature.StartsWith('EFBBBF')) {
        $encoding = [Text.UTF8Encoding]::new($true, $true)
        $preambleLength = 3
    }
    try {
        $content = $encoding.GetString($bytes, $preambleLength, $bytes.Length - $preambleLength)
    } catch [Text.DecoderFallbackException] {
        throw "Invalid profile encoding in '$Path'. Use UTF-8 or BOM-marked UTF-16."
    }
    @{
        Content = $content
        Encoding = $encoding
    }
}

function Get-ManagedProfilePattern {
    param([string]$Destination)

    $line = Get-ManagedProfileLine -Destination $Destination
    '(?<![^\r\n])' + [regex]::Escape($line) + '(?:\r\n|\n|\r|$)'
}

function Add-ManagedProfileLine {
    param([string]$ProfilePath, [string]$Destination, [string]$BackupRoot)

    $file = Resolve-RegularFile -Path $ProfilePath
    $line = Get-ManagedProfileLine -Destination $Destination
    if ($null -eq $file) {
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($ProfilePath))
        $stream = [IO.File]::Open($ProfilePath, 'CreateNew', 'Write', 'Read')
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($line + [Environment]::NewLine)
            $stream.Write($bytes, 0, $bytes.Length)
        } finally {
            $stream.Dispose()
        }
        return
    }

    $profileFile = Read-ProfileFile -Path $file.FullName
    if ($profileFile.Content -cmatch (Get-ManagedProfilePattern -Destination $Destination)) {
        return
    }

    $runDirectory = New-BackupRun -BackupRoot $BackupRoot
    $backup = Get-BackupPath -Path $ProfilePath -RunDirectory $runDirectory
    Copy-VerifiedFile -Source $file.FullName -Destination $backup
    Write-Host "Profile backup completed: $backup"
    $newline = [regex]::Match($profileFile.Content, '\r\n|\n|\r').Value
    if (-not $newline) {
        $newline = [Environment]::NewLine
    }
    $append = $line + $newline
    if ($profileFile.Content -and $profileFile.Content -notmatch '[\r\n]$') {
        $append = $newline + $append
    }
    try {
        # Append encoded bytes directly. AppendAllText can emit a preamble.
        $stream = [IO.File]::Open($file.FullName, 'Append', 'Write', 'Read')
        try {
            $bytes = $profileFile.Encoding.GetBytes($append)
            $stream.Write($bytes, 0, $bytes.Length)
        } finally {
            $stream.Dispose()
        }
    } catch {
        throw "Could not append to profile '$ProfilePath'. Pre-edit backup: '$backup'. $_"
    }
}

function Remove-ManagedProfileLine {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$ProfilePath, [string]$Destination)

    $file = Resolve-RegularFile -Path $ProfilePath
    if ($null -eq $file) {
        return
    }
    $profileFile = Read-ProfileFile -Path $file.FullName
    $updated = [regex]::Replace($profileFile.Content, (Get-ManagedProfilePattern -Destination $Destination), '')
    if ($updated -cne $profileFile.Content -and $PSCmdlet.ShouldProcess($ProfilePath, 'Remove managed profile line')) {
        $bytes = $profileFile.Encoding.GetPreamble() + $profileFile.Encoding.GetBytes($updated)
        [IO.File]::WriteAllBytes($file.FullName, $bytes)
    }
}
