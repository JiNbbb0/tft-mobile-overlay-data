$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'team-planner-contract.ps1')
function Check($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Reject([scriptblock]$Action) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Check $rejected 'Invalid planner source was accepted'
}
$doc = [pscustomobject]@{ TFTSet18 = @(
    [pscustomobject]@{character_id='ExactA';team_planner_code=1043},
    [pscustomobject]@{character_id='ExactB';team_planner_code=1065},
    [pscustomobject]@{character_id='ExactA_variant';team_planner_code=999}
) }
$index = New-TftTeamPlannerIndex -Document $doc -SetId TFTSet18 -ChampionIds @('ExactA','ExactB')
$code = Get-TftTeamPlannerCode -SetId TFTSet18 -UnitIds @('ExactA','ExactB','ExactA') -Index $index
Check ($code -ceq ('02413429413' + ('000' * 7) + 'TFTSet18')) 'Riot v2 golden code differs'
Check ($index.Count -eq 2) 'Non-catalog helper entered planner mapping'
Check ((Get-TftTeamPlannerCode -SetId TFTSet18 -UnitIds @('ExactA_variant') -Index $index) -ceq '') 'Guessed ID alias accepted'
Check ((Get-TftTeamPlannerCode -SetId TFTSet18 -UnitIds (@('ExactA') * 11) -Index $index) -ceq '') 'Over-sized board exported'
Reject { New-TftTeamPlannerIndex -Document $doc -SetId TFTSet19 -ChampionIds @('ExactA') }
$ambiguous = [pscustomobject]@{TFTSet18=@($doc.TFTSet18[0], [pscustomobject]@{character_id='ExactA';team_planner_code=2})}
Reject { New-TftTeamPlannerIndex -Document $ambiguous -SetId TFTSet18 -ChampionIds @('ExactA') }
$bad = [pscustomobject]@{TFTSet18=@([pscustomobject]@{character_id='ExactA';team_planner_code=4096})}
Reject { New-TftTeamPlannerIndex -Document $bad -SetId TFTSet18 -ChampionIds @('ExactA') }
$snapshot = [pscustomobject]@{setId='TFTSet18';compositions=@([pscustomobject]@{teamPlannerCode=$code;finalBoard=@{units=@(1,2,3)}})}
Assert-TftTeamPlannerCodes $snapshot
$snapshot.setId = 'TFTSet19'
Reject { Assert-TftTeamPlannerCodes $snapshot }
Assert-TftTeamPlannerCodes ([pscustomobject]@{setId='TFTSet19';compositions=@()})
Assert-TftTeamPlannerCodes ([pscustomobject]@{setId='TFTSet19';compositions=$null})
Write-Output 'Team planner contract PASS: golden/duplicates, exact IDs, missing set/IDs, ambiguity, overflow, validation.'
