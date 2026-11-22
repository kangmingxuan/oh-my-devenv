param([string]$ManifestPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) { throw 'The Go installer requires native Windows.' }

function Install-GoTool {
    param([Parameter(Mandatory)][string]$ManifestPath)

    $go = Get-MiseToolExecutable -Name go
    $tools = @(Read-GoToolManifest -Path $ManifestPath)
    if (-not $tools.Count) {
        Write-Host 'No Go tools to install.'
        return
    }
    [void][IO.Directory]::CreateDirectory($env:GOBIN)
    Write-Host "Syncing Go tools from '$ManifestPath' into '$env:GOBIN'."
    foreach ($tool in $tools) {
        # Rebuild every tool when the hook inputs change, including the Go version.
        Write-Host "  -> $($tool.Spec)"
        $result = Invoke-NativeCommand -Executable $go -Arguments @('install', $tool.Spec) -WorkingDirectory "$env:SystemDrive\"
        if ($result.Stdout) { Write-Host $result.Stdout }
        if ($result.Stderr) { Write-Host $result.Stderr }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    . (Join-Path $PSScriptRoot 'common.ps1')
    . (Join-Path $PSScriptRoot 'mise.ps1')
    . (Join-Path $PSScriptRoot 'ecosystem.ps1')
    Update-HookPath -Managed
    Install-GoTool -ManifestPath $ManifestPath
}
