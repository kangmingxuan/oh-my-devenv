Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-MiseUserPathWarning {
    param([hashtable]$PathValue, [string]$ShimsDirectory)

    try {
        # mise defaults to installs under its resolved data directory, unless overridden at startup.
        $root = $env:MISE_INSTALLS_DIR
        if (-not $root) {
            $result = Invoke-GlobalMise -Arguments @('doctor', '--json') -AllowFailure
            # Doctor can report valid directory data and exit 1 for an unrelated diagnostic.
            if ($result.ExitCode -notin 0, 1) { return }
            $dataDirectory = (ConvertFrom-Json -InputObject $result.Stdout -AsHashtable)['dirs']['data']
            if ($dataDirectory -isnot [string] -or [string]::IsNullOrWhiteSpace($dataDirectory)) { return }
            $root = [IO.Path]::Combine($dataDirectory, 'installs')
        } elseif ($root -match '^~[\\/]') {
            $root = $HOME + $root.Substring(1)
        }
        $root = if ([IO.Path]::IsPathFullyQualified($root)) {
            [IO.Path]::GetFullPath($root)
        } else {
            # Match the working directory used by Invoke-GlobalMise.
            [IO.Path]::GetFullPath($root, "$env:SystemDrive\")
        }
        $prefix = (ConvertTo-PathKey -Path $root) + '/'
    } catch {
        # This advisory requires a reliable root. The required checks will still run.
        return
    }

    $shimsKey = ConvertTo-PathKey -Path $ShimsDirectory
    foreach ($entry in ($PathValue.Value -split ';')) {
        $path = $entry.Trim('"')
        if ($PathValue.Kind -eq 'ExpandString') {
            $path = [Environment]::ExpandEnvironmentVariables($path)
        }
        if (-not [IO.Path]::IsPathFullyQualified($path)) { continue }
        try {
            $key = ConvertTo-PathKey -Path ([IO.Path]::GetFullPath($path))
        } catch [ArgumentException], [NotSupportedException], [IO.IOException] {
            continue
        }
        if ($key -cne $shimsKey -and $key.StartsWith($prefix, [StringComparison]::Ordinal)) {
            Write-LogWarn -Message "User Path entry points into a mise tool installation: '$entry'."
            Write-LogDetail -Message 'Remove this entry from the user Path. The managed mise shims already provide the tool.'
        }
    }
}
