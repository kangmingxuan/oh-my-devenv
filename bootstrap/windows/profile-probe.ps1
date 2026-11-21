param(
    [Parameter(Mandatory)][string]$SuccessMarker,
    [Parameter(Mandatory)][string]$ExpectedPoshConfig,
    [string]$FixtureProfilePath
)

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
if (-not $env:OH_MY_DEVENV_POSH_CONFIG -or
    (ConvertTo-PathKey -Path $env:OH_MY_DEVENV_POSH_CONFIG) -cne (ConvertTo-PathKey -Path $ExpectedPoshConfig)) {
    throw "The managed profile did not initialize Oh My Posh with '$ExpectedPoshConfig'. Check that oh-my-posh is on PATH and run chezmoi apply."
}
[Console]::WriteLine("`n$SuccessMarker")
