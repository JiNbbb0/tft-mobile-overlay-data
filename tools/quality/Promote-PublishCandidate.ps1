param(
    [Parameter(Mandatory = $true)][string]$SiteDirectory,
    [Parameter(Mandatory = $true)][string]$ReleaseId,
    [Parameter(Mandatory = $true)][string]$AndroidEvidencePath,
    [string]$CandidateQualityPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$siteRoot = [IO.Path]::GetFullPath($SiteDirectory)
$indexPath = Join-Path $siteRoot 'data-index.json'
if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { throw "PROMOTION_INDEX_MISSING path=$indexPath" }
if (-not $CandidateQualityPath) { $CandidateQualityPath = Join-Path $siteRoot "bundles/$ReleaseId/data-quality.json" }
$candidateQualityFull = if ([IO.Path]::IsPathRooted($CandidateQualityPath)) {
    [IO.Path]::GetFullPath($CandidateQualityPath)
} else {
    [IO.Path]::GetFullPath((Join-Path $siteRoot $CandidateQualityPath))
}
$sitePrefix = $siteRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $candidateQualityFull.StartsWith($sitePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "PROMOTION_QUALITY_PATH_ESCAPE path=$candidateQualityFull"
}
if (-not (Test-Path -LiteralPath $candidateQualityFull -PathType Leaf)) {
    throw "PROMOTION_CANDIDATE_QUALITY_MISSING path=$candidateQualityFull"
}

# All fail-closed gates execute before data-index.json is touched. The immutable
# bundle may already be deployed for remote validation, but latestVersionId is
# the final pointer mutation and is impossible without real Android evidence.
& (Join-Path $PSScriptRoot 'Test-PublishCandidate.ps1') `
    -SiteDirectory $siteRoot `
    -ReleaseId $ReleaseId `
    -DataQualityPath $candidateQualityFull
& (Join-Path $PSScriptRoot 'Test-AndroidE2EEvidence.ps1') `
    -EvidencePath $AndroidEvidencePath `
    -ReleaseId $ReleaseId

$indexTextBefore = Get-Content -Raw -Encoding UTF8 -LiteralPath $indexPath
$index = $indexTextBefore | ConvertFrom-Json
$version = @($index.versions | Where-Object { [string]$_.id -eq $ReleaseId }) | Select-Object -First 1
if (-not $version) { throw "PROMOTION_VERSION_NOT_REGISTERED release=$ReleaseId" }
if ([string]$index.latestVersionId -eq $ReleaseId) {
    Write-Output "Publish candidate already promoted: Release=$ReleaseId"
    return
}
$previousLatest = [string]$index.latestVersionId
if (-not $previousLatest) { throw 'PROMOTION_LKG_POINTER_MISSING' }

# Prepare all user-visible status files before the pointer switch. A workflow
# failure before the final index move is never committed/deployed, so remote LKG
# remains unchanged.
$quality = Get-Content -Raw -Encoding UTF8 -LiteralPath $candidateQualityFull | ConvertFrom-Json
if ([string]$quality.releaseId -ne $ReleaseId -or [string]$quality.versionId -ne $ReleaseId) {
    throw "PROMOTION_QUALITY_RELEASE_MISMATCH expected=$ReleaseId"
}
$activeQualityPath = Join-Path $siteRoot 'data-quality.json'
$qualityTempPath = "$activeQualityPath.tmp"
[IO.File]::WriteAllText(
    $qualityTempPath,
    (($quality | ConvertTo-Json -Depth 50).Replace("`r`n", "`n") + "`n"),
    [Text.UTF8Encoding]::new($false)
)
Move-Item -LiteralPath $qualityTempPath -Destination $activeQualityPath -Force

$healthPath = Join-Path $siteRoot 'health.json'
if (Test-Path -LiteralPath $healthPath -PathType Leaf) {
    $health = Get-Content -Raw -Encoding UTF8 -LiteralPath $healthPath | ConvertFrom-Json
    $now = [DateTimeOffset]::UtcNow
    $sourceUpdated = if ($version.PSObject.Properties['sourceTimestampUtc'] -and $version.sourceTimestampUtc) {
        [DateTimeOffset]::Parse([string]$version.sourceTimestampUtc)
    } else { $now }
    $ageSeconds = ($now - $sourceUpdated).TotalSeconds
    $sla = if ($health.PSObject.Properties['freshnessSlaSeconds']) { [int]$health.freshnessSlaSeconds } else { 21600 }
    foreach ($pair in @(
        @('publicationState','ACTIVE'),
        @('activeVersionId',$ReleaseId),
        @('stagedCandidateVersionId',''),
        @('latestSetId',[string]$version.setId),
        @('latestPatch',[string]$version.patch),
        @('latestRevision',[string]$version.revision),
        @('sourceUpdatedAt',[string]$version.sourceTimestampUtc),
        @('latestMetaFingerprint',[string]$version.metaFingerprint),
        @('latestManifestSha256',[string]$version.manifestSha256),
        @('freshnessStatus',$(if ($ageSeconds -ge -60 -and $ageSeconds -le $sla) { 'FRESH' } else { 'STALE' }))
    )) {
        $health | Add-Member -NotePropertyName ([string]$pair[0]) -NotePropertyValue $pair[1] -Force
    }
    [IO.File]::WriteAllText(
        $healthPath,
        (($health | ConvertTo-Json -Depth 30).Replace("`r`n", "`n") + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
}

# FINAL MUTATION: latestVersionId changes only after local candidate validation,
# Android E2E evidence validation, and status preparation have all succeeded.
$index.latestVersionId = $ReleaseId
$index.generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$replacement = ($index | ConvertTo-Json -Depth 50).Replace("`r`n","`n") + "`n"
$tempPath = "$indexPath.tmp"
[IO.File]::WriteAllText($tempPath, $replacement, [Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $tempPath -Destination $indexPath -Force
Write-Output "Publish candidate promoted last: Release=$ReleaseId Previous=$previousLatest"
