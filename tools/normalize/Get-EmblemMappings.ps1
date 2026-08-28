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

function Get-TftEmblemMappings {
    param(
        [Parameter(Mandatory = $true)][object[]]$Traits,
        [Parameter(Mandatory = $true)][object[]]$Items
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

            $associatedTraits = @($item.associatedTraits | Where-Object { $_ } | ForEach-Object { [string]$_ })
            $nameKey = Normalize-TftLookupText -Text $name
            $idMatch = $associatedTraits -contains $traitId
            $nameMatch = $traitNameKey -and ($nameKey -match [regex]::Escape($traitNameKey))

            if ($idMatch -or $nameMatch) {
                $candidateRows.Add([pscustomobject][ordered]@{
                    item = $item
                    confidence = $(if ($idMatch) { 2 } else { 1 })
                })
            }
        }

        $candidates = @(
            $candidateRows.ToArray() |
                Sort-Object @{ Expression = { -[int]$_.confidence } }, @{ Expression = { [string]$_.item.apiName } }
        )
        if ($candidates.Count -eq 0) { continue }

        $bestConfidence = [int]$candidates[0].confidence
        $best = @($candidates | Where-Object { [int]$_.confidence -eq $bestConfidence })
        if ($best.Count -gt 1) {
            $ambiguous.Add([pscustomobject][ordered]@{
                traitId = $traitId
                traitName = $traitName
                candidateIds = @($best | ForEach-Object { [string]$_.item.apiName })
            })
            continue
        }

        $item = $best[0].item
        $recipe = @($item.from | Where-Object { $_ } | ForEach-Object { [string]$_ })
        $mappings.Add([pscustomobject][ordered]@{
            traitId = $traitId
            traitName = $traitName
            emblemId = [string]$item.apiName
            emblemName = [string]$item.name
            craftable = ($recipe.Count -eq 2)
            recipe = @($recipe)
            icon = [string]$item.icon
            sourceConfidence = $(if ($bestConfidence -eq 2) { 'ASSOCIATED_TRAIT' } else { 'LOCALIZED_NAME' })
        })
    }

    return [pscustomobject][ordered]@{
        mappings = @($mappings)
        ambiguous = @($ambiguous)
        mappedTraitIds = @($mappings | ForEach-Object { [string]$_.traitId } | Sort-Object -Unique)
    }
}
