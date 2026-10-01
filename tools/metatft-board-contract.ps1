# Contract observed in MetaTFT's public composition UI (2026-10-01).
# Final-level shortlists preserve the upstream candidate order, take three
# eligible rows, then sort by rank-scaled placement. Early boards are different:
# take four popular rows; their metric is round win rate, not final-level rank.
function New-TftMetaBoardIdentityUniverse {
    param([hashtable]$CanonicalChampionIds, [System.Collections.IDictionary]$Aliases, [object[]]$LookupUnits)
    $playable = @{}
    $ignored = @{}
    foreach ($id in $CanonicalChampionIds.Keys) { $playable[[string]$id] = $true }
    foreach ($id in $Aliases.Keys) {
        if (-not $CanonicalChampionIds.ContainsKey([string]$Aliases[$id])) { throw 'Board alias has no current-set canonical champion.' }
        $playable[[string]$id] = $true
    }
    foreach ($unit in $LookupUnits) {
        # An explicit non-shop, zero-cost, traitless source entity is a helper,
        # not a champion. Never infer this from a name, prefix, or set number.
        if (-not $unit.PSObject.Properties['shopUnit'] -or $unit.shopUnit -ne $false -or
            -not $unit.PSObject.Properties['cost'] -or [int]$unit.cost -ne 0 -or
            -not $unit.PSObject.Properties['traits'] -or @($unit.traits).Count -ne 0) { continue }
        foreach ($id in @([string]$unit.apiName) + @($unit.assetNames)) {
            if (-not $id) { continue }
            if ($playable.ContainsKey([string]$id)) { throw 'Source entity is both a helper and a canonical champion.' }
            $ignored[[string]$id] = $true
        }
    }
    return [pscustomobject]@{ playable=$playable; ignored=$ignored }
}

function Get-TftMetaBoardCandidates {
    param([object[]]$Rows, [ValidateSet('FINAL','EARLY')][string]$Kind,
        [int]$Level, [double]$PlacementScale = 1, [hashtable]$PlayableIds, [hashtable]$IgnoredIds = @{})
    if (-not [double]::IsFinite($PlacementScale) -or $PlacementScale -le 0) { throw 'Invalid board placement scale.' }
    $eligible = @(
        foreach ($row in @($Rows)) {
            if ($null -eq $row) { continue }
            $field = if ($Kind -eq 'EARLY') { 'unit_list' } else { 'units_list' }
            $raw = [string]$row.$field
            if (-not $raw -or [int64]$row.count -le 0) { continue }
            $ids = @($raw.Split('&') | Where-Object { $_ })
            $unresolved = @($ids | Where-Object { -not $PlayableIds.ContainsKey($_) -and -not $IgnoredIds.ContainsKey($_) })
            if ($unresolved.Count) { throw "Unresolved board champion identity: $($unresolved -join ',')" }
            $ids = @($ids | Where-Object { $PlayableIds.ContainsKey($_) })
            if (-not $ids.Count) { continue }
            # Real source boards can contain extra playable units (for example an
            # extra team slot). Preserve source membership rather than truncating
            # it to the level number; the 28-cell board is the physical limit.
            if ($ids.Count -gt 28) { throw 'Board exceeds the physical 28-cell grid.' }
            if ($Kind -eq 'FINAL' -and @($ids | Group-Object | Where-Object Count -GE 3).Count) { continue }
            $avg = [double]$row.avg
            if (-not [double]::IsFinite($avg) -or $avg -lt 1 -or $avg -gt 8) { throw 'Invalid source board placement.' }
            $traits = if ($row.PSObject.Properties['traits_list']) { [string]$row.traits_list } else { '' }
            $key = "$Kind|$Level|$raw|$traits"
            $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key))).ToLowerInvariant()
            [pscustomobject]@{ unitIds=$ids; averagePlacement=[Math]::Clamp([double]($avg*$PlacementScale),[double]1,[double]8);
                rawAveragePlacement=$avg; sampleCount=[int64]$row.count; sourceVariantId=$hash;
                sourceTraits=$traits; roundWinRate=$(if ($Kind -eq 'EARLY') { [double]$row.win } else { $null }) }
        }
    )
    if ($Kind -eq 'EARLY') { return @($eligible | Sort-Object @{Expression={-$_.sampleCount}} | Select-Object -First 4) }
    # No global min(avg) selection: that promotes tiny outliers the website does not show.
    return @($eligible | Select-Object -First 3 | Sort-Object averagePlacement -Stable)
}
