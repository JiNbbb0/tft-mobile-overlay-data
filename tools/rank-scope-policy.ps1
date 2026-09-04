Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'statistics-scope-contract.ps1')

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

    $contract = Get-TftStatisticsScopeContract
    if ($PreferredQualified -ge $RequiredCompositions) {
        return [pscustomobject][ordered]@{
            effectiveScope = $contract.preferredScope
            useFallback = $false
            reason = "Preferred $($contract.displayName) sample coverage is sufficient."
        }
    }
    return [pscustomobject][ordered]@{
        effectiveScope = $contract.limitedScope
        useFallback = $false
        reason = "$($contract.displayName) coverage is limited to $PreferredQualified compositions; a different rank scope is not substituted."
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

    $contract = Get-TftStatisticsScopeContract
    $preferred = Resolve-SampleCoverage -Stats $PreferredStats -RequiredCompositions $RequiredCompositions -Thresholds $Thresholds
    if ($preferred.qualified -ge $RequiredCompositions) {
        return [pscustomobject][ordered]@{
            effectiveScope = $contract.preferredScope
            useFallback = $false
            minimumSamples = $preferred.minimumSamples
            qualified = $preferred.qualified
            reason = "$($contract.displayName) reached $($preferred.qualified) compositions at $($preferred.minimumSamples) samples."
        }
    }

    $fallback = if ($null -ne $FallbackStats) {
        Resolve-SampleCoverage -Stats $FallbackStats -RequiredCompositions $RequiredCompositions -Thresholds $Thresholds
    } else { $null }
    return [pscustomobject][ordered]@{
        effectiveScope = $contract.limitedScope
        useFallback = $false
        minimumSamples = $preferred.minimumSamples
        qualified = $preferred.qualified
        reason = "$($contract.displayName) coverage is limited to $($preferred.qualified); a different rank scope is not substituted."
    }
}
