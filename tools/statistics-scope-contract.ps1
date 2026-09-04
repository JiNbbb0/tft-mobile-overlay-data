Set-StrictMode -Version Latest

function Get-TftStatisticsScopeContract {
    return [pscustomobject][ordered]@{
        preferredScope = 'DIAMOND_PLUS'
        limitedScope = 'DIAMOND_PLUS_LIMITED'
        preferredRankFilter = 'CHALLENGER,DIAMOND,GRANDMASTER,MASTER'
        displayName = 'Diamond+'
        limitedWarningCode = 'DIAMOND_PLUS_COVERAGE_LIMITED'
    }
}

function Test-TftStatisticsScopeName {
    param([AllowEmptyString()][string]$Scope)

    $contract = Get-TftStatisticsScopeContract
    return $Scope -in @($contract.preferredScope, $contract.limitedScope)
}

function Test-TftStatisticsRankFilter {
    param([AllowEmptyString()][string]$RankFilter)

    $contract = Get-TftStatisticsScopeContract
    return $RankFilter -eq $contract.preferredRankFilter
}
