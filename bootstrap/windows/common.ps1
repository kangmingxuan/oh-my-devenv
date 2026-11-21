Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '../../dot_config/oh-my-devenv/powershell/environment.ps1')

function Get-HookPath {
    # Retain commands available to the caller, including CI tool paths.
    $parts = @(
        $env:PATH
        [Environment]::GetEnvironmentVariable('Path', 'Machine')
        [Environment]::GetEnvironmentVariable('Path', 'User')
    )
    $parts -split [IO.Path]::PathSeparator | Where-Object { $_ } | Select-Object -Unique
}

function Update-HookPath {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Changes the current hook process environment.')]
    param()

    $env:PATH = (Get-HookPath) -join [IO.Path]::PathSeparator
}

function Get-HookBackupRoot {
    param([string]$Destination, [string]$HomeDirectory)

    if ($env:OH_MY_DEVENV_WINDOWS_BACKUP_ROOT) {
        return $env:OH_MY_DEVENV_WINDOWS_BACKUP_ROOT
    }
    if ([IO.Path]::GetFullPath($Destination) -ne [IO.Path]::GetFullPath($HomeDirectory)) {
        throw 'Set OH_MY_DEVENV_WINDOWS_BACKUP_ROOT in chezmoi scriptEnv for an alternate destination.'
    }

    Get-LocalBackupRoot -Name 'chezmoi-first-run-backup'
}

function Get-LocalBackupRoot {
    param([string]$Name)

    $localData = [Environment]::GetFolderPath('LocalApplicationData')
    if (-not $localData) {
        throw 'Windows did not resolve the LocalApplicationData known folder.'
    }
    Join-Path $localData "oh-my-devenv/$Name"
}

function Get-HookProfilePath {
    param([string]$Destination, [string]$HomeDirectory)

    if ($env:OH_MY_DEVENV_WINDOWS_PROFILE_PATH) {
        return $env:OH_MY_DEVENV_WINDOWS_PROFILE_PATH
    }
    if ([IO.Path]::GetFullPath($Destination) -ne [IO.Path]::GetFullPath($HomeDirectory)) {
        throw 'Set OH_MY_DEVENV_WINDOWS_PROFILE_PATH in chezmoi scriptEnv for an alternate destination.'
    }
    $PROFILE.CurrentUserAllHosts
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$Arguments,
        [hashtable]$Environment = @{},
        [ValidateRange(0, 2147483)][int]$TimeoutSeconds = 0,
        [switch]$AllowFailure
    )

    $start = [Diagnostics.ProcessStartInfo]::new($Executable)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($argument in $Arguments) {
        $start.ArgumentList.Add($argument)
    }
    foreach ($key in $Environment.Keys) {
        if ($null -eq $Environment[$key]) {
            [void]$start.Environment.Remove($key)
        } else {
            $start.Environment[$key] = $Environment[$key]
        }
    }

    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdoutRead = $process.StandardOutput.ReadToEndAsync()
        $stderrRead = $process.StandardError.ReadToEndAsync()
        if ($TimeoutSeconds) {
            $tasks = [Threading.Tasks.Task[]]@($process.WaitForExitAsync(), $stdoutRead, $stderrRead)
            if (-not [Threading.Tasks.Task]::WaitAll($tasks, [TimeSpan]::FromSeconds($TimeoutSeconds))) {
                if (-not $process.HasExited) {
                    try { $process.Kill($true) } catch [InvalidOperationException] {
                        if (-not $process.HasExited) { throw }
                    }
                }
                throw "'$Executable' did not finish within $TimeoutSeconds seconds."
            }
        } else {
            $process.WaitForExit()
        }
        $result = @{
            Stdout = $stdoutRead.GetAwaiter().GetResult()
            Stderr = $stderrRead.GetAwaiter().GetResult()
            ExitCode = $process.ExitCode
        }
        if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
            throw "'$Executable' exited with code $($result.ExitCode).`n$($result.Stderr)`n$($result.Stdout)"
        }
        $result
    } finally {
        $process.Dispose()
    }
}

function Get-ManagedFile {
    param(
        [string]$Executable,
        [string]$Config,
        [string]$Source,
        [string]$Destination
    )

    $stateDirectory = [IO.Directory]::CreateTempSubdirectory('oh-my-devenv-list-').FullName
    try {
        $result = Invoke-NativeCommand -Executable $Executable -Arguments @(
            "--config=$Config", "--source=$Source", "--destination=$Destination"
            "--persistent-state=$(Join-Path $stateDirectory 'state.boltdb')"
            'managed', '--include=files,symlinks', '--path-style=absolute', '--format='
        )
        $result.Stdout -split '\r?\n' | Where-Object { $_ -ne '' }
    } catch {
        throw "Could not list managed files from '$Source' to '$Destination'. $_"
    } finally {
        [IO.Directory]::Delete($stateDirectory, $true)
    }
}

function Test-SshConfigRead {
    param([string]$Diagnostic, [string]$Path)

    $expected = ConvertTo-PathKey -Path $Path
    foreach ($line in ($Diagnostic -split '\r?\n')) {
        if ($line -match '^debug1: Reading configuration data (.+)$' -and
            (ConvertTo-PathKey -Path $Matches[1]) -ceq $expected) {
            return $true
        }
    }
    $false
}
