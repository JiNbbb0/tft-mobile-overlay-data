param([string]$RepositoryRootOverride = "")

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$RepositoryRoot = if ($RepositoryRootOverride) { [IO.Path]::GetFullPath($RepositoryRootOverride) } else { Split-Path -Parent $PSScriptRoot }
$AssetRoot = Join-Path $RepositoryRoot "source/current"
$CatalogPath = Join-Path $AssetRoot "tft/tft_catalog.json"

$raw = [IO.File]::ReadAllText($CatalogPath, [Text.Encoding]::UTF8)
$catalog = $raw | ConvertFrom-Json
if ([int]$catalog.schemaVersion -ne 1) { throw "Unsupported catalog schema" }

$groups = @($catalog.champions), @($catalog.traits), @($catalog.items), @($catalog.augments)
$records = @($catalog.champions) + @($catalog.traits) + @($catalog.items) + @($catalog.augments)
$ids = @{}
foreach ($record in $records) {
    if (-not $record.id -or -not $record.nameJa) { throw "Missing required id/name" }
    if ($ids.ContainsKey([string]$record.id)) { throw "Duplicate id: $($record.id)" }
    $ids[[string]$record.id] = $true
    if (-not $record.image) { throw "Missing image reference: $($record.id)" }
    $imagePath = Join-Path $AssetRoot ([string]$record.image -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $imagePath)) { throw "Missing image file: $($record.image)" }
    $bytes = [IO.File]::ReadAllBytes($imagePath)
    if ($bytes.Length -lt 8 -or $bytes[0] -ne 137 -or $bytes[1] -ne 80 -or $bytes[2] -ne 78 -or $bytes[3] -ne 71) {
        throw "Invalid PNG: $($record.image)"
    }
}

function Assert-JsonArrayProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Record,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $property = $Record.PSObject.Properties[$Name]
    if (-not $property -or $null -eq $property.Value -or $property.Value -isnot [Array]) {
        throw "Catalog array contract violated: $($Record.id).$Name"
    }
}
foreach ($champion in @($catalog.champions)) { Assert-JsonArrayProperty -Record $champion -Name 'traits' }
foreach ($trait in @($catalog.traits)) {
    Assert-JsonArrayProperty -Record $trait -Name 'activationLevels'
    Assert-JsonArrayProperty -Record $trait -Name 'championIds'
}
foreach ($item in @($catalog.items)) {
    Assert-JsonArrayProperty -Record $item -Name 'recipe'
    if (-not $item.restrictions) { throw "Catalog restrictions missing: $($item.id)" }
    Assert-JsonArrayProperty -Record $item.restrictions -Name 'composition'
    Assert-JsonArrayProperty -Record $item.restrictions -Name 'incompatibleTraits'
}
foreach ($augment in @($catalog.augments)) {
    Assert-JsonArrayProperty -Record $augment -Name 'associatedTraits'
    Assert-JsonArrayProperty -Record $augment -Name 'associatedChampionIds'
    Assert-JsonArrayProperty -Record $augment -Name 'associatedItemIds'
}

$unresolvedAbilities = @(
    $catalog.champions | Where-Object {
        -not $_.ability.descriptionJa -or
        [string]$_.ability.descriptionJa -match '@[^@]+@|未取得|%i:|\{\{'
    }
)
if ($unresolvedAbilities.Count -gt 0) {
    throw "Unresolved champion ability values: $($unresolvedAbilities.id -join ', ')"
}
foreach ($champion in @($catalog.champions)) {
    if (-not $champion.ability.valuesSource) { throw "Missing ability value source: $($champion.id)" }
}

$unresolvedText = @()
foreach ($record in $records) {
    $description = if ($record.PSObject.Properties['ability']) {
        [string]$record.ability.descriptionJa
    } elseif ($record.PSObject.Properties['descriptionJa']) {
        [string]$record.descriptionJa
    } else { '' }
    $name = [string]$record.nameJa
    if ("$name`n$description" -match '@[^@]+@|%i:|\{\{|未取得|\d+\.\d{5,}|NaN|Infinity') {
        $unresolvedText += [string]$record.id
    }
}
if ($unresolvedText.Count -gt 0) {
    throw "Unresolved or imprecise catalog text: $($unresolvedText -join ', ')"
}

$itemIds = @{}
foreach ($item in @($catalog.items)) { $itemIds[[string]$item.id] = $true }
foreach ($item in @($catalog.items)) {
    foreach ($recipeId in @($item.recipe)) {
        if ($recipeId -and -not $itemIds.ContainsKey([string]$recipeId)) { throw "Invalid recipe reference: $($item.id) -> $recipeId" }
    }
}

if ($raw.Contains([char]0xFFFD)) { throw "Unicode replacement character detected" }
Write-Output "OFFLINE CATALOG VALIDATION PASSED"
Write-Output "Set=$($catalog.set.id) Patch=$($catalog.set.tftPatch)"
Write-Output "Champions=$(@($catalog.champions).Count) Traits=$(@($catalog.traits).Count) Items=$(@($catalog.items).Count) Augments=$(@($catalog.augments).Count)"
Write-Output "Records=$($records.Count) UniqueIds=$($ids.Count)"
Write-Output "Champion ability placeholders=0"
Write-Output "Catalog text placeholders and precision leaks=0"
