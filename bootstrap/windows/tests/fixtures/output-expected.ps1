Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-OutputGolden {
    $fixture = Join-Path $PSScriptRoot '../../../tests/fixtures/cli-output.tsv'
    foreach ($line in Get-Content -LiteralPath $fixture) {
        if ($line.StartsWith('#')) { continue }
        $mode, $stream, $level, $bytes = $line -split "`t", 4
        @{
            Mode = $mode; Stream = $stream; Level = $level
            Bytes = $bytes.Replace('\033', "`e").Replace('\n', "`n")
        }
    }
}
