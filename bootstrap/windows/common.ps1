Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '../../dot_config/oh-my-devenv/powershell/environment.ps1')

# Keep host output on the information stream and diagnostics on native stderr.
function Test-LogTerminal {
    param([switch]$Stderr)
    if ($Stderr) { return -not [Console]::IsErrorRedirected }
    -not [Console]::IsOutputRedirected
}

function Test-LogRich {
    param([switch]$Stderr)
    (Test-LogTerminal -Stderr:$Stderr) -and -not $env:NO_COLOR -and -not $env:CI -and
        $env:TERM -cne 'dumb' -and $PSStyle.OutputRendering -ne 'PlainText'
}

function Write-LogLine {
    param(
        [string]$Level,
        [AllowEmptyString()][string]$Message,
        [string]$Detail
    )

    $indent = '  '
    $plain = $rich = $style = $detailStyle = ''
    $stderr = $false
    switch ($Level) {
        'phase'          { $indent = ''; $plain = '==>'; $rich = '❯'; $style = '1;36' }
        'done'           { $plain = '[done]'; $rich = '✓ done'; $style = '2' }
        'ok'             { $plain = '[ok]'; $rich = '✓'; $style = '32'; $detailStyle = '2' }
        'skip'           { $plain = '[skip]'; $rich = '›'; $style = '2' }
        'info'           { $plain = '[info]'; $rich = '›' }
        'missing'        { $stderr = $true; $plain = '[missing]'; $rich = '✗'; $style = '31' }
        'warn'           { $stderr = $true; $plain = '[warn]'; $rich = '!'; $style = '1;33' }
        'error'          { $stderr = $true; $plain = '[error]'; $rich = '✗'; $style = '1;31' }
        'detail'         { $stderr = $true; $indent = '    ' }
        'would'          { $plain = '[would]'; $rich = '▸'; $style = '36' }
        'next'           { $plain = '[next]'; $rich = 'next'; $style = '36' }
        'summary'        { $indent = ''; $rich = '✓'; $style = '1;32'; $detailStyle = '2' }
        'summaryFailed'  { $stderr = $true; $indent = ''; $plain = '[failed]'; $rich = '✗'; $style = '1;31'; $detailStyle = '2' }
    }

    $richMode = Test-LogRich -Stderr:$stderr
    if ($richMode) {
        if ($style) {
            if ($Level -in 'phase', 'done', 'error', 'summary', 'summaryFailed') {
                $Message = "`e[${style}m$rich $Message`e[0m"
                $rich = ''
            } else {
                $rich = "`e[${style}m$rich`e[0m"
            }
        }
        $plain = $rich
    }

    if ($Detail) {
        if ($richMode -and $Level -in 'ok', 'missing') { $Message = $Message.PadRight(16) }
        if ($Level -in 'summary', 'summaryFailed') { $Detail = "($Detail)" }
        if ($richMode -and $detailStyle) { $Detail = "`e[${detailStyle}m$Detail`e[0m" }
        $Message += " $Detail"
    }

    if ($plain) { $Message = "$plain $Message" }
    if ($stderr) { [Console]::Error.WriteLine("$indent$Message") } else { Write-Host "$indent$Message" }
}

$script:LogPhaseClock = $null

function Write-LogPhase {
    param([string]$Message)
    $script:LogPhaseClock = [Diagnostics.Stopwatch]::StartNew()
    Write-LogLine -Level phase -Message $Message
}

function Write-LogPhaseDone {
    param([int]$DurationSeconds)
    if (-not $PSBoundParameters.ContainsKey('DurationSeconds')) {
        $DurationSeconds = [Math]::Floor($script:LogPhaseClock.Elapsed.TotalSeconds)
    }
    if ($DurationSeconds -ge 1) { Write-LogLine -Level done -Message "in ${DurationSeconds}s" }
    Write-Host ''
}

function Write-LogOk {
    param([string]$Name, [string]$Detail)
    Write-LogLine -Level ok -Message $Name -Detail $Detail
}
function Write-LogSkip {
    param([string]$Message)
    Write-LogLine -Level skip -Message $Message
}
function Write-LogInfo {
    param([string]$Message)
    Write-LogLine -Level info -Message $Message
}
function Write-LogMissing {
    param([string]$Name, [string]$Detail)
    Write-LogLine -Level missing -Message $Name -Detail $Detail
}
function Write-LogWarn {
    param([string]$Message)
    Write-LogLine -Level warn -Message $Message
}
function Write-LogDetail {
    param([string]$Message)
    foreach ($line in ($Message -split '\r?\n')) { Write-LogLine -Level detail -Message $line }
}
function Write-LogError {
    param([string]$Message, [string[]]$Details)
    Write-LogLine -Level error -Message $Message
    foreach ($line in $Details) {
        if ($line) { Write-LogDetail -Message $line }
    }
    [Console]::Error.WriteLine()
}
function Write-LogWould {
    param([string]$Action, [string]$Target)
    Write-LogLine -Level would -Message $Action -Detail $Target
}
function Write-LogNext {
    param([string]$Message)
    Write-LogLine -Level next -Message $Message
}
function Write-LogSummary {
    param([string]$Message, [string]$Counts)
    Write-LogLine -Level summary -Message $Message -Detail $Counts
}
function Write-LogSummaryFailed {
    param([string]$Message, [string]$Counts)
    Write-LogLine -Level summaryFailed -Message $Message -Detail $Counts
}

function Get-LogTerminalWidth {
    try {
        $columns = [Console]::WindowWidth
    } catch [IO.IOException] {
        return 80
    }
    if ($columns -gt 0) { return $columns }
    80
}

function Write-StartupBanner {
    param([string]$Platform)
    if (-not (Test-LogTerminal) -or $env:NO_LOGO -ceq '1' -or $env:CI) { return }

    $assets = Join-Path $PSScriptRoot '../assets'
    $columns = Get-LogTerminalWidth
    $art = Get-Content -LiteralPath (Join-Path $assets 'banner-wide.txt')
    $width = ($art | Measure-Object -Property Length -Maximum).Maximum
    if ($columns -lt ($width + 2)) {
        $art = Get-Content -LiteralPath (Join-Path $assets 'banner-narrow.txt')
        $width = ($art | Measure-Object -Property Length -Maximum).Maximum
    }
    $span = $width - 1
    $colored = Test-LogRich
    $truecolor = $env:COLORTERM -cin 'truecolor', '24bit' -or $null -ne $env:WT_SESSION
    foreach ($line in $art) {
        if (-not $colored) {
            Write-Host $line
            continue
        }
        $rendered = [Text.StringBuilder]::new()
        for ($column = 0; $column -lt $line.Length; $column++) {
            $character = $line[$column]
            if ($character -eq ' ') {
                [void]$rendered.Append($character)
                continue
            }
            $style = '35'
            if ($truecolor) {
                $red = 255 - [Math]::Floor(80 * $column / $span)
                $green = 95 + [Math]::Floor(40 * $column / $span)
                $blue = 175 + [Math]::Floor(80 * $column / $span)
                $style = "38;2;$red;$green;$blue"
            }
            [void]$rendered.Append("`e[${style}m$character`e[0m")
        }
        Write-Host $rendered.ToString()
    }
    foreach ($line in 'bootstrap your dev env at lightning speed', $Platform) {
        $padding = ' ' * [Math]::Max(0, $width - $line.Length)
        if ($colored) { $line = "`e[2m$line`e[0m" }
        Write-Host "$padding$line"
    }
    Write-Host ''
}

function ConvertTo-NativeCommandException {
    param([string]$Message, [hashtable]$Result)
    foreach ($output in $Result['Stderr'], $Result['Stdout']) {
        if ($output) { $Message += "`n" + $output.TrimEnd("`r`n") }
    }
    $exception = [InvalidOperationException]::new($Message)
    $exception.Data['NativeExitCode'] = $Result.ExitCode
    $exception
}

function Get-BootstrapExitCode {
    param([Management.Automation.ErrorRecord]$Failure)
    for ($exception = $Failure.Exception; $null -ne $exception; $exception = $exception.InnerException) {
        if ($exception.Data.Contains('NativeExitCode')) { return $exception.Data['NativeExitCode'] }
    }
    1
}

function Write-BootstrapFailure {
    param([Management.Automation.ErrorRecord]$Failure)
    $message, $details = $Failure.Exception.Message -split '\r?\n', 2
    Write-LogError -Message $message -Details $details
}

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
    param([switch]$Managed)

    $entries = @(Get-HookPath)
    if ($Managed) {
        if (-not $env:GOPATH) { $env:GOPATH = Join-Path $HOME 'go' }
        if (-not $env:GOBIN) { $env:GOBIN = Get-DefaultGoBin }
        $entries = @(Get-ManagedProfilePathEntry) + $entries
    }
    $env:PATH = ($entries | Select-Object -Unique) -join [IO.Path]::PathSeparator
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
        [string]$WorkingDirectory,
        [ValidateRange(0, 2147483)][int]$TimeoutSeconds = 0,
        [switch]$AllowFailure,
        [switch]$Live
    )

    $start = [Diagnostics.ProcessStartInfo]::new($Executable)
    $start.UseShellExecute = $false
    if (-not $Live) {
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = [Text.Encoding]::UTF8
        $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    }
    if ($WorkingDirectory) { $start.WorkingDirectory = $WorkingDirectory }
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
        $exitTask = $process.WaitForExitAsync()
        $tasks = @($exitTask)
        if (-not $Live) {
            $stdoutRead = $process.StandardOutput.ReadToEndAsync()
            $stderrRead = $process.StandardError.ReadToEndAsync()
            $tasks += @($stdoutRead, $stderrRead)
        }

        $timeout = if ($TimeoutSeconds) { $TimeoutSeconds * 1000 } else { -1 }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks, [int]$timeout)) {
            if (-not $process.HasExited) {
                try { $process.Kill($true) } catch [InvalidOperationException] {
                    if (-not $process.HasExited) { throw }
                }
                $process.WaitForExit()
            }
            throw "'$Executable' did not finish within $TimeoutSeconds seconds."
        }
        $result = @{ Stdout = ''; Stderr = ''; ExitCode = $process.ExitCode }
        if (-not $Live) {
            $result.Stdout = $stdoutRead.GetAwaiter().GetResult()
            $result.Stderr = $stderrRead.GetAwaiter().GetResult()
        }
        if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
            throw (ConvertTo-NativeCommandException -Message "'$Executable' exited with code $($result.ExitCode)." -Result $result)
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
        throw [InvalidOperationException]::new("Could not list managed files from '$Source' to '$Destination'. $($_.Exception.Message)",
            $_.Exception)
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
