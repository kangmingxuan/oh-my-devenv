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
        { & $uninstall -Apply -Destination $TestDrive } | Should -Throw '*requires a Windows host*'
    }
}

Describe 'Verified profile replacement' {
    It 'preserves an edit made after the profile was read' {
        $path = Join-Path $TestDrive 'edited.ps1'
        [IO.File]::WriteAllText($path, 'concurrent edit')
        $original = [Text.Encoding]::UTF8.GetBytes('original')
        $replacement = [Text.Encoding]::UTF8.GetBytes('replacement')
        { Write-ProfileReplacement -Path $path -Original $original -Bytes $replacement } |
            Should -Throw '*original profile changed*'
        [IO.File]::ReadAllText($path) | Should -BeExactly 'concurrent edit'
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '.oh-my-devenv-*.tmp' -Force).Count | Should -Be 0
    }

    It 'leaves the profile intact when staging cannot create the sibling file' {
        $path = Join-Path $TestDrive 'locked.ps1'
        [IO.File]::WriteAllText($path, 'original')
        $original = [IO.File]::ReadAllBytes($path)
        $replacement = [Text.Encoding]::UTF8.GetBytes('replacement')
        $guid = New-Guid
        Mock New-Guid { $guid }
        $stagingPath = Join-Path $TestDrive ".oh-my-devenv-$guid.tmp"
        [IO.File]::WriteAllText($stagingPath, 'occupied')
        { Write-ProfileReplacement -Path $path -Original $original -Bytes $replacement } | Should -Throw
        [IO.File]::ReadAllText($path) | Should -BeExactly 'original'
        [IO.File]::ReadAllText($stagingPath) | Should -BeExactly 'occupied'
    }
}

Describe 'Fresh profile probe' {
    It 'rejects a profile that returns before reaching its managed line' {
        Mock Get-ProfileProbePath { $env:PATH }
        $profilePath = Join-Path $TestDrive 'return-early.ps1'
        $line = Get-ManagedProfileLine -Destination $TestDrive
        [IO.File]::WriteAllText($profilePath, "return`n$line`n")
        { Confirm-ManagedProfile -ProfilePath $profilePath } | Should -Throw '*did not run to completion*'
    }

    It 'strips every equivalent managed entry from the merged process and machine PATH' {
        Mock Get-ManagedProfilePathEntry { 'C:/Users/Example/.local/bin' }
        Mock Get-HookPath { @('C:/Users/Example/.local/bin', 'C:/Windows', 'c:\USERS\EXAMPLE\.local\bin\') }
        Get-ProfileProbePath | Should -BeExactly 'C:/Windows'
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
        Remove-ManagedProfileLine -ProfilePath $profileFile -Destination $settings.Destination
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
}
