[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Apply,
    [string]$Config,
    [string]$Destination = $HOME,
    [string]$ProfilePath = $PROFILE.CurrentUserAllHosts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'backup.ps1')
. (Join-Path $PSScriptRoot 'profile.ps1')
. (Join-Path $PSScriptRoot 'local-overlays.ps1')

if ($PSVersionTable.PSVersion -lt [version]'7.6') {
    throw "PowerShell 7.6 or later is required. Running $($PSVersionTable.PSVersion)."
}
if ([IO.Path]::GetFullPath($Destination) -ne [IO.Path]::GetFullPath($HOME) -and
    -not $PSBoundParameters.ContainsKey('ProfilePath')) {
    throw 'Specify -ProfilePath when using an alternate destination.'
}

$chezmoi = Get-Command -Name chezmoi -CommandType Application -ErrorAction Stop
$source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$manifest = Join-Path $source 'bootstrap/manifests/local-overlays.tsv'
$overlays = @(Read-LocalOverlay -Manifest $manifest)
$root = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Destination))
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

if (-not $Apply) {
    Write-Host "Would remove the managed line from '$ProfilePath' if present."
    foreach ($path in $candidates) {
        Write-Host "Would remove '$path'."
    }
    return
}
Remove-ManagedProfileLine -ProfilePath $ProfilePath -Destination $root
foreach ($path in $candidates) {
    if ($PSCmdlet.ShouldProcess($path, 'Remove managed file')) {
        [IO.File]::Delete($path)
        Write-Host "Removed '$path'."
    }
}
