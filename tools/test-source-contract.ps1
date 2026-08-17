$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'source-contract.ps1')

function Expect-Throws([scriptblock]$Action, [string]$Message) {
    try { & $Action; throw "Expected failure was not raised: $Message" } catch {
        if ($_.Exception.Message -eq "Expected failure was not raised: $Message") { throw }
    }
}

$preferred = [pscustomobject]@{
    results = @()
    tft_set = 'TFTSet18'
    cluster_id = 501
    filter_adjustment = $null
}
Assert-MetaTftStatsContract -Stats $preferred -ExpectedSetId 'TFTSet18' -ExpectedClusterId 501 `
    -ExpectedRankFilter '' -Context 'preferred fixture'

$fallback = [pscustomobject]@{
    results = @([pscustomobject]@{ cluster = '501001'; places = @(1,1,1,1,1,1,1,1,8) })
    tft_set = 'TFTSet18'
    cluster_id = 501
    filter_adjustment = $null
}
Assert-MetaTftStatsContract -Stats $fallback -ExpectedSetId 'TFTSet18' -ExpectedClusterId 501 `
    -ExpectedRankFilter '' -Context 'all-rank fixture'

$implicitOverride = [pscustomobject]@{
    results = @()
    tft_set = 'TFTSet18'
    cluster_id = 501
    filter_adjustment = [pscustomobject]@{ override_applied = $true; rank_filter = 'ALL' }
}
Expect-Throws { Assert-MetaTftStatsContract -Stats $implicitOverride -ExpectedSetId 'TFTSet18' `
    -ExpectedClusterId 501 -ExpectedRankFilter 'PLATINUM' -Context 'override fixture' } 'implicit adjustment'

$mixedCluster = [pscustomobject]@{ results=@(); tft_set='TFTSet17'; cluster_id=409; filter_adjustment=$null }
Expect-Throws { Assert-MetaTftStatsContract -Stats $mixedCluster -ExpectedSetId 'TFTSet18' `
    -ExpectedClusterId 501 -ExpectedRankFilter '' -Context 'mixed fixture' } 'mixed cluster'

$unrelatedBlock = @"
User-agent: Googlebot
Disallow: /
User-agent: *
Disallow: /private/
"@
if (Test-RobotsSiteWideBlock -RobotsText $unrelatedBlock -UserAgent '*') {
    throw 'An unrelated or partial robots rule was treated as a site-wide block.'
}
$globalBlock = "User-agent: *`nDisallow: /"
if (-not (Test-RobotsSiteWideBlock -RobotsText $globalBlock -UserAgent '*')) {
    throw 'A site-wide robots rule was not detected.'
}

Write-Output 'MetaTFT source contract fixtures passed.'
