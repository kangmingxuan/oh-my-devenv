Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-LocalOverlay {
    param([string]$Manifest)

    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $examples = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $locations = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $lineNumber = 0
    foreach ($line in [IO.File]::ReadLines($Manifest)) {
        $lineNumber++
        if ($line -match '^#|^\s*$') {
            continue
        }
        $fields = $line.Split([char]9)
        if ($fields.Count -ne 4) {
            throw "Expected four overlay fields on row ${lineNumber}: '$Manifest'."
        }
        $id, $example, $location, $match = $fields
        $hasGlob = $location -match '[*?\[]'
        if ($id -cnotmatch '^[a-z][a-z0-9_]*$' -or $example -cnotmatch '\.example$' -or
            $location -cnotmatch '^\$(HOME|XDG_CONFIG_HOME)/' -or
            $match -cnotin @('exact', 'glob') -or ($match -ceq 'glob') -ne $hasGlob) {
            throw "Invalid overlay on row ${lineNumber}: '$Manifest'."
        }
        if (-not ($ids.Add($id) -and $examples.Add($example) -and $locations.Add($location))) {
            throw "Duplicate overlay ID, example, or location on row ${lineNumber}: '$Manifest'."
        }
        @{
            Location = $location
            Match = $match
        }
    }
    if ($ids.Count -eq 0) {
        throw "Local overlay inventory is empty: '$Manifest'."
    }
}

function Test-LocalOverlay {
    param([string]$RelativePath, [hashtable[]]$Overlays)

    $relative = $RelativePath.Replace('\', '/')
    foreach ($overlay in $Overlays) {
        $location = $overlay.Location -creplace '^\$HOME/', '' -creplace '^\$XDG_CONFIG_HOME/', '.config/'
        if (($overlay.Match -eq 'exact' -and $relative -eq $location) -or
            ($overlay.Match -eq 'glob' -and $relative -like $location)) {
            return $true
        }
    }
    $false
}
