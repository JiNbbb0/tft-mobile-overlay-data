$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'composition-condition-contract.ps1')
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$items = @{
    emblem = [pscustomobject]@{name='紋章'; tags=@('Emblem')}
    normal = [pscustomobject]@{name='通常アイテム'; tags=@(); composition=@('TFT_Item_BFSword')}
    crown = [pscustomobject]@{name='王冠'; tags=@(); composition=@('TFT_Item_Spatula','TFT_Item_Spatula')}
}
$normal = [pscustomobject]@{name_string='Champion'; name=@(); top_itemNames=@([pscustomobject]@{itemNames='normal';pcnt=1.0})}
Assert (@(Get-CompositionSituationalRequirements $normal $items).Count -eq 0) 'Normal builds must not become conditional'
$atThreshold = [pscustomobject]@{name_string='Champion'; name=@(); top_itemNames=@([pscustomobject]@{itemNames='emblem';pcnt=0.5})}
$rows = @(Get-CompositionSituationalRequirements $atThreshold $items)
Assert ($rows.Count -eq 1 -and $rows[0].kind -eq 'EMBLEM' -and $rows[0].adoptionRate -eq 0.5) 'Exact source threshold failed'
$below = [pscustomobject]@{name_string='Champion';name=@();top_itemNames=@([pscustomobject]@{itemNames='emblem';pcnt=0.4999})}
Assert (@(Get-CompositionSituationalRequirements $below $items).Count -eq 0) 'Rare emblem must not imply a required emblem'
$unknown = [pscustomobject]@{name_string='Champion';name=@();top_itemNames=@([pscustomobject]@{itemNames='UnknownEmblemLikeName';pcnt=0.9})}
Assert (@(Get-CompositionSituationalRequirements $unknown $items).Count -eq 0) 'Unknown ID must not be guessed from its name'
$hero = [pscustomobject]@{name_string='HeroAugment';name=@([pscustomobject]@{name='exact'});top_itemNames=@()}
$rows = @(Get-CompositionSituationalRequirements $hero $items @{exact=[pscustomobject]@{name='専用オーグメント'}})
Assert ($rows.Count -eq 1 -and $rows[0].sourceId -eq 'exact') 'Hero augment source identity failed'
$marker = @(Get-CompositionSituationalRequirements $hero $items)
Assert ($marker.Count -eq 1 -and $marker[0].sourceId -eq 'METATFT_AUGMENT_MARKER') 'Missing identity must remain an explicit generic source marker'
$crown = [pscustomobject]@{name_string='Champion'; name=@(); top_itemNames=@([pscustomobject]@{itemNames='crown';pcnt=0.9})}
Assert (@(Get-CompositionSituationalRequirements $crown $items).Count -eq 0) 'Double-tool crowns must not become trait emblems'
$valid = [pscustomobject]@{conditionContract='METATFT_SITUATIONAL_V1';situationalRequirements=@([pscustomobject]@{kind='EMBLEM';sourceId='emblem';name='紋章';adoptionRate=0.5})}
Assert-CompositionSituationalContract ([pscustomobject]@{id='legacy'})
Assert-CompositionSituationalContract ([pscustomobject]@{conditionContract='METATFT_SITUATIONAL_V1';situationalRequirements=@()})
Assert-CompositionSituationalContract $valid
function Reject($Value) { try { Assert-CompositionSituationalContract $Value } catch { return }; throw 'Invalid published conditional metadata was accepted' }
Reject ([pscustomobject]@{conditionContract='UNKNOWN';situationalRequirements=$valid.situationalRequirements})
Reject ([pscustomobject]@{conditionContract='METATFT_SITUATIONAL_V1';situationalRequirements=@($valid.situationalRequirements[0],$valid.situationalRequirements[0])})
Reject ([pscustomobject]@{conditionContract='METATFT_SITUATIONAL_V1';situationalRequirements=@([pscustomobject]@{kind='EMBLEM';sourceId='emblem';name='紋章';adoptionRate=0.4})})
Write-Output 'PASS: situational composition contract (13 cases)'
