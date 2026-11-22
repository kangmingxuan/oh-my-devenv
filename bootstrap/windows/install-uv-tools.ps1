param([string]$ManifestPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) { throw 'The uv installer requires native Windows.' }

function Install-UvTool {
    param([Parameter(Mandatory)][string]$ManifestPath)

    $uv = Get-MiseToolExecutable -Name uv
    $tools = @(Read-UvToolManifest -Path $ManifestPath)
    if (-not $tools.Count) {
        Write-Host 'No uv tools to install.'
        return
    }
    $python = Get-MiseToolExecutable -Name python
    $pythonVersion = Get-PythonVersion -Executable $python
    $snapshot = (Invoke-NativeCommand -Executable $uv -Arguments @('tool', 'list')).Stdout
    $directory = (Invoke-NativeCommand -Executable $uv -Arguments @('tool', 'dir')).Stdout.Trim()
    Write-Host "Syncing uv tools from '$ManifestPath'."

    foreach ($tool in $tools) {
        $current = Get-UvToolVersion -Snapshot $snapshot -Name $tool.Name
        if ($current) {
            $problem = if ($env:DOTFILES_FORCE_REINSTALL -ceq '1') { 'force reinstall' } else {
                Get-UvToolEnvironmentProblem -ToolDirectory $directory -Name $tool.Name -ExpectedVersion $pythonVersion
            }
            if ($problem) {
                Write-Host "  -> $($tool.Spec) (rebuilding: $problem)"
                $result = Invoke-NativeCommand -Executable $uv -Arguments @('tool', 'uninstall', $tool.Name)
                if ($result.Stderr) { Write-Host $result.Stderr }
            } elseif ($tool.Version -and $current -ceq $tool.Version) {
                Write-Host "  == $($tool.Spec) (already at $current, skipping)"
                continue
            }
        }
        Write-Host "  -> $($tool.Spec)"
        $result = Invoke-NativeCommand -Executable $uv -Arguments @('tool', 'install', '--python', $python, $tool.Spec)
        if ($result.Stdout) { Write-Host $result.Stdout }
        if ($result.Stderr) { Write-Host $result.Stderr }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    . (Join-Path $PSScriptRoot 'common.ps1')
    . (Join-Path $PSScriptRoot 'mise.ps1')
    . (Join-Path $PSScriptRoot 'ecosystem.ps1')
    Update-HookPath -Managed
    Install-UvTool -ManifestPath $ManifestPath
}
