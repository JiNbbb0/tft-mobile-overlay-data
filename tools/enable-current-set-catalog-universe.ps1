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
$moduleLine = ". (Join-Path `$PSScriptRoot 'normalize/Get-CurrentSetUniverse.ps1')"
if (-not $text.Contains($moduleLine)) {
    if (-not $text.Contains($moduleAnchor)) {
        throw 'Could not find catalog module anchor for current-set universe injection.'
    }
    $text = $text.Replace($moduleAnchor, "$moduleAnchor`n$moduleLine")
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
$currentSetUniverse = Get-TftCurrentSetUniverse `
    -SetNumber $SetNumber `
    -SetData $setJa `
    -AllItems @($ja.items) `
    -ExcludedItemIds @($setJa.augments)
$setItemIds = @{}
foreach ($id in @($currentSetUniverse.itemIds)) { $setItemIds[[string]$id] = $true }
$augmentIds = @{}
foreach ($id in @($setJa.augments)) { $augmentIds[[string]$id] = $true }
$candidateItems = @(
    $currentSetUniverse.items |
        Where-Object {
            -not $augmentIds.ContainsKey([string]$_.apiName) -and
            $_.name -and $_.desc -and $_.icon
        } |
        Sort-Object name, apiName
)
$supplementalItemCount = @(
    $currentSetUniverse.itemIds |
        Where-Object { -not $declaredSetItemIds.Contains([string]$_) }
).Count
Write-Output "Current-set item universe: Declared=$($declaredSetItemIds.Count) Included=$(@($currentSetUniverse.itemIds).Count) Supplemental=$supplementalItemCount Exclusions=$(@($currentSetUniverse.explicitExclusions).Count) MissingSeeds=$(@($currentSetUniverse.missingSeedIds).Count)"
'@

if (-not $text.Contains('$currentSetUniverse = Get-TftCurrentSetUniverse')) {
    if (-not $text.Contains($legacyBlock)) {
        throw 'Legacy catalog item-universe block was not found; refusing an unsafe partial patch.'
    }
    $text = $text.Replace($legacyBlock, $canonicalBlock)
}

if (-not $text.Contains($moduleLine) -or -not $text.Contains('$currentSetUniverse = Get-TftCurrentSetUniverse')) {
    throw 'Current-set catalog universe postcondition failed.'
}

[IO.File]::WriteAllText(
    $resolvedPath,
    $text.Replace("`r`n", "`n"),
    [Text.UTF8Encoding]::new($false)
)
Write-Output "Current-set catalog universe enabled: $resolvedPath"
