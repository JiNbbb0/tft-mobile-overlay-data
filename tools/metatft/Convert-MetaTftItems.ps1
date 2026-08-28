Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Convert-MetaTftUnitItemData {
    param(
        [Parameter(Mandatory = $true)][string]$UnitId,
        [object[]]$OverviewBuilds = @(),
        [object[]]$CompBuildRows = @(),
        [hashtable]$CanonicalItemIdMap = @{},
        [int]$MinimumCorrelationSamples = 1
    )

    function Resolve-ItemId([string]$RawId) {
        if (-not $RawId) { return '' }
        if ($CanonicalItemIdMap.ContainsKey($RawId)) { return [string]$CanonicalItemIdMap[$RawId] }
        return $RawId
    }

    # `recommended` is source-defined only. Preserve the order exposed by the
    # MetaTFT composition overview; never replace it with an independently
    # calculated average-placement ranking.
    $recommended = [Collections.Generic.List[object]]::new()
    $recommendedRows = @(
        $OverviewBuilds | Where-Object {
            [string]$_.unit -eq $UnitId -and [int]$_.num_items -eq 3
        }
    )
    $sourceRank = 1
    foreach ($row in $recommendedRows) {
        $ids = @(
            @($row.buildName) |
                Where-Object { $_ } |
                ForEach-Object { Resolve-ItemId -RawId ([string]$_) }
        )
        if ($ids.Count -eq 0) { continue }
        $recommended.Add([pscustomobject][ordered]@{
            sourceRank = $sourceRank
            itemIds = @($ids)
            source = 'MetaTFT comps_data.cluster_details.builds'
            sourceSemantics = 'OVERVIEW_BUILD'
        })
        $sourceRank++
    }

    $threeItemBuilds = [Collections.Generic.List[object]]::new()
    foreach ($row in @($CompBuildRows | Where-Object {
        [string]$_.unit -eq $UnitId -and
        [int]$_.num_items -eq 3 -and
        [int]$_.count -gt 0
    })) {
        $ids = @(
            @($row.buildName) |
                Where-Object { $_ } |
                ForEach-Object { Resolve-ItemId -RawId ([string]$_) }
        )
        if ($ids.Count -eq 0) { continue }
        $threeItemBuilds.Add([pscustomobject][ordered]@{
            itemIds = @($ids)
            sampleCount = [int]$row.count
            averagePlacement = if ([double]$row.avg -gt 0) { [Math]::Round([double]$row.avg, 4) } else { $null }
            source = 'MetaTFT comp_builds'
        })
    }

    $aggregate = @{}
    foreach ($build in @($threeItemBuilds)) {
        if ($null -eq $build.averagePlacement) { continue }
        foreach ($itemId in @($build.itemIds | Select-Object -Unique)) {
            if (-not $aggregate.ContainsKey($itemId)) {
                $aggregate[$itemId] = [ordered]@{ sampleCount=0; weightedPlacement=0.0 }
            }
            $aggregate[$itemId].sampleCount += [int]$build.sampleCount
            $aggregate[$itemId].weightedPlacement += [double]$build.averagePlacement * [int]$build.sampleCount
        }
    }

    $correlationRows = [Collections.Generic.List[object]]::new()
    foreach ($itemId in $aggregate.Keys) {
        $row = $aggregate[$itemId]
        if ([int]$row.sampleCount -lt $MinimumCorrelationSamples) { continue }
        $correlationRows.Add([pscustomobject][ordered]@{
            itemId = [string]$itemId
            averagePlacement = [Math]::Round(([double]$row.weightedPlacement / [int]$row.sampleCount), 4)
            sampleCount = [int]$row.sampleCount
            source = 'DERIVED_FROM_METATFT_COMPLETE_THREE_ITEM_BUILDS'
            isRecommendation = $false
        })
    }
    $correlations = @(
        $correlationRows.ToArray() |
            Sort-Object averagePlacement, @{ Expression = { -[int]$_.sampleCount } }, itemId
    )

    $popularityRows = [Collections.Generic.List[object]]::new()
    foreach ($itemId in $aggregate.Keys) {
        $popularityRows.Add([pscustomobject][ordered]@{
            itemId = [string]$itemId
            sampleCount = [int]$aggregate[$itemId].sampleCount
            source = 'DERIVED_FROM_METATFT_COMPLETE_THREE_ITEM_BUILDS'
            isRecommendation = $false
        })
    }
    $derivedPopularity = @(
        $popularityRows.ToArray() |
            Sort-Object @{ Expression = { -[int]$_.sampleCount } }, itemId
    )

    return [pscustomobject][ordered]@{
        unitId = $UnitId
        recommended = @($recommended)
        recommendedSourceVerified = ($recommended.Count -gt 0)
        derivedPopularity = @($derivedPopularity)
        averagePlacementCorrelations = @($correlations)
        threeItemBuilds = @($threeItemBuilds)
    }
}
