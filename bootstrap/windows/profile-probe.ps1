param([string]$FixtureProfilePath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($FixtureProfilePath) {
    . $FixtureProfilePath
}
if ($env:OH_MY_DEVENV_PROFILE_LOADED -cne '1') {
    throw 'The managed PowerShell profile body did not run to completion.'
}

. (Join-Path $PSScriptRoot '../../dot_config/oh-my-devenv/powershell/environment.ps1')
$entries = @($env:PATH -split [IO.Path]::PathSeparator | ForEach-Object { ConvertTo-PathKey -Path $_ })
foreach ($entry in Get-ManagedProfilePathEntry) {
    if ((ConvertTo-PathKey -Path $entry) -cnotin $entries) {
        throw "The managed profile did not add '$entry' to PATH."
    }
}
