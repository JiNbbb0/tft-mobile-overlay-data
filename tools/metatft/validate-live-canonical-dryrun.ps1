param(
    [string]$InputPath = 'build/canonical-v2-live/live-canonical-dryrun.json',
    [int]$ExpectedCompositionCount = 18
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\quality\Test-CanonicalContract.ps1')

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$resolvedInput = if ([IO.Path]::IsPathRooted($InputPath)) { $InputPath } else { Join-Path $repoRoot $InputPath }
if (-not (Test-Path -LiteralPath $resolvedInput)) { throw "Dry-run output not found: $resolvedInput" }
$data = Get-Content -Raw -Encoding UTF8 -LiteralPath $resolvedInput | ConvertFrom-Json
$catalog = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repoRoot 'source/current/tft/tft_catalog.json') | ConvertFrom-Json

$quality = Test-CanonicalContract -Value $data -RequiredArrayPaths @('compositions','itemIdAliases','supplementalItems')
if (-not $quality.passed) {
    $text = @($quality.findings | ForEach-Object { "$($_.code) $($_.path)" }) -join '; '
    throw "CANONICAL_QUALITY_FAILED $text"
}

if ([string]$data.mode -ne 'CANONICAL_V2_LIVE_DRYRUN') { throw "Unexpected dry-run mode: $($data.mode)" }
if ([string]$data.set.id -ne [string]$catalog.set.id) { throw "Set mismatch: dryrun=$($data.set.id) catalog=$($catalog.set.id)" }
if ([int]$data.set.number -ne [int]$catalog.set.number) { throw 'Set number mismatch.' }
if ([string]$data.sourceContract.queueId -ne '1100') { throw 'Queue contract must be Ranked queue 1100.' }
if ([string]$data.sourceContract.rank -ne 'PLATINUM_PLUS') { throw 'Rank contract must stay Platinum+.' }
if ([string]$data.sourceContract.patch -ne 'CURRENT') { throw 'Patch contract must stay current.' }
if ([int]$data.sourceContract.windowDays -ne 3) { throw 'Statistics window must stay 3 days.' }
if ([bool]$data.sourceContract.permitFilterAdjustment) { throw 'MetaTFT filter adjustment must remain disabled.' }
if ([bool]$data.sourceContract.allRankFallbackAllowed) { throw 'All-rank fallback must remain disabled.' }

$compositions = @($data.compositions)
if ($compositions.Count -ne $ExpectedCompositionCount) {
    throw "Composition count mismatch. Expected=$ExpectedCompositionCount Actual=$($compositions.Count)"
}
$compositionIds = @($compositions | ForEach-Object { [string]$_.id })
if (@($compositionIds | Sort-Object -Unique).Count -ne $compositionIds.Count) { throw 'Duplicate composition IDs detected.' }
for ($i = 0; $i -lt $compositions.Count; $i++) {
    if ([int]$compositions[$i].sourceRank -ne ($i + 1)) { throw "Source rank mismatch at index $i" }
    if ($i -gt 0 -and [double]$compositions[$i].averagePlacement -lt [double]$compositions[$i - 1].averagePlacement) {
        throw "Composition order is not average-placement ascending at $($compositions[$i].id)"
    }
}

$championIds = @{}
foreach ($champion in @($catalog.champions)) { if ($champion.id) { $championIds[[string]$champion.id] = $true } }
$itemIds = @{}
foreach ($item in @($catalog.items)) { if ($item.id) { $itemIds[[string]$item.id] = $true } }
$augmentIds = @{}
foreach ($augment in @($catalog.augments)) { if ($augment.id) { $augmentIds[[string]$augment.id] = $true } }

$supplementalItems = @($data.supplementalItems)
$supplementalIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($supplemental in $supplementalItems) {
    $id = [string]$supplemental.id
    if (-not $id) { throw 'Supplemental item has no ID.' }
    if ($itemIds.ContainsKey($id)) { throw "Supplemental item duplicates catalog item: $id" }
    if (-not $supplementalIds.Add($id)) { throw "Duplicate supplemental item ID: $id" }
    $nameJa = [string]$supplemental.nameJa
    $nameEn = [string]$supplemental.nameEn
    if (-not $nameJa -and -not $nameEn) { throw "Supplemental item has no display name: $id" }
    if ([string]$supplemental.source -ne 'CommunityDragon current-set universe + MetaTFT observed item') {
        throw "Unexpected supplemental item provenance: $id/$($supplemental.source)"
    }
    $itemIds[$id] = $true
}

$referencedItemIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$recommendedBuildCount = 0
$correlationCount = 0
$directAugmentCount = 0
$boardCount = 0
foreach ($composition in $compositions) {
    $compositionId = [string]$composition.id
    $units = @($composition.unitIds)
    if ($units.Count -eq 0) { throw "Composition has no units: $compositionId" }
    foreach ($unitIdValue in $units) {
        $unitId = [string]$unitIdValue
        if (-not $championIds.ContainsKey($unitId)) { throw "Unknown current-set unit: $compositionId/$unitId" }
    }

    foreach ($unitData in @($composition.itemData)) {
        if (-not $championIds.ContainsKey([string]$unitData.unitId)) { throw "Unknown item-data unit: $compositionId/$($unitData.unitId)" }
        foreach ($recommended in @($unitData.recommended)) {
            if ([string]$recommended.sourceSemantics -ne 'OVERVIEW_BUILD') { throw "Invalid recommendation semantics: $compositionId/$($unitData.unitId)" }
            foreach ($itemIdValue in @($recommended.itemIds)) {
                $itemId = [string]$itemIdValue
                [void]$referencedItemIds.Add($itemId)
                if (-not $itemIds.ContainsKey($itemId)) { throw "Unresolved recommended item: $compositionId/$($unitData.unitId)/$itemId" }
            }
            $recommendedBuildCount++
        }
        foreach ($popularity in @($unitData.derivedPopularity)) {
            if ([bool]$popularity.isRecommendation) { throw "Derived popularity mislabeled as recommendation: $compositionId/$($unitData.unitId)" }
            $itemId = [string]$popularity.itemId
            [void]$referencedItemIds.Add($itemId)
            if (-not $itemIds.ContainsKey($itemId)) { throw "Unresolved popularity item: $compositionId/$itemId" }
        }
        foreach ($correlation in @($unitData.averagePlacementCorrelations)) {
            if ([bool]$correlation.isRecommendation) { throw "Derived correlation mislabeled as recommendation: $compositionId/$($unitData.unitId)" }
            $itemId = [string]$correlation.itemId
            [void]$referencedItemIds.Add($itemId)
            if (-not $itemIds.ContainsKey($itemId)) { throw "Unresolved correlation item: $compositionId/$itemId" }
            $correlationCount++
        }
        foreach ($build in @($unitData.threeItemBuilds)) {
            foreach ($itemIdValue in @($build.itemIds)) {
                $itemId = [string]$itemIdValue
                [void]$referencedItemIds.Add($itemId)
                if (-not $itemIds.ContainsKey($itemId)) { throw "Unresolved three-item build item: $compositionId/$($unitData.unitId)/$itemId" }
            }
        }
    }

    foreach ($augment in @($composition.recommendedAugments)) {
        if ([string]$augment.sourceSemantics -ne 'DIRECT_COMP_AUGMENT_STAT') { throw "Invalid augment semantics: $compositionId/$($augment.id)" }
        if ([string]$augment.source -ne 'MetaTFT comp_details.augments') { throw "Augment source must be direct comp_details: $compositionId/$($augment.id)" }
        if (-not $augmentIds.ContainsKey([string]$augment.id)) { throw "Unresolved augment: $compositionId/$($augment.id)" }
        $directAugmentCount++
    }

    $boards = @($composition.levelBoards)
    $boardCount += $boards.Count
    foreach ($board in $boards) {
        if ([bool]$board.synthetic) { throw "Synthetic level board detected: $compositionId/Lv$($board.level)" }
        if ([int]$board.level -lt 4 -or [int]$board.level -gt 9) { throw "Invalid board level: $compositionId/Lv$($board.level)" }
        foreach ($unitIdValue in @($board.unitIds)) {
            if (-not $championIds.ContainsKey([string]$unitIdValue)) { throw "Unknown board unit: $compositionId/Lv$($board.level)/$unitIdValue" }
        }
        $positions = @($board.positions)
        if ([bool]$board.positionsAvailable) {
            if ($positions.Count -ne @($board.unitIds).Count) { throw "Explicit board position count mismatch: $compositionId/Lv$($board.level)" }
            $cells = @($positions | ForEach-Object { [int]$_.position })
            if (@($cells | Sort-Object -Unique).Count -ne $cells.Count) { throw "Board position collision: $compositionId/Lv$($board.level)" }
            foreach ($cell in $cells) { if ($cell -lt 0 -or $cell -gt 27) { throw "Board cell out of range: $compositionId/Lv$($board.level)/$cell" } }
        } elseif ($positions.Count -ne 0) {
            throw "Positions must stay empty when source positions are unavailable: $compositionId/Lv$($board.level)"
        }
    }
    foreach ($level in 4..9) {
        $levelBoards = @($boards | Where-Object { [int]$_.level -eq $level })
        if ($levelBoards.Count -gt 3) { throw "Too many board variants: $compositionId/Lv$level" }
        for ($rank = 0; $rank -lt $levelBoards.Count; $rank++) {
            if ([int]$levelBoards[$rank].popularityRank -ne ($rank + 1)) { throw "Board popularity rank mismatch: $compositionId/Lv$level" }
            if ($rank -gt 0 -and [int]$levelBoards[$rank].sampleCount -gt [int]$levelBoards[$rank - 1].sampleCount) {
                throw "Board variants are not popularity ordered: $compositionId/Lv$level"
            }
        }
    }
}

foreach ($supplemental in $supplementalItems) {
    $id = [string]$supplemental.id
    if (-not $referencedItemIds.Contains($id)) {
        throw "Unreferenced supplemental item must not be published: $id"
    }
}

if ($recommendedBuildCount -eq 0) { throw 'No source-recommended item builds survived canonicalization.' }
if ($correlationCount -eq 0) { throw 'No derived item correlations were produced.' }
if ($boardCount -eq 0) { throw 'No real level boards were produced.' }
# Do not require augment rows for every composition. New-set comp-specific data can be sparse,
# but when direct rows exist they must be canonical and must never gate the composition list.

Write-Output "Canonical v2 live dry-run validation passed. Set=$($data.set.id) Compositions=$($compositions.Count) RecommendedBuilds=$recommendedBuildCount Correlations=$correlationCount DirectAugments=$directAugmentCount Boards=$boardCount SupplementalItems=$($supplementalItems.Count)"
