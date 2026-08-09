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

$newSet = Resolve-RankScopeDecision -PreferredQualified 0 -FallbackQualified 18 -RequiredCompositions 12 -FallbackAttempted $true
Assert-Equal 'ALL_RANKS_FALLBACK' $newSet.effectiveScope 'New-set coverage should fall back once.'
Assert-Equal $true $newSet.useFallback 'All-rank fallback should be selected.'

$stillSparse = Resolve-RankScopeDecision -PreferredQualified 3 -FallbackQualified 2 -RequiredCompositions 12 -FallbackAttempted $true
Assert-Equal 'PLATINUM_PLUS_LIMITED' $stillSparse.effectiveScope 'A worse fallback must not replace preferred data.'
Assert-Equal $false $stillSparse.useFallback 'Fallback must not loop or reduce coverage.'

if ($Live) {
    $url = 'https://api-hc.metatft.com/tft-comps-api/comps_stats?queue=1100&patch=current&days=3&rank=CHALLENGER,DIAMOND,EMERALD,GRANDMASTER,MASTER,PLATINUM&permit_filter_adjustment=true'
    $stats = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = 'TFT-Mobile-Overlay-Data/1.0' }
    $qualified = Get-QualifiedCompositionCount -Stats $stats -MinimumSamples 5000
    $decision = Resolve-RankScopeDecision `
        -PreferredQualified $qualified `
        -FallbackQualified -1 `
        -RequiredCompositions 12 `
        -FallbackAttempted $false
    Write-Output "Live Platinum+ coverage: Qualified=$qualified Effective=$($decision.effectiveScope)"
}

Write-Output 'Rank scope policy tests passed.'
