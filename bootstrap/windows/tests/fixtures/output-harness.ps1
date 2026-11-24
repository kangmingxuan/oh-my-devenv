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
    $script:FixtureTerminalWidth = $Columns
    function Test-LogTerminal {
        param([switch]$Stderr)
        $Terminals -eq 'both' -or ($Stderr -and $Terminals -eq 'stderr') -or
            (-not $Stderr -and $Terminals -eq 'stdout')
    }
    function Get-LogTerminalWidth { $script:FixtureTerminalWidth }
}

trap {
    Write-BootstrapFailure -Failure $_
    exit (Get-BootstrapExitCode -Failure $_)
}

switch ($Case) {
    'Sample' {
        Write-LogPhase -Message 'Environment check'
        Write-LogOk -Name git -Detail '2.47.1'
        Write-LogOk -Name chezmoi -Detail ''
        Write-LogSkip -Message 'Already installed'
        Write-LogInfo -Message 'Reading configuration'
        Write-LogWould -Action remove -Target '~/.zshrc'
        Write-LogNext -Message 'Open a new terminal'
        Write-LogPhaseDone -DurationSeconds 3
        Write-LogPhaseDone -DurationSeconds 0
        Write-LogSummary -Message 'All checks passed.' -Counts '2 tools'
        Write-LogMissing -Name gh -Detail 'not on PATH'
        Write-LogWarn -Message 'Restart applications'
        Write-LogError -Message 'Installation failed (exit 7).' -Details "child output`n`nsecond line"
        Write-LogDetail -Message 'script: install, line 29'
        Write-LogSummaryFailed -Message 'Checks failed.' -Counts '1 missing'
    }
    'Banner' { Write-StartupBanner -Platform 'Fixture OS, arm64' }
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
