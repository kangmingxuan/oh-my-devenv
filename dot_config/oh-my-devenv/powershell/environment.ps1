Set-StrictMode -Version Latest

function Get-PathApplication {
    param([string]$Name, [switch]$Optional)

    $application = Get-Command -Name $Name -CommandType Application -TotalCount 1 -ErrorAction SilentlyContinue
    if ($null -eq $application -and -not $Optional) {
        throw "Application '$Name' was not found on PATH."
    }
    $application
}

function ConvertTo-PathKey {
    param([string]$Path)

    ($Path.Trim('"') -replace '[\\/]+', '/').TrimEnd('/').ToUpperInvariant()
}

function Get-ManagedProfilePathEntry {
    $localData = [Environment]::GetFolderPath('LocalApplicationData')
    if (-not $localData) {
        throw 'Windows did not resolve the LocalApplicationData known folder.'
    }
    $goPath = $env:GOPATH
    if (-not $goPath) {
        $goPath = Join-Path $HOME 'go'
    }
    $goBin = $env:GOBIN
    if (-not $goBin) {
        $goBin = Join-Path $goPath 'bin'
    }
    Join-Path $localData 'mise/shims'
    Join-Path $HOME '.local/bin'
    $goBin
}
