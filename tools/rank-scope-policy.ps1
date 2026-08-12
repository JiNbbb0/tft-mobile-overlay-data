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

function Resolve-SampleCoverage {
    param(
        [Parameter(Mandatory = $true)]$Stats,
        [Parameter(Mandatory = $true)][int]$RequiredCompositions,
        [Parameter(Mandatory = $true)][int[]]$Thresholds
    )

    $orderedThresholds = @($Thresholds | Where-Object { $_ -gt 0 } | Sort-Object -Descending -Unique)
    if ($orderedThresholds.Count -eq 0) { throw 'At least one positive sample threshold is required.' }
    $best = $null
    foreach ($threshold in $orderedThresholds) {
        $count = Get-QualifiedCompositionCount -Stats $Stats -MinimumSamples $threshold
        $candidate = [pscustomobject][ordered]@{ minimumSamples = [int]$threshold; qualified = [int]$count }
        if (-not $best -or $count -gt $best.qualified) { $best = $candidate }
        if ($count -ge $RequiredCompositions) { return $candidate }
    }
    return $best
}

function Resolve-CompositionCoveragePolicy {
    param(
        [Parameter(Mandatory = $true)]$PreferredStats,
        [AllowNull()]$FallbackStats,
        [Parameter(Mandatory = $true)][int]$RequiredCompositions,
        [Parameter(Mandatory = $true)][int[]]$Thresholds
    )

    $preferred = Resolve-SampleCoverage -Stats $PreferredStats -RequiredCompositions $RequiredCompositions -Thresholds $Thresholds
    if ($preferred.qualified -ge $RequiredCompositions) {
        return [pscustomobject][ordered]@{
            effectiveScope = 'PLATINUM_PLUS'
            useFallback = $false
            minimumSamples = $preferred.minimumSamples
            qualified = $preferred.qualified
            reason = "Platinum+ reached $($preferred.qualified) compositions at $($preferred.minimumSamples) samples."
        }
    }

    $fallback = if ($null -ne $FallbackStats) {
        Resolve-SampleCoverage -Stats $FallbackStats -RequiredCompositions $RequiredCompositions -Thresholds $Thresholds
    } else { $null }
    if ($fallback -and $fallback.qualified -gt $preferred.qualified) {
        return [pscustomobject][ordered]@{
            effectiveScope = 'ALL_RANKS_FALLBACK'
            useFallback = $true
            minimumSamples = $fallback.minimumSamples
            qualified = $fallback.qualified
            reason = "Platinum+ reached only $($preferred.qualified); all ranks reached $($fallback.qualified) at $($fallback.minimumSamples) samples."
        }
    }
    return [pscustomobject][ordered]@{
        effectiveScope = 'PLATINUM_PLUS_LIMITED'
        useFallback = $false
        minimumSamples = $preferred.minimumSamples
        qualified = $preferred.qualified
        reason = "All-rank fallback did not improve Platinum+ coverage of $($preferred.qualified)."
    }
}
