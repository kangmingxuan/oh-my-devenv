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
    throw "Oh My Posh did not load the managed theme.`nExpected '$ExpectedPoshConfig'. Check that oh-my-posh is on PATH and run chezmoi apply."
}
if ($env:OH_MY_DEVENV_PROBE_COMMANDS) {
    $commands = ConvertFrom-Json -InputObject $env:OH_MY_DEVENV_PROBE_COMMANDS -AsHashtable
    foreach ($command in $commands) {
        $application = Get-PathApplication -Name $command.Name
        $expected = @($command.Path, $command['Shim'] | Where-Object { $_ } |
            ForEach-Object { ConvertTo-PathKey -Path $_ })
        if ((ConvertTo-PathKey -Path $application.Source) -cnotin $expected) {
            throw "The managed profile resolved '$($command.Name)' to '$($application.Source)'. Expected '$($command.Path)'."
        }
    }
}
[Console]::WriteLine("`n$SuccessMarker")
