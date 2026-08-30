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

function Get-TftEmblemMappings {
    param(
        [Parameter(Mandatory = $true)][object[]]$Traits,
        [Parameter(Mandatory = $true)][object[]]$Items,
        [int]$SetNumber = 0
    )

    $mappings = [Collections.Generic.List[object]]::new()
    $ambiguous = [Collections.Generic.List[object]]::new()

    foreach ($trait in @($Traits)) {
        if ($null -eq $trait) { continue }
        $traitId = [string]$trait.apiName
        $traitName = [string]$trait.name
        if (-not $traitId -or -not $traitName) { continue }

        $traitNameKey = Normalize-TftLookupText -Text $traitName
        $candidateRows = [Collections.Generic.List[object]]::new()
        foreach ($item in @($Items)) {
            if ($null -eq $item -or -not $item.apiName -or -not $item.name) { continue }
            if (Test-TftTemporaryEmblem -Item $item) { continue }

            $id = [string]$item.apiName
            $name = [string]$item.name
            $isEmblem = ($id -match '(?i)Emblem') -or ($name -match '紋章') -or ([string]$item.name -match '(?i) emblem$')
            if (-not $isEmblem) { continue }

            # If a current set is known, explicit records from another set are
            # never valid canonical candidates. This prevents historical emblem
            # records whose associatedTraits were reused from competing with the
            # actual current-set emblem.
            $explicitItemSet = Get-TftEmblemItemSetNumber -ItemId $id
            if ($SetNumber -gt 0 -and $null -ne $explicitItemSet -and [int]$explicitItemSet -ne $SetNumber) {
                continue
            }

            $associatedTraits = @($item.associatedTraits | Where-Object { $_ } | ForEach-Object { [string]$_ })
            $nameKey = Normalize-TftLookupText -Text $name
            $idMatch = $associatedTraits -contains $traitId
            $nameMatch = $traitNameKey -and ($nameKey -match [regex]::Escape($traitNameKey))

            if ($idMatch -or $nameMatch) {
                $candidateRows.Add([pscustomobject][ordered]@{
                    item = $item
                    confidence = $(if ($idMatch) { 2 } else { 1 })
                    explicitCurrentSet = ($SetNumber -gt 0 -and $null -ne $explicitItemSet -and [int]$explicitItemSet -eq $SetNumber)
                    augmentVariant = ($id -match '(?i)Augment')
                })
            }
        }

        $candidates = @(
            $candidateRows.ToArray() |
                Sort-Object @{ Expression = { -[int]$_.confidence } }, @{ Expression = { [string]$_.item.apiName } }
        )
        if ($candidates.Count -eq 0) { continue }

        # Current-set explicit identity is stronger provenance than a generic
        # or legacy namespace. Only use this preference when the caller supplies
        # SetNumber and at least one explicit current-set candidate exists.
        $currentSetCandidates = @($candidates | Where-Object { [bool]$_.explicitCurrentSet })
        if ($SetNumber -gt 0 -and $currentSetCandidates.Count -gt 0) {
            $candidates = @($currentSetCandidates)
        }

        # Some sets expose a secondary Augment-suffixed emblem record beside
        # the normal emblem. When an otherwise equivalent non-Augment record is
        # available, use the normal record for the encyclopedia mapping. If the
        # source only exposes an Augment variant, keep it unresolved rather than
        # manufacturing a canonical mapping.
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
        $provenance = if ($bestConfidence -eq 2) { 'ASSOCIATED_TRAIT' } else { 'LOCALIZED_NAME' }
        if ([bool]$best[0].explicitCurrentSet) { $provenance = "${provenance}_CURRENT_SET" }
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
