$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'wisp-strength-contract.ps1')
$definition=[pscustomobject]@{setId='TFTSet23';patch='23.1';patchPublishedAt='2020-01-01T00:00:00Z';disabledWispIds=@('disabled')}
$set=[pscustomobject]@{mutator='TFTSet23';items=@('one','disabled')}
$names=@{one=[pscustomobject]@{name='確認済みウィスプ'};disabled=[pscustomobject]@{name='現在停止'}}
$ratings=[pscustomobject]@{content=[pscustomobject]@{updated_at='2020-02-01T00:00:00Z';content=[pscustomobject]@{
    tierListType='Wisps';tierList=@([pscustomobject]@{label='S';content=@([pscustomobject]@{id='one';type='wisp'},[pscustomobject]@{id='disabled';type='wisp'})})}}}
function Reject([scriptblock]$Action){$failed=$false;try{&$Action}catch{$failed=$true};if(-not $failed){throw 'Invalid editorial data accepted'}}
$table=ConvertTo-CheckedWispStrengthTable $definition $ratings $set $names 'TFTSet23' '23.1'
Assert-ReferenceTables @($table) 'TFTSet23' '23.1'
if($table.rows.Count -ne 1 -or $table.rows[0].cells[0] -cne 'S' -or $table.rows[0].cells[1] -cne '確認済みウィスプ'){throw 'Ratings, names or disabled filtering incorrect'}
Reject {ConvertTo-CheckedWispStrengthTable $definition $ratings $set $names 'TFTSet24' '24.1'}
$ratings.content.updated_at='2019-01-01T00:00:00Z'
Reject {ConvertTo-CheckedWispStrengthTable $definition $ratings $set $names 'TFTSet23' '23.1'}
$ratings.content.updated_at='2020-02-01T00:00:00Z';$ratings.content.content.tierListType='Augments'
Reject {ConvertTo-CheckedWispStrengthTable $definition $ratings $set $names 'TFTSet23' '23.1'}
$ratings.content.content.tierListType='Wisps';$ratings.content.content.tierList[0].content[0].id='other_set'
Reject {ConvertTo-CheckedWispStrengthTable $definition $ratings $set $names 'TFTSet23' '23.1'}
$ratings.content.content.tierList[0].content[0].id='one';$ratings.content.content.tierList[0].content[1].id='one'
Reject {ConvertTo-CheckedWispStrengthTable $definition $ratings $set $names 'TFTSet23' '23.1'}
Write-Output 'Wisp strength contract PASS: exact membership, timestamp, type, duplicate and disabled gates; future set fixture'
