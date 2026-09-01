param(
    [string]$SnapshotPath = 'source/current/tft_static_snapshot.json',
    [string]$CatalogPath = 'source/current/tft/tft_catalog.json'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'id-compatibility-policy.ps1')
. (Join-Path $PSScriptRoot 'rank-scope-policy.ps1')

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
function Resolve-RepoPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $repositoryRoot $Path))
}
function Set-ActionOutput([string]$Name, [string]$Value) {
    if ($env:GITHUB_OUTPUT) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$Name=$Value" -Encoding UTF8 }
}

$resolvedSnapshot = Resolve-RepoPath $SnapshotPath
$resolvedCatalog = Resolve-RepoPath $CatalogPath
if (-not (Test-Path -LiteralPath $resolvedSnapshot -PathType Leaf)) { throw "Snapshot not found: $resolvedSnapshot" }
if (-not (Test-Path -LiteralPath $resolvedCatalog -PathType Leaf)) { throw "Catalog not found: $resolvedCatalog" }

$rawSnapshot = [IO.File]::ReadAllText($resolvedSnapshot)
if ($rawSnapshot -notmatch '"augments"\s*:\s*\[') { throw 'Static meta augments must serialize as a JSON array.' }
if ($rawSnapshot -notmatch '"compositions"\s*:\s*\[') { throw 'Static meta compositions must serialize as a JSON array.' }

$snapshot = $rawSnapshot | ConvertFrom-Json
$catalog = Get-Content -Raw -Encoding UTF8 -LiteralPath $resolvedCatalog | ConvertFrom-Json
if ([string]$snapshot.setId -ne [string]$catalog.set.id) {
    throw "Cross-source set mismatch: snapshot=$($snapshot.setId) catalog=$($catalog.set.id)"
}

$champions = @($catalog.champions)
$traits = @($catalog.traits)
$items = @($catalog.items)
$augments = @($catalog.augments)
if ($champions.Count -lt 40) { throw "Playable champion catalog unexpectedly small: $($champions.Count)" }
if ($traits.Count -lt 20) { throw "Trait catalog unexpectedly small: $($traits.Count)" }
if ($items.Count -lt 20) { throw "Item catalog unexpectedly small: $($items.Count)" }
if ($augments.Count -lt 20) { throw "Augment catalog unexpectedly small: $($augments.Count)" }

$catalogIds = @{}
foreach ($entry in @($champions) + @($traits) + @($items) + @($augments)) {
    $id = [string]$entry.id
    if (-not $id) { throw 'Catalog entry without id.' }
    if ($catalogIds.ContainsKey($id)) { throw "Duplicate catalog id across categories: $id" }
    $catalogIds[$id] = $true
}

$itemIndex = New-TftCanonicalIdIndex -Entries $items
$itemIds = @{}
foreach ($item in $items) { $itemIds[[string]$item.id] = $true }
$championIds = @{}
foreach ($champion in $champions) { $championIds[[string]$champion.id] = $true }
$augmentIds = @{}
foreach ($augment in $augments) { $augmentIds[[string]$augment.id] = $true }

function Assert-CanonicalItemReference {
    param(
        [AllowNull()][string]$ItemId,
        [AllowNull()][string]$ItemName,
        [Parameter(Mandatory = $true)][string]$Context
    )
    if (-not $ItemId) { throw "Missing item id: $Context" }
    if ($itemIds.ContainsKey($ItemId)) { return }
    $resolution = Resolve-TftCanonicalId -Index $itemIndex -SourceId $ItemId -SourceName $ItemName
    if ($resolution.status -in @('ALIAS', 'NAME')) {
        throw "Non-canonical item id leaked into publication: $Context/$ItemId -> $($resolution.canonicalId)"
    }
    if ($resolution.status -eq 'AMBIGUOUS') {
        throw "Ambiguous item id cannot be published safely: $Context/$ItemId [$($resolution.candidates -join ',')]"
    }
    throw "Item reference missing from canonical catalog: $Context/$ItemId"
}

$compositions = @($snapshot.compositions | Where-Object { $_ -is [pscustomobject] })
$readiness = if ($snapshot.PSObject.Properties['readiness']) { [string]$snapshot.readiness } else { 'META_STABLE' }
if ($readiness -notin @('CATALOG_READY', 'META_COLLECTING', 'META_STABLE')) { throw "Unknown readiness: $readiness" }
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

$compositionIds = @{}
$missingAugmentCompositions = 0
foreach ($composition in $compositions) {
    $compositionId = [string]$composition.id
    if (-not $compositionId) { throw 'Composition without id.' }
    if ($compositionIds.ContainsKey($compositionId)) { throw "Duplicate composition id: $compositionId" }
    $compositionIds[$compositionId] = $true

    $units = @($composition.units)
    if ($units.Count -eq 0) { throw "Composition contains no units: $compositionId" }
    foreach ($unit in $units) {
        $unitId = [string]$unit.id
        if (-not $championIds.ContainsKey($unitId)) { throw "Composition unit is not canonical: $compositionId/$unitId" }
        foreach ($item in @($unit.recommendedBuild)) {
            Assert-CanonicalItemReference -ItemId ([string]$item.itemId) -ItemName ([string]$item.itemName) -Context "$compositionId/$unitId/recommended"
        }
        foreach ($stat in @($unit.itemStats)) {
            Assert-CanonicalItemReference -ItemId ([string]$stat.itemId) -ItemName ([string]$stat.itemName) -Context "$compositionId/$unitId/stat"
            foreach ($buildItem in @($stat.bestBuild)) {
                Assert-CanonicalItemReference -ItemId ([string]$buildItem.itemId) -ItemName ([string]$buildItem.itemName) -Context "$compositionId/$unitId/bestBuild"
            }
        }
    }

    foreach ($board in @($composition.finalBoard) + @($composition.levelBoards)) {
        foreach ($boardUnit in @($board.units)) {
            $boardUnitId = [string]$boardUnit.id
            if (-not $championIds.ContainsKey($boardUnitId)) {
                throw "Board unit is not canonical: $compositionId/Lv$($board.level)/$boardUnitId"
            }
        }
    }

    $recommendedAugments = @($composition.recommendedAugments)
    if ($recommendedAugments.Count -eq 0) {
        $missingAugmentCompositions++
    } else {
        foreach ($augment in $recommendedAugments) {
            if (-not $augmentIds.ContainsKey([string]$augment.id)) {
                throw "Composition augment is not canonical: $compositionId/$($augment.id)"
            }
        }
    }
}

if ($readiness -eq 'META_STABLE') {
    if ($compositions.Count -lt $targetCompositionCount) {
        throw "META_STABLE cannot publish fewer than $targetCompositionCount compositions: $($compositions.Count)"
    }
}

$warnings = [Collections.Generic.List[string]]::new()
if ($limitedPlatinumCoverage) { $warnings.Add('PLATINUM_PLUS_COVERAGE_LIMITED') }
if ($compositions.Count -eq 0) {
    $warnings.Add('COMPOSITIONS_COLLECTING')
    if ($qualifiedSourceCompositions -ge $targetCompositionCount) {
        $warnings.Add('UPSTREAM_COMPOSITIONS_AVAILABLE_BUT_NOT_RENDERABLE')
    }
} elseif ($compositions.Count -lt $targetCompositionCount) {
    $warnings.Add('COMPOSITION_COUNT_BELOW_TARGET')
}
if ($missingAugmentCompositions -gt 0) {
    $warnings.Add('COMPOSITION_AUGMENTS_COLLECTING')
}

$qualityState = if ($compositions.Count -eq 0) {
    'CATALOG_ONLY'
} elseif ($limitedPlatinumCoverage -or $compositions.Count -lt $targetCompositionCount -or $missingAugmentCompositions -gt 0) {
    'DEGRADED_OPTIONAL'
} else {
    'READY'
}

Set-ActionOutput 'quality_state' $qualityState
Set-ActionOutput 'composition_count' ([string]$compositions.Count)
Set-ActionOutput 'target_composition_count' ([string]$targetCompositionCount)
Set-ActionOutput 'qualified_source_compositions' ([string]$qualifiedSourceCompositions)
Set-ActionOutput 'missing_augment_compositions' ([string]$missingAugmentCompositions)
Set-ActionOutput 'warning_codes' (($warnings.ToArray()) -join ',')

if ($warnings.Count -gt 0) {
    Write-Warning "Data compatibility warnings: $($warnings.ToArray() -join ', ')"
}
Write-Output "Data compatibility contract passed: Set=$($snapshot.setId) Readiness=$readiness Quality=$qualityState Compositions=$($compositions.Count)/$targetCompositionCount MissingAugmentComps=$missingAugmentCompositions"
