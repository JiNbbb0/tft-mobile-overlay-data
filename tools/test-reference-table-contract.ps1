$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'reference-table-contract.ps1')
. (Join-Path $PSScriptRoot 'optional-reference-tables.ps1')
$root = Split-Path -Parent $PSScriptRoot
$definition = Get-Content -Raw (Join-Path $root 'config/reference-tables/TFTSet18-18.3.json') | ConvertFrom-Json
$items = @{'DA_SoloLeveling'=[pscustomobject]@{name='単独レベルアップ'}}
$fixture = foreach ($row in $definition.rows) {
    $items[[string]$row.id] = [pscustomobject]@{name=[string]$row.nameJa}
    $override = $definition.conditionOverrides.PSObject.Properties[[string]$row.id]
    [pscustomobject]@{ApiName=$row.id; Cost=$row.cost; Description=$row.description; Standard='Yes';
        'Round Bands'=$row.bands; 'Special Conditions'=$row.condition;
        'Re-offer Cooldown'=$(if ($override) {$override.Value.cooldown} else {$definition.defaultCooldown});
        MutuallyExclusiveItem1=$(if ($override) {$override.Value.excludedAugmentIds[0]} else {''})}
}
$csv = $fixture | ConvertTo-Csv | Out-String
$page = 'TFT Wisp offer rules (18.3)'
function MustReject([scriptblock]$Action) {
    $rejected=$false
    try { & $Action } catch { $rejected=$true }
    if (-not $rejected) { throw 'Invalid reference data accepted' }
}
$table = ConvertTo-CheckedWispTable $definition $page $csv $items 'TFTSet18' '18.3'
Assert-ReferenceTables @($table) 'TFTSet18' '18.3'
if ($table.rows.Count -ne 8 -or $table.columns.Count -ne 8 -or $table.rows[0].cells[6] -ne '単独レベルアップ') { throw 'Complete conditions or variant rows lost' }
MustReject { ConvertTo-CheckedWispTable $definition $page $csv $items 'TFTSet19' '19.1' }
MustReject { ConvertTo-CheckedWispTable $definition 'TFT Wisp offer rules (18.2)' $csv $items 'TFTSet18' '18.3' }
$changed = $fixture | ConvertTo-Json -Depth 5 | ConvertFrom-Json
$changed[0].Cost='3'
MustReject { ConvertTo-CheckedWispTable $definition $page ($changed|ConvertTo-Csv|Out-String) $items 'TFTSet18' '18.3' }
$changed[0].Cost='4'; $changed[0].'Re-offer Cooldown'='5'
MustReject { ConvertTo-CheckedWispTable $definition $page ($changed|ConvertTo-Csv|Out-String) $items 'TFTSet18' '18.3' }
$changed[0].'Re-offer Cooldown'='20'; $changed[0].MutuallyExclusiveItem1=''
MustReject { ConvertTo-CheckedWispTable $definition $page ($changed|ConvertTo-Csv|Out-String) $items 'TFTSet18' '18.3' }
MustReject { ConvertTo-CheckedWispTable $definition $page (@($fixture)+@($fixture[0])|ConvertTo-Csv|Out-String) $items 'TFTSet18' '18.3' }
$absent=New-UnavailableReferenceTable 'wisp_tiers' 'ウィスプ評価' 'TFTSet18' '18.3' '評価元未確認'
Assert-ReferenceTables @($absent,$table) 'TFTSet18' '18.3'
MustReject { Assert-ReferenceTables @($table,$table) 'TFTSet18' '18.3' }
$bad=$table|ConvertTo-Json -Depth 10|ConvertFrom-Json
$bad.state='UNAVAILABLE'
MustReject { Assert-ReferenceTables @($bad) 'TFTSet18' '18.3' }
$bad.state='READY'; $bad.sourceUpdatedAt='yesterday'
MustReject { Assert-ReferenceTables @($bad) 'TFTSet18' '18.3' }
Assert-ReferenceTables @() 'TFTSet19' '19.1'
$future=@(Get-OptionalReferenceTables $root 'TFTSet19' '19.1' @{})
if ($future.Count -ne 0) { throw 'Future set borrowed old tables or old category names' }
function Get-OptionalReferenceText([string]$Url) { throw 'fixture timeout' }
$failed=@(Get-OptionalReferenceTables $root 'TFTSet18' '18.3' $items)
Assert-ReferenceTables $failed 'TFTSet18' '18.3'
if (@($failed|Where-Object state -ne 'UNAVAILABLE').Count) { throw 'Network failure leaked old references' }
Write-Output 'Reference table contract PASS: identity, content, conditions, future set, timeout; strength and facts independent'
