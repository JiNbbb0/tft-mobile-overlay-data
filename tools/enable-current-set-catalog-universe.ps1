param(
    [string]$CatalogScriptPath = (Join-Path $PSScriptRoot 'refresh-catalog.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$resolvedPath = [IO.Path]::GetFullPath($CatalogScriptPath)
if (-not (Test-Path -LiteralPath $resolvedPath)) {
    throw "Catalog refresh script not found: $resolvedPath"
}

$text = [IO.File]::ReadAllText($resolvedPath)
$moduleAnchor = ". (Join-Path `$PSScriptRoot 'catalog-image-policy.ps1')"
$currentSetModule = ". (Join-Path `$PSScriptRoot 'normalize/Get-CurrentSetUniverse.ps1')"
$emblemModule = ". (Join-Path `$PSScriptRoot 'normalize/Get-EmblemMappings.ps1')"
if (-not $text.Contains($currentSetModule) -or -not $text.Contains($emblemModule)) {
    if (-not $text.Contains($moduleAnchor)) {
        throw 'Could not find catalog module anchor for current-set universe injection.'
    }
    $moduleReplacement = @($moduleAnchor, $currentSetModule, $emblemModule) | Select-Object -Unique
    $text = $text.Replace($moduleAnchor, ($moduleReplacement -join "`n"))
}

$legacyBlock = @'
$setItemIds = @{}
foreach ($id in @($setJa.items)) { $setItemIds[[string]$id] = $true }
$augmentIds = @{}
foreach ($id in @($setJa.augments)) { $augmentIds[[string]$id] = $true }
$candidateItems = @(
    $ja.items |
        Where-Object {
            $setItemIds.ContainsKey([string]$_.apiName) -and
            -not $augmentIds.ContainsKey([string]$_.apiName) -and
            $_.name -and $_.desc -and $_.icon
        } |
        Sort-Object name, apiName
)
'@

$canonicalBlock = @'
$declaredSetItemIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($id in @($setJa.items)) {
    if ($id) { [void]$declaredSetItemIds.Add([string]$id) }
}
$emblemMappingResult = Get-TftEmblemMappings `
    -Traits @($setJa.traits) `
    -Items @($ja.items) `
    -SetNumber $SetNumber
$emblemTraitNameByItemId = @{}
$mappedEmblemIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($mapping in @($emblemMappingResult.mappings)) {
    $emblemId = [string]$mapping.emblemId
    if (-not $emblemId) { continue }
    [void]$mappedEmblemIds.Add($emblemId)
    $emblemTraitNameByItemId[$emblemId] = [string]$mapping.traitName
}
$currentSetUniverse = Get-TftCurrentSetUniverse `
    -SetNumber $SetNumber `
    -SetData $setJa `
    -AllItems @($ja.items) `
    -AdditionalItemIds @($emblemMappingResult.mappings | ForEach-Object { [string]$_.emblemId }) `
    -ExcludedItemIds @($setJa.augments)
$setItemIds = @{}
foreach ($id in @($currentSetUniverse.itemIds)) { $setItemIds[[string]$id] = $true }
$augmentIds = @{}
foreach ($id in @($setJa.augments)) { $augmentIds[[string]$id] = $true }
$candidateItems = @(
    $currentSetUniverse.items |
        Where-Object {
            $id = [string]$_.apiName
            -not $augmentIds.ContainsKey($id) -and
            $_.name -and $_.icon -and ($_.desc -or $mappedEmblemIds.Contains($id))
        } |
        Sort-Object name, apiName
)
$supplementalItemCount = @(
    $currentSetUniverse.itemIds |
        Where-Object { -not $declaredSetItemIds.Contains([string]$_) }
).Count
Write-Output "Current-set item universe: Declared=$($declaredSetItemIds.Count) Included=$(@($currentSetUniverse.itemIds).Count) Supplemental=$supplementalItemCount MappedEmblems=$($mappedEmblemIds.Count) EmblemAmbiguities=$(@($emblemMappingResult.ambiguous).Count) Exclusions=$(@($currentSetUniverse.explicitExclusions).Count) MissingSeeds=$(@($currentSetUniverse.missingSeedIds).Count)"
'@

if (-not $text.Contains('$emblemMappingResult = Get-TftEmblemMappings')) {
    if (-not $text.Contains($legacyBlock)) {
        throw 'Legacy catalog item-universe block was not found; refusing an unsafe partial patch.'
    }
    $text = $text.Replace($legacyBlock, $canonicalBlock)
} elseif (-not $text.Contains('-SetNumber $SetNumber')) {
    # Upgrade an older canonical injection in place. Restrict the replacement to
    # the mapping call so a pre-existing -SetNumber on the universe resolver
    # does not mask missing set scoping on the emblem resolver.
    $oldMappingCall = '$emblemMappingResult = Get-TftEmblemMappings -Traits @($setJa.traits) -Items @($ja.items)'
    if (-not $text.Contains($oldMappingCall)) {
        throw 'Existing emblem mapping call is not recognized; refusing an unsafe partial patch.'
    }
    $newMappingCall = @'
$emblemMappingResult = Get-TftEmblemMappings `
    -Traits @($setJa.traits) `
    -Items @($ja.items) `
    -SetNumber $SetNumber
'@.TrimEnd()
    $text = $text.Replace($oldMappingCall, $newMappingCall)
}

$itemDescriptionAnchor = @'
    $image = Save-Asset -AssetPath ([string]$item.icon) -OwnerId $id -Category "item"
    $items.Add([pscustomobject][ordered]@{
'@
$itemDescriptionReplacement = @'
    $image = Save-Asset -AssetPath ([string]$item.icon) -OwnerId $id -Category "item"
    $itemDescriptionJa = Normalize-Text -Value $item.desc -Effects $item.effects
    if (-not $itemDescriptionJa -and $emblemTraitNameByItemId.ContainsKey($id)) {
        $itemDescriptionJa = "装備者に「$([string]$emblemTraitNameByItemId[$id])」特性を付与する。"
    }
    $items.Add([pscustomobject][ordered]@{
'@
if (-not $text.Contains('$itemDescriptionJa = Normalize-Text -Value $item.desc -Effects $item.effects')) {
    if (-not $text.Contains($itemDescriptionAnchor)) {
        throw 'Catalog item-description anchor was not found; refusing an unsafe partial patch.'
    }
    $text = $text.Replace($itemDescriptionAnchor, $itemDescriptionReplacement)
}

$legacyDescriptionLine = '        descriptionJa = Normalize-Text -Value $item.desc -Effects $item.effects'
$canonicalDescriptionLine = '        descriptionJa = $itemDescriptionJa'
if ($text.Contains($legacyDescriptionLine)) {
    $text = $text.Replace($legacyDescriptionLine, $canonicalDescriptionLine)
}

$requiredPostconditions = @(
    $currentSetModule,
    $emblemModule,
    '$emblemMappingResult = Get-TftEmblemMappings',
    '-Items @($ja.items)',
    '-SetNumber $SetNumber',
    '-AdditionalItemIds @($emblemMappingResult.mappings',
    '$itemDescriptionJa = Normalize-Text -Value $item.desc -Effects $item.effects',
    'descriptionJa = $itemDescriptionJa'
)
foreach ($required in $requiredPostconditions) {
    if (-not $text.Contains($required)) {
        throw "Current-set catalog universe postcondition failed: $required"
    }
}

[IO.File]::WriteAllText(
    $resolvedPath,
    $text.Replace("`r`n", "`n"),
    [Text.UTF8Encoding]::new($false)
)
Write-Output "Current-set catalog universe enabled: $resolvedPath"
