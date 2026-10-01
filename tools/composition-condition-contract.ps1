# MetaTFT desktop's situational-composition predicate, not a guessed requirement.
# Public desktop source on 2026-10-01: name_string contains Augment OR
# a top_itemNames row with pcnt >= 0.5 classified as an emblem.
function Get-CompositionSituationalRequirements {
    param([Parameter(Mandatory)]$Cluster, [hashtable]$ItemLookup = @{}, [hashtable]$AugmentLookup = @{})
    $result = [Collections.Generic.List[object]]::new()
    if ($Cluster.PSObject.Properties['name_string'] -and ([string]$Cluster.name_string).Contains('Augment')) {
        $ids = @(
            if ($Cluster.PSObject.Properties['name']) {
                @($Cluster.name) | ForEach-Object { [string]$_.name } | Where-Object { $AugmentLookup.ContainsKey($_) } | Select-Object -Unique
            }
        )
        if ($ids.Count -eq 0) {
            # Source proves this category is conditional, but does not identify an augment.
            # Do not invent an ID mapping or label an arbitrary recommended augment as required.
            $result.Add([pscustomobject][ordered]@{kind='HERO_AUGMENT'; sourceId='METATFT_AUGMENT_MARKER'; name='特定のオーグメント'})
        } else {
            foreach ($id in $ids) { $result.Add([pscustomobject][ordered]@{kind='HERO_AUGMENT'; sourceId=$id; name=[string]$AugmentLookup[$id].name}) }
        }
    }
    if ($Cluster.PSObject.Properties['top_itemNames']) {
        foreach ($row in @($Cluster.top_itemNames)) {
            $rate = [double]$row.pcnt
            if ([double]::IsNaN($rate) -or [double]::IsInfinity($rate) -or $rate -lt 0.5) { continue }
            $id = [string]$row.itemNames
            if (-not $ItemLookup.ContainsKey($id)) { continue }
            $item = $ItemLookup[$id]
            $tags = if ($item.PSObject.Properties['tags']) { @($item.tags) } else { @() }
            $components = @(if ($item.PSObject.Properties['composition']) { $item.composition })
            # Exact source tags/recipe identities; no fuzzy canonical ID mapping.
            $toolCount = @($components | Where-Object { $_ -in @('TFT_Item_Spatula','TFT_Item_FryingPan') }).Count
            $emblem = 'Emblem' -in $tags -or ($components.Count -eq 2 -and $toolCount -eq 1)
            if ($emblem) {
                if (-not $item.name) { throw 'Conditional emblem has no source-backed display name' }
                $result.Add([pscustomobject][ordered]@{kind='EMBLEM'; sourceId=$id; name=[string]$item.name; adoptionRate=$rate})
            }
        }
    }
    $rows = @($result | Sort-Object kind,sourceId -Unique)
    if ($rows.Count -gt 16) { throw 'Too many situational requirements' }
    return $rows
}

function Assert-CompositionSituationalContract {
    param([Parameter(Mandatory)]$Composition)
    $rows = @(if ($Composition.PSObject.Properties['situationalRequirements']) { $Composition.situationalRequirements })
    if ($rows.Count -eq 0) { return }
    if (-not $Composition.PSObject.Properties['conditionContract'] -or $Composition.conditionContract -ne 'METATFT_SITUATIONAL_V1') { throw 'Unknown situational composition contract' }
    if ($rows.Count -gt 16) { throw 'Too many situational requirements' }
    $ids = @{}
    foreach ($row in $rows) {
        if ($row.kind -notin @('EMBLEM','HERO_AUGMENT') -or [string]::IsNullOrWhiteSpace([string]$row.sourceId) -or [string]::IsNullOrWhiteSpace([string]$row.name)) { throw 'Invalid situational requirement identity' }
        if (([string]$row.sourceId).Length -gt 160 -or ([string]$row.name).Length -gt 200 -or $ids.ContainsKey([string]$row.sourceId)) { throw 'Duplicate or oversized situational requirement' }
        $ids[[string]$row.sourceId] = $true
        if ($row.kind -eq 'EMBLEM') {
            if (-not $row.PSObject.Properties['adoptionRate']) { throw 'Conditional emblem requires source adoption rate' }
            $rate = [double]$row.adoptionRate
            if ([double]::IsNaN($rate) -or [double]::IsInfinity($rate) -or $rate -lt 0.5) { throw 'Conditional emblem below source threshold' }
        }
    }
}
