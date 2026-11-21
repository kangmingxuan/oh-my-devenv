[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '',
    Justification = 'Apply the PowerShell initialization emitted by the installed mise executable.')]
param()

& {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if (-not $env:GOPATH) {
        $env:GOPATH = Join-Path $HOME 'go'
    }
    if (-not $env:GOBIN) {
        $env:GOBIN = Join-Path $env:GOPATH 'bin'
    }

    $localData = [Environment]::GetFolderPath('LocalApplicationData')
    if (-not $localData) {
        throw 'Windows did not resolve the LocalApplicationData known folder.'
    }
    $managedPath = @(
        (Join-Path $localData 'mise/shims')
        (Join-Path $HOME '.local/bin')
        $env:GOBIN
    )
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $env:PATH = ($managedPath + ($env:PATH -split ';') |
        Where-Object { $_ -and $seen.Add($_) }) -join ';'
    $env:BAT_THEME = 'TwoDark'
}

$ohMyDevenvMiseActivation = & {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $false
    $mise = Get-Command -Name mise -CommandType Application -ErrorAction SilentlyContinue
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
