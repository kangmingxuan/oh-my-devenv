[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '',
    Justification = 'Apply PowerShell initialization emitted by the installed mise and Oh My Posh executables.')]
param()

$ohMyDevenvMiseActivation = & {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    . (Join-Path $PSScriptRoot 'environment.ps1')
    if (-not $env:GOPATH) {
        $env:GOPATH = Join-Path $HOME 'go'
    }
    if (-not $env:GOBIN) {
        $env:GOBIN = Get-DefaultGoBin
    }

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

$env:OH_MY_DEVENV_POSH_CONFIG = $null
$ohMyDevenvPoshActivation = & {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # Script hosts with redirected streams do not need a prompt.
    if ($env:OH_MY_DEVENV_PROBE_PROMPT -cne '1' -and
        ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected)) {
        return
    }

    . (Join-Path $PSScriptRoot 'environment.ps1')
    $posh = Get-PathApplication -Name oh-my-posh -Optional
    if ($posh) {
        $theme = Join-Path $PSScriptRoot 'robbyrussell.omp.json'
        if (-not (Test-Path -LiteralPath $theme -PathType Leaf)) {
            throw "Oh My Posh theme '$theme' is missing. Run chezmoi apply."
        }
        $PSNativeCommandUseErrorActionPreference = $false
        $activation = & $posh.Source init pwsh --config $theme
        if ($LASTEXITCODE -ne 0) {
            throw "Oh My Posh init pwsh exited with code $LASTEXITCODE."
        }
        $activation | Out-String
    }
}
if ($ohMyDevenvPoshActivation) {
    $ohMyDevenvPreviousPrompt = $Function:prompt
    Invoke-Expression -Command $ohMyDevenvPoshActivation
    # Capture the init script's resolved config before the local overlay can replace the prompt.
    if ($env:POSH_SESSION_ID -and $Function:prompt -ne $ohMyDevenvPreviousPrompt) {
        $env:OH_MY_DEVENV_POSH_CONFIG = $env:POSH_CONFIG
    }
    Remove-Variable -Name ohMyDevenvPreviousPrompt
}
Remove-Variable -Name ohMyDevenvPoshActivation

$ohMyDevenvLocalProfile = Join-Path $PSScriptRoot 'profile.local.ps1'
if (Test-Path -LiteralPath $ohMyDevenvLocalProfile -PathType Leaf) {
    . $ohMyDevenvLocalProfile
    & {
        . (Join-Path $PSScriptRoot 'environment.ps1')
        $pathKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($entry in ($env:PATH -split ';')) {
            [void]$pathKeys.Add((ConvertTo-PathKey -Path $entry))
        }
        $missing = @(Get-ManagedProfilePathEntry | Where-Object { $pathKeys.Add((ConvertTo-PathKey -Path $_)) })
        if ($missing.Count) {
            $env:PATH = ($missing + $env:PATH) -join ';'
        }
    }
}
Remove-Variable -Name ohMyDevenvLocalProfile
$env:OH_MY_DEVENV_PROFILE_LOADED = '1'
