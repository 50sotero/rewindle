#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$verifier = Join-Path $projectRoot 'src\verify_my_drive_cloud_repository.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $verifier,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -ne 0) {
    throw 'The direct-cloud verifier did not parse before timestamp-function extraction.'
}
$wanted = @(
    'ConvertTo-ResticSnapshotSortKey',
    'Get-ResticSnapshotListingFromJson'
)
$definitions = @(
    $ast.FindAll(
        {
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -in $wanted
        },
        $true
    ) |
        Sort-Object { $wanted.IndexOf($_.Name) } |
        ForEach-Object { $_.Extent.Text }
)
if ($definitions.Count -ne $wanted.Count) {
    throw 'The timestamp parser functions could not be extracted exactly.'
}
. ([scriptblock]::Create(($definitions -join [Environment]::NewLine)))

$script:assertions = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)

    $script:assertions++
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-FailsClosed {
    param(
        [Parameter(Mandatory)] [scriptblock]$Action,
        [Parameter(Mandatory)] [string]$Message
    )

    $script:assertions++
    $failure = $null
    try {
        [void](& $Action)
    }
    catch {
        $failure = $_.Exception.Message
    }
    if ([string]::IsNullOrWhiteSpace($failure)) {
        throw "Assertion failed: $Message"
    }
}

$idA = 'a' * 64
$idB = 'b' * 64
$idC = 'c' * 64
$idD = 'd' * 64
$multiItemJson = @"
[
  {"id":"$idA","time":"2026-07-29T03:00:00.123456789+02:00"},
  {"id":"$idB","time":"2026-07-29T01:00:00.12345678Z"},
  {"id":"$idC","time":"2026-07-28T20:30:00.123456789-04:30"},
  {"id":"$idD","time":"2026-07-29T01:00:00.123456790Z"}
]
"@
$listing = Get-ResticSnapshotListingFromJson -Json $multiItemJson
Assert-True ($listing.count -eq 4) (
    'Windows PowerShell 5.1 must unroll every top-level snapshot-array item.'
)
Assert-True (
    [string[]]$listing.latest_snapshot_ids -contains $idD
) 'The ninth fractional digit must participate in latest-snapshot ordering.'
Assert-True (
    [string[]]$listing.latest_snapshot_ids -notcontains $idA
) 'A snapshot one nanosecond older must not tie after seven .NET digits.'

$offsetTie = Get-ResticSnapshotListingFromJson -Json @"
[
  {"id":"$idA","time":"2026-07-29T03:00:00.000000001+02:00"},
  {"id":"$idB","time":"2026-07-28T20:30:00.000000001-04:30"}
]
"@
Assert-True (
    $offsetTie.latest_snapshot_ids.Count -eq 2
) 'Equivalent RFC3339 offsets must normalize to the same UTC nanosecond.'

$eightDigits = ConvertTo-ResticSnapshotSortKey `
    -Value '2026-07-29T01:00:00.12345678Z'
$nineDigits = ConvertTo-ResticSnapshotSortKey `
    -Value '2026-07-29T01:00:00.123456789Z'
Assert-True (
    $eightDigits.utc_ticks -eq $nineDigits.utc_ticks -and
    $eightDigits.sub_tick_nanoseconds -eq 80 -and
    $nineDigits.sub_tick_nanoseconds -eq 89
) 'Eight- and nine-digit fractions must retain their exact nanosecond ordering.'

$malformedJsonCases = @(
    '{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","time":"2026-07-29T01:00:00Z"}',
    '[]',
    '[null]',
    '[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]',
    '[{"time":"2026-07-29T01:00:00Z"}]',
    '[{"id":42,"time":"2026-07-29T01:00:00Z"}]',
    '[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","time":42}]',
    '[{"id":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","time":"2026-07-29T01:00:00Z"}]',
    ('[{"id":"' + $idA + '","time":"2026-07-29T01:00:00Z"},' +
        '{"id":"' + $idA + '","time":"2026-07-29T02:00:00Z"}]')
)
foreach ($json in $malformedJsonCases) {
    Assert-FailsClosed `
        -Action { Get-ResticSnapshotListingFromJson -Json $json } `
        -Message 'Malformed snapshot JSON must fail closed.'
}

$malformedTimestampCases = @(
    '2026-07-29T01:00:00',
    '2026-07-29 01:00:00Z',
    '2026-07-29T01:00:00.Z',
    '2026-07-29T01:00:00.1234567890Z',
    '2026-02-29T01:00:00Z',
    '2026-07-29T24:00:00Z',
    '2026-07-29T01:00:60Z',
    '2026-07-29T01:00:00+14:30',
    ' 2026-07-29T01:00:00Z',
    '2026-07-29T01:00:00z'
)
foreach ($timestamp in $malformedTimestampCases) {
    Assert-FailsClosed `
        -Action { ConvertTo-ResticSnapshotSortKey -Value $timestamp } `
        -Message "Malformed timestamp must fail closed: $timestamp"
}

$verifierText = [IO.File]::ReadAllText($verifier)
Assert-True (
    $verifierText -match "@\('snapshots', '--json'\)"
) 'The verifier must obtain the direct-cloud snapshot listing read-only.'
Assert-True (
    $verifierText -match 'direct_cloud_latest_snapshot_verified = \$true'
) 'The immutable proof must record successful latest-snapshot verification.'

[ordered]@{
    schema_version = 1
    assertions = $script:assertions
    powershell_version = $PSVersionTable.PSVersion.ToString()
    top_level_array_normalization = 'passed'
    nanosecond_ordering = 'passed'
    offset_normalization = 'passed'
    malformed_inputs_fail_closed = 'passed'
} | ConvertTo-Json -Compress
