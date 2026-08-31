param(
    [string]$PublishHistoryPath = (Join-Path $PSScriptRoot 'publish-data-history.ps1'),
    [string]$RefreshLivePath = (Join-Path $PSScriptRoot 'refresh-live-data.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$publishPath = [IO.Path]::GetFullPath($PublishHistoryPath)
$refreshPath = [IO.Path]::GetFullPath($RefreshLivePath)
foreach ($path in @($publishPath, $refreshPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Candidate lifecycle target missing: $path" }
}

$publish = [IO.File]::ReadAllText($publishPath).Replace("`r`n", "`n")
$refresh = [IO.File]::ReadAllText($refreshPath).Replace("`r`n", "`n")

$stageMarker = '# CANONICAL_V2_CANDIDATE_STAGE_BEGIN'
if (-not $publish.Contains($stageMarker)) {
    $retentionAnchor = '$retention = Select-ActiveDataHistory `'
    if (-not $publish.Contains($retentionAnchor)) { throw 'Candidate retention anchor missing.' }
    $stagingPrelude = @'
# CANONICAL_V2_CANDIDATE_STAGE_BEGIN
# Register the immutable candidate while preserving the current LKG pointer.
# A later promotion workflow is the only code allowed to mutate latestVersionId.
$candidatePreviousLatestVersionId = if ($existingIndex -and $existingIndex.PSObject.Properties['latestVersionId'] -and [string]$existingIndex.latestVersionId) {
    [string]$existingIndex.latestVersionId
} else {
    throw 'CANDIDATE_STAGING_REQUIRES_EXISTING_LKG'
}
if (-not @($versions | Where-Object { [string]$_.id -eq $candidatePreviousLatestVersionId } | Select-Object -First 1)) {
    throw "CANDIDATE_LKG_NOT_REGISTERED release=$candidatePreviousLatestVersionId"
}
# CANONICAL_V2_CANDIDATE_STAGE_END
'@
    $publish = $publish.Replace($retentionAnchor, $stagingPrelude + "`n" + $retentionAnchor)
}

$publish = $publish.Replace('-LatestVersionId $versionId `', '-LatestVersionId $candidatePreviousLatestVersionId `')
$publish = $publish.Replace('    latestVersionId = $versionId', '    latestVersionId = $candidatePreviousLatestVersionId')

$descriptorMarker = '# CANONICAL_V2_CANDIDATE_DESCRIPTOR_BEGIN'
if (-not $publish.Contains($descriptorMarker)) {
    $outputAnchor = 'Write-Output "Published local site: Version=$versionId Kind=$updateKind Files=$($entries.Count) Versions=$($versions.Count)"'
    if (-not $publish.Contains($outputAnchor)) { throw 'Candidate descriptor output anchor missing.' }
    $descriptorBlock = @'
# CANONICAL_V2_CANDIDATE_DESCRIPTOR_BEGIN
$candidateDescriptorPath = Join-Path $repositoryRoot 'build/publish-candidate.json'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $candidateDescriptorPath) | Out-Null
$candidateDescriptor = [pscustomobject][ordered]@{
    schemaVersion = 1
    releaseId = $versionId
    previousLatestVersionId = $candidatePreviousLatestVersionId
    manifestSha256 = $manifestSha256
    manifestPath = "bundles/$versionId/manifest.json"
    dataQualityPath = "bundles/$versionId/data-quality.json"
    stagedAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
}
[IO.File]::WriteAllText(
    $candidateDescriptorPath,
    (($candidateDescriptor | ConvertTo-Json -Depth 8).Replace("`r`n", "`n") + "`n"),
    [Text.UTF8Encoding]::new($false)
)
# CANONICAL_V2_CANDIDATE_DESCRIPTOR_END
'@
    $publish = $publish.Replace($outputAnchor, $descriptorBlock + "`n" + $outputAnchor)
}

$refreshMarker = '# CANONICAL_V2_CANDIDATE_REFRESH_BEGIN'
if (-not $refresh.Contains($refreshMarker)) {
    $refreshStart = '$publishedIndex = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $siteRoot "data-index.json") | ConvertFrom-Json'
    $refreshEnd = '$stage = "final-validation"'
    $startIndex = $refresh.IndexOf($refreshStart, [StringComparison]::Ordinal)
    if ($startIndex -lt 0) { throw 'Refresh candidate result start marker missing.' }
    $endIndex = $refresh.IndexOf($refreshEnd, $startIndex, [StringComparison]::Ordinal)
    if ($endIndex -lt 0) { throw 'Refresh candidate result end marker missing.' }
    $refreshReplacement = @'
# CANONICAL_V2_CANDIDATE_REFRESH_BEGIN
$publishedIndex = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $siteRoot "data-index.json") | ConvertFrom-Json
$candidateDescriptorPath = Join-Path $repositoryRoot 'build/publish-candidate.json'
if (-not (Test-Path -LiteralPath $candidateDescriptorPath -PathType Leaf)) {
    throw 'Candidate descriptor missing after publication staging.'
}
$candidateDescriptor = Get-Content -Raw -Encoding UTF8 -LiteralPath $candidateDescriptorPath | ConvertFrom-Json
$publishedVersion = @($publishedIndex.versions | Where-Object { [string]$_.id -eq [string]$candidateDescriptor.releaseId }) | Select-Object -First 1
if (-not $publishedVersion) { throw "Staged candidate is not registered in data-index: $($candidateDescriptor.releaseId)" }
if ([string]$publishedIndex.latestVersionId -eq [string]$publishedVersion.id) {
    throw "CANDIDATE_WAS_PROMOTED_EARLY release=$($publishedVersion.id)"
}
Set-ActionOutput "detected_version" ([string]$publishedVersion.id)
Set-ActionOutput "detected_kind" ([string]$publishedVersion.updateKind)
# CANONICAL_V2_CANDIDATE_REFRESH_END
'@
    $refresh = $refresh.Substring(0, $startIndex) + $refreshReplacement + "`n" + $refresh.Substring($endIndex)
}

foreach ($forbidden in @(
    '    latestVersionId = $versionId',
    'Where-Object { [string]$_.id -eq [string]$publishedIndex.latestVersionId }'
)) {
    if ($publish.Contains($forbidden) -or $refresh.Contains($forbidden)) {
        throw "Candidate lifecycle postcondition failed; early-promotion code remains: $forbidden"
    }
}
foreach ($required in @(
    $stageMarker,
    '-LatestVersionId $candidatePreviousLatestVersionId',
    'latestVersionId = $candidatePreviousLatestVersionId',
    $descriptorMarker
)) {
    if (-not $publish.Contains($required)) { throw "Candidate publication postcondition missing: $required" }
}
foreach ($required in @($refreshMarker, 'CANDIDATE_WAS_PROMOTED_EARLY', 'candidateDescriptor.releaseId')) {
    if (-not $refresh.Contains($required)) { throw "Candidate refresh postcondition missing: $required" }
}

[IO.File]::WriteAllText($publishPath, $publish, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($refreshPath, $refresh, [Text.UTF8Encoding]::new($false))
Write-Output "Candidate publication lifecycle enabled: Publish=$publishPath Refresh=$refreshPath"
