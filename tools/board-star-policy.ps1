# Source-backed star targets used by BOTH generation and publication validation.
# 0 means no statistically supported target, not a one-star champion.
function Test-TftBoardStarLevel([int]$Level, [int]$Cost) {
    return $Level -in @(0, 2, 3, 4) -and ($Level -ne 2 -or $Cost -ge 4)
}

function Resolve-TftBoardStarTarget($Tiers, [int]$Cost) {
    foreach ($tier in @($Tiers)) {
        $level = [double]$tier.tier
        $rate = [double]$tier.pcnt
        if ($level -notin @(1, 2, 3, 4) -or [double]::IsNaN($rate) -or [double]::IsInfinity($rate) -or $rate -lt 0 -or $rate -gt 1) {
            throw 'Unsupported or invalid MetaTFT star statistics. Refusing to guess a star target.'
        }
    }
    $selected = @($Tiers | Where-Object { [int]$_.tier -ge 3 -and [double]$_.pcnt -ge 0.20 } |
        Sort-Object { -[int]$_.tier }) | Select-Object -First 1
    if (-not $selected -and $Cost -ge 4) {
        $selected = @($Tiers | Where-Object { [int]$_.tier -eq 2 -and [double]$_.pcnt -ge 0.55 }) | Select-Object -First 1
    }
    return [pscustomobject]@{
        level = if ($selected) { [int]$selected.tier } else { 0 }
        rate = if ($selected) { [double]$selected.pcnt } else { 0.0 }
    }
}

function New-StarTargets {
    param([Parameter(Mandatory = $true)]$Details, [Parameter(Mandatory = $true)][hashtable]$UnitMap)
    $targets = @{}
    foreach ($unit in @($Details.unit_stats)) {
        $cost = if ($UnitMap.ContainsKey([string]$unit.unit)) { [int]$UnitMap[[string]$unit.unit].cost } else { 0 }
        $targets[[string]$unit.unit] = Resolve-TftBoardStarTarget -Tiers @($unit.tiers) -Cost $cost
    }
    return $targets
}
