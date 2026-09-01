$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'quality/Test-CanonicalContract.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot
$fixtureRoot = Join-Path $repoRoot 'test/fixtures/contracts'

function Read-Fixture([string]$Name) {
    $path = Join-Path $fixtureRoot $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Fixture missing: $path" }
    return Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json
}

$unresolved = Test-CanonicalContract -Value (Read-Fixture 'bad-unresolved.json')
if ($unresolved.passed -or -not @($unresolved.findings.code).Contains('UNRESOLVED_RAW_TOKEN')) {
    throw 'Unresolved token fixture was not rejected.'
}

$pseudo = Test-CanonicalContract -Value (Read-Fixture 'bad-pseudo-value.json')
if ($pseudo.passed -or -not @($pseudo.findings.code).Contains('PSEUDO_VALUE_IN_DESCRIPTION')) {
    throw 'Pseudo value fixture was not rejected.'
}

$nullArray = Test-CanonicalContract -Value (Read-Fixture 'bad-null-array.json') -RequiredArrayPaths @('compositions')
if ($nullArray.passed -or -not @($nullArray.findings.code).Contains('ARRAY_CONTRACT_NULL_OR_NON_ARRAY')) {
    throw 'Null array fixture was not rejected.'
}

$goodArray = Test-CanonicalContract -Value (Read-Fixture 'good-empty-array.json') -RequiredArrayPaths @('compositions')
if (-not $goodArray.passed) {
    throw "Valid empty array fixture failed: $($goodArray.findings | ConvertTo-Json -Compress)"
}

Write-Output 'Canonical quality fixture tests passed.'
