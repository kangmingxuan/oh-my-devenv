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
    param([string]$HomeDirectory = $HOME)

    $localData = [Environment]::GetFolderPath('LocalApplicationData')
    $expected = Join-Path $HomeDirectory 'AppData/Local'
    if (-not $localData -or (ConvertTo-PathKey -Path $localData) -cne (ConvertTo-PathKey -Path $expected)) {
        throw "Unsupported Windows desktop baseline: LocalAppData resolves to '$localData'. Expected '$expected'."
    }
    if (-not (Test-WindowsTerminal)) {
        throw 'Unsupported Windows desktop baseline: Windows Terminal is required. Install it or make wt.exe (or WindowsTerminal.exe) available on PATH.'
    }
    $localData
}

function Get-DesktopFontTarget {
    param([Parameter(Mandatory)][string]$LocalData)

    @{
        FontDirectory = Join-Path $LocalData 'Microsoft/Windows/Fonts'
        RegistryPath = 'Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    }
}

function Install-DesktopFont {
    param(
        [Parameter(Mandatory)][hashtable]$Manifest,
        [Parameter(Mandatory)][string]$FontDirectory,
        [Parameter(Mandatory)][string]$RegistryPath
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

        $null = [IO.Directory]::CreateDirectory($FontDirectory)
        $registry = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($RegistryPath)
        try {
            foreach ($face in $Manifest.Faces) {
                $source = Join-Path $temp "$face.ttf"
                $target = [IO.Path]::GetFullPath((Join-Path $FontDirectory "$face.ttf"))
                if (-not [IO.File]::Exists($target) -or
                    (Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $target).Hash) {
                    $staged = Join-Path $FontDirectory ('.' + [guid]::NewGuid().ToString('N') + '.tmp')
                    try {
                        [IO.File]::Copy($source, $staged)
                        [IO.File]::Move($staged, $target, $true)
                    } finally {
                        [IO.File]::Delete($staged)
                    }
                }
                $valueName = "$face (TrueType)"
                if ($registry.GetValue($valueName) -ne $target) {
                    $registry.SetValue($valueName, $target, [Microsoft.Win32.RegistryValueKind]::String)
                }
            }
        } finally {
            $registry.Dispose()
        }
        Confirm-DesktopFont -Manifest $Manifest -FontDirectory $FontDirectory -RegistryPath $RegistryPath
    } finally {
        [IO.Directory]::Delete($temp, $true)
    }
}

function Confirm-DesktopFont {
    param(
        [Parameter(Mandatory)][hashtable]$Manifest,
        [Parameter(Mandatory)][string]$FontDirectory,
        [Parameter(Mandatory)][string]$RegistryPath
    )

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
