param(
    [string]$SiteDirectory = "site",
    [string]$OutputDirectory = "source/current/metadata"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$siteRoot = if ([IO.Path]::IsPathRooted($SiteDirectory)) { [IO.Path]::GetFullPath($SiteDirectory) } else { [IO.Path]::GetFullPath((Join-Path $repositoryRoot $SiteDirectory)) }
$outputRoot = if ([IO.Path]::IsPathRooted($OutputDirectory)) { [IO.Path]::GetFullPath($OutputDirectory) } else { [IO.Path]::GetFullPath((Join-Path $repositoryRoot $OutputDirectory)) }
$catalogPath = Join-Path $repositoryRoot "source/current/tft/tft_catalog.json"
$metaPath = Join-Path $repositoryRoot "source/current/tft_static_snapshot.json"
$currentCatalog = Get-Content -Raw -Encoding UTF8 -LiteralPath $catalogPath | ConvertFrom-Json
$currentMeta = Get-Content -Raw -Encoding UTF8 -LiteralPath $metaPath | ConvertFrom-Json

function Get-ManifestFilePath($Manifest, [string]$LogicalPath, [string]$ManifestPath) {
    $entry = @($Manifest.files | Where-Object { [string]$_.path -eq $LogicalPath }) | Select-Object -First 1
    if (-not $entry) { return $null }
    return [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $ManifestPath) ([string]$entry.url)))
}

$previousCatalog = $null
$previousMeta = $null
$previousManifest = $null
$indexPath = Join-Path $siteRoot "data-index.json"
if (Test-Path -LiteralPath $indexPath) {
    $index = Get-Content -Raw -Encoding UTF8 -LiteralPath $indexPath | ConvertFrom-Json
    $previousVersion = @($index.versions | Where-Object { [string]$_.id -eq [string]$index.latestVersionId }) | Select-Object -First 1
    if ($previousVersion) {
        $manifestPath = [IO.Path]::GetFullPath((Join-Path $siteRoot ([string]$previousVersion.manifestUrl)))
        $previousManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
        $previousCatalogPath = Get-ManifestFilePath $previousManifest "tft/tft_catalog.json" $manifestPath
        $previousMetaPath = Get-ManifestFilePath $previousManifest "tft_static_snapshot.json" $manifestPath
        if ($previousCatalogPath -and (Test-Path -LiteralPath $previousCatalogPath)) { $previousCatalog = Get-Content -Raw -Encoding UTF8 -LiteralPath $previousCatalogPath | ConvertFrom-Json }
        if ($previousMetaPath -and (Test-Path -LiteralPath $previousMetaPath)) { $previousMeta = Get-Content -Raw -Encoding UTF8 -LiteralPath $previousMetaPath | ConvertFrom-Json }
    }
}

function Compare-Records($Current, $Previous) {
    $currentMap = @{}
    foreach ($record in @($Current)) { $currentMap[[string]$record.id] = $record }
    $previousMap = @{}
    foreach ($record in @($Previous)) { $previousMap[[string]$record.id] = $record }
    $added = @($currentMap.Keys | Where-Object { -not $previousMap.ContainsKey($_) } | Sort-Object)
    $removed = @($previousMap.Keys | Where-Object { -not $currentMap.ContainsKey($_) } | Sort-Object)
    $changed = @(
        $currentMap.Keys | Where-Object {
            $previousMap.ContainsKey($_) -and
            (($currentMap[$_] | ConvertTo-Json -Depth 30 -Compress) -ne ($previousMap[$_] | ConvertTo-Json -Depth 30 -Compress))
        } | Sort-Object
    )
    return [pscustomobject][ordered]@{ added = $added; removed = $removed; changed = $changed }
}

$previousCatalogSafe = if ($previousCatalog) { $previousCatalog } else { [pscustomobject]@{ champions=@(); traits=@(); items=@(); augments=@() } }
$previousMetaSafe = if ($previousMeta) { $previousMeta } else { [pscustomobject]@{ compositions=@() } }
$champions = Compare-Records $currentCatalog.champions $previousCatalogSafe.champions
$traits = Compare-Records $currentCatalog.traits $previousCatalogSafe.traits
$items = Compare-Records $currentCatalog.items $previousCatalogSafe.items
$augments = Compare-Records $currentCatalog.augments $previousCatalogSafe.augments
$compositions = Compare-Records $currentMeta.compositions $previousMetaSafe.compositions

$previousCompositions = @{}
foreach ($composition in @($previousMetaSafe.compositions)) { $previousCompositions[[string]$composition.id] = $composition }
$tierChanges = @()
$placementChanges = @()
foreach ($composition in @($currentMeta.compositions)) {
    $before = $previousCompositions[[string]$composition.id]
    if (-not $before) { continue }
    if ([string]$before.tier -ne [string]$composition.tier) {
        $tierChanges += [pscustomobject]@{ id=$composition.id; before=$before.tier; after=$composition.tier }
    }
    if ([Math]::Abs([double]$before.averagePlacement - [double]$composition.averagePlacement) -ge 0.0001) {
        $placementChanges += [pscustomobject]@{ id=$composition.id; before=[double]$before.averagePlacement; after=[double]$composition.averagePlacement }
    }
}

function Get-MissingCount($Catalog, [string]$AssetRoot) {
    $records = @($Catalog.champions) + @($Catalog.traits) + @($Catalog.items) + @($Catalog.augments)
    $missingNames = @($records | Where-Object { -not [string]$_.nameJa }).Count
    $missingDescriptions = @($records | Where-Object {
        $description = if ($_.PSObject.Properties['ability']) { [string]$_.ability.descriptionJa } else { [string]$_.descriptionJa }
        [string]::IsNullOrWhiteSpace($description)
    }).Count
    $missingImages = @($records | Where-Object {
        -not [string]$_.image -or -not (Test-Path -LiteralPath (Join-Path $AssetRoot ([string]$_.image -replace '/', [IO.Path]::DirectorySeparatorChar)))
    }).Count
    return [pscustomobject]@{ names=$missingNames; descriptions=$missingDescriptions; images=$missingImages }
}

$currentMissing = Get-MissingCount $currentCatalog (Join-Path $repositoryRoot "source/current")
$previousMissing = if ($previousCatalog) {
    $previousRecords = @($previousCatalog.champions) + @($previousCatalog.traits) + @($previousCatalog.items) + @($previousCatalog.augments)
    $previousPaths = @{}
    foreach ($entry in @($previousManifest.files)) { $previousPaths[[string]$entry.path] = $true }
    [pscustomobject]@{
        names = @($previousRecords | Where-Object { -not [string]$_.nameJa }).Count
        descriptions = @($previousRecords | Where-Object {
            $description = if ($_.PSObject.Properties['ability']) { [string]$_.ability.descriptionJa } else { [string]$_.descriptionJa }
            [string]::IsNullOrWhiteSpace($description)
        }).Count
        images = @($previousRecords | Where-Object { -not [string]$_.image -or -not $previousPaths.ContainsKey([string]$_.image) }).Count
    }
} else { [pscustomobject]@{ names=0; descriptions=0; images=0 } }
$counts = [ordered]@{
    champions = [ordered]@{ previous=@($previousCatalogSafe.champions).Count; current=@($currentCatalog.champions).Count }
    traits = [ordered]@{ previous=@($previousCatalogSafe.traits).Count; current=@($currentCatalog.traits).Count }
    items = [ordered]@{ previous=@($previousCatalogSafe.items).Count; current=@($currentCatalog.items).Count }
    augments = [ordered]@{ previous=@($previousCatalogSafe.augments).Count; current=@($currentCatalog.augments).Count }
    compositions = [ordered]@{ previous=@($previousMetaSafe.compositions).Count; current=@($currentMeta.compositions).Count }
    images = [ordered]@{ previous=$(if ($previousManifest) { @($previousManifest.files | Where-Object { [string]$_.path -match '^tft/images/' }).Count } else { 0 }); current=@(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot "source/current/tft/images") -File).Count }
}

$summary = [pscustomobject][ordered]@{
    schemaVersion = 1
    generatedAt = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    fromVersionId = $(if ($previousManifest) { [string]$previousManifest.id } else { $null })
    toSetId = [string]$currentMeta.setId
    toPatch = [string]$currentCatalog.set.tftPatch
    toRevision = [string]$currentMeta.clusterId
    champions = $champions
    traits = $traits
    items = $items
    augments = $augments
    compositions = $compositions
    tierChanges = @($tierChanges)
    averagePlacementChanges = @($placementChanges)
    imageChanges = [ordered]@{ previous=$counts.images.previous; current=$counts.images.current; delta=([int]$counts.images.current-[int]$counts.images.previous) }
    missingCounts = [ordered]@{ previous=$previousMissing; current=$currentMissing }
    recordCounts = $counts
}
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$jsonPath = Join-Path $outputRoot "CHANGE_SUMMARY.json"
$mdPath = Join-Path $outputRoot "CHANGE_SUMMARY.md"
[IO.File]::WriteAllText($jsonPath, ($summary | ConvertTo-Json -Depth 12) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
$markdown = @"
# Change Summary

- Generated: $($summary.generatedAt)
- From: $(if ($summary.fromVersionId) { $summary.fromVersionId } else { 'initial publication' })
- To: $($summary.toSetId) / patch $($summary.toPatch) / revision $($summary.toRevision)

| Category | Previous | Current | Added | Removed | Changed |
|---|---:|---:|---:|---:|---:|
| Champions | $($counts.champions.previous) | $($counts.champions.current) | $(@($champions.added).Count) | $(@($champions.removed).Count) | $(@($champions.changed).Count) |
| Traits | $($counts.traits.previous) | $($counts.traits.current) | $(@($traits.added).Count) | $(@($traits.removed).Count) | $(@($traits.changed).Count) |
| Items | $($counts.items.previous) | $($counts.items.current) | $(@($items.added).Count) | $(@($items.removed).Count) | $(@($items.changed).Count) |
| Augments | $($counts.augments.previous) | $($counts.augments.current) | $(@($augments.added).Count) | $(@($augments.removed).Count) | $(@($augments.changed).Count) |
| Compositions | $($counts.compositions.previous) | $($counts.compositions.current) | $(@($compositions.added).Count) | $(@($compositions.removed).Count) | $(@($compositions.changed).Count) |
| Images | $($counts.images.previous) | $($counts.images.current) | - | - | $($summary.imageChanges.delta) delta |

- Tier changes: $(@($tierChanges).Count)
- Average-placement changes: $(@($placementChanges).Count)
- Missing names/descriptions/images: $($currentMissing.names) / $($currentMissing.descriptions) / $($currentMissing.images)
"@
[IO.File]::WriteAllText($mdPath, $markdown + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
Write-Output "Change summary: $jsonPath"
