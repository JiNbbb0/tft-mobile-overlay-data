param(
    [Parameter(Mandatory = $true)][string]$SiteDirectory,
    [string]$CandidateDescriptorPath = 'build/publish-candidate.json'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$siteRoot = if ([IO.Path]::IsPathRooted($SiteDirectory)) { [IO.Path]::GetFullPath($SiteDirectory) } else { [IO.Path]::GetFullPath((Join-Path $repoRoot $SiteDirectory)) }
$descriptorPath = if ([IO.Path]::IsPathRooted($CandidateDescriptorPath)) { [IO.Path]::GetFullPath($CandidateDescriptorPath) } else { [IO.Path]::GetFullPath((Join-Path $repoRoot $CandidateDescriptorPath)) }
$indexPath = Join-Path $siteRoot 'data-index.json'
$healthPath = Join-Path $siteRoot 'health.json'
foreach ($path in @($descriptorPath, $indexPath, $healthPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "STAGED_STATUS_INPUT_MISSING path=$path" }
}

$descriptor = Get-Content -Raw -Encoding UTF8 -LiteralPath $descriptorPath | ConvertFrom-Json
$index = Get-Content -Raw -Encoding UTF8 -LiteralPath $indexPath | ConvertFrom-Json
$health = Get-Content -Raw -Encoding UTF8 -LiteralPath $healthPath | ConvertFrom-Json
$releaseId = [string]$descriptor.releaseId
$lkgId = [string]$index.latestVersionId
if (-not $releaseId -or -not $lkgId) { throw 'STAGED_STATUS_RELEASE_ID_MISSING' }
if ($releaseId -eq $lkgId) { throw "STAGED_STATUS_CANDIDATE_ALREADY_ACTIVE release=$releaseId" }
if ([string]$descriptor.previousLatestVersionId -ne $lkgId) {
    throw "STAGED_STATUS_LKG_CHANGED expected=$($descriptor.previousLatestVersionId) actual=$lkgId"
}
$candidate = @($index.versions | Where-Object { [string]$_.id -eq $releaseId }) | Select-Object -First 1
$lkg = @($index.versions | Where-Object { [string]$_.id -eq $lkgId }) | Select-Object -First 1
if (-not $candidate) { throw "STAGED_STATUS_CANDIDATE_NOT_REGISTERED release=$releaseId" }
if (-not $lkg) { throw "STAGED_STATUS_LKG_NOT_REGISTERED release=$lkgId" }

$now = [DateTimeOffset]::UtcNow
$sourceUpdated = if ($lkg.PSObject.Properties['sourceTimestampUtc'] -and $lkg.sourceTimestampUtc) { [DateTimeOffset]::Parse([string]$lkg.sourceTimestampUtc) } else { $now }
$sla = if ($health.PSObject.Properties['freshnessSlaSeconds']) { [int]$health.freshnessSlaSeconds } else { 21600 }
$ageSeconds = ($now - $sourceUpdated).TotalSeconds
$values = [ordered]@{
    status = 'ok'
    publicationState = 'CANDIDATE_STAGED'
    activeVersionId = $lkgId
    stagedCandidateVersionId = $releaseId
    candidateStagedAtUtc = [string]$descriptor.stagedAtUtc
    latestSetId = [string]$lkg.setId
    latestPatch = [string]$lkg.patch
    latestRevision = [string]$lkg.revision
    sourceUpdatedAt = [string]$lkg.sourceTimestampUtc
    latestMetaFingerprint = [string]$lkg.metaFingerprint
    latestManifestSha256 = [string]$lkg.manifestSha256
    freshnessStatus = $(if ($ageSeconds -ge -60 -and $ageSeconds -le $sla) { 'FRESH' } else { 'STALE' })
}
foreach ($key in $values.Keys) {
    $health | Add-Member -NotePropertyName ([string]$key) -NotePropertyValue $values[$key] -Force
}

# Write twice so fileCount includes the final health file itself and any staged
# candidate quality file created before this step.
for ($pass = 1; $pass -le 2; $pass++) {
    $health | Add-Member -NotePropertyName 'fileCount' -NotePropertyValue @(Get-ChildItem -LiteralPath $siteRoot -File -Recurse).Count -Force
    [IO.File]::WriteAllText(
        $healthPath,
        (($health | ConvertTo-Json -Depth 30).Replace("`r`n", "`n") + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
}
Write-Output "Staged public status preserved LKG: Active=$lkgId Candidate=$releaseId Freshness=$($health.freshnessStatus)"
