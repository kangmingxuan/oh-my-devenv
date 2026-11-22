param(
    [Parameter(Mandatory)][ValidateSet('install', 'check', 'list')][string]$Action,
    [Parameter(Mandatory)][ValidateSet('windows')][string]$Platform,
    [Parameter(Mandatory)][string]$ManifestPath,
    [string]$Destination = $HOME
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) { throw 'The shell completion installer requires native Windows.' }
if ($PSVersionTable.PSVersion -lt [version]'7.6') { throw 'PowerShell 7.6 or later is required.' }

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'completions.ps1')

if ($Platform -eq 'windows' -and $Action -ne 'list') { Update-HookPath -Managed }
Invoke-PowerShellCompletion -Action $Action -ManifestPath $ManifestPath -LocalData (Get-CompletionLocalData -Destination $Destination)
