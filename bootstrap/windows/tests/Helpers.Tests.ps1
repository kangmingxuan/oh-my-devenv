[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester shares BeforeEach variables with the individual tests.')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $helpers = Join-Path $PSScriptRoot '..'
    . (Join-Path $helpers 'common.ps1')
    . (Join-Path $helpers 'backup.ps1')
    . (Join-Path $helpers 'profile.ps1')
    . (Join-Path $helpers 'local-overlays.ps1')
}

Describe 'First-run backup' {
    It 'maps local paths with spaces, Unicode, and literal brackets on both drives' {
        $first = Get-BackupPath -Path 'C:/Users/é 中/[test]/.gitconfig' -RunDirectory $TestDrive
        $second = Get-BackupPath -Path 'd:\Users\é 中\[test]\.gitconfig' -RunDirectory $TestDrive
        $first | Should -BeExactly (Join-Path $TestDrive 'drives/C/Users/é 中/[test]/.gitconfig')
        $second | Should -BeExactly (Join-Path $TestDrive 'drives/D/Users/é 中/[test]/.gitconfig')
    }

    It 'rejects <path>' -ForEach @(
        @{ Path = 'C:/../escape' }
        @{ Path = 'C:/x/./file' }
        @{ Path = 'C:drive-relative' }
        @{ Path = '//server/share/config' }
        @{ Path = '\\?\C:\users\config' }
        @{ Path = 'C:/x/aux.txt' }
        @{ Path = 'C:/x/file:stream' }
        @{ Path = 'C:/x//file' }
    ) {
        { Get-BackupPath -Path $path -RunDirectory $TestDrive } | Should -Throw
    }

    It 'copies literal regular files and preserves their last-write time' {
        $source = Join-Path $TestDrive '[source].txt'
        $destination = Join-Path $TestDrive 'new/[copy].txt'
        [IO.File]::WriteAllText($source, 'original')
        [IO.File]::SetLastWriteTimeUtc($source, [datetime]'2020-08-13T12:00:00Z')
        Copy-VerifiedFile -Source $source -Destination $destination
        [IO.File]::ReadAllText($destination) | Should -BeExactly 'original'
        [IO.File]::GetLastWriteTimeUtc($destination) | Should -Be ([IO.File]::GetLastWriteTimeUtc($source))
        { Copy-VerifiedFile -Source $source -Destination $destination } | Should -Throw '*already exists*'
    }

    It 'fails when the backup directory cannot be written' {
        $source = Join-Path $TestDrive 'existing-file'
        [IO.File]::WriteAllText($source, 'original')
        { Copy-VerifiedFile -Source $source -Destination (Join-Path $source 'child') } |
            Should -Throw '*Could not back up*'
    }

    It 'propagates metadata access failures instead of skipping the file' {
        Mock Get-FileAttribute { throw [UnauthorizedAccessException]::new('Fixture denied read') }
        { Backup-ExistingFile -Paths @('C:/existing') -BackupRoot $TestDrive } |
            Should -Throw '*Fixture denied read*'
    }

    It 'allocates a distinct run directory for each backup' {
        $root = Join-Path $TestDrive 'backups [literal]'
        $first = New-BackupRun -BackupRoot $root
        $second = New-BackupRun -BackupRoot $root
        $first | Should -Not -Be $second
        [IO.Directory]::Exists($first) | Should -BeTrue
        [IO.Directory]::Exists($second) | Should -BeTrue
    }

    It 'rejects a run directory collision' {
        $date = Get-Date -AsUTC
        $guid = New-Guid
        Mock Get-Date { $date }
        Mock New-Guid { $guid }
        $root = Join-Path $TestDrive 'collision'
        $null = New-BackupRun -BackupRoot $root
        { New-BackupRun -BackupRoot $root } | Should -Throw
    }

    It 'copies a file link, skips a dangling link, and rejects a directory link' -Skip:(-not $IsWindows) {
        $real = Join-Path $TestDrive 'file'
        $link = Join-Path $TestDrive '[link]'
        $dangling = Join-Path $TestDrive 'dangling'
        $directoryLink = Join-Path $TestDrive 'directory-link'
        $root = Join-Path $TestDrive 'backups'
        [IO.File]::WriteAllText($real, 'target')
        $null = [IO.File]::CreateSymbolicLink($link, $real)
        $null = [IO.File]::CreateSymbolicLink($dangling, (Join-Path $TestDrive 'missing'))
        $empty = [IO.Directory]::CreateTempSubdirectory('oh-my-devenv-link-target-').FullName
        try {
            $null = [IO.Directory]::CreateSymbolicLink($directoryLink, $empty)
            Backup-ExistingFile -Paths @($link, $dangling) -BackupRoot $root
            $run = Get-ChildItem -LiteralPath $root -Directory
            $copy = Get-BackupPath -Path $link -RunDirectory $run.FullName
            [IO.File]::ReadAllText($copy) | Should -BeExactly 'target'
            [IO.FileInfo]::new($copy).LinkTarget | Should -BeNullOrEmpty
            (Get-BackupPath -Path $dangling -RunDirectory $run.FullName) | Should -Not -Exist
            { Backup-ExistingFile -Paths @($directoryLink) -BackupRoot $root } | Should -Throw '*found a directory*'
        } finally {
            if ([IO.Directory]::Exists($directoryLink)) {
                [IO.Directory]::Delete($directoryLink)
            }
            [IO.Directory]::Delete($empty)
        }
    }

    It 'does not create a run directory without existing files' -Skip:(-not $IsWindows) {
        $root = Join-Path $TestDrive 'empty-backups'
        Backup-ExistingFile -Paths @() -BackupRoot $root
        Backup-ExistingFile -Paths @((Join-Path $TestDrive 'missing')) -BackupRoot $root
        $root | Should -Not -Exist
    }
}

Describe 'Application and SSH diagnostics' {
    It 'uses the first application on PATH and executes it' {
        $first = [IO.Directory]::CreateDirectory((Join-Path $TestDrive 'first')).FullName
        $second = [IO.Directory]::CreateDirectory((Join-Path $TestDrive 'second')).FullName
        $name = 'oh-my-devenv-test-command'
        if ($IsWindows) {
            $firstFile = Join-Path $first "$name.exe"
            $secondFile = Join-Path $second "$name.exe"
            $system = Join-Path $env:WINDIR 'System32'
            [IO.File]::Copy((Join-Path $system 'cmd.exe'), $firstFile)
            [IO.File]::Copy((Join-Path $system 'whoami.exe'), $secondFile)
            $arguments = @('/d', '/c', 'echo first')
        } else {
            $firstFile = Join-Path $first $name
            $secondFile = Join-Path $second $name
            [IO.File]::WriteAllText($firstFile, "#!/bin/sh`necho first`n")
            [IO.File]::WriteAllText($secondFile, "#!/bin/sh`necho second`n")
            $mode = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserExecute
            [IO.File]::SetUnixFileMode($firstFile, $mode)
            [IO.File]::SetUnixFileMode($secondFile, $mode)
            $arguments = @('test')
        }
        $originalPath = $env:PATH
        try {
            $env:PATH = ($first, $second, $originalPath) -join [IO.Path]::PathSeparator
            (Get-PathApplication -Name $name).Source | Should -BeExactly $firstFile
            $result = Invoke-NativeCommand -Executable (Get-PathApplication -Name $name).Source -Arguments $arguments
            $result.Stdout.Trim() | Should -BeExactly 'first'
            $env:PATH = ($second, $first, $originalPath) -join [IO.Path]::PathSeparator
            (Get-PathApplication -Name $name).Source | Should -BeExactly $secondFile
        } finally {
            $env:PATH = $originalPath
        }
    }

    It 'matches the doubled-backslash diagnostic and rejects another user path' {
        $diagnostic = 'debug1: Reading configuration data c:\\USERS\\Alice/.ssh/config'
        Test-SshConfigRead -Diagnostic $diagnostic -Path 'C:/Users/alice/.ssh/config' | Should -BeTrue
        Test-SshConfigRead -Diagnostic $diagnostic -Path 'C:/Users/other/.ssh/config' | Should -BeFalse
    }
}

Describe 'Uninstall platform boundary' {
    It 'rejects Unix before trying to list targets' -Skip:$IsWindows {
        $uninstall = Join-Path $helpers 'uninstall.ps1'
        $result = Invoke-NativeCommand -Executable (Join-Path $PSHOME 'pwsh') -Arguments @(
            '-NoProfile', '-File', $uninstall, '-Apply', '-Destination', $TestDrive
        ) -AllowFailure -TimeoutSeconds 30
        $result.ExitCode | Should -Be 1
        $result.Stderr | Should -Match 'requires a Windows host'
    }
}

Describe 'Verified profile replacement' {
    It 'preserves an edit made after the profile was read' {
        $path = Join-Path $TestDrive 'edited.ps1'
        $backup = Join-Path $TestDrive 'edited-backup.ps1'
        [IO.File]::WriteAllText($path, 'concurrent edit')
        $original = [Text.Encoding]::UTF8.GetBytes('original')
        $replacement = [Text.Encoding]::UTF8.GetBytes('replacement')
        { Write-ProfileReplacement -Path $path -Original $original -Bytes $replacement -BackupPath $backup } |
            Should -Throw '*original profile changed*'
        [IO.File]::ReadAllText($path) | Should -BeExactly 'concurrent edit'
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '.oh-my-devenv-*.tmp' -Force).Count | Should -Be 0
    }

    It 'leaves the profile intact when staging cannot create the sibling file' {
        $path = Join-Path $TestDrive 'locked.ps1'
        $backup = Join-Path $TestDrive 'locked-backup.ps1'
        [IO.File]::WriteAllText($path, 'original')
        $original = [IO.File]::ReadAllBytes($path)
        $replacement = [Text.Encoding]::UTF8.GetBytes('replacement')
        $guid = New-Guid
        Mock New-Guid { $guid }
        $stagingPath = Join-Path $TestDrive ".oh-my-devenv-$guid.tmp"
        [IO.File]::WriteAllText($stagingPath, 'occupied')
        { Write-ProfileReplacement -Path $path -Original $original -Bytes $replacement -BackupPath $backup } |
            Should -Throw
        [IO.File]::ReadAllText($path) | Should -BeExactly 'original'
        [IO.File]::ReadAllText($stagingPath) | Should -BeExactly 'occupied'
    }

    It 'retains the staged profile and reports recovery paths if replacement fails' -Skip:(-not $IsWindows) {
        $path = Join-Path $TestDrive 'replace-failure.ps1'
        $backup = Join-Path $TestDrive 'replace-failure-backup.ps1'
        $original = [Text.Encoding]::UTF8.GetBytes('original')
        $replacement = [Text.Encoding]::UTF8.GetBytes('replacement')
        [IO.File]::WriteAllBytes($path, $original)
        [IO.File]::WriteAllBytes($backup, $original)
        $guid = New-Guid
        Mock New-Guid { $guid }
        $staged = Join-Path $TestDrive ".oh-my-devenv-$guid.tmp"

        # Let the verification read the profile but deny the delete access File.Replace needs.
        $reader = [IO.File]::Open($path, 'Open', 'Read', 'Read')
        try {
            { Write-ProfileReplacement -Path $path -Original $original -Bytes $replacement -BackupPath $backup } |
                Should -Throw "*profile '$path'. Staged profile: '$staged'. Pre-uninstall backup: '$backup'.*"
        } finally {
            $reader.Dispose()
        }
        [IO.File]::ReadAllText($staged) | Should -BeExactly 'replacement'
        [IO.File]::ReadAllText($backup) | Should -BeExactly 'original'
    }
}

Describe 'Go binary directory' {
    It 'uses the first Windows GOPATH entry when GOBIN is unset' {
        $first = Join-Path $TestDrive 'first Go workspace'
        $second = Join-Path $TestDrive 'second Go workspace'
        $originalGoPath = $env:GOPATH
        $originalGoBin = $env:GOBIN
        try {
            $env:GOPATH = ($first, $second) -join ';'
            $env:GOBIN = $null
            Get-DefaultGoBin | Should -BeExactly (Join-Path $first 'bin')
        } finally {
            $env:GOPATH = $originalGoPath
            $env:GOBIN = $originalGoBin
        }
    }
}

Describe 'Fresh profile probe' {
    It 'rejects <statement> before reaching the managed line' -ForEach @(
        @{ Statement = 'return'; Expected = '*did not run to completion*' }
        @{ Statement = '[Environment]::Exit(0)'; Expected = '*did not report the profile probe success marker*' }
    ) {
        Mock Get-ProfileProbePath { $env:PATH }
        $profilePath = Join-Path $TestDrive 'return-early.ps1'
        $body = Join-Path $TestDrive '.config/oh-my-devenv/powershell/profile.ps1'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $body))
        [IO.File]::WriteAllText($body, "throw 'The fixture profile body ran.'")
        $line = Get-ManagedProfileLine -Destination $TestDrive
        [IO.File]::WriteAllText($profilePath, "$statement`n$line`n")
        { Confirm-ManagedProfile -ProfilePath $profilePath -Destination $TestDrive } | Should -Throw $expected

        [IO.File]::WriteAllText($profilePath, "$line`n")
        { Confirm-ManagedProfile -ProfilePath $profilePath -Destination $TestDrive } | Should -Throw '*fixture profile body ran*'
    }

    It 'builds the probe Path from persistent entries without inheriting the hook process Path' {
        $processOnly = Join-Path $TestDrive 'process-only'
        $fixtureBin = Join-Path $TestDrive 'probe-bin'
        $separator = [IO.Path]::PathSeparator
        $persistent = @(
            [Environment]::GetEnvironmentVariable('Path', 'Machine')
            [Environment]::GetEnvironmentVariable('Path', 'User')
        ) -split $separator | Where-Object { $_ }
        $expected = @($persistent | Select-Object -Unique)
        if ($expected.Count) {
            $managed = $expected[0]
            Mock Get-ManagedProfilePathEntry { $managed.ToUpperInvariant() }
            $managedKey = ConvertTo-PathKey -Path $managed
            $expected = @($expected | Where-Object { (ConvertTo-PathKey -Path $_) -cne $managedKey })
        } else {
            Mock Get-ManagedProfilePathEntry {}
        }
        $originalPath = $env:PATH
        try {
            $env:PATH = $processOnly
            Get-ProfileProbePath | Should -BeExactly ($expected -join $separator)
            Get-ProfileProbePath -FixtureBin $fixtureBin |
                Should -BeExactly ((@($fixtureBin) + $expected) -join $separator)
        } finally {
            $env:PATH = $originalPath
        }
    }

    It 'restores managed entries when mise activation removes them and no overlay exists' {
        $body = Join-Path $TestDrive 'profile.ps1'
        $source = Join-Path $PSScriptRoot '../../../dot_config/oh-my-devenv/powershell/profile.ps1'
        [IO.File]::Copy($source, $body, $true)
        [IO.File]::WriteAllText((Join-Path $TestDrive 'environment.ps1'), @'
function Get-ManagedProfilePathEntry { 'fixture-shims'; 'fixture-local-bin'; 'fixture-go-bin' }
function Get-DefaultGoBin { 'fixture-go-bin' }
function ConvertTo-PathKey { param([string]$Path) $Path.ToUpperInvariant() }
function Get-PathApplication {
    param([string]$Name, [switch]$Optional)
    if ($Name -eq 'mise') { @{ Source = Join-Path $PSScriptRoot 'mise.ps1' } }
}
'@)
        [IO.File]::WriteAllText((Join-Path $TestDrive 'mise.ps1'), @'
$global:LASTEXITCODE = 0
'$env:PATH = "activation-left-this-entry"'
'@)
        $runner = Join-Path $TestDrive 'run-profile.ps1'
        [IO.File]::WriteAllText($runner, @'
. (Join-Path $PSScriptRoot 'profile.ps1')
[Console]::Write($env:PATH)
'@)
        $pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
        $result = Invoke-NativeCommand -Executable $pwsh -Arguments @('-NoProfile', '-File', $runner)
        $result.Stdout | Should -BeExactly 'fixture-shims;fixture-local-bin;fixture-go-bin;activation-left-this-entry'
    }

    It 'applies the profile PSReadLine settings only when PSReadLine is loaded' -ForEach @(
        @{ Import = $true }
        @{ Import = $false }
    ) {
        $source = Join-Path $PSScriptRoot '../../../dot_config/oh-my-devenv/powershell/profile.ps1'
        # Read the configured values from the profile so the test follows configuration changes.
        $ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $source), [ref]$null, [ref]$null)
        $commands = $ast.FindAll({ $args[0] -is [Management.Automation.Language.CommandAst] }, $true)
        $argument = {
            param([string]$Command, [string]$Parameter)
            $elements = @($commands | Where-Object { $_.GetCommandName() -eq $Command } |
                Select-Object -First 1 -ExpandProperty CommandElements)
            for ($i = 0; $i -lt $elements.Count - 1; $i++) {
                if ($elements[$i] -is [Management.Automation.Language.CommandParameterAst] -and
                    $elements[$i].ParameterName -eq $Parameter) {
                    return $elements[$i + 1].Extent.Text
                }
            }
        }
        $editMode = & $argument 'Set-PSReadLineOption' 'EditMode'
        $chord = & $argument 'Set-PSReadLineKeyHandler' 'Chord'
        $function = & $argument 'Set-PSReadLineKeyHandler' 'Function'
        $editMode | Should -Not -BeNullOrEmpty
        $chord | Should -Not -BeNullOrEmpty
        $function | Should -Not -BeNullOrEmpty
        # Start from another edit mode so the assertion holds whatever the host default is.
        $startMode = if ($editMode -eq 'Windows') { 'Emacs' } else { 'Windows' }
        $expected = if ($Import) { "loaded $editMode $function" } else { 'not-loaded' }

        $body = Join-Path $TestDrive 'profile.ps1'
        [IO.File]::Copy($source, $body, $true)
        [IO.File]::WriteAllText((Join-Path $TestDrive 'environment.ps1'), @'
function Get-ManagedProfilePathEntry {}
function Get-DefaultGoBin { 'fixture-go-bin' }
function ConvertTo-PathKey { param([string]$Path) $Path.ToUpperInvariant() }
function Get-PathApplication { param([string]$Name, [switch]$Optional) }
'@)
        $runner = Join-Path $TestDrive 'run-psreadline-profile.ps1'
        $importLine = if ($Import) { "Import-Module PSReadLine; Set-PSReadLineOption -EditMode $startMode" } else { '' }
        [IO.File]::WriteAllText($runner, @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
$importLine
. (Join-Path `$PSScriptRoot 'profile.ps1')
if (Get-Module -Name PSReadLine) {
    [Console]::Write("loaded `$((Get-PSReadLineOption).EditMode) `$((Get-PSReadLineKeyHandler -Chord '$chord').Function)")
} else {
    [Console]::Write('not-loaded')
}
"@)
        $pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
        $result = Invoke-NativeCommand -Executable $pwsh -Arguments @('-NoProfile', '-File', $runner)
        $result.Stdout | Should -BeExactly $expected
    }

    It 'rejects a function that shadows the expected application when invoked by its bare name' {
        $probe = Join-Path $PSScriptRoot '../profile-probe.ps1'
        $fixtureProfile = Join-Path $TestDrive 'shadowing-profile.ps1'
        [IO.File]::WriteAllText($fixtureProfile, @'
. $env:OH_MY_DEVENV_TEST_PROFILE_ENV
$env:PATH = (@(Get-ManagedProfilePathEntry) + $PSHOME) -join [IO.Path]::PathSeparator
$env:OH_MY_DEVENV_PROFILE_LOADED = '1'
$env:OH_MY_DEVENV_POSH_CONFIG = 'fixture-theme'
function pwsh { 'shadowed' }
'@)
        $binary = if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' }
        $pwsh = Join-Path $PSHOME $binary
        $environment = @{
            OH_MY_DEVENV_TEST_PROFILE_ENV = Join-Path $PSScriptRoot '../../../dot_config/oh-my-devenv/powershell/environment.ps1'
            OH_MY_DEVENV_PROBE_COMMANDS = ConvertTo-Json -InputObject @(@{ Name = $binary; Path = $pwsh }) -Compress
        }
        {
            Invoke-NativeCommand -Executable $pwsh -Arguments @(
                '-NoProfile', '-File', $probe, '-SuccessMarker', 'fixture-success',
                '-ExpectedPoshConfig', 'fixture-theme', '-FixtureProfilePath', $fixtureProfile
            ) -Environment $environment
        } | Should -Throw "*'pwsh'*Function*"
    }

    It 'collects machine PATH entries absent from the process and user PATH' -Skip:(-not $IsWindows) {
        $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';'
        $user = [Environment]::GetEnvironmentVariable('Path', 'User') -split ';'
        $machineOnly = @($machine | Where-Object { $_ -and $_ -notin $user })
        $machineOnly.Count | Should -BeGreaterThan 0

        $originalPath = $env:PATH
        try {
            $env:PATH = $TestDrive
            $collected = @(Get-HookPath)
            foreach ($entry in $machineOnly) {
                $collected | Should -Contain $entry
            }
        } finally {
            $env:PATH = $originalPath
        }
    }
}

Describe 'Managed file listing' {
    BeforeEach {
        $listing = @{
            Executable = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
            Config = Join-Path $TestDrive 'test.toml'
            Source = $TestDrive
            Destination = $TestDrive
        }
    }

    It 'uses the caller arguments, requests plain output, ignores stderr, and deletes private state' {
        Mock Invoke-NativeCommand {
            $Arguments[0] | Should -BeExactly "--config=$($listing.Config)"
            $Arguments[1] | Should -BeExactly "--source=$($listing.Source)"
            $Arguments[2] | Should -BeExactly "--destination=$($listing.Destination)"
            $Arguments | Should -Contain '--format='
            $state = $Arguments[3] -replace '^--persistent-state=', ''
            $script:listingStateParent = Split-Path -Parent $state
            $script:listingStateParent | Should -Exist
            @{ Stdout = "C:/Users/é [smoke]/file`r`n"; Stderr = 'not a path'; ExitCode = 0 }
        }
        @(Get-ManagedFile @listing) | Should -Be @('C:/Users/é [smoke]/file')
        $script:listingStateParent | Should -Not -Exist
    }

    It 'handles an empty listing' {
        Mock Invoke-NativeCommand { @{ Stdout = ''; Stderr = 'status'; ExitCode = 0 } }
        @(Get-ManagedFile @listing).Count | Should -Be 0
    }

    It 'propagates listing errors and cleans up private state' {
        Mock Invoke-NativeCommand {
            $script:listingStateParent = Split-Path -Parent ($Arguments[3] -replace '^--persistent-state=', '')
            throw 'fixture failed with exit 42'
        }
        { Get-ManagedFile @listing } | Should -Throw '*fixture failed with exit 42*'
        $script:listingStateParent | Should -Not -Exist
    }

    It 'separates native stdout and stderr and checks the exit status' {
        $process = @{
            Executable = $listing.Executable
            Arguments = @('-NoProfile', '-Command', "[Console]::Out.Write('file'); [Console]::Error.Write('error'); exit 42")
        }
        $result = Invoke-NativeCommand @process -AllowFailure
        $result.Stdout | Should -BeExactly 'file'
        $result.Stderr | Should -BeExactly 'error'
        $result.ExitCode | Should -Be 42
        { Invoke-NativeCommand @process } | Should -Throw '*code 42*'
    }

    It 'reports a native child timeout' {
        $arguments = @('-NoProfile', '-Command', 'Start-Sleep -Seconds 10')
        { Invoke-NativeCommand -Executable $listing.Executable -Arguments $arguments -TimeoutSeconds 1 } |
            Should -Throw '*did not finish within 1 seconds*'
    }
}

Describe 'Profile line' {
    BeforeEach {
        $profileFile = Join-Path $TestDrive 'redirected Documents/profile.ps1'
        $settings = @{
            ProfilePath = $profileFile
            Destination = Join-Path $TestDrive "home with ’ and ' apostrophes [test]"
            BackupRoot = Join-Path $TestDrive 'backups'
        }
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $profileFile))
        [IO.File]::Delete($profileFile)

        # The backup mapper has separate native drive tests.
        Mock New-BackupRun { $TestDrive }
        Mock Get-BackupPath { Join-Path $TestDrive 'backup.ps1' }
        [IO.File]::Delete((Join-Path $TestDrive 'backup.ps1'))
    }

    It 'creates a missing profile and the line can run with a missing body' {
        Add-ManagedProfileLine @settings
        $line = Get-ManagedProfileLine -Destination $settings.Destination
        [IO.File]::ReadAllText($profileFile).TrimEnd() | Should -BeExactly $line
        { & ([scriptblock]::Create($line)) } | Should -Not -Throw
    }

    It 'safely quotes literal Windows paths in the dot-source line' {
        $body = Join-Path $settings.Destination '.config/oh-my-devenv/powershell/profile.ps1'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $body))
        [IO.File]::WriteAllText($body, "'loaded'")
        $line = Get-ManagedProfileLine -Destination $settings.Destination
        & ([scriptblock]::Create($line)) | Should -BeExactly 'loaded'
        [IO.File]::Delete($body)
    }

    It 'keeps original bytes and removes only the line for <name>' -ForEach @(
        @{ Name = 'UTF-8'; Encoding = [Text.UTF8Encoding]::new($false); Ending = '' }
        @{ Name = 'UTF-8 BOM'; Encoding = [Text.UTF8Encoding]::new($true); Ending = "`r`n" }
        @{ Name = 'UTF-16 LE'; Encoding = [Text.UnicodeEncoding]::new($false, $true); Ending = "`n" }
        @{ Name = 'UTF-16 BE'; Encoding = [Text.UnicodeEncoding]::new($true, $true); Ending = "`r" }
    ) {
        $initial = $encoding.GetPreamble() + $encoding.GetBytes("# café 中$ending")
        [IO.File]::WriteAllBytes($profileFile, $initial)
        Add-ManagedProfileLine @settings
        $backup = [IO.File]::ReadAllBytes((Join-Path $TestDrive 'backup.ps1'))
        [Convert]::ToHexString($backup) | Should -BeExactly ([Convert]::ToHexString($initial))
        $after = [IO.File]::ReadAllBytes($profileFile)
        [Convert]::ToHexString($after, 0, $initial.Length) | Should -BeExactly ([Convert]::ToHexString($initial))

        Add-ManagedProfileLine @settings
        [Convert]::ToHexString([IO.File]::ReadAllBytes($profileFile)) | Should -BeExactly ([Convert]::ToHexString($after))
        Remove-ManagedProfileLine -ProfilePath $profileFile -Destination $settings.Destination `
            -BackupPath (Join-Path $TestDrive 'backup.ps1')
        $kept = "# café 中$ending"
        if (-not $ending) {
            $kept += [Environment]::NewLine
        }
        $expected = $encoding.GetPreamble() + $encoding.GetBytes($kept)
        [Convert]::ToHexString([IO.File]::ReadAllBytes($profileFile)) | Should -BeExactly ([Convert]::ToHexString($expected))
    }

    It 'fails on invalid UTF-8 without changing bytes' {
        [IO.File]::WriteAllBytes($profileFile, [byte[]]@(0xc3, 0x28))
        { Add-ManagedProfileLine @settings } | Should -Throw '*Invalid profile encoding*'
        [Convert]::ToHexString([IO.File]::ReadAllBytes($profileFile)) | Should -BeExactly 'C328'
    }

    It 'leaves the profile untouched when its backup fails' {
        [IO.File]::WriteAllText($profileFile, '# existing')
        Mock Copy-VerifiedFile { throw 'Fixture copy error' }
        { Add-ManagedProfileLine @settings } | Should -Throw '*Fixture copy error*'
        [IO.File]::ReadAllText($profileFile) | Should -BeExactly '# existing'
    }

    It 'reports the backup and preserves original content when append fails' -Skip:(-not $IsWindows) {
        [IO.File]::WriteAllText($profileFile, '# existing')
        $lock = [IO.File]::Open($profileFile, 'Open', 'Read', 'Read')
        try {
            { Add-ManagedProfileLine @settings } | Should -Throw '*Pre-edit backup*'
            [IO.File]::ReadAllText((Join-Path $TestDrive 'backup.ps1')) | Should -BeExactly '# existing'
        } finally {
            $lock.Dispose()
        }
        [IO.File]::ReadAllText($profileFile) | Should -BeExactly '# existing'
    }
}

Describe 'Shared local overlay manifest' {
    BeforeEach {
        $manifest = Join-Path $TestDrive 'local-overlays.tsv'
    }

    It 'reads the canonical manifest' {
        $canonical = Join-Path $PSScriptRoot '../../manifests/local-overlays.tsv'
        $overlays = @(Read-LocalOverlay -Manifest $canonical)
        $overlays.Count | Should -BeGreaterThan 0
        foreach ($overlay in $overlays) {
            $fixturePath = ($overlay.Location -creplace '^\$HOME/', '' -creplace '^\$XDG_CONFIG_HOME/', '.config/').Replace('*', 'smoke')
            Test-LocalOverlay -RelativePath $fixturePath -Overlays $overlays | Should -BeTrue
        }
    }

    It 'rejects a missing manifest' {
        { Read-LocalOverlay -Manifest (Join-Path $TestDrive 'missing.tsv') } | Should -Throw
    }

    It 'rejects an invalid match type' {
        [IO.File]::WriteAllText($manifest, ('broken', 'broken.example', '$HOME/.broken', 'invalid' -join "`t"))
        { Read-LocalOverlay -Manifest $manifest } | Should -Throw '*Invalid overlay*'
    }

    It 'rejects duplicate IDs, examples, and locations' -ForEach @(
        @{ Row = @('first', 'second.example', '$HOME/.second', 'exact') }
        @{ Row = @('second', 'first.example', '$HOME/.second', 'exact') }
        @{ Row = @('second', 'second.example', '$HOME/.first', 'exact') }
    ) {
        $first = 'first', 'first.example', '$HOME/.first', 'exact' -join "`t"
        [IO.File]::WriteAllLines($manifest, @($first, ($row -join "`t")))
        { Read-LocalOverlay -Manifest $manifest } | Should -Throw '*Duplicate overlay*'
    }

    It 'releases the manifest for immediate rewrite after successful and failed parsing' {
        $row = 'first', 'first.example', '$HOME/.first', 'exact' -join "`t"
        [IO.File]::WriteAllLines($manifest, @($row))
        @(Read-LocalOverlay -Manifest $manifest).Count | Should -Be 1
        [IO.File]::WriteAllLines($manifest, @($row, $row))
        { Read-LocalOverlay -Manifest $manifest } | Should -Throw '*Duplicate overlay*'

        # Request exclusive access so a leaked reader also fails this test on Unix.
        $writer = [IO.File]::Open($manifest, 'Open', 'Write', 'None')
        $writer.Dispose()
        [IO.File]::WriteAllLines($manifest, @($row))
        @(Read-LocalOverlay -Manifest $manifest).Count | Should -Be 1
    }
}
