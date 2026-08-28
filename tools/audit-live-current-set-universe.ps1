param(
    [string]$CatalogPath = (Join-Path $PSScriptRoot '..\source\current\tft\tft_catalog.json'),
    [string]$CommunityDragonUrl = 'https://raw.communitydragon.org/latest/cdragon/tft/ja_jp.json'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'normalize/Get-CurrentSetUniverse.ps1')

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
$setData = @($live.setData | Where-Object { [string]$_.mutator -eq $setId } | Select-Object -First 1)
if ($setData.Count -ne 1) { throw "Live CommunityDragon does not contain exactly one setData record for $setId." }
$setData = $setData[0]

$result = Get-TftCurrentSetUniverse `
    -SetNumber $setNumber `
    -SetData $setData `
    -AllItems @($live.items) `
    -ExcludedItemIds @($setData.augments)

$augmentIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($id in @($setData.augments)) { if ($id) { [void]$augmentIds.Add([string]$id) } }
$declaredIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($id in @($setData.items)) { if ($id) { [void]$declaredIds.Add([string]$id) } }

$includedItems = @($result.items)
$includedIds = @($result.itemIds | ForEach-Object { [string]$_ })
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

$invalidDisplayItems = @(
    $includedItems | Where-Object {
        -not $_.apiName -or -not $_.name -or -not $_.desc -or -not $_.icon
    }
)
if ($invalidDisplayItems.Count -gt 0) {
    throw "Current-set universe contains items without id/name/desc/icon: $(@($invalidDisplayItems | ForEach-Object { [string]$_.apiName }) -join ', ')"
}

$supplemental = @($includedItems | Where-Object { -not $declaredIds.Contains([string]$_.apiName) })
$explicitCurrentSetSupplemental = @(
    $supplemental | Where-Object {
        $sourceSet = Get-TftExplicitItemSetNumber -Id ([string]$_.apiName)
        $null -ne $sourceSet -and [int]$sourceSet -eq $setNumber
    }
)
$emblems = @(
    $includedItems | Where-Object {
        ([string]$_.name -match '紋章') -or ([string]$_.apiName -match '(?i)Emblem')
    }
)
$explicitCurrentSetEmblems = @(
    $emblems | Where-Object {
        $sourceSet = Get-TftExplicitItemSetNumber -Id ([string]$_.apiName)
        $null -ne $sourceSet -and [int]$sourceSet -eq $setNumber
    }
)

# Modern sets rely on explicit current-set items that may be absent from setData.items.
# If the live source exposes such items, the canonical universe must discover them.
$liveExplicitCandidates = @(
    @($live.items) | Where-Object {
        if (-not $_.apiName) { return $false }
        if ($augmentIds.Contains([string]$_.apiName)) { return $false }
        if (Test-TftInternalItem -Item $_) { return $false }
        $sourceSet = Get-TftExplicitItemSetNumber -Id ([string]$_.apiName)
        return $null -ne $sourceSet -and [int]$sourceSet -eq $setNumber
    }
)
$missingExplicitCandidates = @(
    $liveExplicitCandidates | Where-Object { $includedIds -notcontains [string]$_.apiName }
)
if ($missingExplicitCandidates.Count -gt 0) {
    throw "Explicit current-set items were not discovered: $(@($missingExplicitCandidates | ForEach-Object { [string]$_.apiName }) -join ', ')"
}

if ($liveExplicitCandidates.Count -gt 0 -and $explicitCurrentSetSupplemental.Count -eq 0) {
    throw "Live $setId exposes explicit current-set items, but none were recovered outside setData.items."
}
if (@($liveExplicitCandidates | Where-Object { ([string]$_.name -match '紋章') -or ([string]$_.apiName -match '(?i)Emblem') }).Count -gt 0 -and $explicitCurrentSetEmblems.Count -eq 0) {
    throw "Live $setId exposes explicit current-set emblems, but the canonical universe recovered none."
}

Write-Output "Live current-set universe audit passed: Set=$setId Number=$setNumber Declared=$($declaredIds.Count) Included=$($includedIds.Count) Supplemental=$($supplemental.Count) ExplicitSupplemental=$($explicitCurrentSetSupplemental.Count) Emblems=$($emblems.Count) ExplicitEmblems=$($explicitCurrentSetEmblems.Count) AugmentLeaks=0 OtherSetLeaks=0"
