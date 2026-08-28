param(
    [string]$OutputDirectory = 'build/metatft-source-audit'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\source-contract.ps1')

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$outRoot = if ([IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory } else { Join-Path $repoRoot $OutputDirectory }
New-Item -ItemType Directory -Force -Path $outRoot | Out-Null
$ua = 'TFT-Mobile-Overlay-Data/1.0 canonical-v2-source-audit'

function Get-PublicText([string]$Url) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $lines = & curl.exe -L --fail --silent --show-error --max-time 90 -A $ua $Url
        if ($LASTEXITCODE -eq 0) { return ($lines -join "`n") }
        if ($attempt -lt 3) { Start-Sleep -Seconds (2 * $attempt) }
    }
    throw "Public source request failed: $Url"
}
function Get-PublicJson([string]$Url) {
    $text = Get-PublicText -Url $Url
    try { return $text | ConvertFrom-Json } catch { throw "Invalid JSON from $Url" }
}
function Get-PropertyNames($Value) {
    if ($null -eq $Value) { return @() }
    return @($Value.PSObject.Properties.Name | Sort-Object)
}

$robots = Get-PublicText -Url 'https://www.metatft.com/robots.txt'
if (Test-RobotsSiteWideBlock -RobotsText $robots -UserAgent '*') {
    throw 'MetaTFT robots.txt contains a site-wide block; live audit aborted.'
}

$clusterResponse = Get-PublicJson -Url 'https://api-hc.metatft.com/tft-comps-api/latest_cluster_info'
$cluster = $clusterResponse.cluster_info
if (-not $cluster -or -not $cluster.cluster_id -or -not $cluster.tft_set) { throw 'latest_cluster_info shape changed.' }
$clusterId = [int]$cluster.cluster_id
$rank = 'CHALLENGER,DIAMOND,EMERALD,GRANDMASTER,MASTER,PLATINUM'

Start-Sleep -Milliseconds 350
$compsData = Get-PublicJson -Url 'https://api-hc.metatft.com/tft-comps-api/comps_data'
Start-Sleep -Milliseconds 350
$compsStats = Get-PublicJson -Url "https://api-hc.metatft.com/tft-comps-api/comps_stats?queue=1100&patch=current&days=3&rank=$rank&permit_filter_adjustment=false"
Start-Sleep -Milliseconds 350
$compOptions = Get-PublicJson -Url "https://api-hc.metatft.com/tft-comps-api/comp_options?cluster_id=$clusterId"
Start-Sleep -Milliseconds 350
$compBuilds = Get-PublicJson -Url "https://api-hc.metatft.com/tft-comps-api/comp_builds?cluster_id=$clusterId"

$data = $compsData.results.data
if ([string]$data.tft_set -ne [string]$cluster.tft_set -or [int]$data.cluster_id -ne $clusterId) {
    throw 'SOURCE_SET_MISMATCH comps_data differs from latest_cluster_info.'
}
if (-not $data.cluster_details) { throw 'comps_data is missing cluster_details.' }
if (-not $compsStats.PSObject.Properties['results']) { throw 'comps_stats is missing results.' }

$clusterIds = @($data.cluster_details.PSObject.Properties.Name)
$sampleClusterId = @($compsStats.results | ForEach-Object { [string]$_.cluster } | Where-Object { $_ -and $_ -ne '-1' -and $_ -in $clusterIds } | Select-Object -First 1)
if ($sampleClusterId.Count -eq 0) { throw 'No shared composition id exists between comps_data and Platinum+ comps_stats.' }
$sampleId = [string]$sampleClusterId[0]
$sampleCluster = $data.cluster_details.PSObject.Properties[$sampleId].Value

Start-Sleep -Milliseconds 350
$detailsResponse = Get-PublicJson -Url "https://api-hc.metatft.com/tft-comps-api/comp_details?comp=$sampleId&cluster_id=$clusterId"
$details = $detailsResponse.results
if (-not $details) { throw 'Sample comp_details is missing results.' }

$optionProperty = $compOptions.results.PSObject.Properties[$sampleId]
$buildProperty = $compBuilds.results.PSObject.Properties[$sampleId]
$sampleOption = if ($optionProperty) { @($optionProperty.Value.options | Select-Object -First 1) } else { @() }
$sampleBuild = if ($buildProperty) { @($buildProperty.Value.builds | Select-Object -First 1) } else { @() }

$summary = [pscustomobject][ordered]@{
    fetchedAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    tftSet = [string]$cluster.tft_set
    clusterId = $clusterId
    sampleCompositionId = $sampleId
    endpoints = [ordered]@{
        clusterInfo = Get-PropertyNames $clusterResponse
        clusterInfoValue = Get-PropertyNames $cluster
        compsData = Get-PropertyNames $compsData
        compsDataValue = Get-PropertyNames $data
        compsStats = Get-PropertyNames $compsStats
        compsStatsRow = if (@($compsStats.results).Count -gt 0) { Get-PropertyNames @($compsStats.results)[0] } else { @() }
        compOptions = Get-PropertyNames $compOptions
        compOptionsSample = if (@($sampleOption).Count -gt 0) { Get-PropertyNames @($sampleOption)[0] } else { @() }
        compBuilds = Get-PropertyNames $compBuilds
        compBuildsSample = if (@($sampleBuild).Count -gt 0) { Get-PropertyNames @($sampleBuild)[0] } else { @() }
        compDetails = Get-PropertyNames $details
        compDetailsPositioning = if ($details.PSObject.Properties['positioning']) { Get-PropertyNames $details.positioning } else { @() }
        compDetailsEarlyOptions = if ($details.PSObject.Properties['early_options']) { Get-PropertyNames $details.early_options } else { @() }
        compDetailsOptions = if ($details.PSObject.Properties['options']) { Get-PropertyNames $details.options } else { @() }
        clusterDetail = Get-PropertyNames $sampleCluster
        clusterBuild = if (@($sampleCluster.builds).Count -gt 0) { Get-PropertyNames @($sampleCluster.builds)[0] } else { @() }
    }
    counts = [ordered]@{
        clusterDetails = $clusterIds.Count
        platinumStatsRows = @($compsStats.results).Count
        sampleOverviewBuilds = @($sampleCluster.builds).Count
        sampleCompOptions = if ($optionProperty) { @($optionProperty.Value.options).Count } else { 0 }
        sampleCompBuilds = if ($buildProperty) { @($buildProperty.Value.builds).Count } else { 0 }
    }
}

$outFile = Join-Path $outRoot 'source-shapes.json'
[IO.File]::WriteAllText($outFile, (($summary | ConvertTo-Json -Depth 12).Replace("`r`n","`n") + "`n"), [Text.UTF8Encoding]::new($false))
Write-Output ($summary | ConvertTo-Json -Depth 12)
