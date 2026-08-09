Set-StrictMode -Version Latest

function Get-QualifiedCompositionCount {
    param(
        [Parameter(Mandatory = $true)]$Stats,
        [Parameter(Mandatory = $true)][int]$MinimumSamples
    )

    return @(
        @($Stats.results) | Where-Object {
            $clusterId = [string]$_.cluster
            $places = @($_.places)
            $clusterId -and
                $clusterId -ne '-1' -and
                $places.Count -ge 9 -and
                [int]$places[8] -ge $MinimumSamples
        }
    ).Count
}

function Resolve-RankScopeDecision {
    param(
        [Parameter(Mandatory = $true)][int]$PreferredQualified,
        [Parameter(Mandatory = $true)][int]$FallbackQualified,
        [Parameter(Mandatory = $true)][int]$RequiredCompositions,
        [Parameter(Mandatory = $true)][bool]$FallbackAttempted
    )

    if ($PreferredQualified -ge $RequiredCompositions) {
        return [pscustomobject][ordered]@{
            effectiveScope = 'PLATINUM_PLUS'
            useFallback = $false
            reason = 'Preferred Platinum+ sample coverage is sufficient.'
        }
    }
    if ($FallbackAttempted -and $FallbackQualified -gt $PreferredQualified) {
        return [pscustomobject][ordered]@{
            effectiveScope = 'ALL_RANKS_FALLBACK'
            useFallback = $true
            reason = "Platinum+ produced $PreferredQualified qualified compositions; all ranks produced $FallbackQualified."
        }
    }
    return [pscustomobject][ordered]@{
        effectiveScope = 'PLATINUM_PLUS_LIMITED'
        useFallback = $false
        reason = "Neither scope improved coverage beyond $PreferredQualified qualified compositions."
    }
}
