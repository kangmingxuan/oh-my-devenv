Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) { throw 'The mise helpers require native Windows.' }

function Invoke-GlobalMise {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$AllowFailure, [switch]$Live)

    $mise = Get-PathApplication -Name mise.exe
    Invoke-NativeCommand -Executable $mise.Source -Arguments $Arguments -WorkingDirectory "$env:SystemDrive\" -AllowFailure:$AllowFailure -Live:$Live
}

function Install-Mise {
    if (-not (Get-PathApplication -Name mise.exe -Optional)) {
        $winget = Get-WinGetApplication
        Write-LogInfo 'Installing jdx.mise with WinGet.'
        $result = Invoke-NativeCommand -Executable $winget.Source -Arguments @(
            'install', '--id', 'jdx.mise', '--exact', '--source', 'winget', '--scope', 'user'
            '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
        ) -AllowFailure -Live
        if ($result.ExitCode -ne 0) {
            throw (New-NativeCommandFailure -Result $result -Message (
                "WinGet install of jdx.mise failed (exit $($result.ExitCode)). " +
                'mise requires the architecture-matched Microsoft Visual C++ (VC++ 2015+ Redistributable) installed at machine scope. ' +
                'If it is missing or device policy blocks the install, contact the device administrator.'
            ))
        }
        Update-HookPath -Managed
    } else {
        Write-LogSkip 'mise is already installed.'
    }
    Write-LogOk mise (Invoke-GlobalMise -Arguments @('--version')).Stdout.Trim()
}

function Get-MiseToolExecutable {
    param([Parameter(Mandatory)][string]$Name)

    $result = Invoke-GlobalMise -Arguments @('which', $Name)
    $path = $result.Stdout.Trim()
    if (-not [IO.Path]::IsPathFullyQualified($path) -or -not [IO.File]::Exists($path)) {
        throw "mise did not resolve '$Name' to an existing executable. Reported '$path'."
    }
    $path
}

function Confirm-MiseToolchain {
    $missing = Invoke-GlobalMise -Arguments @('ls', '--current', '--missing', '--no-header')
    if ($missing.Stdout.Trim()) {
        foreach ($line in ($missing.Stdout.Trim() -split '\r?\n')) {
            $name, $version = $line.Trim() -split '\s+', 2
            Write-LogMissing $name $version
        }
        throw "Missing mise tools. Run 'mise install --yes' from the system drive root.`n$($missing.Stdout.Trim())"
    }
}

function Get-MiseProfileCommand {
    param([string]$ConfigPath, [string]$ShimsDirectory)

    $inventory = (Invoke-GlobalMise -Arguments @('ls', '--current', '--json')).Stdout | ConvertFrom-Json -AsHashtable
    # mise merges the machine-local overlay next to the managed config, and its values take precedence.
    $configKeys = @(
        ConvertTo-PathKey -Path $ConfigPath
        ConvertTo-PathKey -Path (Join-Path ([IO.Path]::GetDirectoryName($ConfigPath)) 'config.local.toml')
    )
    $found = $false
    foreach ($name in $inventory.Keys) {
        foreach ($version in $inventory[$name]) {
            $source = $version['source']
            if ($version['active'] -and $source -and (ConvertTo-PathKey -Path $source['path']) -cin $configKeys) {
                $found = $true
                $path = Get-MiseToolExecutable -Name $name
                $binary = [IO.Path]::GetFileName($path)
                @{ Name = $binary; Path = $path; Shim = Join-Path $ShimsDirectory $binary; Version = $version['version'] }
                break
            }
        }
    }
    if (-not $found) { throw "mise reported no active tools from managed config '$ConfigPath'." }
}
