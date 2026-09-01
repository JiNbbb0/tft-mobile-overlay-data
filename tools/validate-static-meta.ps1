param(
    [string]$SnapshotPath = "source/current/tft_static_snapshot.json",
    [string]$CatalogPath = "source/current/tft/tft_catalog.json"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$resolvedSnapshot = if ([IO.Path]::IsPathRooted($SnapshotPath)) {
    $SnapshotPath
} else {
    Join-Path $repositoryRoot $SnapshotPath
}
$resolvedCatalog = if ([IO.Path]::IsPathRooted($CatalogPath)) {
    $CatalogPath
} else {
    Join-Path $repositoryRoot $CatalogPath
}

if (-not (Test-Path -LiteralPath $resolvedSnapshot)) {
    throw "Snapshot not found: $resolvedSnapshot"
}
if (-not (Test-Path -LiteralPath $resolvedCatalog)) {
    throw "Catalog not found: $resolvedCatalog"
}

$snapshot = Get-Content -Raw -Encoding UTF8 -LiteralPath $resolvedSnapshot | ConvertFrom-Json
$catalog = Get-Content -Raw -Encoding UTF8 -LiteralPath $resolvedCatalog | ConvertFrom-Json
$assetRoot = Split-Path -Parent (Split-Path -Parent $resolvedCatalog)
$catalogEntries = @{}
foreach ($entry in @($catalog.champions) + @($catalog.items) + @($catalog.augments)) {
    $catalogEntries[$entry.id] = $entry
}
if ([int]$snapshot.schemaVersion -notin @(4,5)) { throw "Unsupported static meta schema" }
if (-not $snapshot.setId) { throw "Missing setId" }
if (-not $snapshot.sources.compositionItemBuilds) { throw "Missing composition item source" }
if (-not $snapshot.sources.compositionDetails) { throw "Missing composition details source" }
if (-not $snapshot.sources.compositionAugmentTiers) { throw "Missing composition augment source" }
if ([int]$snapshot.schemaVersion -ge 5 -and -not $snapshot.sources.metaTftJapaneseLookup) { throw "Missing MetaTFT Japanese lookup source" }
if ([int]$snapshot.itemStatBasis.buildSize -ne 3) { throw "Unexpected static meta build size" }
if ($snapshot.PSObject.Properties['statisticsScope']) {
    $scope = $snapshot.statisticsScope
    if ([string]$scope.preferred -ne 'PLATINUM_PLUS') { throw "Unexpected preferred rank scope" }
    if ([string]$scope.effective -eq 'ALL_RANKS_FALLBACK') { throw "MetaTFT comps page parity forbids the legacy all-rank fallback" }
    if ([string]$scope.effective -notin @('PLATINUM_PLUS', 'ALL_RANKS_FALLBACK', 'PLATINUM_PLUS_LIMITED')) {
        throw "Unexpected effective rank scope"
    }
    if ([int]$scope.minimumCompositionSamples -lt 1 -or [int]$scope.minimumPreferredCompositions -lt 1) {
        throw "Invalid rank fallback thresholds"
    }
    if ([bool]$scope.fallbackAttempted -and -not $scope.fallbackReason) { throw "Rank fallback reason missing" }
    if (-not $scope.PSObject.Properties['pageParity']) { throw "MetaTFT comps page parity contract missing" }
    if ([string]$scope.pageParity.queue -ne '1100' -or [int]$scope.pageParity.days -ne 3 -or [string]$scope.pageParity.sort -ne 'Avg Placement') {
        throw "MetaTFT comps page parity filters do not match the public page"
    }
    if ([double]$scope.pageParity.minimumPickRate -ne 0.01 -or [double]$scope.pageParity.centroidVisibilityMinimum -ne 1.0) {
        throw "MetaTFT comps page visibility thresholds do not match the public page"
    }
    $statsUrl = [string]$snapshot.sources.compositionStats
    if ($statsUrl -notmatch 'rank=CHALLENGER,DIAMOND,EMERALD,GRANDMASTER,MASTER,PLATINUM' -or
        $statsUrl -notmatch 'permit_filter_adjustment=true' -or
        $statsUrl -notmatch 'cluster_id=') {
        throw "MetaTFT composition statistics URL does not match the public comps page"
    }
}

# ConvertFrom-Json can surface a JSON null composition value as a pipeline
# placeholder. Only real composition objects belong in the validation list.
$compositions = @($snapshot.compositions | Where-Object { $_ -is [pscustomobject] })
$readiness = if ($snapshot.PSObject.Properties['readiness']) { [string]$snapshot.readiness } else { 'META_STABLE' }
$isPartial = $readiness -in @('CATALOG_READY', 'META_COLLECTING')
if (-not $isPartial -and $compositions.Count -lt 18) { throw "Expected at least 18 compositions, found $($compositions.Count)" }
if ($isPartial -and $compositions.Count -eq 0) {
    Write-Output "Static meta catalog-only snapshot valid"
    Write-Output "Set=$($snapshot.setId) Readiness=$readiness"
    exit 0
}

$allItemStats = @()
$trustedStatCount = 0
$trustedOptionCount = 0
foreach ($composition in $compositions) {
    $title = if ($composition.PSObject.Properties['displayNameJa']) { [string]$composition.displayNameJa } else { [string]$composition.name }
    if (-not $composition.id -or -not $title) { throw "Composition identity missing" }
    if ([int]$snapshot.schemaVersion -ge 5 -and (-not $composition.titleKey -or -not $composition.titleSource)) {
        throw "Composition title provenance missing: $($composition.id)"
    }
    if ($composition.tier -notin @('OP', 'S', 'A', 'B', 'C', 'D')) { throw "Invalid composition tier: $($composition.id)/$($composition.tier)" }
    if ([double]$composition.averagePlacement -lt 1 -or [double]$composition.averagePlacement -gt 8) {
        throw "Composition placement outside 1-8: $($composition.id)"
    }
    if ([int]$snapshot.schemaVersion -ge 5 -and -not $isPartial) {
        if ([string]$composition.titleSource -ne 'MetaTFT comps_data title localized with MetaTFT Japanese lookup') {
            throw "Composition title is not sourced from MetaTFT comps_data: $($composition.id)"
        }
        if ($title -match '\s/\s') {
            throw "Composition title still uses the legacy separator: $($composition.id)/$title"
        }
        $averagePlacement = [double]$composition.averagePlacement
        $expectedTier = if ($averagePlacement -lt 4.25) {
            'S'
        } elseif ($averagePlacement -lt 4.5) {
            'A'
        } elseif ($averagePlacement -lt 4.75) {
            'B'
        } elseif ($averagePlacement -lt 5.0) {
            'C'
        } else {
            'D'
        }
        if ([string]$composition.tier -ne $expectedTier) {
            throw "Composition tier does not match MetaTFT Avg Placement band: $($composition.id)/$($composition.tier)/expected=$expectedTier"
        }
    }
    if ([int]$composition.sampleCount -le 0) { throw "Composition sample count missing: $($composition.id)" }
    if (-not $composition.rollPlan.label -or [int]$composition.rollPlan.targetLevel -lt 5 -or [int]$composition.rollPlan.targetLevel -gt 9) {
        throw "Composition roll plan missing or invalid: $($composition.id)"
    }
    if ([string]$composition.rollPlan.label -notmatch '^Lv[5-9]リロール$') {
        throw "Composition roll plan label must be compact: $($composition.id)/$($composition.rollPlan.label)"
    }
    if (-not $composition.rollPlan.recommendedRolls -or @($composition.rollPlan.levelTimings).Count -lt 6) {
        throw "Composition reroll count or level timing missing: $($composition.id)"
    }
    $recommendedAugments = @($composition.recommendedAugments)
    if ($recommendedAugments.Count -eq 0 -and -not $isPartial) { throw "No recommended augments: $($composition.id)" }
    foreach ($augment in $recommendedAugments) {
        if ($augment.tier -notin @('S', 'A', 'B')) { throw "Unexpected recommended augment tier: $($composition.id)/$($augment.id)/$($augment.tier)" }
        if (-not $catalogEntries.ContainsKey($augment.id)) { throw "Recommended augment missing from catalog: $($composition.id)/$($augment.id)" }
    }

    $units = @($composition.units)
    if ($units.Count -eq 0) { throw "Composition has no units: $($composition.id)" }
    $trustedByItem = @{}

    $finalBoardUnits = @($composition.finalBoard.units)
    if ([int]$composition.finalBoard.level -lt 7 -or [int]$composition.finalBoard.level -gt 9) {
        throw "Completed board level must be 7-9: $($composition.id)/Lv$($composition.finalBoard.level)"
    }
    if ($finalBoardUnits.Count -ne [int]$composition.finalBoard.level) {
        throw "Completed board unit count must match its level: $($composition.id)/Lv$($composition.finalBoard.level) [$($finalBoardUnits.Count)]"
    }

    $boards = @($composition.finalBoard) + @($composition.levelBoards)
    $levels = @($composition.levelBoards | ForEach-Object { [int]$_.level } | Sort-Object -Unique)
    if (($levels -join ',') -ne '4,5,6,7,8,9') {
        throw "Composition level boards must include Lv4-Lv9: $($composition.id) [$($levels -join ',')]"
    }
    foreach ($level in $levels) {
        $placements = @($composition.levelBoards | Where-Object { [int]$_.level -eq $level } | ForEach-Object { [double]$_.averagePlacement })
        $sortedPlacements = @($placements | Sort-Object)
        if (($placements -join ',') -ne ($sortedPlacements -join ',')) {
            throw "Board variants must be ordered by average placement: $($composition.id)/Lv$level"
        }
    }
    foreach ($board in $boards) {
        $boardUnits = @($board.units)
        if ($boardUnits.Count -eq 0) { throw "Composition board has no units: $($composition.id)/Lv$($board.level)" }
        if ([int]$board.sampleCount -le 0) { throw "Composition board sample count missing: $($composition.id)/Lv$($board.level)" }
        $positions = @{}
        foreach ($boardUnit in $boardUnits) {
            if (-not $catalogEntries.ContainsKey($boardUnit.id)) {
                throw "Board unit missing from catalog: $($composition.id)/Lv$($board.level)/$($boardUnit.id)"
            }
            $position = [int]$boardUnit.position
            if ($position -lt 0 -or $position -ge 28) {
                throw "Board position outside 0-27: $($composition.id)/Lv$($board.level)/$position"
            }
            if ($positions.ContainsKey([string]$position)) {
                throw "Duplicate board position: $($composition.id)/Lv$($board.level)/$position"
            }
            if ([int]$boardUnit.starLevel -notin @(0, 2, 3)) {
                throw "Board star target must be flexible, 2, or 3: $($composition.id)/Lv$($board.level)/$($boardUnit.id)"
            }
            if ([int]$boardUnit.starLevel -eq 2 -and [int]$catalogEntries[$boardUnit.id].cost -lt 4) {
                throw "Two-star target must be cost 4 or higher: $($composition.id)/Lv$($board.level)/$($boardUnit.id)"
            }
            if ([double]$boardUnit.starRate -lt 0 -or [double]$boardUnit.starRate -gt 1) {
                throw "Board star rate outside 0-1: $($composition.id)/Lv$($board.level)/$($boardUnit.id)"
            }
            $positions[[string]$position] = $true
            $boardCatalogEntry = $catalogEntries[$boardUnit.id]
            if (-not $boardCatalogEntry.image -or -not (Test-Path -LiteralPath (Join-Path $assetRoot $boardCatalogEntry.image))) {
                throw "Board unit image missing: $($composition.id)/Lv$($board.level)/$($boardUnit.id)"
            }
        }
    }
    foreach ($unit in $units) {
        if (-not $unit.id -or -not $unit.name) { throw "Unit identity missing in $($composition.id)" }
        if (-not $catalogEntries.ContainsKey($unit.id)) {
            throw "Composition unit missing from catalog: $($composition.id)/$($unit.id)"
        }
        $unitCatalogEntry = $catalogEntries[$unit.id]
        if (-not $unitCatalogEntry.image -or -not (Test-Path -LiteralPath (Join-Path $assetRoot $unitCatalogEntry.image))) {
            throw "Composition unit image missing: $($composition.id)/$($unit.id)"
        }
        foreach ($recommendedItem in @($unit.recommendedBuild)) {
            if (-not $recommendedItem.itemId -or -not $catalogEntries.ContainsKey([string]$recommendedItem.itemId)) {
                throw "Recommended overview item missing from catalog: $($composition.id)/$($unit.id)/$($recommendedItem.itemId)"
            }
            $recommendedCatalogEntry = $catalogEntries[[string]$recommendedItem.itemId]
            if (-not $recommendedCatalogEntry.image -or -not (Test-Path -LiteralPath (Join-Path $assetRoot $recommendedCatalogEntry.image))) {
                throw "Recommended overview item image missing: $($composition.id)/$($unit.id)/$($recommendedItem.itemId)"
            }
        }
        foreach ($stat in @($unit.itemStats)) {
            if (-not $stat.itemId -or -not $stat.itemName) { throw "Item identity missing for $($unit.id)" }
            if ([double]$stat.averagePlacement -lt 1 -or [double]$stat.averagePlacement -gt 8) {
                throw "Item placement outside 1-8: $($composition.id)/$($unit.id)/$($stat.itemId)"
            }
            if ([int]$stat.sampleCount -lt [int]$snapshot.itemStatBasis.minimumSamples) {
                throw "Item sample threshold violated: $($composition.id)/$($unit.id)/$($stat.itemId)"
            }
            if (@($stat.bestBuild).Count -eq 0) {
                throw "Best build missing: $($composition.id)/$($unit.id)/$($stat.itemId)"
            }
            foreach ($buildItem in @($stat.bestBuild)) {
                if (-not $catalogEntries.ContainsKey($buildItem.itemId)) {
                    throw "Best-build item missing from catalog: $($composition.id)/$($unit.id)/$($buildItem.itemId)"
                }
                $itemCatalogEntry = $catalogEntries[$buildItem.itemId]
                if (-not $itemCatalogEntry.image -or -not (Test-Path -LiteralPath (Join-Path $assetRoot $itemCatalogEntry.image))) {
                    throw "Best-build item image missing: $($composition.id)/$($unit.id)/$($stat.itemId)"
                }
            }
            if ([int]$stat.sampleCount -ge 250) {
                $trustedStatCount++
                if (-not $trustedByItem.ContainsKey($stat.itemId)) {
                    $trustedByItem[$stat.itemId] = @{ Samples = 0; Holders = 0 }
                }
                $trustedByItem[$stat.itemId].Samples += [int]$stat.sampleCount
                $trustedByItem[$stat.itemId].Holders++
            }
            $allItemStats += $stat
        }
    }
    $compositionTrustedOptions = @(
        $trustedByItem.Values | Where-Object { $_.Holders -ge 2 -or $_.Samples -ge 1000 }
    ).Count
    if ($compositionTrustedOptions -eq 0 -and $trustedByItem.Count -eq 0) {
        throw "No statistics meet the trusted 250-sample threshold: $($composition.id)"
    }
    $trustedOptionCount += if ($compositionTrustedOptions -gt 0) {
        $compositionTrustedOptions
    } else {
        $trustedByItem.Count
    }
}

if ($allItemStats.Count -eq 0 -and -not $isPartial) { throw "No composition item statistics" }

Write-Output "Static meta snapshot valid"
Write-Output "Set=$($snapshot.setId) Compositions=$($compositions.Count) ItemStats=$($allItemStats.Count) MinimumSamples=$($snapshot.itemStatBasis.minimumSamples)"
Write-Output "TrustedStats=$trustedStatCount TrustedOptions=$trustedOptionCount Threshold=250"
Write-Output "Composition unit and recommended-item images are present"
$missingAugmentCompositions = @($compositions | Where-Object { @($_.recommendedAugments).Count -eq 0 }).Count
Write-Output "Roll plans and star targets are present; composition augments available=$($compositions.Count - $missingAugmentCompositions)/$($compositions.Count)"
