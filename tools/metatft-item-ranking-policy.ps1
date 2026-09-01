$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Sort-MetaTftCompositionItemRanking {
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $true)][string]$CompositionId,
        [switch]$AllowEmpty
    )

    $normalized = @($Rows)
    if ($normalized.Count -eq 0) {
        if ($AllowEmpty) { return @() }
        throw "MetaTFT comp_details exposes no item play-rate rows for composition $CompositionId."
    }

    $duplicates = @(
        $normalized |
            Group-Object itemId |
            Where-Object Count -gt 1 |
            ForEach-Object Name
    )
    if ($duplicates.Count -gt 0) {
        throw "MetaTFT item recommendation IDs collapse to duplicate canonical IDs for ${CompositionId}: $($duplicates -join ',')."
    }

    foreach ($row in $normalized) {
        if (-not [string]$row.itemId -or -not [string]$row.itemName) {
            throw "MetaTFT item recommendation identity is incomplete for $CompositionId."
        }
        if ([double]$row.adoptionRate -lt 0.0 -or [double]$row.adoptionRate -gt 27.0) {
            throw "MetaTFT item recommendation adoption rate is outside the equipable 0-27 range for $CompositionId/$($row.itemId)."
        }
        if ([double]$row.averagePlacement -lt 1.0 -or [double]$row.averagePlacement -gt 8.0) {
            throw "MetaTFT item recommendation placement is outside 1-8 for $CompositionId/$($row.itemId)."
        }
        if ([int]$row.sampleCount -le 0) {
            throw "MetaTFT item recommendation sample count is invalid for $CompositionId/$($row.itemId)."
        }
    }

    return @(
        $normalized |
            Sort-Object @{ Expression = { -[double]$_.adoptionRate } }, averagePlacement, @{ Expression = { -[int]$_.sampleCount } }, itemName
    )
}
