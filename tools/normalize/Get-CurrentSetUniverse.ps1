Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-TftInternalItem {
    param([Parameter(Mandatory = $true)]$Item)
    $id = [string]$Item.apiName
    if (-not $id) { return $true }
    if ($id -match '(?i)^TFT_Assist_|Debug|Tutorial|TrainingDummy|ArmoryItem_|_Debug|Cheat') { return $true }
    return $false
}

function Test-TftSharedItemFamily {
    param([Parameter(Mandatory = $true)][string]$Id)
    return $Id -match '(?i)(^TFT_Item_|Artifact|Ornn|Radiant|Support|Emblem|Spatula|FryingPan)'
}

function Get-TftExplicitItemSetNumber {
    param([Parameter(Mandatory = $true)][string]$Id)
    if ($Id -match '^TFT(\d+)_') { return [int]$Matches[1] }
    if ($Id -match '^DA_(\d+)_') { return [int]$Matches[1] }
    return $null
}

function Get-TftCurrentSetUniverse {
    param(
        [Parameter(Mandatory = $true)][int]$SetNumber,
        [Parameter(Mandatory = $true)]$SetData,
        [Parameter(Mandatory = $true)][object[]]$AllItems,
        [string[]]$AdditionalItemIds = @(),
        [string[]]$ExcludedItemIds = @()
    )

    $itemById = @{}
    foreach ($item in @($AllItems)) {
        if ($null -ne $item -and $item.apiName) { $itemById[[string]$item.apiName] = $item }
    }

    $explicitExclusions = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($ExcludedItemIds)) {
        if ($id) { [void]$explicitExclusions.Add([string]$id) }
    }

    $seedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($SetData.items) + @($AdditionalItemIds)) {
        if ($id -and -not $explicitExclusions.Contains([string]$id)) {
            [void]$seedIds.Add([string]$id)
        }
    }

    # CommunityDragon setData.items is not exhaustive for every equipable item.
    # In particular, modern sets can expose emblems and augment-granted special
    # items under explicit current-set namespaces such as DA_18_* without
    # listing them in setData.items. Seed every explicit current-set identity so
    # valid live statistics are not lost merely because the setData list lags.
    # Callers can exclude known non-equipment namespaces (for example augments)
    # without weakening current-set discovery for actual items.
    foreach ($idValue in @($itemById.Keys)) {
        $id = [string]$idValue
        if ($explicitExclusions.Contains($id)) { continue }
        $explicitSetNumber = Get-TftExplicitItemSetNumber -Id $id
        if ($null -ne $explicitSetNumber -and [int]$explicitSetNumber -eq $SetNumber) {
            [void]$seedIds.Add($id)
        }
    }

    $included = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $excluded = [Collections.Generic.List[object]]::new()
    $queue = [Collections.Generic.Queue[string]]::new()

    foreach ($id in $seedIds) {
        if ($explicitExclusions.Contains([string]$id)) {
            $excluded.Add([pscustomobject][ordered]@{ id = [string]$id; reason = 'EXPLICIT_EXCLUSION' })
            continue
        }
        if (-not $itemById.ContainsKey($id)) { continue }
        $item = $itemById[$id]
        if (Test-TftInternalItem -Item $item) {
            $excluded.Add([pscustomobject][ordered]@{ id = $id; reason = 'INTERNAL_HELPER' })
            continue
        }

        $sourceSet = Get-TftExplicitItemSetNumber -Id $id
        $otherSet = $null -ne $sourceSet -and [int]$sourceSet -ne $SetNumber
        if ($otherSet -and -not (Test-TftSharedItemFamily -Id $id)) {
            $excluded.Add([pscustomobject][ordered]@{ id = $id; reason = 'OTHER_SET_ONLY' })
            continue
        }

        if ($included.Add($id)) { $queue.Enqueue($id) }
    }

    while ($queue.Count -gt 0) {
        $id = $queue.Dequeue()
        $item = $itemById[$id]
        foreach ($componentId in @($item.from | Where-Object { $_ } | ForEach-Object { [string]$_ })) {
            if ($explicitExclusions.Contains($componentId)) { continue }
            if (-not $itemById.ContainsKey($componentId)) { continue }
            $component = $itemById[$componentId]
            if (Test-TftInternalItem -Item $component) { continue }
            if ($included.Add($componentId)) { $queue.Enqueue($componentId) }
        }
    }

    return [pscustomobject][ordered]@{
        itemIds = @($included | Sort-Object)
        items = @($included | Sort-Object | ForEach-Object { $itemById[[string]$_] })
        excluded = @($excluded)
        explicitExclusions = @($explicitExclusions | Sort-Object)
        missingSeedIds = @($seedIds | Where-Object { -not $itemById.ContainsKey([string]$_) } | Sort-Object)
    }
}
