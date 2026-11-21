[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '',
    Justification = 'Apply the PowerShell initialization emitted by the installed mise executable.')]
param()

$ohMyDevenvMiseActivation = & {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if (-not $env:GOPATH) {
        $env:GOPATH = Join-Path $HOME 'go'
    }
    if (-not $env:GOBIN) {
        $env:GOBIN = Join-Path $env:GOPATH 'bin'
    }

    . (Join-Path $PSScriptRoot 'environment.ps1')
    $managedPath = @(Get-ManagedProfilePathEntry)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $env:PATH = ($managedPath + ($env:PATH -split ';') |
        Where-Object { $_ -and $seen.Add($_) }) -join ';'
    $env:BAT_THEME = 'TwoDark'
    $PSNativeCommandUseErrorActionPreference = $false
    $mise = Get-PathApplication -Name mise -Optional
    if ($mise) {
        $activation = & $mise.Source activate pwsh
        if ($LASTEXITCODE -ne 0) {
            throw "mise activate pwsh exited with code $LASTEXITCODE."
        }
        $activation | Out-String
    }
}
if ($ohMyDevenvMiseActivation) {
    Invoke-Expression -Command $ohMyDevenvMiseActivation
}
Remove-Variable -Name ohMyDevenvMiseActivation

$ohMyDevenvLocalProfile = Join-Path $PSScriptRoot 'profile.local.ps1'
if (Test-Path -LiteralPath $ohMyDevenvLocalProfile -PathType Leaf) {
    . $ohMyDevenvLocalProfile
}
Remove-Variable -Name ohMyDevenvLocalProfile
$env:OH_MY_DEVENV_PROFILE_LOADED = '1'
