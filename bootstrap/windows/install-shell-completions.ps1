param(
    [Parameter(Mandatory)][ValidateSet('install', 'check', 'list')][string]$Action,
    [Parameter(Mandatory)][ValidateSet('windows')][string]$Platform,
    [Parameter(Mandatory)][string]$ManifestPath,
    [string]$Destination = $HOME,
    [string]$Fingerprint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')
trap {
    Write-BootstrapFailure -Failure $_
    exit (Get-BootstrapExitCode -Failure $_)
}

if (-not $IsWindows) { throw 'The shell completion installer requires native Windows.' }
if ($PSVersionTable.PSVersion -lt [version]'7.6') { throw 'PowerShell 7.6 or later is required.' }

. (Join-Path $PSScriptRoot 'completions.ps1')

if ($Platform -eq 'windows' -and $Action -ne 'list') { Update-HookPath -Managed }
$options = @{ Action = $Action; ManifestPath = $ManifestPath; LocalData = Get-CompletionLocalData -Destination $Destination }
if ($PSBoundParameters.ContainsKey('Fingerprint')) { $options.Fingerprint = $Fingerprint }
if ($Action -eq 'install') { Write-LogPhase -Message 'Installing shell completions...' }
Invoke-PowerShellCompletion @options
if ($Action -eq 'install') { Write-LogPhaseDone }
exit 0
