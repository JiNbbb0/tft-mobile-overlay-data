param(
    [string]$StaticMetaPath = (Join-Path $PSScriptRoot 'refresh-static-meta.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$resolvedPath = [IO.Path]::GetFullPath($StaticMetaPath)
if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
    throw "Static MetaTFT refresh script not found: $resolvedPath"
}

$text = [IO.File]::ReadAllText($resolvedPath).Replace("`r`n", "`n")

function Replace-BetweenMarkers {
    param(
        [Parameter(Mandatory = $true)][string]$InputText,
        [Parameter(Mandatory = $true)][string]$StartMarker,
        [Parameter(Mandatory = $true)][string]$EndMarker,
        [Parameter(Mandatory = $true)][string]$Replacement,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $start = $InputText.IndexOf($StartMarker, [StringComparison]::Ordinal)
    if ($start -lt 0) { throw "Strict source-policy start marker missing: $Context" }
    $end = $InputText.IndexOf($EndMarker, $start, [StringComparison]::Ordinal)
    if ($end -lt 0) { throw "Strict source-policy end marker missing: $Context" }
    return $InputText.Substring(0, $start) + $Replacement + $InputText.Substring($end)
}

$rankBegin = '# CANONICAL_V2_STRICT_RANK_SCOPE_BEGIN'
if (-not $text.Contains($rankBegin)) {
    $rankReplacement = @'
# CANONICAL_V2_STRICT_RANK_SCOPE_BEGIN
# Rank population is immutable: Ranked / Platinum+ / current patch / 3 days.
# Sparse upstream data may lower the sample threshold inside Platinum+, but it
# must never widen to all ranks or permit MetaTFT to adjust the filter.
$fallbackAttempted = $false
$rankScopeDecision = Resolve-CompositionCoveragePolicy `
    -PreferredStats $preferredCompsStats `
    -FallbackStats $null `
    -RequiredCompositions $candidatePoolTarget `
    -Thresholds $sampleThresholds
if ($rankScopeDecision.useFallback -or [string]$rankScopeDecision.effectiveScope -eq 'ALL_RANKS_FALLBACK') {
    throw 'CANONICAL_RANK_SCOPE_WIDENING_REFUSED'
}
$effectiveMinimumCompSamples = [int]$rankScopeDecision.minimumSamples
$preferredQualifiedCompositions = Get-QualifiedCompositionCount -Stats $preferredCompsStats -MinimumSamples $effectiveMinimumCompSamples
$effectiveQualifiedCompositions = [int]$rankScopeDecision.qualified
# CANONICAL_V2_STRICT_RANK_SCOPE_END
'@
    $text = Replace-BetweenMarkers `
        -InputText $text `
        -StartMarker '$fallbackCompsStats = $null' `
        -EndMarker 'Write-Output "Composition rank scope:' `
        -Replacement $rankReplacement `
        -Context 'rank scope'
}

$positionFallback = @'
        } else {
            $fallback = 0..27 | Where-Object { -not $occupied.ContainsKey([string]$_) } | Select-Object -First 1
            $assigned[[string]$instance.key] = [int]$fallback
            $occupied[[string]$fallback] = $true
        }
'@
$strictPositionFailure = @'
        } else {
            # Never invent a free hex. If MetaTFT positioning cannot support a
            # complete collision-free board, reject this snapshot and keep LKG.
            throw "METATFT_BOARD_POSITION_UNAVAILABLE unit=$unitId occurrence=$($instance.occurrence)"
        }
'@
if ($text.Contains($positionFallback)) {
    $text = $text.Replace($positionFallback, $strictPositionFailure)
}

$derivedBegin = "    foreach (`$level in 4..9) {`n        if (`$levelBoardRows.ContainsKey([string]`$level)) { continue }"
$levelBoardsBegin = "    `$levelBoards = foreach (`$level in 4..9) {"
if ($text.Contains($derivedBegin)) {
    $text = Replace-BetweenMarkers `
        -InputText $text `
        -StartMarker $derivedBegin `
        -EndMarker $levelBoardsBegin `
        -Replacement "    # Missing level boards remain missing; adjacent-level synthesis is forbidden.`n" `
        -Context 'derived level boards'
}

$boardSampleAnchor = @'
        sampleCount = $SampleCount
        units = @(New-BoardUnits -UnitIds $UnitIds -Details $Details -UnitMap $UnitMap -StarTargets $StarTargets)
'@
$boardSampleReplacement = @'
        sampleCount = $SampleCount
        synthetic = $false
        units = @(New-BoardUnits -UnitIds $UnitIds -Details $Details -UnitMap $UnitMap -StarTargets $StarTargets)
'@
if (-not $text.Contains('        synthetic = $false')) {
    if (-not $text.Contains($boardSampleAnchor)) {
        throw 'Board synthetic=false insertion anchor missing.'
    }
    $text = $text.Replace($boardSampleAnchor, $boardSampleReplacement)
}

$forbidden = @(
    '$fallbackCompsStatsUrl =',
    'ALL_RANKS_FALLBACK comps_stats',
    'Derived from adjacent MetaTFT public boards',
    '$fallback = 0..27',
    'permit_filter_adjustment=true'
)
foreach ($needle in $forbidden) {
    if ($text.Contains($needle)) { throw "Strict production source-policy postcondition failed; forbidden content remains: $needle" }
}
$required = @(
    $rankBegin,
    '-FallbackStats $null',
    'CANONICAL_RANK_SCOPE_WIDENING_REFUSED',
    'permit_filter_adjustment=false',
    'METATFT_BOARD_POSITION_UNAVAILABLE',
    'Missing level boards remain missing; adjacent-level synthesis is forbidden.',
    'synthetic = $false'
)
foreach ($needle in $required) {
    if (-not $text.Contains($needle)) { throw "Strict production source-policy postcondition missing: $needle" }
}

[IO.File]::WriteAllText($resolvedPath, $text, [Text.UTF8Encoding]::new($false))
Write-Output "Strict production MetaTFT source policy enabled: $resolvedPath"
