Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-MetaTftAveragePlacement {
    param([Parameter(Mandatory = $true)]$Places)
    $values = @($Places)
    if ($values.Count -lt 9) { throw 'MetaTFT places array must contain places 1-8 plus total sample count.' }
    $sampleCount = [int]$values[8]
    if ($sampleCount -le 0) { return [pscustomobject]@{ averagePlacement = $null; sampleCount = 0 } }
    $sum = 0.0
    for ($i = 0; $i -lt 8; $i++) { $sum += ($i + 1) * [double]$values[$i] }
    return [pscustomobject]@{
        averagePlacement = [Math]::Round($sum / $sampleCount, 4)
        sampleCount = $sampleCount
    }
}

function Assert-MetaTftFilterIdentity {
    param(
        [Parameter(Mandatory = $true)]$Filter,
        [string]$ExpectedQueue = '1100',
        [string]$ExpectedPatch = 'current',
        [int]$ExpectedDays = 3,
        [string]$ExpectedRank = 'CHALLENGER,DIAMOND,EMERALD,GRANDMASTER,MASTER,PLATINUM'
    )
    if ([string]$Filter.queue -ne $ExpectedQueue) { throw "METATFT_FILTER_MISMATCH queue=$($Filter.queue)" }
    if ([string]$Filter.patch -ne $ExpectedPatch) { throw "METATFT_FILTER_MISMATCH patch=$($Filter.patch)" }
    if ([int]$Filter.days -ne $ExpectedDays) { throw "METATFT_FILTER_MISMATCH days=$($Filter.days)" }
    if ([string]$Filter.rank -ne $ExpectedRank) { throw "METATFT_FILTER_MISMATCH rank=$($Filter.rank)" }
    if ($Filter.PSObject.Properties['permitFilterAdjustment'] -and [bool]$Filter.permitFilterAdjustment) {
        throw 'METATFT_FILTER_MISMATCH implicit filter adjustment must be disabled.'
    }
}

function Convert-MetaTftCompositionSnapshot {
    param(
        [Parameter(Mandatory = $true)]$ClusterInfo,
        [Parameter(Mandatory = $true)]$CompsData,
        [Parameter(Mandatory = $true)]$CompsStats,
        [Parameter(Mandatory = $true)]$Filter,
        [int]$MinimumSamples = 1
    )

    Assert-MetaTftFilterIdentity -Filter $Filter

    $setId = [string]$ClusterInfo.tft_set
    $clusterId = [int]$ClusterInfo.cluster_id
    $data = $CompsData.results.data
    if ([string]$data.tft_set -ne $setId -or [int]$data.cluster_id -ne $clusterId) {
        throw 'SOURCE_SET_MISMATCH MetaTFT comps_data and cluster_info differ.'
    }

    if ($CompsStats.PSObject.Properties['tft_set'] -and [string]$CompsStats.tft_set -ne $setId) {
        throw 'SOURCE_SET_MISMATCH MetaTFT comps_stats set differs.'
    }
    if ($CompsStats.PSObject.Properties['cluster_id'] -and [int]$CompsStats.cluster_id -ne $clusterId) {
        throw 'SOURCE_SET_MISMATCH MetaTFT comps_stats cluster differs.'
    }

    $clusters = @{}
    foreach ($property in $data.cluster_details.PSObject.Properties) {
        $clusters[[string]$property.Name] = $property.Value
    }

    $rows = [Collections.Generic.List[object]]::new()
    $sourceIndex = 0
    foreach ($stats in @($CompsStats.results)) {
        $id = [string]$stats.cluster
        if (-not $id -or $id -eq '-1' -or -not $clusters.ContainsKey($id)) { $sourceIndex++; continue }
        $placement = Get-MetaTftAveragePlacement -Places $stats.places
        if ([int]$placement.sampleCount -lt $MinimumSamples) { $sourceIndex++; continue }
        $cluster = $clusters[$id]
        $rows.Add([pscustomobject][ordered]@{
            id = $id
            averagePlacement = [double]$placement.averagePlacement
            sampleCount = [int]$placement.sampleCount
            sourceIndex = $sourceIndex
            unitsString = [string]$cluster.units_string
            titleParts = @($cluster.name)
            overviewBuilds = @($cluster.builds)
        })
        $sourceIndex++
    }

    $sorted = @(
        $rows.ToArray() |
            Sort-Object averagePlacement, sourceIndex
    )

    return [pscustomobject][ordered]@{
        setId = $setId
        clusterId = $clusterId
        filter = [pscustomobject][ordered]@{
            queue = 'RANKED'
            queueId = $ExpectedQueue = '1100'
            rank = 'PLATINUM_PLUS'
            rawRankFilter = 'CHALLENGER,DIAMOND,EMERALD,GRANDMASTER,MASTER,PLATINUM'
            patch = 'CURRENT'
            windowDays = 3
            permitFilterAdjustment = $false
        }
        compositions = @($sorted)
    }
}
