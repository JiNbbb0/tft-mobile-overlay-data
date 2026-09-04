param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9._-]+$')][string]$VersionId,
    [string]$SiteDirectory = "site"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$siteRoot = if ([IO.Path]::IsPathRooted($SiteDirectory)) { [IO.Path]::GetFullPath($SiteDirectory) } else { [IO.Path]::GetFullPath((Join-Path $repositoryRoot $SiteDirectory)) }
$indexPath = Join-Path $siteRoot "data-index.json"
$oldIndexText = Get-Content -Raw -Encoding UTF8 -LiteralPath $indexPath
$index = $oldIndexText | ConvertFrom-Json
$version = @($index.versions | Where-Object { [string]$_.id -eq $VersionId }) | Select-Object -First 1
if (-not $version) { throw "Version does not exist in data-index: $VersionId" }
$manifestPath = [IO.Path]::GetFullPath((Join-Path $siteRoot ([string]$version.manifestUrl)))
$sitePrefix = $siteRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $manifestPath.StartsWith($sitePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Manifest path escaped site root" }
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Manifest missing for version: $VersionId" }
$manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
if ([string]$manifest.id -ne $VersionId) { throw "Manifest identity mismatch for version: $VersionId" }
$targetReleaseState = if ($manifest.PSObject.Properties['releaseState']) { [string]$manifest.releaseState } elseif ([string]$manifest.readiness -eq 'META_STABLE') { 'STABLE' } else { 'PARTIAL' }
if ($targetReleaseState -ne 'STABLE') { throw 'Rollback latest may only select a validated STABLE (or legacy META_STABLE) version.' }
$manifestFingerprint = if ($manifest.PSObject.Properties['metaFingerprint']) { [string]$manifest.metaFingerprint } else { '' }
$manifestQueryHash = if ($manifest.PSObject.Properties['sourceQueryHash']) { [string]$manifest.sourceQueryHash } else { '' }
$manifestSourceTimestamp = if ($manifest.PSObject.Properties['sourceTimestampUtc']) { [string]$manifest.sourceTimestampUtc } else { [string]$manifest.generatedAtUtc }
$calculatedManifestSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant()
# Normalize legacy index records in place. Empty optional identity values match
# legacy manifests, while a calculated manifest SHA is always available.
if (-not $version.PSObject.Properties['metaFingerprint']) { $version | Add-Member -NotePropertyName metaFingerprint -NotePropertyValue $manifestFingerprint }
if (-not $version.PSObject.Properties['sourceQueryHash']) { $version | Add-Member -NotePropertyName sourceQueryHash -NotePropertyValue $manifestQueryHash }
if (-not $version.PSObject.Properties['manifestSha256']) { $version | Add-Member -NotePropertyName manifestSha256 -NotePropertyValue $calculatedManifestSha }
if (-not $version.PSObject.Properties['sourceTimestampUtc']) { $version | Add-Member -NotePropertyName sourceTimestampUtc -NotePropertyValue $manifestSourceTimestamp }

$oldLatest = [string]$index.latestVersionId
$healthPath = Join-Path $siteRoot "health.json"
$oldHealthText = Get-Content -Raw -Encoding UTF8 -LiteralPath $healthPath
$qualityPath = Join-Path $siteRoot 'data-quality.json'
$oldQualityText = if (Test-Path -LiteralPath $qualityPath) { Get-Content -Raw -Encoding UTF8 -LiteralPath $qualityPath } else { $null }
$health = $oldHealthText | ConvertFrom-Json
$index.latestVersionId = $VersionId
if ($index.PSObject.Properties['latestStableVersionId']) { $index.latestStableVersionId = $VersionId } else { $index | Add-Member -NotePropertyName latestStableVersionId -NotePropertyValue $VersionId }
if ($index.PSObject.Properties['latestAvailableVersionId']) { $index.latestAvailableVersionId = $VersionId } else { $index | Add-Member -NotePropertyName latestAvailableVersionId -NotePropertyValue $VersionId }
$index.generatedAtUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
$nextPath = Join-Path $siteRoot "data-index.next.json"
[IO.File]::WriteAllText($nextPath, ($index | ConvertTo-Json -Depth 8) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
Move-Item -Force -LiteralPath $nextPath -Destination $indexPath
$health.latestSetId = [string]$version.setId
$health.latestPatch = [string]$version.patch
$health.latestRevision = [string]$version.revision
foreach ($pair in @(
    @{ Name='latestStableVersionId'; Value=$VersionId }, @{ Name='latestAvailableVersionId'; Value=$VersionId },
    @{ Name='latestAvailableSetId'; Value=[string]$version.setId }, @{ Name='latestAvailablePatch'; Value=[string]$version.patch }, @{ Name='latestAvailableRevision'; Value=[string]$version.revision }
)) {
    if ($health.PSObject.Properties[$pair.Name]) { $health.($pair.Name) = $pair.Value } else { $health | Add-Member -NotePropertyName $pair.Name -NotePropertyValue $pair.Value }
}
$health.generatedAt = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
$health.publishedAtUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
$health.workflowRunId = $(if ($env:GITHUB_RUN_ID) { [string]$env:GITHUB_RUN_ID } else { "local-rollback" })
$health.lastSuccessfulRunId = $health.workflowRunId
$health.consecutiveFailures = 0
$health.status = 'ok'
$health.latestMetaFingerprint = if ($version.PSObject.Properties['metaFingerprint']) { [string]$version.metaFingerprint } else { $manifestFingerprint }
$health.latestManifestSha256 = if ($version.PSObject.Properties['manifestSha256'] -and [string]$version.manifestSha256) {
    [string]$version.manifestSha256
} else {
    $calculatedManifestSha
}
$health.sourceQueryHash = if ($version.PSObject.Properties['sourceQueryHash']) { [string]$version.sourceQueryHash } else { $manifestQueryHash }
foreach ($pair in @(
    @{ Name='latestAvailableMetaFingerprint'; Value=[string]$health.latestMetaFingerprint },
    @{ Name='latestAvailableManifestSha256'; Value=[string]$health.latestManifestSha256 },
    @{ Name='latestAvailableSourceQueryHash'; Value=[string]$health.sourceQueryHash }
)) {
    if ($health.PSObject.Properties[$pair.Name]) { $health.($pair.Name) = $pair.Value } else { $health | Add-Member -NotePropertyName $pair.Name -NotePropertyValue $pair.Value }
}
$sourceUpdatedAt = if ($version.PSObject.Properties['sourceTimestampUtc'] -and $version.sourceTimestampUtc) {
    $version.sourceTimestampUtc
} elseif ($manifest.PSObject.Properties['sourceTimestampUtc'] -and $manifest.sourceTimestampUtc) {
    $manifest.sourceTimestampUtc
} else {
    $version.generatedAtUtc
}
$health.sourceUpdatedAt = if ($sourceUpdatedAt -is [DateTime]) {
    $sourceUpdatedAt.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
} else {
    [string]$sourceUpdatedAt
}
$freshnessWarningAfterSeconds = if ($health.PSObject.Properties['freshnessWarningAfterSeconds']) { [int]$health.freshnessWarningAfterSeconds } else { 21600 }
$freshnessCriticalAfterSeconds = if ($health.PSObject.Properties['freshnessCriticalAfterSeconds']) { [int]$health.freshnessCriticalAfterSeconds } else { 86400 }
$health.freshnessSlaSeconds = $freshnessWarningAfterSeconds
foreach ($pair in @(
    @{ Name='freshnessWarningAfterSeconds'; Value=$freshnessWarningAfterSeconds },
    @{ Name='freshnessCriticalAfterSeconds'; Value=$freshnessCriticalAfterSeconds }
)) {
    if ($health.PSObject.Properties[$pair.Name]) { $health.($pair.Name) = $pair.Value } else { $health | Add-Member -NotePropertyName $pair.Name -NotePropertyValue $pair.Value }
}
$sourceAgeSeconds = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse(
    [string]$health.sourceUpdatedAt,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeUniversal
)).TotalSeconds
$health.freshnessStatus = if ($sourceAgeSeconds -lt -60 -or $sourceAgeSeconds -ge $freshnessCriticalAfterSeconds) {
    'CRITICAL'
} elseif ($sourceAgeSeconds -ge $freshnessWarningAfterSeconds) {
    'WARNING'
} else {
    'FRESH'
}
[IO.File]::WriteAllText($healthPath, ($health | ConvertTo-Json) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
try {
    $catalogEntry = @($manifest.files | Where-Object { [string]$_.path -eq 'tft/tft_catalog.json' }) | Select-Object -First 1
    $snapshotEntry = @($manifest.files | Where-Object { [string]$_.path -eq 'tft_static_snapshot.json' }) | Select-Object -First 1
    if ($catalogEntry -and $snapshotEntry) {
        $catalogPath = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $manifestPath) ([string]$catalogEntry.url)))
        $snapshotPath = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $manifestPath) ([string]$snapshotEntry.url)))
        & (Join-Path $PSScriptRoot 'write-data-quality-status.ps1') -SiteDirectory $siteRoot -CatalogPath $catalogPath -SnapshotPath $snapshotPath
    }
    & (Join-Path $PSScriptRoot "validate-site.ps1") -SiteDirectory $SiteDirectory
} catch {
    [IO.File]::WriteAllText($indexPath, $oldIndexText, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($healthPath, $oldHealthText, [Text.UTF8Encoding]::new($false))
    if ($null -ne $oldQualityText) { [IO.File]::WriteAllText($qualityPath, $oldQualityText, [Text.UTF8Encoding]::new($false)) }
    throw
}
Write-Output "Latest changed safely: $oldLatest -> $VersionId"
