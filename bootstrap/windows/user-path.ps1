Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) { throw 'User Path management requires native Windows.' }

function Get-HookUserPathTarget {
    param([string]$Destination, [string]$HomeDirectory)

    $registry = $env:OH_MY_DEVENV_WINDOWS_PATH_REGISTRY
    $state = $env:OH_MY_DEVENV_WINDOWS_PATH_STATE
    if ($registry -or $state -or (ConvertTo-PathKey $Destination) -cne (ConvertTo-PathKey $HomeDirectory)) {
        if (-not $registry -or -not $state) {
            throw 'Specify both OH_MY_DEVENV_WINDOWS_PATH_REGISTRY and OH_MY_DEVENV_WINDOWS_PATH_STATE for a Path fixture.'
        }
        return @{ RegistryPath = $registry; StatePath = $state }
    }
    @{ RegistryPath = 'Environment'; StatePath = Get-LocalBackupRoot -Name 'user-path.json' }
}

function Read-UserPath {
    param([Parameter(Mandatory)][string]$RegistryPath)

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RegistryPath)
    try {
        if ($null -eq $key -or 'Path' -notin $key.GetValueNames()) {
            return @{ Kind = $null; Value = $null }
        }
        $kind = $key.GetValueKind('Path')
        if ($kind -notin @('String', 'ExpandString')) {
            throw "Unsupported user Path value type '$kind' in HKCU\$RegistryPath."
        }
        @{ Kind = $kind; Value = $key.GetValue('Path', $null, 'DoNotExpandEnvironmentNames') }
    } finally {
        if ($null -ne $key) { $key.Dispose() }
    }
}

function Get-UserPathEntryKey {
    param([string]$Entry, [hashtable]$PathValue)

    if ($PathValue.Kind -eq 'ExpandString') {
        $Entry = [Environment]::ExpandEnvironmentVariables($Entry)
    }
    ConvertTo-PathKey -Path $Entry
}

function Get-MissingUserPathEntry {
    param([Parameter(Mandatory)][hashtable]$PathValue, [string[]]$Entries)

    $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in ($PathValue.Value -split ';')) {
        [void]$keys.Add((Get-UserPathEntryKey -Entry $entry -PathValue $PathValue))
    }
    foreach ($entry in $Entries) {
        if (-not [IO.Path]::IsPathFullyQualified($entry) -or $entry.Contains(';')) {
            throw "Managed Path entry '$entry' must be a fully qualified directory without semicolons."
        }
        $resolved = [IO.Path]::GetFullPath($entry)
        if ($keys.Add((ConvertTo-PathKey -Path $resolved))) { $resolved }
    }
}

function Read-UserPathRecord {
    param([Parameter(Mandatory)][string]$StatePath)

    try {
        $record = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($StatePath)) -NoEnumerate
    } catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] {
        return
    }
    if ($record -isnot [array] -or ($record | Where-Object {
        $_ -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($_) -or $_.Contains(';')
    })) {
        throw "Invalid managed user Path record '$StatePath'."
    }
    $record
}

function Send-UserPathChange {
    if (-not ('OhMyDevenv.EnvironmentChange' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace OhMyDevenv {
    public static class EnvironmentChange {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr window, uint message, UIntPtr wParam, string lParam,
            uint flags, uint timeout, out UIntPtr result);
    }
}
'@
    }
    $result = [UIntPtr]::Zero
    # HWND_BROADCAST, WM_SETTINGCHANGE, SMTO_ABORTIFHUNG.
    if ([OhMyDevenv.EnvironmentChange]::SendMessageTimeout(
        [IntPtr]0xffff, 0x001a, [UIntPtr]::Zero, 'Environment', 0x0002, 1000, [ref]$result) -eq [IntPtr]::Zero) {
        Write-LogWarn -Message 'Windows did not confirm the Environment notification. Restart applications to pick up the user Path.'
    }
}

function Add-ManagedUserPath {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by the authorized apply hook with an explicit user registry target.')]
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][string[]]$Entries,
        [scriptblock]$Notify = { Send-UserPathChange }
    )

    $before = Read-UserPath -RegistryPath $RegistryPath
    $missing = @(Get-MissingUserPathEntry -PathValue $before -Entries $Entries)
    if (-not $missing.Count) { return }

    $record = @(Read-UserPathRecord -StatePath $StatePath)
    $record += @($missing | Where-Object { $_ -cnotin $record })
    $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($StatePath))
    [void][IO.Directory]::CreateDirectory($directory)
    $temporary = Join-Path $directory ([IO.Path]::GetRandomFileName())
    $kind = $before.Kind ?? [Microsoft.Win32.RegistryValueKind]::ExpandString
    $newValue = if ($before.Value) { $before.Value + ';' + ($missing -join ';') } else { $missing -join ';' }
    try {
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $record -Compress))
        # Keep ownership if the process stops after the registry write. A retry adds any entries still missing.
        [IO.File]::Move($temporary, $StatePath, $true)
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($RegistryPath)
        try {
            $key.SetValue('Path', $newValue, $kind)
        } finally {
            $key.Dispose()
        }
    } finally {
        [IO.File]::Delete($temporary)
    }
    & $Notify
}

function Get-UserPathRemoval {
    param([Parameter(Mandatory)][string]$RegistryPath, [Parameter(Mandatory)][string]$StatePath)

    $before = Read-UserPath -RegistryPath $RegistryPath
    $record = @(Read-UserPathRecord -StatePath $StatePath)
    $remaining = [Collections.Generic.List[string]]::new()
    $remaining.AddRange([string[]]($before.Value -split ';'))
    $removed = @(foreach ($entry in $record) {
        # Remove one exact occurrence. A differently spelled or expanded entry is user-owned.
        if ($remaining.Remove($entry)) { $entry }
    })
    @{ Entries = $removed; Value = $remaining -join ';'; Kind = $before.Kind }
}

function Remove-ManagedUserPath {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The Windows uninstaller gates the change with ShouldProcess.')]
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)][string]$StatePath,
        [scriptblock]$Notify = { Send-UserPathChange }
    )

    $removal = Get-UserPathRemoval -RegistryPath $RegistryPath -StatePath $StatePath
    if ($removal.Entries.Count) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RegistryPath, $true)
        try { $key.SetValue('Path', $removal.Value, $removal.Kind) }
        finally { $key.Dispose() }
        & $Notify
    }
    try { [IO.File]::Delete($StatePath) } catch [IO.DirectoryNotFoundException] { return }
}
