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
    [pscustomobject]@{ unit='Carry'; num_items=3; count=100; avg=1.8; buildName=@('ItemB','ItemF','ItemG') },
    [pscustomobject]@{ unit='Carry'; num_items=3; count=50; avg=5.2; buildName=@('ItemC','ItemH','ItemI') }
)

$result = Convert-MetaTftUnitItemData -UnitId 'Carry' -OverviewBuilds $overview -CompBuildRows $builds
Assert-Equal @($result.recommended).Count 1 'Only the carry overview build should be source-recommended'
Assert-Equal ($result.recommended[0].itemIds -join ',') 'ItemC,ItemB,ItemA' 'Source-recommended build order must be preserved exactly'
Assert-Equal $result.recommended[0].sourceSemantics 'OVERVIEW_BUILD' 'Recommendation provenance must be explicit'

# The best derived average-placement item is intentionally ItemB, while the
# source overview starts with ItemC. A regression must never replace one
# semantic with the other merely because the derived statistic looks better.
$bestCorrelation = [string]$result.averagePlacementCorrelations[0].itemId
Assert-Equal $bestCorrelation 'ItemB' 'Synthetic fixture must produce the intended derived ranking disagreement'
if ($bestCorrelation -eq [string]$result.recommended[0].itemIds[0]) {
    throw 'Derived correlation unexpectedly matches the source recommendation; regression is not exercising semantic separation.'
}
Assert-Equal ($result.recommended[0].itemIds -join ',') 'ItemC,ItemB,ItemA' 'Derived correlations must never reorder source recommendations'
if (@($result.averagePlacementCorrelations | Where-Object isRecommendation -eq $true).Count -gt 0) {
    throw 'Derived average-placement correlations must never be mislabeled as recommendations.'
}

Write-Output 'MetaTFT item semantic separation regression passed.'
