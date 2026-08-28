param(
    [string]$SiteDirectory = 'site',
    [string]$SnapshotPath = 'source/current/tft_static_snapshot.json',
    [string]$CatalogPath = 'source/current/tft/tft_catalog.json'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
function Resolve-RepoPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $repositoryRoot $Path))
}

$siteRoot = Resolve-RepoPath $SiteDirectory
$snapshotFile = Resolve-RepoPath $SnapshotPath
$catalogFile = Resolve-RepoPath $CatalogPath
$indexFile = Join-Path $siteRoot 'data-index.json'
foreach ($file in @($snapshotFile, $catalogFile, $indexFile)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Required data-quality input missing: $file" }
}

$snapshot = Get-Content -Raw -Encoding UTF8 -LiteralPath $snapshotFile | ConvertFrom-Json
$catalog = Get-Content -Raw -Encoding UTF8 -LiteralPath $catalogFile | ConvertFrom-Json
$index = Get-Content -Raw -Encoding UTF8 -LiteralPath $indexFile | ConvertFrom-Json
$latestVersion = @($index.versions | Where-Object { [string]$_.id -eq [string]$index.latestVersionId }) | Select-Object -First 1
if (-not $latestVersion) { throw 'Latest version is missing from data-index.json.' }
if ([string]$snapshot.setId -ne [string]$catalog.set.id) { throw 'Snapshot/catalog set mismatch while writing data quality status.' }

$compositions = @($snapshot.compositions | Where-Object { $_ -is [pscustomobject] })
$readiness = if ($snapshot.PSObject.Properties['readiness']) { [string]$snapshot.readiness } else { 'META_STABLE' }
$targetCompositionCount = 18
$qualifiedSourceCompositions = 0
if ($snapshot.PSObject.Properties['statisticsScope']) {
    if ($snapshot.statisticsScope.PSObject.Properties['minimumPreferredCompositions']) {
        $targetCompositionCount = [Math]::Max(1, [int]$snapshot.statisticsScope.minimumPreferredCompositions)
    }
    if ($snapshot.statisticsScope.PSObject.Properties['qualifiedEffectiveCompositions']) {
        $qualifiedSourceCompositions = [Math]::Max(0, [int]$snapshot.statisticsScope.qualifiedEffectiveCompositions)
    }
}
$missingAugmentCompositions = @($compositions | Where-Object { @($_.recommendedAugments).Count -eq 0 }).Count
$qualityState = if ($compositions.Count -eq 0) {
    'CATALOG_ONLY'
} elseif ($compositions.Count -lt $targetCompositionCount -or $missingAugmentCompositions -gt 0) {
    'DEGRADED_OPTIONAL'
} else {
    'READY'
}

$warningCodes = [Collections.Generic.List[string]]::new()
if ($compositions.Count -eq 0) {
    $warningCodes.Add('COMPOSITIONS_COLLECTING')
    if ($qualifiedSourceCompositions -ge $targetCompositionCount) {
        $warningCodes.Add('UPSTREAM_COMPOSITIONS_AVAILABLE_BUT_NOT_RENDERABLE')
    }
} elseif ($compositions.Count -lt $targetCompositionCount) {
    $warningCodes.Add('COMPOSITION_COUNT_BELOW_TARGET')
}
if ($missingAugmentCompositions -gt 0) { $warningCodes.Add('COMPOSITION_AUGMENTS_COLLECTING') }

$userMessageJa = switch ($qualityState) {
    'CATALOG_ONLY' { '新セットの図鑑データは利用できます。構成データは現在収集中です。データが揃い次第、自動更新されます。' }
    'DEGRADED_OPTIONAL' { '構成データは利用できます。一部のおすすめ情報は現在収集中です。データが揃い次第、自動更新されます。' }
    default { '' }
}
$userMessageEn = switch ($qualityState) {
    'CATALOG_ONLY' { 'Catalog data is available. Composition data is still being collected and will update automatically.' }
    'DEGRADED_OPTIONAL' { 'Composition data is available. Some recommendations are still being collected and will update automatically.' }
    default { '' }
}

$sourceUpdatedAtUtc = if ($snapshot.PSObject.Properties['statsUpdatedEpochMs'] -and [int64]$snapshot.statsUpdatedEpochMs -gt 0) {
    [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$snapshot.statsUpdatedEpochMs).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
} else {
    [string]$snapshot.fetchedAtUtc
}

$status = [pscustomobject][ordered]@{
    schemaVersion = 1
    generatedAtUtc = [string]$snapshot.fetchedAtUtc
    sourceUpdatedAtUtc = $sourceUpdatedAtUtc
    versionId = [string]$index.latestVersionId
    setId = [string]$snapshot.setId
    setNumber = [int]$catalog.set.number
    setName = [string]$catalog.set.nameJa
    patch = [string]$catalog.set.tftPatch
    revision = [string]$snapshot.clusterId
    readiness = $readiness
    qualityState = $qualityState
    userMessageJa = $userMessageJa
    userMessageEn = $userMessageEn
    features = [ordered]@{
        catalog = 'READY'
        compositions = $(if ($compositions.Count -eq 0) { 'COLLECTING' } elseif ($compositions.Count -lt $targetCompositionCount) { 'PARTIAL' } else { 'READY' })
        compositionAugments = $(if ($missingAugmentCompositions -gt 0) { 'COLLECTING' } else { 'READY' })
    }
    counts = [ordered]@{
        champions = @($catalog.champions).Count
        traits = @($catalog.traits).Count
        items = @($catalog.items).Count
        augments = @($catalog.augments).Count
        compositions = $compositions.Count
        targetCompositions = $targetCompositionCount
        qualifiedSourceCompositions = $qualifiedSourceCompositions
        missingAugmentCompositions = $missingAugmentCompositions
    }
    warnings = @($warningCodes.ToArray())
}

$outputPath = Join-Path $siteRoot 'data-quality.json'
$json = ($status | ConvertTo-Json -Depth 10).Replace("`r`n", "`n") + "`n"
[IO.File]::WriteAllText($outputPath, $json, [Text.UTF8Encoding]::new($false))
Write-Output "Wrote data quality status: Quality=$qualityState Compositions=$($compositions.Count)/$targetCompositionCount MissingAugmentComps=$missingAugmentCompositions"
