[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester shares fixture variables with the individual tests.')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Windows phase 4 helpers' -Skip:(-not $IsWindows) {
    BeforeAll {
        $helpers = Join-Path $PSScriptRoot '..'
        . (Join-Path $helpers 'common.ps1')
        . (Join-Path $helpers 'system-packages.ps1')
        . (Join-Path $helpers 'user-path.ps1')
        . (Join-Path $helpers 'mise.ps1')
        . (Join-Path $helpers 'ecosystem.ps1')
        . (Join-Path $helpers 'install-go-tools.ps1')
        . (Join-Path $helpers 'install-uv-tools.ps1')
    }

    Context 'Shared manifest parsing' {
        BeforeEach {
            $manifest = Join-Path $TestDrive 'tools.txt'
        }

        It 'omits blank lines and comments and preserves remaining entry text' {
            [IO.File]::WriteAllText($manifest, "# comment`r`n`t `r`nalpha # inline`r`nbeta`r`n")
            @(Read-EcosystemManifest -Path $manifest) | Should -BeExactly @('alpha ', 'beta')
        }

        It 'reads Go <Spec> as <Name> at <Version>' -ForEach @(
            @{ Spec = 'example.com/foo/v2@v2.1.0'; Name = 'foo'; Version = 'v2.1.0' }
            @{ Spec = 'example.com/foo/v12@v12.1.0'; Name = 'foo'; Version = 'v12.1.0' }
            @{ Spec = 'example.com/foo/cmd/tool@v1.2.3'; Name = 'tool'; Version = 'v1.2.3' }
            @{ Spec = 'example.com/foo/v1@v1.2.3'; Name = 'v1'; Version = 'v1.2.3' }
            @{ Spec = 'example.com/foo/v2tool@v1.2.3'; Name = 'v2tool'; Version = 'v1.2.3' }
            @{ Spec = 'example.com/tool@v1.2.3-rc.1'; Name = 'tool'; Version = 'v1.2.3-rc.1' }
            @{ Spec = 'example.com/tool@v0.0.0-20240101000000-abcdef123456'; Name = 'tool'; Version = 'v0.0.0-20240101000000-abcdef123456' }
        ) {
            [IO.File]::WriteAllText($manifest, $Spec)
            $tool = Read-GoToolManifest -Path $manifest
            $tool.Name | Should -BeExactly $Name
            $tool.Version | Should -BeExactly $Version
        }

        It 'rejects a Go entry that is not pinned: <_>' -ForEach @(
            'example.com/tool@latest', 'example.com/tool', 'example.com/tool@v1.2', 'example.com/tool@1.2.3'
        ) {
            [IO.File]::WriteAllText($manifest, $_)
            { Read-GoToolManifest -Path $manifest } | Should -Throw '*must pin an exact module version*'
        }

        It 'reads literal uv extras, exact pins and other requirement forms' {
            [IO.File]::WriteAllLines($manifest, @('some-tool[extra]==1.2.3', 'other-tool>=2', 'direct-tool @ https://example.invalid/direct.whl'))
            $tools = @(Read-UvToolManifest -Path $manifest)
            $tools.Name | Should -BeExactly @('some-tool', 'other-tool', 'direct-tool')
            $tools[0].Version | Should -BeExactly '1.2.3'
            $tools[1].Version | Should -BeNullOrEmpty
            $tools[2].Version | Should -BeNullOrEmpty
        }

        It 'derives a name for every shared entry' {
            $root = Join-Path $helpers '../manifests/ecosystem'
            foreach ($tool in Read-GoToolManifest -Path (Join-Path $root 'go-tools.txt')) {
                $tool.Name | Should -Not -BeNullOrEmpty
            }
            foreach ($tool in Read-UvToolManifest -Path (Join-Path $root 'uv-tools.txt')) {
                $tool.Name | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'WinGet mise bootstrap' {
        BeforeEach {
            Mock Get-PathApplication { @{ Source = 'mise.exe' } }
            Mock Get-WinGetApplication { @{ Source = 'winget.exe' } }
            Mock Update-HookPath {}
            Mock Invoke-NativeCommand { @{ ExitCode = 0; Stdout = 'fixture'; Stderr = '' } }
        }

        It 'uses an existing mise without invoking WinGet' {
            Install-Mise
            Should -Invoke Get-WinGetApplication -Times 0 -Exactly
            Should -Invoke Invoke-NativeCommand -Times 1 -Exactly -ParameterFilter {
                $Executable -eq 'mise.exe' -and ($Arguments -join ' ') -ceq '--version' -and
                $WorkingDirectory -eq "$env:SystemDrive\"
            }
        }

        It 'installs per user and refreshes PATH before validating mise' {
            Mock Get-PathApplication {} -ParameterFilter { $Optional }
            Install-Mise
            Should -Invoke Invoke-NativeCommand -Times 1 -Exactly -ParameterFilter {
                $Executable -eq 'winget.exe' -and ($Arguments -join ' ') -ceq
                    'install --id jdx.mise --exact --source winget --scope user --accept-package-agreements --accept-source-agreements --disable-interactivity'
            }
            Should -Invoke Update-HookPath -Times 1 -Exactly -ParameterFilter { $Managed }
            Should -Invoke Invoke-NativeCommand -Times 1 -Exactly -ParameterFilter { $Executable -eq 'mise.exe' }
        }

        It 'stops on a WinGet install failure' {
            Mock Get-PathApplication {} -ParameterFilter { $Optional }
            Mock Invoke-NativeCommand { @{ ExitCode = 42; Stdout = ''; Stderr = 'blocked by fixture policy' } } -ParameterFilter {
                $Executable -eq 'winget.exe'
            }
            { Install-Mise } | Should -Throw '*jdx.mise failed (exit 42)*blocked by fixture policy*'
            Should -Invoke Update-HookPath -Times 0 -Exactly
            Should -Invoke Invoke-NativeCommand -Times 0 -Exactly -ParameterFilter { $Executable -eq 'mise.exe' }
        }

        It 'rejects missing mise tools based on stdout' {
            Mock Invoke-NativeCommand { @{ Stdout = 'fixture-tool 1.2.3'; Stderr = '' } } -ParameterFilter {
                $Arguments[0] -eq 'ls'
            }
            { Confirm-MiseToolchain } | Should -Throw '*Missing mise tools*fixture-tool 1.2.3*'
        }
    }

    Context 'Ecosystem installer decisions' {
        BeforeEach {
            $manifest = Join-Path $TestDrive 'tools.txt'
            $venv = Join-Path $TestDrive 'fixture/Scripts'
            [void][IO.Directory]::CreateDirectory($venv)
            [IO.File]::WriteAllText((Join-Path $venv '../pyvenv.cfg'), "version_info = 3.13.4`n")
            $oldForce = $env:DOTFILES_FORCE_REINSTALL
            $oldGoBin = $env:GOBIN
            $env:DOTFILES_FORCE_REINSTALL = $null
            $env:GOBIN = Join-Path $TestDrive 'go-bin'
            Mock Get-MiseToolExecutable { "managed-$Name.exe" }
            Mock Invoke-NativeCommand {
                $stdout = switch ($Arguments -join ' ') {
                    'tool list' { "fixture v1.2.3`n- fixture" }
                    'tool dir' { $TestDrive }
                    default { '' }
                }
                @{ ExitCode = 0; Stdout = $stdout; Stderr = '' }
            }
            Mock Invoke-NativeCommand {
                @{ ExitCode = 0; Stdout = "3.13.4`n"; Stderr = '' }
            } -ParameterFilter { $Executable -like '*python.exe' }
        }

        AfterEach {
            $env:DOTFILES_FORCE_REINSTALL = $oldForce
            $env:GOBIN = $oldGoBin
        }

        It 'rebuilds all Go entries on each installer invocation' {
            [IO.File]::WriteAllLines($manifest, @('example.com/first@v1.2.3', 'example.com/second@v2.3.4'))
            Install-GoTool -ManifestPath $manifest
            Install-GoTool -ManifestPath $manifest
            Should -Invoke Invoke-NativeCommand -Times 4 -Exactly -ParameterFilter {
                $Executable -eq 'managed-go.exe' -and $Arguments[0] -eq 'install'
            }
        }

        It 'validates the entire Go manifest before installing any entry' {
            [IO.File]::WriteAllLines($manifest, @('example.com/first@v1.2.3', 'example.com/second@latest'))
            { Install-GoTool -ManifestPath $manifest } | Should -Throw '*must pin an exact module version*'
            Should -Invoke Invoke-NativeCommand -Times 0 -Exactly
        }

        It 'skips an exact uv pin on the selected Python' {
            [IO.File]::WriteAllText($manifest, 'fixture==1.2.3')
            Install-UvTool -ManifestPath $manifest
            Should -Invoke Invoke-NativeCommand -Times 1 -Exactly -ParameterFilter {
                $Executable -like '*fixture*Scripts*python.exe'
            }
            Should -Invoke Invoke-NativeCommand -Times 0 -Exactly -ParameterFilter { $Arguments[1] -in 'install', 'uninstall' }
        }

        It 'rebuilds the uv environment if it was <Reason>' -ForEach @(
            @{ Reason = 'forced' }, @{ Reason = 'built on another Python' }, @{ Reason = 'missing its interpreter' }
        ) {
            [IO.File]::WriteAllText($manifest, 'fixture==1.2.3')
            if ($Reason -eq 'forced') {
                $env:DOTFILES_FORCE_REINSTALL = '1'
            } elseif ($Reason -eq 'built on another Python') {
                [IO.File]::WriteAllText((Join-Path $TestDrive 'fixture/pyvenv.cfg'), "version_info = 3.12.8`n")
            } else {
                Mock Invoke-NativeCommand { throw 'fixture interpreter missing' } -ParameterFilter { $Executable -like '*Scripts*python.exe' }
            }
            Install-UvTool -ManifestPath $manifest
            Should -Invoke Invoke-NativeCommand -Times 1 -Exactly -ParameterFilter {
                ($Arguments -join ' ') -ceq 'tool uninstall fixture'
            }
            Should -Invoke Invoke-NativeCommand -Times 1 -Exactly -ParameterFilter {
                ($Arguments -join ' ') -ceq 'tool install --python managed-python.exe fixture==1.2.3'
            }
        }

        It 'uses normal uv install for a different pin without uninstalling a healthy environment' {
            [IO.File]::WriteAllText($manifest, 'fixture==2.0.0')
            Install-UvTool -ManifestPath $manifest
            Should -Invoke Invoke-NativeCommand -Times 0 -Exactly -ParameterFilter { $Arguments[1] -eq 'uninstall' }
            Should -Invoke Invoke-NativeCommand -Times 1 -Exactly -ParameterFilter {
                ($Arguments -join ' ') -ceq 'tool install --python managed-python.exe fixture==2.0.0'
            }
        }
    }

    Context 'Persistent user Path ownership' {
        BeforeEach {
            $state = Join-Path $TestDrive 'config/user-path.json'
            if ([IO.File]::Exists($state)) { [IO.File]::Delete($state) }
            $registry = "Software\oh-my-devenv-test-$([Guid]::NewGuid())"
            $target = @{ RegistryPath = $registry; StatePath = $state }
            $entries = @('C:\Example\mise\shims', 'C:\Example\local\bin', 'C:\Example\go\bin')
            Mock Send-UserPathChange {}
        }

        AfterEach {
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($registry, $false)
        }

        It 'retains unexpanded data and type, prevents duplicates, and removes only recorded entries' {
            $oldFixture = $env:OH_MY_DEVENV_PATH_TEST_HOME
            $env:OH_MY_DEVENV_PATH_TEST_HOME = 'c:\EXAMPLE'
            try {
                $original = '%OH_MY_DEVENV_PATH_TEST_HOME%/local/bin/;C:\other;C:\other;'
                $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registry)
                try { $key.SetValue('Path', $original, 'ExpandString') }
                finally { $key.Dispose() }

                Add-ManagedUserPath @target -Entries ($entries + $entries[0].ToUpperInvariant())
                $after = Read-UserPath -RegistryPath $registry
                $after.Kind | Should -Be 'ExpandString'
                $after.Value | Should -BeExactly "$original;$($entries[0]);$($entries[2])"
                @(Read-UserPathRecord -StatePath $state) | Should -BeExactly @($entries[0], $entries[2])
                @(Get-MissingUserPathEntry -PathValue $after -Entries $entries).Count | Should -Be 0
                $bytes = [IO.File]::ReadAllBytes($state)
                Add-ManagedUserPath @target -Entries $entries
                [Linq.Enumerable]::SequenceEqual[byte]($bytes, [IO.File]::ReadAllBytes($state)) | Should -BeTrue
                (Read-UserPath -RegistryPath $registry).Value | Should -BeExactly $after.Value
                (Get-UserPathRemoval @target).Entries | Should -BeExactly @($entries[0], $entries[2])
                Remove-ManagedUserPath @target
                $final = Read-UserPath -RegistryPath $registry
                $final.Value | Should -BeExactly $original
                $final.Kind | Should -Be 'ExpandString'
                [IO.File]::Exists($state) | Should -BeFalse
                Should -Invoke Send-UserPathChange -Times 2 -Exactly
            } finally {
                $env:OH_MY_DEVENV_PATH_TEST_HOME = $oldFixture
            }
        }

        It 'handles <State> Path and retains the type of an existing empty value' -ForEach @(
            @{ State = 'absent'; InitialType = $null; FinalType = 'ExpandString' }
            @{ State = 'empty'; InitialType = 'String'; FinalType = 'String' }
        ) {
            if ($InitialType) {
                $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registry)
                try { $key.SetValue('Path', '', $InitialType) }
                finally { $key.Dispose() }
            }
            (Read-UserPath -RegistryPath $registry).Kind | Should -Be $InitialType
            Add-ManagedUserPath @target -Entries $entries
            $after = Read-UserPath -RegistryPath $registry
            $after.Value | Should -BeExactly ($entries -join ';')
            $after.Kind | Should -Be $FinalType
            Remove-ManagedUserPath @target
            $final = Read-UserPath -RegistryPath $registry
            ($final.Value -ceq '') | Should -BeTrue
            $final.Kind | Should -Be $FinalType
        }

        It 'does not write a record or notify when all entries pre-exist' {
            $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registry)
            try { $key.SetValue('Path', ($entries -join ';'), 'String') }
            finally { $key.Dispose() }
            Add-ManagedUserPath @target -Entries $entries
            Remove-ManagedUserPath @target
            [IO.File]::Exists($state) | Should -BeFalse
            (Read-UserPath -RegistryPath $registry).Value | Should -BeExactly ($entries -join ';')
            Should -Invoke Send-UserPathChange -Times 0 -Exactly
        }
    }
}
