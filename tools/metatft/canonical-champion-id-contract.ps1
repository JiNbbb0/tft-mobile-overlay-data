Set-StrictMode -Version Latest

function New-MetaTftCanonicalChampionAliasIndex {
    param(
        [Parameter(Mandatory = $true)][hashtable]$CanonicalChampionIds,
        [Parameter(Mandatory = $true)][object[]]$MetaTftUnits
    )

    $candidatesBySourceId = @{}
    $ambiguousSources = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($unit in $MetaTftUnits) {
        $canonicalTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($assetName in @($unit.assetNames)) {
            $assetId = [string]$assetName
            if ($CanonicalChampionIds.ContainsKey($assetId)) { [void]$canonicalTargets.Add($assetId) }
        }
        $metaApiName = [string]$unit.apiName
        if ($CanonicalChampionIds.ContainsKey($metaApiName)) { [void]$canonicalTargets.Add($metaApiName) }
        if ($canonicalTargets.Count -ne 1) {
            if ($canonicalTargets.Count -gt 1) {
                foreach ($sourceId in @([string]$unit.apiName) + @($unit.assetNames | ForEach-Object { [string]$_ })) {
                    if ($sourceId -and -not $CanonicalChampionIds.ContainsKey($sourceId)) { [void]$ambiguousSources.Add($sourceId) }
                }
            }
            continue
        }

        $canonicalId = @($canonicalTargets)[0]
        foreach ($sourceId in @($metaApiName) + @($unit.assetNames | ForEach-Object { [string]$_ })) {
            if (-not $sourceId -or $CanonicalChampionIds.ContainsKey($sourceId)) { continue }
            if (-not $candidatesBySourceId.ContainsKey($sourceId)) {
                $candidatesBySourceId[$sourceId] = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            }
            [void]$candidatesBySourceId[$sourceId].Add($canonicalId)
        }
    }

    $index = @{}
    $ambiguousIds = [Collections.Generic.List[string]]::new()
    foreach ($sourceId in $candidatesBySourceId.Keys) {
        $targets = @($candidatesBySourceId[$sourceId])
        if ($targets.Count -eq 1) {
            $index[[string]$sourceId] = [string]$targets[0]
        } else {
            [void]$ambiguousSources.Add([string]$sourceId)
        }
    }
    foreach ($sourceId in $ambiguousSources) { $ambiguousIds.Add([string]$sourceId) }

    return [pscustomobject]@{
        aliases = $index
        ambiguousIds = @($ambiguousIds.ToArray() | Sort-Object -Unique)
    }
}

function Resolve-MetaTftCanonicalChampionId {
    param(
        [Parameter(Mandatory = $true)][string]$SourceId,
        [Parameter(Mandatory = $true)][hashtable]$CanonicalChampionIds,
        [Parameter(Mandatory = $true)][hashtable]$Aliases
    )

    if ($CanonicalChampionIds.ContainsKey($SourceId)) { return $SourceId }
    if ($Aliases.ContainsKey($SourceId)) { return [string]$Aliases[$SourceId] }
    throw "UNRESOLVED_CANONICAL_CHAMPION_ID raw=$SourceId"
}
