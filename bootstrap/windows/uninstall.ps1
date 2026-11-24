<#
.SYNOPSIS
Preview or remove managed Windows configuration.

.DESCRIPTION
Close editors and wait for running Git commands to finish before uninstall because the pre-delete backup holds the content seen when it ran.

.PARAMETER Apply
Back up candidates, remove the managed configuration and recorded assets and user Path entries, and reset chezmoi script and entry state.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Apply,
    [string]$Config,
    [string]$Destination = $HOME,
    [string]$ProfilePath = $PROFILE.CurrentUserAllHosts,
    [string]$BackupRoot,
    [string]$RegistryPath,
    [string]$StatePath,
    [hashtable]$FontTarget
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')

trap {
    Write-BootstrapFailure -Failure $_
    exit (Get-BootstrapExitCode -Failure $_)
}

if (-not $IsWindows) {
    throw 'The Windows uninstaller requires a Windows host.'
}

. (Join-Path $PSScriptRoot 'backup.ps1')
. (Join-Path $PSScriptRoot 'profile.ps1')
. (Join-Path $PSScriptRoot 'local-overlays.ps1')
. (Join-Path $PSScriptRoot 'user-path.ps1')
. (Join-Path $PSScriptRoot 'desktop.ps1')
. (Join-Path $PSScriptRoot 'completions.ps1')

if ($PSVersionTable.PSVersion -lt [version]'7.6') {
    throw "PowerShell 7.6 or later is required. Running $($PSVersionTable.PSVersion)."
}
$pathTarget = if ($RegistryPath -or $StatePath) {
    if (-not $RegistryPath -or -not $StatePath) { throw 'Specify both -RegistryPath and -StatePath.' }
    @{ RegistryPath = $RegistryPath; StatePath = $StatePath }
} else {
    Get-HookUserPathTarget -Destination $Destination -HomeDirectory $HOME
}
$pathRemoval = Get-UserPathRemoval @pathTarget
if ([IO.Path]::GetFullPath($Destination) -ne [IO.Path]::GetFullPath($HOME)) {
    if (-not $PSBoundParameters.ContainsKey('ProfilePath') -or ($Apply -and (-not $BackupRoot -or -not $Config))) {
        throw 'For alternate destinations, specify -ProfilePath. With -Apply, also pass -BackupRoot and the -Config used for apply.'
    }
}

$chezmoi = Get-PathApplication -Name chezmoi
$source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$manifest = Join-Path $source 'bootstrap/manifests/local-overlays.tsv'
$overlays = @(Read-LocalOverlay -Manifest $manifest)
$root = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Destination))
$localData = Get-CompletionLocalData -Destination $root
$completionManifest = Join-Path $source 'bootstrap/manifests/shell/completions.txt'
$completionFiles = @(Invoke-PowerShellCompletion -Action list -ManifestPath $completionManifest -LocalData $localData)
if (-not $FontTarget -and (ConvertTo-PathKey $root) -ceq (ConvertTo-PathKey $HOME)) {
    $FontTarget = Get-DesktopFontTarget -LocalData $localData
}
$fonts = @(if ($FontTarget) { Get-OwnedDesktopFont @FontTarget })
$prefix = $root + [IO.Path]::DirectorySeparatorChar
$paths = @(Get-ManagedFile -Executable $chezmoi.Source -Config $Config -Source $source -Destination $root)

# Validate the full candidate list before editing the profile or removing files.
$candidates = foreach ($path in $paths) {
    $fullPath = [IO.Path]::GetFullPath($path)
    if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Managed path '$path' escapes '$root'."
    }
    if (Test-LocalOverlay -RelativePath $fullPath.Substring($prefix.Length) -Overlays $overlays) {
        throw "Managed path '$path' overlaps a user-owned overlay."
    }
    for ($parent = [IO.Path]::GetDirectoryName($fullPath); $parent -ne $root; $parent = [IO.Path]::GetDirectoryName($parent)) {
        if ((Get-FileAttribute -Path $parent) -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing to remove '$path' through reparse point '$parent'."
        }
    }
    $attributes = Get-FileAttribute -Path $fullPath
    if ($null -eq $attributes) {
        continue
    }
    if ($attributes -band [IO.FileAttributes]::Directory) {
        throw "Expected a file, found a directory at '$fullPath'."
    }
    $fullPath
}

$stateBuckets = @('scriptState', 'entryState')
if (-not $Apply) {
    Write-LogPhase -Message 'Uninstall preview'
    Write-LogWould -Action remove -Target "the managed line from '$ProfilePath' if present."
    foreach ($path in @($candidates; $completionFiles)) {
        Write-LogWould -Action remove -Target "'$path'."
    }
    foreach ($font in $fonts) {
        if ($font.File) { Write-LogWould -Action remove -Target "desktop font '$($font.Path)'." }
        if ($font.Registry) { Write-LogWould -Action remove -Target "HKCU\$($FontTarget.RegistryPath) value '$($font.Name)'." }
    }
    if ($FontTarget -and [IO.File]::Exists($FontTarget.StatePath)) {
        Write-LogWould -Action remove -Target "desktop font record '$($FontTarget.StatePath)'."
    }
    foreach ($entry in $pathRemoval.Entries) {
        Write-LogWould -Action remove -Target "user Path entry '$entry'."
    }
    if ([IO.File]::Exists($pathTarget.StatePath)) {
        Write-LogWould -Action remove -Target "user Path record '$($pathTarget.StatePath)'."
    }
    foreach ($bucket in $stateBuckets) {
        Write-LogWould -Action reset -Target "chezmoi state bucket '$bucket'."
    }
    Write-LogPhaseDone
    Write-LogSummary -Message 'Dry-run complete. No files were deleted.'
    exit 0
}
$profileFile = Resolve-RegularFile -Path $ProfilePath
$removeProfileLine = $null -ne $profileFile -and
    (Read-ProfileFile -Path $profileFile.FullName).Content -cmatch (Get-ManagedProfilePattern -Destination $root)
$backupCandidates = @($candidates | Where-Object { $_ }) + $completionFiles +
    @($fonts | Where-Object File | ForEach-Object Path)
if ($removeProfileLine) {
    $backupCandidates += $ProfilePath
}
if (-not $PSCmdlet.ShouldProcess($root, 'Back up and remove Windows configuration and reset chezmoi state')) {
    exit 0
}
Write-LogPhase -Message 'Uninstalling the baseline...'
if ($backupCandidates.Count) {
    if (-not $BackupRoot) {
        $BackupRoot = Get-LocalBackupRoot -Name 'chezmoi-uninstall-backup'
    }
    $backupRun = Backup-ExistingFile -Paths $backupCandidates -BackupRoot $BackupRoot -BeforeUninstall -PassThru
    if ($removeProfileLine) {
        $profileBackup = Get-BackupPath -Path $ProfilePath -RunDirectory $backupRun
        Remove-ManagedProfileLine -ProfilePath $ProfilePath -Destination $root -BackupPath $profileBackup -Confirm:$false
    }
}
foreach ($path in $candidates) {
    [IO.File]::Delete($path)
    Write-LogOk -Name removed -Detail "'$path'."
}
foreach ($path in $completionFiles) {
    if (Test-OwnedPowerShellCompletion -Path $path) {
        [IO.File]::Delete($path)
        Write-LogOk -Name removed -Detail "'$path'."
    }
}
if ($FontTarget) { Remove-OwnedDesktopFont @FontTarget }
if ($pathTarget.RegistryPath -ne 'Environment') {
    Remove-ManagedUserPath @pathTarget -Notify {}
} else {
    Remove-ManagedUserPath @pathTarget
}

# Use the state database selected by the apply configuration.
foreach ($bucket in $stateBuckets) {
    $null = Invoke-NativeCommand -Executable $chezmoi.Source -Arguments @(
        "--config=$Config", "--source=$source", "--destination=$root", 'state', 'delete-bucket', "--bucket=$bucket"
    )
    Write-LogOk -Name reset -Detail "chezmoi state bucket '$bucket'."
}
Write-LogPhaseDone
Write-LogSummary -Message 'Uninstall finished. Source checkout kept.'
Write-LogNext -Message 'Re-run chezmoi apply to restore the baseline.'
exit 0
