[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester shares BeforeAll variables with the individual tests.')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    . (Join-Path $PSScriptRoot '../common.ps1')
    . (Join-Path $PSScriptRoot 'fixtures/output-expected.ps1')
    $harness = Join-Path $PSScriptRoot 'fixtures/output-harness.ps1'
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    $golden = @(Read-OutputGolden)

    function Read-GoldenStream {
        param([string]$Mode, [string]$Stream)
        ($golden | Where-Object { $_.Mode -ceq $Mode -and $_.Stream -ceq $Stream } |
            ForEach-Object { $_.Bytes }) -join ''
    }

    function Invoke-OutputHarness {
        param(
            [string]$Case = 'Sample',
            [string]$Terminals = 'actual',
            [int]$Columns = 80,
            [string]$Rendering = 'Ansi',
            [hashtable]$Variables = @{}
        )
        $environment = @{
            CI = $null; NO_COLOR = $null; NO_LOGO = $null
            TERM = 'xterm'; COLORTERM = $null; WT_SESSION = $null
        }
        foreach ($key in $Variables.Keys) { $environment[$key] = $Variables[$key] }
        Invoke-NativeCommand -Executable $pwsh -Arguments @(
            '-NoLogo', '-NoProfile', '-File', $harness, '-Case', $Case, '-Terminals', $Terminals,
            '-Columns', [string]$Columns, '-Rendering', $Rendering
        ) -Environment $environment -AllowFailure -TimeoutSeconds 30
    }

    function Assert-GoldenStreams {
        param([hashtable]$Result, [string]$Stdout, [string]$Stderr)
        $Result.ExitCode | Should -Be 0
        ($Result.Stdout -creplace '\r\n', "`n") | Should -BeExactly (Read-GoldenStream $Stdout stdout)
        ($Result.Stderr -creplace '\r\n', "`n") | Should -BeExactly (Read-GoldenStream $Stderr stderr)
    }
}

Describe 'PowerShell CLI output' {
    It 'matches the golden streams with both native handles redirected' {
        Assert-GoldenStreams (Invoke-OutputHarness) plain plain
    }

    It 'selects each stream independently when the terminal probe reports <Terminals>' -ForEach @(
        @{ Terminals = 'both'; Stdout = 'rich'; Stderr = 'rich' }
        @{ Terminals = 'stdout'; Stdout = 'rich'; Stderr = 'plain' }
        @{ Terminals = 'stderr'; Stdout = 'plain'; Stderr = 'rich' }
    ) {
        Assert-GoldenStreams (Invoke-OutputHarness -Terminals $Terminals) $Stdout $Stderr
    }

    It 'uses plain output with <Name> even when both streams are terminal streams' -ForEach @(
        @{ Name = 'NO_COLOR'; Variables = @{ NO_COLOR = 'anything' }; Rendering = 'Ansi' }
        @{ Name = 'CI'; Variables = @{ CI = 'anything' }; Rendering = 'Ansi' }
        @{ Name = 'TERM=dumb'; Variables = @{ TERM = 'dumb' }; Rendering = 'Ansi' }
        @{ Name = 'PSStyle PlainText'; Variables = @{}; Rendering = 'PlainText' }
    ) {
        Assert-GoldenStreams (Invoke-OutputHarness -Terminals both -Variables $Variables -Rendering $Rendering) plain plain
    }

    It 'renders the shared <Art> banner with <Name>' -ForEach @(
        @{ Art = 'wide'; Name = 'truecolor'; Variables = @{ COLORTERM = 'truecolor' }; TrueColor = $true }
        @{ Art = 'narrow'; Name = 'COLORTERM=24bit'; Variables = @{ COLORTERM = '24bit' }; TrueColor = $true }
        @{ Art = 'wide'; Name = 'WT_SESSION'; Variables = @{ WT_SESSION = 'fixture' }; TrueColor = $true }
        @{ Art = 'wide'; Name = 'empty WT_SESSION'; Variables = @{ WT_SESSION = '' }; TrueColor = $true }
        @{ Art = 'narrow'; Name = '16 colors'; Variables = @{}; TrueColor = $false }
        @{ Art = 'wide'; Name = 'NO_COLOR'; Variables = @{ NO_COLOR = 'anything' }; TrueColor = $false }
    ) {
        $assets = Join-Path $PSScriptRoot '../../assets'
        $wide = Get-Content -LiteralPath (Join-Path $assets 'banner-wide.txt')
        $width = ($wide | Measure-Object -Property Length -Maximum).Maximum
        $columns = if ($Art -ceq 'wide') { $width + 2 } else { $width + 1 }
        $artLines = Get-Content -LiteralPath (Join-Path $assets "banner-$Art.txt")
        $artWidth = ($artLines | Measure-Object -Property Length -Maximum).Maximum
        $expected = @($artLines) + @(
            'bootstrap your dev env at lightning speed'.PadLeft($artWidth)
            'Fixture OS, arm64'.PadLeft($artWidth)
            ''
            ''
        )
        $result = Invoke-OutputHarness -Case Banner -Terminals stdout -Columns $columns -Variables $Variables
        $result.ExitCode | Should -Be 0
        $result.Stderr | Should -BeExactly ''
        ($result.Stdout -creplace '\r\n', "`n" -creplace "`e\[[0-9;]+m", '') |
            Should -BeExactly ($expected -join "`n")
        $result.Stdout | Should -Not -Match "`e\[(35|38;2;[0-9;]+)m "
        if ($Variables.ContainsKey('NO_COLOR')) {
            $result.Stdout | Should -Not -Match "`e"
        } else {
            $result.Stdout | Should -Match "`e\[2mbootstrap your dev env at lightning speed"
            if ($TrueColor) {
                $result.Stdout | Should -Match "`e\[38;2;255;95;175m"
                $result.Stdout | Should -Match "`e\[38;2;175;135;255m"
            } else {
                $result.Stdout | Should -Match "`e\[35m"
                $result.Stdout | Should -Not -Match "`e\[38;2;"
            }
        }
    }

    It 'hides the banner with <Name>' -ForEach @(
        @{ Name = 'NO_LOGO'; Terminals = 'stdout'; Variables = @{ NO_LOGO = '1' } }
        @{ Name = 'CI'; Terminals = 'stdout'; Variables = @{ CI = 'anything' } }
        @{ Name = 'stdout redirected'; Terminals = 'actual'; Variables = @{} }
    ) {
        $result = Invoke-OutputHarness -Case Banner -Terminals $Terminals -Variables $Variables
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -BeExactly ''
        $result.Stderr | Should -BeExactly ''
    }

    It 'renders captured child failures as error details and exits with the child status' {
        $result = Invoke-OutputHarness -Case Failure
        $result.ExitCode | Should -Be 7
        $result.Stdout | Should -BeExactly ''
        $result.Stderr | Should -Match '\[error\].*exited with code 7\.'
        $result.Stderr | Should -Match '(?m)^ {4}probe stdout\r?$'
        $result.Stderr | Should -Match '(?m)^ {4}probe stderr\r?$'
    }

    It 'keeps a successful short probe private' {
        $result = Invoke-OutputHarness -Case Probe
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -BeExactly ''
        $result.Stderr | Should -BeExactly ''
    }

    It 'streams native output on the original streams and preserves failure status' {
        $result = Invoke-OutputHarness -Case Live
        $result.ExitCode | Should -Be 7
        $result.Stdout.TrimEnd() | Should -BeExactly 'probe stdout'
        $result.Stderr | Should -Match '(?m)^probe stderr\r?$'
        $result.Stderr | Should -Match '\[error\].*exited with code 7\.'
    }

    It 'enforces the native timeout when output is streamed' {
        $result = Invoke-OutputHarness -Case Timeout
        $result.ExitCode | Should -Be 1
        $result.Stderr | Should -Match '\[error\].*did not finish within 1 seconds'
    }
}
