param(
    [string]$OutputPath = 'build/canonical-v2-live/live-canonical-dryrun.json',
    [int]$CompositionLimit = 18,
    [int]$MinimumSamples = 500,
    [int]$MaximumBoardsPerLevel = 3,
    [int]$MinimumItemSamples = 50
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Convert-MetaTftSnapshot.ps1')
. (Join-Path $PSScriptRoot 'Convert-MetaTftBoards.ps1')
. (Join-Path $PSScriptRoot 'Convert-MetaTftItems.ps1')
. (Join-Path $PSScriptRoot '..\source-contract.ps1')
. (Join-Path $PSScriptRoot '..\normalize\Get-CurrentSetUniverse.ps1')

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$resolvedOutput = if ([IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path $repoRoot $OutputPath }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
$userAgent = 'TFT-Mobile-Overlay-Data/1.0 canonical-v2-live-dryrun'
$rankFilter = 'CHALLENGER,DIAMOND,EMERALD,GRANDMASTER,MASTER,PLATINUM'

function Get-PublicText([string]$Url) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $lines = & curl.exe -L --fail --silent --show-error --max-time 120 -A $userAgent $Url
        if ($LASTEXITCODE -eq 0) { return ($lines -join "`n") }
        if ($attempt -lt 3) { Start-Sleep -Seconds (2 * $attempt) }
    }
    throw "Public source request failed: $Url"
}
function Get-PublicJson([string]$Url) {
    $text = Get-PublicText -Url $Url
    try { return $text | ConvertFrom-Json } catch { throw "Invalid JSON from $Url" }
}
function Get-LooseItemKey([string]$ItemId) {
    if (-not $ItemId) { return '' }
    return (($ItemId -replace '^(?:TFT\d*_Item_|TFT_Item_|DA_)', '').ToLowerInvariant())
}
function Get-ItemNameKey([string]$Name) {
    if (-not $Name) { return '' }
    $normalized = $Name.Normalize([Text.NormalizationForm]::FormKC).Trim().ToLowerInvariant()
    return [regex]::Replace($normalized, '[\p{P}\p{Z}\s]+', '')
}
function Get-OptionalPropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

$robots = Get-PublicText -Url 'https://www.metatft.com/robots.txt'
if (Test-RobotsSiteWideBlock -RobotsText $robots -UserAgent '*') {
    throw 'MetaTFT robots.txt contains a site-wide block; dry-run aborted.'
}

$catalogPath = Join-Path $repoRoot 'source/current/tft/tft_catalog.json'
$catalog = Get-Content -Raw -Encoding UTF8 -LiteralPath $catalogPath | ConvertFrom-Json
$catalogChampionIds = @{}
foreach ($champion in @($catalog.champions)) { if ($champion.id) { $catalogChampionIds[[string]$champion.id] = $true } }
$catalogItemIds = @{}
$catalogItemLoose = @{}
$ambiguousLoose = @{}
$catalogItemByName = @{}
$ambiguousNames = @{}
foreach ($item in @($catalog.items)) {
    $id = [string]$item.id
    if (-not $id) { continue }
    $catalogItemIds[$id] = $true

    $key = Get-LooseItemKey -ItemId $id
    if ($key) {
        if ($catalogItemLoose.ContainsKey($key) -and [string]$catalogItemLoose[$key] -ne $id) {
            $ambiguousLoose[$key] = $true
        } elseif (-not $catalogItemLoose.ContainsKey($key)) {
            $catalogItemLoose[$key] = $id
        }
    }

    foreach ($nameValue in @([string]$item.nameJa, [string]$item.nameEn)) {
        $nameKey = Get-ItemNameKey -Name $nameValue
        if (-not $nameKey) { continue }
        if ($catalogItemByName.ContainsKey($nameKey) -and [string]$catalogItemByName[$nameKey] -ne $id) {
            $ambiguousNames[$nameKey] = $true
        } elseif (-not $catalogItemByName.ContainsKey($nameKey)) {
            $catalogItemByName[$nameKey] = $id
        }
    }
}
foreach ($key in @($ambiguousLoose.Keys)) { $catalogItemLoose.Remove([string]$key) }
foreach ($key in @($ambiguousNames.Keys)) { $catalogItemByName.Remove([string]$key) }
$catalogAugmentIds = @{}
foreach ($augment in @($catalog.augments)) { if ($augment.id) { $catalogAugmentIds[[string]$augment.id] = $true } }
$sourceItemNamesById = @{}

function Add-SourceItemNames($SourceItems) {
    foreach ($sourceItem in @($SourceItems)) {
        $sourceId = [string](Get-OptionalPropertyValue -Object $sourceItem -Name 'apiName')
        $sourceName = [string](Get-OptionalPropertyValue -Object $sourceItem -Name 'name')
        if (-not $sourceId -or -not $sourceName) { continue }
        if (-not $sourceItemNamesById.ContainsKey($sourceId)) {
            $sourceItemNamesById[$sourceId] = [Collections.Generic.List[string]]::new()
        }
        $nameList = $sourceItemNamesById[$sourceId]
        if (-not $nameList.Contains($sourceName)) { $nameList.Add($sourceName) }
    }
}

function Resolve-CanonicalItemId([string]$RawId) {
    if (-not $RawId) { return '' }
    if ($catalogItemIds.ContainsKey($RawId)) { return $RawId }

    $key = Get-LooseItemKey -ItemId $RawId
    if ($key -and $catalogItemLoose.ContainsKey($key)) { return [string]$catalogItemLoose[$key] }

    if ($sourceItemNamesById.ContainsKey($RawId)) {
        $resolvedByName = @(
            @(
                foreach ($sourceName in @($sourceItemNamesById[$RawId])) {
                    $nameKey = Get-ItemNameKey -Name ([string]$sourceName)
                    if ($nameKey -and $catalogItemByName.ContainsKey($nameKey)) {
                        [string]$catalogItemByName[$nameKey]
                    }
                }
            ) | Select-Object -Unique
        )
        if ($resolvedByName.Count -eq 1) { return [string]$resolvedByName[0] }
        if ($resolvedByName.Count -gt 1) {
            throw "AMBIGUOUS_ITEM_NAME_MAPPING raw=$RawId candidates=$($resolvedByName -join ',')"
        }
    }
    return $RawId
}

$clusterResponse = Get-PublicJson -Url 'https://api-hc.metatft.com/tft-comps-api/latest_cluster_info'
$cluster = $clusterResponse.cluster_info
if (-not $cluster -or -not $cluster.cluster_id -or -not $cluster.tft_set) { throw 'latest_cluster_info shape changed.' }
$clusterId = [int]$cluster.cluster_id
if ([string]$catalog.set.id -ne [string]$cluster.tft_set) {
    throw "CATALOG_SET_MISMATCH catalog=$($catalog.set.id) live=$($cluster.tft_set)"
}

# MetaTFT and CommunityDragon can expose semantically identical items under
# different API namespaces (for example DA_* versus TFT_Item_*). Use exact ID,
# then an unambiguous loose ID key, then an unambiguous localized/English name.
# Name matching is unique-only: ambiguous names fail instead of guessing.
Start-Sleep -Milliseconds 350
$communityDragonJa = Get-PublicJson -Url 'https://raw.communitydragon.org/latest/cdragon/tft/ja_jp.json'
Start-Sleep -Milliseconds 350
$communityDragonEn = Get-PublicJson -Url 'https://raw.communitydragon.org/latest/cdragon/tft/en_us.json'
Add-SourceItemNames -SourceItems $communityDragonJa.items
Add-SourceItemNames -SourceItems $communityDragonEn.items

$sourceSetMatches = @(
    $communityDragonJa.setData |
        Where-Object { [string]$_.mutator -eq [string]$cluster.tft_set } |
        Select-Object -First 1
)
if ($sourceSetMatches.Count -ne 1) {
    throw "COMMUNITYDRAGON_SET_NOT_FOUND set=$($cluster.tft_set)"
}
$sourceSet = $sourceSetMatches[0]
$sourceItemsJaById = @{}
foreach ($sourceItem in @($communityDragonJa.items)) {
    $sourceId = [string](Get-OptionalPropertyValue -Object $sourceItem -Name 'apiName')
    if ($sourceId) { $sourceItemsJaById[$sourceId] = $sourceItem }
}
$sourceItemsEnById = @{}
foreach ($sourceItem in @($communityDragonEn.items)) {
    $sourceId = [string](Get-OptionalPropertyValue -Object $sourceItem -Name 'apiName')
    if ($sourceId) { $sourceItemsEnById[$sourceId] = $sourceItem }
}

Start-Sleep -Milliseconds 350
$compsData = Get-PublicJson -Url 'https://api-hc.metatft.com/tft-comps-api/comps_data'
Start-Sleep -Milliseconds 350
$compsStats = Get-PublicJson -Url "https://api-hc.metatft.com/tft-comps-api/comps_stats?queue=1100&patch=current&days=3&rank=$rankFilter&permit_filter_adjustment=false"
Assert-MetaTftStatsContract -Stats $compsStats `
    -ExpectedSetId ([string]$cluster.tft_set) `
    -ExpectedClusterId $clusterId `
    -ExpectedRankFilter $rankFilter `
    -Context 'Canonical v2 live dry-run Platinum+ comps_stats'

$filter = [pscustomobject]@{
    queue = '1100'
    patch = 'current'
    days = 3
    rank = $rankFilter
    permitFilterAdjustment = $false
}
$snapshot = Convert-MetaTftCompositionSnapshot `
    -ClusterInfo $cluster `
    -CompsData $compsData `
    -CompsStats $compsStats `
    -Filter $filter `
    -MinimumSamples $MinimumSamples
$selected = @($snapshot.compositions | Select-Object -First $CompositionLimit)
if ($selected.Count -lt $CompositionLimit) {
    throw "PLATINUM_PLUS_COVERAGE_INSUFFICIENT required=$CompositionLimit actual=$($selected.Count) minimumSamples=$MinimumSamples"
}

$observedRawItemIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$canonicalItemIdByRaw = @{}
$resolvedAliasRows = [Collections.Generic.List[object]]::new()
$compositions = [Collections.Generic.List[object]]::new()
foreach ($composition in $selected) {
    $compositionId = [string]$composition.id
    Start-Sleep -Milliseconds 350
    $detailsResponse = Get-PublicJson -Url "https://api-hc.metatft.com/tft-comps-api/comp_details?comp=$compositionId&cluster_id=$clusterId"
    $details = $detailsResponse.results
    if (-not $details) { throw "METATFT_SCHEMA_MISMATCH comp_details missing results for $compositionId" }

    $unitIds = @(
        ([string]$composition.unitsString -split ',\s*') |
            Where-Object { $_ } |
            ForEach-Object { [string]$_ }
    )
    if ($unitIds.Count -eq 0) { throw "NO_COMPOSITION_UNITS $compositionId" }
    foreach ($unitId in $unitIds) {
        if (-not $catalogChampionIds.ContainsKey($unitId)) { throw "UNKNOWN_CURRENT_SET_UNIT $compositionId/$unitId" }
    }

    $rawItemIds = @(
        @($composition.overviewBuilds) + @($details.builds) |
            ForEach-Object { @($_.buildName) } |
            ForEach-Object { $_ } |
            Where-Object { $_ } |
            ForEach-Object { [string]$_ } |
            Select-Object -Unique
    )
    $canonicalItemIdMap = @{}
    foreach ($rawItemId in $rawItemIds) {
        [void]$observedRawItemIds.Add($rawItemId)
        $canonicalItemId = Resolve-CanonicalItemId -RawId $rawItemId
        $canonicalItemIdMap[$rawItemId] = $canonicalItemId
        $canonicalItemIdByRaw[$rawItemId] = $canonicalItemId
        if ($canonicalItemId -ne $rawItemId) {
            $resolvedAliasRows.Add([pscustomobject][ordered]@{ raw = $rawItemId; canonical = $canonicalItemId })
        }
    }

    $unitItemData = [Collections.Generic.List[object]]::new()
    foreach ($unitId in @($unitIds | Select-Object -Unique)) {
        $itemData = Convert-MetaTftUnitItemData `
            -UnitId $unitId `
            -OverviewBuilds @($composition.overviewBuilds) `
            -CompBuildRows @($details.builds) `
            -CanonicalItemIdMap $canonicalItemIdMap `
            -MinimumCorrelationSamples $MinimumItemSamples
        $unitItemData.Add($itemData)
    }

    $directAugments = [Collections.Generic.List[object]]::new()
    foreach ($augmentRow in @($details.augments)) {
        if ($null -eq $augmentRow) { continue }
        $augmentProperty = $augmentRow.PSObject.Properties['aug']
        if (-not $augmentProperty -or -not $augmentProperty.Value) { continue }
        $augmentId = [string]$augmentProperty.Value
        if (-not $catalogAugmentIds.ContainsKey($augmentId)) { continue }
        $directAugments.Add([pscustomobject][ordered]@{
            id = $augmentId
            averagePlacement = if ($augmentRow.PSObject.Properties['avg']) { [Math]::Round([double]$augmentRow.avg, 4) } else { $null }
            sampleCount = if ($augmentRow.PSObject.Properties['count']) { [int]$augmentRow.count } else { 0 }
            pickRate = if ($augmentRow.PSObject.Properties['pcnt']) { [Math]::Round([double]$augmentRow.pcnt, 6) } else { $null }
            source = 'MetaTFT comp_details.augments'
            sourceSemantics = 'DIRECT_COMP_AUGMENT_STAT'
        })
    }
    $recommendedAugments = @(
        $directAugments.ToArray() |
            Sort-Object @{ Expression = { -[int]$_.sampleCount } }, averagePlacement, id |
            Select-Object -First 10
    )

    $boards = @(Convert-MetaTftLevelBoards -Details $details -MaximumBoardsPerLevel $MaximumBoardsPerLevel)
    $compositions.Add([pscustomobject][ordered]@{
        id = $compositionId
        averagePlacement = [double]$composition.averagePlacement
        sampleCount = [int]$composition.sampleCount
        sourceRank = $compositions.Count + 1
        unitIds = @($unitIds)
        itemData = @($unitItemData)
        recommendedAugments = @($recommendedAugments)
        levelBoards = @($boards)
        source = 'MetaTFT Platinum+ current patch 3-day public statistics'
    })
}

# Only materialize source-observed items that actually survive into the
# canonical output. MetaTFT comp_details can contain build rows for units that
# are not part of the selected composition; those rows must not expand the
# published item universe.
$referencedCanonicalItemIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($composition in @($compositions)) {
    foreach ($unitData in @($composition.itemData)) {
        foreach ($recommended in @($unitData.recommended)) {
            foreach ($itemId in @($recommended.itemIds)) { if ($itemId) { [void]$referencedCanonicalItemIds.Add([string]$itemId) } }
        }
        foreach ($popularity in @($unitData.derivedPopularity)) {
            if ($popularity.itemId) { [void]$referencedCanonicalItemIds.Add([string]$popularity.itemId) }
        }
        foreach ($correlation in @($unitData.averagePlacementCorrelations)) {
            if ($correlation.itemId) { [void]$referencedCanonicalItemIds.Add([string]$correlation.itemId) }
        }
        foreach ($build in @($unitData.threeItemBuilds)) {
            foreach ($itemId in @($build.itemIds)) { if ($itemId) { [void]$referencedCanonicalItemIds.Add([string]$itemId) } }
        }
    }
}

# A source-observed item can be equipable and statistically meaningful without
# being listed in CommunityDragon setData.items (for example augment-granted
# special emblems). Preserve such identities instead of aliasing them to a
# different ordinary item or dropping their statistics.
$sourceUniverse = Get-TftCurrentSetUniverse `
    -SetNumber ([int]$catalog.set.number) `
    -SetData $sourceSet `
    -AllItems @($communityDragonJa.items) `
    -AdditionalItemIds @($observedRawItemIds)
$sourceUniverseById = @{}
foreach ($sourceItem in @($sourceUniverse.items)) {
    $sourceId = [string](Get-OptionalPropertyValue -Object $sourceItem -Name 'apiName')
    if ($sourceId) { $sourceUniverseById[$sourceId] = $sourceItem }
}

$supplementalItems = [Collections.Generic.List[object]]::new()
foreach ($rawItemId in @($observedRawItemIds | Sort-Object)) {
    $canonicalItemId = if ($canonicalItemIdByRaw.ContainsKey($rawItemId)) {
        [string]$canonicalItemIdByRaw[$rawItemId]
    } else {
        Resolve-CanonicalItemId -RawId $rawItemId
    }
    if (-not $referencedCanonicalItemIds.Contains($canonicalItemId)) { continue }
    if ($catalogItemIds.ContainsKey($canonicalItemId)) { continue }
    if ($canonicalItemId -ne $rawItemId) {
        throw "CANONICAL_ITEM_TARGET_MISSING raw=$rawItemId canonical=$canonicalItemId"
    }
    if (-not $sourceUniverseById.ContainsKey($rawItemId)) {
        throw "SOURCE_OBSERVED_ITEM_NOT_IN_COMMUNITYDRAGON raw=$rawItemId"
    }

    $jaItem = $sourceUniverseById[$rawItemId]
    $enItem = if ($sourceItemsEnById.ContainsKey($rawItemId)) { $sourceItemsEnById[$rawItemId] } else { $null }
    $associatedTraits = @(
        @(Get-OptionalPropertyValue -Object $jaItem -Name 'associatedTraits') |
            Where-Object { $_ } |
            ForEach-Object { [string]$_ }
    )
    $supplementalItems.Add([pscustomobject][ordered]@{
        id = $rawItemId
        nameJa = [string](Get-OptionalPropertyValue -Object $jaItem -Name 'name')
        nameEn = [string](Get-OptionalPropertyValue -Object $enItem -Name 'name')
        icon = [string](Get-OptionalPropertyValue -Object $jaItem -Name 'icon')
        associatedTraits = @($associatedTraits)
        source = 'CommunityDragon current-set universe + MetaTFT observed item'
    })
}

$result = [pscustomobject][ordered]@{
    schemaVersion = 1
    mode = 'CANONICAL_V2_LIVE_DRYRUN'
    generatedAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    set = [pscustomobject][ordered]@{
        id = [string]$catalog.set.id
        number = [int]$catalog.set.number
        patch = [string]$catalog.set.tftPatch
        clusterId = $clusterId
    }
    sourceContract = [pscustomobject][ordered]@{
        queueId = '1100'
        queue = 'RANKED'
        rank = 'PLATINUM_PLUS'
        rawRankFilter = $rankFilter
        patch = 'CURRENT'
        rawPatch = 'current'
        windowDays = 3
        permitFilterAdjustment = $false
        allRankFallbackAllowed = $false
    }
    itemIdAliases = @($resolvedAliasRows.ToArray() | Sort-Object raw, canonical -Unique)
    supplementalItems = @($supplementalItems.ToArray() | Sort-Object id)
    compositions = @($compositions)
}

[IO.File]::WriteAllText(
    $resolvedOutput,
    (($result | ConvertTo-Json -Depth 30).Replace("`r`n", "`n") + "`n"),
    [Text.UTF8Encoding]::new($false)
)
Write-Output "Canonical v2 live dry-run built: Set=$($result.set.id) Cluster=$clusterId Compositions=$($compositions.Count) ItemAliases=$(@($result.itemIdAliases).Count) SupplementalItems=$(@($result.supplementalItems).Count) Output=$resolvedOutput"
