$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'metatft-page-parity-policy.ps1')

$minimum = Get-MetaTftPageMinimumSamples -GameCount 40000 -MinimumPickRate 0.01 -PlayerSlotsPerGame 8
if ($minimum -ne 50) { throw "Expected a 50-sample page threshold, got $minimum." }
if (-not (Test-MetaTftPageCompositionVisible -SampleCount 50 -CentroidMaximum 1.0 -MinimumSamples $minimum)) {
    throw 'A composition on both MetaTFT page visibility boundaries was rejected.'
}
if (Test-MetaTftPageCompositionVisible -SampleCount 49 -CentroidMaximum 2.0 -MinimumSamples $minimum) {
    throw 'A composition below the MetaTFT page pick-rate threshold was accepted.'
}
if (Test-MetaTftPageCompositionVisible -SampleCount 500 -CentroidMaximum 0.99 -MinimumSamples $minimum) {
    throw 'A composition below the MetaTFT centroid visibility threshold was accepted.'
}

Write-Output 'MetaTFT comps page parity policy fixtures passed.'
