Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($query in @(
    @{ Line = 'chezmoi '; Expected = 'apply' }
    @{ Line = 'uv '; Expected = 'tool' }
)) {
    $completions = (TabExpansion2 -inputScript $query.Line -cursorColumn $query.Line.Length).CompletionMatches
    # Check a subcommand so fallback file completions cannot pass the probe.
    if (-not ($completions | Where-Object {
            ($_.CompletionText -split '\s+', 2)[0] -ceq $query.Expected -and
                $_.ResultType -notin 'ProviderItem', 'ProviderContainer'
        })) {
        throw "PowerShell did not complete '$($query.Line)' with '$($query.Expected)'. Run chezmoi apply."
    }
}
