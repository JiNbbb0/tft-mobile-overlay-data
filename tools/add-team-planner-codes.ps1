param([Parameter(Mandatory)][string]$SnapshotPath, [Parameter(Mandatory)][string]$CatalogPath,
    [Parameter(Mandatory)][string]$PlannerSourcePath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'team-planner-contract.ps1')
$catalog = Get-Content -Raw -LiteralPath $CatalogPath | ConvertFrom-Json
$snapshot = Get-Content -Raw -LiteralPath $SnapshotPath | ConvertFrom-Json
if ($snapshot.setId -cne $catalog.set.id) { throw 'Planner snapshot/catalog set mismatch' }
$index = New-TftTeamPlannerIndex -Document (Get-Content -Raw -LiteralPath $PlannerSourcePath | ConvertFrom-Json) `
    -SetId $snapshot.setId -ChampionIds @($catalog.champions.id)
$snapshots = @($snapshot)
if ($snapshot.PSObject.Properties['compositionRanks']) { $snapshots += @($snapshot.compositionRanks.datasets.snapshot) }
$available = 0; $total = 0
foreach ($data in $snapshots) {
    if ($data.setId -cne $snapshot.setId) { throw 'Planner rank dataset set mismatch' }
    foreach ($comp in @($data.compositions)) {
        $code = Get-TftTeamPlannerCode -SetId $data.setId -UnitIds @($comp.finalBoard.units.id) -Index $index
        $comp | Add-Member -Force -NotePropertyName teamPlannerCode -NotePropertyValue $code
        $total++; if ($code) { $available++ }
    }
    Assert-TftTeamPlannerCodes $data
}
# Reproducible local asset/fixture generation. Production uses the same contract
# with its batch-cached, recorded source response in refresh-static-meta.ps1.
[IO.File]::WriteAllText([IO.Path]::GetFullPath($SnapshotPath),
    (($snapshot | ConvertTo-Json -Depth 50 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
Write-Output "Planner codes generated: $available/$total compositions, $($index.Count) exact champion mappings."
