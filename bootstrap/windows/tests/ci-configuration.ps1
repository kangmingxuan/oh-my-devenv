param([Parameter(Mandatory)][ValidateSet('smoke', 'apply')][string]$Mode)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Run this CI fixture on a disposable GitHub-hosted Windows runner.'
}

$helpers = Split-Path -Parent $PSScriptRoot
. (Join-Path $helpers 'common.ps1')
. (Join-Path $helpers 'backup.ps1')
. (Join-Path $helpers 'profile.ps1')

function Invoke-FixtureChezmoi {
    param([string[]]$Arguments, [switch]$AllowFailure)

    Invoke-NativeCommand -Executable $chezmoi.Source -Arguments ($chezmoiArgs + $Arguments) -AllowFailure:$AllowFailure
}

function Invoke-FixtureApply {
    $result = Invoke-FixtureChezmoi -Arguments @('apply', '--force')
    Write-Host $result.Stdout
    Write-Host $result.Stderr
    if ($result.Stdout -notmatch 'All checks passed\.') {
        throw 'The Windows check did not run or did not pass.'
    }
}

function Set-FixtureText {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal fixture setup runs only on a disposable hosted runner.')]
    param([string]$Path, [string]$Content)

    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Content)
}

function Assert-UnsafeSshAcl {
    param([string]$Path)

    $original = Get-Acl -LiteralPath $Path
    $unsafe = Get-Acl -LiteralPath $Path
    $everyone = [Security.Principal.SecurityIdentifier]::new('S-1-1-0')
    $rule = [Security.AccessControl.FileSystemAccessRule]::new($everyone, 'Write', 'Allow')
    $unsafe.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $unsafe
    try {
        $result = Invoke-NativeCommand -Executable $ssh.Source -Arguments @('-v', '-G', 'oh-my-devenv-check.invalid') -AllowFailure
        if ($result.ExitCode -eq 0 -or $result.Stderr -notmatch 'Bad owner or permissions') {
            throw "SSH did not reject the unsafe ACL on '$Path'. Exit $($result.ExitCode).`n$($result.Stderr)"
        }
        Write-Host "SSH rejected the unsafe ACL on '$Path'."
        Write-Host $result.Stderr
        Assert-FixtureCheckFailure -Pattern 'Bad owner or permissions'
    } finally {
        Set-Acl -LiteralPath $Path -AclObject $original
    }
}

function Assert-FixtureCheckFailure {
    param([string]$Pattern)

    $result = Invoke-NativeCommand -Executable $pwsh -Arguments @(
        '-NoProfile', '-File', (Join-Path $helpers 'check.ps1')
        '-Destination', $destination, '-ProfilePath', $profilePath
    ) -AllowFailure
    if ($result.ExitCode -eq 0 -or ($result.Stderr + $result.Stdout) -notmatch $Pattern) {
        throw "Expected the checker to fail with '$Pattern'.`n$($result.Stderr)`n$($result.Stdout)"
    }
    Write-Host $result.Stderr
}

function Initialize-SmokeStub {
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    $stubSource = Join-Path $fixture 'stub.cs'
    $shimDirectory = Join-Path $fixture 'stub-bin'
    [void][IO.Directory]::CreateDirectory($shimDirectory)
    $shim = Join-Path $shimDirectory 'ssh.exe'
    Set-FixtureText -Path $stubSource -Content @'
using System;
using System.IO;

class Stub
{
    static int Main(string[] args)
    {
        Console.OutputEncoding = System.Text.Encoding.UTF8;
        string program = Path.GetFileNameWithoutExtension(Environment.GetCommandLineArgs()[0]);
        if (program == "mise" && args.Length == 2 && args[0] == "activate" && args[1] == "pwsh")
            return 0;
        if (program != "ssh")
        {
            File.AppendAllText(Environment.GetEnvironmentVariable("OH_MY_DEVENV_TEST_INSTALLERS"), "unexpected installer");
            return 97;
        }
        if (args.Length == 1 && args[0] == "-V")
        {
            Console.Error.WriteLine("OpenSSH fixture");
            return 0;
        }
        if (args.Length != 3 || args[0] != "-v" || args[1] != "-G" || !args[2].EndsWith(".invalid"))
            return 98;
        string config = Path.Combine(Environment.GetEnvironmentVariable("OH_MY_DEVENV_TEST_HOME"), ".ssh", "config");
        Console.Error.WriteLine("debug1: Reading configuration data " + config.Replace("\\", "\\\\"));
        return 0;
    }
}
'@
    $null = Invoke-NativeCommand -Executable $compiler -Arguments @('/nologo', "/out:$shim", $stubSource)
    foreach ($tool in @('winget', 'mise', 'uv')) {
        Copy-Item -LiteralPath $shim -Destination (Join-Path $shimDirectory "$tool.exe")
    }
    $env:PATH = "$shimDirectory;$env:PATH"
    $env:OH_MY_DEVENV_TEST_INSTALLERS = Join-Path $fixture 'unexpected-installers'
    $env:OH_MY_DEVENV_TEST_HOME = $destination
}

$source = [IO.Path]::GetFullPath((Join-Path $helpers '../..'))
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$uninstall = Join-Path $helpers 'uninstall.ps1'
$chezmoi = Get-PathApplication -Name chezmoi
$git = Get-PathApplication -Name git
$fixture = [IO.Directory]::CreateTempSubdirectory('oh-my-devenv-windows-').FullName
$backupRoot = Join-Path $fixture 'backups'
$uninstallBackupRoot = Join-Path $fixture 'uninstall-backups'
$config = Join-Path $fixture 'chezmoi.json'
$fixtureConfig = @{
    data = @{ name = 'Windows CI'; email = 'smoke@example.invalid'; desktopBaseline = $true }
    scriptEnv = @{ OH_MY_DEVENV_WINDOWS_BACKUP_ROOT = $backupRoot }
}
try {
    if ($Mode -eq 'smoke') {
        $destination = Join-Path $fixture "home with spaces [test] and 'quote’"
        $profilePath = Join-Path $fixture 'redirected Documents/PowerShell/profile.ps1'
        $fixtureConfig.scriptEnv.OH_MY_DEVENV_WINDOWS_PROFILE_PATH = $profilePath
        Initialize-SmokeStub
    } else {
        $destination = $HOME
        $profilePath = $PROFILE.CurrentUserAllHosts
        $openSsh = Join-Path $env:WINDIR 'System32/OpenSSH'
        $env:PATH = "$openSsh;$env:PATH"
    }
    $ssh = Get-PathApplication -Name ssh
    if ($Mode -eq 'apply' -and $ssh.Source -ne (Join-Path $openSsh 'ssh.exe')) {
        throw "Expected Windows OpenSSH at '$openSsh'. Resolved '$($ssh.Source)'."
    }
    $chezmoiArgs = @(
        "--source=$source", "--config=$config", "--destination=$destination"
        "--persistent-state=$(Join-Path $fixture 'state.boltdb')"
    )
    $gitConfig = Join-Path $destination '.gitconfig'
    $gitOverlay = Join-Path $destination '.config/oh-my-devenv/git/config'
    $miseConfig = Join-Path $destination '.config/mise/config.toml'
    $profileBody = Join-Path $destination '.config/oh-my-devenv/powershell/profile.ps1'
    $profileEnvironment = Join-Path $destination '.config/oh-my-devenv/powershell/environment.ps1'
    $profileOverlay = Join-Path $destination '.config/oh-my-devenv/powershell/profile.local.ps1'
    $sshConfig = Join-Path $destination '.ssh/config'
    $sshOverlay = Join-Path $destination '.ssh/config.d/oh-my-devenv-fixture.conf'
    $oldMise = "# pre-existing mise fixture`n"
    $oldProfile = "# pre-existing profile fixture`n"
    $overlayContent = '$env:OH_MY_DEVENV_PROFILE_FIXTURE = ''loaded'''
    Set-FixtureText -Path $config -Content ($fixtureConfig | ConvertTo-Json -Depth 4)
    Set-FixtureText -Path $miseConfig -Content $oldMise
    Set-FixtureText -Path $profilePath -Content $oldProfile
    Set-FixtureText -Path $profileOverlay -Content $overlayContent
    Set-FixtureText -Path $gitOverlay -Content "[ohmydevenv]`n    fixture = loaded`n"
    Set-FixtureText -Path $sshOverlay -Content "# local SSH fixture`n"

    Write-Host "PowerShell $($PSVersionTable.PSVersion) at $PSHOME"
    Write-Host "Effective execution policy: $(Get-ExecutionPolicy)"
    Get-ExecutionPolicy -List | Format-Table
    Write-Host (Invoke-FixtureChezmoi -Arguments @('--version')).Stdout
    $pathProbe = 'homeDir={{ .chezmoi.homeDir }}; destDir={{ .chezmoi.destDir }}; joined={{ joinPath .chezmoi.destDir ".config/oh-my-devenv/git/config" }}'
    Write-Host (Invoke-FixtureChezmoi -Arguments @('execute-template', $pathProbe)).Stdout
    Write-Host "CurrentUserAllHosts profile: $profilePath"

    if ($Mode -eq 'smoke') {
        $renderedRoot = Join-Path $fixture 'rendered'
        foreach ($hook in Get-ChildItem -LiteralPath (Join-Path $source '.chezmoiscripts') -Filter '*.ps1.tmpl') {
            $rendered = Invoke-FixtureChezmoi -Arguments @('execute-template', '--file', $hook.FullName)
            Set-FixtureText -Path (Join-Path $renderedRoot $hook.BaseName) -Content $rendered.Stdout
        }
        $settings = Join-Path $helpers 'PSScriptAnalyzer.psd1'
        $findings = @(
            Invoke-ScriptAnalyzer -Settings $settings -Path $helpers -Recurse
            Invoke-ScriptAnalyzer -Settings $settings -Path $renderedRoot -Recurse
            Invoke-ScriptAnalyzer -Settings $settings -Path (Join-Path $source 'dot_config/oh-my-devenv/powershell') -Recurse
        )
        if ($findings.Count) {
            $findings | Format-List
            throw 'PSScriptAnalyzer found problems.'
        }
        Invoke-Pester -Path $PSScriptRoot -Output Detailed -CI

        # The mise file sorts before Git and proves a partial backup cannot authorize deletions.
        $oldGit = "# pre-existing Git fixture`n"
        Set-FixtureText -Path $gitConfig -Content $oldGit
        $originalAcl = Get-Acl -LiteralPath $gitConfig
        $blockedAcl = Get-Acl -LiteralPath $gitConfig
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity.User, 'ReadData', 'Deny')
        } finally {
            $identity.Dispose()
        }
        $blockedAcl.AddAccessRule($rule)
        $uninstallOptions = @{
            Apply = $true; Config = $config; Destination = $destination
            ProfilePath = $profilePath; BackupRoot = $uninstallBackupRoot
        }
        Set-Acl -LiteralPath $gitConfig -AclObject $blockedAcl
        try {
            if ($null -eq (Get-FileAttribute -Path $gitConfig)) {
                throw 'The denied-read fixture must still have readable metadata.'
            }
            try {
                $null = [IO.File]::ReadAllBytes($gitConfig)
                throw 'The fixture ACL did not deny content reads.'
            } catch [UnauthorizedAccessException] {
                Write-Host 'The fixture denies content reads and permits metadata reads.'
            }
            $failed = Invoke-FixtureChezmoi -Arguments @('apply', '--force') -AllowFailure
            if ($failed.ExitCode -eq 0 -or ($failed.Stderr + $failed.Stdout) -notmatch 'Could not back up') {
                throw "Expected a first-run copy error.`n$($failed.Stderr)`n$($failed.Stdout)"
            }
            Write-Host "First-run copy failure stopped apply with exit $($failed.ExitCode)."
            Write-Host $failed.Stderr
            try {
                & $uninstall @uninstallOptions
                throw 'Uninstall should fail when a pre-delete copy fails.'
            } catch {
                if ($_ -notlike '*Pre-uninstall backup failed*Could not back up*') {
                    throw
                }
                Write-Host $_
            }
        } finally {
            Set-Acl -LiteralPath $gitConfig -AclObject $originalAcl
        }
        if ([IO.File]::ReadAllText($miseConfig) -cne $oldMise -or
            [IO.File]::ReadAllText($gitConfig) -cne $oldGit -or
            [IO.File]::ReadAllText($profilePath) -cne $oldProfile -or [IO.File]::Exists($profileBody)) {
            throw 'The failed backups allowed changes to the destination.'
        }
        [IO.Directory]::Move($uninstallBackupRoot, (Join-Path $fixture 'failed-uninstall-backup'))
        & $uninstall @uninstallOptions
        $run = Get-ChildItem -LiteralPath $uninstallBackupRoot -Directory
        $miseCopy = Get-BackupPath -Path $miseConfig -RunDirectory $run.FullName
        $gitCopy = Get-BackupPath -Path $gitConfig -RunDirectory $run.FullName
        if ([IO.File]::ReadAllText($miseCopy) -cne $oldMise -or [IO.File]::ReadAllText($gitCopy) -cne $oldGit -or
            [IO.File]::Exists($miseConfig) -or [IO.File]::Exists($gitConfig)) {
            throw 'Uninstall did not verify a backup and remove the pre-existing configuration.'
        }
        # Re-seed old mise content for the successful first-run backup assertion.
        Set-FixtureText -Path $miseConfig -Content $oldMise
        [IO.Directory]::Move($backupRoot, (Join-Path $fixture 'failed-backup'))
    }

    Invoke-FixtureApply
    foreach ($old in @(@{ Path = $miseConfig; Text = $oldMise }, @{ Path = $profilePath; Text = $oldProfile })) {
        $backupCopies = @(Get-ChildItem -LiteralPath $backupRoot -Directory | ForEach-Object {
            $copy = Get-BackupPath -Path $old.Path -RunDirectory $_.FullName
            if ([IO.File]::Exists($copy) -and [IO.File]::ReadAllText($copy) -ceq $old.Text) {
                $copy
            }
        })
        if ($backupCopies.Count -ne 1) {
            throw "Expected one verified backup of '$($old.Path)'."
        }
    }
    $include = Invoke-NativeCommand -Executable $git.Source -Arguments @(
        'config', '--file', $gitConfig, '--includes', '--show-origin', '--get', 'ohmydevenv.fixture'
    )
    Write-Host "Git include origin and value: $($include.Stdout.Trim())"
    if ($include.Stdout.TrimEnd() -notmatch '\sloaded$') {
        throw 'Git did not load the local include.'
    }

    if ($Mode -eq 'smoke') {
        $installedProfile = [IO.File]::ReadAllText($profilePath)
        Set-FixtureText -Path $profilePath -Content "return`n$installedProfile"
        Assert-FixtureCheckFailure -Pattern 'profile body did not run'
        Set-FixtureText -Path $profilePath -Content $installedProfile
        $installedBody = [IO.File]::ReadAllText($profileBody)
        $originalPath = $env:PATH
        try {
            $env:PATH = (@(Get-ManagedProfilePathEntry) + $originalPath) -join [IO.Path]::PathSeparator
            Set-FixtureText -Path $profileBody -Content '$env:OH_MY_DEVENV_PROFILE_LOADED = ''1'''
            Assert-FixtureCheckFailure -Pattern 'did not add .+ to PATH'
        } finally {
            $env:PATH = $originalPath
            Set-FixtureText -Path $profileBody -Content $installedBody
        }
        Set-FixtureText -Path $profilePath -Content $oldProfile
        Invoke-FixtureApply
        if ([IO.File]::Exists($env:OH_MY_DEVENV_TEST_INSTALLERS)) {
            throw 'A phase-2 hook attempted to install tools.'
        }
        return
    }

    $baselineProfile = [IO.File]::ReadAllText($profilePath)
    $probe = Invoke-NativeCommand -Executable $pwsh -Arguments @(
        '-NoLogo', '-NonInteractive', '-Command', '[Console]::Write($env:OH_MY_DEVENV_PROFILE_FIXTURE)'
    )
    if ($probe.Stdout -cne 'loaded') {
        throw "A new PowerShell process did not load the profile overlay.`n$($probe.Stderr)`n$($probe.Stdout)"
    }

    Invoke-FixtureApply
    if ([IO.File]::ReadAllText($profilePath) -cne $baselineProfile) {
        throw 'Reapply changed the profile.'
    }
    Set-FixtureText -Path $profilePath -Content $oldProfile
    Invoke-FixtureApply
    if ([IO.File]::ReadAllText($profilePath) -cne $baselineProfile) {
        throw 'Reapply did not repair the managed profile line.'
    }

    Assert-UnsafeSshAcl -Path $sshConfig
    Assert-UnsafeSshAcl -Path $sshOverlay

    & $uninstall -Config $config
    if ([IO.File]::ReadAllText($profilePath) -cne $baselineProfile -or -not [IO.File]::Exists($profileBody)) {
        throw 'The uninstall preview changed the destination.'
    }
    & $uninstall -Apply -Config $config -BackupRoot $uninstallBackupRoot
    foreach ($target in @($gitConfig, $miseConfig, $profileBody, $profileEnvironment, $sshConfig)) {
        if ([IO.File]::Exists($target)) {
            throw "Uninstall kept managed target '$target'."
        }
    }
    if ([IO.File]::ReadAllText($profilePath) -cne $oldProfile -or
        [IO.File]::ReadAllText($profileOverlay) -cne $overlayContent -or
        -not [IO.File]::Exists($gitOverlay) -or -not [IO.File]::Exists($sshOverlay) -or
        -not [IO.Directory]::Exists($backupRoot)) {
        throw 'Uninstall changed the user profile content, overlays, or backups.'
    }
    Invoke-FixtureApply
    $status = Invoke-FixtureChezmoi -Arguments @('status', '--exclude=scripts')
    if ($status.Stdout.Trim()) {
        throw "Restored destination has drift.`n$($status.Stdout)"
    }
} finally {
    [IO.Directory]::Delete($fixture, $true)
}
