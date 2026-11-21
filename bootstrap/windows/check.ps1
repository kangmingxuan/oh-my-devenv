param(
    [string]$Destination = $HOME,
    [string]$ProfilePath = $PROFILE.CurrentUserAllHosts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'backup.ps1')
. (Join-Path $PSScriptRoot 'profile.ps1')

if ($PSVersionTable.PSVersion -lt [version]'7.6') {
    throw "PowerShell 7.6 or later is required. Running $($PSVersionTable.PSVersion)."
}
$git = Get-PathApplication -Name git
$result = Invoke-NativeCommand -Executable $git.Source -Arguments @('--version')
Write-Host $result.Stdout.Trim()

foreach ($relativePath in @('.gitconfig', '.config/mise/config.toml', '.config/oh-my-devenv/powershell/profile.ps1',
    '.config/oh-my-devenv/powershell/environment.ps1')) {
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

Confirm-ManagedProfile -ProfilePath $ProfilePath

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
Write-Host 'All checks passed.'
