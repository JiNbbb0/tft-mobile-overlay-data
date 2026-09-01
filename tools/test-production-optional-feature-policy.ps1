$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$productionPath = Join-Path $PSScriptRoot 'refresh-static-meta.ps1'
$compatibilityPath = Join-Path $PSScriptRoot 'validate-data-compatibility.ps1'
$production = [IO.File]::ReadAllText($productionPath).Replace("`r`n", "`n")
$compatibility = [IO.File]::ReadAllText($compatibilityPath).Replace("`r`n", "`n")

$forbidden = @(
    'No comp-specific augments for composition',
    'META_STABLE cannot contain compositions with missing augment recommendations',
    'if (-not $compAugmentTiers.results.PSObject.Properties[$clusterId])'
)
foreach ($needle in $forbidden) {
    if ($production.Contains($needle) -or $compatibility.Contains($needle)) {
        throw "Optional composition-augment data still blocks an otherwise valid candidate: $needle"
    }
}
foreach ($required in @(
    'COMPOSITION_AUGMENTS_COLLECTING',
    "'DEGRADED_OPTIONAL'"
)) {
    if (-not $compatibility.Contains($required)) { throw "Optional feature degradation contract missing: $required" }
}

Write-Output 'Production optional-feature degradation regression passed.'
