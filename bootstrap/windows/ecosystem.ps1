Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) { throw 'The ecosystem helpers require native Windows.' }

function Read-EcosystemManifest {
    param([Parameter(Mandatory)][string]$Path)

    [IO.File]::ReadLines($Path) | ForEach-Object {
        $entry = ($_ -creplace '#.*$').Trim()
        if ($entry) { $entry }
    }
}

function Read-GoToolManifest {
    param([Parameter(Mandatory)][string]$Path)

    foreach ($spec in Read-EcosystemManifest -Path $Path) {
        $token = ($spec -csplit '\s', 2)[0]
        if ($token -cnotmatch '^.*@(v[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?)$') {
            throw "Go tool entry must pin an exact module version (module@vX.Y.Z): $spec"
        }
        $version = $Matches[1]
        $importPath = $token -creplace '@[^@]*$'
        $parts = $importPath -csplit '/'
        $name = $parts[-1]
        if ($parts.Count -gt 1 -and $name -cmatch '^v([2-9]|[1-9][0-9]+)$') { $name = $parts[-2] }
        @{ Spec = $spec; Name = $name; Version = $version; ImportPath = $importPath }
    }
}

function Read-UvToolManifest {
    param([Parameter(Mandatory)][string]$Path)

    foreach ($spec in Read-EcosystemManifest -Path $Path) {
        $name = $spec -creplace '(\s|\[|===|==|~=|!=|<=|>=|<|>|@).*$'
        if (-not $name) { throw "Invalid uv tool entry: $spec" }
        $version = if ($spec.Contains('==')) { ($spec -csplit '==')[-1] }
        @{ Spec = $spec; Name = $name; Version = $version }
    }
}

function Get-PythonVersion {
    param([Parameter(Mandatory)][string]$Executable)

    $result = Invoke-NativeCommand -Executable $Executable -Arguments @(
        '-c', 'import sys; print("%d.%d.%d" % sys.version_info[:3])'
    )
    $result.Stdout.Trim()
}

function Get-UvToolEnvironmentProblem {
    param([string]$ToolDirectory, [string]$Name, [string]$ExpectedVersion)

    $directory = Join-Path $ToolDirectory $Name
    try {
        $running = Get-PythonVersion -Executable (Join-Path $directory 'Scripts/python.exe')
    } catch {
        return 'interpreter is missing or failed to start'
    }
    $builtOn = 'unknown'
    $config = Join-Path $directory 'pyvenv.cfg'
    if ([IO.File]::Exists($config)) {
        $version = Select-String -LiteralPath $config -Pattern '^version_info\s*=\s*(.*)$' -CaseSensitive |
            Select-Object -First 1
        if ($version) { $builtOn = ($version.Matches[0].Groups[1].Value -csplit '\.' | Select-Object -First 3) -join '.' }
    }
    if ($builtOn -cne $running) { return "built on Python $builtOn but runs Python $running" }
    if ($running -cne $ExpectedVersion) { "runs Python $running but mise selects Python $ExpectedVersion" }
}

function Get-UvToolVersion {
    param([string]$Snapshot, [string]$Name)

    $pattern = '^' + [regex]::Escape($Name) + ' v(\S+)'
    foreach ($line in $Snapshot -split '\r?\n') {
        if ($line -cmatch $pattern) { return $Matches[1] }
    }
}

function Confirm-ToolBinary {
    param([string]$Name, [string]$Directory)

    $binary = "$Name.exe"
    $application = Get-PathApplication -Name $binary
    $expected = [IO.Path]::GetFullPath((Join-Path $Directory $binary))
    if ((ConvertTo-PathKey -Path $application.Source) -cne (ConvertTo-PathKey -Path $expected)) {
        throw "$binary is shadowed. PATH selects '$($application.Source)'. Expected '$expected'."
    }
    $expected
}

function Confirm-EcosystemTool {
    param([string]$GoManifest, [string]$UvManifest)

    $goTools = @(Read-GoToolManifest -Path $GoManifest)
    $uvTools = @(Read-UvToolManifest -Path $UvManifest)
    if ($goTools.Count) {
        $go = Get-MiseToolExecutable -Name go
        foreach ($tool in $goTools) {
            $binary = Confirm-ToolBinary -Name $tool.Name -Directory $env:GOBIN
            $result = Invoke-NativeCommand -Executable $go -Arguments @('version', '-m', $binary) `
                -Environment @{ GOROOT = $null }
            $buildInfo = $result.Stdout -split '\r?\n'
            $pathLines = @($buildInfo | Where-Object { $_ -cmatch '^\tpath\t' })
            if ($pathLines.Count -ne 1 -or ($pathLines[0] -csplit '\t', 3)[2] -cne $tool.ImportPath) {
                throw "Go tool '$($tool.Name)' does not have command path '$($tool.ImportPath)'.`n$($result.Stdout)"
            }
            $moduleLines = @($buildInfo | Where-Object { $_ -cmatch '^\tmod\t' })
            if ($moduleLines.Count -ne 1 -or ($moduleLines[0] -csplit '\t')[3] -cne $tool.Version) {
                throw "Go tool '$($tool.Name)' does not have module version '$($tool.Version)'.`n$($result.Stdout)"
            }
            @{ Name = "$($tool.Name).exe"; Path = $binary }
        }
    }
    if ($uvTools.Count) {
        $uv = Get-MiseToolExecutable -Name uv
        $python = Get-MiseToolExecutable -Name python
        $pythonVersion = Get-PythonVersion -Executable $python
        $snapshot = (Invoke-NativeCommand -Executable $uv -Arguments @('tool', 'list')).Stdout
        $directory = (Invoke-NativeCommand -Executable $uv -Arguments @('tool', 'dir')).Stdout.Trim()
        $binDirectory = (Invoke-NativeCommand -Executable $uv -Arguments @('tool', 'dir', '--bin')).Stdout.Trim()
        foreach ($tool in $uvTools) {
            $current = Get-UvToolVersion -Snapshot $snapshot -Name $tool.Name
            if (-not $current -or ($tool.Version -and $current -cne $tool.Version)) {
                throw "uv tool '$($tool.Name)' has version '$current'. Expected '$($tool.Spec)'."
            }
            $binary = Confirm-ToolBinary -Name $tool.Name -Directory $binDirectory
            $problem = Get-UvToolEnvironmentProblem -ToolDirectory $directory -Name $tool.Name -ExpectedVersion $pythonVersion
            if ($problem) { throw "uv tool '$($tool.Name)': $problem." }
            @{ Name = "$($tool.Name).exe"; Path = $binary }
        }
    }
}
