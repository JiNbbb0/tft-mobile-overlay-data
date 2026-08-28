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

$metaPath = Join-Path $PSScriptRoot 'refresh-static-meta.ps1'
$validatorPath = Join-Path $PSScriptRoot 'validate-static-meta.ps1'
$livePath = Join-Path $PSScriptRoot 'refresh-live-data.ps1'
$rawFallbackPath = Join-Path $PSScriptRoot 'raw-champion-fallback.ps1'

foreach ($path in @($metaPath, $validatorPath, $livePath, $rawFallbackPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required hardening file missing: $path" }
}

$meta = [IO.File]::ReadAllText($metaPath).Replace("`r`n", "`n")
$validator = [IO.File]::ReadAllText($validatorPath).Replace("`r`n", "`n")
$live = [IO.File]::ReadAllText($livePath).Replace("`r`n", "`n")

Assert-Contains $meta '    augments = @($augments)' 'Android JSON contract hardening is missing for augments.'
Assert-Contains $meta '    compositions = @($compositions)' 'Android JSON contract hardening is missing for compositions.'
Assert-Contains $meta '-and -not $AllowPartial' 'Partial new-set composition policy is missing.'
Assert-Contains $meta 'function Resolve-CatalogItemId' 'Cross-source item ID canonicalization is missing.'
Assert-Contains $meta '$catalogItemIdByLooseKey' 'Loose-key item compatibility index is missing.'
Assert-Contains $meta 'Resolve-CatalogItemId -ItemId' 'Composition item references are not being canonicalized.'
Assert-Contains $meta '$hasIncompleteCompositionMetadata' 'Metadata readiness no longer accounts for optional composition gaps.'
Assert-Contains $meta "'META_COLLECTING'" 'Partial metadata readiness state is missing.'

Assert-Contains $validator 'recommendedAugments.Count -eq 0 -and -not $isPartial' 'Validator would reject usable partial compositions when optional augment data is late.'
Assert-Contains $live '$existingSetReadiness' 'Existing partial-set readiness continuation is missing.'
Assert-Contains $live '$allowPartial = $isNewSet -or $existingSetReadiness' 'Partial-mode continuation until META_STABLE is missing.'

$currentSnapshot = Join-Path (Split-Path -Parent $PSScriptRoot) 'source/current/tft_static_snapshot.json'
if (Test-Path -LiteralPath $currentSnapshot -PathType Leaf) {
    $raw = [IO.File]::ReadAllText($currentSnapshot)
    if ($raw -notmatch '"augments"\s*:\s*\[') { throw 'Tracked snapshot no longer serializes augments as a JSON array.' }
    if ($raw -notmatch '"compositions"\s*:\s*\[') { throw 'Tracked snapshot no longer serializes compositions as a JSON array.' }
}

Write-Output 'Runtime compatibility hardening postconditions passed.'
