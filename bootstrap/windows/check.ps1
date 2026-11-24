param(
    [string]$Destination = $HOME,
    [string]$ProfilePath = $PROFILE.CurrentUserAllHosts,
    [string]$RegistryPath = 'Environment',
    [switch]$DesktopBaseline,
    [string]$ProbeFixtureBin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')

if (-not $IsWindows) {
    Write-LogError -Message 'This check requires native Windows.'
    exit 1
}
if ($PSVersionTable.PSVersion -lt [version]'7.6') {
    Write-LogError -Message "PowerShell 7.6 or later is required. Running $($PSVersionTable.PSVersion)."
    exit 1
}
. (Join-Path $PSScriptRoot 'backup.ps1')
. (Join-Path $PSScriptRoot 'profile.ps1')
. (Join-Path $PSScriptRoot 'system-packages.ps1')
. (Join-Path $PSScriptRoot 'desktop.ps1')
. (Join-Path $PSScriptRoot 'user-path.ps1')
. (Join-Path $PSScriptRoot 'mise.ps1')
. (Join-Path $PSScriptRoot 'ecosystem.ps1')
. (Join-Path $PSScriptRoot 'completions.ps1')

Write-LogPhase -Message 'Running environment checks...'
$checkName = 'Environment'
try {
    Update-HookPath -Managed
    $git = Get-PathApplication -Name git
    $chezmoi = Get-PathApplication -Name chezmoi

    $checkName = 'Managed files'
    foreach ($relativePath in @('.gitconfig', '.config/mise/config.toml', '.config/oh-my-devenv/powershell/profile.ps1',
        '.config/oh-my-devenv/powershell/environment.ps1', '.config/oh-my-devenv/powershell/completions.ps1')) {
        $target = Join-Path $Destination $relativePath
        if ($null -eq (Resolve-RegularFile -Path $target)) {
            throw "Missing managed file '$target'. Run chezmoi apply."
        }
        Write-LogOk -Name $relativePath
    }

    $checkName = 'Git config'
    $gitConfig = [IO.Path]::GetFullPath((Join-Path $Destination '.gitconfig'))
    $result = Invoke-NativeCommand -Executable $git.Source -Arguments @('var', 'GIT_CONFIG_GLOBAL')
    # Git can read an XDG global file in addition to the managed home file.
    $gitGlobalPaths = @($result.Stdout.TrimEnd("`r`n") -split '\r?\n' | Where-Object { $_ })
    $gitGlobalKeys = @($gitGlobalPaths | ForEach-Object { ConvertTo-PathKey -Path ([IO.Path]::GetFullPath($_)) })
    if ((ConvertTo-PathKey -Path $gitConfig) -cnotin $gitGlobalKeys) {
        throw "Git global config paths '$($gitGlobalPaths -join "', '")' do not include managed file '$gitConfig'."
    }
    Write-LogOk -Name "Git config" -Detail "$gitConfig"

    $checkName = 'PowerShell profile'
    if ($null -eq (Resolve-RegularFile -Path $ProfilePath) -or
        (Read-ProfileFile -Path $ProfilePath).Content -cnotmatch (Get-ManagedProfilePattern -Destination $Destination)) {
        throw "The managed line is missing from PowerShell profile '$ProfilePath'. Run chezmoi apply."
    }

    $checkName = 'mise toolchain'
    $manifestRoot = Join-Path $PSScriptRoot '../manifests'
    Confirm-MiseToolchain
    $configPath = Join-Path $Destination '.config/mise/config.toml'
    $checkName = 'User Path'
    $managedEntries = @(Get-ManagedProfilePathEntry)
    $missingPath = @(Get-MissingUserPathEntry -PathValue (Read-UserPath -RegistryPath $RegistryPath) -Entries $managedEntries)
    if ($missingPath.Count) {
        throw "Missing directories in the user Path: $($missingPath -join '; '). Run chezmoi apply."
    }
    Write-LogOk -Name 'User Path' -Detail 'Managed directories are present.'
    $checkName = 'mise toolchain'
    $runtimes = @(Get-MiseProfileCommand -ConfigPath $configPath -ShimsDirectory $managedEntries[0])
    $checkName = 'Ecosystem tools'
    $commands = $runtimes + @(Confirm-EcosystemTool -GoManifest (Join-Path $manifestRoot 'ecosystem/go-tools.txt') `
        -UvManifest (Join-Path $manifestRoot 'ecosystem/uv-tools.txt'))
    $checkName = 'PowerShell completions'
    $completionLocalData = Get-CompletionLocalData -Destination $Destination
    Invoke-PowerShellCompletion -Action check -ManifestPath (Join-Path $manifestRoot 'shell/completions.txt') `
        -LocalData $completionLocalData
    $checkName = 'PowerShell profile'
    Confirm-ManagedProfile -ProfilePath $ProfilePath -Destination $Destination -Commands $commands -FixtureBin $ProbeFixtureBin `
        -CompletionLocalData $completionLocalData

    $checkName = 'SSH config'
    $ssh = Get-PathApplication -Name ssh
    Write-LogOk -Name 'SSH executable' -Detail $ssh.Source

    $sshConfig = Join-Path $Destination '.ssh/config'
    if ($null -eq (Resolve-RegularFile -Path $sshConfig)) {
        throw "Missing managed SSH config '$sshConfig'. Run chezmoi apply."
    }
    # -G reads configuration without connecting. Omit -F to exercise the user's
    # default path and the same permission checks as a normal connection.
    $result = Invoke-NativeCommand -Executable $ssh.Source -Arguments @('-v', '-G', 'oh-my-devenv-check.invalid')
    if (-not (Test-SshConfigRead -Diagnostic $result.Stderr -Path $sshConfig)) {
        throw "SSH did not report reading its default user config at '$sshConfig'.`n$($result.Stderr)"
    }
    Write-LogOk -Name 'SSH config' -Detail "$sshConfig"

    if (-not $PSBoundParameters.ContainsKey('DesktopBaseline')) {
        $data = Invoke-NativeCommand -Executable $chezmoi.Source -Arguments @('data', '--format=json')
        $DesktopBaseline = [bool](ConvertFrom-Json -InputObject $data.Stdout -AsHashtable)['desktopBaseline']
    }
    $packageManifests = @(
        Join-Path $manifestRoot 'system/winget-packages.json'
        if ($DesktopBaseline) { Join-Path $manifestRoot 'desktop/winget-packages.json' }
    )
    $checkName = 'WinGet packages'
    Confirm-WinGetPackage -ManifestPath $packageManifests
    if ($DesktopBaseline) {
        $checkName = 'Desktop baseline'
        $localData = Get-DesktopLocalData -Destination $Destination
        $target = Get-DesktopFontTarget -LocalData $localData
        $manifest = Read-DesktopFontManifest -Path (Join-Path $manifestRoot 'desktop/maple-mono-nf-cn.env')
        Confirm-DesktopFont -Manifest $manifest @target
        $fragment = Join-Path $Destination 'AppData/Local/Microsoft/Windows Terminal/Fragments/oh-my-devenv/desktop.json'
        if ($null -eq (Resolve-RegularFile -Path $fragment)) {
            throw "Missing Windows Terminal fragment '$fragment'. Run chezmoi apply."
        }
        Confirm-TerminalFragment -Path $fragment -Family $manifest.Family
    }
    Write-LogInfo -Message 'Core tools in this environment:'
    $checkName = 'chezmoi'
    Write-LogOk -Name chezmoi -Detail (Invoke-NativeCommand -Executable $chezmoi.Source -Arguments @('--version')).Stdout.Trim()
    $checkName = 'git'
    Write-LogOk -Name git -Detail (Invoke-NativeCommand -Executable $git.Source -Arguments @('--version')).Stdout.Trim()
    $checkName = 'mise'
    Write-LogOk -Name mise -Detail (Invoke-GlobalMise -Arguments @('--version')).Stdout.Trim()
    $checkName = 'ssh'
    $version = Invoke-NativeCommand -Executable $ssh.Source -Arguments @('-V')
    Write-LogOk -Name ssh -Detail ($version.Stderr + $version.Stdout).Trim()
    foreach ($runtime in $runtimes) {
        Write-LogOk -Name ([IO.Path]::GetFileNameWithoutExtension($runtime.Name)) -Detail $runtime.Version
    }
    Write-LogPhaseDone
    Write-LogSummary -Message 'All checks passed.' -Counts "$($runtimes.Count + 4) core tools"
} catch {
    Write-LogMissing -Name $checkName
    Write-BootstrapFailure -Failure $_
    Write-LogSummaryFailed -Message 'Checks failed.' -Counts '1 failed check'
    Write-LogNext -Message 'Review the failed check and re-run the environment check.'
    exit (Get-BootstrapExitCode -Failure $_)
}
exit 0
