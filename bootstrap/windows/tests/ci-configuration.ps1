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
    } finally {
        Set-Acl -LiteralPath $Path -AclObject $original
    }
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
        if (Path.GetFileNameWithoutExtension(Environment.GetCommandLineArgs()[0]) != "ssh")
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
        Console.Error.WriteLine("debug1: Reading configuration data " +
            Path.Combine(Environment.GetEnvironmentVariable("OH_MY_DEVENV_TEST_HOME"), ".ssh", "config"));
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
$chezmoi = Get-Command -Name chezmoi -CommandType Application -ErrorAction Stop
$git = Get-Command -Name git -CommandType Application -ErrorAction Stop
$fixture = [IO.Directory]::CreateTempSubdirectory('oh-my-devenv-windows-').FullName
$backupRoot = Join-Path $fixture 'backups'
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
    $ssh = Get-Command -Name ssh -CommandType Application -ErrorAction Stop
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
            Invoke-ScriptAnalyzer -Settings $settings -Path (Join-Path $source 'dot_config/oh-my-devenv/powershell/profile.ps1')
        )
        if ($findings.Count) {
            $findings | Format-List
            throw 'PSScriptAnalyzer found problems.'
        }
        Invoke-Pester -Path $PSScriptRoot -Output Detailed -CI

        $blockedRoot = Join-Path $fixture 'blocked-backup-root'
        Set-FixtureText -Path $blockedRoot -Content 'regular file'
        $fixtureConfig.scriptEnv.OH_MY_DEVENV_WINDOWS_BACKUP_ROOT = $blockedRoot
        Set-FixtureText -Path $config -Content ($fixtureConfig | ConvertTo-Json -Depth 4)
        $failed = Invoke-FixtureChezmoi -Arguments @('apply', '--force') -AllowFailure
        if ($failed.ExitCode -eq 0 -or ($failed.Stderr + $failed.Stdout) -notmatch 'First-run backup failed') {
            throw "Expected a first-run backup error.`n$($failed.Stderr)`n$($failed.Stdout)"
        }
        if ([IO.File]::ReadAllText($miseConfig) -cne $oldMise -or [IO.File]::Exists($gitConfig)) {
            throw 'The failed first-run backup allowed changes to the destination.'
        }
        Write-Host "First-run backup failure stopped apply with exit $($failed.ExitCode)."
        $fixtureConfig.scriptEnv.OH_MY_DEVENV_WINDOWS_BACKUP_ROOT = $backupRoot
        Set-FixtureText -Path $config -Content ($fixtureConfig | ConvertTo-Json -Depth 4)
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
        Set-FixtureText -Path $profilePath -Content $oldProfile
        Invoke-FixtureApply
        if ([IO.File]::Exists($env:OH_MY_DEVENV_TEST_INSTALLERS)) {
            throw 'A phase-2 hook attempted to install tools.'
        }
        return
    }

    $baselineProfile = [IO.File]::ReadAllText($profilePath)
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
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

    $uninstall = Join-Path $helpers 'uninstall.ps1'
    & $uninstall -Config $config
    if ([IO.File]::ReadAllText($profilePath) -cne $baselineProfile -or -not [IO.File]::Exists($profileBody)) {
        throw 'The uninstall preview changed the destination.'
    }
    & $uninstall -Apply -Config $config
    foreach ($target in @($gitConfig, $miseConfig, $profileBody, $sshConfig)) {
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
