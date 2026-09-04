param([switch]$Live)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'rank-scope-policy.ps1')

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "$Message Expected=$Expected Actual=$Actual" }
}

$scopeContract = Get-TftStatisticsScopeContract
Assert-Equal 'DIAMOND_PLUS' $scopeContract.preferredScope 'Preferred scope contract drifted.'
Assert-Equal 'DIAMOND_PLUS_LIMITED' $scopeContract.limitedScope 'Limited scope contract drifted.'
Assert-Equal 'CHALLENGER,DIAMOND,GRANDMASTER,MASTER' $scopeContract.preferredRankFilter 'Diamond+ filter must not include Emerald or Platinum.'

$fixture = [pscustomobject]@{
    results = @(
        [pscustomobject]@{ cluster = '100'; places = @(1, 1, 1, 1, 1, 1, 1, 1, 5000) },
        [pscustomobject]@{ cluster = '101'; places = @(1, 1, 1, 1, 1, 1, 1, 1, 4999) },
        [pscustomobject]@{ cluster = '-1'; places = @(1, 1, 1, 1, 1, 1, 1, 1, 9000) },
        [pscustomobject]@{ cluster = '102'; places = @(1, 1, 1) }
    )
}
Assert-Equal 1 (Get-QualifiedCompositionCount -Stats $fixture -MinimumSamples 5000) 'Qualified count mismatch.'

$preferred = Resolve-RankScopeDecision -PreferredQualified 18 -FallbackQualified 0 -RequiredCompositions 12 -FallbackAttempted $false
Assert-Equal 'DIAMOND_PLUS' $preferred.effectiveScope 'Preferred scope should remain active.'
Assert-Equal $false $preferred.useFallback 'Sufficient preferred data must not fall back.'

$newSet = Resolve-RankScopeDecision -PreferredQualified 0 -FallbackQualified 18 -RequiredCompositions 12 -FallbackAttempted $true
Assert-Equal 'DIAMOND_PLUS_LIMITED' $newSet.effectiveScope 'New-set coverage must remain on the page rank scope.'
Assert-Equal $false $newSet.useFallback 'All-rank fallback must not be selected.'

$stillSparse = Resolve-RankScopeDecision -PreferredQualified 3 -FallbackQualified 2 -RequiredCompositions 12 -FallbackAttempted $true
Assert-Equal 'DIAMOND_PLUS_LIMITED' $stillSparse.effectiveScope 'A worse fallback must not replace preferred data.'
Assert-Equal $false $stillSparse.useFallback 'Fallback must not loop or reduce coverage.'

$adaptiveFixture = [pscustomobject]@{
    results = @(
        1..40 | ForEach-Object {
            $samples = if ($_ -le 6) { 5000 } elseif ($_ -le 20) { 3000 } else { 1000 }
            [pscustomobject]@{ cluster = [string](200 + $_); places = @(1, 1, 1, 1, 1, 1, 1, 1, $samples) }
        }
    )
}
$adaptive = Resolve-CompositionCoveragePolicy `
    -PreferredStats $adaptiveFixture `
    -FallbackStats $null `
    -RequiredCompositions 36 `
    -Thresholds @(5000, 3000, 2000, 1000, 500, 250)
Assert-Equal 'DIAMOND_PLUS' $adaptive.effectiveScope 'Adaptive threshold must preserve the preferred rank scope.'
Assert-Equal 1000 $adaptive.minimumSamples 'Adaptive threshold should retain a broad candidate pool before selecting the visible leaderboard.'
Assert-Equal 40 $adaptive.qualified 'Adaptive threshold composition count mismatch.'

$emptyPreferred = [pscustomobject]@{ results = @() }
$fallbackAdaptive = Resolve-CompositionCoveragePolicy `
    -PreferredStats $emptyPreferred `
    -FallbackStats $adaptiveFixture `
    -RequiredCompositions 36 `
    -Thresholds @(5000, 3000, 2000, 1000, 500, 250)
Assert-Equal 'DIAMOND_PLUS_LIMITED' $fallbackAdaptive.effectiveScope 'A new set without high-rank data must remain limited instead of changing rank scope.'
Assert-Equal 5000 $fallbackAdaptive.minimumSamples 'Limited coverage should retain the preferred-scope threshold evidence.'
Assert-Equal $false $fallbackAdaptive.useFallback 'Limited coverage must not use fallback data.'

if ($Live) {
    $rankContract = Get-TftStatisticsScopeContract
    $url = "https://api-hc.metatft.com/tft-comps-api/comps_stats?queue=1100&patch=current&days=3&rank=$($rankContract.preferredRankFilter)&permit_filter_adjustment=false"
    $stats = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = 'TFT-Mobile-Overlay-Data/1.0' }
    $decision = Resolve-CompositionCoveragePolicy `
        -PreferredStats $stats `
        -FallbackStats $null `
        -RequiredCompositions 36 `
        -Thresholds @(5000, 3000, 2000, 1000, 500, 250)
    Write-Output "Live $($rankContract.displayName) coverage: Qualified=$($decision.qualified) MinimumSamples=$($decision.minimumSamples) Effective=$($decision.effectiveScope)"
}

Write-Output 'Rank scope policy tests passed.'
