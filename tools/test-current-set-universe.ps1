$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'normalize/Get-CurrentSetUniverse.ps1')

function Assert-Contains([object[]]$Values, [string]$Expected, [string]$Message) {
    if (-not (@($Values | ForEach-Object { [string]$_ }) -contains $Expected)) { throw "${Message}: $Expected" }
}
function Assert-NotContains([object[]]$Values, [string]$Unexpected, [string]$Message) {
    if (@($Values | ForEach-Object { [string]$_ }) -contains $Unexpected) { throw "${Message}: $Unexpected" }
}

$setData = [pscustomobject]@{
    items = @(
        'TFT_Item_Deathblade',
        'TFT19_Item_ForestEmblem',
        'TFT9_Item_OrnnDeathfireGrasp',
        'TFT7_Item_ShimmerscaleMogulsMail',
        'TFT_Assist_1x2star5cost'
    )
}
$items = @(
    [pscustomobject]@{ apiName='TFT_Item_Deathblade'; name='デスブレード'; from=@('TFT_Item_BFSword','TFT_Item_BFSword') },
    [pscustomobject]@{ apiName='TFT_Item_BFSword'; name='B.F.ソード'; from=@() },
    [pscustomobject]@{ apiName='TFT19_Item_ForestEmblem'; name='森の紋章'; from=@('TFT_Item_Spatula','TFT_Item_GiantsBelt') },
    [pscustomobject]@{ apiName='TFT_Item_Spatula'; name='へら'; from=@() },
    [pscustomobject]@{ apiName='TFT_Item_GiantsBelt'; name='ジャイアントベルト'; from=@() },
    [pscustomobject]@{ apiName='TFT9_Item_OrnnDeathfireGrasp'; name='デスファイア グラスプ'; from=@() },
    [pscustomobject]@{ apiName='TFT7_Item_ShimmerscaleMogulsMail'; name='モーグル メイル'; from=@() },
    [pscustomobject]@{ apiName='TFT_Assist_1x2star5cost'; name='★2のコスト5チャンピオン'; from=@() },
    [pscustomobject]@{ apiName='DA_19_EmblemSpecial'; name='特殊な紋章'; from=@() },
    [pscustomobject]@{ apiName='DA_19_UnvalidatedHelper'; name='未検証の補助レコード'; from=@() },
    [pscustomobject]@{ apiName='DA_19_SpecialAugment'; name='特殊オーグメント'; from=@() },
    [pscustomobject]@{ apiName='DA_18_MechanicConsumable'; name='旧セット専用消耗品'; from=@() }
)

$result = Get-TftCurrentSetUniverse `
    -SetNumber 19 `
    -SetData $setData `
    -AllItems $items `
    -AdditionalItemIds @('DA_19_EmblemSpecial', 'DA_19_SpecialAugment', 'DA_18_MechanicConsumable') `
    -ExcludedItemIds @('DA_19_SpecialAugment')
Assert-Contains $result.itemIds 'TFT_Item_Deathblade' 'Global completed item should stay'
Assert-Contains $result.itemIds 'TFT_Item_BFSword' 'Recipe component should be reachable'
Assert-Contains $result.itemIds 'TFT19_Item_ForestEmblem' 'Current-set item should stay'
Assert-Contains $result.itemIds 'TFT9_Item_OrnnDeathfireGrasp' 'Shared artifact family must survive old numeric prefix'
Assert-Contains $result.itemIds 'DA_19_EmblemSpecial' 'Validated supplemental current-set item should stay'
Assert-Contains $result.supplementalSeedIds 'DA_19_EmblemSpecial' 'Supplemental seed should be reported for auditability'
Assert-NotContains $result.itemIds 'DA_19_UnvalidatedHelper' 'Current-set namespaces must not be auto-seeded wholesale'
Assert-NotContains $result.itemIds 'DA_19_SpecialAugment' 'Explicit exclusions must keep augment-like IDs out of the item universe'
Assert-Contains $result.explicitExclusions 'DA_19_SpecialAugment' 'Explicit exclusions should be reported for auditability'
Assert-NotContains $result.itemIds 'DA_18_MechanicConsumable' 'Other-set supplemental item must still be rejected'
Assert-NotContains $result.itemIds 'TFT7_Item_ShimmerscaleMogulsMail' 'Unreachable other-set mechanic item must be excluded'
Assert-NotContains $result.itemIds 'TFT_Assist_1x2star5cost' 'Internal assist item must be excluded'

Write-Output 'Current-set item universe regression passed.'
