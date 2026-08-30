param(
    [string]$CatalogPath = (Join-Path $PSScriptRoot '..\source\current\tft\tft_catalog.json'),
    [string]$CommunityDragonUrl = 'https://raw.communitydragon.org/latest/cdragon/tft/ja_jp.json'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'normalize/Get-CurrentSetUniverse.ps1')
. (Join-Path $PSScriptRoot 'normalize/Get-EmblemMappings.ps1')

function Get-LiveJson([string]$Url) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            return (Invoke-RestMethod -Uri $Url -Headers @{ 'User-Agent' = 'TFT-Mobile-Overlay-Data/1.0 current-set-universe-audit' } -TimeoutSec 120)
        } catch {
            if ($attempt -eq 3) { throw }
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}

$resolvedCatalogPath = [IO.Path]::GetFullPath($CatalogPath)
if (-not (Test-Path -LiteralPath $resolvedCatalogPath)) {
    throw "Catalog not found: $resolvedCatalogPath"
}
$catalog = Get-Content -Raw -Encoding UTF8 -LiteralPath $resolvedCatalogPath | ConvertFrom-Json
$setId = [string]$catalog.set.id
$setNumber = [int]$catalog.set.number
if (-not $setId -or $setNumber -le 0) { throw 'Catalog set identity is missing.' }

$live = Get-LiveJson -Url $CommunityDragonUrl
$setDataRows = @($live.setData | Where-Object { [string]$_.mutator -eq $setId } | Select-Object -First 1)
if ($setDataRows.Count -ne 1) { throw "Live CommunityDragon does not contain exactly one setData record for $setId." }
$setData = $setDataRows[0]

$itemById = @{}
foreach ($item in @($live.items)) {
    if ($null -ne $item -and $item.apiName) { $itemById[[string]$item.apiName] = $item }
}
$augmentIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($id in @($setData.augments)) { if ($id) { [void]$augmentIds.Add([string]$id) } }
$declaredIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($id in @($setData.items)) { if ($id) { [void]$declaredIds.Add([string]$id) } }

$emblemMappingResult = Get-TftEmblemMappings -Traits @($setData.traits) -Items @($live.items) -SetNumber $setNumber
$mappedEmblemIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($mapping in @($emblemMappingResult.mappings)) {
    if ($mapping.emblemId) { [void]$mappedEmblemIds.Add([string]$mapping.emblemId) }
}
if ($mappedEmblemIds.Count -eq 0) {
    throw "No validated trait-to-emblem mappings were recovered for live set $setId."
}

$result = Get-TftCurrentSetUniverse `
    -SetNumber $setNumber `
    -SetData $setData `
    -AllItems @($live.items) `
    -AdditionalItemIds @($emblemMappingResult.mappings | ForEach-Object { [string]$_.emblemId }) `
    -ExcludedItemIds @($setData.augments)

$includedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($id in @($result.itemIds)) { if ($id) { [void]$includedIds.Add([string]$id) } }

$augmentLeaks = @($includedIds | Where-Object { $augmentIds.Contains([string]$_) })
if ($augmentLeaks.Count -gt 0) {
    throw "Augment IDs leaked into the item universe: $($augmentLeaks -join ', ')"
}

$otherSetLeaks = @(
    $includedIds | Where-Object {
        $sourceSet = Get-TftExplicitItemSetNumber -Id ([string]$_)
        $null -ne $sourceSet -and [int]$sourceSet -ne $setNumber -and -not (Test-TftSharedItemFamily -Id ([string]$_))
    }
)
if ($otherSetLeaks.Count -gt 0) {
    throw "Other-set non-shared items leaked into the current universe: $($otherSetLeaks -join ', ')"
}

$missingMappedEmblems = @($mappedEmblemIds | Where-Object { -not $includedIds.Contains([string]$_) })
if ($missingMappedEmblems.Count -gt 0) {
    throw "Validated mapped emblems were not included: $($missingMappedEmblems -join ', ')"
}

$mappedDisplayFailures = [Collections.Generic.List[string]]::new()
$mappedWithoutSourceDescription = [Collections.Generic.List[string]]::new()
foreach ($emblemIdValue in $mappedEmblemIds) {
    $emblemId = [string]$emblemIdValue
    if (-not $itemById.ContainsKey($emblemId)) {
        $mappedDisplayFailures.Add("${emblemId}:missing-source-record")
        continue
    }
    $item = $itemById[$emblemId]
    if (-not $item.name -or -not $item.icon) {
        $mappedDisplayFailures.Add("${emblemId}:missing-name-or-icon")
        continue
    }
    if (-not $item.desc) { $mappedWithoutSourceDescription.Add($emblemId) }
}
if ($mappedDisplayFailures.Count -gt 0) {
    throw "Mapped emblem display contract failed: $($mappedDisplayFailures -join ', ')"
}

$candidateIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($item in @($result.items)) {
    if ($null -eq $item -or -not $item.apiName) { continue }
    $id = [string]$item.apiName
    if ($augmentIds.Contains($id)) { continue }
    if (-not $item.name -or -not $item.icon) { continue }
    if (-not $item.desc -and -not $mappedEmblemIds.Contains($id)) { continue }
    [void]$candidateIds.Add($id)
}

$missingMappedCandidates = @($mappedEmblemIds | Where-Object { -not $candidateIds.Contains([string]$_) })
if ($missingMappedCandidates.Count -gt 0) {
    throw "Validated mapped emblems would be dropped by catalog candidate filtering: $($missingMappedCandidates -join ', ')"
}

$mappedOutsideDeclared = @($mappedEmblemIds | Where-Object { -not $declaredIds.Contains([string]$_) })
$missingSupplementalMapped = @(
    $mappedOutsideDeclared | Where-Object {
        -not $includedIds.Contains([string]$_) -or -not $candidateIds.Contains([string]$_)
    }
)
if ($missingSupplementalMapped.Count -gt 0) {
    throw "Supplemental mapped emblems were not recovered as catalog candidates: $($missingSupplementalMapped -join ', ')"
}

$ambiguousIds = @(
    @($emblemMappingResult.ambiguous) |
        ForEach-Object { @($_.candidateIds) } |
        ForEach-Object { $_ } |
        Where-Object { $_ } |
        Sort-Object -Unique
)

Write-Output "Live current-set universe audit passed: Set=$setId Number=$setNumber Declared=$($declaredIds.Count) Included=$($includedIds.Count) CatalogCandidates=$($candidateIds.Count) MappedEmblems=$($mappedEmblemIds.Count) SupplementalMappedEmblems=$($mappedOutsideDeclared.Count) MappedWithoutSourceDesc=$($mappedWithoutSourceDescription.Count) EmblemAmbiguities=$(@($emblemMappingResult.ambiguous).Count) AmbiguousCandidateIds=$($ambiguousIds.Count) AugmentLeaks=0 OtherSetLeaks=0"
