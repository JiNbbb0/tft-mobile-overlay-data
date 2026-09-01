param([switch]$Live)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'rank-scope-policy.ps1')

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "$Message Expected=$Expected Actual=$Actual" }
}

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
Assert-Equal 'PLATINUM_PLUS' $preferred.effectiveScope 'Preferred scope should remain active.'
Assert-Equal $false $preferred.useFallback 'Sufficient preferred data must not fall back.'
Assert-Equal $false $preferred.fallbackAllowed 'All-rank fallback must remain contractually disabled.'

$newSet = Resolve-RankScopeDecision -PreferredQualified 0 -FallbackQualified 18 -RequiredCompositions 12 -FallbackAttempted $true
Assert-Equal 'PLATINUM_PLUS_LIMITED' $newSet.effectiveScope 'Sparse new-set coverage must stay within Platinum+.'
Assert-Equal $false $newSet.useFallback 'All-rank fallback is forbidden even when it would improve coverage.'
Assert-Equal $false $newSet.fallbackAllowed 'Fallback policy must fail closed.'

$stillSparse = Resolve-RankScopeDecision -PreferredQualified 3 -FallbackQualified 20 -RequiredCompositions 12 -FallbackAttempted $true
Assert-Equal 'PLATINUM_PLUS_LIMITED' $stillSparse.effectiveScope 'Sparse preferred data must remain Platinum+ limited.'
Assert-Equal $false $stillSparse.useFallback 'Fallback must never widen the rank population.'

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
Assert-Equal 'PLATINUM_PLUS' $adaptive.effectiveScope 'Adaptive threshold must preserve the preferred rank scope.'
Assert-Equal 1000 $adaptive.minimumSamples 'Adaptive threshold should retain a broad Platinum+ candidate pool before selecting the visible leaderboard.'
Assert-Equal 40 $adaptive.qualified 'Adaptive threshold composition count mismatch.'
Assert-Equal $false $adaptive.fallbackAllowed 'Adaptive thresholding must not enable rank fallback.'

$emptyPreferred = [pscustomobject]@{ results = @() }
$ignoredFallback = Resolve-CompositionCoveragePolicy `
    -PreferredStats $emptyPreferred `
    -FallbackStats $adaptiveFixture `
    -RequiredCompositions 36 `
    -Thresholds @(5000, 3000, 2000, 1000, 500, 250)
Assert-Equal 'PLATINUM_PLUS_LIMITED' $ignoredFallback.effectiveScope 'An all-rank dataset supplied by an old caller must be ignored.'
Assert-Equal $false $ignoredFallback.useFallback 'All-rank fallback must remain disabled.'
Assert-Equal 0 $ignoredFallback.qualified 'Fallback data must not affect qualified composition count.'

$sufficientQuality = Resolve-RankScopeQualityContract -EffectiveScope 'PLATINUM_PLUS'
Assert-Equal 'PLATINUM_PLUS' $sufficientQuality.rankFilter 'Normal source must preserve the Platinum+ rank filter.'
Assert-Equal 'SUFFICIENT' $sufficientQuality.coverage 'Normal source coverage was misclassified.'
$limitedQuality = Resolve-RankScopeQualityContract -EffectiveScope 'PLATINUM_PLUS_LIMITED'
Assert-Equal 'PLATINUM_PLUS' $limitedQuality.rankFilter 'Limited coverage must not widen the rank filter.'
Assert-Equal 'LIMITED' $limitedQuality.coverage 'Limited Platinum+ coverage was not surfaced.'
$blockedFallback = $false
try { Resolve-RankScopeQualityContract -EffectiveScope 'ALL_RANKS_FALLBACK' | Out-Null } catch { $blockedFallback = $_.Exception.Message -match 'DATA_QUALITY_FILTER_MISMATCH' }
if (-not $blockedFallback) { throw 'ALL_RANKS_FALLBACK must fail closed in the data-quality contract.' }

if ($Live) {
    $url = 'https://api-hc.metatft.com/tft-comps-api/comps_stats?queue=1100&patch=current&days=3&rank=CHALLENGER,DIAMOND,EMERALD,GRANDMASTER,MASTER,PLATINUM&permit_filter_adjustment=false'
    $stats = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = 'TFT-Mobile-Overlay-Data/1.0' }
    $decision = Resolve-CompositionCoveragePolicy `
        -PreferredStats $stats `
        -FallbackStats $null `
        -RequiredCompositions 36 `
        -Thresholds @(5000, 3000, 2000, 1000, 500, 250)
    if ($decision.useFallback -or $decision.effectiveScope -eq 'ALL_RANKS_FALLBACK') {
        throw 'Live policy attempted to widen beyond Platinum+.'
    }
    Write-Output "Live Platinum+ coverage: Qualified=$($decision.qualified) MinimumSamples=$($decision.minimumSamples) Effective=$($decision.effectiveScope)"
}

Write-Output 'Rank scope policy tests passed.'
