Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '../../dot_config/oh-my-devenv/powershell/completions.ps1')

function Get-CompletionLocalData {
    param([string]$Destination, [string]$HomeDirectory = $HOME)

    # A disposable apply uses its own LocalAppData tree, including shipped assets.
    if ((ConvertTo-PathKey $Destination) -cne (ConvertTo-PathKey $HomeDirectory)) {
        return Join-Path $Destination 'AppData/Local'
    }
    $localData = [Environment]::GetFolderPath('LocalApplicationData')
    if (-not $localData) { throw 'Windows did not resolve the LocalApplicationData known folder.' }
    $localData
}

function Read-CompletionManifest {
    param([Parameter(Mandatory)][string]$Path)

    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    # Close the file before validation can throw.
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $name = ($line -replace '#.*$').Trim()
        if (-not $name) { continue }
        if ($name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.+-]*$') {
            throw "Invalid completion command name in '$Path': '$name'."
        }
        if (-not $seen.Add($name)) { throw "Duplicate completion command in '$Path': '$name'." }
        $name
    }
}

function Get-PowerShellCompletionArgument {
    param([string]$Name)

    switch ($Name) {
        { $_ -in 'uv', 'ruff' } { 'generate-shell-completion'; 'powershell' }
        'uvx' { '--generate-shell-completion'; 'powershell' }
        { $_ -in 'chezmoi', 'golangci-lint', 'dlv', 'mise' } { 'completion'; 'powershell' }
        'bat' { '--completion'; 'ps1' }
        default { throw "Unsupported completion generator: '$Name'." }
    }
}

function Get-PowerShellCompletionSource {
    param([string]$Name, [string]$LocalData)

    $arguments = @(Get-PowerShellCompletionArgument -Name $Name)
    $command = Get-PathApplication -Name $Name -Optional
    if (-not $command) {
        Write-LogSkip "PowerShell completion for '$Name': application is not on PATH."
        return
    }
    # This is the upstream mise --install location on Windows. PowerShell
    # needs an explicit loader, so copy the asset to the owned directory.
    $shipped = Join-Path $LocalData "PowerShell/completions/$Name.ps1"
    if (Test-Path -LiteralPath $shipped -PathType Leaf) {
        return @{ Shipped = $shipped }
    }
    @{ Application = $command; Arguments = $arguments }
}

function Invoke-PowerShellCompletion {
    param(
        [Parameter(Mandatory)][ValidateSet('install', 'check', 'list')][string]$Action,
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$LocalData,
        [ValidatePattern('^[0-9a-f]{64}$', Options = 'None')][string]$Fingerprint
    )

    if ($Action -eq 'install' -and -not $Fingerprint) {
        throw 'A completion input fingerprint is required for install.'
    }
    $names = @(Read-CompletionManifest -Path $ManifestPath)
    $directory = Get-PowerShellCompletionDirectory -LocalData $LocalData
    if ($Action -eq 'list') {
        Get-OwnedPowerShellCompletion -Directory $directory | ForEach-Object FullName
        return
    }

    $targets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $missing = 0
    foreach ($name in $names) {
        $source = Get-PowerShellCompletionSource -Name $name -LocalData $LocalData
        if (-not $source) { continue }
        $target = Join-Path $directory "$name.ps1"
        [void]$targets.Add($target)
        if ($Action -eq 'check') {
            if ((Test-OwnedPowerShellCompletion -Path $target) -and
                (Get-Content -LiteralPath $target -TotalCount 2 | Select-Object -Skip 1)) {
                Write-LogOk $name "PowerShell completion: $target"
            } else {
                Write-LogMissing $name "Owned PowerShell completion: $target"
                $missing++
            }
            continue
        }
        $item = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        if ($item) {
            if (Test-OwnedPowerShellCompletion -Path $target -Fingerprint $Fingerprint) { continue }
            if (-not (Test-OwnedPowerShellCompletion -Path $target)) {
                throw "Refusing to overwrite unowned PowerShell completion '$target'."
            }
        }

        $content = if ($source.ContainsKey('Shipped')) {
            [IO.File]::ReadAllText($source.Shipped)
        } else {
            (Invoke-NativeCommand -Executable $source.Application.Source -Arguments $source.Arguments `
                -WorkingDirectory "$env:SystemDrive/" -TimeoutSeconds 30).Stdout
        }
        if ([string]::IsNullOrWhiteSpace($content)) {
            throw "Empty PowerShell completion for '$name'."
        }
        $tokens = $parseErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count) {
            throw "Invalid PowerShell completion for '$name': $($parseErrors[0].Message)"
        }

        [void][IO.Directory]::CreateDirectory($directory)
        $temporary = Join-Path $directory ([IO.Path]::GetRandomFileName())
        try {
            $content = $content.TrimStart()
            [IO.File]::WriteAllText($temporary, "# oh-my-devenv: generated by install-shell-completions.ps1; sha256=$Fingerprint`n$content")
            [IO.File]::Move($temporary, $target, [bool]$item)
        } finally {
            [IO.File]::Delete($temporary)
        }
        Write-LogOk $name "Installed PowerShell completion: $target"
    }
    foreach ($file in Get-OwnedPowerShellCompletion -Directory $directory) {
        if ($targets.Contains($file.FullName)) { continue }
        if ($Action -eq 'check') {
            Write-LogMissing $file.BaseName "stale: $($file.FullName)"
            $missing++
        } elseif (Test-OwnedPowerShellCompletion -Path $file.FullName) {
            [IO.File]::Delete($file.FullName)
            Write-LogOk removed "obsolete PowerShell completion: $($file.FullName)"
        }
    }
    if ($missing) { throw "PowerShell completion check found $($missing) missing or stale files." }
}
