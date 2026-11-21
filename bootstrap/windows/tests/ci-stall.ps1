Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Run this diagnostic on a disposable GitHub-hosted Windows runner.'
}

$helpers = Split-Path -Parent $PSScriptRoot
. (Join-Path $helpers 'common.ps1')
. (Join-Path $helpers 'backup.ps1')
. (Join-Path $helpers 'profile.ps1')
. (Join-Path $helpers 'system-packages.ps1')

function Invoke-StallProbe {
    param([string]$Name, [string]$Executable, [string[]]$Arguments, [switch]$CloseInput)

    Write-Host "START $Name"
    $start = [Diagnostics.ProcessStartInfo]::new($Executable)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.RedirectStandardInput = $CloseInput
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($start)
    try {
        if ($CloseInput) { $process.StandardInput.Close() }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(90000)) {
            Write-Host "TIMEOUT $Name at 90 seconds, terminating PID $($process.Id) and its descendants"
            try { $process.Kill($true) } catch [InvalidOperationException] {
                if (-not $process.HasExited) { throw }
            }
            if (-not $process.WaitForExit(5000)) { throw "Could not terminate $Name." }
            $exitCode = 124
        } else {
            $exitCode = $process.ExitCode
        }
        Write-Host "END $Name exit=$exitCode elapsed=$($timer.Elapsed.TotalSeconds.ToString('F2'))s"
        foreach ($stream in @($stdout, $stderr)) {
            if ($stream.Wait(2000) -and $stream.Result) { Write-Host $stream.Result }
        }
        $exitCode
    } finally {
        $process.Dispose()
    }
}

$root = [IO.Path]::GetFullPath((Join-Path $helpers '../..'))
$fixture = [IO.Directory]::CreateTempSubdirectory('oh-my-devenv-stall-')
$profilePath = $PROFILE.CurrentUserAllHosts
$profileExisted = [IO.File]::Exists($profilePath)
if ($profileExisted) { $profileBytes = [IO.File]::ReadAllBytes($profilePath) }
try {
    $managedFolder = Join-Path $fixture.FullName '.config/oh-my-devenv/powershell'
    [void][IO.Directory]::CreateDirectory($managedFolder)
    foreach ($file in @('profile.ps1', 'environment.ps1', 'robbyrussell.omp.json')) {
        Copy-Item -LiteralPath (Join-Path $root "dot_config/oh-my-devenv/powershell/$file") -Destination $managedFolder
    }
    Add-ManagedProfileLine -ProfilePath $profilePath -Destination $fixture.FullName -BackupRoot $fixture.FullName
    Update-HookPath
    Install-WinGetPackage -ManifestPath (Join-Path $root 'bootstrap/manifests/system/winget-packages.json')
    Update-HookPath
    $posh = Get-PathApplication -Name oh-my-posh
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    $winget = Get-WinGetApplication
    $theme = Join-Path $managedFolder 'robbyrussell.omp.json'
    Write-Host "Resolved Oh My Posh executable: $($posh.Source)"
    $null = Invoke-StallProbe -Name 'pwsh with profile' -Executable $pwsh -Arguments @('-NoLogo', '-Command', 'exit 0')
    $null = Invoke-StallProbe -Name 'pwsh without profile' -Executable $pwsh -Arguments @('-NoLogo', '-NoProfile', '-Command', 'exit 0')
    $null = Invoke-StallProbe -Name 'Oh My Posh init' -Executable $posh.Source -Arguments @('init', 'pwsh', '--config', $theme)
    $null = Invoke-StallProbe -Name 'Oh My Posh version' -Executable $posh.Source -Arguments @('--version')
    $null = Invoke-StallProbe -Name 'Oh My Posh init with closed stdin' -Executable $posh.Source -Arguments @('init', 'pwsh', '--config', $theme) -CloseInput
    $trace = 'Set-PSDebug -Trace 1; ' + (Get-ManagedProfileLine -Destination $fixture.FullName)
    $null = Invoke-StallProbe -Name 'trace managed profile' -Executable $pwsh -Arguments @('-NoLogo', '-NoProfile', '-Command', $trace)
    $desktop = Join-Path $root 'bootstrap/manifests/desktop/winget-packages.json'
    $null = Read-WinGetPackageManifest -Path $desktop
    $null = Invoke-StallProbe -Name 'PowerToys import' -Executable $winget.Source -Arguments @(
        'import', '--import-file', $desktop, '--no-upgrade', '--accept-package-agreements',
        '--accept-source-agreements', '--disable-interactivity'
    )
} finally {
    if ($profileExisted) {
        [IO.File]::WriteAllBytes($profilePath, $profileBytes)
    } elseif ([IO.File]::Exists($profilePath)) {
        [IO.File]::Delete($profilePath)
    }
    $fixture.Delete($true)
    $wingetLogs = Join-Path $env:LOCALAPPDATA 'Packages/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe/LocalState/DiagOutputDir'
    Write-Host "WinGet logs at $wingetLogs"
    Get-ChildItem -LiteralPath $wingetLogs -Filter 'WinGet-*.log' -File | Sort-Object LastWriteTime -Descending |
        Select-Object -First 5 | ForEach-Object {
            Write-Host $_.Name
            Get-Content -LiteralPath $_.FullName -Tail 100
        }
}
