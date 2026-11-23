param([string]$ManifestPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) { throw 'The Go installer requires native Windows.' }

function Get-GoInstallArgument {
    param(
        [Parameter(Mandatory)][string]$Spec,
        [Parameter(Mandatory)][string]$TargetArchitecture
    )

    # Delve v1.27.2 builds for windows/arm64 only with its experimental tag. Scope the tag to
    # Delve so other tools keep their default build inputs.
    $package = $Spec.Substring(0, $Spec.LastIndexOf('@'))
    if ($TargetArchitecture -ceq 'arm64' -and $package -ceq 'github.com/go-delve/delve/cmd/dlv') {
        return @('install', '-tags=exp.winarm64', $Spec)
    }
    @('install', $Spec)
}

function Install-GoTool {
    param([Parameter(Mandatory)][string]$ManifestPath)

    $go = Get-MiseToolExecutable -Name go
    $tools = @(Read-GoToolManifest -Path $ManifestPath)
    if (-not $tools.Count) {
        Write-Host 'No Go tools to install.'
        return
    }
    $targetArchitecture = (Invoke-NativeCommand -Executable $go -Arguments @('env', 'GOARCH') `
            -WorkingDirectory "$env:SystemDrive\").Stdout.Trim()
    if (-not $targetArchitecture) { throw "'$go env GOARCH' reported no target architecture." }
    [void][IO.Directory]::CreateDirectory($env:GOBIN)
    Write-Host "Syncing Go tools from '$ManifestPath' into '$env:GOBIN'."
    foreach ($tool in $tools) {
        # Rebuild every tool when the hook inputs change, including the Go version.
        Write-Host "  -> $($tool.Spec)"
        $arguments = Get-GoInstallArgument -Spec $tool.Spec -TargetArchitecture $targetArchitecture
        $result = Invoke-NativeCommand -Executable $go -Arguments $arguments -WorkingDirectory "$env:SystemDrive\"
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
