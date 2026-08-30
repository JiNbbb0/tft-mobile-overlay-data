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
# available for source records that do not expose associatedTraits.
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

$result = Get-TftEmblemMappings -Traits $traits -Items $items -SetNumber 19
Assert-Equal @($result.mappings).Count 2 'Expected two real trait emblems'
Assert-Equal @($result.ambiguous).Count 0 'Synthetic fixture should have no ambiguous mappings'
$forest = @($result.mappings | Where-Object traitId -eq 'TFT19_Forest')[0]
Assert-Equal $forest.emblemId 'TFT19_Item_ForestEmblem' 'Associated-trait mapping failed'
Assert-Equal $forest.craftable $true 'Two-component emblem should be craftable'
$mage = @($result.mappings | Where-Object traitId -eq 'TFT19_Mage')[0]
Assert-True ([string]$mage.sourceConfidence -like 'LOCALIZED_NAME*') 'Localized-name fallback failed'
if (@($result.mappings.emblemId) -contains 'DA_PhantomEmblem19') { throw 'Temporary phantom emblem must not satisfy a trait mapping.' }
if (@($result.mappedTraitIds) -contains 'TFT19_NoEmblem') { throw 'Traits without an emblem must remain unmapped.' }

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
$invokerResult = Get-TftEmblemMappings -Traits $invokerTrait -Items $invokerItems -SetNumber 18
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
$floraResult = Get-TftEmblemMappings -Traits $floraTrait -Items $floraItems -SetNumber 18
Assert-Equal @($floraResult.ambiguous).Count 0 'Normal emblem should resolve beside augment variant'
Assert-Equal @($floraResult.mappings).Count 1 'Flora should have one canonical mapping'
Assert-Equal $floraResult.mappings[0].emblemId 'DA_18_EmblemFloraFatalis' 'Normal Flora emblem must beat Augment variant'

# Fail closed when the source exposes only an Augment variant. A plausible name
# is not enough evidence to manufacture a canonical encyclopedia emblem.
$augmentOnlyResult = Get-TftEmblemMappings -Traits $floraTrait -Items @($floraItems[0]) -SetNumber 18
Assert-Equal @($augmentOnlyResult.mappings).Count 0 'Augment-only emblem must not be promoted as canonical'
Assert-Equal @($augmentOnlyResult.ambiguous).Count 1 'Augment-only emblem must remain explicitly unresolved'
Assert-Equal $augmentOnlyResult.ambiguous[0].reason 'AUGMENT_VARIANT_ONLY' 'Augment-only ambiguity reason changed'

Write-Output 'Trait-to-emblem mapping regression passed.'
