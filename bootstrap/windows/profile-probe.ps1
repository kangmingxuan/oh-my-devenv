[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Writes the internal probe success marker directly to stdout rather than user-facing status output.')]
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
        $name = [IO.Path]::GetFileNameWithoutExtension($command.Name)
        $resolved = Get-Command -Name $name -TotalCount 1 -ErrorAction SilentlyContinue
        if ($null -eq $resolved) { throw "The managed profile did not resolve '$name'." }
        if ($resolved.CommandType -ne 'Application') {
            throw "The managed profile resolved '$name' as $($resolved.CommandType). Expected application '$($command.Path)'."
        }
        $expected = @($command.Path, $command['Shim'] | Where-Object { $_ } |
            ForEach-Object { ConvertTo-PathKey -Path $_ })
        if ((ConvertTo-PathKey -Path $resolved.Source) -cnotin $expected) {
            throw "The managed profile resolved '$name' to '$($resolved.Source)'. Expected '$($command.Path)'."
        }
    }
}
if ($env:OH_MY_DEVENV_COMPLETIONS_LOADED -cne '1') {
    throw 'The managed PowerShell profile did not load owned completions. Run chezmoi apply.'
}
& (Join-Path $PSScriptRoot 'completion-probe.ps1')
[Console]::WriteLine("`n$SuccessMarker")
