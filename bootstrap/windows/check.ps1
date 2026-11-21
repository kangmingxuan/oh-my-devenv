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
$git = Get-Command -Name git -CommandType Application -ErrorAction Stop
$result = Invoke-NativeCommand -Executable $git.Source -Arguments @('--version')
Write-Host $result.Stdout.Trim()

foreach ($relativePath in @('.gitconfig', '.config/mise/config.toml', '.config/oh-my-devenv/powershell/profile.ps1')) {
    $target = Join-Path $Destination $relativePath
    if ($null -eq (Resolve-RegularFile -Path $target)) {
        throw "Missing managed file '$target'. Run chezmoi apply."
    }
}

if ($null -eq (Resolve-RegularFile -Path $ProfilePath) -or
    (Read-ProfileFile -Path $ProfilePath).Content -cnotmatch (Get-ManagedProfilePattern -Destination $Destination)) {
    throw "The managed line is missing from PowerShell profile '$ProfilePath'. Run chezmoi apply."
}

$ssh = Get-Command -Name ssh -CommandType Application -ErrorAction Stop
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
$prefix = 'Reading configuration data '
$expected = [IO.Path]::GetFullPath($sshConfig).Replace('\', '/')
$readConfig = foreach ($line in ($result.Stderr -split '\r?\n')) {
    if ($line -match "^debug1: $prefix(.+)$") {
        $Matches[1].Replace('\', '/')
    }
}
if ($expected -notin $readConfig) {
    throw "SSH did not report reading its default user config at '$expected'.`n$($result.Stderr)"
}
Write-Host "SSH read managed config: $expected"
Write-Host 'All checks passed.'
