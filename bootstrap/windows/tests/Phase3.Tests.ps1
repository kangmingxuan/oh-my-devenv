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
        { Install-SystemPackage -ManifestPath $packagePath } | Should -Throw '*winget.exe*not found on PATH*'
        Should -Invoke Invoke-NativeCommand -Times 0 -Exactly
    }

    It 'preserves a failed import exit code and package diagnostic' {
        Mock Get-PathApplication { @{ Source = 'winget fixture' } }
        Mock Invoke-NativeCommand { @{ ExitCode = 42; Stdout = ''; Stderr = 'Fixture installer blocked' } }
        { Install-SystemPackage -ManifestPath $packagePath } |
            Should -Throw '*source ''winget'' failed (exit 42)*Example.First*Fixture installer blocked*'
        Should -Invoke Invoke-NativeCommand -Times 1 -Exactly -ParameterFilter { $Arguments[0] -eq 'import' }
    }

    It 'reports every absent ID by the WinGet HRESULT' {
        Mock Get-PathApplication { @{ Source = 'winget fixture' } }
        Mock Invoke-NativeCommand { @{ ExitCode = 0x8A150014; Stdout = ''; Stderr = '' } }
        { Confirm-SystemPackage -ManifestPath $packagePath } | Should -Throw '*Missing WinGet packages: Example.First, Example.Second*'
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
        { Confirm-SystemPackage -ManifestPath $packagePath } | Should -Throw '*Missing WinGet packages: Example.Second. Install*'
        $inventory.Sources[0].Packages += @{ PackageIdentifier = 'Example.Second' }
        { Confirm-SystemPackage -ManifestPath $packagePath } | Should -Not -Throw
    }

    It 'reports a source failure with its exit code and diagnostic' {
        Mock Get-PathApplication { @{ Source = 'winget fixture' } }
        Mock Invoke-NativeCommand { @{ ExitCode = 0x8A150012; Stdout = ''; Stderr = 'Fixture source disabled' } }
        { Confirm-SystemPackage -ManifestPath $packagePath } |
            Should -Throw "*could not export installed packages from source 'winget'*Fixture source disabled*"
    }

    It 'reports a missing Visual C++ runtime without attempting installation' {
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*vcruntime140.dll' -and $PathType -eq 'Leaf' }
        Mock Invoke-NativeCommand { throw 'Unexpected native call' }
        $architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
        { Confirm-VisualCppRuntime -PackageIds @('Example.First', 'Example.Second') } |
            Should -Throw "*Example.First, Example.Second*administrator*winget install --id Microsoft.VCRedist.2015+.$architecture --exact*"
        Should -Invoke Test-Path -Times 1 -Exactly -ParameterFilter { $LiteralPath -like '*vcruntime140.dll' }
        Should -Invoke Invoke-NativeCommand -Times 0 -Exactly
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
        { Install-DesktopFont -Manifest $manifest -FontDirectory $fontDirectory -RegistryPath $registryPath } |
            Should -Throw '*SHA-256 mismatch*'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        [IO.Directory]::Exists($fontDirectory) | Should -BeFalse
        if ($IsWindows) {
            [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registryPath) | Should -BeNullOrEmpty
        }
    }

    It 'rejects an archive missing a required face before writing any destination' {
        $manifest.Faces += 'Example-Bold'
        { Install-DesktopFont -Manifest $manifest -FontDirectory $fontDirectory -RegistryPath $registryPath } |
            Should -Throw '*Expected exactly one nonempty*Example-Bold.ttf*'
        [IO.Directory]::Exists($fontDirectory) | Should -BeFalse
    }

    It 'copies the expected bytes, keeps matching files, and detects a missing registration' -Skip:(-not $IsWindows) {
        $options = @{ Manifest = $manifest; FontDirectory = $fontDirectory; RegistryPath = $registryPath }
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
