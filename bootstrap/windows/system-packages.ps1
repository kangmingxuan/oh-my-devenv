Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-WinGetPackageManifest {
    param([Parameter(Mandatory)][string]$Path)

    $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    $sources = $manifest['Sources']
    if ($sources -isnot [array] -or $sources.Count -ne 1 -or $sources[0].SourceDetails.Name -cne 'winget') {
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

function Install-SystemPackage {
    param([Parameter(Mandatory)][string]$ManifestPath)

    $ids = @(Read-WinGetPackageManifest -Path $ManifestPath)
    $winget = Get-WinGetApplication
    $result = Invoke-NativeCommand -Executable $winget.Source -Arguments @(
        'import', '--import-file', $ManifestPath, '--no-upgrade', '--accept-package-agreements'
        '--accept-source-agreements', '--disable-interactivity'
    ) -AllowFailure
    if ($result.ExitCode -ne 0) {
        throw "WinGet import from source 'winget' failed (exit $($result.ExitCode)). Device policy may block this source or an installer. Manifest package IDs: $($ids -join ', ').`n$($result.Stderr)`n$($result.Stdout)"
    }
    Write-Host $result.Stdout.Trim()
    if ($result.Stderr) {
        Write-Host $result.Stderr.Trim()
    }
}

function Confirm-SystemPackage {
    param([Parameter(Mandatory)][string]$ManifestPath)

    $ids = @(Read-WinGetPackageManifest -Path $ManifestPath)
    $winget = Get-WinGetApplication
    $missing = foreach ($id in $ids) {
        $result = Invoke-NativeCommand -Executable $winget.Source -Arguments @(
            'list', '--id', $id, '--exact', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity'
        ) -AllowFailure
        # APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND is independent of the client locale.
        if ($result.ExitCode -eq 0x8A150014) {
            $id
        } elseif ($result.ExitCode -ne 0) {
            throw "WinGet could not check '$id' in source 'winget' (exit $($result.ExitCode)). Device policy may block this source.`n$($result.Stderr)`n$($result.Stdout)"
        }
    }
    if ($missing) {
        throw "Missing WinGet packages: $($missing -join ', '). Install them from the winget source using user scope."
    }
    Write-Host "WinGet reported all $($ids.Count) system packages."
}
