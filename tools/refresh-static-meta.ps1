param(
    [string]$OutputPath = "source/current/tft_static_snapshot.json",
    [string]$Locale = "ja_jp",
    [int]$MinimumCompSamples = 5000,
    [int]$MinimumItemSamples = 50,
    [int]$CompositionLimit = 18,
    [int]$MinimumPreferredCompositions = 18,
    [switch]$AllowPartial
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'id-compatibility-policy.ps1')
. (Join-Path $PSScriptRoot 'metatft-page-parity-policy.ps1')
. (Join-Path $PSScriptRoot 'metatft-item-ranking-policy.ps1')
. (Join-Path $PSScriptRoot 'source-contract.ps1')
. (Join-Path $PSScriptRoot 'statistics-scope-contract.ps1')

$UserAgent = "TFT-Mobile-Overlay-Data/1.0 public-statistics-refresh"
$MetaTftRobotsUrl = "https://www.metatft.com/robots.txt"
$ClusterInfoUrl = "https://api-hc.metatft.com/tft-comps-api/latest_cluster_info"
$CompsDataUrl = "https://api-hc.metatft.com/tft-comps-api/comps_data"
$CompsStatsBaseUrl = "https://api-hc.metatft.com/tft-comps-api/comps_stats"
$AugmentTiersUrl = "https://api-hc.metatft.com/tft-stat-api/augments_tiers"
$CompAugmentTiersBaseUrl = "https://api-hc.metatft.com/tft-comps-api/comp_augment_tiers"
$CommunityDragonUrl = "https://raw.communitydragon.org/latest/cdragon/tft/$Locale.json"
$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$ObservationRoot = Join-Path $RepositoryRoot "build/source-observations"
$IdentityEvidenceRoot = Join-Path $RepositoryRoot "build/source-identity-evidence"

function Write-SourceObservation {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Text
    )
    New-Item -ItemType Directory -Force -Path $ObservationRoot | Out-Null
    $sha = [Security.Cryptography.SHA256]::Create()
    $urlKey = ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Url)) | ForEach-Object { $_.ToString('x2') }) -join ''
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $responseHash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    $sha.Dispose()
    $record = [ordered]@{
        sourceUrl = $Url
        finalUrl = $Url
        fetchedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        responseHash = $responseHash
        bytes = [int64]$bytes.Length
    }
    [IO.File]::WriteAllText(
        (Join-Path $ObservationRoot "$urlKey-$responseHash.json"),
        ($record | ConvertTo-Json) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
}

function Get-Text {
    param([Parameter(Mandatory = $true)][string]$Url)

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $lines = & curl.exe -L --fail --silent --show-error --max-time 120 `
            -A $UserAgent $Url
        if ($LASTEXITCODE -eq 0) {
            $text = ($lines -join "`n")
            Write-SourceObservation -Url $Url -Text $text
            return $text
        }
        if ($attempt -lt 3) { Start-Sleep -Seconds ([Math]::Pow(2, $attempt - 1)) }
    }
    throw "Request failed after 3 attempts ($LASTEXITCODE): $Url"
}

function Get-Json {
    param([Parameter(Mandatory = $true)][string]$Url)

    $text = Get-Text -Url $Url
    try {
        $document = $text | ConvertFrom-Json
        $nativeClaims = [ordered]@{}
        if ($document.PSObject.Properties['cluster_info'] -and $document.cluster_info) {
            if ($document.cluster_info.tft_set) { $nativeClaims.setId = [string]$document.cluster_info.tft_set }
            if ($document.cluster_info.cluster_id) { $nativeClaims.revisionId = [string]$document.cluster_info.cluster_id }
        } elseif ($document.PSObject.Properties['tft_set']) {
            if ($document.tft_set) { $nativeClaims.setId = [string]$document.tft_set }
            if ($document.PSObject.Properties['cluster_id'] -and $document.cluster_id) { $nativeClaims.revisionId = [string]$document.cluster_id }
        } elseif ($document.PSObject.Properties['results'] -and $document.results -and $document.results.PSObject.Properties['data']) {
            if ($document.results.data.tft_set) { $nativeClaims.setId = [string]$document.results.data.tft_set }
            if ($document.results.data.cluster_id) { $nativeClaims.revisionId = [string]$document.results.data.cluster_id }
        }
        $queryClaims = [ordered]@{}
        if ($Url -match '(?:[?&])cluster_id=([^&]+)') { $queryClaims.revisionId = [uri]::UnescapeDataString($Matches[1]) }
        if ($Url -match '(?:[?&])patch=([^&]+)') { $queryClaims.patchMode = [uri]::UnescapeDataString($Matches[1]) }
        if ($Url -match '(?:[?&])rank=([^&]+)') { $queryClaims.rank = [uri]::UnescapeDataString($Matches[1]) }
        if ($Url -match '(?:[?&])permit_filter_adjustment=([^&]+)') { $queryClaims.permitFilterAdjustment = [uri]::UnescapeDataString($Matches[1]) }
        if ($nativeClaims.Count -gt 0 -or $queryClaims.Count -gt 0) {
            New-Item -ItemType Directory -Force -Path $IdentityEvidenceRoot | Out-Null
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $urlKey = ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Url)) | ForEach-Object { $_.ToString('x2') }) -join ''
                $responseHash = ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)) | ForEach-Object { $_.ToString('x2') }) -join ''
            } finally { $sha.Dispose() }
            $evidence = [ordered]@{
                sourceUrl = $Url
                responseHash = $responseHash
                evidenceKind = $(if ($nativeClaims.Count -gt 0) { 'RESPONSE_NATIVE_IDENTITY' } else { 'QUERY_BOUND_RESPONSE' })
                nativeClaims = $nativeClaims
                queryClaims = $queryClaims
                observedAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
            }
            [IO.File]::WriteAllText((Join-Path $IdentityEvidenceRoot "$urlKey-$responseHash.json"), (($evidence | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
        }
        return $document
    } catch {
        throw "Invalid JSON from $Url`: $($_.Exception.Message)"
    }
}

function ConvertTo-ReadableName {
    param([Parameter(Mandatory = $true)][string]$ApiName)

    $name = $ApiName -replace '^TFT\d*_', '' -replace '^TFT_', ''
    $name = $name -replace '_', ' '
    return (($name -creplace '([a-z])([A-Z])', '$1 $2') -replace '\s+', ' ').Trim()
}

function ConvertTo-MetaTftTitlePart {
    param(
        [Parameter(Mandatory = $true)][string]$ApiName,
        [Parameter(Mandatory = $true)][hashtable]$MetaTftNameMap,
        [Parameter(Mandatory = $true)][hashtable]$UnitMap,
        [Parameter(Mandatory = $true)][hashtable]$TraitMap,
        [Parameter(Mandatory = $true)][hashtable]$ItemMap
    )

    if ($MetaTftNameMap.ContainsKey($ApiName)) {
        return [string]$MetaTftNameMap[$ApiName]
    }
    if ($UnitMap.ContainsKey($ApiName)) {
        return [string]$UnitMap[$ApiName].name
    }
    if ($TraitMap.ContainsKey($ApiName)) {
        $localizedName = [string]$TraitMap[$ApiName].name
        # CommunityDragon intentionally gives all Stargazer variants the same
        # base trait name. MetaTFT's composition list appends the variant name.
        $stargazerVariant = switch ($ApiName) {
            'TFT17_Stargazer_Wolf' { '狼' }
            'TFT17_Stargazer_Medallion' { 'メダリオン' }
            'TFT17_Stargazer_Huntress' { '女狩人' }
            'TFT17_Stargazer_Serpent' { '蛇' }
            'TFT17_Stargazer_Shield' { '盾' }
            'TFT17_Stargazer_Fountain' { '泉' }
            'TFT17_Stargazer_Mountain' { '山' }
            default { $null }
        }
        if ($stargazerVariant) {
            return "$localizedName - $stargazerVariant"
        }
        return $localizedName
    }
    if ($ItemMap.ContainsKey($ApiName)) {
        return [string]$ItemMap[$ApiName].name
    }
    return ConvertTo-ReadableName -ApiName $ApiName
}

function ConvertTo-BoardPosition {
    param([Parameter(Mandatory = $true)][string]$Cell)

    if ($Cell -notmatch '^cell_(\d+)$') { return -1 }
    $position = [int]$Matches[1] - 1
    if ($position -lt 0 -or $position -ge 28) { return -1 }
    $sourceRow = [Math]::Floor($position / 7)
    $column = $position % 7
    return [int]((3 - $sourceRow) * 7 + $column)
}

function New-BoardUnits {
    param(
        [Parameter(Mandatory = $true)][string[]]$UnitIds,
        [Parameter(Mandatory = $true)]$Details,
        [Parameter(Mandatory = $true)][hashtable]$UnitMap,
        [Parameter(Mandatory = $true)][hashtable]$StarTargets
    )

    $positioningUnits = $Details.positioning.units
    $eligibleUnitIds = @(
        $UnitIds | Where-Object {
            $UnitMap.ContainsKey([string]$_) -and @($UnitMap[[string]$_].traits).Count -gt 0
        }
    )
    $positionCandidatesByUnit = @{}
    foreach ($uniqueUnitIdValue in @($eligibleUnitIds | Select-Object -Unique)) {
        $uniqueUnitId = [string]$uniqueUnitIdValue
        $property = $positioningUnits.PSObject.Properties[$uniqueUnitId]
        $candidateList = [System.Collections.Generic.List[object]]::new()
        if ($property) {
            foreach ($positionRow in @($property.Value.positions)) {
                $boardPosition = ConvertTo-BoardPosition -Cell ([string]$positionRow.cell)
                if ($boardPosition -ge 0) {
                    $candidateList.Add([pscustomobject]@{
                        position = [int]$boardPosition
                        count = [int]$positionRow.count
                    })
                }
            }
        }
        $positionCandidatesByUnit[$uniqueUnitId] = @(
            $candidateList.ToArray() | Sort-Object @{ Expression = { -[int]$_.count } }, position
        )
    }

    # MetaTFT includes duplicate champion IDs when a completed board fields
    # multiple copies. Keep each occurrence as an independent board slot.
    $occurrences = @{}
    $instances = @(
        foreach ($unitIdValue in $eligibleUnitIds) {
            $unitId = [string]$unitIdValue
            $occurrence = if ($occurrences.ContainsKey($unitId)) { [int]$occurrences[$unitId] } else { 0 }
            $occurrences[$unitId] = $occurrence + 1
            [pscustomobject]@{
                key = "$unitId#$occurrence"
                unitId = $unitId
                occurrence = $occurrence
            }
        }
    )
    $priorityRows = [System.Collections.Generic.List[object]]::new()
    foreach ($instance in $instances) {
        $unitCandidateRows = @($positionCandidatesByUnit[[string]$instance.unitId])
        $firstCandidate = if ($unitCandidateRows.Count -gt 0) { $unitCandidateRows[0] } else { $null }
        $priorityCount = if ($null -ne $firstCandidate) { [int]$firstCandidate.count } else { 0 }
        $priorityRows.Add([pscustomobject]@{
            instance = $instance
            priorityCount = $priorityCount
        })
    }
    $priority = @(
        $priorityRows.ToArray() |
            Sort-Object @{ Expression = { -[int]$_.priorityCount } }, @{ Expression = { [int]$_.instance.occurrence } } |
            ForEach-Object { $_.instance }
    )
    $occupied = @{}
    $assigned = @{}
    foreach ($instance in $priority) {
        $unitId = [string]$instance.unitId
        $choice = $null
        foreach ($candidate in @($positionCandidatesByUnit[$unitId])) {
            $candidatePosition = [int]$candidate.position
            if (-not $occupied.ContainsKey([string]$candidatePosition)) {
                $choice = $candidate
                break
            }
        }
        if ($choice) {
            $assigned[[string]$instance.key] = [int]$choice.position
            $occupied[[string]$choice.position] = $true
        } else {
            $fallback = 0..27 | Where-Object { -not $occupied.ContainsKey([string]$_) } | Select-Object -First 1
            $assigned[[string]$instance.key] = [int]$fallback
            $occupied[[string]$fallback] = $true
        }
    }

    return @(
        foreach ($instance in $instances) {
            $unitId = [string]$instance.unitId
            [pscustomobject][ordered]@{
                id = [string]$unitId
                name = [string]$UnitMap[[string]$unitId].name
                position = [int]$assigned[[string]$instance.key]
                starLevel = if ($StarTargets.ContainsKey([string]$unitId)) { [int]$StarTargets[[string]$unitId].level } else { 0 }
                starRate = if ($StarTargets.ContainsKey([string]$unitId)) { [double]$StarTargets[[string]$unitId].rate } else { 0.0 }
            }
        }
    )
}

function New-BoardReference {
    param(
        [Parameter(Mandatory = $true)][int]$Level,
        [Parameter(Mandatory = $true)][string[]]$UnitIds,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][double]$AveragePlacement,
        [Parameter(Mandatory = $true)][int]$SampleCount,
        [Parameter(Mandatory = $true)]$Details,
        [Parameter(Mandatory = $true)][hashtable]$UnitMap,
        [Parameter(Mandatory = $true)][hashtable]$StarTargets
    )

    return [pscustomobject][ordered]@{
        level = $Level
        source = $Source
        averagePlacement = [double]$AveragePlacement
        sampleCount = $SampleCount
        units = @(New-BoardUnits -UnitIds $UnitIds -Details $Details -UnitMap $UnitMap -StarTargets $StarTargets)
    }
}

function New-StarTargets {
    param(
        [Parameter(Mandatory = $true)]$Details,
        [Parameter(Mandatory = $true)][hashtable]$UnitMap
    )

    $targets = @{}
    foreach ($unit in @($Details.unit_stats)) {
        $selected = @(
            $unit.tiers |
                Where-Object { [int]$_.tier -ge 3 -and [double]$_.pcnt -ge 0.20 } |
                Sort-Object @{ Expression = { -[int]$_.tier } }
        ) | Select-Object -First 1
        $unitCost = if ($UnitMap.ContainsKey([string]$unit.unit)) {
            [int]$UnitMap[[string]$unit.unit].cost
        } else {
            0
        }
        if (-not $selected -and $unitCost -ge 4) {
            $selected = @(
                $unit.tiers |
                    Where-Object { [int]$_.tier -eq 2 -and [double]$_.pcnt -ge 0.55 }
            ) | Select-Object -First 1
        }
        $targets[[string]$unit.unit] = [pscustomobject]@{
            level = if ($selected) { [int]$selected.tier } else { 0 }
            rate = if ($selected) { [double]$selected.pcnt } else { 0.0 }
        }
    }
    return $targets
}

function New-RollPlanResult {
    param(
        [Parameter(Mandatory = $true)][int]$TargetLevel,
        [Parameter(Mandatory = $true)][string]$Source
    )

    $recommendedRolls = switch ($TargetLevel) {
        5 { '目安 10〜15回 / 20〜30G' }
        6 { '目安 15〜20回 / 30〜40G' }
        7 { '目安 15〜25回 / 30〜50G' }
        8 { '目安 10〜20回 / 20〜40G' }
        9 { '目安 5〜10回 / 10〜20G' }
    }
    return [pscustomobject][ordered]@{
        label = "Lv$TargetLevel`リロール"
        targetLevel = $TargetLevel
        recommendedRolls = $recommendedRolls
        levelTimings = @(
            [pscustomobject][ordered]@{ level = 4; stage = '2-1' }
            [pscustomobject][ordered]@{ level = 5; stage = '2-5' }
            [pscustomobject][ordered]@{ level = 6; stage = '3-2' }
            [pscustomobject][ordered]@{ level = 7; stage = '4-1' }
            [pscustomobject][ordered]@{ level = 8; stage = '4-5' }
            [pscustomobject][ordered]@{ level = 9; stage = '5-5' }
        )
        source = "$Source; roll count and level timing are economy heuristics"
    }
}

function New-RollPlan {
    param(
        [Parameter(Mandatory = $true)]$Details,
        [Parameter(Mandatory = $true)]$Composition,
        [Parameter(Mandatory = $true)][hashtable]$UnitMap
    )

    $proCompsProperty = $Details.PSObject.Properties['proComps']
    $proComps = if ($proCompsProperty) { @($proCompsProperty.Value) } else { @() }
    $econTag = @(
        foreach ($proComp in $proComps) {
            $outerContent = $proComp.PSObject.Properties['content']
            if (-not $outerContent) { continue }
            $innerContent = $outerContent.Value.PSObject.Properties['content']
            if (-not $innerContent) { continue }
            $titleImages = $innerContent.Value.PSObject.Properties['titleImages']
            if (-not $titleImages) { continue }
            foreach ($titleImage in @($titleImages.Value)) {
                $apiName = $titleImage.PSObject.Properties['apiName']
                if ($apiName -and [string]$apiName.Value -match '^TFT_Custom_Econ_') {
                    [string]$apiName.Value
                }
            }
        }
    ) | Select-Object -First 1

    switch ([string]$econTag) {
        'TFT_Custom_Econ_Reroll5' { return New-RollPlanResult -TargetLevel 5 -Source 'MetaTFT public guide tag' }
        'TFT_Custom_Econ_Reroll6' { return New-RollPlanResult -TargetLevel 6 -Source 'MetaTFT public guide tag' }
        'TFT_Custom_Econ_Reroll78' {
            $carryId = @($Composition.primaryUnitIds | Where-Object { $UnitMap.ContainsKey([string]$_) }) | Select-Object -First 1
            $carryCost = if ($carryId) { [int]$UnitMap[[string]$carryId].cost } else { 0 }
            if ($carryCost -eq 3) { return New-RollPlanResult -TargetLevel 7 -Source 'MetaTFT guide tag + carry cost' }
            if ($carryCost -eq 4) { return New-RollPlanResult -TargetLevel 8 -Source 'MetaTFT guide tag + carry cost' }
            return New-RollPlanResult -TargetLevel 7 -Source 'MetaTFT public guide tag'
        }
        'TFT_Custom_Econ_Fast9' { return New-RollPlanResult -TargetLevel 9 -Source 'MetaTFT public guide tag' }
        'TFT_Custom_Econ_Fast8' { return New-RollPlanResult -TargetLevel 8 -Source 'MetaTFT public guide tag' }
    }

    $fallbackCarry = @($Composition.primaryUnitIds | Where-Object { $UnitMap.ContainsKey([string]$_) }) | Select-Object -First 1
    $fallbackCost = if ($fallbackCarry) { [int]$UnitMap[[string]$fallbackCarry].cost } else { 4 }
    $targetLevel = switch ($fallbackCost) { 1 { 5 } 2 { 6 } 3 { 7 } 5 { 9 } default { 8 } }
    return New-RollPlanResult -TargetLevel $targetLevel -Source 'Primary carry cost heuristic'
}

$robots = Get-Text -Url $MetaTftRobotsUrl
$siteWideBlock = Test-RobotsSiteWideBlock -RobotsText $robots -UserAgent '*'
if ($siteWideBlock) {
    throw 'MetaTFT robots.txt now contains a site-wide block. Review before refreshing.'
}

$clusterResponse = Get-Json -Url $ClusterInfoUrl
$clusterInfo = $clusterResponse.cluster_info
if (-not $clusterInfo -or -not $clusterInfo.cluster_id -or -not $clusterInfo.tft_set) {
    throw "MetaTFT cluster response is missing cluster_id or tft_set."
}

Start-Sleep -Milliseconds 350
$compsData = Get-Json -Url $CompsDataUrl
$compsDataSet = [string]$compsData.results.data.tft_set
$compsDataClusterId = [int]$compsData.results.data.cluster_id
if (-not $compsData.results.data.cluster_details -or
    $compsDataSet -ne [string]$clusterInfo.tft_set -or
    $compsDataClusterId -ne [int]$clusterInfo.cluster_id) {
    throw "MetaTFT comps_data does not match latest_cluster_info. Refusing a mixed-version snapshot."
}

Start-Sleep -Milliseconds 350
$statisticsScopeContract = Get-TftStatisticsScopeContract
$preferredRankFilter = [string]$statisticsScopeContract.preferredRankFilter
$preferredCompsStatsUrl = "$CompsStatsBaseUrl`?queue=1100&patch=current&days=3&rank=$preferredRankFilter&permit_filter_adjustment=false&cluster_id=$($clusterInfo.cluster_id)"
$compsStatsUrl = $preferredCompsStatsUrl
$compsStats = Get-Json -Url $preferredCompsStatsUrl
Assert-MetaTftStatsContract -Stats $compsStats `
    -ExpectedSetId ([string]$clusterInfo.tft_set) `
    -ExpectedClusterId ([int]$clusterInfo.cluster_id) `
    -ExpectedRankFilter $preferredRankFilter `
    -Context "MetaTFT $($statisticsScopeContract.displayName) comps_stats"
$requiredPreferredCompositions = [Math]::Min($CompositionLimit, [Math]::Max(1, $MinimumPreferredCompositions))
$gameRow = @($compsStats.results | Where-Object { [string]$_.cluster -eq '' } | Select-Object -First 1)
if ($gameRow.Count -eq 0 -or @($gameRow[0].places).Count -lt 1 -or [double]$gameRow[0].places[0] -le 0) {
    throw 'MetaTFT comps_stats is missing the aggregate game-count row used by the comps page.'
}
$gameCount = [double]$gameRow[0].places[0]
$minimumPagePickRate = 0.01
$playerSlotsPerGame = 8
$effectiveMinimumCompSamples = Get-MetaTftPageMinimumSamples `
    -GameCount $gameCount `
    -MinimumPickRate $minimumPagePickRate `
    -PlayerSlotsPerGame $playerSlotsPerGame
$candidatePoolTarget = $CompositionLimit
$fallbackAttempted = $false
$rankScopeDecision = [pscustomobject][ordered]@{
    effectiveScope = [string]$statisticsScopeContract.preferredScope
    useFallback = $false
    minimumSamples = $effectiveMinimumCompSamples
    qualified = 0
    reason = 'Mirrors the public MetaTFT comps page rank scope and visibility rules; rank fallback is disabled.'
}

Start-Sleep -Milliseconds 350
$compOptionsUrl = "https://api-hc.metatft.com/tft-comps-api/comp_options?cluster_id=$($clusterInfo.cluster_id)"
$compOptions = Get-Json -Url $compOptionsUrl

Start-Sleep -Milliseconds 350
$compBuildsUrl = "https://api-hc.metatft.com/tft-comps-api/comp_builds?cluster_id=$($clusterInfo.cluster_id)"
$compBuilds = Get-Json -Url $compBuildsUrl

Start-Sleep -Milliseconds 350
$compAugmentTiersUrl = "$CompAugmentTiersBaseUrl`?cluster_id=$($clusterInfo.cluster_id)"
$compAugmentTiers = Get-Json -Url $compAugmentTiersUrl

Start-Sleep -Milliseconds 350
$augmentResponse = Get-Json -Url $AugmentTiersUrl

Start-Sleep -Milliseconds 350
$communityDragon = Get-Json -Url $CommunityDragonUrl

Start-Sleep -Milliseconds 350
$metaTftLookupUrl = "https://data.metatft.com/lookups/$($clusterInfo.tft_set)_latest_$Locale.json"
$metaTftLookup = Get-Json -Url $metaTftLookupUrl
if (-not $metaTftLookup.PSObject.Properties['_metadata'] -or
    [string]$metaTftLookup._metadata.set -ne [string]$clusterInfo.tft_set) {
    throw "MetaTFT Japanese lookup does not match current set $($clusterInfo.tft_set)."
}

$setData = $communityDragon.setData |
    Where-Object { $_.mutator -eq $clusterInfo.tft_set } |
    Select-Object -First 1
if (-not $setData) {
    throw "CommunityDragon does not contain mutator $($clusterInfo.tft_set)."
}

$unitMap = @{}
foreach ($unit in $setData.champions) {
    if ($unit.apiName -and $unit.name) {
        $unitMap[[string]$unit.apiName] = $unit
    }
}

$traitMap = @{}
foreach ($trait in $setData.traits) {
    if ($trait.apiName -and $trait.name) {
        $traitMap[[string]$trait.apiName] = $trait
    }
}

$itemMap = @{}
foreach ($item in $communityDragon.items) {
    if ($item.apiName -and $item.name) {
        $itemMap[[string]$item.apiName] = $item
    }
}

$metaTftTitleNameMap = @{}
foreach ($entry in @($metaTftLookup.traits) + @($metaTftLookup.items)) {
    if ($entry.apiName -and $entry.name) {
        $metaTftTitleNameMap[[string]$entry.apiName] = [string]$entry.name
    }
}
foreach ($unit in @($metaTftLookup.units)) {
    if (-not $unit.name) { continue }
    if ($unit.apiName) { $metaTftTitleNameMap[[string]$unit.apiName] = [string]$unit.name }
    foreach ($assetName in @($unit.assetNames)) {
        if ($assetName) { $metaTftTitleNameMap[[string]$assetName] = [string]$unit.name }
    }
}
if ($metaTftTitleNameMap.Count -eq 0) {
    throw 'MetaTFT Japanese lookup produced no title mappings.'
}

$canonicalCatalogPath = Join-Path $RepositoryRoot 'source/current/tft/tft_catalog.json'
if (-not (Test-Path -LiteralPath $canonicalCatalogPath -PathType Leaf)) {
    throw "Canonical item catalog missing before static-meta refresh: $canonicalCatalogPath"
}
$canonicalCatalog = Get-Content -Raw -Encoding UTF8 -LiteralPath $canonicalCatalogPath | ConvertFrom-Json
$canonicalItemIndex = New-TftCanonicalIdIndex -Entries @($canonicalCatalog.items)
$canonicalItemMap = @{}
foreach ($canonicalItem in @($canonicalCatalog.items)) {
    if ($canonicalItem.id) { $canonicalItemMap[[string]$canonicalItem.id] = $canonicalItem }
}
if ($canonicalItemMap.Count -eq 0) { throw 'Canonical item catalog is empty.' }

function Resolve-CanonicalPublicationItemId([string]$RawId) {
    if (-not $RawId) { throw 'Empty MetaTFT item ID cannot be published.' }
    $sourceName = if ($itemMap.ContainsKey($RawId)) { [string]$itemMap[$RawId].name } else { '' }
    $resolution = Resolve-TftCanonicalId -Index $canonicalItemIndex -SourceId $RawId -SourceName $sourceName
    if ($resolution.status -in @('EXACT','ALIAS','NAME')) { return [string]$resolution.canonicalId }
    if ($resolution.status -eq 'AMBIGUOUS') {
        throw "AMBIGUOUS_CANONICAL_ITEM_ID raw=$RawId candidates=$($resolution.candidates -join ',')"
    }
    throw "UNRESOLVED_CANONICAL_ITEM_ID raw=$RawId"
}

$activeAugments = @{}
foreach ($augmentId in $setData.augments) {
    $activeAugments[[string]$augmentId] = $true
}

$tierOrder = @{ S = 0; A = 1; B = 2; C = 3; D = 4 }
$augments = foreach ($tierGroup in $augmentResponse.content.content.tierList) {
    $tier = [string]$tierGroup.label
    foreach ($entry in $tierGroup.content) {
        $id = [string]$entry.id
        if (-not $activeAugments.ContainsKey($id) -or -not $itemMap.ContainsKey($id)) {
            continue
        }
        [pscustomobject][ordered]@{
            id = $id
            name = [string]$itemMap[$id].name
            tier = $tier
        }
    }
}
$augments = @($augments | Sort-Object @{ Expression = { $tierOrder[$_.tier] } }, name)
if ($augments.Count -eq 0) {
    throw "No active augments were mapped from MetaTFT to CommunityDragon."
}

$clusters = @{}
foreach ($property in $compsData.results.data.cluster_details.PSObject.Properties) {
    $cluster = $property.Value
    $clusters[[string]$property.Name] = $cluster
}

$compositionCandidates = foreach ($stats in @($compsStats.results)) {
    $clusterId = [string]$stats.cluster
    if (-not $clusterId -or $clusterId -eq '-1') {
        continue
    }
    if (-not $clusters.ContainsKey($clusterId)) {
        continue
    }
    $places = @($stats.places)
    if ($places.Count -lt 9) {
        continue
    }
    $sampleCount = [int]$places[8]
    if ($sampleCount -lt $effectiveMinimumCompSamples) {
        continue
    }
    $placementSum = 0.0
    for ($placeIndex = 0; $placeIndex -lt 8; $placeIndex++) {
        $placementSum += ($placeIndex + 1) * [double]$places[$placeIndex]
    }
    $averagePlacement = $placementSum / $sampleCount

    $cluster = $clusters[$clusterId]
    $centroidMaximum = @($cluster.centroid | Measure-Object -Maximum).Maximum
    if ($null -eq $centroidMaximum -or -not (Test-MetaTftPageCompositionVisible `
        -SampleCount $sampleCount `
        -CentroidMaximum ([double]$centroidMaximum) `
        -MinimumSamples $effectiveMinimumCompSamples `
        -CentroidVisibilityMinimum 1.0)) {
        continue
    }
    $nameParts = foreach ($part in @($cluster.name)) {
        $id = [string]$part.name
        ConvertTo-MetaTftTitlePart -ApiName $id -MetaTftNameMap $metaTftTitleNameMap -UnitMap $unitMap -TraitMap $traitMap -ItemMap $itemMap
    }
    # comps_data is the source used by MetaTFT's live composition list. Preserve
    # its current title-part order; latest_cluster_info can lag behind these
    # user-facing names even when the cluster id has not changed.
    $name = (@($nameParts | Where-Object { $_ } | Select-Object -Unique) -join ' ')
    if (-not $name) { continue }

    $boardUnitIds = @(
        ([string]$cluster.units_string -split ',\s*') |
            Where-Object { $unitMap.ContainsKey($_) -and @($unitMap[$_].traits).Count -gt 0 } |
            Select-Object -First 9
    )

    [pscustomobject][ordered]@{
        id = $clusterId
        displayNameJa = $name
        titleSource = 'MetaTFT comps_data title localized with MetaTFT Japanese lookup'
        titleKey = (@($cluster.name) | ForEach-Object { [string]$_.name } | Where-Object { $_ }) -join '|'
        averagePlacement = [double]$averagePlacement
        sampleCount = $sampleCount
        boardUnitIds = @($boardUnitIds)
        unitIds = @($boardUnitIds | Select-Object -Unique)
        primaryUnitIds = @(
            @($cluster.name) |
                ForEach-Object { [string]$_.name } |
                Where-Object { $unitMap.ContainsKey([string]$_) } |
                Select-Object -Unique
        )
        # Exact per-unit builds rendered by MetaTFT's composition overview.
        # These are intentionally separate from the full item-stat rows used
        # by the optimizer and ranking screens.
        overviewBuilds = @($cluster.builds)
    }
}
$effectiveQualifiedCompositions = @($compositionCandidates).Count
$preferredQualifiedCompositions = $effectiveQualifiedCompositions
$rankScopeDecision.qualified = $effectiveQualifiedCompositions
$rankScopeDecision.effectiveScope = if ($effectiveQualifiedCompositions -lt $requiredPreferredCompositions) { [string]$statisticsScopeContract.limitedScope } else { [string]$statisticsScopeContract.preferredScope }
Write-Output "Composition page parity: Scope=$($rankScopeDecision.effectiveScope) Games=$([int]$gameCount) MinimumSamples=$effectiveMinimumCompSamples Visible=$effectiveQualifiedCompositions Display=$requiredPreferredCompositions"
$compositionCandidates = @(
    $compositionCandidates |
        Sort-Object averagePlacement, @{ Expression = { -$_.sampleCount } } |
        Select-Object -First $CompositionLimit
)
if ($compositionCandidates.Count -eq 0 -and -not $AllowPartial) {
    throw "No compositions met the adaptive minimum sample threshold of $effectiveMinimumCompSamples."
}
for ($compositionIndex = 0; $compositionIndex -lt $compositionCandidates.Count; $compositionIndex++) {
    # Mirrors MetaTFT's unadjusted Avg Placement tier bands. Conditional item,
    # augment, portal, or supporter filters can change the website tier for an
    # individual browser session; the public default list uses these bands.
    $averagePlacement = [double]$compositionCandidates[$compositionIndex].averagePlacement
    $tier = if ($averagePlacement -lt 4.25) {
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
    $compositionCandidates[$compositionIndex] | Add-Member -NotePropertyName tier -NotePropertyValue $tier
}

$totalItemStats = 0
$totalItemRecommendations = 0
$excludedUnresolvableItemRecommendations = 0
$compositions = foreach ($composition in $compositionCandidates) {
    Start-Sleep -Milliseconds 350
    $compDetailsUrl = "https://api-hc.metatft.com/tft-comps-api/comp_details?comp=$($composition.id)&cluster_id=$($clusterInfo.cluster_id)"
    $detailsResponse = Get-Json -Url $compDetailsUrl
    $details = $detailsResponse.results
    if (-not $details -or -not $details.positioning -or -not $details.early_options -or -not $details.options) {
        if ($AllowPartial) { continue }
        throw "MetaTFT comp_details response is incomplete for composition $($composition.id)."
    }
    $starTargets = New-StarTargets -Details $details -UnitMap $unitMap
    $rollPlan = New-RollPlan -Details $details -Composition $composition -UnitMap $unitMap
    if ([int]$rollPlan.targetLevel -le 7) {
        foreach ($primaryUnitId in @($composition.primaryUnitIds)) {
            if (-not $unitMap.ContainsKey([string]$primaryUnitId)) { continue }
            $existingTarget = $starTargets[[string]$primaryUnitId]
            $starTargets[[string]$primaryUnitId] = [pscustomobject]@{
                level = 3
                rate = if ($existingTarget) { [double]$existingTarget.rate } else { 0.0 }
            }
        }
    }

    $compAugmentProperty = $compAugmentTiers.results.PSObject.Properties[[string]$composition.id]
    $recommendedAugments = @(
        if ($compAugmentProperty) {
            $compAugmentProperty.Value.augments |
                Where-Object {
                    $_.tier -in @('S', 'A', 'B') -and
                    $activeAugments.ContainsKey([string]$_.id) -and
                    $itemMap.ContainsKey([string]$_.id)
                } |
                ForEach-Object {
                    [pscustomobject][ordered]@{
                        id = [string]$_.id
                        name = [string]$itemMap[[string]$_.id].name
                        tier = [string]$_.tier
                    }
                }
        }
    )
    if ($recommendedAugments.Count -lt 3) {
        Write-Warning "MetaTFT currently exposes only $($recommendedAugments.Count) comp-specific augment(s) for composition $($composition.id); preserving the source result without generic padding."
    }

    # MetaTFT's composition detail renders the item list in descending `pcnt`
    # order (the UI labels this as item play rate). Keep this composition-wide
    # ranking separate from per-unit three-item-build correlations: the former
    # answers "which items are most commonly adopted in this comp", while the
    # latter answers "which holder performs best with the selected item".
    $itemRecommendations = @(
        foreach ($itemRow in @($details.itemNames)) {
            $rawItemId = [string]$itemRow.itemNames
            $sampleCount = [int]$itemRow.count
            $averagePlacement = [double]$itemRow.avg
            $adoptionRate = [double]$itemRow.pcnt
            if (-not $rawItemId -or $sampleCount -le 0) { continue }
            if ($rawItemId -match '(?i)Augment$') {
                # comp_details can expose augment-granted item aliases beside
                # the equipable item. The app ranks equipable items only.
                continue
            }
            if ($averagePlacement -lt 1.0 -or $averagePlacement -gt 8.0) {
                throw "MetaTFT item recommendation placement is outside 1-8 for $($composition.id)/$rawItemId."
            }
            if ($adoptionRate -lt 0.0 -or $adoptionRate -gt 27.0) {
                throw "MetaTFT item recommendation adoption rate is outside the equipable 0-27 range for $($composition.id)/$rawItemId."
            }
            $canonicalItemId = try {
                Resolve-CanonicalPublicationItemId -RawId $rawItemId
            } catch {
                if ($_.Exception.Message -match '^(AMBIGUOUS|UNRESOLVED)_CANONICAL_ITEM_ID') {
                    $excludedUnresolvableItemRecommendations++
                    Write-Warning "MetaTFT item play-rate row excluded because its canonical ID is not uniquely resolvable: comp=$($composition.id) raw=$rawItemId"
                    continue
                }
                throw
            }
            [pscustomobject][ordered]@{
                itemId = $canonicalItemId
                itemName = [string]$canonicalItemMap[$canonicalItemId].nameJa
                adoptionRate = [double]$adoptionRate
                averagePlacement = [double]$averagePlacement
                sampleCount = $sampleCount
            }
        }
    )
    $itemRecommendations = @(
        Sort-MetaTftCompositionItemRanking `
            -Rows $itemRecommendations `
            -CompositionId ([string]$composition.id) `
            -AllowEmpty:$AllowPartial
    )
    $totalItemRecommendations += $itemRecommendations.Count

    $buildProperty = $compBuilds.results.PSObject.Properties[[string]$composition.id]
    $buildRows = if ($buildProperty) { @($buildProperty.Value.builds) } else { @() }

    $units = foreach ($unitId in $composition.unitIds) {
        $aggregates = @{}
        $unitBuilds = @(
            $buildRows | Where-Object {
                [string]$_.unit -eq $unitId -and
                [int]$_.num_items -eq 3 -and
                [int]$_.count -gt 0 -and
                [double]$_.avg -gt 0
            }
        )

        foreach ($build in $unitBuilds) {
            $count = [int]$build.count
            $averagePlacement = [double]$build.avg
            $fullBuildItemIds = @(
                @($build.buildName) |
                    Where-Object { $_ } |
                    ForEach-Object { Resolve-CanonicalPublicationItemId -RawId ([string]$_) }
            )
            $buildItemIds = @($fullBuildItemIds | Select-Object -Unique)
            foreach ($itemId in $buildItemIds) {
                if (-not $aggregates.ContainsKey($itemId)) {
                    $aggregates[$itemId] = [ordered]@{
                        sampleCount = 0
                        weightedPlacement = 0.0
                        bestBuildSampleCount = 0
                        bestBuildItemIds = @()
                    }
                }
                $aggregate = $aggregates[$itemId]
                $aggregate.sampleCount += $count
                $aggregate.weightedPlacement += $averagePlacement * $count
                if ($count -gt $aggregate.bestBuildSampleCount) {
                    $aggregate.bestBuildSampleCount = $count
                    $aggregate.bestBuildItemIds = @($fullBuildItemIds)
                }
            }
        }

        $itemStats = foreach ($itemId in $aggregates.Keys) {
            $aggregate = $aggregates[$itemId]
            if ($aggregate.sampleCount -lt $MinimumItemSamples) {
                continue
            }
            $itemAverage = $aggregate.weightedPlacement / $aggregate.sampleCount
            [pscustomobject][ordered]@{
                itemId = [string]$itemId
                itemName = [string]$canonicalItemMap[$itemId].nameJa
                averagePlacement = [double]$itemAverage
                placementDelta = [double]($itemAverage - [double]$composition.averagePlacement)
                sampleCount = [int]$aggregate.sampleCount
                bestBuildSampleCount = [int]$aggregate.bestBuildSampleCount
                bestBuild = @(
                    foreach ($buildItemId in $aggregate.bestBuildItemIds) {
                        [pscustomobject][ordered]@{
                            itemId = [string]$buildItemId
                            itemName = [string]$canonicalItemMap[$buildItemId].nameJa
                        }
                    }
                )
            }
        }
        $itemStats = @(
            $itemStats |
                Sort-Object averagePlacement, @{ Expression = { -$_.sampleCount } }, itemName
        )
        $totalItemStats += $itemStats.Count

        $overviewBuildRow = @(
            @($composition.overviewBuilds) |
                Where-Object {
                    [string]$_.unit -eq $unitId -and
                    [int]$_.num_items -eq 3
                } |
                Select-Object -First 1
        )
        $recommendedBuild = @(
            if ($overviewBuildRow.Count -gt 0) {
                @($overviewBuildRow[0].buildName) |
                    Where-Object { $_ } |
                    ForEach-Object {
                        $canonicalItemId = Resolve-CanonicalPublicationItemId -RawId ([string]$_)
                        [pscustomobject][ordered]@{
                            itemId = $canonicalItemId
                            itemName = [string]$canonicalItemMap[$canonicalItemId].nameJa
                        }
                    }
            }
        )

        [pscustomobject][ordered]@{
            id = [string]$unitId
            name = [string]$unitMap[$unitId].name
            recommendedBuild = @($recommendedBuild)
            itemStats = $itemStats
        }
    }

    $finalBoard = New-BoardReference `
        -Level $composition.boardUnitIds.Count `
        -UnitIds @($composition.boardUnitIds) `
        -Source 'MetaTFT aggregate positioning' `
        -AveragePlacement ([double]$composition.averagePlacement) `
        -SampleCount ([int]$composition.sampleCount) `
        -Details $details `
        -UnitMap $unitMap `
        -StarTargets $starTargets

    $levelBoardRows = @{}
    foreach ($level in 4..9) {
        $sourceCollection = if ($level -le 7) { $details.early_options } else { $details.options }
        $levelProperty = $sourceCollection.PSObject.Properties[[string]$level]
        if (-not $levelProperty) { continue }
        $candidates = @($levelProperty.Value | Sort-Object avg, @{ Expression = { -[int]$_.count } } | Select-Object -First 3)
        $rows = @(
            foreach ($candidate in $candidates) {
                $unitListValue = if ($level -le 7) { [string]$candidate.unit_list } else { [string]$candidate.units_list }
                if (-not $unitListValue) { continue }
                $levelUnitIds = @(
                    ($unitListValue -split '&') |
                        Where-Object {
                            $unitMap.ContainsKey([string]$_) -and @($unitMap[[string]$_].traits).Count -gt 0
                        } |
                        Select-Object -First $level
                )
                if ($levelUnitIds.Count -eq 0) { continue }
                [pscustomobject]@{
                    unitIds = @($levelUnitIds)
                    source = $(if ($level -le 7) { 'MetaTFT early_options' } else { 'MetaTFT options' })
                    averagePlacement = [double]$candidate.avg
                    sampleCount = [int]$candidate.count
                }
            }
        )
        if ($rows.Count -gt 0) { $levelBoardRows[[string]$level] = @($rows) }
    }
    $levelBoards = foreach ($level in 4..9) {
        foreach ($row in @($levelBoardRows[[string]$level] | Sort-Object averagePlacement, @{ Expression = { -[int]$_.sampleCount } })) {
            New-BoardReference `
                -Level $level `
                -UnitIds @($row.unitIds) `
                -Source ([string]$row.source) `
                -AveragePlacement ([double]$row.averagePlacement) `
                -SampleCount ([int]$row.sampleCount) `
                -Details $details `
                -UnitMap $unitMap `
                -StarTargets $starTargets
        }
    }

    [pscustomobject][ordered]@{
        id = [string]$composition.id
        displayNameJa = [string]$composition.displayNameJa
        titleSource = [string]$composition.titleSource
        titleKey = [string]$composition.titleKey
        tier = [string]$composition.tier
        averagePlacement = [double]$composition.averagePlacement
        sampleCount = [int]$composition.sampleCount
        itemRecommendations = @($itemRecommendations)
        units = @($units)
        rollPlan = $rollPlan
        recommendedAugments = @($recommendedAugments)
        finalBoard = $finalBoard
        levelBoards = @($levelBoards)
    }
}

$hasIncompleteCompositionMetadata = @(
    @($compositions) | Where-Object { @($_.recommendedAugments).Count -eq 0 }
).Count -gt 0
$readiness = if (@($compositions).Count -eq 0) {
    'META_COLLECTING'
} elseif (@($compositions).Count -lt $requiredPreferredCompositions) {
    'META_COLLECTING'
} elseif ($hasIncompleteCompositionMetadata) {
    'META_COLLECTING'
} else {
    'META_STABLE'
}

$snapshot = [pscustomobject][ordered]@{
    schemaVersion = 5
    fetchedAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    setId = [string]$clusterInfo.tft_set
    clusterId = [int]$clusterInfo.cluster_id
    statsUpdatedEpochMs = [int64]$compsStats.updated
    readiness = $readiness
    locale = $Locale
    sourceSummary = 'MetaTFT public comps page statistics and Japanese names + CommunityDragon canonical catalog'
    statisticsScope = [ordered]@{
        preferred = [string]$statisticsScopeContract.preferredScope
        effective = [string]$rankScopeDecision.effectiveScope
        minimumCompositionSamples = $effectiveMinimumCompSamples
        minimumPreferredCompositions = $requiredPreferredCompositions
        candidatePoolTarget = $candidatePoolTarget
        qualifiedPreferredCompositions = $preferredQualifiedCompositions
        qualifiedEffectiveCompositions = $effectiveQualifiedCompositions
        fallbackAttempted = $fallbackAttempted
        fallbackReason = [string]$rankScopeDecision.reason
        implicitFilterAdjustmentAllowed = $false
        preferredRankFilter = $preferredRankFilter
        fallbackRankFilter = ''
        pageParity = [ordered]@{
            queue = '1100'
            patch = 'current'
            days = 3
            sort = 'Avg Placement'
            minimumPickRate = $minimumPagePickRate
            playerSlotsPerGame = $playerSlotsPerGame
            centroidVisibilityMinimum = 1.0
            situationalCompositions = $true
        }
    }
    disclaimer = 'Static pre-game reference only. Composition item order follows MetaTFT item play rate; holder ranks remain correlations from complete three-item builds.'
    itemStatBasis = [ordered]@{
        source = 'MetaTFT comp_builds public endpoint'
        buildSize = 3
        aggregation = 'For each comp and unit, weighted average of complete three-item build rows containing the item.'
        minimumSamples = $MinimumItemSamples
        lowerAveragePlacementIsBetter = $true
        compositionRankingSource = 'MetaTFT comp_details itemNames'
        compositionRankingMetric = 'adoptionRate'
        compositionRankingDirection = 'descending'
        excludedUnresolvableRecommendationRows = $excludedUnresolvableItemRecommendations
    }
    sources = [ordered]@{
        metaTftRobots = $MetaTftRobotsUrl
        augmentTiers = $AugmentTiersUrl
        clusterInfo = $ClusterInfoUrl
        compositionCatalog = $CompsDataUrl
        compositionStats = $compsStatsUrl
        compositionOptions = $compOptionsUrl
        compositionItemBuilds = $compBuildsUrl
        compositionAugmentTiers = $compAugmentTiersUrl
        compositionDetails = 'https://api-hc.metatft.com/tft-comps-api/comp_details'
        metaTftJapaneseLookup = $metaTftLookupUrl
        communityDragon = $CommunityDragonUrl
    }
    augments = @($augments)
    compositions = @($compositions)
}

$repositoryRoot = $RepositoryRoot
$resolvedOutput = if ([IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath
} else {
    Join-Path $repositoryRoot $OutputPath
}
$outputDirectory = Split-Path -Parent $resolvedOutput
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

$json = $snapshot | ConvertTo-Json -Depth 20 -Compress
[IO.File]::WriteAllText($resolvedOutput, ($json.Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))

Write-Output "Wrote $resolvedOutput"
Write-Output "Set=$($snapshot.setId) Cluster=$($snapshot.clusterId) Augments=$($augments.Count) Compositions=$($compositions.Count) ItemRecommendations=$totalItemRecommendations ExcludedUnresolvableRecommendations=$excludedUnresolvableItemRecommendations ItemStats=$totalItemStats"
