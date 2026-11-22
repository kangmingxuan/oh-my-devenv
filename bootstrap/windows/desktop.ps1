Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-DesktopFontManifest {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Desktop font manifest '$Path' not found."
    }
    $values = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*(?:#.*)?$') { continue }
        if ($line -cnotmatch '^(MAPLE_MONO_[A-Z0-9_]+)=(?:"([^"]*)"|([^"\s]*))$') {
            throw "Invalid assignment in desktop font manifest '$Path': $line"
        }
        $key = $Matches[1]
        $value = if ($Matches.ContainsKey(2)) { $Matches[2] } else { $Matches[3] }
        if (-not $values.TryAdd($key, $value)) {
            throw "Duplicate assignment '$key' in desktop font manifest '$Path'."
        }
    }
    foreach ($key in @('FAMILY', 'POSTSCRIPT_NAMES', 'VERSION', 'ARCHIVE', 'URL', 'SHA256')) {
        $name = "MAPLE_MONO_$key"
        if (-not $values.ContainsKey($name) -or -not $values[$name]) {
            throw "Desktop font manifest '$Path' does not define $name."
        }
    }
    if ($values['MAPLE_MONO_FAMILY'] -cnotmatch '^[A-Za-z0-9][A-Za-z0-9 -]*$') {
        throw 'MAPLE_MONO_FAMILY must contain only letters, digits, spaces, and hyphens.'
    }
    $faces = $values['MAPLE_MONO_POSTSCRIPT_NAMES'].Trim() -split '\s+'
    foreach ($face in $faces) {
        if ($face -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]*$') {
            throw "MAPLE_MONO_POSTSCRIPT_NAMES contains an invalid PostScript name: '$face'."
        }
    }
    if (@($faces | Select-Object -Unique).Count -ne $faces.Count) {
        throw 'MAPLE_MONO_POSTSCRIPT_NAMES contains duplicate PostScript names.'
    }
    $sha = $values['MAPLE_MONO_SHA256']
    if ($sha -cnotmatch '^[0-9a-f]{64}$') {
        throw 'MAPLE_MONO_SHA256 is not a lowercase SHA-256 digest.'
    }
    $url = [uri]$values['MAPLE_MONO_URL']
    if (-not $url.IsAbsoluteUri -or $url.Scheme -ne 'https') {
        throw 'MAPLE_MONO_URL must be an absolute HTTPS URL.'
    }
    @{ Family = $values['MAPLE_MONO_FAMILY']; Faces = $faces; Url = $url; Sha256 = $sha }
}

function Test-WindowsTerminal {
    [bool]((Get-PathApplication -Name wt.exe -Optional) -or
        (Get-PathApplication -Name WindowsTerminal.exe -Optional))
}

function Get-DesktopLocalData {
    param([Parameter(Mandatory)][string]$Destination)

    $localData = [Environment]::GetFolderPath('LocalApplicationData')
    $expected = Join-Path $Destination 'AppData/Local'
    if (-not $localData -or (ConvertTo-PathKey -Path $localData) -cne (ConvertTo-PathKey -Path $expected)) {
        throw "Unsupported Windows desktop baseline: LocalAppData resolves to '$localData'. Expected '$expected'."
    }
    if (-not (Test-WindowsTerminal)) {
        throw 'Unsupported Windows desktop baseline: Windows Terminal is required. Install it or make wt.exe (or WindowsTerminal.exe) available on PATH.'
    }
    $localData
}

function Confirm-TerminalFragment {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Family)

    $content = Get-Content -LiteralPath $Path -Raw
    try {
        $fragment = ConvertFrom-Json -InputObject $content -AsHashtable -NoEnumerate
    } catch {
        throw "Invalid JSON in Windows Terminal fragment '$Path'. $($_.Exception.Message)"
    }
    if ($fragment -isnot [Collections.IDictionary] -or $fragment['profiles'] -isnot [array] -or
        $fragment['profiles'].Count -ne 1 -or $fragment['profiles'][0] -isnot [Collections.IDictionary] -or
        $fragment['profiles'][0]['updates'] -isnot [string] -or
        $fragment['profiles'][0]['updates'] -ne '{574e775e-4f2a-5b96-ac1e-a2962a402336}') {
        throw "The Windows Terminal fragment '$Path' must update the PowerShell 7 profile. Run chezmoi apply."
    }
    $font = $fragment['profiles'][0]['font']
    if ($font -isnot [Collections.IDictionary] -or $font['face'] -isnot [string] -or $font['face'] -cne $Family) {
        throw "The Windows Terminal fragment '$Path' must set the font face to '$Family'. Run chezmoi apply."
    }
}

function Get-DesktopFontTarget {
    param([Parameter(Mandatory)][string]$LocalData)

    @{
        FontDirectory = Join-Path $LocalData 'Microsoft/Windows/Fonts'
        RegistryPath = 'Software\Microsoft\Windows NT\CurrentVersion\Fonts'
        StatePath = Join-Path $LocalData 'oh-my-devenv/fonts.json'
    }
}

function Read-DesktopFontRecord {
    param([Parameter(Mandatory)][string]$StatePath)

    try {
        $record = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($StatePath)) -AsHashtable -NoEnumerate
    } catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] {
        return @{}
    }
    if ($record -isnot [Collections.IDictionary]) { throw "Invalid desktop font ownership record '$StatePath'." }
    foreach ($face in $record.Keys) {
        $entry = $record[$face]
        if ($face -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]*$' -or $entry -isnot [Collections.IDictionary] -or
            $entry['File'] -isnot [bool] -or $entry['Registry'] -isnot [bool] -or
            (-not $entry['File'] -and -not $entry['Registry'])) {
            throw "Invalid desktop font ownership entry '$face' in '$StatePath'."
        }
    }
    $record
}

function Write-DesktopFontRecord {
    param([string]$StatePath, [Collections.IDictionary]$Record)

    $directory = [IO.Path]::GetDirectoryName($StatePath)
    [void][IO.Directory]::CreateDirectory($directory)
    $temporary = Join-Path $directory ([IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $Record -Compress))
        [IO.File]::Move($temporary, $StatePath, $true)
    } finally {
        [IO.File]::Delete($temporary)
    }
}

function Test-DesktopFontFile {
    param([string]$Path)

    $file = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($file -and ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
        throw "Expected a regular desktop font file at '$Path'."
    }
    [bool]$file
}

function Install-DesktopFont {
    param(
        [Parameter(Mandatory)][hashtable]$Manifest,
        [Parameter(Mandatory)][string]$FontDirectory,
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)][string]$StatePath
    )

    $temp = [IO.Directory]::CreateTempSubdirectory('oh-my-devenv-font-').FullName
    try {
        $archivePath = Join-Path $temp 'font.zip'
        Invoke-WebRequest -Uri $Manifest.Url -OutFile $archivePath
        $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
        if ($actualHash -ne $Manifest.Sha256) {
            throw "SHA-256 mismatch for '$($Manifest.Url)': expected $($Manifest.Sha256), got $actualHash."
        }
        $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
        try {
            foreach ($face in $Manifest.Faces) {
                $entries = @($archive.Entries | Where-Object Name -CEQ "$face.ttf")
                if ($entries.Count -ne 1 -or $entries[0].Length -eq 0) {
                    throw "Expected exactly one nonempty '$face.ttf' in '$($Manifest.Url)'."
                }
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], (Join-Path $temp "$face.ttf"))
            }
        } finally {
            $archive.Dispose()
        }

        $record = Read-DesktopFontRecord -StatePath $StatePath
        $null = [IO.Directory]::CreateDirectory($FontDirectory)
        $registry = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($RegistryPath)
        try {
            foreach ($face in $Manifest.Faces) {
                $source = Join-Path $temp "$face.ttf"
                $target = [IO.Path]::GetFullPath((Join-Path $FontDirectory "$face.ttf"))
                $exists = Test-DesktopFontFile -Path $target
                $writeFile = -not $exists -or
                    (Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $target).Hash
                $valueName = "$face (TrueType)"
                $value = $registry.GetValue($valueName, $null, 'DoNotExpandEnvironmentNames')
                $writeValue = $null -eq $value
                $owned = $record[$face] ?? @{ File = $false; Registry = $false }
                if ($writeFile -and $exists -and -not $owned.File) {
                    throw "A different unowned desktop font already exists at '$target'."
                }
                if (-not $writeValue -and ($value -isnot [string] -or $value -ne $target)) {
                    throw "HKCU\$RegistryPath value '$valueName' already points to '$value'. Expected '$target'."
                }
                if (($writeFile -and -not $owned.File) -or ($writeValue -and -not $owned.Registry)) {
                    $record[$face] = @{ File = $owned.File -or $writeFile; Registry = $owned.Registry -or $writeValue }
                    Write-DesktopFontRecord -StatePath $StatePath -Record $record
                }
                if ($writeFile) {
                    $staged = Join-Path $FontDirectory ('.' + [guid]::NewGuid().ToString('N') + '.tmp')
                    try {
                        [IO.File]::Copy($source, $staged)
                        [IO.File]::Move($staged, $target, $exists)
                    } finally {
                        [IO.File]::Delete($staged)
                    }
                }
                if ($writeValue) {
                    $registry.SetValue($valueName, $target, [Microsoft.Win32.RegistryValueKind]::String)
                }
            }
        } finally {
            $registry.Dispose()
        }
        Confirm-DesktopFont -Manifest $Manifest -FontDirectory $FontDirectory -RegistryPath $RegistryPath -StatePath $StatePath
    } finally {
        [IO.Directory]::Delete($temp, $true)
    }
}

function Confirm-DesktopFont {
    param(
        [Parameter(Mandatory)][hashtable]$Manifest,
        [Parameter(Mandatory)][string]$FontDirectory,
        [Parameter(Mandatory)][string]$RegistryPath,
        [string]$StatePath
    )

    if ($StatePath) { $null = Read-DesktopFontRecord -StatePath $StatePath }
    $registry = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RegistryPath)
    try {
        $missing = foreach ($face in $Manifest.Faces) {
            $path = [IO.Path]::GetFullPath((Join-Path $FontDirectory "$face.ttf"))
            if (-not [IO.File]::Exists($path) -or $null -eq $registry -or
                $registry.GetValue("$face (TrueType)") -ne $path) {
                $face
            }
        }
        if ($missing) {
            throw "Missing or unregistered $($Manifest.Family) faces: $($missing -join ', ')."
        }
    } finally {
        if ($null -ne $registry) { $registry.Dispose() }
    }
    Write-Host "$($Manifest.Family) faces are installed and registered."
}

function Get-OwnedDesktopFont {
    param([string]$FontDirectory, [string]$RegistryPath, [string]$StatePath)

    $record = Read-DesktopFontRecord -StatePath $StatePath
    if (-not $record.Count) { return }
    $registry = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RegistryPath)
    try {
        foreach ($face in $record.Keys) {
            $path = [IO.Path]::GetFullPath((Join-Path $FontDirectory "$face.ttf"))
            $name = "$face (TrueType)"
            $value = $null
            if ($registry) { $value = $registry.GetValue($name, $null, 'DoNotExpandEnvironmentNames') }
            [pscustomobject]@{
                Path = $path
                Name = $name
                File = $record[$face].File -and (Test-DesktopFontFile -Path $path)
                Registry = $record[$face].Registry -and $value -is [string] -and $value -eq $path
            }
        }
    } finally {
        if ($null -ne $registry) { $registry.Dispose() }
    }
}

function Remove-OwnedDesktopFont {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The Windows uninstaller gates the change with ShouldProcess.')]
    param([string]$FontDirectory, [string]$RegistryPath, [string]$StatePath)

    $fonts = @(Get-OwnedDesktopFont @PSBoundParameters)
    if ($fonts.Count) {
        $registry = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RegistryPath, $true)
        try {
            foreach ($font in $fonts) {
                if ($font.File) {
                    try {
                        [IO.File]::Delete($font.Path)
                    } catch {
                        throw "Could not remove desktop font '$($font.Path)'. Close applications using the font and retry uninstall. $_"
                    }
                    Write-Host "Removed desktop font '$($font.Path)'."
                }
                $value = $null
                if ($registry) { $value = $registry.GetValue($font.Name, $null, 'DoNotExpandEnvironmentNames') }
                if ($font.Registry -and $value -is [string] -and $value -eq $font.Path) {
                    $registry.DeleteValue($font.Name, $false)
                    Write-Host "Removed HKCU\$RegistryPath value '$($font.Name)'."
                }
            }
        } finally {
            if ($null -ne $registry) { $registry.Dispose() }
        }
    }
    if ([IO.File]::Exists($StatePath)) { [IO.File]::Delete($StatePath) }
}
