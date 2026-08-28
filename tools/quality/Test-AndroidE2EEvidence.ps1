param(
    [Parameter(Mandatory = $true)][string]$EvidencePath,
    [Parameter(Mandatory = $true)][string]$ReleaseId,
    [int]$MaximumEvidenceAgeHours = 24
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$resolvedEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
if (-not (Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf)) {
    throw "ANDROID_E2E_EVIDENCE_MISSING path=$resolvedEvidencePath"
}
try {
    $evidence = Get-Content -Raw -Encoding UTF8 -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
} catch {
    throw "ANDROID_E2E_EVIDENCE_INVALID_JSON path=$resolvedEvidencePath"
}
if ([int]$evidence.schemaVersion -ne 1) { throw "ANDROID_E2E_EVIDENCE_SCHEMA_UNSUPPORTED actual=$($evidence.schemaVersion)" }
if ([string]$evidence.releaseId -ne $ReleaseId) {
    throw "ANDROID_E2E_RELEASE_MISMATCH expected=$ReleaseId actual=$($evidence.releaseId)"
}
if ([string]$evidence.testResult -ne 'PASS') { throw "ANDROID_E2E_NOT_PASS result=$($evidence.testResult)" }
if (-not $evidence.appVersion -or [int]$evidence.appVersionCode -le 0) { throw 'ANDROID_E2E_APP_IDENTITY_MISSING' }
if ([string]$evidence.dataContractVersion -ne 'canonical-v2') {
    throw "ANDROID_E2E_DATA_CONTRACT_MISMATCH actual=$($evidence.dataContractVersion)"
}
$testedAt = [DateTimeOffset]::Parse([string]$evidence.testedAtUtc)
$ageHours = ([DateTimeOffset]::UtcNow - $testedAt).TotalHours
if ($ageHours -lt -0.25) { throw 'ANDROID_E2E_EVIDENCE_FROM_FUTURE' }
if ($ageHours -gt $MaximumEvidenceAgeHours) { throw "ANDROID_E2E_EVIDENCE_STALE ageHours=$([Math]::Round($ageHours,2))" }

$requiredTests = @(
    'bundle-parse',
    'online-update',
    'catalog-render',
    'composition-render',
    'rollback-lkg'
)
$testRows = @($evidence.tests)
if ($testRows.Count -eq 0) { throw 'ANDROID_E2E_TEST_LIST_EMPTY' }
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($row in $testRows) {
    if ($null -eq $row -or -not $row.name) { continue }
    if ([string]$row.result -ne 'PASS') { throw "ANDROID_E2E_SUBTEST_NOT_PASS name=$($row.name) result=$($row.result)" }
    [void]$seen.Add([string]$row.name)
}
foreach ($required in $requiredTests) {
    if (-not $seen.Contains($required)) { throw "ANDROID_E2E_REQUIRED_TEST_MISSING name=$required" }
}
if (-not $evidence.sourceCommitSha -or ([string]$evidence.sourceCommitSha).Length -lt 7) {
    throw 'ANDROID_E2E_SOURCE_COMMIT_MISSING'
}
if (-not $evidence.apkSha256 -or [string]$evidence.apkSha256 -notmatch '^[a-fA-F0-9]{64}$') {
    throw 'ANDROID_E2E_APK_SHA256_INVALID'
}

Write-Output "Android canonical-v2 E2E evidence passed: Release=$ReleaseId App=$($evidence.appVersion)($($evidence.appVersionCode)) Source=$($evidence.sourceCommitSha)"
