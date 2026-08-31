$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$refreshPath = Join-Path $repoRoot '.github/workflows/refresh-tft-data.yml'
$promotePath = Join-Path $repoRoot '.github/workflows/promote-canonical-candidate.yml'
$promotionScriptPath = Join-Path $PSScriptRoot 'quality/Promote-PublishCandidate.ps1'
foreach ($path in @($refreshPath,$promotePath,$promotionScriptPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Publication workflow contract input missing: $path" }
}
$refresh = [IO.File]::ReadAllText($refreshPath).Replace("`r`n", "`n")
$promote = [IO.File]::ReadAllText($promotePath).Replace("`r`n", "`n")
$promotionScript = [IO.File]::ReadAllText($promotionScriptPath).Replace("`r`n", "`n")

foreach ($required in @(
    'Prepare Canonical v2 production runtime',
    'Detect, generate, validate, and stage immutable candidate',
    'bundles/$release/data-quality.json',
    'Test-StagedPublishCandidate.ps1',
    'Test-RemoteStagedPublishCandidate.ps1',
    'Candidate was promoted before Android E2E.',
    'latestVersionId is not promoted by this workflow.'
)) {
    if (-not $refresh.Contains($required)) { throw "Refresh staging contract missing: $required" }
}
foreach ($forbidden in @(
    'Promote-PublishCandidate.ps1',
    'Test-AndroidE2EEvidence.ps1',
    'reconcile-publication.ps1',
    'permit_filter_adjustment=true'
)) {
    if ($refresh.Contains($forbidden)) { throw "Refresh workflow contains forbidden promotion behavior: $forbidden" }
}

foreach ($required in @(
    'workflow_dispatch:',
    'Test-RemoteStagedPublishCandidate.ps1',
    'Require real Android E2E evidence',
    'Test-AndroidE2EEvidence.ps1',
    'Promote-PublishCandidate.ps1',
    'Promote latestVersionId last',
    'evidence/android/$release.json'
)) {
    if (-not $promote.Contains($required)) { throw "Promotion workflow contract missing: $required" }
}
if ($promote.Contains('schedule:')) { throw 'Promotion workflow must never run on a schedule.' }
$remoteIndex = $promote.IndexOf('Test-RemoteStagedPublishCandidate.ps1', [StringComparison]::Ordinal)
$androidIndex = $promote.IndexOf('Test-AndroidE2EEvidence.ps1', [StringComparison]::Ordinal)
$promoteIndex = $promote.IndexOf('Promote-PublishCandidate.ps1', [StringComparison]::Ordinal)
if ($remoteIndex -lt 0 -or $androidIndex -lt 0 -or $promoteIndex -lt 0 -or -not ($remoteIndex -lt $androidIndex -and $androidIndex -lt $promoteIndex)) {
    throw 'Promotion gate order must be remote SHA -> Android E2E -> latest promotion.'
}

$localCandidateIndex = $promotionScript.IndexOf('Test-PublishCandidate.ps1', [StringComparison]::Ordinal)
$localAndroidIndex = $promotionScript.IndexOf('Test-AndroidE2EEvidence.ps1', [StringComparison]::Ordinal)
$pointerIndex = $promotionScript.LastIndexOf('$index.latestVersionId = $ReleaseId', [StringComparison]::Ordinal)
if ($localCandidateIndex -lt 0 -or $localAndroidIndex -lt 0 -or $pointerIndex -lt 0 -or -not ($localCandidateIndex -lt $localAndroidIndex -and $localAndroidIndex -lt $pointerIndex)) {
    throw 'Local promotion script gate order changed.'
}
if ($promotionScript.IndexOf('Move-Item -LiteralPath $tempPath -Destination $indexPath -Force', [StringComparison]::Ordinal) -lt $pointerIndex) {
    throw 'data-index replacement must occur only after latestVersionId is assigned as the final pointer mutation.'
}

Write-Output 'Production staged-publication workflow contract passed.'
