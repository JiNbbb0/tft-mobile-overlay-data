$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'normalize/Get-EmblemMappings.ps1')

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ([string]$Actual -ne [string]$Expected) { throw "$Message. Expected=$Expected Actual=$Actual" }
}

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

$result = Get-TftEmblemMappings -Traits $traits -Items $items
Assert-Equal @($result.mappings).Count 2 'Expected two real trait emblems'
Assert-Equal @($result.ambiguous).Count 0 'Synthetic fixture should have no ambiguous mappings'
$forest = @($result.mappings | Where-Object traitId -eq 'TFT19_Forest')[0]
Assert-Equal $forest.emblemId 'TFT19_Item_ForestEmblem' 'Associated-trait mapping failed'
Assert-Equal $forest.craftable $true 'Two-component emblem should be craftable'
$mage = @($result.mappings | Where-Object traitId -eq 'TFT19_Mage')[0]
Assert-Equal $mage.sourceConfidence 'LOCALIZED_NAME' 'Localized-name fallback failed'
if (@($result.mappings.emblemId) -contains 'DA_PhantomEmblem19') { throw 'Temporary phantom emblem must not satisfy a trait mapping.' }
if (@($result.mappedTraitIds) -contains 'TFT19_NoEmblem') { throw 'Traits without an emblem must remain unmapped.' }

Write-Output 'Trait-to-emblem mapping regression passed.'
