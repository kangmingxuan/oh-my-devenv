Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-BuiltInWinGetSource {
    param($Details)

    $Details -is [Collections.IDictionary] -and $Details['Name'] -ceq 'winget' -and
        $Details['Type'] -ceq 'Microsoft.PreIndexed.Package' -and
        $Details['Identifier'] -ceq 'Microsoft.Winget.Source_8wekyb3d8bbwe'
}

function Read-WinGetPackageManifest {
    param([Parameter(Mandatory)][string]$Path)

    $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    $sources = $manifest['Sources']
    $details = if ($sources -is [array] -and $sources.Count -eq 1 -and $sources[0] -is [Collections.IDictionary]) {
        $sources[0]['SourceDetails']
    }
    if (-not (Test-BuiltInWinGetSource -Details $details)) {
        throw "The WinGet manifest '$Path' must use only the winget source."
    }
    $packages = $sources[0].Packages
    if ($packages -isnot [array] -or $packages.Count -eq 0) {
        throw "The WinGet manifest '$Path' must contain a nonempty Packages array."
    }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($package in $packages) {
        $id = $package['PackageIdentifier']
        if ($id -isnot [string] -or $id -cnotmatch '^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$') {
            throw "Invalid package ID '$id' in the WinGet manifest '$Path'."
        }
        if ($package['Scope'] -cne 'user' -or $package.Contains('Version')) {
            throw "Package '$id' must use user scope without a pinned version in '$Path'."
        }
        if (-not $ids.Add($id)) {
            throw "Duplicate package ID '$id' in the WinGet manifest '$Path'."
        }
    }
    $packages.PackageIdentifier
}

function Get-WinGetApplication {
    $winget = Get-PathApplication -Name winget.exe -Optional
    if ($null -eq $winget) {
        throw 'WinGet (winget.exe) was not found on PATH. Install or enable App Installer. Device policy may block WinGet.'
    }
    $winget
}

function Install-WinGetPackage {
    param([Parameter(Mandatory)][string]$ManifestPath)

    $ids = @(Read-WinGetPackageManifest -Path $ManifestPath)
    $winget = Get-WinGetApplication
    $result = Invoke-NativeCommand -Executable $winget.Source -Arguments @(
        'import', '--import-file', $ManifestPath, '--no-upgrade', '--accept-package-agreements'
        '--accept-source-agreements', '--disable-interactivity'
    ) -AllowFailure -Live
    if ($result.ExitCode -ne 0) {
        throw (ConvertTo-NativeCommandException -Result $result -Message (
            "WinGet import from source 'winget' failed (exit $($result.ExitCode)). Device policy may block this source or an installer. Manifest package IDs: $($ids -join ', ')."
        ))
    }
    Write-LogOk -Name WinGet -Detail "Imported '$ManifestPath'."
}

function Confirm-WinGetPackage {
    param([Parameter(Mandatory)][string[]]$ManifestPath)

    $ids = @(foreach ($path in $ManifestPath) { Read-WinGetPackageManifest -Path $path })
    $winget = Get-WinGetApplication
    # WinGet 1.11 can enumerate an installed package that its exact-ID list filter misses.
    # Export enumerates installed registrations and supplies the catalog IDs as JSON.
    $temp = [IO.Directory]::CreateTempSubdirectory('oh-my-devenv-winget-')
    try {
        $inventoryPath = Join-Path $temp.FullName 'installed.json'
        $result = Invoke-NativeCommand -Executable $winget.Source -Arguments @(
            'export', '--output', $inventoryPath, '--source', 'winget', '--accept-source-agreements', '--disable-interactivity'
        ) -AllowFailure
        if ($result.ExitCode -eq 0x8A150014) {
            # APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND means there is nothing to export.
            $installedIds = @()
        } elseif ($result.ExitCode -ne 0) {
            throw (ConvertTo-NativeCommandException -Result $result -Message (
                "WinGet could not export installed packages from source 'winget' (exit $($result.ExitCode)). Device policy may block this source."
            ))
        } else {
            $inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json -AsHashtable
            $installedIds = @(
                foreach ($source in $inventory['Sources']) {
                    if (Test-BuiltInWinGetSource -Details $source['SourceDetails']) {
                        foreach ($package in $source['Packages']) {
                            $package['PackageIdentifier']
                        }
                    }
                }
            )
        }
    } finally {
        $temp.Delete($true)
    }

    $missing = @($ids | Where-Object { $_ -cnotin $installedIds })
    if ($missing) {
        foreach ($id in $missing) { Write-LogMissing -Name $id -Detail "WinGet user package" }
        throw "Missing WinGet packages: $($missing -join ', '). Install them from the winget source using user scope."
    }
    Write-LogOk -Name WinGet -Detail "Reported all $($ids.Count) packages from the enabled layers."
}
