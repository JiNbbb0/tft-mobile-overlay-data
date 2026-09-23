Set-StrictMode -Version Latest

function Test-TftCanonicalChampionIdExact {
    param(
        [Parameter(Mandatory = $true)][hashtable]$CanonicalChampionIds,
        [Parameter(Mandatory = $true)][string]$Id
    )

    foreach ($canonicalId in $CanonicalChampionIds.Keys) {
        if ([StringComparer]::Ordinal.Equals([string]$canonicalId, $Id)) { return $true }
    }
    return $false
}

function New-MetaTftCanonicalChampionAliasIndex {
    param(
        [Parameter(Mandatory = $true)][hashtable]$CanonicalChampionIds,
        [Parameter(Mandatory = $true)][object[]]$MetaTftUnits
    )

    $candidatesBySourceId = [Collections.Generic.Dictionary[string, Collections.Generic.HashSet[string]]]::new([StringComparer]::Ordinal)
    $ambiguousSources = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($unit in $MetaTftUnits) {
        $canonicalTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($assetName in @($unit.assetNames)) {
            $assetId = [string]$assetName
            if (Test-TftCanonicalChampionIdExact -CanonicalChampionIds $CanonicalChampionIds -Id $assetId) { [void]$canonicalTargets.Add($assetId) }
        }
        $metaApiName = [string]$unit.apiName
        if (Test-TftCanonicalChampionIdExact -CanonicalChampionIds $CanonicalChampionIds -Id $metaApiName) { [void]$canonicalTargets.Add($metaApiName) }
        if ($canonicalTargets.Count -ne 1) {
            if ($canonicalTargets.Count -gt 1) {
                foreach ($sourceId in @([string]$unit.apiName) + @($unit.assetNames | ForEach-Object { [string]$_ })) {
                    if ($sourceId -and -not (Test-TftCanonicalChampionIdExact -CanonicalChampionIds $CanonicalChampionIds -Id $sourceId)) { [void]$ambiguousSources.Add($sourceId) }
                }
            }
            continue
        }

        $canonicalId = @($canonicalTargets)[0]
        foreach ($sourceId in @($metaApiName) + @($unit.assetNames | ForEach-Object { [string]$_ })) {
            if (-not $sourceId -or (Test-TftCanonicalChampionIdExact -CanonicalChampionIds $CanonicalChampionIds -Id $sourceId)) { continue }
            if (-not $candidatesBySourceId.ContainsKey($sourceId)) {
                $candidatesBySourceId[$sourceId] = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            }
            [void]$candidatesBySourceId[$sourceId].Add($canonicalId)
        }
    }

    $index = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
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
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Aliases
    )

    if (Test-TftCanonicalChampionIdExact -CanonicalChampionIds $CanonicalChampionIds -Id $SourceId) { return $SourceId }
    if ($Aliases.ContainsKey($SourceId)) { return [string]$Aliases[$SourceId] }
    throw "UNRESOLVED_CANONICAL_CHAMPION_ID raw=$SourceId"
}
