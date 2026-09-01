param(
    [string]$SiteDirectory = 'site',
    [string]$SnapshotPath = 'source/current/tft_static_snapshot.json',
    [string]$CatalogPath = 'source/current/tft/tft_catalog.json',
    [string]$EmblemQualityPath = 'build/canonical-v2-live/emblem-quality.json',
    [string]$ReleaseId = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'rank-scope-policy.ps1')

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
function Resolve-RepoPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $repositoryRoot $Path))
}
function Get-PropertyValue($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}
function Count-UnresolvedTokens([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    $patterns = @(
        '@[^@\r\n]+@',
        '\{\{[^}\r\n]+\}\}',
        '任意の',
        '可変値',
        '戦闘中に変動'
    )
    $count = 0
    foreach ($pattern in $patterns) { $count += [regex]::Matches($Text, $pattern).Count }
    return $count
}
function Convert-ToUtcIso([string]$Value, [string]$Context) {
    try { return [DateTimeOffset]::Parse($Value).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ') }
    catch { throw "Invalid timestamp for ${Context}: $Value" }
}

$siteRoot = Resolve-RepoPath $SiteDirectory
$snapshotFile = Resolve-RepoPath $SnapshotPath
$catalogFile = Resolve-RepoPath $CatalogPath
$emblemQualityFile = Resolve-RepoPath $EmblemQualityPath
$indexFile = Join-Path $siteRoot 'data-index.json'
foreach ($file in @($snapshotFile, $catalogFile, $emblemQualityFile, $indexFile)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Required data-quality input missing: $file" }
}

$snapshotText = Get-Content -Raw -Encoding UTF8 -LiteralPath $snapshotFile
$catalogText = Get-Content -Raw -Encoding UTF8 -LiteralPath $catalogFile
$snapshot = $snapshotText | ConvertFrom-Json
$catalog = $catalogText | ConvertFrom-Json
$emblemQuality = Get-Content -Raw -Encoding UTF8 -LiteralPath $emblemQualityFile | ConvertFrom-Json
$index = Get-Content -Raw -Encoding UTF8 -LiteralPath $indexFile | ConvertFrom-Json

if ([string]$snapshot.setId -ne [string]$catalog.set.id) { throw 'Snapshot/catalog set mismatch while writing data quality status.' }
if ([int](Get-PropertyValue $emblemQuality 'schemaVersion' 0) -ne 1) { throw 'Unsupported emblem-quality schema.' }
if ([string]$emblemQuality.setId -ne [string]$catalog.set.id -or [int]$emblemQuality.setNumber -ne [int]$catalog.set.number) {
    throw "EMBLEM_QUALITY_SET_MISMATCH catalog=$($catalog.set.id)/$($catalog.set.number) audit=$($emblemQuality.setId)/$($emblemQuality.setNumber)"
}

if (-not $ReleaseId) { $ReleaseId = [string]$index.latestVersionId }
if (-not $ReleaseId) { throw 'data-quality v2 requires a non-empty releaseId.' }
$releaseVersion = @($index.versions | Where-Object { [string]$_.id -eq $ReleaseId }) | Select-Object -First 1
if (-not $releaseVersion) { throw "data-quality release is not registered in data-index.json: $ReleaseId" }
if ([string]$releaseVersion.setId -ne [string]$catalog.set.id) { throw 'data-quality release/catalog set mismatch.' }

$emblemMissingEligible = [Math]::Max(0, [int](Get-PropertyValue $emblemQuality 'missingEligible' 0))
$emblemDuplicateMappings = [Math]::Max(0, [int](Get-PropertyValue $emblemQuality 'duplicateMappings' 0))
$emblemMissingImages = [Math]::Max(0, [int](Get-PropertyValue $emblemQuality 'missingImages' 0))
$emblemStatus = if ($emblemMissingEligible -eq 0 -and $emblemDuplicateMappings -eq 0 -and $emblemMissingImages -eq 0 -and [string]$emblemQuality.status -eq 'READY') { 'READY' } else { 'BLOCKED' }

$compositions = @($snapshot.compositions | Where-Object { $_ -is [pscustomobject] })
$readiness = if ($snapshot.PSObject.Properties['readiness']) { [string]$snapshot.readiness } else { 'META_STABLE' }
$targetCompositionCount = 18
$qualifiedSourceCompositions = 0
$effectiveScope = 'PLATINUM_PLUS'
if ($snapshot.PSObject.Properties['statisticsScope']) {
    if ($snapshot.statisticsScope.PSObject.Properties['minimumPreferredCompositions']) {
        $targetCompositionCount = [Math]::Max(1, [int]$snapshot.statisticsScope.minimumPreferredCompositions)
    }
    if ($snapshot.statisticsScope.PSObject.Properties['qualifiedEffectiveCompositions']) {
        $qualifiedSourceCompositions = [Math]::Max(0, [int]$snapshot.statisticsScope.qualifiedEffectiveCompositions)
    }
    if ($snapshot.statisticsScope.PSObject.Properties['effective'] -and $snapshot.statisticsScope.effective) {
        $effectiveScope = [string]$snapshot.statisticsScope.effective
    }
}
$scopeContract = Resolve-RankScopeQualityContract -EffectiveScope $effectiveScope
$limitedPlatinumCoverage = [bool]$scopeContract.isLimited

$missingAugmentCompositions = @($compositions | Where-Object { @($_.recommendedAugments).Count -eq 0 }).Count
$levelBoards = @(
    foreach ($composition in $compositions) {
        foreach ($board in @(Get-PropertyValue -Object $composition -Name 'levelBoards' -Default @())) {
            if ($null -ne $board) { $board }
        }
    }
)
$syntheticBoardCount = @($levelBoards | Where-Object { [bool](Get-PropertyValue -Object $_ -Name 'synthetic' -Default $false) }).Count
$unknownBoardUnitCount = 0
$championIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($champion in @($catalog.champions)) { if ($champion.id) { [void]$championIds.Add([string]$champion.id) } }
foreach ($board in $levelBoards) {
    foreach ($unitId in @(Get-PropertyValue -Object $board -Name 'unitIds' -Default @())) {
        if ($unitId -and -not $championIds.Contains([string]$unitId)) { $unknownBoardUnitCount++ }
    }
}
if ($syntheticBoardCount -gt 0) { throw "DATA_QUALITY_SYNTHETIC_BOARDS count=$syntheticBoardCount" }
if ($unknownBoardUnitCount -gt 0) { throw "DATA_QUALITY_UNKNOWN_BOARD_UNITS count=$unknownBoardUnitCount" }

$recommendedItemRecords = 0
$itemStatsProperty = $snapshot.PSObject.Properties['itemStats']
if ($itemStatsProperty -and $itemStatsProperty.Value) { $recommendedItemRecords = @($itemStatsProperty.Value).Count }
if ($recommendedItemRecords -eq 0) {
    foreach ($composition in $compositions) {
        foreach ($unitData in @(Get-PropertyValue -Object $composition -Name 'itemData' -Default @())) {
            $recommendedItemRecords += @((Get-PropertyValue -Object $unitData -Name 'recommended' -Default @())).Count
        }
    }
}

$unresolvedTokens = (Count-UnresolvedTokens -Text $catalogText) + (Count-UnresolvedTokens -Text $snapshotText)
if ($unresolvedTokens -gt 0) { throw "DATA_QUALITY_UNRESOLVED_TOKENS count=$unresolvedTokens" }

$qualityState = if ($compositions.Count -eq 0) {
    'CATALOG_ONLY'
} elseif ($limitedPlatinumCoverage -or $compositions.Count -lt $targetCompositionCount -or $missingAugmentCompositions -gt 0 -or $levelBoards.Count -eq 0 -or $recommendedItemRecords -eq 0 -or $emblemStatus -ne 'READY') {
    'DEGRADED_OPTIONAL'
} else {
    'READY'
}

$warningCodes = [Collections.Generic.List[string]]::new()
if ($limitedPlatinumCoverage) { $warningCodes.Add('PLATINUM_PLUS_COVERAGE_LIMITED') }
if ($compositions.Count -eq 0) {
    $warningCodes.Add('COMPOSITIONS_COLLECTING')
    if ($qualifiedSourceCompositions -ge $targetCompositionCount) {
        $warningCodes.Add('UPSTREAM_COMPOSITIONS_AVAILABLE_BUT_NOT_RENDERABLE')
    }
} elseif ($compositions.Count -lt $targetCompositionCount) {
    $warningCodes.Add('COMPOSITION_COUNT_BELOW_TARGET')
}
if ($missingAugmentCompositions -gt 0) { $warningCodes.Add('COMPOSITION_AUGMENTS_COLLECTING') }
if ($levelBoards.Count -eq 0) { $warningCodes.Add('LEVEL_BOARDS_COLLECTING') }
if ($recommendedItemRecords -eq 0) { $warningCodes.Add('RECOMMENDED_ITEMS_COLLECTING') }
if ($emblemStatus -ne 'READY') { $warningCodes.Add('EMBLEM_MAPPING_BLOCKED') }

$userMessageJa = switch ($qualityState) {
    'CATALOG_ONLY' { '新セットの図鑑データは利用できます。構成データは現在収集中です。データが揃い次第、自動更新されます。' }
    'DEGRADED_OPTIONAL' { '利用可能なデータを表示しています。一部の情報は検証中または収集中です。検証済みデータのみ自動更新されます。' }
    default { '' }
}
$userMessageEn = switch ($qualityState) {
    'CATALOG_ONLY' { 'Catalog data is available. Composition data is still being collected and will update automatically.' }
    'DEGRADED_OPTIONAL' { 'Validated data is shown. Some information is still being validated or collected and will update automatically when verified.' }
    default { '' }
}

$sourceUpdatedAtUtc = if ($snapshot.PSObject.Properties['statsUpdatedEpochMs'] -and [int64]$snapshot.statsUpdatedEpochMs -gt 0) {
    [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$snapshot.statsUpdatedEpochMs).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
} else {
    Convert-ToUtcIso -Value ([string]$snapshot.fetchedAtUtc) -Context 'snapshot.fetchedAtUtc'
}
$generatedAtUtc = Convert-ToUtcIso -Value ([string]$snapshot.fetchedAtUtc) -Context 'snapshot.fetchedAtUtc'

$status = [pscustomobject][ordered]@{
    schemaVersion = 2
    releaseId = $ReleaseId
    generatedAtUtc = $generatedAtUtc
    sourceUpdatedAtUtc = $sourceUpdatedAtUtc
    versionId = $ReleaseId
    setId = [string]$snapshot.setId
    setNumber = [int]$catalog.set.number
    setName = [string]$catalog.set.nameJa
    patch = [string]$catalog.set.tftPatch
    revision = [string]$snapshot.clusterId
    readiness = $readiness
    qualityState = $qualityState
    overall = $qualityState
    userMessageJa = $userMessageJa
    userMessageEn = $userMessageEn
    features = [ordered]@{
        champions = [ordered]@{ status = 'READY'; unresolvedTokens = 0 }
        traits = [ordered]@{ status = 'READY'; unresolvedTokens = 0 }
        emblems = [ordered]@{
            status = $emblemStatus
            missingEligible = $emblemMissingEligible
            duplicateMappings = $emblemDuplicateMappings
            missingImages = $emblemMissingImages
        }
        compositions = [ordered]@{
            status = $(if ($compositions.Count -eq 0) { 'COLLECTING' } elseif ($limitedPlatinumCoverage -or $compositions.Count -lt $targetCompositionCount) { 'PARTIAL' } else { 'READY' })
            filter = [string]$scopeContract.rankFilter
            sourceScope = [string]$scopeContract.sourceScope
            coverage = [string]$scopeContract.coverage
            queue = 'RANKED'
            patch = 'CURRENT'
            days = 3
            permitFilterAdjustment = $false
        }
        boards = [ordered]@{
            status = $(if ($levelBoards.Count -gt 0) { 'READY' } else { 'COLLECTING' })
            syntheticBoardCount = $syntheticBoardCount
            unknownUnitCount = $unknownBoardUnitCount
        }
        recommendedItems = [ordered]@{
            status = $(if ($recommendedItemRecords -gt 0) { 'READY' } else { 'COLLECTING' })
            unresolvedItemIds = 0
        }
        compositionAugments = [ordered]@{
            status = $(if ($missingAugmentCompositions -gt 0) { 'COLLECTING' } else { 'READY' })
            missingCompositions = $missingAugmentCompositions
        }
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
        levelBoards = $levelBoards.Count
        recommendedItemRecords = $recommendedItemRecords
        unresolvedTokens = $unresolvedTokens
    }
    warnings = @($warningCodes.ToArray())
}

if ([string]$status.releaseId -ne [string]$status.versionId) { throw 'data-quality releaseId/versionId mismatch.' }
$outputPath = Join-Path $siteRoot 'data-quality.json'
$json = ($status | ConvertTo-Json -Depth 20).Replace("`r`n", "`n") + "`n"
[IO.File]::WriteAllText($outputPath, $json, [Text.UTF8Encoding]::new($false))
Write-Output "Wrote data quality v2: Release=$ReleaseId Quality=$qualityState Emblems=$emblemStatus Compositions=$($compositions.Count)/$targetCompositionCount Boards=$($levelBoards.Count) RecommendedItems=$recommendedItemRecords MissingAugmentComps=$missingAugmentCompositions"
