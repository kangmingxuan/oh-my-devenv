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
        Bytes = $bytes
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
    param([string]$ProfilePath, [string]$Destination, [Parameter(Mandatory)][string]$BackupPath)

    $file = Resolve-RegularFile -Path $ProfilePath
    if ($null -eq $file) {
        return
    }
    $profileFile = Read-ProfileFile -Path $file.FullName
    $updated = [regex]::Replace($profileFile.Content, (Get-ManagedProfilePattern -Destination $Destination), '')
    if ($updated -cne $profileFile.Content -and $PSCmdlet.ShouldProcess($ProfilePath, 'Remove managed profile line')) {
        $bytes = $profileFile.Encoding.GetPreamble() + $profileFile.Encoding.GetBytes($updated)
        Write-ProfileReplacement -Path $file.FullName -Original $profileFile.Bytes -Bytes $bytes -BackupPath $BackupPath
    }
}

function Write-ProfileReplacement {
    param([string]$Path, [byte[]]$Original, [byte[]]$Bytes, [Parameter(Mandatory)][string]$BackupPath)

    $temporary = Join-Path ([IO.Path]::GetDirectoryName($Path)) ".oh-my-devenv-$(New-Guid).tmp"
    $created = $false
    $replaceFailed = $false
    try {
        $writer = [IO.File]::Open($temporary, 'CreateNew', 'Write', 'None')
        $created = $true
        try {
            $writer.Write($Bytes, 0, $Bytes.Length)
            $writer.Flush($true)
        } finally {
            $writer.Dispose()
        }
        if (-not [Linq.Enumerable]::SequenceEqual[byte]($Bytes, [IO.File]::ReadAllBytes($temporary))) {
            throw 'Could not verify the staged profile.'
        }

        # Allow atomic replacement while excluding in-place writers.
        $sharing = [IO.FileShare]::Read -bor [IO.FileShare]::Delete
        $reader = [IO.File]::Open($Path, 'Open', 'Read', $sharing)
        try {
            $currentHash = [Security.Cryptography.SHA256]::HashData($reader)
            $originalHash = [Security.Cryptography.SHA256]::HashData($Original)
            if (-not [Linq.Enumerable]::SequenceEqual[byte]($currentHash, $originalHash)) {
                throw 'The original profile changed after it was read.'
            }
            try {
                [IO.File]::Replace($temporary, $Path, [NullString]::Value)
            } catch {
                $replaceFailed = $true
                throw
            }
        } finally {
            $reader.Dispose()
        }
    } catch {
        if ($replaceFailed) {
            throw "Could not replace PowerShell profile '$Path'. Staged profile: '$temporary'. Pre-uninstall backup: '$BackupPath'. $_"
        }
        throw "Could not replace PowerShell profile '$Path'. $_"
    } finally {
        if ($created -and -not $replaceFailed) {
            [IO.File]::Delete($temporary)
        }
    }
}

function Get-ProfileProbePath {
    $managed = @(Get-ManagedProfilePathEntry | ForEach-Object { ConvertTo-PathKey -Path $_ })
    (Get-HookPath | Where-Object { (ConvertTo-PathKey -Path $_) -cnotin $managed }) -join [IO.Path]::PathSeparator
}

function Confirm-ManagedProfile {
    param([string]$ProfilePath, [string]$Destination)

    $arguments = @('-NoLogo', '-NonInteractive')
    $fixtureProfile = (ConvertTo-PathKey -Path $ProfilePath) -cne
        (ConvertTo-PathKey -Path $PROFILE.CurrentUserAllHosts)
    if ($fixtureProfile) {
        $arguments += '-NoProfile'
    }
    $successMarker = "oh-my-devenv-profile-probe-$(New-Guid)"
    $arguments += @('-File', (Join-Path $PSScriptRoot 'profile-probe.ps1'), '-SuccessMarker', $successMarker)
    $arguments += @('-ExpectedPoshConfig', (Join-Path $Destination '.config/oh-my-devenv/powershell/robbyrussell.omp.json'))
    if ($fixtureProfile) {
        $arguments += @('-FixtureProfilePath', $ProfilePath)
    }
    $probeEnvironment = @{
        PATH = Get-ProfileProbePath
        OH_MY_DEVENV_PROFILE_LOADED = $null
        OH_MY_DEVENV_POSH_CONFIG = $null
        POSH_CONFIG = $null
        POSH_SESSION_ID = $null
    }
    $pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    try {
        $result = Invoke-NativeCommand -Executable $pwsh -Arguments $arguments -Environment $probeEnvironment
        if (($result.Stdout -split '\r?\n') -cnotcontains $successMarker) {
            throw 'The child PowerShell did not report the profile probe success marker.'
        }
    } catch {
        throw "PowerShell profile check failed for '$ProfilePath'. $_"
    }
    Write-Host 'PowerShell loaded the managed profile, restored its PATH entries, and initialized Oh My Posh with the managed theme.'
}
