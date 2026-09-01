Set-StrictMode -Version Latest

function Get-MetaTftPageMinimumSamples {
    param(
        [Parameter(Mandatory = $true)][double]$GameCount,
        [double]$MinimumPickRate = 0.01,
        [int]$PlayerSlotsPerGame = 8
    )

    if ($GameCount -le 0) { throw 'MetaTFT page parity requires a positive game count.' }
    if ($MinimumPickRate -lt 0 -or $MinimumPickRate -gt 1) { throw 'MetaTFT page minimum pick rate must be between 0 and 1.' }
    if ($PlayerSlotsPerGame -le 0) { throw 'MetaTFT player slots per game must be positive.' }
    return [Math]::Max(1, [Math]::Ceiling($GameCount * $MinimumPickRate / $PlayerSlotsPerGame))
}

function Test-MetaTftPageCompositionVisible {
    param(
        [Parameter(Mandatory = $true)][int]$SampleCount,
        [Parameter(Mandatory = $true)][double]$CentroidMaximum,
        [Parameter(Mandatory = $true)][int]$MinimumSamples,
        [double]$CentroidVisibilityMinimum = 1.0
    )

    return $SampleCount -ge $MinimumSamples -and $CentroidMaximum -ge $CentroidVisibilityMinimum
}
