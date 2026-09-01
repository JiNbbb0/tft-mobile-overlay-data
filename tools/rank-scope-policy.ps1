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
            fallbackAllowed = $false
            reason = 'Preferred Platinum+ sample coverage is sufficient.'
        }
    }

    # Canonical v2 is deliberately fail-closed on rank scope. A sparse new set
    # may publish partial Platinum+ data, but it must never widen to all ranks.
    return [pscustomobject][ordered]@{
        effectiveScope = 'PLATINUM_PLUS_LIMITED'
        useFallback = $false
        fallbackAllowed = $false
        reason = "Platinum+ produced $PreferredQualified qualified compositions; all-rank fallback is disabled by contract."
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
            fallbackAllowed = $false
            minimumSamples = $preferred.minimumSamples
            qualified = $preferred.qualified
            reason = "Platinum+ reached $($preferred.qualified) compositions at $($preferred.minimumSamples) samples."
        }
    }

    # FallbackStats remains in the signature for compatibility with older
    # callers, but is intentionally ignored. This prevents a delayed/new-set
    # upstream from silently changing the statistical population.
    return [pscustomobject][ordered]@{
        effectiveScope = 'PLATINUM_PLUS_LIMITED'
        useFallback = $false
        fallbackAllowed = $false
        minimumSamples = $preferred.minimumSamples
        qualified = $preferred.qualified
        reason = "Platinum+ reached only $($preferred.qualified) compositions at $($preferred.minimumSamples) samples; all-rank fallback is disabled by contract."
    }
}

function Resolve-RankScopeQualityContract {
    param(
        [Parameter(Mandatory = $true)][string]$EffectiveScope
    )

    switch ($EffectiveScope) {
        'PLATINUM_PLUS' {
            return [pscustomobject][ordered]@{
                sourceScope = 'PLATINUM_PLUS'
                rankFilter = 'PLATINUM_PLUS'
                coverage = 'SUFFICIENT'
                isLimited = $false
            }
        }
        'PLATINUM_PLUS_LIMITED' {
            return [pscustomobject][ordered]@{
                sourceScope = 'PLATINUM_PLUS_LIMITED'
                rankFilter = 'PLATINUM_PLUS'
                coverage = 'LIMITED'
                isLimited = $true
            }
        }
        default {
            throw "DATA_QUALITY_FILTER_MISMATCH expected=PLATINUM_PLUS_OR_LIMITED actual=$EffectiveScope"
        }
    }
}
