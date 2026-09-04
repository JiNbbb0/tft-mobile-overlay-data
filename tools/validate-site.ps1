param(
    [string]$SiteDirectory = "site"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'release-contract-policy.ps1')

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$root = if ([IO.Path]::IsPathRooted($SiteDirectory)) { [IO.Path]::GetFullPath($SiteDirectory) } else { [IO.Path]::GetFullPath((Join-Path $repositoryRoot $SiteDirectory)) }
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Site directory not found: $root" }

$allFiles = @(Get-ChildItem -LiteralPath $root -File -Recurse)
if ($allFiles.Count -eq 0) { throw "Site is empty" }
if (@($allFiles | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -gt 0) { throw "Symbolic links and reparse points are not allowed" }
$siteBytes = [int64](($allFiles | Measure-Object Length -Sum).Sum)
$siteLimit = [int64]250MB
if ($siteBytes -gt $siteLimit) { throw "Published site exceeds the 250 MiB application distribution limit" }
$usagePercent = [Math]::Round(($siteBytes / $siteLimit) * 100, 2)
$capacityWarning = if ($usagePercent -ge 95) { "CRITICAL_95" } elseif ($usagePercent -ge 85) { "WARNING_85" } elseif ($usagePercent -ge 70) { "WARNING_70" } else { "OK" }

$relativeFileMap = @{}
foreach ($file in $allFiles) {
    $relative = $file.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
    $key = $relative.ToLowerInvariant()
    if ($relativeFileMap.ContainsKey($key)) { throw "Case-insensitive duplicate path: $relative" }
    $relativeFileMap[$key] = $relative
}

$jsonFiles = @($allFiles | Where-Object Extension -eq '.json')
foreach ($jsonFile in $jsonFiles) {
    $raw = [IO.File]::ReadAllText($jsonFile.FullName, [Text.Encoding]::UTF8)
    if ($raw.Contains([char]0xFFFD)) { throw "Japanese text corruption marker found: $($jsonFile.FullName)" }
    try { $null = $raw | ConvertFrom-Json } catch { throw "Invalid JSON: $($jsonFile.FullName): $($_.Exception.Message)" }
}

$indexPath = Join-Path $root "data-index.json"
$healthPath = Join-Path $root "health.json"
foreach ($required in @($indexPath, $healthPath, (Join-Path $root "schema/data-index.schema.json"), (Join-Path $root "schema/manifest.schema.json"), (Join-Path $root "schema/health.schema.json"))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required site file missing: $required" }
}
$index = Get-Content -Raw -Encoding UTF8 -LiteralPath $indexPath | ConvertFrom-Json
if ([int]$index.schemaVersion -ne 1) { throw "Unsupported data-index schema" }
$versions = @($index.versions)
if ($versions.Count -lt 1 -or $versions.Count -gt 100) { throw "Version count outside 1..100" }
if (@($versions.id | Sort-Object -Unique).Count -ne $versions.Count) { throw "Duplicate version ID" }
if (@($versions.id | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique).Count -ne $versions.Count) { throw "Case-insensitive duplicate version ID" }
$latest = @($versions | Where-Object { [string]$_.id -eq [string]$index.latestVersionId }) | Select-Object -First 1
if (-not $latest) { throw "latestVersionId is not present" }
if ([bool]$latest.hidden) { throw "latestVersionId must not point to a hidden version" }
$hasDualPointers = $index.PSObject.Properties['latestStableVersionId'] -or $index.PSObject.Properties['latestAvailableVersionId']
$latestStable = $latest
$latestAvailable = $latest
if ($hasDualPointers) {
    foreach ($field in @('latestStableVersionId','latestAvailableVersionId','sourceCheckedAtUtc','latestObservedSourceTimestampUtc','freshnessPolicy')) {
        if (-not $index.PSObject.Properties[$field]) { throw "Ideal update contract is incomplete: missing $field" }
    }
    if ([string]$index.latestVersionId -ne [string]$index.latestStableVersionId) { throw 'Legacy latestVersionId must alias latestStableVersionId.' }
    $latestStable = @($versions | Where-Object { [string]$_.id -eq [string]$index.latestStableVersionId }) | Select-Object -First 1
    $latestAvailable = @($versions | Where-Object { [string]$_.id -eq [string]$index.latestAvailableVersionId }) | Select-Object -First 1
    if (-not $latestStable -or -not $latestAvailable -or [bool]$latestStable.hidden -or [bool]$latestAvailable.hidden) { throw 'Stable/available pointer is missing or hidden.' }
    $stableContractState = if ($latestStable.PSObject.Properties['releaseState']) { [string]$latestStable.releaseState } elseif ([string]$latestStable.readiness -eq 'META_STABLE') { 'STABLE' } else { '' }
    if ($stableContractState -ne 'STABLE') { throw 'latestStableVersionId must reference a STABLE or legacy META_STABLE version.' }
    if ([int]$index.freshnessPolicy.warningAfterSeconds -ne 21600 -or [int]$index.freshnessPolicy.criticalAfterSeconds -ne 86400) { throw 'Freshness policy must be 6h warning / 24h critical.' }
}

$allowedExtensions = @('.json', '.md', '.png', '.jpg', '.jpeg', '.webp')
$checkedFiles = 0
$manifestByVersion = @{}
foreach ($version in $versions) {
    if ([string]$version.id -notmatch '^[a-z0-9._-]+$') { throw "Unsafe version ID: $($version.id)" }
    if ([string]$version.manifestUrl -notmatch '^bundles/[a-z0-9._-]+/manifest\.json$') { throw "Unsafe manifest URL: $($version.manifestUrl)" }
    if ([string]$version.manifestUrl -ne "bundles/$($version.id)/manifest.json") { throw "Manifest URL and version ID differ: $($version.id)" }
    $manifestPath = [IO.Path]::GetFullPath((Join-Path $root ([string]$version.manifestUrl)))
    if (-not $manifestPath.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Manifest escaped site root" }
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Manifest missing: $($version.id)" }
    $manifestRelative = $manifestPath.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
    if ($relativeFileMap[$manifestRelative.ToLowerInvariant()] -cne $manifestRelative) { throw "Manifest path case mismatch: $manifestRelative" }
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
    $manifestSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant()
    if ($version.PSObject.Properties['manifestSha256'] -and [string]$version.manifestSha256 -ne $manifestSha256) {
        throw "Manifest SHA/index mismatch: $($version.id)"
    }
    $manifestByVersion[[string]$version.id] = [pscustomobject]@{ manifest=$manifest; path=$manifestPath }
    if ([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.id -ne [string]$version.id) { throw "Manifest identity mismatch: $($version.id)" }
    foreach ($field in @('setId','patch','revision','updateKind','readiness','metaFingerprint','sourceQueryHash')) {
        $manifestValue = if ($manifest.PSObject.Properties[$field]) { [string]$manifest.$field } else { '' }
        $indexValue = if ($version.PSObject.Properties[$field]) { [string]$version.$field } else { '' }
        if ($manifestValue -ne $indexValue) { throw "Manifest/index $field mismatch: $($version.id)" }
    }
    if ($version.PSObject.Properties['releaseState'] -or $manifest.PSObject.Properties['releaseState']) {
        foreach ($field in @('releaseState','validationStatus','sourceAlignment','validatedAtUtc')) {
            if (-not $version.PSObject.Properties[$field] -or -not $manifest.PSObject.Properties[$field] -or [string]$version.$field -ne [string]$manifest.$field) { throw "Manifest/index contract field mismatch: $($version.id)/$field" }
        }
        foreach ($field in @('featureReadiness','levelBoardReadiness')) {
            if (-not $version.PSObject.Properties[$field] -or -not $manifest.PSObject.Properties[$field]) { throw "Manifest/index contract field missing: $($version.id)/$field" }
            if (($version.$field | ConvertTo-Json -Depth 10 -Compress) -cne ($manifest.$field | ConvertTo-Json -Depth 10 -Compress)) { throw "Manifest/index contract object mismatch: $($version.id)/$field" }
        }
        if ([string]$version.releaseState -eq 'STABLE' -and ([string]$version.validationStatus -ne 'PASS' -or [string]$version.sourceAlignment -ne 'VERIFIED')) { throw "Stable version lacks verified validation/source alignment: $($version.id)" }
    }
    $files = @($manifest.files)
    if ($files.Count -lt 5 -or $files.Count -gt 1500) { throw "Manifest file count outside 5..1500: $($version.id)" }
    $logicalLower = @($files.path | ForEach-Object { ([string]$_).ToLowerInvariant() })
    if (@($logicalLower | Sort-Object -Unique).Count -ne $files.Count) { throw "Duplicate logical path: $($version.id)" }
    foreach ($requiredPath in @('tft/tft_catalog.json','tft_static_snapshot.json','metadata/DATA_SOURCE_MANIFEST.json','metadata/CHANGE_SUMMARY.json','metadata/CHANGE_SUMMARY.md')) {
        if ($requiredPath -notin @($files.path)) { throw "Required bundle file missing: $($version.id)/$requiredPath" }
    }
    $totalBytes = [int64]0
    foreach ($entry in $files) {
        $logicalPath = [string]$entry.path
        $relativeUrl = [string]$entry.url
        if ($logicalPath -match '(^[./\\])|(^|[\\/])\.\.([\\/]|$)|:') { throw "Unsafe logical path: $logicalPath" }
        if ($relativeUrl -match '^[a-zA-Z]+:' -and $relativeUrl -notmatch '^https://') { throw "Non-HTTPS URL: $relativeUrl" }
        if ($relativeUrl -match '^https://') { throw "Absolute file URLs are not used in manifests: $relativeUrl" }
        $extension = [IO.Path]::GetExtension(($relativeUrl -split '[?#]')[0]).ToLowerInvariant()
        if ($extension -notin $allowedExtensions) { throw "Disallowed extension: $relativeUrl" }
        if ([string]$entry.sha256 -notmatch '^[0-9a-f]{64}$') { throw "Invalid SHA-256: $logicalPath" }
        if ([int64]$entry.bytes -lt 1 -or [int64]$entry.bytes -gt 30MB) { throw "File size outside limit: $logicalPath" }
        $target = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $manifestPath) $relativeUrl))
        if (-not $target.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "File escaped site root: $logicalPath" }
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Referenced file missing: $logicalPath" }
        $targetRelative = $target.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
        if ($relativeFileMap[$targetRelative.ToLowerInvariant()] -cne $targetRelative) { throw "Referenced path case mismatch: $targetRelative" }
        $item = Get-Item -LiteralPath $target
        if ([int64]$item.Length -ne [int64]$entry.bytes) { throw "Size mismatch: $logicalPath" }
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
        if ($hash -ne [string]$entry.sha256) { throw "Hash mismatch: $logicalPath" }
        if ($targetRelative -match '^blobs/([0-9a-f]{64})\.[a-z0-9]+$' -and $Matches[1] -ne $hash) { throw "Blob filename hash mismatch: $targetRelative" }
        $totalBytes += [int64]$entry.bytes
        $checkedFiles++
    }
    if ($totalBytes -gt 250MB) { throw "Version exceeds 250 MiB: $($version.id)" }

    $catalogEntry = @($files | Where-Object { [string]$_.path -eq 'tft/tft_catalog.json' })[0]
    $metaEntry = @($files | Where-Object { [string]$_.path -eq 'tft_static_snapshot.json' })[0]
    $sourceManifestEntry = @($files | Where-Object { [string]$_.path -eq 'metadata/DATA_SOURCE_MANIFEST.json' })[0]
    $catalogPath = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $manifestPath) ([string]$catalogEntry.url)))
    $metaPath = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $manifestPath) ([string]$metaEntry.url)))
    $sourceManifestPath = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $manifestPath) ([string]$sourceManifestEntry.url)))
    $catalog = Get-Content -Raw -Encoding UTF8 -LiteralPath $catalogPath | ConvertFrom-Json
    $meta = Get-Content -Raw -Encoding UTF8 -LiteralPath $metaPath | ConvertFrom-Json
    if ([int]$catalog.schemaVersion -ne 1 -or [int]$meta.schemaVersion -notin @(4,5)) { throw "Unsupported content schema: $($version.id)" }
    if ([string]$catalog.set.id -ne [string]$version.setId -or [string]$meta.setId -ne [string]$version.setId) { throw "Set mismatch: $($version.id)" }
    if ([string]$catalog.set.tftPatch -ne [string]$version.patch) { throw "Patch mismatch: $($version.id)" }
    if ([string]$meta.clusterId -ne [string]$version.revision) { throw "Revision mismatch: $($version.id)" }
    $versionReleaseState = if ($version.PSObject.Properties['releaseState']) { [string]$version.releaseState } else { '' }
    if ($versionReleaseState) {
        $sourceManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $sourceManifestPath | ConvertFrom-Json
        $derivedContract = Resolve-TftReleaseContract -Catalog $catalog -Snapshot $meta -SourceManifest $sourceManifest
        foreach ($field in @('releaseState','validationStatus','sourceAlignment')) {
            if ([string]$version.$field -ne [string]$derivedContract.$field) {
                throw "Derived release contract mismatch: $($version.id)/$field"
            }
        }
        foreach ($field in @('featureReadiness','levelBoardReadiness')) {
            if (($version.$field | ConvertTo-Json -Depth 10 -Compress) -cne ($derivedContract.$field | ConvertTo-Json -Depth 10 -Compress)) {
                throw "Derived release contract object mismatch: $($version.id)/$field"
            }
        }
    }
    if ($versionReleaseState -eq 'STABLE') {
        $syntheticBoards = @($meta.compositions | ForEach-Object { @($_.levelBoards) } | Where-Object { [string]$_.source -notin @('MetaTFT early_options','MetaTFT options') })
        if ($syntheticBoards.Count -gt 0) { throw "Stable version contains synthetic or unknown level boards: $($version.id)" }
    }
    $groups = @($catalog.champions), @($catalog.traits), @($catalog.items), @($catalog.augments)
    $versionReadiness = if ($version.PSObject.Properties['readiness']) { [string]$version.readiness } else { 'META_STABLE' }
    if ($versionReadiness -eq 'META_STABLE') { $groups += ,@($meta.compositions) }
    if (@($groups | Where-Object { @($_).Count -eq 0 }).Count -gt 0) { throw "Zero-record category: $($version.id)" }
    $records = @($catalog.champions) + @($catalog.traits) + @($catalog.items) + @($catalog.augments)
    if (@($records | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.nameJa) }).Count -gt 0) { throw "Empty Japanese name: $($version.id)" }
    $badDescriptions = @($records | Where-Object {
        $description = if ($_.PSObject.Properties['ability']) { [string]$_.ability.descriptionJa } else { [string]$_.descriptionJa }
        [string]::IsNullOrWhiteSpace($description)
    })
    if ($badDescriptions.Count -gt 0) { throw "Empty descriptions: $($version.id) Count=$($badDescriptions.Count)" }
    $unresolvedRecords = @($records | Where-Object {
        $description = if ($_.PSObject.Properties['ability']) { [string]$_.ability.descriptionJa } else { [string]$_.descriptionJa }
        "$($_.nameJa)`n$description" -match '@[^@]+@|%i:|\{\{|\d+\.\d{5,}|NaN|Infinity'
    })
    if ($unresolvedRecords.Count -gt 0) { throw "Unresolved token or user-facing precision leak: $($version.id) Count=$($unresolvedRecords.Count)" }
}

$bundleDirectories = @(Get-ChildItem -LiteralPath (Join-Path $root 'bundles') -Directory | Select-Object -ExpandProperty Name)
if (@($bundleDirectories | Where-Object { $_ -notin @($versions.id) }).Count -gt 0) {
    throw "Unreferenced bundle directory remains after retention"
}
$archiveMapPath = Join-Path $root 'archive-map.json'
if (Test-Path -LiteralPath $archiveMapPath) {
    $archiveMap = Get-Content -Raw -Encoding UTF8 -LiteralPath $archiveMapPath | ConvertFrom-Json
    if ([int]$archiveMap.schemaVersion -ne 1) { throw "Unsupported archive-map schema" }
    $archiveEntries = @($archiveMap.entries)
    if (@($archiveEntries.id | Sort-Object -Unique).Count -ne $archiveEntries.Count) { throw "Duplicate archived version ID" }
    if (@($archiveEntries | Where-Object { [string]$_.id -in @($versions.id) }).Count -gt 0) { throw "Active version also appears in archive-map" }
    foreach ($archiveEntry in $archiveEntries) {
        if ([string]$archiveEntry.id -notmatch '^[a-z0-9._-]+$') { throw "Unsafe archived version ID" }
        if ([string]$archiveEntry.manifestSha256 -and [string]$archiveEntry.manifestSha256 -notmatch '^[0-9a-f]{64}$') { throw "Invalid archived manifest SHA" }
        if ([string]::IsNullOrWhiteSpace([string]$archiveEntry.archivedFromCommit)) { throw "Archive recovery commit is missing" }
    }
}

$orderedVersions = @($versions | Sort-Object generatedAtUtc -Descending)
if ($orderedVersions.Count -ge 2) {
    $currentVersion = $orderedVersions[0]
    $previousVersion = $orderedVersions[1]
    $currentInfo = $manifestByVersion[[string]$currentVersion.id]
    $previousInfo = $manifestByVersion[[string]$previousVersion.id]
    function Get-VersionCounts($Info) {
        $catalogEntry = @($Info.manifest.files | Where-Object path -eq 'tft/tft_catalog.json')[0]
        $metaEntry = @($Info.manifest.files | Where-Object path -eq 'tft_static_snapshot.json')[0]
        $catalog = Get-Content -Raw -Encoding UTF8 -LiteralPath ([IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Info.path) ([string]$catalogEntry.url)))) | ConvertFrom-Json
        $meta = Get-Content -Raw -Encoding UTF8 -LiteralPath ([IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Info.path) ([string]$metaEntry.url)))) | ConvertFrom-Json
        return [pscustomobject]@{ champions=@($catalog.champions).Count; items=@($catalog.items).Count; augments=@($catalog.augments).Count; compositions=@($meta.compositions).Count }
    }
    $currentCounts = Get-VersionCounts $currentInfo
    $previousCounts = Get-VersionCounts $previousInfo
    foreach ($category in @('champions','items','augments','compositions')) {
        $currentReadiness = if ($currentInfo.manifest.PSObject.Properties['readiness']) { [string]$currentInfo.manifest.readiness } else { 'META_STABLE' }
        if ([string]$currentVersion.setId -ne [string]$previousVersion.setId -or $currentReadiness -ne 'META_STABLE') { continue }
        if ([int]$previousCounts.$category -gt 0 -and [double]$currentCounts.$category -lt ([double]$previousCounts.$category * 0.70)) {
            throw "Abnormal record loss in ${category}: $($previousCounts.$category) -> $($currentCounts.$category)"
        }
    }
}

$health = Get-Content -Raw -Encoding UTF8 -LiteralPath $healthPath | ConvertFrom-Json
foreach ($field in @('status','freshnessStatus','freshnessSlaSeconds','generatedAt','publishedAtUtc','latestSetId','latestPatch','latestRevision','versionCount','fileCount','workflowRunId','lastSuccessfulRunId','consecutiveFailures','sourceUpdatedAt','latestMetaFingerprint','latestManifestSha256','sourceQueryHash')) {
    if (-not $health.PSObject.Properties[$field]) { throw "health.json missing $field" }
}
if ([string]$health.status -ne 'ok') { throw "health status is not ok" }
if ([string]$health.latestSetId -ne [string]$latest.setId -or [string]$health.latestPatch -ne [string]$latest.patch -or [string]$health.latestRevision -ne [string]$latest.revision) { throw "health latest fields mismatch" }
if ([int]$health.versionCount -ne $versions.Count) { throw "health version count mismatch" }
if ([int]$health.fileCount -ne $allFiles.Count) { throw "health file count mismatch" }
if ([string]$health.latestMetaFingerprint -ne [string]$latest.metaFingerprint) { throw "health meta fingerprint mismatch" }
if ([string]$health.latestManifestSha256 -ne [string]$latest.manifestSha256) { throw "health manifest SHA mismatch" }
if ([string]$health.sourceQueryHash -ne [string]$latest.sourceQueryHash) { throw "health source query hash mismatch" }
if ($hasDualPointers) {
    foreach ($field in @(
        'freshnessWarningAfterSeconds','freshnessCriticalAfterSeconds',
        'latestStableVersionId','latestAvailableVersionId',
        'latestAvailableSetId','latestAvailablePatch','latestAvailableRevision',
        'latestAvailableMetaFingerprint','latestAvailableManifestSha256','latestAvailableSourceQueryHash'
    )) {
        if (-not $health.PSObject.Properties[$field]) { throw "health.json missing ideal-contract field $field" }
    }
    if ([int]$health.freshnessWarningAfterSeconds -ne 21600 -or [int]$health.freshnessCriticalAfterSeconds -ne 86400) { throw 'health freshness thresholds do not match the 6h/24h policy.' }
    if ([string]$health.latestStableVersionId -ne [string]$index.latestStableVersionId -or [string]$health.latestAvailableVersionId -ne [string]$index.latestAvailableVersionId) { throw 'health stable/available pointers do not match data-index.' }
    if ([string]$health.latestAvailableSetId -ne [string]$latestAvailable.setId -or [string]$health.latestAvailablePatch -ne [string]$latestAvailable.patch -or [string]$health.latestAvailableRevision -ne [string]$latestAvailable.revision) { throw 'health available identity mismatch.' }
    if ([string]$health.latestAvailableMetaFingerprint -ne [string]$latestAvailable.metaFingerprint -or [string]$health.latestAvailableManifestSha256 -ne [string]$latestAvailable.manifestSha256 -or [string]$health.latestAvailableSourceQueryHash -ne [string]$latestAvailable.sourceQueryHash) { throw 'health available content identity mismatch.' }
}

$qualityPath = Join-Path $root 'data-quality.json'
if (Test-Path -LiteralPath $qualityPath) {
    $quality = Get-Content -Raw -Encoding UTF8 -LiteralPath $qualityPath | ConvertFrom-Json
    $expectedQualityVersion = if ($hasDualPointers) { [string]$index.latestAvailableVersionId } else { [string]$index.latestVersionId }
    if ([string]$quality.versionId -ne $expectedQualityVersion) { throw 'data-quality.json must describe latestAvailableVersionId.' }
    if ($hasDualPointers -and [int]$quality.schemaVersion -eq 2) {
        if ([string]$quality.latestStableVersionId -ne [string]$index.latestStableVersionId -or [string]$quality.latestAvailableVersionId -ne [string]$index.latestAvailableVersionId) { throw 'data-quality pointer contract mismatch.' }
        if ($latestAvailable.PSObject.Properties['featureReadiness'] -and ($quality.features | ConvertTo-Json -Depth 10 -Compress) -cne ($latestAvailable.featureReadiness | ConvertTo-Json -Depth 10 -Compress)) { throw 'data-quality/index feature readiness mismatch.' }
    }
}

Write-Output "Site validation passed"
Write-Output "Versions=$($versions.Count) CheckedManifestFiles=$checkedFiles SiteFiles=$($allFiles.Count) Bytes=$siteBytes UsagePercent=$usagePercent Capacity=$capacityWarning Latest=$($index.latestVersionId)"
