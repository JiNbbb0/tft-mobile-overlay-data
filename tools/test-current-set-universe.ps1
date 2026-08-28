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
    # Explicit current-set DA identities must survive even when CommunityDragon
    # omits them from setData.items. This mirrors Set18 augment-granted emblems.
    [pscustomobject]@{ apiName='DA_19_EmblemSpecial'; name='特殊な紋章'; from=@() },
    # Explicit current-set IDs can also identify non-item records such as augments.
    # Catalog callers must be able to exclude those without disabling DA discovery.
    [pscustomobject]@{ apiName='DA_19_SpecialAugment'; name='特殊オーグメント'; from=@() },
    # A non-shared DA item from another set must not leak into the current set.
    [pscustomobject]@{ apiName='DA_18_MechanicConsumable'; name='旧セット専用消耗品'; from=@() }
)

$result = Get-TftCurrentSetUniverse `
    -SetNumber 19 `
    -SetData $setData `
    -AllItems $items `
    -ExcludedItemIds @('DA_19_SpecialAugment')
Assert-Contains $result.itemIds 'TFT_Item_Deathblade' 'Global completed item should stay'
Assert-Contains $result.itemIds 'TFT_Item_BFSword' 'Recipe component should be reachable'
Assert-Contains $result.itemIds 'TFT19_Item_ForestEmblem' 'Current-set item should stay'
Assert-Contains $result.itemIds 'TFT9_Item_OrnnDeathfireGrasp' 'Shared artifact family must survive old numeric prefix'
Assert-Contains $result.itemIds 'DA_19_EmblemSpecial' 'Explicit current-set DA item should be discovered even when absent from setData.items'
Assert-NotContains $result.itemIds 'DA_19_SpecialAugment' 'Explicit exclusions must keep augment-like IDs out of the item universe'
Assert-Contains $result.explicitExclusions 'DA_19_SpecialAugment' 'Explicit exclusions should be reported for auditability'
Assert-NotContains $result.itemIds 'DA_18_MechanicConsumable' 'Other-set DA item must not leak into current set'
Assert-NotContains $result.itemIds 'TFT7_Item_ShimmerscaleMogulsMail' 'Unreachable other-set mechanic item must be excluded'
Assert-NotContains $result.itemIds 'TFT_Assist_1x2star5cost' 'Internal assist item must be excluded'

Write-Output 'Current-set item universe regression passed.'
