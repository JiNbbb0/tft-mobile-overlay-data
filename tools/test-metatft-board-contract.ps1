$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'metatft-board-contract.ps1')
$ids=@{ A=$true; B=$true; C=$true; D=$true }
$rows=@(
    [pscustomobject]@{ units_list='A&B'; traits_list='X_1'; avg=5.52; count=16000 },
    [pscustomobject]@{ units_list='A&B'; traits_list='X_2'; avg=5.10; count=2600 },
    [pscustomobject]@{ units_list='A&C'; traits_list='X_1'; avg=6.31; count=700 },
    [pscustomobject]@{ units_list='A&D'; traits_list='X_1'; avg=1.00; count=1 }
)
$result=@(Get-TftMetaBoardCandidates -Rows $rows -Kind FINAL -Level 7 -PlacementScale 0.95 -PlayableIds $ids)
if ($result.Count -ne 3 -or $result[0].rawAveragePlacement -ne 5.10 -or $result[0].sampleCount -ne 2600) { throw 'Source shortlist / best headline / count contract failed.' }
if ($result[0].averagePlacement -ne 4.845 -or $result[0].sourceVariantId -eq $result[1].sourceVariantId) { throw 'Scaling or trait-variant identity lost.' }
$early=@([pscustomobject]@{unit_list='A&B';avg=4;count=100;win=0.6},[pscustomobject]@{unit_list='A&C';avg=3;count=50;win=0.8})
$result=@(Get-TftMetaBoardCandidates -Rows $early -Kind EARLY -Level 4 -PlayableIds $ids)
if ($result[0].sampleCount -ne 100 -or $result[0].roundWinRate -ne 0.6) { throw 'Early boards must preserve popularity and round-win semantics.' }
$blocked=$false
try { Get-TftMetaBoardCandidates -Rows @([pscustomobject]@{units_list='A&UNKNOWN';avg=3;count=20}) -Kind FINAL -Level 7 -PlayableIds $ids | Out-Null } catch { $blocked=$true }
if (-not $blocked) { throw 'Unresolved champion did not fail closed.' }
$lookup=@([pscustomobject]@{apiName='HELPER';assetNames=@('HELPER_ALIAS');shopUnit=$false;cost=0;traits=@()})
$universe=New-TftMetaBoardIdentityUniverse -CanonicalChampionIds $ids -Aliases @{} -LookupUnits $lookup
$result=@(Get-TftMetaBoardCandidates -Rows @([pscustomobject]@{units_list='A&HELPER_ALIAS';avg=3.2;count=20}) -Kind FINAL -Level 7 -PlayableIds $universe.playable -IgnoredIds $universe.ignored)
if ($result[0].unitIds.Count -ne 1 -or $result[0].unitIds[0] -ne 'A') { throw 'Source-declared helper was shown as a champion.' }
$lookup[0].shopUnit=$true
$universe=New-TftMetaBoardIdentityUniverse -CanonicalChampionIds $ids -Aliases @{} -LookupUnits $lookup
if ($universe.ignored.Count) { throw 'Unknown shop entity was silently treated as a helper.' }
$result=@(Get-TftMetaBoardCandidates -Rows @([pscustomobject]@{unit_list='A&B&C&D';avg=3.2;count=20;win=0.6}) -Kind EARLY -Level 3 -PlayableIds $ids)
if ($result[0].unitIds.Count -ne 4) { throw 'Source-backed extra team slot was truncated.' }
Write-Output 'MetaTFT board shortlist / scaling / early-board / identity contract PASS'
