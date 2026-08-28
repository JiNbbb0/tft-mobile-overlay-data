$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'normalize/Get-CurrentSetUniverse.ps1')
. (Join-Path $PSScriptRoot 'normalize/Get-EmblemMappings.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Contains([object[]]$Values, [string]$Expected, [string]$Message) {
    if (-not (@($Values | ForEach-Object { [string]$_ }) -contains $Expected)) {
        throw "$Message: $Expected"
    }
}
function Assert-NotContains([object[]]$Values, [string]$Unexpected, [string]$Message) {
    if (@($Values | ForEach-Object { [string]$_ }) -contains $Unexpected) {
        throw "$Message: $Unexpected"
    }
}
function Assert-JsonArrayProperty($Object, [string]$Name, [string]$Context) {
    $property = $Object.PSObject.Properties[$Name]
    if (-not $property) { throw "$Context missing array property: $Name" }
    if ($null -eq $property.Value) { throw "$Context array property is null: $Name" }
    if ($property.Value -is [string] -or $property.Value -isnot [Collections.IEnumerable]) {
        throw "$Context property is not array-like: $Name"
    }
}

$fixtureRoot = Join-Path $PSScriptRoot '..\test\fixtures\golden'
$fixturePaths = @(
    Join-Path $fixtureRoot 'set17.json',
    Join-Path $fixtureRoot 'set18.json',
    Join-Path $fixtureRoot 'future-set19.json'
)

$seenSetNumbers = [Collections.Generic.HashSet[int]]::new()
$seenSetIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($fixturePath in $fixturePaths) {
    if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) { throw "Golden fixture missing: $fixturePath" }
    $fixture = Get-Content -Raw -Encoding UTF8 -LiteralPath $fixturePath | ConvertFrom-Json
    $setId = [string]$fixture.setId
    $setNumber = [int]$fixture.setNumber
    Assert-True ($setId -and $setNumber -gt 0) "Golden fixture identity missing: $fixturePath"
    Assert-True ($seenSetIds.Add($setId)) "Duplicate golden setId: $setId"
    Assert-True ($seenSetNumbers.Add($setNumber)) "Duplicate golden setNumber: $setNumber"

    Assert-JsonArrayProperty $fixture 'traits' $setId
    Assert-JsonArrayProperty $fixture 'items' $setId
    Assert-JsonArrayProperty $fixture.setData 'items' "$setId.setData"
    Assert-JsonArrayProperty $fixture.setData 'augments' "$setId.setData"
    Assert-JsonArrayProperty $fixture.expect 'included' "$setId.expect"
    Assert-JsonArrayProperty $fixture.expect 'excluded' "$setId.expect"

    $result = Get-TftCurrentSetUniverse `
        -SetNumber $setNumber `
        -SetData $fixture.setData `
        -AllItems @($fixture.items) `
        -ExcludedItemIds @($fixture.setData.augments)

    foreach ($id in @($fixture.expect.included)) {
        Assert-Contains $result.itemIds ([string]$id) "$setId expected current/shared item missing"
    }
    foreach ($id in @($fixture.expect.excluded)) {
        Assert-NotContains $result.itemIds ([string]$id) "$setId excluded/cross-set item leaked"
    }

    $mappings = Get-TftEmblemMappings -Traits @($fixture.traits) -Items @($fixture.items)
    $expectedTraitId = [string]$fixture.expect.emblemTraitId
    $expectedEmblemId = [string]$fixture.expect.emblemItemId
    $mapping = @($mappings.mappings | Where-Object { [string]$_.traitId -eq $expectedTraitId }) | Select-Object -First 1
    Assert-True ($null -ne $mapping) "$setId expected emblem mapping missing: $expectedTraitId"
    Assert-True ([string]$mapping.emblemId -eq $expectedEmblemId) "$setId emblem mapping mismatch. Expected=$expectedEmblemId Actual=$($mapping.emblemId)"
}

Assert-True ($seenSetNumbers.Contains(17)) 'Set17 golden coverage missing.'
Assert-True ($seenSetNumbers.Contains(18)) 'Set18 golden coverage missing.'
Assert-True ($seenSetNumbers.Contains(19)) 'Future Set19 golden coverage missing.'

# Explicitly prove future-set handling is data-driven rather than hard-coded to Set18.
$futureFixture = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $fixtureRoot 'future-set19.json') | ConvertFrom-Json
$futureResult = Get-TftCurrentSetUniverse `
    -SetNumber 19 `
    -SetData $futureFixture.setData `
    -AllItems @($futureFixture.items) `
    -ExcludedItemIds @($futureFixture.setData.augments)
Assert-Contains $futureResult.itemIds 'TFT19_Item_CurrentMechanic' 'Future-set explicit TFT19 identity should be discovered'
Assert-Contains $futureResult.itemIds 'DA_19_ForestEmblem' 'Future-set explicit DA_19 emblem should be discovered'
Assert-NotContains $futureResult.itemIds 'DA_18_MechanicConsumable' 'Set18-specific item must not leak into future Set19'

Write-Output 'Set17/Set18/future-Set golden regressions passed.'
