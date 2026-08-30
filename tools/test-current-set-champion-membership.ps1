$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$catalogPath = Join-Path $PSScriptRoot 'refresh-catalog.ps1'
$gatedPath = Join-Path $PSScriptRoot 'refresh-live-data-gated.ps1'
foreach ($path in @($catalogPath, $gatedPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing source under test: $path" }
}

$catalog = [IO.File]::ReadAllText($catalogPath).Replace("`r`n", "`n")
$gated = [IO.File]::ReadAllText($gatedPath).Replace("`r`n", "`n")

if ($catalog -match '\$playableChampions\s*=\s*@\([\s\S]{0,900}?apiName\s+-match\s+"\^TFT\$\{SetNumber\}_"') {
    throw 'Playable champion selection must not depend on a TFT{SetNumber}_ API-name prefix.'
}
if (-not $catalog.Contains("Get-PropertyValue -Object $_ -Name 'traits'")) {
    throw 'Playable champion selection must access traits through the safe property accessor.'
}
if (-not $catalog.Contains("Get-PropertyValue -Object $champion -Name 'traits'")) {
    throw 'Trait-name flattening must tolerate champion records without a direct traits property.'
}
if (-not $catalog.Contains('$expectedChampionIds = @{}')) {
    throw 'Out-of-set validation must use the actual selected current-set champion IDs.'
}

# The raw-client fallback patch must accept the already-hardened trait flattener;
# otherwise the next genuinely partial CommunityDragon set would fail while
# attempting to enable fallback.
if (-not $gated.Contains('if ($catalogText.Contains($newTraitNames))')) {
    throw 'Raw champion fallback must accept an already-hardened trait-name block.'
}

# Synthetic behavior fixture: current-set membership is data membership, not a
# namespace-prefix guess. DA_18_* is valid for Set 18, while malformed records
# are ignored without StrictMode property errors.
$fixture = @(
    [pscustomobject]@{ apiName='DA_18_Ahri'; cost=4; name='Ahri'; traits=@('Witch') },
    [pscustomobject]@{ apiName='TFT18_Kobuko'; cost=2; name='Kobuko'; traits=@('Brawler') },
    [pscustomobject]@{ apiName='DA_18_NoTraits'; cost=1; name='Broken' },
    [pscustomobject]@{ apiName='DA_18_ZeroCost'; cost=0; name='Internal'; traits=@('Internal') }
)
function Get-SafeProperty($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}
$selected = @(
    $fixture | Where-Object {
        $id = [string](Get-SafeProperty $_ 'apiName')
        $cost = Get-SafeProperty $_ 'cost'
        $name = Get-SafeProperty $_ 'name'
        $traits = Get-SafeProperty $_ 'traits'
        $id -and $null -ne $cost -and [int]$cost -ge 1 -and [int]$cost -le 5 -and $name -and @($traits).Count -gt 0
    }
)
if ($selected.Count -ne 2) { throw "Current-set membership fixture selected $($selected.Count), expected 2." }
if (@($selected.apiName) -notcontains 'DA_18_Ahri') { throw 'DA_18 current-set champion was incorrectly rejected.' }

Write-Output 'Current-set champion membership regression passed.'
