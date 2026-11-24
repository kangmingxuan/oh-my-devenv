param([string]$ManifestPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) { throw 'The uv installer requires native Windows.' }

function Install-UvTool {
    param([Parameter(Mandatory)][string]$ManifestPath)

    $uv = Get-MiseToolExecutable -Name uv
    $tools = @(Read-UvToolManifest -Path $ManifestPath)
    if (-not $tools.Count) {
        Write-LogSkip -Message 'No uv tools to install.'
        return
    }
    $python = Get-MiseToolExecutable -Name python
    $pythonVersion = Get-PythonVersion -Executable $python
    $snapshot = (Invoke-NativeCommand -Executable $uv -Arguments @('tool', 'list')).Stdout
    $directory = (Invoke-NativeCommand -Executable $uv -Arguments @('tool', 'dir')).Stdout.Trim()
    Write-LogInfo -Message "Syncing uv tools from '$ManifestPath'."

    foreach ($tool in $tools) {
        $current = Get-UvToolVersion -Snapshot $snapshot -Name $tool.Name
        if ($current) {
            $problem = if ($env:DOTFILES_FORCE_REINSTALL -ceq '1') { 'force reinstall' } else {
                Get-UvToolEnvironmentProblem -ToolDirectory $directory -Name $tool.Name -ExpectedVersion $pythonVersion
            }
            if ($problem) {
                Write-LogInfo -Message "Installing $($tool.Spec) (rebuilding: $problem)"
                $null = Invoke-NativeCommand -Executable $uv -Arguments @('tool', 'uninstall', $tool.Name) -Live
            } elseif ($tool.Version -and $current -ceq $tool.Version) {
                Write-LogSkip -Message "$($tool.Spec) (already at $current, skipping)"
                continue
            }
        }
        Write-LogInfo -Message "Installing $($tool.Spec)"
        $null = Invoke-NativeCommand -Executable $uv -Arguments @('tool', 'install', '--python', $python, $tool.Spec) -Live
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    . (Join-Path $PSScriptRoot 'common.ps1')
    . (Join-Path $PSScriptRoot 'mise.ps1')
    . (Join-Path $PSScriptRoot 'ecosystem.ps1')
    trap {
        Write-BootstrapFailure -Failure $_
        exit (Get-BootstrapExitCode -Failure $_)
    }
    Write-LogPhase -Message 'Syncing uv tools...'
    Update-HookPath -Managed
    Install-UvTool -ManifestPath $ManifestPath
    Write-LogPhaseDone
}
