Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Normalize-TftLookupText {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    return (($Text.Normalize([Text.NormalizationForm]::FormKC).ToLowerInvariant()) -replace '[\s\p{P}\p{S}]', '')
}

function Test-TftTemporaryEmblem {
    param([Parameter(Mandatory = $true)]$Item)
    $id = [string]$Item.apiName
    $name = [string]$Item.name
    if ($id -match '(?i)PhantomEmblem|TemporaryEmblem|CopyEmblem') { return $true }
    if ($name -match '(?i)一時的|temporary') { return $true }
    return $false
}

function Get-TftEmblemItemSetNumber {
    param([AllowNull()][string]$ItemId)
    if ([string]::IsNullOrWhiteSpace($ItemId)) { return $null }
    if ($ItemId -match '(?i)^DA_(\d+)_') { return [int]$Matches[1] }
    if ($ItemId -match '(?i)^TFT(\d+)_') { return [int]$Matches[1] }
    return $null
}

function Test-TftExactLocalizedEmblemName {
    param(
        [Parameter(Mandatory = $true)][string]$TraitName,
        [Parameter(Mandatory = $true)][string]$ItemName
    )

    $traitKey = Normalize-TftLookupText -Text $TraitName
    $itemKey = Normalize-TftLookupText -Text $ItemName
    if (-not $traitKey -or -not $itemKey) { return $false }

    # This resolver intentionally accepts only an exact localized emblem label.
    # It must never use substring/fuzzy similarity because a plausible-looking
    # name is not sufficient evidence for a canonical trait->item identity.
    foreach ($suffix in @('の紋章', '紋章', 'emblem')) {
        $suffixKey = Normalize-TftLookupText -Text $suffix
        if ($itemKey -eq "${traitKey}${suffixKey}") { return $true }
    }
    return $false
}

function Get-TftEmblemMappings {
    param(
        [Parameter(Mandatory = $true)][object[]]$Traits,
        [Parameter(Mandatory = $true)][object[]]$Items,
        [int]$SetNumber = 0,
        [string[]]$AllowedItemIds = @()
    )

    $mappings = [Collections.Generic.List[object]]::new()
    $ambiguous = [Collections.Generic.List[object]]::new()

    $allowedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($allowedId in @($AllowedItemIds)) {
        if ($allowedId) { [void]$allowedIds.Add([string]$allowedId) }
    }
    $restrictToAllowedIds = $allowedIds.Count -gt 0

    foreach ($trait in @($Traits)) {
        if ($null -eq $trait) { continue }
        $traitId = [string]$trait.apiName
        $traitName = [string]$trait.name
        if (-not $traitId -or -not $traitName) { continue }

        $candidateRows = [Collections.Generic.List[object]]::new()
        foreach ($item in @($Items)) {
            if ($null -eq $item -or -not $item.apiName -or -not $item.name) { continue }
            if (Test-TftTemporaryEmblem -Item $item) { continue }

            $id = [string]$item.apiName
            $name = [string]$item.name
            if ($restrictToAllowedIds -and -not $allowedIds.Contains($id)) { continue }

            $isEmblem = ($id -match '(?i)Emblem') -or ($name -match '紋章') -or ($name -match '(?i) emblem$')
            if (-not $isEmblem) { continue }

            # Explicit records from another set are never current-set evidence,
            # even if a historical record reused the same associatedTraits.
            $explicitItemSet = Get-TftEmblemItemSetNumber -ItemId $id
            if ($SetNumber -gt 0 -and $null -ne $explicitItemSet -and [int]$explicitItemSet -ne $SetNumber) {
                continue
            }

            $associatedTraits = @($item.associatedTraits | Where-Object { $_ } | ForEach-Object { [string]$_ })
            $idMatch = $associatedTraits -contains $traitId

            # Localized-name fallback is accepted only when the name is exact
            # AND there is independent current-set membership evidence:
            # either an explicit current-set namespace or caller-supplied
            # AllowedItemIds (normally authoritative setData.items).
            $explicitCurrentSet = ($SetNumber -gt 0 -and $null -ne $explicitItemSet -and [int]$explicitItemSet -eq $SetNumber)
            $allowedCurrentSet = ($restrictToAllowedIds -and $allowedIds.Contains($id))
            $nameMatch = $false
            if ($explicitCurrentSet -or $allowedCurrentSet) {
                $nameMatch = Test-TftExactLocalizedEmblemName -TraitName $traitName -ItemName $name
            }

            if ($idMatch -or $nameMatch) {
                $candidateRows.Add([pscustomobject][ordered]@{
                    item = $item
                    confidence = $(if ($idMatch) { 2 } else { 1 })
                    explicitCurrentSet = $explicitCurrentSet
                    allowedCurrentSet = $allowedCurrentSet
                    augmentVariant = ($id -match '(?i)Augment')
                    exactLocalizedName = $nameMatch
                })
            }
        }

        $candidates = @(
            $candidateRows.ToArray() |
                Sort-Object @{ Expression = { -[int]$_.confidence } }, @{ Expression = { [string]$_.item.apiName } }
        )
        if ($candidates.Count -eq 0) { continue }

        # Explicit current-set identity is stronger provenance than a generic or
        # legacy namespace. Do not use this preference to mask two conflicting
        # explicit current-set candidates; those still reach the ambiguity gate.
        $currentSetCandidates = @($candidates | Where-Object { [bool]$_.explicitCurrentSet })
        if ($SetNumber -gt 0 -and $currentSetCandidates.Count -gt 0) {
            $candidates = @($currentSetCandidates)
        }

        # Some sets expose an Augment-suffixed helper record beside the normal
        # emblem. Prefer the normal item only when it exists. Augment-only source
        # data remains unresolved rather than becoming an encyclopedia item.
        $nonAugmentCandidates = @($candidates | Where-Object { -not [bool]$_.augmentVariant })
        if ($nonAugmentCandidates.Count -gt 0) {
            $candidates = @($nonAugmentCandidates)
        } elseif (@($candidates | Where-Object { [bool]$_.augmentVariant }).Count -gt 0) {
            $ambiguous.Add([pscustomobject][ordered]@{
                traitId = $traitId
                traitName = $traitName
                reason = 'AUGMENT_VARIANT_ONLY'
                candidateIds = @($candidates | ForEach-Object { [string]$_.item.apiName })
            })
            continue
        }

        $bestConfidence = [int]($candidates | Measure-Object -Property confidence -Maximum).Maximum
        $best = @($candidates | Where-Object { [int]$_.confidence -eq $bestConfidence })
        if ($best.Count -gt 1) {
            $ambiguous.Add([pscustomobject][ordered]@{
                traitId = $traitId
                traitName = $traitName
                reason = 'MULTIPLE_EQUAL_CONFIDENCE'
                candidateIds = @($best | ForEach-Object { [string]$_.item.apiName })
            })
            continue
        }

        $item = $best[0].item
        $recipe = @($item.from | Where-Object { $_ } | ForEach-Object { [string]$_ })
        $provenance = if ($bestConfidence -eq 2) { 'ASSOCIATED_TRAIT' } else { 'EXACT_LOCALIZED_NAME' }
        if ([bool]$best[0].explicitCurrentSet) {
            $provenance = "${provenance}_CURRENT_SET"
        } elseif ([bool]$best[0].allowedCurrentSet) {
            $provenance = "${provenance}_DECLARED_CURRENT_SET"
        }

        $mappings.Add([pscustomobject][ordered]@{
            traitId = $traitId
            traitName = $traitName
            emblemId = [string]$item.apiName
            emblemName = [string]$item.name
            craftable = ($recipe.Count -eq 2)
            recipe = @($recipe)
            icon = [string]$item.icon
            sourceConfidence = $provenance
        })
    }

    return [pscustomobject][ordered]@{
        mappings = @($mappings)
        ambiguous = @($ambiguous)
        mappedTraitIds = @($mappings | ForEach-Object { [string]$_.traitId } | Sort-Object -Unique)
    }
}
