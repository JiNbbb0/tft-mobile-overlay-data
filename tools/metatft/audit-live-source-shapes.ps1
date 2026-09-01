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
function Get-FirstItem($Value) {
    $items = @($Value)
    if ($items.Count -eq 0) { return $null }
    return $items[0]
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
$sampleOption = if ($optionProperty) { Get-FirstItem $optionProperty.Value.options } else { $null }
$sampleBuild = if ($buildProperty) { Get-FirstItem $buildProperty.Value.builds } else { $null }
$sampleDetailAugment = if ($details.PSObject.Properties['augments']) { Get-FirstItem $details.augments } else { $null }
$sampleDetailBuild = if ($details.PSObject.Properties['builds']) { Get-FirstItem $details.builds } else { $null }
$sampleDetailItem = if ($details.PSObject.Properties['items']) { Get-FirstItem $details.items } else { $null }
$sampleDetailReroll = if ($details.PSObject.Properties['rerolls']) { Get-FirstItem $details.rerolls } else { $null }
$earlyLevel4Property = if ($details.PSObject.Properties['early_options']) { $details.early_options.PSObject.Properties['4'] } else { $null }
$lateLevel8Property = if ($details.PSObject.Properties['options']) { $details.options.PSObject.Properties['8'] } else { $null }
$sampleEarlyLevel4 = if ($earlyLevel4Property) { Get-FirstItem $earlyLevel4Property.Value } else { $null }
$sampleLateLevel8 = if ($lateLevel8Property) { Get-FirstItem $lateLevel8Property.Value } else { $null }
$positionUnitProperty = if ($details.PSObject.Properties['positioning'] -and $details.positioning.PSObject.Properties['units']) {
    Get-FirstItem $details.positioning.units.PSObject.Properties
} else { $null }
$samplePositionUnitValue = if ($positionUnitProperty) { $positionUnitProperty.Value } else { $null }
$samplePositionRow = if ($samplePositionUnitValue -and $samplePositionUnitValue.PSObject.Properties['positions']) {
    Get-FirstItem $samplePositionUnitValue.positions
} else { $null }

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
        compOptionsSample = Get-PropertyNames $sampleOption
        compBuilds = Get-PropertyNames $compBuilds
        compBuildsSample = Get-PropertyNames $sampleBuild
        compDetails = Get-PropertyNames $details
        compDetailsAugmentSample = Get-PropertyNames $sampleDetailAugment
        compDetailsBuildSample = Get-PropertyNames $sampleDetailBuild
        compDetailsItemSample = Get-PropertyNames $sampleDetailItem
        compDetailsRerollSample = Get-PropertyNames $sampleDetailReroll
        compDetailsPositioning = if ($details.PSObject.Properties['positioning']) { Get-PropertyNames $details.positioning } else { @() }
        compDetailsPositionUnitSample = Get-PropertyNames $samplePositionUnitValue
        compDetailsPositionRowSample = Get-PropertyNames $samplePositionRow
        compDetailsEarlyOptions = if ($details.PSObject.Properties['early_options']) { Get-PropertyNames $details.early_options } else { @() }
        compDetailsEarlyLevel4Sample = Get-PropertyNames $sampleEarlyLevel4
        compDetailsOptions = if ($details.PSObject.Properties['options']) { Get-PropertyNames $details.options } else { @() }
        compDetailsLevel8Sample = Get-PropertyNames $sampleLateLevel8
        clusterDetail = Get-PropertyNames $sampleCluster
        clusterBuild = if (@($sampleCluster.builds).Count -gt 0) { Get-PropertyNames @($sampleCluster.builds)[0] } else { @() }
    }
    counts = [ordered]@{
        clusterDetails = $clusterIds.Count
        platinumStatsRows = @($compsStats.results).Count
        sampleOverviewBuilds = @($sampleCluster.builds).Count
        sampleCompOptions = if ($optionProperty) { @($optionProperty.Value.options).Count } else { 0 }
        sampleCompBuilds = if ($buildProperty) { @($buildProperty.Value.builds).Count } else { 0 }
        sampleDetailAugments = if ($details.PSObject.Properties['augments']) { @($details.augments).Count } else { 0 }
        sampleDetailBuilds = if ($details.PSObject.Properties['builds']) { @($details.builds).Count } else { 0 }
        sampleDetailItems = if ($details.PSObject.Properties['items']) { @($details.items).Count } else { 0 }
        sampleDetailRerolls = if ($details.PSObject.Properties['rerolls']) { @($details.rerolls).Count } else { 0 }
        sampleEarlyLevel4 = if ($earlyLevel4Property) { @($earlyLevel4Property.Value).Count } else { 0 }
        sampleLevel8 = if ($lateLevel8Property) { @($lateLevel8Property.Value).Count } else { 0 }
        samplePositionUnits = if ($details.PSObject.Properties['positioning'] -and $details.positioning.PSObject.Properties['units']) { @($details.positioning.units.PSObject.Properties).Count } else { 0 }
    }
}

$outFile = Join-Path $outRoot 'source-shapes.json'
[IO.File]::WriteAllText($outFile, (($summary | ConvertTo-Json -Depth 12).Replace("`r`n","`n") + "`n"), [Text.UTF8Encoding]::new($false))
Write-Output ($summary | ConvertTo-Json -Depth 12)
