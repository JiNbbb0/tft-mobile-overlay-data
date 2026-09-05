Set-StrictMode -Version Latest

function Get-TftStatisticsScopeContract {
    param([string]$RankId = 'DIAMOND_PLUS')
    $registry = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '../config/composition-ranks.json') | ConvertFrom-Json
    $rank = @($registry.ranks | Where-Object id -CEQ $RankId)
    if ($rank.Count -ne 1) { throw "Unknown composition rank: $RankId" }
    return [pscustomobject][ordered]@{
        preferredScope = $RankId
        limitedScope = "${RankId}_LIMITED"
        preferredRankFilter = [string]$rank[0].rankFilter
        displayName = [string]$rank[0].label
        limitedWarningCode = "${RankId}_COVERAGE_LIMITED"
    }
}

function Test-TftStatisticsScopeName {
    param([AllowEmptyString()][string]$Scope, [string]$RankId = 'DIAMOND_PLUS')

    $contract = Get-TftStatisticsScopeContract -RankId $RankId
    return $Scope -in @($contract.preferredScope, $contract.limitedScope)
}

function Test-TftStatisticsRankFilter {
    param([AllowEmptyString()][string]$RankFilter)

    $contract = Get-TftStatisticsScopeContract
    return $RankFilter -eq $contract.preferredRankFilter
}
