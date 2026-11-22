param(
    [string]$Destination = $HOME,
    [string]$ProfilePath = $PROFILE.CurrentUserAllHosts,
    [string]$RegistryPath = 'Environment',
    [switch]$DesktopBaseline,
    [string]$ProbeFixtureBin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'This check requires native Windows.'
}
if ($PSVersionTable.PSVersion -lt [version]'7.6') {
    throw "PowerShell 7.6 or later is required. Running $($PSVersionTable.PSVersion)."
}
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'backup.ps1')
. (Join-Path $PSScriptRoot 'profile.ps1')
. (Join-Path $PSScriptRoot 'system-packages.ps1')
. (Join-Path $PSScriptRoot 'desktop.ps1')
. (Join-Path $PSScriptRoot 'user-path.ps1')
. (Join-Path $PSScriptRoot 'mise.ps1')
. (Join-Path $PSScriptRoot 'ecosystem.ps1')
. (Join-Path $PSScriptRoot 'completions.ps1')

Update-HookPath -Managed
$git = Get-PathApplication -Name git
$result = Invoke-NativeCommand -Executable $git.Source -Arguments @('--version')
Write-Host $result.Stdout.Trim()

foreach ($relativePath in @('.gitconfig', '.config/mise/config.toml', '.config/oh-my-devenv/powershell/profile.ps1',
    '.config/oh-my-devenv/powershell/environment.ps1', '.config/oh-my-devenv/powershell/completions.ps1')) {
    $target = Join-Path $Destination $relativePath
    if ($null -eq (Resolve-RegularFile -Path $target)) {
        throw "Missing managed file '$target'. Run chezmoi apply."
    }
}

$gitConfig = [IO.Path]::GetFullPath((Join-Path $Destination '.gitconfig'))
$result = Invoke-NativeCommand -Executable $git.Source -Arguments @('var', 'GIT_CONFIG_GLOBAL')
# Git can read an XDG global file in addition to the managed home file.
$gitGlobalPaths = @($result.Stdout.TrimEnd("`r`n") -split '\r?\n' | Where-Object { $_ })
$gitGlobalKeys = @($gitGlobalPaths | ForEach-Object { ConvertTo-PathKey -Path ([IO.Path]::GetFullPath($_)) })
if ((ConvertTo-PathKey -Path $gitConfig) -cnotin $gitGlobalKeys) {
    throw "Git global config paths '$($gitGlobalPaths -join "', '")' do not include managed file '$gitConfig'."
}
Write-Host "Git reported managed global config: $gitConfig"

if ($null -eq (Resolve-RegularFile -Path $ProfilePath) -or
    (Read-ProfileFile -Path $ProfilePath).Content -cnotmatch (Get-ManagedProfilePattern -Destination $Destination)) {
    throw "The managed line is missing from PowerShell profile '$ProfilePath'. Run chezmoi apply."
}

$manifestRoot = Join-Path $PSScriptRoot '../manifests'
Confirm-MiseToolchain
$configPath = Join-Path $Destination '.config/mise/config.toml'
$managedEntries = @(Get-ManagedProfilePathEntry)
$missingPath = @(Get-MissingUserPathEntry -PathValue (Read-UserPath -RegistryPath $RegistryPath) -Entries $managedEntries)
if ($missingPath.Count) {
    throw "Missing directories in the user Path: $($missingPath -join '; '). Run chezmoi apply."
}
$commands = @(
    Get-MiseProfileCommand -ConfigPath $configPath -ShimsDirectory $managedEntries[0]
    Confirm-EcosystemTool -GoManifest (Join-Path $manifestRoot 'ecosystem/go-tools.txt') `
        -UvManifest (Join-Path $manifestRoot 'ecosystem/uv-tools.txt')
)
$completionLocalData = Get-CompletionLocalData -Destination $Destination
Invoke-PowerShellCompletion -Action check -ManifestPath (Join-Path $manifestRoot 'shell/completions.txt') `
    -LocalData $completionLocalData
Confirm-ManagedProfile -ProfilePath $ProfilePath -Destination $Destination -Commands $commands -FixtureBin $ProbeFixtureBin `
    -CompletionLocalData $completionLocalData

$ssh = Get-PathApplication -Name ssh
$version = Invoke-NativeCommand -Executable $ssh.Source -Arguments @('-V')
Write-Host "SSH executable: $($ssh.Source)"
Write-Host ($version.Stderr + $version.Stdout).Trim()

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
Write-Host "SSH read managed config: $sshConfig"

if (-not $PSBoundParameters.ContainsKey('DesktopBaseline')) {
    $chezmoi = Get-PathApplication -Name chezmoi
    $data = Invoke-NativeCommand -Executable $chezmoi.Source -Arguments @('data', '--format=json')
    $DesktopBaseline = [bool](ConvertFrom-Json -InputObject $data.Stdout -AsHashtable)['desktopBaseline']
}
$packageManifests = @(
    Join-Path $manifestRoot 'system/winget-packages.json'
    if ($DesktopBaseline) { Join-Path $manifestRoot 'desktop/winget-packages.json' }
)
Confirm-WinGetPackage -ManifestPath $packageManifests
if ($DesktopBaseline) {
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
Write-Host 'All checks passed.'
