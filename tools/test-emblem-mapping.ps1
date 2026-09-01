$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'normalize/Get-EmblemMappings.ps1')

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ([string]$Actual -ne [string]$Expected) { throw "$Message. Expected=$Expected Actual=$Actual" }
}
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

# Baseline: associatedTraits is authoritative; localized-name fallback remains
# available only when the item has independent current-set membership evidence.
$traits = @(
    [pscustomobject]@{ apiName = 'TFT19_Forest'; name = '森' },
    [pscustomobject]@{ apiName = 'TFT19_Mage'; name = '魔術師' },
    [pscustomobject]@{ apiName = 'TFT19_NoEmblem'; name = '固有特性' }
)
$items = @(
    [pscustomobject]@{
        apiName = 'TFT19_Item_ForestEmblem'
        name = '森の紋章'
        associatedTraits = @('TFT19_Forest')
        from = @('TFT_Item_Spatula','TFT_Item_GiantsBelt')
        icon = 'forest.png'
    },
    [pscustomobject]@{
        apiName = 'TFT19_Item_MageEmblem'
        name = '魔術師の紋章'
        associatedTraits = @()
        from = @()
        icon = 'mage.png'
    },
    [pscustomobject]@{
        apiName = 'DA_PhantomEmblem19'
        name = '幻の紋章'
        associatedTraits = @()
        from = @()
        icon = 'phantom.png'
    }
)

$result = Get-TftEmblemMappings -Traits $traits -Items $items -SetNumber 19 -AllowedItemIds @('TFT19_Item_ForestEmblem','TFT19_Item_MageEmblem')
Assert-Equal @($result.mappings).Count 2 'Expected two real trait emblems'
Assert-Equal @($result.ambiguous).Count 0 'Synthetic fixture should have no ambiguous mappings'
$forest = @($result.mappings | Where-Object traitId -eq 'TFT19_Forest')[0]
Assert-Equal $forest.emblemId 'TFT19_Item_ForestEmblem' 'Associated-trait mapping failed'
Assert-Equal $forest.craftable $true 'Two-component emblem should be craftable'
$mage = @($result.mappings | Where-Object traitId -eq 'TFT19_Mage')[0]
Assert-True ([string]$mage.sourceConfidence -like 'EXACT_LOCALIZED_NAME*') 'Exact localized-name fallback failed'
if (@($result.mappings.emblemId) -contains 'DA_PhantomEmblem19') { throw 'Temporary phantom emblem must not satisfy a trait mapping.' }
if (@($result.mappedTraitIds) -contains 'TFT19_NoEmblem') { throw 'Traits without an emblem must remain unmapped.' }

# A substring is not identity evidence. The previous implementation could map
# "魔術師" to "大魔術師の紋章" because it used regex substring matching.
$substringTrap = @(
    [pscustomobject]@{
        apiName = 'TFT19_Item_ArchMageEmblem'
        name = '大魔術師の紋章'
        associatedTraits = @()
        from = @()
        icon = 'arch-mage.png'
    }
)
$substringResult = Get-TftEmblemMappings -Traits @($traits[1]) -Items $substringTrap -SetNumber 19 -AllowedItemIds @('TFT19_Item_ArchMageEmblem')
Assert-Equal @($substringResult.mappings).Count 0 'Substring/fuzzy localized names must never create a canonical mapping'
Assert-Equal @($substringResult.ambiguous).Count 0 'Substring-only evidence must be ignored, not promoted to ambiguity'

# Even an exact localized name is ignored when the caller supplies an
# authoritative current-set universe and the item is outside it.
$outsideUniverse = @(
    [pscustomobject]@{
        apiName = 'TFT19_Item_MageEmblem'
        name = '魔術師の紋章'
        associatedTraits = @()
        from = @()
        icon = 'mage.png'
    },
    [pscustomobject]@{
        apiName = 'TFT19_Item_ForestEmblem'
        name = '森の紋章'
        associatedTraits = @('TFT19_Forest')
        from = @()
        icon = 'forest.png'
    }
)
$outsideResult = Get-TftEmblemMappings -Traits @($traits[1]) -Items $outsideUniverse -SetNumber 19 -AllowedItemIds @('TFT19_Item_ForestEmblem')
Assert-Equal @($outsideResult.mappings).Count 0 'Emblem-like items outside the declared current-set universe must not map'

# Two equally strong exact current-set candidates are ambiguity, never a
# deterministic first-result choice.
$duplicateItems = @(
    [pscustomobject]@{
        apiName = 'TFT19_Item_MageEmblemA'
        name = '魔術師の紋章'
        associatedTraits = @()
        from = @()
        icon = 'mage-a.png'
    },
    [pscustomobject]@{
        apiName = 'TFT19_Item_MageEmblemB'
        name = '魔術師の紋章'
        associatedTraits = @()
        from = @()
        icon = 'mage-b.png'
    }
)
$duplicateResult = Get-TftEmblemMappings -Traits @($traits[1]) -Items $duplicateItems -SetNumber 19 -AllowedItemIds @('TFT19_Item_MageEmblemA','TFT19_Item_MageEmblemB')
Assert-Equal @($duplicateResult.mappings).Count 0 'Duplicate exact current-set emblem candidates must fail closed'
Assert-Equal @($duplicateResult.ambiguous).Count 1 'Duplicate exact current-set candidates must be reported as ambiguous'
Assert-Equal $duplicateResult.ambiguous[0].reason 'MULTIPLE_EQUAL_CONFIDENCE' 'Duplicate ambiguity reason changed'
Assert-Equal @($duplicateResult.ambiguous[0].candidateIds).Count 2 'Both duplicate candidate IDs must be preserved as evidence'

# Generic IDs can use exact localized names only when authoritative setData
# membership is supplied by the caller. This supports future sets without
# guessing from namespace prefixes.
$genericItem = @(
    [pscustomobject]@{
        apiName = 'TFT_Item_MageEmblem'
        name = '魔術師の紋章'
        associatedTraits = @()
        from = @()
        icon = 'generic-mage.png'
    }
)
$genericWithoutEvidence = Get-TftEmblemMappings -Traits @($traits[1]) -Items $genericItem -SetNumber 19
Assert-Equal @($genericWithoutEvidence.mappings).Count 0 'Generic name-only emblem must not map without current-set membership evidence'
$genericWithEvidence = Get-TftEmblemMappings -Traits @($traits[1]) -Items $genericItem -SetNumber 19 -AllowedItemIds @('TFT_Item_MageEmblem')
Assert-Equal @($genericWithEvidence.mappings).Count 1 'Declared generic current-set emblem should map by exact localized name'
Assert-Equal $genericWithEvidence.mappings[0].sourceConfidence 'EXACT_LOCALIZED_NAME_DECLARED_CURRENT_SET' 'Declared current-set provenance must be explicit'

# Regression from live Set18: historical records can reuse the same associated
# trait identity. Once the current SetNumber is known, a current-set record must
# beat the legacy record without relying on names or item ordering.
$invokerTrait = @([pscustomobject]@{ apiName = 'DA_18_Invoker'; name = 'インヴォーカー' })
$invokerItems = @(
    [pscustomobject]@{
        apiName = 'TFT16_Item_InvokerEmblemItem'
        name = 'インヴォーカーの紋章'
        associatedTraits = @('DA_18_Invoker')
        from = @()
        icon = 'legacy-invoker.png'
    },
    [pscustomobject]@{
        apiName = 'DA_18_EmblemInvoker'
        name = 'インヴォーカーの紋章'
        associatedTraits = @('DA_18_Invoker')
        from = @()
        icon = 'current-invoker.png'
    }
)
$invokerResult = Get-TftEmblemMappings -Traits $invokerTrait -Items $invokerItems -SetNumber 18 -AllowedItemIds @('DA_18_EmblemInvoker')
Assert-Equal @($invokerResult.ambiguous).Count 0 'Current-set identity should resolve legacy/current emblem collision'
Assert-Equal @($invokerResult.mappings).Count 1 'Invoker should have one canonical mapping'
Assert-Equal $invokerResult.mappings[0].emblemId 'DA_18_EmblemInvoker' 'Current Set18 emblem must beat TFT16 legacy alias'
Assert-True ([string]$invokerResult.mappings[0].sourceConfidence -like '*CURRENT_SET') 'Current-set provenance should be recorded'

# Regression from live Flora Fatalis: the normal canonical emblem and an
# Augment-suffixed variant coexist. The normal record is the encyclopedia item.
$floraTrait = @([pscustomobject]@{ apiName = 'DA_FloraFatalis18'; name = 'フローラ・ファターリス' })
$floraItems = @(
    [pscustomobject]@{
        apiName = 'DA_18_EmblemFloraFatalisAugment'
        name = 'フローラ・ファターリスの紋章'
        associatedTraits = @('DA_FloraFatalis18')
        from = @()
        icon = 'flora-augment.png'
    },
    [pscustomobject]@{
        apiName = 'DA_18_EmblemFloraFatalis'
        name = 'フローラ・ファターリスの紋章'
        associatedTraits = @('DA_FloraFatalis18')
        from = @()
        icon = 'flora.png'
    }
)
$floraResult = Get-TftEmblemMappings -Traits $floraTrait -Items $floraItems -SetNumber 18 -AllowedItemIds @('DA_18_EmblemFloraFatalisAugment','DA_18_EmblemFloraFatalis')
Assert-Equal @($floraResult.ambiguous).Count 0 'Normal emblem should resolve beside augment variant'
Assert-Equal @($floraResult.mappings).Count 1 'Flora should have one canonical mapping'
Assert-Equal $floraResult.mappings[0].emblemId 'DA_18_EmblemFloraFatalis' 'Normal Flora emblem must beat Augment variant'

# Fail closed when the source exposes only an Augment variant. A plausible name
# is not enough evidence to manufacture a canonical encyclopedia emblem.
$augmentOnlyResult = Get-TftEmblemMappings -Traits $floraTrait -Items @($floraItems[0]) -SetNumber 18 -AllowedItemIds @('DA_18_EmblemFloraFatalisAugment')
Assert-Equal @($augmentOnlyResult.mappings).Count 0 'Augment-only emblem must not be promoted as canonical'
Assert-Equal @($augmentOnlyResult.ambiguous).Count 1 'Augment-only emblem must remain explicitly unresolved'
Assert-Equal $augmentOnlyResult.ambiguous[0].reason 'AUGMENT_VARIANT_ONLY' 'Augment-only ambiguity reason changed'

Write-Output 'Trait-to-emblem mapping regression passed.'
