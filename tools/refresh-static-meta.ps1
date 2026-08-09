param(
    [string]$OutputPath = "source/current/tft_static_snapshot.json",
    [string]$Locale = "ja_jp",
    [int]$MinimumCompSamples = 5000,
    [int]$MinimumItemSamples = 50,
    [int]$CompositionLimit = 18,
    [switch]$AllowPartial
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

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
        fetchedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        responseHash = $responseHash
        bytes = [int64]$bytes.Length
    }
    [IO.File]::WriteAllText(
        (Join-Path $ObservationRoot "$urlKey.json"),
        ($record | ConvertTo-Json) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
}

function Get-Text {
    param([Parameter(Mandatory = $true)][string]$Url)

    $lines = & curl.exe -L --fail --silent --show-error --max-time 120 `
        -A $UserAgent $Url
    if ($LASTEXITCODE -ne 0) {
        throw "Request failed ($LASTEXITCODE): $Url"
    }
    $text = ($lines -join "`n")
    Write-SourceObservation -Url $Url -Text $text
    return $text
}

function Get-Json {
    param([Parameter(Mandatory = $true)][string]$Url)

    $text = Get-Text -Url $Url
    try {
        return $text | ConvertFrom-Json
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
        [Parameter(Mandatory = $true)][hashtable]$UnitMap,
        [Parameter(Mandatory = $true)][hashtable]$TraitMap,
        [Parameter(Mandatory = $true)][hashtable]$ItemMap
    )

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
                starRate = if ($StarTargets.ContainsKey([string]$unitId)) { [Math]::Round([double]$StarTargets[[string]$unitId].rate, 4) } else { 0.0 }
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
        averagePlacement = [Math]::Round($AveragePlacement, 4)
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
$blockedPaths = @(
    [regex]::Matches($robots, '(?im)^Disallow:\s*(\S+)') |
        ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ -and $_ -ne '/' }
)
if ($blockedPaths.Count -gt 0) {
    throw "MetaTFT robots.txt now contains blocked paths. Review before refreshing: $($blockedPaths -join ', ')"
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
$compsStatsUrl = "$CompsStatsBaseUrl`?queue=1100&patch=current&days=3&rank=CHALLENGER,DIAMOND,EMERALD,GRANDMASTER,MASTER,PLATINUM&permit_filter_adjustment=true"
$compsStats = Get-Json -Url $compsStatsUrl
if ([int]$compsStats.cluster_id -ne [int]$clusterInfo.cluster_id -or
    [string]$compsStats.tft_set -ne [string]$clusterInfo.tft_set) {
    throw "MetaTFT comps_stats does not match latest_cluster_info. Refusing a mixed-version snapshot."
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
    if (-not $compAugmentTiers.results.PSObject.Properties[$clusterId]) {
        continue
    }

    $places = @($stats.places)
    if ($places.Count -lt 9) {
        continue
    }
    $sampleCount = [int]$places[8]
    if ($sampleCount -lt $MinimumCompSamples) {
        continue
    }
    $placementSum = 0.0
    for ($placeIndex = 0; $placeIndex -lt 8; $placeIndex++) {
        $placementSum += ($placeIndex + 1) * [double]$places[$placeIndex]
    }
    $averagePlacement = $placementSum / $sampleCount

    $cluster = $clusters[$clusterId]
    $nameParts = foreach ($part in @($cluster.name)) {
        $id = [string]$part.name
        ConvertTo-MetaTftTitlePart -ApiName $id -UnitMap $unitMap -TraitMap $traitMap -ItemMap $itemMap
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
        titleSource = 'MetaTFT comps_data title localized with CommunityDragon'
        titleKey = (@($cluster.name) | ForEach-Object { [string]$_.name } | Where-Object { $_ }) -join '|'
        averagePlacement = [Math]::Round($averagePlacement, 4)
        sampleCount = $sampleCount
        boardUnitIds = @($boardUnitIds)
        unitIds = @($boardUnitIds | Select-Object -Unique)
        primaryUnitIds = @(
            @($cluster.name) |
                ForEach-Object { [string]$_.name } |
                Where-Object { $unitMap.ContainsKey([string]$_) } |
                Select-Object -Unique
        )
    }
}
$compositionCandidates = @(
    $compositionCandidates |
        Sort-Object averagePlacement, @{ Expression = { -$_.sampleCount } } |
        Select-Object -First $CompositionLimit
)
if ($compositionCandidates.Count -eq 0 -and -not $AllowPartial) {
    throw "No compositions met the minimum sample threshold of $MinimumCompSamples."
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
    if ($recommendedAugments.Count -eq 0 -and -not $AllowPartial) {
        throw "No comp-specific augments for composition $($composition.id)."
    }
    if ($recommendedAugments.Count -lt 3) {
        Write-Warning "MetaTFT currently exposes only $($recommendedAugments.Count) comp-specific augment(s) for composition $($composition.id); preserving the source result without generic padding."
    }
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
                    Where-Object { $_ -and $itemMap.ContainsKey([string]$_) } |
                    ForEach-Object { [string]$_ }
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
                itemName = [string]$itemMap[$itemId].name
                averagePlacement = [Math]::Round($itemAverage, 4)
                placementDelta = [Math]::Round($itemAverage - [double]$composition.averagePlacement, 4)
                sampleCount = [int]$aggregate.sampleCount
                bestBuildSampleCount = [int]$aggregate.bestBuildSampleCount
                bestBuild = @(
                    foreach ($buildItemId in $aggregate.bestBuildItemIds) {
                        [pscustomobject][ordered]@{
                            itemId = [string]$buildItemId
                            itemName = [string]$itemMap[$buildItemId].name
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

        [pscustomobject][ordered]@{
            id = [string]$unitId
            name = [string]$unitMap[$unitId].name
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
    foreach ($level in 4..9) {
        if ($levelBoardRows.ContainsKey([string]$level)) { continue }
        $nearbyLevels = @($levelBoardRows.Keys | ForEach-Object { [int]$_ } | Sort-Object @{ Expression = { [Math]::Abs($_ - $level) } }, @{ Expression = { $_ } })
        if ($nearbyLevels.Count -eq 0) { throw "No adjacent public board available for $($composition.id)/Lv$level" }
        $base = @($levelBoardRows[[string]$nearbyLevels[0]])[0]
        $derivedUnitIds = @(
            @($base.unitIds) +
                @($nearbyLevels | ForEach-Object { @($levelBoardRows[[string]$_])[0].unitIds }) +
                @($composition.boardUnitIds) |
                Where-Object {
                    $unitMap.ContainsKey([string]$_) -and @($unitMap[[string]$_].traits).Count -gt 0
                } |
                Select-Object -First $level
        )
        $levelBoardRows[[string]$level] = @([pscustomobject]@{
            unitIds = @($derivedUnitIds)
            source = 'Derived from adjacent MetaTFT public boards'
            averagePlacement = [double]$base.averagePlacement
            sampleCount = [int]$base.sampleCount
        })
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
        units = @($units)
        rollPlan = $rollPlan
        recommendedAugments = @($recommendedAugments)
        finalBoard = $finalBoard
        levelBoards = @($levelBoards)
    }
}

$readiness = if (@($compositions).Count -eq 0) {
    'META_COLLECTING'
} elseif (@($compositions).Count -lt $CompositionLimit -or $MinimumCompSamples -lt 5000) {
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
    sourceSummary = 'MetaTFT public statistics + CommunityDragon Japanese names'
    disclaimer = 'Static pre-game reference only. Item ranks are correlations aggregated from complete three-item builds inside the selected composition.'
    itemStatBasis = [ordered]@{
        source = 'MetaTFT comp_builds public endpoint'
        buildSize = 3
        aggregation = 'For each comp and unit, weighted average of complete three-item build rows containing the item.'
        minimumSamples = $MinimumItemSamples
        lowerAveragePlacementIsBetter = $true
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
        communityDragon = $CommunityDragonUrl
    }
    augments = $augments
    compositions = $compositions
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
[IO.File]::WriteAllText($resolvedOutput, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

Write-Output "Wrote $resolvedOutput"
Write-Output "Set=$($snapshot.setId) Cluster=$($snapshot.clusterId) Augments=$($augments.Count) Compositions=$($compositions.Count) ItemStats=$totalItemStats"
