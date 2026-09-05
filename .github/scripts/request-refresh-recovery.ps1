param([Parameter(Mandatory)][ValidatePattern('^[\w.-]+/[\w.-]+$')][string]$Repository)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../../tools/automation-health-policy.ps1')
$raw = gh api "repos/$Repository/actions/workflows/refresh-tft-data.yml/runs?per_page=20"
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect refresh queue; no speculative dispatch performed' }
$runs = @((($raw -join "`n") | ConvertFrom-Json).workflow_runs)
$decision = Resolve-RecoveryDispatch -Runs $runs -NeedsRefresh $true
if ($decision -eq 'DISPATCH') {
    gh workflow run refresh-tft-data.yml --ref main --repo $Repository
    if ($LASTEXITCODE -ne 0) { throw 'Recovery dispatch failed' }
}
Write-Output "Bounded refresh recovery: $decision"
