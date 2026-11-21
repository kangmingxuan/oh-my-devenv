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
. (Join-Path $helpers 'system-packages.ps1')
. (Join-Path $helpers 'desktop.ps1')

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

    try {
        & (Join-Path $helpers 'check.ps1') -Destination $destination -ProfilePath $profilePath `
            -DesktopBaseline:$fixtureConfig.data.desktopBaseline
    } catch {
        # Native stderr is part of the exception message before PowerShell formats it.
        $diagnostic = $_.Exception.Message
        if ($diagnostic -notmatch $Pattern) {
            throw "Expected the checker to fail with '$Pattern'.`n$diagnostic"
        }
        Write-Host $diagnostic
        return
    }
    throw "Expected the checker to fail with '$Pattern', but it succeeded."
}

function Initialize-FixtureStub {
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    $stubSource = Join-Path $fixture 'stub.cs'
    $shimDirectory = Join-Path $fixture 'stub-bin'
    [void][IO.Directory]::CreateDirectory($shimDirectory)
    $shim = Join-Path $fixture 'stub.exe'
    Set-FixtureText -Path $stubSource -Content @'
using System;
using System.IO;

class Stub
{
    static int Main(string[] args)
    {
        Console.OutputEncoding = System.Text.Encoding.UTF8;
        string program = Path.GetFileNameWithoutExtension(Environment.GetCommandLineArgs()[0]);
        if (program == "winget")
        {
            string action = null;
            if (args.Length == 7 && args[0] == "import" && args[1] == "--import-file" &&
                File.Exists(args[2]) && args[3] == "--no-upgrade" && args[4] == "--accept-package-agreements" &&
                args[5] == "--accept-source-agreements" && args[6] == "--disable-interactivity")
                action = "import";
            if (args.Length == 7 && args[0] == "export" && args[1] == "--output" &&
                args[3] == "--source" && args[4] == "winget" && args[5] == "--accept-source-agreements" &&
                args[6] == "--disable-interactivity")
            {
                File.Copy(Environment.GetEnvironmentVariable("OH_MY_DEVENV_TEST_WINGET_MANIFEST"), args[2]);
                action = "export";
            }
            if (action == null)
                return 96;
            File.AppendAllText(Environment.GetEnvironmentVariable("OH_MY_DEVENV_TEST_WINGET_LOG"), action + "\n");
            Console.WriteLine("WinGet fixture: " + action);
            return 0;
        }
        if (program == "mise" && args.Length == 2 && args[0] == "activate" && args[1] == "pwsh")
            return 0;
        if (program == "oh-my-posh")
        {
            if (args.Length != 4 || args[0] != "init" || args[1] != "pwsh" ||
                args[2] != "--config" || !File.Exists(args[3]))
                return 95;
            string configPath = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(args[3]));
            Console.WriteLine("$env:POSH_CONFIG = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + configPath + "'))");
            Console.WriteLine("$env:POSH_SESSION_ID = 'fixture'");
            Console.WriteLine("function prompt { 'Oh My Posh fixture> ' }");
            return 0;
        }
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
    foreach ($tool in @('ssh', 'mise', 'uv', 'winget', 'oh-my-posh')) {
        Copy-Item -LiteralPath $shim -Destination (Join-Path $shimDirectory "$tool.exe")
    }
    $env:OH_MY_DEVENV_TEST_INSTALLERS = Join-Path $fixture 'unexpected-installers'
    $env:OH_MY_DEVENV_TEST_HOME = $destination
    $env:OH_MY_DEVENV_TEST_WINGET_LOG = Join-Path $fixture 'winget.log'
    $env:OH_MY_DEVENV_TEST_WINGET_MANIFEST = $packageManifestPath
    $env:PATH = "$shimDirectory;$env:PATH"
}

function Assert-FixtureWinGet {
    $calls = Get-Content -LiteralPath $env:OH_MY_DEVENV_TEST_WINGET_LOG
    if (@($calls -ceq 'import').Count -ne 1) {
        throw 'Expected one WinGet import across the first apply and reapply.'
    }
    if (@($calls -ceq 'export').Count -ne 2) {
        throw 'Expected one WinGet inventory export during each apply.'
    }
}

function Get-FixtureFontState {
    param([hashtable]$Manifest, [string]$FontDirectory, [string]$RegistryPath)

    $registry = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RegistryPath)
    try {
        $valueNames = if ($null -ne $registry) { $registry.GetValueNames() }
        foreach ($face in $Manifest.Faces) {
            $file = Join-Path $FontDirectory "$face.ttf"
            $copy = $null
            if ([IO.File]::Exists($file)) {
                $copy = Join-Path $fixture "$face.previous.ttf"
                [IO.File]::Copy($file, $copy)
            }
            $name = "$face (TrueType)"
            $value = $kind = $null
            if ($name -in $valueNames) {
                $value = $registry.GetValue($name, $null, 'DoNotExpandEnvironmentNames')
                $kind = $registry.GetValueKind($name)
            }
            @{ File = $file; Copy = $copy; Name = $name; Value = $value; Kind = $kind }
        }
    } finally {
        if ($null -ne $registry) { $registry.Dispose() }
    }
}

function Restore-FixtureFontState {
    param([hashtable[]]$State, [string]$RegistryPath)

    $registry = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RegistryPath, $true)
    try {
        foreach ($face in $State) {
            if ($face.Copy) {
                [IO.File]::Copy($face.Copy, $face.File, $true)
            } elseif ([IO.File]::Exists($face.File)) {
                [IO.File]::Delete($face.File)
            }
            if ($null -ne $registry) {
                if ($null -eq $face.Kind) {
                    $registry.DeleteValue($face.Name, $false)
                } else {
                    $registry.SetValue($face.Name, $face.Value, $face.Kind)
                }
            }
        }
    } finally {
        if ($null -ne $registry) { $registry.Dispose() }
    }
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
$packageManifestPath = Join-Path $source 'bootstrap/manifests/system/winget-packages.json'
$fontManifestPath = Join-Path $source 'bootstrap/manifests/desktop/maple-mono-nf-cn.env'
$fixtureConfig = @{
    data = @{ name = 'Windows CI'; email = 'smoke@example.invalid'; desktopBaseline = $false }
    persistentState = Join-Path $fixture 'state.boltdb'
    scriptEnv = @{ OH_MY_DEVENV_WINDOWS_BACKUP_ROOT = $backupRoot }
}
$originalGitGlobal = $env:GIT_CONFIG_GLOBAL
$originalPath = $env:PATH
$fontState = $null
try {
    Update-HookPath
    if ($Mode -eq 'smoke') {
        $destination = Join-Path $fixture "home with spaces [test] and 'quote’"
        $profilePath = Join-Path $fixture 'redirected Documents/PowerShell/profile.ps1'
        $fixtureConfig.scriptEnv.OH_MY_DEVENV_WINDOWS_PROFILE_PATH = $profilePath
        Initialize-FixtureStub
    } else {
        $winget = Get-WinGetApplication
        Write-Host "Hosted image: $env:ImageOS $env:ImageVersion"
        Write-Host "Hosted image WinGet path: $($winget.Source)"
        Write-Host (Invoke-NativeCommand -Executable $winget.Source -Arguments @('--version')).Stdout.Trim()
        $terminal = Test-WindowsTerminal
        Write-Host "Hosted image Windows Terminal discoverable: $terminal"
        $destination = $HOME
        $profilePath = $PROFILE.CurrentUserAllHosts
        $openSsh = Join-Path $env:WINDIR 'System32/OpenSSH'
        $env:PATH = "$openSsh;$env:PATH"
        $fixtureConfig.data.desktopBaseline = $true
        $fontManifest = Read-DesktopFontManifest -Path $fontManifestPath
        $fontTarget = Get-DesktopFontTarget -LocalData (Get-DesktopLocalData -Destination $destination)
        $fontState = Get-FixtureFontState -Manifest $fontManifest @fontTarget

        # The hosted Windows Server stalls when activating the installed MSIX.
        # Keep the real registration and run its binary from a fixture directory.
        Install-WinGetPackage -ManifestPath $packageManifestPath
        $windowsPowerShell = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $package = Invoke-NativeCommand -Executable $windowsPowerShell -Arguments @(
            '-NoProfile', '-NonInteractive', '-Command', "(Get-AppxPackage -Name 'ohmyposh.cli').InstallLocation"
        ) -TimeoutSeconds 90
        $installLocation = $package.Stdout.Trim()
        if (-not $installLocation) {
            throw 'WinGet did not register Oh My Posh for the hosted user.'
        }
        $poshBin = [IO.Directory]::CreateDirectory((Join-Path $fixture 'posh-bin')).FullName
        Copy-Item -LiteralPath (Join-Path $installLocation 'oh-my-posh.exe') -Destination $poshBin
        $env:PATH = "$poshBin;$env:PATH"
        Write-Host 'Hosted Oh My Posh probe uses the executable copied from the registered MSIX.'
    }
    $ssh = Get-PathApplication -Name ssh
    if ($Mode -eq 'apply' -and $ssh.Source -ne (Join-Path $openSsh 'ssh.exe')) {
        throw "Expected Windows OpenSSH at '$openSsh'. Resolved '$($ssh.Source)'."
    }
    $chezmoiArgs = @(
        "--source=$source", "--config=$config", "--destination=$destination"
    )
    $renderedConfig = Join-Path $fixture 'rendered-config.toml'
    $renderConfig = Invoke-FixtureChezmoi -Arguments @(
        '--override-data', ($fixtureConfig.data | ConvertTo-Json -Compress), 'execute-template',
        '--init', '--file', (Join-Path $source '.chezmoi.toml.tmpl')
    )
    Set-FixtureText -Path $renderedConfig -Content $renderConfig.Stdout
    $effectiveConfig = Invoke-NativeCommand -Executable $chezmoi.Source -Arguments @(
        "--source=$source", "--config=$renderedConfig", 'dump-config', '--format=json'
    )
    $fixtureConfig.interpreters = (ConvertFrom-Json -InputObject $effectiveConfig.Stdout -AsHashtable).interpreters
    $gitConfig = Join-Path $destination '.gitconfig'
    if ($Mode -eq 'smoke') {
        $env:GIT_CONFIG_GLOBAL = $gitConfig
    }
    $gitOverlay = Join-Path $destination '.config/oh-my-devenv/git/config'
    $miseConfig = Join-Path $destination '.config/mise/config.toml'
    $profileBody = Join-Path $destination '.config/oh-my-devenv/powershell/profile.ps1'
    $profileEnvironment = Join-Path $destination '.config/oh-my-devenv/powershell/environment.ps1'
    $profileOverlay = Join-Path $destination '.config/oh-my-devenv/powershell/profile.local.ps1'
    $poshTheme = Join-Path $destination '.config/oh-my-devenv/powershell/robbyrussell.omp.json'
    $sshConfig = Join-Path $destination '.ssh/config'
    $sshOverlay = Join-Path $destination '.ssh/config.d/oh-my-devenv-fixture.conf'
    $terminalFragment = Join-Path $destination 'AppData/Local/Microsoft/Windows Terminal/Fragments/oh-my-devenv/desktop.json'
    $oldMise = "# pre-existing mise fixture`n"
    $oldProfile = "# pre-existing profile fixture`n"
    $overlayGoBin = [IO.Directory]::CreateDirectory((Join-Path $fixture 'overlay-go-bin')).FullName
    $overlayFirst = Join-Path $fixture 'overlay-first'
    $overlaySecond = Join-Path $fixture 'overlay-second'
    $overlayPath = ($overlayFirst, $overlaySecond, $overlayFirst) -join ';'
    $overlayContent = @'
$env:OH_MY_DEVENV_PROFILE_FIXTURE = 'loaded'
$env:GOBIN = '{0}'
$env:PATH = '{1};' + $env:PATH
function prompt {{ 'overlay prompt> ' }}
'@ -f $overlayGoBin.Replace("'", "''"), $overlayPath.Replace("'", "''")
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
            $rendered = Invoke-FixtureChezmoi -Arguments @(
                '--override-data', '{"desktopBaseline":true}', 'execute-template', '--file', $hook.FullName
            )
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

        # An alternate desktop destination must fail before writing the fragment or reaching the installer.
        $fixtureConfig.data.desktopBaseline = $true
        Set-FixtureText -Path $config -Content ($fixtureConfig | ConvertTo-Json -Depth 4)
        try {
            $failed = Invoke-FixtureChezmoi -Arguments @('apply', '--force') -AllowFailure
            if ($failed.ExitCode -eq 0 -or ($failed.Stderr + $failed.Stdout) -notmatch 'LocalAppData resolves to' -or
                [IO.File]::Exists($terminalFragment) -or [IO.File]::Exists($env:OH_MY_DEVENV_TEST_WINGET_LOG)) {
                throw "The alternate desktop destination did not stop before writes.`n$($failed.Stderr)`n$($failed.Stdout)"
            }
            Write-Host $failed.Stderr
        } finally {
            $fixtureConfig.data.desktopBaseline = $false
            Set-FixtureText -Path $config -Content ($fixtureConfig | ConvertTo-Json -Depth 4)
        }

        # The mise file sorts before Git and proves a partial backup cannot authorize deletions.
        $oldGit = "# pre-existing Git fixture`n"
        Set-FixtureText -Path $gitConfig -Content $oldGit
        $oldGitBytes = [IO.File]::ReadAllBytes($gitConfig)
        $oldMiseBytes = [IO.File]::ReadAllBytes($miseConfig)
        $oldProfileBytes = [IO.File]::ReadAllBytes($profilePath)
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
        if (-not [Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes($miseConfig), $oldMiseBytes) -or
            -not [Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes($gitConfig), $oldGitBytes) -or
            -not [Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes($profilePath), $oldProfileBytes) -or
            [IO.File]::Exists($profileBody)) {
            throw 'The failed backups allowed changes to the destination.'
        }
        [IO.Directory]::Move($uninstallBackupRoot, (Join-Path $fixture 'failed-uninstall-backup'))
        & $uninstall @uninstallOptions
        $run = Get-ChildItem -LiteralPath $uninstallBackupRoot -Directory
        $miseCopy = Get-BackupPath -Path $miseConfig -RunDirectory $run.FullName
        $gitCopy = Get-BackupPath -Path $gitConfig -RunDirectory $run.FullName
        if (-not [Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes($miseCopy), $oldMiseBytes) -or
            -not [Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes($gitCopy), $oldGitBytes) -or
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
        $alternateGitConfig = Join-Path $fixture 'alternate.gitconfig'
        Set-FixtureText -Path $alternateGitConfig -Content "# alternate global config`n"
        $env:GIT_CONFIG_GLOBAL = $alternateGitConfig
        try {
            $actual = [regex]::Escape($alternateGitConfig.Replace('\', '/')) -replace '/', '[\\/]'
            $expected = [regex]::Escape($gitConfig)
            Assert-FixtureCheckFailure -Pattern "Git global config paths '$actual' do not include managed file '$expected'"
        } finally {
            $env:GIT_CONFIG_GLOBAL = $gitConfig
        }

        $installedProfile = [IO.File]::ReadAllText($profilePath)
        Set-FixtureText -Path $profilePath -Content "return`n$installedProfile"
        Assert-FixtureCheckFailure -Pattern 'profile body did not run'
        Set-FixtureText -Path $profilePath -Content $installedProfile
        $installedBody = [IO.File]::ReadAllText($profileBody)
        $originalProbePath = $env:PATH
        $originalGoBin = $env:GOBIN
        try {
            $env:GOBIN = Join-Path $fixture 'profile-go-bin'
            $probeEntries = @(
                (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'mise/shims')
                (Join-Path $HOME '.local/bin')
                $env:GOBIN
            )
            $env:PATH = ($probeEntries + $originalProbePath) -join ';'
            foreach ($missingEntry in $probeEntries) {
                $keptEntries = ($probeEntries | Where-Object { $_ -ne $missingEntry }) -join ';'
                $keptEntries = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($keptEntries)
                $fixtureBody = @'
$env:PATH = '{0};' + $env:PATH
$env:OH_MY_DEVENV_PROFILE_LOADED = '1'
'@ -f $keptEntries
                Set-FixtureText -Path $profileBody -Content $fixtureBody
                $missingName = [regex]::Escape((Split-Path -Leaf $missingEntry))
                Assert-FixtureCheckFailure -Pattern "(?s)The managed profile did not add.*?[\\/]$missingName'"
            }
        } finally {
            $env:PATH = $originalProbePath
            $env:GOBIN = $originalGoBin
            Set-FixtureText -Path $profileBody -Content $installedBody
        }
        $alternateTheme = Join-Path (Split-Path -Parent $poshTheme) 'fixture.omp.json'
        Copy-Item -LiteralPath $poshTheme -Destination $alternateTheme
        try {
            Set-FixtureText -Path $profileBody -Content ($installedBody.Replace('robbyrussell.omp.json', 'fixture.omp.json'))
            Assert-FixtureCheckFailure -Pattern '(?s)Oh My Posh did not load the managed theme\..*robbyrussell\.omp\.json'
        } finally {
            Set-FixtureText -Path $profileBody -Content $installedBody
            [IO.File]::Delete($alternateTheme)
        }
        Set-FixtureText -Path $profilePath -Content $oldProfile
        Invoke-FixtureApply
        Assert-FixtureWinGet
        if ([IO.File]::Exists($env:OH_MY_DEVENV_TEST_INSTALLERS)) {
            throw 'A hook attempted to install mise or ecosystem tools.'
        }
        return
    }

    $baselineProfile = [IO.File]::ReadAllText($profilePath)
    $plainScript = Join-Path $fixture 'plain-profile-startup.ps1'
    Set-FixtureText -Path $plainScript -Content @'
if ($env:OH_MY_DEVENV_PROFILE_LOADED -cne '1' -or $env:OH_MY_DEVENV_POSH_CONFIG) {
    throw 'Script startup must load the managed profile without initializing Oh My Posh.'
}
[Console]::WriteLine($env:OH_MY_DEVENV_PROFILE_FIXTURE)
[Console]::WriteLine((prompt))
[Console]::Write($env:PATH)
'@
    $probe = Invoke-NativeCommand -Executable $pwsh -Arguments @('-NoLogo', '-File', $plainScript) -TimeoutSeconds 90 -Environment @{
        OH_MY_DEVENV_PROFILE_LOADED = $null
        OH_MY_DEVENV_PROBE_PROMPT = $null
    }
    $profileOutput = $probe.Stdout -split '\r?\n', 3
    if ($profileOutput.Count -ne 3 -or $profileOutput[0] -cne 'loaded' -or $profileOutput[1] -cne 'overlay prompt> ') {
        throw "A new PowerShell process did not load the profile overlay.`n$($probe.Stderr)`n$($probe.Stdout)"
    }
    if (-not ";$($profileOutput[2])".Contains(";$overlayGoBin;$overlayPath;", [StringComparison]::Ordinal)) {
        throw 'The new PowerShell process did not prepend the overlay GOBIN and preserve its PATH order.'
    }
    Write-Host 'Plain pwsh -File loaded the managed profile and overlay without initializing Oh My Posh.'

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
    $fragmentBytes = [IO.File]::ReadAllBytes($terminalFragment)
    try {
        [IO.File]::Delete($terminalFragment)
        Assert-FixtureCheckFailure -Pattern 'Missing Windows Terminal fragment'
        Set-FixtureText -Path $terminalFragment -Content '{ "profiles": ['
        Assert-FixtureCheckFailure -Pattern 'Invalid JSON in Windows Terminal fragment'
    } finally {
        [IO.File]::WriteAllBytes($terminalFragment, $fragmentBytes)
    }

    $beforePreview = (Invoke-FixtureChezmoi -Arguments @('state', 'dump')).Stdout
    & $uninstall -Config $config
    if ((Invoke-FixtureChezmoi -Arguments @('state', 'dump')).Stdout -cne $beforePreview) {
        throw 'The uninstall preview changed the chezmoi state.'
    }
    if ([IO.File]::ReadAllText($profilePath) -cne $baselineProfile -or -not [IO.File]::Exists($profileBody)) {
        throw 'The uninstall preview changed the destination.'
    }
    & $uninstall -Apply -Config $config -BackupRoot $uninstallBackupRoot
    $state = (Invoke-FixtureChezmoi -Arguments @('state', 'dump')).Stdout | ConvertFrom-Json -AsHashtable
    if ($state.scriptState.Count -or $state.entryState.Count) {
        throw 'Uninstall did not reset the chezmoi script and entry state.'
    }
    foreach ($target in @($gitConfig, $miseConfig, $profileBody, $profileEnvironment, $sshConfig)) {
        if ([IO.File]::Exists($target)) {
            throw "Uninstall kept managed target '$target'."
        }
    }
    if ([IO.File]::Exists($terminalFragment)) {
        throw 'Uninstall kept the Terminal fragment.'
    }
    Confirm-DesktopFont -Manifest $fontManifest @fontTarget
    if ([IO.File]::ReadAllText($profilePath) -cne $oldProfile -or
        [IO.File]::ReadAllText($profileOverlay) -cne $overlayContent -or
        -not [IO.File]::Exists($gitOverlay) -or -not [IO.File]::Exists($sshOverlay) -or
        -not [IO.Directory]::Exists($backupRoot)) {
        throw 'Uninstall changed the user profile content, overlays, or backups.'
    }
    [byte[]]$restoredMiseBytes = [Text.Encoding]::UTF8.GetPreamble() +
        [Text.Encoding]::UTF8.GetBytes("# user restored mise content before reapply`r`n")
    [IO.File]::WriteAllBytes($miseConfig, $restoredMiseBytes)
    Invoke-FixtureApply
    $restoredCopies = @(Get-ChildItem -LiteralPath $backupRoot -Directory | ForEach-Object {
        $copy = Get-BackupPath -Path $miseConfig -RunDirectory $_.FullName
        if ([IO.File]::Exists($copy) -and
            [Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes($copy), $restoredMiseBytes)) {
            $copy
        }
    })
    if ($restoredCopies.Count -ne 1) {
        throw "Expected one byte-for-byte first-run backup of '$miseConfig' after uninstall."
    }
    $status = Invoke-FixtureChezmoi -Arguments @('status', '--exclude=scripts')
    if ($status.Stdout.Trim()) {
        throw "Restored destination has drift.`n$($status.Stdout)"
    }
} finally {
    try {
        if ($null -ne $fontState) {
            Restore-FixtureFontState -State $fontState -RegistryPath $fontTarget.RegistryPath
        }
    } finally {
        $env:GIT_CONFIG_GLOBAL = $originalGitGlobal
        $env:PATH = $originalPath
        [IO.Directory]::Delete($fixture, $true)
    }
}
