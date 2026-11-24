param(
    [ValidateSet('Sample', 'Banner', 'Probe', 'Failure', 'Live', 'Timeout')][string]$Case,
    [ValidateSet('actual', 'both', 'stdout', 'stderr')][string]$Terminals,
    [int]$Columns,
    [ValidateSet('Ansi', 'PlainText')][string]$Rendering
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$PSStyle.OutputRendering = $Rendering
. (Join-Path $PSScriptRoot '../../common.ps1')

# Override the terminal probe only for cases that require a terminal on a headless runner.
if ($Terminals -ne 'actual') {
    function Test-LogTerminal {
        param([switch]$Stderr)
        $Terminals -eq 'both' -or ($Stderr -and $Terminals -eq 'stderr') -or
            (-not $Stderr -and $Terminals -eq 'stdout')
    }
    function Get-LogTerminalWidth { $Columns }
}

trap {
    Write-BootstrapFailure $_
    exit (Get-BootstrapExitCode $_)
}

switch ($Case) {
    'Sample' {
        Write-LogPhase 'Environment check'
        Write-LogOk git '2.47.1'
        Write-LogOk chezmoi ''
        Write-LogSkip 'Already installed'
        Write-LogInfo 'Reading configuration'
        Write-LogWould remove '~/.zshrc'
        Write-LogNext 'Open a new terminal'
        Write-LogPhaseDone -DurationSeconds 3
        Write-LogPhaseDone -DurationSeconds 0
        Write-LogSummary 'All checks passed.' '2 tools'
        Write-LogMissing gh 'not on PATH'
        Write-LogWarn 'Restart applications'
        Write-LogError 'Installation failed (exit 7).' -Details "child output`n`nsecond line"
        Write-LogDetail 'script: install, line 29'
        Write-LogSummaryFailed 'Checks failed.' '1 missing'
    }
    'Banner' { Write-StartupBanner 'Fixture OS, arm64' }
    default {
        $pwsh = Join-Path $PSHOME 'pwsh.exe'
        if ($Case -eq 'Timeout') {
            $null = Invoke-NativeCommand -Executable $pwsh -Arguments @('-NoProfile', '-Command', 'Start-Sleep 20') `
                -Live -TimeoutSeconds 1
        } else {
            $command = '[Console]::WriteLine("probe stdout"); [Console]::Error.WriteLine("probe stderr")'
            if ($Case -ne 'Probe') { $command += '; exit 7' }
            $null = Invoke-NativeCommand -Executable $pwsh -Arguments @('-NoProfile', '-Command', $command) `
                -Live:($Case -eq 'Live')
        }
    }
}
