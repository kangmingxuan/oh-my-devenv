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
. (Join-Path $helpers 'user-path.ps1')
. (Join-Path $helpers 'mise.ps1')
. (Join-Path $helpers 'ecosystem.ps1')
. (Join-Path $helpers 'completions.ps1')

# Isolate in-process information-stream captures from the runner's terminal.
$env:NO_COLOR = '1'
. (Join-Path $PSScriptRoot 'fixtures/output-expected.ps1')
$fixtureOutput = @(Read-OutputGolden)

function Get-FixtureOutputLabel {
    param([string]$Level)
    $row = $fixtureOutput | Where-Object { $_.Mode -ceq 'plain' -and $_.Level -ceq $Level }
    ($row.Bytes.TrimStart() -split ' ')[0]
}

$previewLabel = Get-FixtureOutputLabel would
$okLabel = Get-FixtureOutputLabel ok
$nextLabel = Get-FixtureOutputLabel next
$missingLabel = Get-FixtureOutputLabel missing

function Invoke-FixtureChezmoi {
    param([string[]]$Arguments, [switch]$AllowFailure, [int]$TimeoutSeconds = 0)

    Invoke-NativeCommand -Executable $chezmoi.Source -Arguments ($chezmoiArgs + $Arguments) -AllowFailure:$AllowFailure -TimeoutSeconds $TimeoutSeconds
}

function Invoke-FixtureApply {
    param([switch]$Reapply)

    $result = Invoke-FixtureChezmoi -Arguments @('apply', '--force') -AllowFailure -TimeoutSeconds 900
    Write-Host $result.Stdout
    Write-Host $result.Stderr
    $script:fixtureInstallLog += $result.Stdout + $result.Stderr
    if ($result.ExitCode -ne 0) { throw "Windows fixture apply exited with code $($result.ExitCode)." }
    if ($Reapply -and ($result.Stdout + $result.Stderr) -match '(?:Syncing mise-managed|Syncing Go tools|Syncing uv tools|Installing jdx.mise|Installed PowerShell completion:)') {
        throw 'Reapply ran an unchanged runtime, tool, or completion installer.'
    }
    if ($result.Stdout -notmatch 'All checks passed\.') {
        throw 'The Windows check did not run or did not pass.'
    }
    if (-not $result.Stdout.Contains("  $okLabel chezmoi ") -or
        -not $result.Stdout.Contains("  $nextLabel Open a new PowerShell session")) {
        throw 'The Windows check omitted the core tool versions or next steps.'
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

    $diagnostic = [IO.StringWriter]::new()
    $originalError = [Console]::Error
    try {
        [Console]::SetError($diagnostic)
        & (Join-Path $helpers 'check.ps1') -Destination $destination -ProfilePath $profilePath `
            -DesktopBaseline:$fixtureConfig.data.desktopBaseline -RegistryPath $pathTarget.RegistryPath `
            -ProbeFixtureBin $fixtureConfig.scriptEnv.OH_MY_DEVENV_WINDOWS_PROBE_BIN
        $exitCode = $LASTEXITCODE
        $output = $diagnostic.ToString()
    } finally {
        [Console]::SetError($originalError)
        $diagnostic.Dispose()
    }
    if ($exitCode -eq 0 -or $output -notmatch $Pattern) {
        throw "Expected the checker to fail with '$Pattern'. Exit $exitCode.`n$output"
    }
    Write-Host $output
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
        if (Phase4Stub.TryCompletion(program, String.Join(" ", args)))
            return 0;
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
        if (program == "mise" || program == "go" || program == "uv" || program == "python")
            return Phase4Stub.Run(program, args);
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
            return 97;
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
    $null = Invoke-NativeCommand -Executable $compiler -Arguments @(
        '/nologo', "/out:$shim", $stubSource, (Join-Path $PSScriptRoot 'Phase4Stub.cs')
    )
    foreach ($tool in @('ssh', 'winget', 'oh-my-posh', 'mise')) {
        Copy-Item -LiteralPath $shim -Destination (Join-Path $shimDirectory "$tool.exe")
    }
    # The fresh profile probe uses persistent PATH plus these fixture entries.
    $fixtureConfig.scriptEnv.OH_MY_DEVENV_WINDOWS_PROBE_BIN = "$shimDirectory;$([IO.Path]::GetDirectoryName($chezmoi.Source))"
    $env:OH_MY_DEVENV_TEST_PHASE4 = $fixture
    $env:GOBIN = Join-Path $fixture 'ecosystem-bin'
    $env:UV_TOOL_BIN_DIR = $env:GOBIN
    $env:UV_TOOL_DIR = Join-Path $fixture 'uv-tools'
    $env:OH_MY_DEVENV_TEST_HOME = $destination
    $env:OH_MY_DEVENV_TEST_WINGET_LOG = Join-Path $fixture 'winget.log'
    $env:OH_MY_DEVENV_TEST_WINGET_MANIFEST = $packageManifestPath
    $env:PATH = "$shimDirectory;$(Join-Path $fixture 'runtime-bin');$env:PATH"
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
    param([hashtable]$Manifest, [hashtable]$Target)

    $registry = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Target.RegistryPath)
    try {
        $valueNames = if ($null -ne $registry) { $registry.GetValueNames() }
        foreach ($face in $Manifest.Faces) {
            $file = Join-Path $Target.FontDirectory "$face.ttf"
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

function Assert-FixtureFontState {
    param([hashtable[]]$State, [hashtable]$Target)

    if ([IO.File]::Exists($Target.StatePath)) { throw 'Uninstall kept the desktop font ownership record.' }
    $registry = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Target.RegistryPath)
    try {
        foreach ($face in $State) {
            if ([IO.File]::Exists($face.File) -ne [bool]$face.Copy -or ($face.Copy -and
                -not [Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes($face.File), [IO.File]::ReadAllBytes($face.Copy)))) {
                throw "Unexpected post-uninstall font bytes or presence at '$($face.File)'."
            }
            $value = if ($registry) { $registry.GetValue($face.Name, $null, 'DoNotExpandEnvironmentNames') }
            if ($value -cne $face.Value -or ($null -ne $value -and $registry.GetValueKind($face.Name) -ne $face.Kind)) {
                throw "Unexpected post-uninstall registration '$($face.Name)'."
            }
        }
    } finally {
        if ($registry) { $registry.Dispose() }
    }
}

function Assert-FixtureCompletionUninstall {
    param([string[]]$Owned, [string]$UserFile, [byte[]]$UserBytes)

    foreach ($file in $Owned) {
        if ([IO.File]::Exists($file)) { throw "Uninstall kept owned completion '$file'." }
    }
    if (-not [Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes($UserFile), $UserBytes)) {
        throw "Uninstall changed the unowned completion '$UserFile'."
    }
    Write-Host 'Uninstall removed the owned completions and preserved the unowned script bytes.'
}

function Test-FixtureCompletionStartup {
    param([string]$Loader, [string]$LocalData, [string]$Executable, [string]$PromptBin)

    $probePath = Join-Path $fixture 'completion-startup.ps1'
    $resultPath = Join-Path $fixture 'interactive-completion.json'
    Set-FixtureText -Path $probePath -Content @'
param([string]$Loader, [string]$LocalData, [string]$InteractiveResult, [string]$CompletionProbe)
$ErrorActionPreference = 'Stop'
if ($InteractiveResult) {
    $redirected = [Console]::IsInputRedirected -or [Console]::IsOutputRedirected
    $loaded = $env:OH_MY_DEVENV_COMPLETION_FIXTURE -ceq 'loaded'
    if (-not $redirected -and $loaded) { & $CompletionProbe }
    @{
        Redirected = $redirected
        Loaded = $loaded
    } | ConvertTo-Json | Set-Content -LiteralPath $InteractiveResult
    return
}
$elapsed = [Diagnostics.Stopwatch]::StartNew()
. $Loader
$directory = Get-PowerShellCompletionDirectory -LocalData $LocalData
foreach ($file in Get-OwnedPowerShellCompletion -Directory $directory) {
    . $file.FullName
}
$elapsed.Stop()
if ($env:OH_MY_DEVENV_COMPLETION_FIXTURE -cne 'loaded') { throw 'The managed completion loader did not source the probe.' }
[Console]::WriteLine($elapsed.ElapsedMilliseconds)
'@
    $times = @(1..3 | ForEach-Object {
        $result = Invoke-NativeCommand -Executable $Executable -Arguments @(
            '-NoLogo', '-NoProfile', '-File', $probePath, '-Loader', $Loader, '-LocalData', $LocalData
        ) -Environment @{ OH_MY_DEVENV_COMPLETION_FIXTURE = $null } -TimeoutSeconds 30
        [int]$result.Stdout.Trim()
    } | Sort-Object)
    Write-Host "Added completion load time in fresh Windows PowerShell processes: $($times -join ', ') ms, median $($times[1]) ms."
    if ($times[1] -gt 300) {
        Write-Warning 'Median completion loading exceeded 300 ms. Consider registering a lightweight completer that loads the command script on first use.'
    }

    # Launch an unredirected child with its own console if the runner allows it.
    # The child writes a result file so reading the result does not redirect its streams.
    $escapedProbe = $probePath.Replace("'", "''")
    $escapedResult = $resultPath.Replace("'", "''")
    $completionProbe = (Join-Path $helpers 'completion-probe.ps1').Replace("'", "''")
    $command = '& ''{0}'' -InteractiveResult ''{1}'' -CompletionProbe ''{2}''' -f $escapedProbe, $escapedResult, $completionProbe
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    try {
        $process = Start-Process -FilePath $Executable -ArgumentList @('-NoLogo', '-EncodedCommand', $encoded) `
            -Environment @{ PATH = "$PromptBin;$env:PATH"; OH_MY_DEVENV_COMPLETION_FIXTURE = $null } `
            -WindowStyle Hidden -PassThru
    } catch {
        Write-Warning "Interactive profile completion probe could not create a hosted console. $_"
        return
    }
    try {
        if (-not $process.WaitForExit(90000)) {
            $process.Kill($true)
            throw 'Interactive completion probe did not finish within 90 seconds.'
        }
        if ($process.ExitCode -ne 0 -or -not [IO.File]::Exists($resultPath)) {
            throw "Interactive completion probe exited with code $($process.ExitCode) or did not write its result."
        }
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -AsHashtable
        if ($result.Redirected) {
            if ($result.Loaded) { throw 'The profile loaded completions with redirected I/O.' }
            Write-Warning 'Hosted child has redirected streams. Interactive profile startup is unverified.'
        } elseif (-not $result.Loaded) {
            throw 'The interactive profile did not load the managed completions.'
        } else {
            Write-Host 'An unredirected PowerShell profile completed chezmoi and uv commands.'
        }
    } finally {
        $process.Dispose()
    }
}

function Restore-FixtureFontState {
    param([hashtable[]]$State, [string]$RegistryPath)

    $registry = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RegistryPath, $true)
    try {
        foreach ($face in $State) {
            if ($face.Copy -and (-not [IO.File]::Exists($face.File) -or
                -not [Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes($face.File), [IO.File]::ReadAllBytes($face.Copy)))) {
                [IO.File]::Copy($face.Copy, $face.File, $true)
            } elseif (-not $face.Copy -and [IO.File]::Exists($face.File)) {
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

function Initialize-FixturePathSnapshot {
    if ('OhMyDevenv.FixtureRegistry' -as [type]) { return }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace OhMyDevenv {
    public static class FixtureRegistry {
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        public static extern int RegQueryValueEx(SafeRegistryHandle key, string name, IntPtr reserved,
            out uint type, [Out] byte[] data, ref uint size);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        public static extern int RegSetValueEx(SafeRegistryHandle key, string name, uint reserved,
            uint type, byte[] data, uint size);
    }
}
'@
}

function Get-FixturePathSnapshot {
    param([string]$RegistryPath)

    Initialize-FixturePathSnapshot
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RegistryPath)
    try {
        if ($null -eq $key) { return @{ Type = $null; Bytes = [byte[]]@() } }
        $size = $kind = [uint32]0
        $status = [OhMyDevenv.FixtureRegistry]::RegQueryValueEx($key.Handle, 'Path', [IntPtr]::Zero,
            [ref]$kind, $null, [ref]$size)
        if ($status -eq 2) { return @{ Type = $null; Bytes = [byte[]]@() } }
        if ($status -ne 0) { throw "Could not read the hosted user Path size. Win32 error $status." }
        $bytes = [byte[]]::new($size)
        $status = [OhMyDevenv.FixtureRegistry]::RegQueryValueEx($key.Handle, 'Path', [IntPtr]::Zero,
            [ref]$kind, $bytes, [ref]$size)
        if ($status -ne 0 -or $size -ne $bytes.Length) { throw "Could not snapshot the hosted user Path. Win32 error $status." }
        @{ Type = $kind; Bytes = $bytes }
    } finally {
        if ($null -ne $key) { $key.Dispose() }
    }
}

function Restore-FixturePathSnapshot {
    param([string]$RegistryPath, [hashtable]$Snapshot)

    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($RegistryPath)
    try {
        if ($null -eq $Snapshot.Type) {
            $key.DeleteValue('Path', $false)
        } else {
            $status = [OhMyDevenv.FixtureRegistry]::RegSetValueEx($key.Handle, 'Path', 0,
                $Snapshot.Type, $Snapshot.Bytes, $Snapshot.Bytes.Length)
            if ($status -ne 0) { throw "Could not restore the hosted user Path. Win32 error $status." }
        }
    } finally {
        $key.Dispose()
    }
}

function Assert-FixturePathSnapshot {
    param([string]$RegistryPath, [hashtable]$Expected)

    $actual = Get-FixturePathSnapshot -RegistryPath $RegistryPath
    if ($actual.Type -ne $Expected.Type -or
        -not [Linq.Enumerable]::SequenceEqual[byte]($actual.Bytes, $Expected.Bytes)) {
        throw "The Path value type or raw registry bytes changed in HKCU\$RegistryPath."
    }
}

function Assert-FixturePathUnchanged {
    param([hashtable]$Expected = $afterPhase4)

    Assert-FixturePathSnapshot -RegistryPath $pathTarget.RegistryPath -Expected $Expected
    if ($recordedPath.Count) {
        if (-not [Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes($pathTarget.StatePath), $recordBytes)) {
            throw 'The user Path ownership record changed.'
        }
    } elseif ([IO.File]::Exists($pathTarget.StatePath)) {
        throw 'The existing user Path did not require an ownership record.'
    }
}

function Assert-FixturePathUninstall {
    param([hashtable]$Options)

    Assert-FixturePathUnchanged
    $before = Read-UserPath -RegistryPath $pathTarget.RegistryPath
    if ($recordedPath.Count) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($pathTarget.RegistryPath, $true)
        try { $key.SetValue('Path', "$($before.Value);$($recordedPath[0])", $before.Kind) }
        finally { $key.Dispose() }
        $before = Read-UserPath -RegistryPath $pathTarget.RegistryPath
    }
    $beforePreview = Get-FixturePathSnapshot -RegistryPath $pathTarget.RegistryPath
    $remaining = [Collections.Generic.List[string]]::new()
    $remaining.AddRange([string[]]($before.Value -split ';'))
    foreach ($entry in $recordedPath) {
        if (-not $remaining.Remove($entry)) { throw "The fixture Path lacked recorded entry '$entry'." }
    }
    $expected = $remaining -join ';'
    $previewOptions = $Options.Clone()
    $previewOptions.Remove('Apply')
    $preview = (& $uninstall @previewOptions 6>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "Uninstall preview failed with exit $LASTEXITCODE." }
    foreach ($entry in $recordedPath) {
        if (-not $preview.Contains("  $previewLabel remove user Path entry '$entry'.")) {
            throw "Uninstall preview omitted '$entry'."
        }
    }
    Assert-FixturePathUnchanged -Expected $beforePreview
    & $uninstall @Options
    if ($LASTEXITCODE -ne 0) { throw "Uninstall failed with exit $LASTEXITCODE." }
    $after = Read-UserPath -RegistryPath $pathTarget.RegistryPath
    if ($after.Value -cne $expected -or $after.Kind -ne $before.Kind -or [IO.File]::Exists($pathTarget.StatePath)) {
        throw 'Uninstall did not remove exactly the recorded user Path entries and their record.'
    }
    Write-Host 'Uninstall removed exactly the recorded entries and preserved the pre-existing user Path entries.'
}

function Write-FixturePhase4Diagnostic {
    $pathError = $fixtureInstallLog -match '(?i)path.{0,60}(too long|length limit)|filename.{0,60}too long|(?:os error|Win32 error) 206\b'
    if ($fixtureInstallLog) {
        Write-Host "Phase 4 installer log contains a path-length error: $pathError"
    } else {
        Write-Host 'Phase 4 installer path-length errors: unavailable without an apply log.'
    }

    Update-HookPath -Managed
    $inventory = @{}
    $directories = @{}
    if (Get-PathApplication -Name mise.exe -Optional) {
        try {
            $inventory = (Invoke-GlobalMise -Arguments @('ls', '--current', '--json')).Stdout | ConvertFrom-Json -AsHashtable
        } catch { Write-Warning "Could not read the installed mise inventory. $_" }
        try {
            $doctor = Invoke-GlobalMise -Arguments @('doctor', '--json') -AllowFailure
            $directories['mise data'] = ($doctor.Stdout | ConvertFrom-Json -AsHashtable).dirs.data
        } catch { Write-Warning "Could not resolve the mise data directory. $_" }
        try {
            $uv = Get-MiseToolExecutable -Name uv
            $directories['uv tools'] = (Invoke-NativeCommand -Executable $uv -Arguments @('tool', 'dir')).Stdout.Trim()
        } catch { Write-Warning "Could not resolve the uv tools directory. $_" }
    }
    foreach ($tool in $miseVersions.Keys | Sort-Object) {
        $records = @($inventory[$tool] | Where-Object { $_ -and $_['installed'] })
        $versions = if ($records.Count) { ($records | ForEach-Object { $_['version'] }) -join ', ' } else { 'unconfirmed' }
        Write-Host "Phase 4 mise tool ${tool}: requested $($miseVersions[$tool]), installed $versions"
    }
    foreach ($name in 'mise data', 'uv tools') {
        $directory = $directories[$name]
        if (-not $directory -or -not [IO.Directory]::Exists($directory)) {
            Write-Host "Phase 4 longest $name path: unavailable"
            continue
        }
        try {
            $length = 0
            foreach ($entry in Get-ChildItem -LiteralPath $directory -Recurse -Force) {
                $length = [Math]::Max($length, $entry.FullName.Length)
            }
            Write-Host "Phase 4 longest $name path: $length characters under '$directory'"
        } catch { Write-Warning "Could not measure the $name paths. $_" }
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
$runnerFileState = @()
$completionFilesTouched = $false
$pathSnapshot = $null
$pathTarget = $null
$fixtureInstallLog = ''
$miseVersions = @{}
$originalToolEnvironment = @{}
foreach ($name in @('GOPATH', 'GOBIN', 'UV_TOOL_BIN_DIR', 'UV_TOOL_DIR')) {
    $originalToolEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
try {
    Update-HookPath
    if ($Mode -eq 'smoke') {
        $destination = Join-Path $fixture "home with spaces [test] and 'quote’"
        $profilePath = Join-Path $fixture 'redirected Documents/PowerShell/profile.ps1'
        $fixtureConfig.scriptEnv.OH_MY_DEVENV_WINDOWS_PROFILE_PATH = $profilePath
        Initialize-FixtureStub
        $pathTarget = @{
            RegistryPath = "Software/oh-my-devenv-fixture-$([Guid]::NewGuid())".Replace('/', '\')
            StatePath = Join-Path $fixture 'user-path.json'
        }
        $fixtureConfig.scriptEnv.OH_MY_DEVENV_WINDOWS_PATH_REGISTRY = $pathTarget.RegistryPath
        $fixtureConfig.scriptEnv.OH_MY_DEVENV_WINDOWS_PATH_STATE = $pathTarget.StatePath
    } else {
        $pathTarget = Get-HookUserPathTarget -Destination $HOME -HomeDirectory $HOME
        if ([IO.File]::Exists($pathTarget.StatePath)) {
            throw 'The hosted runner already has a managed user Path ownership record.'
        }
        $pathSnapshot = Get-FixturePathSnapshot -RegistryPath $pathTarget.RegistryPath
        Write-Host "Hosted image mise before apply: $((Get-PathApplication -Name mise.exe -Optional | Select-Object -ExpandProperty Source))"
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
        if ([IO.File]::Exists($fontTarget.StatePath)) {
            throw 'The hosted runner already has a desktop font ownership record.'
        }
        $fontState = Get-FixtureFontState -Manifest $fontManifest -Target $fontTarget

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
        $fixtureConfig.scriptEnv.OH_MY_DEVENV_WINDOWS_PROBE_BIN = "$poshBin;$([IO.Path]::GetDirectoryName($chezmoi.Source))"
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
    $miseTools = '{{ (include "dot_config/mise/config.toml.tmpl" | fromToml).tools | toJson }}'
    $miseVersions = (Invoke-FixtureChezmoi -Arguments @('execute-template', $miseTools)).Stdout | ConvertFrom-Json -AsHashtable
    if ($Mode -eq 'smoke') {
        $inventory = @{}
        foreach ($name in $miseVersions.Keys) {
            $inventory[$name] = @(@{ version = $miseVersions[$name]; active = $true; installed = $true; source = @{ path = $miseConfig } })
        }
        Set-FixtureText -Path (Join-Path $fixture 'mise-tools.txt') -Content ($miseVersions.Keys -join "`n")
        Set-FixtureText -Path (Join-Path $fixture 'mise-inventory.json') -Content ($inventory | ConvertTo-Json -Depth 5)
        Set-FixtureText -Path (Join-Path $fixture 'mise-python-version') -Content $miseVersions.python
    }
    $profileBody = Join-Path $destination '.config/oh-my-devenv/powershell/profile.ps1'
    $profileEnvironment = Join-Path $destination '.config/oh-my-devenv/powershell/environment.ps1'
    $profileCompletionLoader = Join-Path $destination '.config/oh-my-devenv/powershell/completions.ps1'
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
    $completionLocalData = Get-CompletionLocalData -Destination $destination
    $completionDirectory = Get-PowerShellCompletionDirectory -LocalData $completionLocalData
    $completionManifest = Join-Path $source 'bootstrap/manifests/shell/completions.txt'
    $completionOptions = @{ ManifestPath = $completionManifest; LocalData = $completionLocalData }
    $unownedCompletion = Join-Path $completionDirectory 'oh-my-devenv-user-fixture.ps1'
    $completionProbe = Join-Path $completionDirectory 'oh-my-devenv-startup-fixture.ps1'
    if ($Mode -eq 'apply') {
        if (@(Get-OwnedPowerShellCompletion -Directory $completionDirectory).Count -or
            [IO.File]::Exists($unownedCompletion) -or [IO.File]::Exists($completionProbe)) {
            throw 'The hosted runner already has a completion fixture or ownership marker.'
        }
        $runnerFileState = @(foreach ($file in @(
            Get-ManagedFile -Executable $chezmoi.Source -Config $config -Source $source -Destination $destination
            $profilePath; $profileOverlay; $gitOverlay; $sshOverlay
        ) | Sort-Object -Unique) {
            $bytes = $acl = $null
            if ([IO.File]::Exists($file)) {
                $bytes = [IO.File]::ReadAllBytes($file)
                $acl = Get-Acl -LiteralPath $file
            }
            @{ Path = $file; Bytes = $bytes; Acl = $acl }
        })
    }
    $completionFilesTouched = $true
    Set-FixtureText -Path $unownedCompletion -Content 'throw "Loaded a user-owned completion"'
    $unownedCompletionBytes = [IO.File]::ReadAllBytes($unownedCompletion)
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
        Push-Location $fixture
        try { Invoke-Pester -Path $PSScriptRoot -Output Detailed -CI }
        finally { Pop-Location }

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
            RegistryPath = $pathTarget.RegistryPath; StatePath = $pathTarget.StatePath
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
            $diagnostic = [IO.StringWriter]::new()
            $originalError = [Console]::Error
            try {
                [Console]::SetError($diagnostic)
                & $uninstall @uninstallOptions
                $exitCode = $LASTEXITCODE
                $output = $diagnostic.ToString()
            } finally {
                [Console]::SetError($originalError)
                $diagnostic.Dispose()
            }
            if ($exitCode -eq 0 -or $output -notlike '*Pre-uninstall backup failed*Could not back up*') {
                throw "Expected a pre-delete copy failure. Exit $exitCode.`n$output"
            }
            Write-Host $output
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
        if ($LASTEXITCODE -ne 0) { throw "Uninstall failed with exit $LASTEXITCODE." }
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

    $managedPath = @(Get-ManagedProfilePathEntry)
    $seedPath = Read-UserPath -RegistryPath $pathTarget.RegistryPath
    # Keep one managed directory as a user-owned entry to check ownership on uninstall.
    if (@(Get-MissingUserPathEntry -PathValue $seedPath -Entries @($managedPath[-1])).Count) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($pathTarget.RegistryPath)
        try {
            $seed = if ($seedPath.Value) { "$($seedPath.Value);$($managedPath[-1])" } else { $managedPath[-1] }
            $key.SetValue('Path', $seed, ($seedPath.Kind ?? [Microsoft.Win32.RegistryValueKind]::ExpandString))
        } finally { $key.Dispose() }
    }
    $managedMissingBeforeApply = @(Get-MissingUserPathEntry -PathValue (Read-UserPath -RegistryPath $pathTarget.RegistryPath) -Entries $managedPath)
    Invoke-FixtureApply
    $ownedCompletions = @(Invoke-PowerShellCompletion @completionOptions -Action list)
    if (-not $ownedCompletions.Count -or $fixtureInstallLog -notmatch 'Installed PowerShell completion:') {
        throw 'The first apply did not install PowerShell completions through hook 55.'
    }
    $afterPhase4 = Get-FixturePathSnapshot -RegistryPath $pathTarget.RegistryPath
    $recordedPath = @(Read-UserPathRecord -StatePath $pathTarget.StatePath)
    if (($recordedPath -join ';') -cne ($managedMissingBeforeApply -join ';')) {
        throw 'The user Path record did not contain exactly the newly inserted entries.'
    }
    [byte[]]$recordBytes = if ($recordedPath.Count) { [IO.File]::ReadAllBytes($pathTarget.StatePath) }
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
        $completion = $ownedCompletions[0]
        $completionBytes = [IO.File]::ReadAllBytes($completion)
        try {
            [IO.File]::Delete($completion)
            Assert-FixtureCheckFailure -Pattern ([regex]::Escape($missingLabel) + ' [^ ]+ Owned PowerShell completion:')
        } finally {
            [IO.File]::WriteAllBytes($completion, $completionBytes)
        }
        try {
            Set-FixtureText -Path $completion -Content @'
# oh-my-devenv: generated by install-shell-completions.ps1
throw 'Fixture completion could not load.'
'@
            Assert-FixtureCheckFailure -Pattern 'Fixture completion could not load\.'
        } finally {
            [IO.File]::WriteAllBytes($completion, $completionBytes)
        }
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($pathTarget.RegistryPath, $true)
        try {
            $key.DeleteValue('Path', $true)
            Assert-FixtureCheckFailure -Pattern 'Missing directories in the user Path'
        } finally {
            $key.Dispose()
            Restore-FixturePathSnapshot -RegistryPath $pathTarget.RegistryPath -Snapshot $afterPhase4
        }

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
        try {
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
        $generatorLog = Join-Path $fixture 'completion-generators.log'
        $generatorCalls = [IO.File]::ReadAllText($generatorLog)
        $completionSnapshot = foreach ($file in $ownedCompletions) {
            [IO.File]::SetLastWriteTimeUtc($file, [datetime]'2020-01-01Z')
            @{
                Path = $file
                Time = [IO.File]::GetLastWriteTimeUtc($file)
                Hash = (Get-FileHash -LiteralPath $file).Hash
            }
        }
        Set-FixtureText -Path $profilePath -Content $oldProfile
        Invoke-FixtureApply -Reapply
        if ([IO.File]::ReadAllText($generatorLog) -cne $generatorCalls) {
            throw 'An unchanged apply called a completion generator.'
        }
        foreach ($file in $completionSnapshot) {
            if ([IO.File]::GetLastWriteTimeUtc($file.Path) -ne $file.Time -or
                (Get-FileHash -LiteralPath $file.Path).Hash -cne $file.Hash) {
                throw "An unchanged apply rewrote '$($file.Path)'."
            }
        }
        Assert-FixtureWinGet
        Assert-FixturePathUnchanged
        $phase4Calls = @(Get-Content -LiteralPath (Join-Path $fixture 'phase4.log'))
        $manifestDirectory = Join-Path $source 'bootstrap/manifests/ecosystem'
        $expectedCalls = @(
            'mise install'
            Read-GoToolManifest -Path (Join-Path $manifestDirectory 'go-tools.txt') | ForEach-Object { "go install $($_.Spec)" }
            Read-UvToolManifest -Path (Join-Path $manifestDirectory 'uv-tools.txt') | ForEach-Object { "uv install $($_.Spec)" }
        )
        if (($phase4Calls -join "`n") -cne ($expectedCalls -join "`n")) {
            throw "Unexpected stub install calls across apply and reapply: $phase4Calls"
        }
        $batCompletion = Join-Path $completionDirectory 'bat.ps1'
        if ([IO.File]::Exists($batCompletion)) {
            throw 'The availability fixture requires bat to be absent from the runner.'
        }
        $batExecutable = Join-Path $fixture 'stub-bin/bat.exe'
        try {
            [IO.File]::Copy((Join-Path $fixture 'stub.exe'), $batExecutable)
            Invoke-FixtureApply
            if (-not (Test-OwnedPowerShellCompletion -Path $batCompletion) -or
                [IO.File]::ReadAllText($generatorLog) -cne ($generatorCalls + "bat`n")) {
                throw 'Apply did not generate exactly one completion for the newly available bat.'
            }
        } finally {
            [IO.File]::Delete($batExecutable)
        }
        Invoke-FixtureApply -Reapply
        if ([IO.File]::Exists($batCompletion) -or [IO.File]::ReadAllText($generatorLog) -cne ($generatorCalls + "bat`n")) {
            throw 'Apply did not prune the completion for the newly absent bat without generating files.'
        }
        Assert-FixturePathUninstall -Options $uninstallOptions
        Assert-FixtureCompletionUninstall -Owned $ownedCompletions -UserFile $unownedCompletion -UserBytes $unownedCompletionBytes
        return
    }

    Set-FixtureText -Path $completionProbe -Content @'
# oh-my-devenv: generated by install-shell-completions.ps1
$env:OH_MY_DEVENV_COMPLETION_FIXTURE = 'loaded'
'@
    Test-FixtureCompletionStartup -Loader $profileCompletionLoader -LocalData $completionLocalData -Executable $pwsh -PromptBin $poshBin
    $baselineProfile = [IO.File]::ReadAllText($profilePath)
    $plainScript = Join-Path $fixture 'plain-profile-startup.ps1'
    Set-FixtureText -Path $plainScript -Content @'
if ($env:OH_MY_DEVENV_PROFILE_LOADED -cne '1' -or $env:OH_MY_DEVENV_POSH_CONFIG -or $env:OH_MY_DEVENV_COMPLETION_FIXTURE) {
    throw 'Script startup must load the managed profile and skip Oh My Posh and completions.'
}
[Console]::WriteLine($env:OH_MY_DEVENV_PROFILE_FIXTURE)
[Console]::WriteLine((prompt))
[Console]::Write($env:PATH)
'@
    $probe = Invoke-NativeCommand -Executable $pwsh -Arguments @('-NoLogo', '-File', $plainScript) -TimeoutSeconds 90 -Environment @{
        OH_MY_DEVENV_PROFILE_LOADED = $null
        OH_MY_DEVENV_PROBE_PROMPT = $null
        OH_MY_DEVENV_COMPLETION_FIXTURE = $null
    }
    $profileOutput = $probe.Stdout -split '\r?\n', 3
    if ($profileOutput.Count -ne 3 -or $profileOutput[0] -cne 'loaded' -or $profileOutput[1] -cne 'overlay prompt> ') {
        throw "A new PowerShell process did not load the profile overlay.`n$($probe.Stderr)`n$($probe.Stdout)"
    }
    if (-not ";$($profileOutput[2])".Contains(";$overlayGoBin;$overlayPath;", [StringComparison]::Ordinal)) {
        throw 'The new PowerShell process did not prepend the overlay GOBIN and preserve its PATH order.'
    }
    Write-Host 'Plain pwsh -File loaded the managed profile and overlay and skipped Oh My Posh and completions.'
    [IO.File]::Delete($completionProbe)

    Invoke-FixtureApply -Reapply
    Assert-FixturePathUnchanged
    if ([IO.File]::ReadAllText($profilePath) -cne $baselineProfile) {
        throw 'Reapply changed the profile.'
    }
    Set-FixtureText -Path $profilePath -Content $oldProfile
    Invoke-FixtureApply -Reapply
    Assert-FixturePathUnchanged
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
    $preview = (& $uninstall -Config $config 6>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "Uninstall preview failed with exit $LASTEXITCODE." }
    Write-Host $preview
    foreach ($file in $ownedCompletions) {
        if (-not $preview.Contains("  $previewLabel remove '$file'.") -or -not [IO.File]::Exists($file)) {
            throw "Uninstall preview omitted or removed PowerShell completion '$file'."
        }
    }
    foreach ($font in Get-OwnedDesktopFont @fontTarget) {
        if (($font.File -and -not $preview.Contains("  $previewLabel remove desktop font '$($font.Path)'.")) -or
            ($font.Registry -and -not $preview.Contains("value '$($font.Name)'."))) {
            throw "Uninstall preview omitted owned desktop font '$($font.Name)'."
        }
    }
    if ((Invoke-FixtureChezmoi -Arguments @('state', 'dump')).Stdout -cne $beforePreview) {
        throw 'The uninstall preview changed the chezmoi state.'
    }
    if ([IO.File]::ReadAllText($profilePath) -cne $baselineProfile -or -not [IO.File]::Exists($profileBody)) {
        throw 'The uninstall preview changed the destination.'
    }
    Assert-FixturePathUnchanged
    Update-HookPath -Managed
    $installedTools = @(
        Get-PathApplication -Name mise.exe | ForEach-Object Source
        Get-MiseProfileCommand -ConfigPath $miseConfig -ShimsDirectory $managedPath[0] | ForEach-Object Path
        Confirm-EcosystemTool -GoManifest (Join-Path $source 'bootstrap/manifests/ecosystem/go-tools.txt') `
            -UvManifest (Join-Path $source 'bootstrap/manifests/ecosystem/uv-tools.txt') | ForEach-Object Path
    )
    $completionNames = @(Read-CompletionManifest -Path $completionManifest)
    foreach ($tool in $installedTools) {
        $name = [IO.Path]::GetFileNameWithoutExtension($tool)
        if ($name -in $completionNames -and (Get-PowerShellCompletionArgument -Name $name) -and
            (Join-Path $completionDirectory "$name.ps1") -notin $ownedCompletions) {
            throw "Hook 55 missed the installed tool '$tool'."
        }
    }
    Assert-FixturePathUninstall -Options @{ Apply = $true; Config = $config; BackupRoot = $uninstallBackupRoot }
    Assert-FixtureCompletionUninstall -Owned $ownedCompletions -UserFile $unownedCompletion -UserBytes $unownedCompletionBytes
    $state = (Invoke-FixtureChezmoi -Arguments @('state', 'dump')).Stdout | ConvertFrom-Json -AsHashtable
    if ($state.scriptState.Count -or $state.entryState.Count) {
        throw 'Uninstall did not reset the chezmoi script and entry state.'
    }
    foreach ($target in @($gitConfig, $miseConfig, $profileBody, $profileEnvironment, $profileCompletionLoader, $sshConfig)) {
        if ([IO.File]::Exists($target)) {
            throw "Uninstall kept managed target '$target'."
        }
    }
    if ([IO.File]::Exists($terminalFragment)) {
        throw 'Uninstall kept the Terminal fragment.'
    }
    Assert-FixtureFontState -State $fontState -Target $fontTarget
    Confirm-WinGetPackage -ManifestPath @($packageManifestPath, (Join-Path $source 'bootstrap/manifests/desktop/winget-packages.json'))
    foreach ($tool in $installedTools) {
        if (-not [IO.File]::Exists($tool)) { throw "Uninstall removed the installed tool '$tool'." }
    }
    Write-Host 'WinGet packages, mise, runtimes, and Go and uv tools remained installed.'
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
        try {
            # Retain WinGet's executable directory in this process for diagnostics.
            if ($Mode -eq 'apply') { Update-HookPath -Managed }
        } finally {
            if ($null -ne $pathSnapshot) {
                Restore-FixturePathSnapshot -RegistryPath $pathTarget.RegistryPath -Snapshot $pathSnapshot
                Assert-FixturePathSnapshot -RegistryPath $pathTarget.RegistryPath -Expected $pathSnapshot
                if ([IO.File]::Exists($pathTarget.StatePath)) { [IO.File]::Delete($pathTarget.StatePath) }
                Send-UserPathChange
            } elseif ($pathTarget -and $Mode -eq 'smoke') {
                [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($pathTarget.RegistryPath, $false)
            }
        }
    } finally {
        try {
            if ($null -ne $fontState) {
                Restore-FixtureFontState -State $fontState -RegistryPath $fontTarget.RegistryPath
                if ([IO.File]::Exists($fontTarget.StatePath)) { [IO.File]::Delete($fontTarget.StatePath) }
                Assert-FixtureFontState -State $fontState -Target $fontTarget
            }
            if ($Mode -eq 'apply') { Write-FixturePhase4Diagnostic }
        } finally {
            try {
                if ($Mode -eq 'apply' -and $completionFilesTouched) {
                    foreach ($file in Get-OwnedPowerShellCompletion -Directory $completionDirectory) {
                        [IO.File]::Delete($file.FullName)
                    }
                    [IO.File]::Delete($unownedCompletion)
                    [IO.File]::Delete($completionProbe)
                }
                foreach ($file in $runnerFileState) {
                    if ($null -eq $file.Bytes) {
                        if ([IO.File]::Exists($file.Path)) { [IO.File]::Delete($file.Path) }
                    } else {
                        [IO.File]::WriteAllBytes($file.Path, $file.Bytes)
                        Set-Acl -LiteralPath $file.Path -AclObject $file.Acl
                    }
                }
            } finally {
                $env:GIT_CONFIG_GLOBAL = $originalGitGlobal
                $env:PATH = $originalPath
                foreach ($name in $originalToolEnvironment.Keys) {
                    [Environment]::SetEnvironmentVariable($name, $originalToolEnvironment[$name])
                }
                [IO.Directory]::Delete($fixture, $true)
            }
        }
    }
}
