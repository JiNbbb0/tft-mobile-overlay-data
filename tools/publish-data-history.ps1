param(
    [string]$SiteDirectory = "site",
    [string]$SourceRoot = "source/current",
    [int]$MinimumAppVersionCode = 24,
    [string]$MetaFingerprint = "",
    [ValidateSet("CATALOG_READY", "META_COLLECTING", "META_STABLE")]
    [string]$Readiness = "",
    [int]$MaxActiveVersions = 5,
    [int]$MaxRecentMetaUpdates = 5,
    [switch]$ForceReplaceSameVersion
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "data-history-policy.ps1")
. (Join-Path $PSScriptRoot "release-contract-policy.ps1")

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$siteRoot = if ([IO.Path]::IsPathRooted($SiteDirectory)) { [IO.Path]::GetFullPath($SiteDirectory) } else { [IO.Path]::GetFullPath((Join-Path $repositoryRoot $SiteDirectory)) }
$sourceRootResolved = if ([IO.Path]::IsPathRooted($SourceRoot)) { [IO.Path]::GetFullPath($SourceRoot) } else { [IO.Path]::GetFullPath((Join-Path $repositoryRoot $SourceRoot)) }
$repoPrefix = $repositoryRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $siteRoot.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "SiteDirectory must stay inside repository" }
if (-not $sourceRootResolved.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "SourceRoot must stay inside repository" }

$catalogSource = Join-Path $sourceRootResolved "tft/tft_catalog.json"
$metaSource = Join-Path $sourceRootResolved "tft_static_snapshot.json"
$imageSourceRoot = Join-Path $sourceRootResolved "tft/images"
$metadataRoot = Join-Path $sourceRootResolved "metadata"
$sourceManifest = Join-Path $metadataRoot "DATA_SOURCE_MANIFEST.json"
$changeSummaryJson = Join-Path $metadataRoot "CHANGE_SUMMARY.json"
$changeSummaryMd = Join-Path $metadataRoot "CHANGE_SUMMARY.md"
foreach ($required in @($catalogSource,$metaSource,$sourceManifest,$changeSummaryJson,$changeSummaryMd)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required source file missing: $required" }
}
if (-not (Test-Path -LiteralPath $imageSourceRoot -PathType Container)) { throw "Image source directory missing" }

$catalog = Get-Content -Raw -Encoding UTF8 -LiteralPath $catalogSource | ConvertFrom-Json
$meta = Get-Content -Raw -Encoding UTF8 -LiteralPath $metaSource | ConvertFrom-Json
if ($meta.PSObject.Properties['compositionRanks']) {
    & (Join-Path $PSScriptRoot 'validate-static-meta.ps1') -SnapshotPath $metaSource -CatalogPath $catalogSource
}
$sourceManifestDocument = Get-Content -Raw -Encoding UTF8 -LiteralPath $sourceManifest | ConvertFrom-Json
if ([int]$catalog.schemaVersion -ne 1 -or [int]$meta.schemaVersion -notin @(4,5)) { throw "Unsupported source schema" }
if ([string]$catalog.set.id -ne [string]$meta.setId) { throw "Catalog and composition set do not match" }
$setId = [string]$catalog.set.id
$setNumber = [int]$catalog.set.number
$setName = [string]$catalog.set.nameJa
$patch = [string]$catalog.set.tftPatch
$revision = [string]$meta.clusterId
$baseVersionId = (("{0}-{1}-r{2}" -f $setId,$patch,$revision).ToLowerInvariant() -replace '[^a-z0-9._-]','-')
$generatedAtUtc = ConvertTo-DataUtcTimestamp $meta.fetchedAtUtc
if (-not $generatedAtUtc) { $generatedAtUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ") }
$sourceTimestampUtc = if ($meta.PSObject.Properties['statsUpdatedEpochMs'] -and [int64]$meta.statsUpdatedEpochMs -gt 0) {
    [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$meta.statsUpdatedEpochMs).UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
} else {
    $generatedAtUtc
}
$sourceQueryJson = if ($meta.PSObject.Properties['statisticsScope']) {
    $meta.statisticsScope | ConvertTo-Json -Depth 12 -Compress
} else { '{}' }
$sourceQuerySha = [Security.Cryptography.SHA256]::Create()
try {
    $sourceQueryHash = ($sourceQuerySha.ComputeHash([Text.Encoding]::UTF8.GetBytes($sourceQueryJson)) |
        ForEach-Object { $_.ToString('x2') }) -join ''
} finally {
    $sourceQuerySha.Dispose()
}
if (-not $MetaFingerprint) {
    $MetaFingerprint = & (Join-Path $PSScriptRoot "get-meta-fingerprint.ps1") -SnapshotPath $metaSource
}
if ($MetaFingerprint -notmatch '^[0-9a-f]{64}$') { throw "Invalid meta fingerprint" }
if (-not $Readiness) {
    $Readiness = if ($meta.PSObject.Properties['readiness']) { [string]$meta.readiness } else { "META_STABLE" }
}
$releaseContract = Resolve-TftReleaseContract -Catalog $catalog -Snapshot $meta -SourceManifest $sourceManifestDocument
$validatedAtUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", [Globalization.CultureInfo]::InvariantCulture)

$stagingRoot = Join-Path $repositoryRoot "build/site-staging"
if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -Recurse -Force -LiteralPath $stagingRoot }
New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null
if (Test-Path -LiteralPath $siteRoot) {
    Get-ChildItem -LiteralPath $siteRoot -Force | ForEach-Object { Copy-Item -Recurse -Force -LiteralPath $_.FullName -Destination $stagingRoot }
}
$stagingSchemaRoot = Join-Path $stagingRoot "schema"
if (Test-Path -LiteralPath $stagingSchemaRoot) { Remove-Item -Recurse -Force -LiteralPath $stagingSchemaRoot }
Copy-Item -Recurse -Force -LiteralPath (Join-Path $repositoryRoot "schema") -Destination $stagingSchemaRoot
New-Item -ItemType Directory -Force -Path (Join-Path $stagingRoot "bundles"),(Join-Path $stagingRoot "blobs") | Out-Null

$indexPath = Join-Path $stagingRoot "data-index.json"
$existingVersions = @()
$existingIndex = $null
if (Test-Path -LiteralPath $indexPath) {
    $existingIndex = Get-Content -Raw -Encoding UTF8 -LiteralPath $indexPath | ConvertFrom-Json
    if ([int]$existingIndex.schemaVersion -ne 1) { throw "Unsupported existing data-index schema" }
    $existingVersions = @(Normalize-DataVersionTimestamps -Versions @($existingIndex.versions))
}
$previous = Get-PreviousDataVersion -Index $existingIndex -Versions $existingVersions
$publicationIdentity = Resolve-DataPublicationIdentity `
    -Previous $previous `
    -SetId $setId `
    -Patch $patch `
    -Revision $revision `
    -MetaFingerprint $MetaFingerprint `
    -BaseVersionId $baseVersionId
$updateKind = [string]$publicationIdentity.updateKind
$versionId = [string]$publicationIdentity.versionId
$sameVersion = @($existingVersions | Where-Object { [string]$_.id -eq $versionId }) | Select-Object -First 1
if ($sameVersion) { $updateKind = [string]$sameVersion.updateKind }

$bundleRoot = Join-Path $stagingRoot "bundles/$versionId"
if (Test-Path -LiteralPath $bundleRoot) {
    if (-not $ForceReplaceSameVersion) { throw "Version already exists; same ID with different content is refused: $versionId" }
    Remove-Item -Recurse -Force -LiteralPath $bundleRoot
}
$filesRoot = Join-Path $bundleRoot "files"
$catalogRoot = Join-Path $filesRoot "catalog"
$compsRoot = Join-Path $filesRoot "comps"
$statsRoot = Join-Path $filesRoot "stats"
$bundleMetadataRoot = Join-Path $filesRoot "metadata"
New-Item -ItemType Directory -Force -Path $catalogRoot,$compsRoot,$statsRoot,$bundleMetadataRoot | Out-Null
Copy-Item -Force -LiteralPath $catalogSource -Destination (Join-Path $catalogRoot "tft_catalog.json")
Copy-Item -Force -LiteralPath $metaSource -Destination (Join-Path $compsRoot "tft_static_snapshot.json")
Copy-Item -Force -LiteralPath $sourceManifest -Destination (Join-Path $bundleMetadataRoot "DATA_SOURCE_MANIFEST.json")
Copy-Item -Force -LiteralPath $changeSummaryJson -Destination (Join-Path $bundleMetadataRoot "CHANGE_SUMMARY.json")
Copy-Item -Force -LiteralPath $changeSummaryMd -Destination (Join-Path $bundleMetadataRoot "CHANGE_SUMMARY.md")
$statsBasis = [pscustomobject][ordered]@{
    schemaVersion = 1
    generatedAt = $generatedAtUtc
    setId = $setId
    patch = $patch
    revision = $revision
    sourceSummary = [string]$meta.sourceSummary
    itemStatBasis = $meta.itemStatBasis
    compositionCount = @($meta.compositions | Where-Object { $_ -is [pscustomobject] }).Count
    itemStatCount = @(
        foreach ($composition in @($meta.compositions)) {
            if ($composition -isnot [pscustomobject] -or -not ($composition.PSObject.Properties.Name -contains 'units')) { continue }
            foreach ($unit in @($composition.units)) {
                if ($unit -is [pscustomobject] -and ($unit.PSObject.Properties.Name -contains 'itemStats')) {
                    @($unit.itemStats)
                }
            }
        }
    ).Count
}
[IO.File]::WriteAllText((Join-Path $statsRoot "STATS_BASIS.json"), (($statsBasis | ConvertTo-Json -Depth 8).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))

function New-FileEntry {
    param([string]$LogicalPath,[string]$RelativeUrl,[string]$PhysicalPath)
    $item = Get-Item -LiteralPath $PhysicalPath
    return [pscustomobject][ordered]@{
        path = $LogicalPath.Replace('\','/')
        url = $RelativeUrl.Replace('\','/')
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $PhysicalPath).Hash.ToLowerInvariant()
        bytes = [int64]$item.Length
    }
}

$entries = [Collections.Generic.List[object]]::new()
$entries.Add((New-FileEntry "tft/tft_catalog.json" "files/catalog/tft_catalog.json" (Join-Path $catalogRoot "tft_catalog.json")))
$entries.Add((New-FileEntry "tft_static_snapshot.json" "files/comps/tft_static_snapshot.json" (Join-Path $compsRoot "tft_static_snapshot.json")))
$entries.Add((New-FileEntry "metadata/DATA_SOURCE_MANIFEST.json" "files/metadata/DATA_SOURCE_MANIFEST.json" (Join-Path $bundleMetadataRoot "DATA_SOURCE_MANIFEST.json")))
$entries.Add((New-FileEntry "metadata/CHANGE_SUMMARY.json" "files/metadata/CHANGE_SUMMARY.json" (Join-Path $bundleMetadataRoot "CHANGE_SUMMARY.json")))
$entries.Add((New-FileEntry "metadata/CHANGE_SUMMARY.md" "files/metadata/CHANGE_SUMMARY.md" (Join-Path $bundleMetadataRoot "CHANGE_SUMMARY.md")))
$entries.Add((New-FileEntry "metadata/STATS_BASIS.json" "files/stats/STATS_BASIS.json" (Join-Path $statsRoot "STATS_BASIS.json")))

$blobsRoot = Join-Path $stagingRoot "blobs"
foreach ($image in Get-ChildItem -LiteralPath $imageSourceRoot -File | Sort-Object Name) {
    $extension = $image.Extension.ToLowerInvariant()
    if ($extension -notin @('.png','.jpg','.jpeg','.webp')) { throw "Unsupported image extension: $($image.Name)" }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $image.FullName).Hash.ToLowerInvariant()
    $blobName = "$hash$extension"
    $blobPath = Join-Path $blobsRoot $blobName
    if (-not (Test-Path -LiteralPath $blobPath)) { Copy-Item -Force -LiteralPath $image.FullName -Destination $blobPath }
    $entries.Add((New-FileEntry "tft/images/$($image.Name)" "../../blobs/$blobName" $image.FullName))
}

$manifest = [pscustomobject][ordered]@{
    schemaVersion = 1
    id = $versionId
    setId = $setId
    setNumber = $setNumber
    setName = $setName
    patch = $patch
    revision = $revision
    updateKind = $updateKind
    generatedAtUtc = $generatedAtUtc
    sourceTimestampUtc = $sourceTimestampUtc
    metaFingerprint = $MetaFingerprint
    sourceQueryHash = $sourceQueryHash
    readiness = $Readiness
    releaseState = [string]$releaseContract.releaseState
    validationStatus = [string]$releaseContract.validationStatus
    sourceAlignment = [string]$releaseContract.sourceAlignment
    validatedAtUtc = $validatedAtUtc
    featureReadiness = $releaseContract.featureReadiness
    levelBoardReadiness = $releaseContract.levelBoardReadiness
    minimumAppVersionCode = $MinimumAppVersionCode
    files = @($entries)
}
$manifestPath = Join-Path $bundleRoot "manifest.json"
[IO.File]::WriteAllText($manifestPath, (($manifest | ConvertTo-Json -Depth 8).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
$manifestSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant()

$record = [pscustomobject][ordered]@{
    id = $versionId
    setId = $setId
    setNumber = $setNumber
    setName = $setName
    patch = $patch
    revision = $revision
    updateKind = $updateKind
    generatedAtUtc = $generatedAtUtc
    sourceTimestampUtc = $sourceTimestampUtc
    metaFingerprint = $MetaFingerprint
    manifestSha256 = $manifestSha256
    sourceQueryHash = $sourceQueryHash
    readiness = $Readiness
    releaseState = [string]$releaseContract.releaseState
    validationStatus = [string]$releaseContract.validationStatus
    sourceAlignment = [string]$releaseContract.sourceAlignment
    validatedAtUtc = $validatedAtUtc
    featureReadiness = $releaseContract.featureReadiness
    levelBoardReadiness = $releaseContract.levelBoardReadiness
    manifestUrl = "bundles/$versionId/manifest.json"
    hidden = $false
}
$versions = @($record) + @($existingVersions | Where-Object { [string]$_.id -ne $versionId })
$versions = @($versions | Sort-Object { ConvertTo-DataUtcTimestamp $_.generatedAtUtc } -Descending)
$previousStableVersionId = if ($existingIndex -and $existingIndex.PSObject.Properties['latestStableVersionId']) {
    [string]$existingIndex.latestStableVersionId
} else {
    $previousStableRecord = @($existingVersions | Where-Object {
        [string](Get-TftObjectProperty $_ 'releaseState' '') -eq 'STABLE' -or
        (-not (Get-TftObjectProperty $_ 'releaseState' '') -and [string](Get-TftObjectProperty $_ 'readiness' '') -eq 'META_STABLE')
    } | Sort-Object { ConvertTo-DataUtcTimestamp (Get-TftObjectProperty $_ 'generatedAtUtc' '') } -Descending | Select-Object -First 1)
    if ($previousStableRecord.Count -gt 0) { [string](Get-TftObjectProperty $previousStableRecord[0] 'id' '') } else { '' }
}
$latestStableVersionId = if ([bool]$releaseContract.stableEligible) { $versionId } else { $previousStableVersionId }
if (-not $latestStableVersionId) {
    throw 'A partial candidate cannot be exposed before a validated stable baseline exists.'
}
$stablePointerRecord = @($versions | Where-Object { [string]$_.id -eq $latestStableVersionId }) | Select-Object -First 1
if (-not $stablePointerRecord) { throw "Stable pointer record is missing: $latestStableVersionId" }
if (-not [bool]$releaseContract.stableEligible) {
    foreach ($field in @('metaFingerprint','manifestSha256','sourceQueryHash')) {
        if ([string](Get-TftObjectProperty $stablePointerRecord $field '') -notmatch '^[0-9a-f]{64}$') {
            throw "A partial candidate requires a content-addressed v2 stable baseline: missing $field"
        }
    }
    if ([string](Get-TftObjectProperty $stablePointerRecord 'releaseState' '') -ne 'STABLE' -or
        [string](Get-TftObjectProperty $stablePointerRecord 'validationStatus' '') -ne 'PASS' -or
        [string](Get-TftObjectProperty $stablePointerRecord 'sourceAlignment' '') -ne 'VERIFIED') {
        throw 'A partial candidate requires a validated and source-aligned v2 stable baseline.'
    }
}
$retention = Select-ActiveDataHistory `
    -Versions $versions `
    -LatestVersionId $versionId `
    -ProtectedVersionIds @($latestStableVersionId, $(if ($previous) { [string]$previous.id })) `
    -MaxActiveVersions $MaxActiveVersions `
    -MaxRecentMetaUpdates $MaxRecentMetaUpdates -RecentOnly
$versions = @($retention.retained)

$archivePath = Join-Path $stagingRoot "archive-map.json"
$existingArchiveEntries = @()
if (Test-Path -LiteralPath $archivePath) {
    $existingArchive = Get-Content -Raw -Encoding UTF8 -LiteralPath $archivePath | ConvertFrom-Json
    $existingArchiveEntries = @($existingArchive.entries)
}
$archiveById = [ordered]@{}
foreach ($entry in $existingArchiveEntries) { $archiveById[[string]$entry.id] = $entry }
$archiveCommit = if ($env:GITHUB_SHA) {
    [string]$env:GITHUB_SHA
} else {
    $gitCommand = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitCommand -and (Test-Path -LiteralPath 'C:\Program Files\Git\cmd\git.exe')) {
        $gitCommand = Get-Item -LiteralPath 'C:\Program Files\Git\cmd\git.exe'
    }
    if ($gitCommand) { (& $gitCommand.Source -C $repositoryRoot rev-parse HEAD).Trim() } else { "HEAD-before-publication" }
}
$archiveCommit = $archiveCommit.Trim()
foreach ($entry in $existingArchiveEntries) {
    if ([string]$entry.archivedFromCommit -in @("local-before-publication", "HEAD-before-publication") -and
        $archiveCommit -notin @("local-before-publication", "HEAD-before-publication")) {
        $entry.archivedFromCommit = $archiveCommit
    }
}
foreach ($archivedVersion in @($retention.archived)) {
    if ([string]$archivedVersion.id -cnotmatch '^[a-z0-9][a-z0-9._-]*$' -or [string]$archivedVersion.id -match '\.\.') {
        throw 'Unsafe version ID refused before retention cleanup'
    }
    $archivedBundle = [IO.Path]::GetFullPath((Join-Path $stagingRoot "bundles/$($archivedVersion.id)"))
    $bundlePrefix = [IO.Path]::GetFullPath((Join-Path $stagingRoot 'bundles')) + [IO.Path]::DirectorySeparatorChar
    if (-not $archivedBundle.StartsWith($bundlePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Retention path escaped staged bundles' }
    $archivedManifest = Join-Path $archivedBundle "manifest.json"
    $archivedManifestSha = if ($archivedVersion.PSObject.Properties['manifestSha256'] -and [string]$archivedVersion.manifestSha256) {
        [string]$archivedVersion.manifestSha256
    } elseif (Test-Path -LiteralPath $archivedManifest) {
        (Get-FileHash -Algorithm SHA256 -LiteralPath $archivedManifest).Hash.ToLowerInvariant()
    } else { "" }
    $archiveById[[string]$archivedVersion.id] = [pscustomobject][ordered]@{
        id = [string]$archivedVersion.id
        setId = [string]$archivedVersion.setId
        patch = [string]$archivedVersion.patch
        revision = [string]$archivedVersion.revision
        updateKind = [string]$archivedVersion.updateKind
        generatedAtUtc = ConvertTo-DataUtcTimestamp $archivedVersion.generatedAtUtc
        sourceTimestampUtc = if ($archivedVersion.PSObject.Properties['sourceTimestampUtc']) {
            ConvertTo-DataUtcTimestamp $archivedVersion.sourceTimestampUtc
        } else { "" }
        metaFingerprint = if ($archivedVersion.PSObject.Properties['metaFingerprint']) { [string]$archivedVersion.metaFingerprint } else { "" }
        manifestSha256 = $archivedManifestSha
        archivedAtUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        archivedFromCommit = $archiveCommit
        reason = "bounded-active-history"
    }
    if (Test-Path -LiteralPath $archivedBundle) { Remove-Item -Recurse -Force -LiteralPath $archivedBundle }
}
foreach ($activeVersion in $versions) { $archiveById.Remove([string]$activeVersion.id) }
$archiveDocument = [pscustomobject][ordered]@{
    schemaVersion = 1
    generatedAtUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    recoveryNote = "Archived bundles remain recoverable from the recorded Git commit history."
    entries = @($archiveById.Values | Sort-Object { ConvertTo-DataUtcTimestamp $_.generatedAtUtc } -Descending | Select-Object -First 50)
}
[IO.File]::WriteAllText($archivePath, (($archiveDocument | ConvertTo-Json -Depth 8).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))

# Blobs are content-addressed. Remove only blobs that are no longer referenced
# by any manifest in the bounded active window.
$referencedBlobs = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($retainedVersion in $versions) {
    $retainedManifestPath = Join-Path $stagingRoot ([string]$retainedVersion.manifestUrl)
    $retainedManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $retainedManifestPath | ConvertFrom-Json
    foreach ($fileEntry in @($retainedManifest.files)) {
        if ([string]$fileEntry.url -match '^\.\./\.\./blobs/([0-9a-f]{64}\.[a-z0-9]+)$') {
            $null = $referencedBlobs.Add($Matches[1])
        }
    }
}
foreach ($blob in @(Get-ChildItem -LiteralPath $blobsRoot -File)) {
    if (-not $referencedBlobs.Contains($blob.Name)) { Remove-Item -Force -LiteralPath $blob.FullName }
}
$index = [pscustomobject][ordered]@{
    schemaVersion = 1
    # Legacy clients understand only latestVersionId and cannot safely render a
    # catalog-first partial bundle. Keep it pinned to the formal stable LKG.
    latestVersionId = $latestStableVersionId
    latestStableVersionId = $latestStableVersionId
    latestAvailableVersionId = $versionId
    generatedAtUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    sourceCheckedAtUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    latestObservedSourceTimestampUtc = $sourceTimestampUtc
    freshnessPolicy = [pscustomobject][ordered]@{
        warningAfterSeconds = 21600
        criticalAfterSeconds = 86400
    }
    versions = $versions
}

$indexTempPath = Join-Path $stagingRoot "data-index.next.json"
[IO.File]::WriteAllText($indexTempPath, (($index | ConvertTo-Json -Depth 8).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
Move-Item -Force -LiteralPath $indexTempPath -Destination $indexPath

[IO.File]::WriteAllText((Join-Path $stagingRoot ".nojekyll"), "", [Text.UTF8Encoding]::new($false))
$indexHtml = @"
<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>TFT Overlay Data</title></head><body><main><h1>TFT Overlay Data</h1><p>&#20491;&#20154;&#29992;TFT&#25126;&#34899;&#21442;&#29031;&#12450;&#12503;&#12522;&#12398;&#26908;&#35388;&#28168;&#12415;&#12487;&#12540;&#12479;&#37197;&#20449;&#20808;&#12391;&#12377;&#12290;Riot Games&#12289;MetaTFT&#12289;Overwolf&#12398;&#20844;&#24335;&#12469;&#12540;&#12499;&#12473;&#12391;&#12399;&#12354;&#12426;&#12414;&#12379;&#12435;&#12290;</p><p><a href="data-index.json">data-index.json</a> &middot; <a href="health.json">health.json</a></p></main></body></html>
"@
[IO.File]::WriteAllText((Join-Path $stagingRoot "index.html"), $indexHtml, [Text.UTF8Encoding]::new($false))

$workflowRunId = if ($env:GITHUB_RUN_ID) { [string]$env:GITHUB_RUN_ID } else { "local" }
$freshnessWarningAfterSeconds = 21600
$freshnessCriticalAfterSeconds = 86400
$sourceAgeSeconds = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse(
    $sourceTimestampUtc,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeUniversal
)).TotalSeconds
$freshnessStatus = if ($sourceAgeSeconds -lt -60) {
    "CRITICAL"
} elseif ($sourceAgeSeconds -ge $freshnessCriticalAfterSeconds) {
    "CRITICAL"
} elseif ($sourceAgeSeconds -ge $freshnessWarningAfterSeconds) {
    "WARNING"
} else {
    "FRESH"
}
$stableVersion = @($versions | Where-Object { [string]$_.id -eq $latestStableVersionId }) | Select-Object -First 1
if (-not $stableVersion) { throw "Stable version was lost during retention: $latestStableVersionId" }
$stableManifestPath = Join-Path $stagingRoot ([string]$stableVersion.manifestUrl)
$stableManifestSha256 = if ($stableVersion.PSObject.Properties['manifestSha256'] -and [string]$stableVersion.manifestSha256) {
    [string]$stableVersion.manifestSha256
} else {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $stableManifestPath).Hash.ToLowerInvariant()
}
$health = [pscustomobject][ordered]@{
    status = "ok"
    freshnessStatus = $freshnessStatus
    freshnessSlaSeconds = $freshnessWarningAfterSeconds
    freshnessWarningAfterSeconds = $freshnessWarningAfterSeconds
    freshnessCriticalAfterSeconds = $freshnessCriticalAfterSeconds
    generatedAt = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    publishedAtUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    latestSetId = [string]$stableVersion.setId
    latestPatch = [string]$stableVersion.patch
    latestRevision = [string]$stableVersion.revision
    latestStableVersionId = $latestStableVersionId
    latestAvailableVersionId = $versionId
    latestAvailableSetId = $setId
    latestAvailablePatch = $patch
    latestAvailableRevision = $revision
    versionCount = $versions.Count
    fileCount = 0
    workflowRunId = $workflowRunId
    lastSuccessfulRunId = $workflowRunId
    consecutiveFailures = 0
    sourceUpdatedAt = $sourceTimestampUtc
    latestMetaFingerprint = [string](Get-TftObjectProperty $stableVersion 'metaFingerprint' '')
    latestManifestSha256 = $stableManifestSha256
    sourceQueryHash = [string](Get-TftObjectProperty $stableVersion 'sourceQueryHash' '')
    latestAvailableMetaFingerprint = $MetaFingerprint
    latestAvailableManifestSha256 = $manifestSha256
    latestAvailableSourceQueryHash = $sourceQueryHash
}
$healthPath = Join-Path $stagingRoot "health.json"
[IO.File]::WriteAllText($healthPath, (($health | ConvertTo-Json).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
$health.fileCount = @(Get-ChildItem -LiteralPath $stagingRoot -File -Recurse).Count
[IO.File]::WriteAllText($healthPath, (($health | ConvertTo-Json).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))

& (Join-Path $PSScriptRoot 'write-data-quality-status.ps1') -SiteDirectory $stagingRoot -SnapshotPath $metaSource -CatalogPath $catalogSource
& (Join-Path $PSScriptRoot "validate-site.ps1") -SiteDirectory $stagingRoot

$backupRoot = Join-Path $repositoryRoot "build/site-previous"
if (Test-Path -LiteralPath $backupRoot) { Remove-Item -Recurse -Force -LiteralPath $backupRoot }
try {
    if (Test-Path -LiteralPath $siteRoot) { Move-Item -LiteralPath $siteRoot -Destination $backupRoot }
    Move-Item -LiteralPath $stagingRoot -Destination $siteRoot
    if (Test-Path -LiteralPath $backupRoot) { Remove-Item -Recurse -Force -LiteralPath $backupRoot }
} catch {
    if (-not (Test-Path -LiteralPath $siteRoot) -and (Test-Path -LiteralPath $backupRoot)) { Move-Item -LiteralPath $backupRoot -Destination $siteRoot }
    throw
}

Write-Output "Published local site: Available=$versionId Stable=$latestStableVersionId State=$($releaseContract.releaseState) Kind=$updateKind Files=$($entries.Count) Versions=$($versions.Count)"
