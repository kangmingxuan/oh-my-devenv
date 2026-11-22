[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester shares BeforeEach variables with the individual tests.')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $helpers = Join-Path $PSScriptRoot '..'
    . (Join-Path $helpers 'common.ps1')
    . (Join-Path $helpers 'system-packages.ps1')
    . (Join-Path $helpers 'desktop.ps1')
    $manifests = Join-Path $helpers '../manifests'
    $fontManifestPath = Join-Path $manifests 'desktop/maple-mono-nf-cn.env'
    $packageManifestPath = Join-Path $manifests 'system/winget-packages.json'
    $desktopPackageManifestPath = Join-Path $manifests 'desktop/winget-packages.json'
}

Describe 'The WinGet layer' {
    BeforeEach {
        $packagePath = Join-Path $TestDrive 'package manifest.json'
        $manifest = @{
            Sources = @(@{
                SourceDetails = (Get-Content -LiteralPath $packageManifestPath -Raw | ConvertFrom-Json -AsHashtable).Sources[0].SourceDetails
                Packages = @(
                    @{ PackageIdentifier = 'Example.First'; Scope = 'user' }
                    @{ PackageIdentifier = 'Example.Second'; Scope = 'user' }
                )
            })
        }
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $packagePath
    }

    It 'reads the source inventory and validates its package contract' {
        @(Read-WinGetPackageManifest -Path $packageManifestPath).Count | Should -BeGreaterThan 0
        @(Read-WinGetPackageManifest -Path $desktopPackageManifestPath).Count | Should -BeGreaterThan 0
    }

    It 'rejects an alternate source' {
        $manifest.Sources[0].SourceDetails.Name = 'other'
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $packagePath
        { Read-WinGetPackageManifest -Path $packagePath } | Should -Throw '*must use only the winget source*'
    }

    It 'rejects a winget source with a mismatched <Field>' -ForEach @(
        @{ Field = 'Type' }
        @{ Field = 'Identifier' }
    ) {
        $manifest.Sources[0].SourceDetails[$Field] = 'Example.Other'
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $packagePath
        { Read-WinGetPackageManifest -Path $packagePath } | Should -Throw '*must use only the winget source*'
    }

    It 'rejects a package that requires machine scope' {
        $manifest.Sources[0].Packages[0].Scope = 'machine'
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $packagePath
        { Read-WinGetPackageManifest -Path $packagePath } | Should -Throw "*Package 'Example.First' must use user scope*"
    }

    It 'reports missing winget without running an installer' {
        Mock Get-PathApplication { $null } -ParameterFilter { $Name -eq 'winget.exe' }
        Mock Invoke-NativeCommand { throw 'Unexpected native call' }
        { Install-WinGetPackage -ManifestPath $packagePath } | Should -Throw '*winget.exe*not found on PATH*'
        Should -Invoke Invoke-NativeCommand -Times 0 -Exactly
    }

    It 'preserves a failed import exit code and package diagnostic' {
        Mock Get-PathApplication { @{ Source = 'winget fixture' } }
        Mock Invoke-NativeCommand { @{ ExitCode = 42; Stdout = ''; Stderr = 'Fixture installer blocked' } }
        { Install-WinGetPackage -ManifestPath $packagePath } |
            Should -Throw '*source ''winget'' failed (exit 42)*Example.First*Fixture installer blocked*'
        Should -Invoke Invoke-NativeCommand -Times 1 -Exactly -ParameterFilter { $Arguments[0] -eq 'import' }
    }

    It 'reports every absent ID by the WinGet HRESULT' {
        Mock Get-PathApplication { @{ Source = 'winget fixture' } }
        Mock Invoke-NativeCommand { @{ ExitCode = 0x8A150014; Stdout = ''; Stderr = '' } }
        { Confirm-WinGetPackage -ManifestPath $packagePath } | Should -Throw '*Missing WinGet packages: Example.First, Example.Second*'
        Should -Invoke Invoke-NativeCommand -Times 1 -Exactly -ParameterFilter {
            $Arguments[0] -eq 'export' -and $Arguments[3] -eq '--source' -and $Arguments[4] -eq 'winget'
        }
    }

    It 'compares complete installed IDs only from the built-in source' {
        $inventory = @{
            Sources = @(
                @{
                    SourceDetails = $manifest.Sources[0].SourceDetails
                    Packages = @(@{ PackageIdentifier = 'Example.First' }, @{ PackageIdentifier = 'Example.SecondPreview' })
                }
                @{
                    SourceDetails = @{ Name = 'winget'; Type = 'Microsoft.PreIndexed.Package'; Identifier = 'Example.Other' }
                    Packages = @(@{ PackageIdentifier = 'Example.Second' })
                }
            )
        }
        Mock Get-PathApplication { @{ Source = 'winget fixture' } }
        Mock Invoke-NativeCommand {
            $inventory | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Arguments[2]
            @{ ExitCode = 0; Stdout = ''; Stderr = '' }
        } -ParameterFilter { $Arguments[0] -eq 'export' }
        { Confirm-WinGetPackage -ManifestPath $packagePath } | Should -Throw '*Missing WinGet packages: Example.Second. Install*'
        $inventory.Sources[0].Packages += @{ PackageIdentifier = 'Example.Second' }
        { Confirm-WinGetPackage -ManifestPath $packagePath } | Should -Not -Throw
    }

    It 'reports a source failure with its exit code and diagnostic' {
        Mock Get-PathApplication { @{ Source = 'winget fixture' } }
        Mock Invoke-NativeCommand { @{ ExitCode = 0x8A150012; Stdout = ''; Stderr = 'Fixture source disabled' } }
        { Confirm-WinGetPackage -ManifestPath $packagePath } |
            Should -Throw "*could not export installed packages from source 'winget'*Fixture source disabled*"
    }

    It 'reports an absent desktop ID when both layers use one inventory export' {
        $desktopPath = Join-Path $TestDrive 'desktop manifest.json'
        $desktop = @{ Sources = @(@{
            SourceDetails = $manifest.Sources[0].SourceDetails
            Packages = @(@{ PackageIdentifier = 'Example.Desktop'; Scope = 'user' })
        }) }
        $desktop | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $desktopPath
        Mock Get-PathApplication { @{ Source = 'winget fixture' } }
        Mock Invoke-NativeCommand {
            Copy-Item -LiteralPath $packagePath -Destination $Arguments[2]
            @{ ExitCode = 0; Stdout = ''; Stderr = '' }
        } -ParameterFilter { $Arguments[0] -eq 'export' }
        { Confirm-WinGetPackage -ManifestPath @($packagePath, $desktopPath) } |
            Should -Throw '*Missing WinGet packages: Example.Desktop. Install*'
        Should -Invoke Invoke-NativeCommand -Times 1 -Exactly
    }
}

Describe 'The shared desktop font manifest' {
    It 'parses the same manifest used by the Unix platforms' {
        $manifest = Read-DesktopFontManifest -Path $fontManifestPath
        $manifest.Family | Should -Not -BeNullOrEmpty
        $manifest.Faces.Count | Should -BeGreaterThan 0
        $manifest.Url.Scheme | Should -BeExactly 'https'
        $manifest.Sha256 | Should -Match '^[a-f0-9]{64}$'
    }

    It 'reports a missing manifest' {
        { Read-DesktopFontManifest -Path (Join-Path $TestDrive 'missing.env') } | Should -Throw '*not found*'
    }

    # Keep these cases in sync with the shared font manifest cases in run-smoke-tests.sh.
    It 'rejects <assignment>' -ForEach @(
        @{ Assignment = 'MAPLE_MONO_FAMILY='; Pattern = '*does not define MAPLE_MONO_FAMILY*' }
        @{ Assignment = 'MAPLE_MONO_FAMILY="Bad; Family"'; Pattern = '*must contain only letters, digits, spaces, and hyphens*' }
        @{ Assignment = 'MAPLE_MONO_POSTSCRIPT_NAMES="Good-Face bad.face"'; Pattern = '*invalid PostScript name*' }
        @{ Assignment = 'MAPLE_MONO_SHA256=ABC'; Pattern = '*not a lowercase SHA-256 digest*' }
    ) {
        $path = Join-Path $TestDrive 'invalid.env'
        $key = ($assignment -split '=', 2)[0]
        $lines = Get-Content -LiteralPath $fontManifestPath | Where-Object { $_ -cnotmatch "^$key=" }
        ($lines + $assignment) | Set-Content -LiteralPath $path
        { Read-DesktopFontManifest -Path $path } | Should -Throw $pattern
    }

    It 'rejects multiple assignments for the same key' {
        $path = Join-Path $TestDrive 'duplicate.env'
        $lines = Get-Content -LiteralPath $fontManifestPath
        ($lines + 'MAPLE_MONO_FAMILY="Fixture"') | Set-Content -LiteralPath $path
        { Read-DesktopFontManifest -Path $path } | Should -Throw '*Duplicate assignment*MAPLE_MONO_FAMILY*'
    }
}

Describe 'The Windows desktop layer' {
    BeforeEach {
        $caseRoot = [IO.Directory]::CreateDirectory((Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))).FullName
        $fontDirectory = Join-Path $caseRoot 'fonts [fixture]'
        $statePath = Join-Path $caseRoot 'fonts.json'
        $registryPath = "Software\oh-my-devenv-tests\$([guid]::NewGuid().ToString('N'))"
        $sourceDirectory = [IO.Directory]::CreateDirectory((Join-Path $caseRoot 'zip input')).FullName
        $fontBytes = [byte[]](0, 255, 3, 27)
        [IO.File]::WriteAllBytes((Join-Path $sourceDirectory 'Example-Regular.ttf'), $fontBytes)
        $archive = Join-Path $caseRoot 'fixture.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($sourceDirectory, $archive, 'Fastest', $true)
        $manifest = @{
            Family = 'Example Font'
            Faces = @('Example-Regular')
            Url = [uri]'https://example.invalid/font.zip'
            Sha256 = (Get-FileHash -LiteralPath $archive).Hash
        }
        Mock Invoke-WebRequest { [IO.File]::Copy($archive, $OutFile) }
    }

    AfterEach {
        if ($IsWindows) {
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($registryPath, $false)
        }
    }

    It 'stops on redirected LocalAppData before checking Windows Terminal' {
        Mock Test-WindowsTerminal { throw 'Unexpected Terminal check' }
        { Get-DesktopLocalData -Destination $TestDrive } | Should -Throw '*Unsupported*LocalAppData resolves to*'
        Should -Invoke Test-WindowsTerminal -Times 0 -Exactly
    }

    It 'reports an unavailable Windows Terminal at the standard LocalAppData path' -Skip:(-not $IsWindows) {
        $localData = [Environment]::GetFolderPath('LocalApplicationData')
        $destination = Split-Path -Parent (Split-Path -Parent $localData)
        Mock Test-WindowsTerminal { $false }
        { Get-DesktopLocalData -Destination $destination } | Should -Throw '*Unsupported*Windows Terminal is required*'
    }

    It 'rejects a digest mismatch before opening the archive or writing any destination' {
        $manifest.Sha256 = '0' * 64
        { Install-DesktopFont -Manifest $manifest -FontDirectory $fontDirectory -RegistryPath $registryPath -StatePath $statePath } |
            Should -Throw '*SHA-256 mismatch*'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        [IO.Directory]::Exists($fontDirectory) | Should -BeFalse
        if ($IsWindows) {
            [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registryPath) | Should -BeNullOrEmpty
        }
    }

    It 'rejects an archive missing a required face before writing any destination' {
        $manifest.Faces += 'Example-Bold'
        { Install-DesktopFont -Manifest $manifest -FontDirectory $fontDirectory -RegistryPath $registryPath -StatePath $statePath } |
            Should -Throw '*Expected exactly one nonempty*Example-Bold.ttf*'
        [IO.Directory]::Exists($fontDirectory) | Should -BeFalse
    }

    It 'copies the expected bytes, keeps matching files, and detects a missing registration' -Skip:(-not $IsWindows) {
        $options = @{ Manifest = $manifest; FontDirectory = $fontDirectory; RegistryPath = $registryPath; StatePath = $statePath }
        Install-DesktopFont @options
        $installed = Join-Path $fontDirectory 'Example-Regular.ttf'
        [Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes($installed), $fontBytes) | Should -BeTrue
        [IO.File]::SetLastWriteTimeUtc($installed, [datetime]'2020-08-13T12:00:00Z')
        $time = [IO.File]::GetLastWriteTimeUtc($installed)
        Install-DesktopFont @options
        [IO.File]::GetLastWriteTimeUtc($installed) | Should -Be $time
        $registry = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registryPath, $true)
        try {
            $registry.GetValue('Example-Regular (TrueType)') | Should -BeExactly $installed
            $registry.DeleteValue('Example-Regular (TrueType)')
            { Confirm-DesktopFont @options } | Should -Throw '*Missing or unregistered Example Font faces: Example-Regular*'
        } finally {
            $registry.Dispose()
        }
        Install-DesktopFont @options
        [IO.File]::GetLastWriteTimeUtc($installed) | Should -Be $time
    }

    It 'keeps an existing matching file and registration out of the ownership record' -Skip:(-not $IsWindows) {
        [void][IO.Directory]::CreateDirectory($fontDirectory)
        $file = Join-Path $fontDirectory 'Example-Regular.ttf'
        [IO.File]::WriteAllBytes($file, $fontBytes)
        $registry = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registryPath)
        try {
            $registry.SetValue('Example-Regular (TrueType)', $file, 'String')
            $target = @{ FontDirectory = $fontDirectory; RegistryPath = $registryPath; StatePath = $statePath }
            Install-DesktopFont -Manifest $manifest @target
            [IO.File]::Exists($statePath) | Should -BeFalse
            Remove-OwnedDesktopFont @target
            [Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes($file), $fontBytes) | Should -BeTrue
            $registry.GetValue('Example-Regular (TrueType)') | Should -BeExactly $file
        } finally { $registry.Dispose() }
    }

    It 'records newly created registrations for pre-existing matching font files' -Skip:(-not $IsWindows) {
        [void][IO.Directory]::CreateDirectory($fontDirectory)
        $file = Join-Path $fontDirectory 'Example-Regular.ttf'
        [IO.File]::WriteAllBytes($file, $fontBytes)
        $target = @{ FontDirectory = $fontDirectory; RegistryPath = $registryPath; StatePath = $statePath }
        Install-DesktopFont -Manifest $manifest @target
        $record = Read-DesktopFontRecord -StatePath $statePath
        $record['Example-Regular'].File | Should -BeFalse
        $record['Example-Regular'].Registry | Should -BeTrue
        Remove-OwnedDesktopFont @target
        [Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes($file), $fontBytes) | Should -BeTrue
        $registry = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registryPath)
        try { $registry.GetValue('Example-Regular (TrueType)') | Should -BeNullOrEmpty }
        finally { $registry.Dispose() }
        [IO.File]::Exists($statePath) | Should -BeFalse
    }

    It 'removes a recorded file and keeps a registry value that now points elsewhere' -Skip:(-not $IsWindows) {
        $target = @{ FontDirectory = $fontDirectory; RegistryPath = $registryPath; StatePath = $statePath }
        Install-DesktopFont -Manifest $manifest @target
        $record = Read-DesktopFontRecord -StatePath $statePath
        $record['Example-Regular'].File | Should -BeTrue
        $record['Example-Regular'].Registry | Should -BeTrue
        $registry = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registryPath, $true)
        try {
            $registry.SetValue('Example-Regular (TrueType)', 'another-font.ttf', 'String')
            Remove-OwnedDesktopFont @target
            $registry.GetValue('Example-Regular (TrueType)') | Should -BeExactly 'another-font.ttf'
        } finally { $registry.Dispose() }
        [IO.File]::Exists((Join-Path $fontDirectory 'Example-Regular.ttf')) | Should -BeFalse
        [IO.File]::Exists($statePath) | Should -BeFalse
    }

    It 'writes ownership before changing font bytes or the registry value' -Skip:(-not $IsWindows) {
        $target = @{ FontDirectory = $fontDirectory; RegistryPath = $registryPath; StatePath = $statePath }
        Mock Write-DesktopFontRecord { throw 'Fixture cannot write ownership' }
        { Install-DesktopFont -Manifest $manifest @target } | Should -Throw '*Fixture cannot write ownership*'
        [IO.File]::Exists((Join-Path $fontDirectory 'Example-Regular.ttf')) | Should -BeFalse
        $registry = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registryPath)
        try { $registry.GetValue('Example-Regular (TrueType)') | Should -BeNullOrEmpty }
        finally { $registry.Dispose() }
    }

    It 'keeps ownership when a font is in use and succeeds after closing it' -Skip:(-not $IsWindows) {
        $target = @{ FontDirectory = $fontDirectory; RegistryPath = $registryPath; StatePath = $statePath }
        Install-DesktopFont -Manifest $manifest @target
        $file = Join-Path $fontDirectory 'Example-Regular.ttf'
        $recordBytes = [IO.File]::ReadAllBytes($statePath)
        $locked = [IO.File]::Open($file, 'Open', 'Read', 'Read')
        try {
            { Remove-OwnedDesktopFont @target } | Should -Throw '*Close applications using the font and retry uninstall*'
            [Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes($statePath), $recordBytes) | Should -BeTrue
        } finally { $locked.Dispose() }
        Remove-OwnedDesktopFont @target
        [IO.File]::Exists($file) | Should -BeFalse
        [IO.File]::Exists($statePath) | Should -BeFalse
    }
}

Describe 'The deployed Windows Terminal fragment' {
    BeforeEach {
        $fragment = Join-Path $TestDrive 'desktop.json'
        $profiles = @(@{ updates = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'; font = @{ face = 'Example Font' } })
    }

    It 'accepts the PowerShell profile update with the manifest family' {
        @{ profiles = $profiles } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $fragment
        { Confirm-TerminalFragment -Path $fragment -Family 'Example Font' } | Should -Not -Throw
    }

    It 'rejects a fragment with invalid JSON that still contains the family' {
        '{ "profiles": [ { "font": { "face": "Example Font" } }' | Set-Content -LiteralPath $fragment
        { Confirm-TerminalFragment -Path $fragment -Family 'Example Font' } | Should -Throw '*Invalid JSON*Windows Terminal fragment*'
    }

    It 'rejects a profile without an update target' {
        $profiles[0].Remove('updates')
        @{ profiles = $profiles } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $fragment
        { Confirm-TerminalFragment -Path $fragment -Family 'Example Font' } | Should -Throw '*must update the PowerShell 7 profile*'
    }

    It 'rejects a different font family' {
        @{ profiles = $profiles } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $fragment
        { Confirm-TerminalFragment -Path $fragment -Family 'Different Font' } | Should -Throw '*must set*Different Font*'
    }
}
