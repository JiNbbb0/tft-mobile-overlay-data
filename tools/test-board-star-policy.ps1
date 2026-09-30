$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'board-star-policy.ps1')

# Observed public response on 2026-10-01: comp 425049 / cluster 425.
# This is a regression fixture, not a set-specific production exception.
$observed = [pscustomobject]@{ unit_stats = @([pscustomobject]@{
    unit='DA_18_Camille'; tiers=@([pscustomobject]@{ tier=4; avg=1; count=14; pcnt=1 })
}) }
$target = (New-StarTargets -Details $observed -UnitMap @{ DA_18_Camille=[pscustomobject]@{cost=1} })['DA_18_Camille']
if ($target.level -ne 4 -or $target.rate -ne 1 -or -not (Test-TftBoardStarLevel 4 1)) { throw 'Source-backed four-star target was rejected or rounded.' }
foreach ($case in @(@(3,0.2,1,3), @(3,0.19,1,0), @(2,0.55,4,2), @(2,0.99,1,0), @(1,1,4,0), @(4,0.19,1,0))) {
    $result = Resolve-TftBoardStarTarget @([pscustomobject]@{tier=$case[0];pcnt=$case[1]}) $case[2]
    if ($result.level -ne $case[3] -or -not (Test-TftBoardStarLevel $result.level $case[2])) { throw 'Generation and validation star policy diverged.' }
}
foreach ($invalid in @(@(5,1), @(3.5,1), @(3,-1), @(3,2), @(3,[double]::NaN), @(3,[double]::PositiveInfinity))) {
    $rejected = $false
    try { $null = Resolve-TftBoardStarTarget @([pscustomobject]@{tier=$invalid[0];pcnt=$invalid[1]}) 1 } catch { $rejected=$true }
    if (-not $rejected) { throw 'Invalid star statistics were accepted.' }
}
if ((Test-TftBoardStarLevel 5 1) -or (Test-TftBoardStarLevel 2 1)) { throw 'Unsupported targets passed validation.' }
Write-Output 'Board star policy PASS: source-backed four-star, existing thresholds, unknown values fail-closed.'
