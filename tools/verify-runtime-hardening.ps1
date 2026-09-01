$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Needle,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Text.Contains($Needle)) { throw $Message }
}
function Assert-NotContains {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Needle,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ($Text.Contains($Needle)) { throw $Message }
}

$catalogPath = Join-Path $PSScriptRoot 'refresh-catalog.ps1'
$metaPath = Join-Path $PSScriptRoot 'refresh-static-meta.ps1'
$validatorPath = Join-Path $PSScriptRoot 'validate-static-meta.ps1'
$livePath = Join-Path $PSScriptRoot 'refresh-live-data.ps1'
$publishPath = Join-Path $PSScriptRoot 'publish-data-history.ps1'
$rawFallbackPath = Join-Path $PSScriptRoot 'raw-champion-fallback.ps1'

foreach ($path in @($catalogPath,$metaPath,$validatorPath,$livePath,$publishPath,$rawFallbackPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required hardening file missing: $path" }
}

$catalog = [IO.File]::ReadAllText($catalogPath).Replace("`r`n", "`n")
$meta = [IO.File]::ReadAllText($metaPath).Replace("`r`n", "`n")
$validator = [IO.File]::ReadAllText($validatorPath).Replace("`r`n", "`n")
$live = [IO.File]::ReadAllText($livePath).Replace("`r`n", "`n")
$publish = [IO.File]::ReadAllText($publishPath).Replace("`r`n", "`n")

# Catalog: current-set item universe + typed, fail-closed display resolution.
Assert-Contains $catalog "normalize/Get-CurrentSetUniverse.ps1" 'Current-set catalog universe module is missing.'
Assert-Contains $catalog "normalize/Get-EmblemMappings.ps1" 'Validated emblem mapping module is missing.'
Assert-Contains $catalog "normalize/Resolve-TftDisplayValue.ps1" 'Typed display resolver module is missing.'
Assert-Contains $catalog '# CANONICAL_V2_TYPED_DISPLAY_BEGIN' 'Typed display runtime patch is missing.'
Assert-Contains $catalog 'CATALOG_UNRESOLVED_DISPLAY_TOKENS' 'Unresolved display token gate is missing.'
Assert-NotContains $catalog "return '可変値'" 'Legacy arbitrary-value placeholder survived runtime patch.'
Assert-NotContains $catalog "return '戦闘中の値'" 'Legacy dynamic placeholder survived runtime patch.'
Assert-NotContains $catalog "'戦闘中に変動'" 'Legacy blanket dynamic placeholder survived runtime patch.'
Assert-NotContains $catalog "'特殊効果'" 'Legacy unknown-keyword placeholder survived runtime patch.'

# Meta: existing compatibility plus strict source/board policy.
Assert-Contains $meta '    augments = @($augments)' 'Android JSON contract hardening is missing for augments.'
Assert-Contains $meta '    compositions = @($compositions)' 'Android JSON contract hardening is missing for compositions.'
Assert-Contains $meta 'preserving the source result without generic padding' 'Optional composition metadata policy is missing.'
Assert-NotContains $meta 'if (-not $compAugmentTiers.results.PSObject.Properties[$clusterId])' 'Missing optional augment tiers still suppress composition candidates.'
Assert-Contains $meta "id-compatibility-policy.ps1" 'Cross-source item ID policy is missing.'
Assert-Contains $meta 'function Resolve-CanonicalPublicationItemId' 'Fail-closed item ID canonicalization is missing.'
Assert-Contains $meta 'Resolve-TftCanonicalId -Index $canonicalItemIndex' 'Canonical item compatibility index is not used.'
Assert-Contains $meta 'Resolve-CanonicalPublicationItemId -RawId' 'Composition item references are not being canonicalized.'
Assert-Contains $meta 'UNRESOLVED_CANONICAL_ITEM_ID' 'Unresolved production item IDs do not fail closed.'
Assert-Contains $meta '$hasIncompleteCompositionMetadata' 'Metadata readiness no longer accounts for optional composition gaps.'
Assert-Contains $meta "'META_COLLECTING'" 'Partial metadata readiness state is missing.'
Assert-Contains $meta '# CANONICAL_V2_STRICT_RANK_SCOPE_BEGIN' 'Strict Platinum+ runtime policy is missing.'
Assert-Contains $meta 'METATFT_BOARD_POSITION_UNAVAILABLE' 'Fail-closed board position gate is missing.'
Assert-Contains $meta 'synthetic = $false' 'Non-synthetic board declaration is missing.'
Assert-NotContains $meta '$fallbackCompsStatsUrl =' 'All-rank fallback request survived runtime patch.'
Assert-NotContains $meta 'Derived from adjacent MetaTFT public boards' 'Synthetic adjacent-level board derivation survived runtime patch.'
Assert-NotContains $meta '$fallback = 0..27' 'Synthetic first-free-cell board positioning survived runtime patch.'
Assert-NotContains $meta 'permit_filter_adjustment=true' 'Implicit MetaTFT filter adjustment is enabled.'

Assert-Contains $validator 'recommendedAugments.Count -eq 0 -and -not $isPartial' 'Validator would reject usable partial compositions when optional augment data is late.'

# Publication: candidate registration must preserve LKG until promotion workflow.
Assert-Contains $publish '# CANONICAL_V2_CANDIDATE_STAGE_BEGIN' 'Candidate staging patch is missing.'
Assert-Contains $publish 'latestVersionId = $candidatePreviousLatestVersionId' 'Candidate publisher does not preserve LKG pointer.'
Assert-NotContains $publish '    latestVersionId = $versionId' 'Candidate publisher still promotes latest during generation.'
Assert-Contains $live '# CANONICAL_V2_CANDIDATE_REFRESH_BEGIN' 'Refresh candidate identity patch is missing.'
Assert-Contains $live 'CANDIDATE_WAS_PROMOTED_EARLY' 'Early-promotion guard is missing.'
Assert-Contains $live '$existingSetReadiness' 'Existing partial-set readiness continuation is missing.'
Assert-Contains $live '$allowPartial = $isNewSet -or $existingSetReadiness' 'Partial-mode continuation until META_STABLE is missing.'

$currentSnapshot = Join-Path (Split-Path -Parent $PSScriptRoot) 'source/current/tft_static_snapshot.json'
if (Test-Path -LiteralPath $currentSnapshot -PathType Leaf) {
    $raw = [IO.File]::ReadAllText($currentSnapshot)
    if ($raw -notmatch '"augments"\s*:\s*\[') { throw 'Tracked snapshot no longer serializes augments as a JSON array.' }
    if ($raw -notmatch '"compositions"\s*:\s*\[') { throw 'Tracked snapshot no longer serializes compositions as a JSON array.' }
}

Write-Output 'Runtime compatibility hardening postconditions passed.'
