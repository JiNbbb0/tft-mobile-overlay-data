$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'normalize/Get-CurrentSetUniverse.ps1')

function Assert-Contains([object[]]$Values, [string]$Expected, [string]$Message) {
    if (-not (@($Values | ForEach-Object { [string]$_ }) -contains $Expected)) { throw "$Message: $Expected" }
}
function Assert-NotContains([object[]]$Values, [string]$Unexpected, [string]$Message) {
    if (@($Values | ForEach-Object { [string]$_ }) -contains $Unexpected) { throw "$Message: $Unexpected" }
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
    [pscustomobject]@{ apiName='TFT_Assist_1x2star5cost'; name='★2のコスト5チャンピオン'; from=@() }
)

$result = Get-TftCurrentSetUniverse -SetNumber 19 -SetData $setData -AllItems $items
Assert-Contains $result.itemIds 'TFT_Item_Deathblade' 'Global completed item should stay'
Assert-Contains $result.itemIds 'TFT_Item_BFSword' 'Recipe component should be reachable'
Assert-Contains $result.itemIds 'TFT19_Item_ForestEmblem' 'Current-set item should stay'
Assert-Contains $result.itemIds 'TFT9_Item_OrnnDeathfireGrasp' 'Shared artifact family must survive old numeric prefix'
Assert-NotContains $result.itemIds 'TFT7_Item_ShimmerscaleMogulsMail' 'Unreachable other-set mechanic item must be excluded'
Assert-NotContains $result.itemIds 'TFT_Assist_1x2star5cost' 'Internal assist item must be excluded'

Write-Output 'Current-set item universe regression passed.'
