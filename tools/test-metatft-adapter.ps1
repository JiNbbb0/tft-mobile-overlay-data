$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'metatft/Convert-MetaTftSnapshot.ps1')

function New-Places([int[]]$Counts) {
    if ($Counts.Count -ne 8) { throw 'New-Places requires eight placement counts.' }
    return @($Counts + (@($Counts | Measure-Object -Sum).Sum))
}
function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ([string]$Actual -ne [string]$Expected) { throw "$Message. Expected=$Expected Actual=$Actual" }
}

$clusterInfo = [pscustomobject]@{ tft_set = 'TFTSet19'; cluster_id = 999 }
$compsData = [pscustomobject]@{
    results = [pscustomobject]@{
        data = [pscustomobject]@{
            tft_set = 'TFTSet19'
            cluster_id = 999
            cluster_details = [pscustomobject]@{
                A = [pscustomobject]@{ units_string='U1,U2'; name=@(); builds=@() }
                B = [pscustomobject]@{ units_string='U3,U4'; name=@(); builds=@() }
                C = [pscustomobject]@{ units_string='U5,U6'; name=@(); builds=@() }
            }
        }
    }
}
$compsStats = [pscustomobject]@{
    tft_set = 'TFTSet19'
    cluster_id = 999
    results = @(
        [pscustomobject]@{ cluster='B'; places=(New-Places @(10,10,10,10,10,10,10,30)) },
        [pscustomobject]@{ cluster='C'; places=(New-Places @(30,20,15,10,10,5,5,5)) },
        [pscustomobject]@{ cluster='A'; places=(New-Places @(5,5,5,10,10,15,20,30)) }
    )
}
$filter = [pscustomobject]@{
    queue = '1100'
    patch = 'current'
    days = 3
    rank = 'CHALLENGER,DIAMOND,EMERALD,GRANDMASTER,MASTER,PLATINUM'
    permitFilterAdjustment = $false
}

$result = Convert-MetaTftCompositionSnapshot -ClusterInfo $clusterInfo -CompsData $compsData -CompsStats $compsStats -Filter $filter
Assert-Equal $result.filter.queue 'RANKED' 'Canonical queue label differs'
Assert-Equal $result.filter.rank 'PLATINUM_PLUS' 'Canonical rank label differs'
Assert-Equal $result.filter.windowDays 3 'Canonical time window differs'
Assert-Equal @($result.compositions).Count 3 'Adapter must preserve every qualifying Platinum+ composition'

$expected = @($compsStats.results | ForEach-Object {
    $placement = Get-MetaTftAveragePlacement -Places $_.places
    [pscustomobject]@{ id=[string]$_.cluster; avg=[double]$placement.averagePlacement; sourceIndex=[array]::IndexOf(@($compsStats.results), $_) }
} | Sort-Object avg, sourceIndex | ForEach-Object { $_.id })
$actual = @($result.compositions | ForEach-Object { [string]$_.id })
Assert-Equal ($actual -join ',') ($expected -join ',') 'Composition order must be average-placement ascending without a local cap'

$badFilter = [pscustomobject]@{ queue='1100'; patch='current'; days=3; rank=''; permitFilterAdjustment=$false }
$rejected = $false
try {
    $null = Convert-MetaTftCompositionSnapshot -ClusterInfo $clusterInfo -CompsData $compsData -CompsStats $compsStats -Filter $badFilter
} catch {
    $rejected = $_.Exception.Message -match 'METATFT_FILTER_MISMATCH'
}
if (-not $rejected) { throw 'All-rank/blank-rank fallback must fail the Platinum+ contract.' }

# No augment response is supplied anywhere in this test. Composition inclusion
# therefore cannot accidentally depend on optional augment readiness.
Write-Output 'MetaTFT Platinum+ composition adapter regression passed.'
