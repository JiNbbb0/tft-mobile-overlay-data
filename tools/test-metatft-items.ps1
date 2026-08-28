$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'metatft/Convert-MetaTftItems.ps1')

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ([string]$Actual -ne [string]$Expected) { throw "$Message. Expected=$Expected Actual=$Actual" }
}

$overview = @(
    [pscustomobject]@{ unit='Carry'; num_items=3; buildName=@('ItemC','ItemB','ItemA') },
    [pscustomobject]@{ unit='Other'; num_items=3; buildName=@('Other1','Other2','Other3') }
)
$builds = @(
    [pscustomobject]@{ unit='Carry'; num_items=3; count=1000; avg=4.8; buildName=@('ItemA','ItemD','ItemE') },
    [pscustomobject]@{ unit='Carry'; num_items=3; count=100; avg=2.1; buildName=@('ItemB','ItemF','ItemG') },
    [pscustomobject]@{ unit='Carry'; num_items=3; count=50; avg=1.9; buildName=@('ItemC','ItemH','ItemI') }
)

$result = Convert-MetaTftUnitItemData -UnitId 'Carry' -OverviewBuilds $overview -CompBuildRows $builds
Assert-Equal @($result.recommended).Count 1 'Only the carry overview build should be source-recommended'
Assert-Equal ($result.recommended[0].itemIds -join ',') 'ItemC,ItemB,ItemA' 'Source-recommended build order must be preserved exactly'
Assert-Equal $result.recommended[0].sourceSemantics 'OVERVIEW_BUILD' 'Recommendation provenance must be explicit'

# The best derived average-placement item is not allowed to rewrite source recommendation order.
$bestCorrelation = [string]$result.averagePlacementCorrelations[0].itemId
if ($bestCorrelation -eq [string]$result.recommended[0].itemIds[0]) {
    throw 'Synthetic fixture failed to create a ranking disagreement; regression would be meaningless.'
}
Assert-Equal ($result.recommended[0].itemIds -join ',') 'ItemC,ItemB,ItemA' 'Derived correlations must never reorder source recommendations'
if (@($result.averagePlacementCorrelations | Where-Object isRecommendation -eq $true).Count -gt 0) {
    throw 'Derived average-placement correlations must never be mislabeled as recommendations.'
}

Write-Output 'MetaTFT item semantic separation regression passed.'
