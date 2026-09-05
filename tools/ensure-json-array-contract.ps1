$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$repairFlag = Join-Path $repositoryRoot "build/force-json-contract-repair.flag"
if (Test-Path -LiteralPath $repairFlag) { Remove-Item -Force -LiteralPath $repairFlag }
$currentSnapshotPath = Join-Path $repositoryRoot "source/current/tft_static_snapshot.json"
if (Test-Path -LiteralPath $currentSnapshotPath) {
    $currentRaw = [IO.File]::ReadAllText($currentSnapshotPath)
    if ($currentRaw -match '"compositions"\s*:\s*null') {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $repairFlag) | Out-Null
        [IO.File]::WriteAllText($repairFlag, "repair`n", [Text.UTF8Encoding]::new($false))
        Write-Warning "Tracked latest metadata contains compositions:null; one forced publication is required for Android compatibility."
    }
}

# Android's org.json getJSONArray() rejects JSON null. During catalog-first
# publication, empty collections must therefore be emitted as [] rather than null.
$metaPath = Join-Path $PSScriptRoot "refresh-static-meta.ps1"
$metaText = [IO.File]::ReadAllText($metaPath).Replace("`r`n", "`n")
$metaReplacements = [ordered]@{
    '    augments = $augments' = '    augments = @($augments)'
    '    compositions = $compositions' = '    compositions = @($compositions)'
}
$metaChanged = $false
foreach ($entry in $metaReplacements.GetEnumerator()) {
    $old = [string]$entry.Key
    $new = [string]$entry.Value
    if ($metaText.Contains($new)) { continue }
    if (-not $metaText.Contains($old)) {
        throw "Could not enforce JSON array contract; expected generator line not found: $old"
    }
    $metaText = $metaText.Replace($old, $new)
    $metaChanged = $true
}
if ($metaChanged) {
    Write-Utf8NoBom -Path $metaPath -Text $metaText
    Write-Output "Patched static-meta generator so empty collections serialize as JSON arrays."
} else {
    Write-Output "Static-meta generator already preserves JSON array collections."
}

# New-set statistics can arrive before comp-specific augment tiers. Do not let
# that optional metadata suppress otherwise valid composition candidates while
# catalog-first partial mode is active; recommendedAugments can legitimately be [].
$metaText = [IO.File]::ReadAllText($metaPath).Replace("`r`n", "`n")
$oldAugmentGate = @'
    if (-not $compAugmentTiers.results.PSObject.Properties[$clusterId]) {
        continue
    }
'@
$newAugmentGate = @'
    if (-not $compAugmentTiers.results.PSObject.Properties[$clusterId] -and -not $AllowPartial) {
        continue
    }
'@
if ($metaText.Contains($newAugmentGate)) {
    Write-Output "Partial composition candidate policy already patched."
} elseif ($metaText.Contains($oldAugmentGate)) {
    $metaText = $metaText.Replace($oldAugmentGate, $newAugmentGate)
    Write-Utf8NoBom -Path $metaPath -Text $metaText
    Write-Output "Patched partial composition policy so missing augment tiers do not hide valid comps."
} elseif (
    $metaText.Contains('$compAugmentProperty = $compAugmentTiers.results.PSObject.Properties[[string]$composition.id]') -and
    $metaText.Contains('preserving the source result without generic padding')
) {
    # The hardened generator no longer gates composition candidates on optional
    # augment metadata. It resolves the property only while building each
    # composition and publishes an empty source-backed list when unavailable.
    Write-Output "Partial composition candidate policy is implemented by optional per-composition augment lookup."
} else {
    throw "Could not patch partial composition candidate policy in refresh-static-meta.ps1"
}

# MetaTFT/CommunityDragon may expose current-set standard item IDs under DA_*
# while the local catalog uses canonical TFT_Item_* IDs. Normalize all comp item
# references before publication so app lookups, images, and validation use the
# same canonical ID namespace.
$metaText = [IO.File]::ReadAllText($metaPath).Replace("`r`n", "`n")
$oldItemMapBlock = @'
$itemMap = @{}
foreach ($item in $communityDragon.items) {
    if ($item.apiName -and $item.name) {
        $itemMap[[string]$item.apiName] = $item
    }
}
'@
$newItemMapBlock = @'
$itemMap = @{}
foreach ($item in $communityDragon.items) {
    if ($item.apiName -and $item.name) {
        $itemMap[[string]$item.apiName] = $item
    }
}

$catalogPathForItemIds = Join-Path $RepositoryRoot 'source/current/tft/tft_catalog.json'
$catalogForItemIds = Get-Content -Raw -Encoding UTF8 -LiteralPath $catalogPathForItemIds | ConvertFrom-Json
$catalogItemIds = @{}
$catalogItemIdByLooseKey = @{}
$catalogItemIdByName = @{}
foreach ($catalogItem in @($catalogForItemIds.items)) {
    $catalogItemId = [string]$catalogItem.id
    if (-not $catalogItemId) { continue }
    $catalogItemIds[$catalogItemId] = $true
    $looseKey = ($catalogItemId -replace '^(?:TFT\d*_Item_|TFT_Item_|DA_)', '').ToLowerInvariant()
    if ($looseKey -and -not $catalogItemIdByLooseKey.ContainsKey($looseKey)) {
        $catalogItemIdByLooseKey[$looseKey] = $catalogItemId
    }
    foreach ($catalogName in @([string]$catalogItem.nameJa, [string]$catalogItem.nameEn)) {
        $nameKey = $catalogName.Trim().ToLowerInvariant()
        if ($nameKey -and -not $catalogItemIdByName.ContainsKey($nameKey)) {
            $catalogItemIdByName[$nameKey] = $catalogItemId
        }
    }
}
function Resolve-CatalogItemId {
    param([Parameter(Mandatory = $true)][string]$ItemId)
    if ($catalogItemIds.ContainsKey($ItemId)) { return $ItemId }
    $looseKey = ($ItemId -replace '^(?:TFT\d*_Item_|TFT_Item_|DA_)', '').ToLowerInvariant()
    if ($looseKey -and $catalogItemIdByLooseKey.ContainsKey($looseKey)) {
        return [string]$catalogItemIdByLooseKey[$looseKey]
    }
    if ($itemMap.ContainsKey($ItemId)) {
        $sourceName = [string]$itemMap[$ItemId].name
        $nameKey = $sourceName.Trim().ToLowerInvariant()
        if ($nameKey -and $catalogItemIdByName.ContainsKey($nameKey)) {
            return [string]$catalogItemIdByName[$nameKey]
        }
    }
    return $ItemId
}
foreach ($sourceItemIdValue in @($itemMap.Keys)) {
    $sourceItemId = [string]$sourceItemIdValue
    $canonicalItemId = Resolve-CatalogItemId -ItemId $sourceItemId
    if ($canonicalItemId -ne $sourceItemId -and -not $itemMap.ContainsKey($canonicalItemId)) {
        $itemMap[$canonicalItemId] = $itemMap[$sourceItemId]
    }
}
'@
if (
    $metaText.Contains('$canonicalItemIndex = New-TftCanonicalIdIndex -Entries @($canonicalCatalog.items)') -and
    $metaText.Contains('function Resolve-CanonicalPublicationItemId')
) {
    Write-Output "MetaTFT item IDs use the fail-closed canonical publication resolver."
} elseif ($metaText.Contains($newItemMapBlock)) {
    Write-Output "MetaTFT item ID canonicalization already patched."
} elseif ($metaText.Contains($oldItemMapBlock)) {
    $metaText = $metaText.Replace($oldItemMapBlock, $newItemMapBlock)
    Write-Utf8NoBom -Path $metaPath -Text $metaText
    Write-Output "Patched MetaTFT item IDs to resolve against the canonical catalog."
} else {
    throw "Could not patch item ID canonicalization block in refresh-static-meta.ps1"
}

$metaText = [IO.File]::ReadAllText($metaPath).Replace("`r`n", "`n")
$oldFullBuildIds = @'
            $fullBuildItemIds = @(
                @($build.buildName) |
                    Where-Object { $_ -and $itemMap.ContainsKey([string]$_) } |
                    ForEach-Object { [string]$_ }
            )
'@
$newFullBuildIds = @'
            $fullBuildItemIds = @(
                @($build.buildName) |
                    Where-Object { $_ } |
                    ForEach-Object { Resolve-CatalogItemId -ItemId ([string]$_) } |
                    Where-Object { $_ -and $catalogItemIds.ContainsKey([string]$_) -and $itemMap.ContainsKey([string]$_) }
            )
'@
if ($metaText.Contains($newFullBuildIds)) {
    Write-Output "Composition item-stat IDs already canonicalized."
} elseif ($metaText.Contains($oldFullBuildIds)) {
    $metaText = $metaText.Replace($oldFullBuildIds, $newFullBuildIds)
    Write-Utf8NoBom -Path $metaPath -Text $metaText
    Write-Output "Patched composition item-stat IDs to canonical catalog IDs."
} elseif (
    $metaText.Contains('ForEach-Object { Resolve-CanonicalPublicationItemId -RawId ([string]$_) }') -and
    $metaText.Contains('AMBIGUOUS_CANONICAL_ITEM_ID') -and
    $metaText.Contains('UNRESOLVED_CANONICAL_ITEM_ID')
) {
    Write-Output "Composition item-stat IDs use the fail-closed canonical publication resolver."
} else {
    throw "Could not patch composition item-stat ID normalization in refresh-static-meta.ps1"
}

$metaText = [IO.File]::ReadAllText($metaPath).Replace("`r`n", "`n")
$oldRecommendedBuild = @'
        $recommendedBuild = @(
            if ($overviewBuildRow.Count -gt 0) {
                @($overviewBuildRow[0].buildName) |
                    Where-Object { $_ -and $itemMap.ContainsKey([string]$_) } |
                    ForEach-Object {
                        [pscustomobject][ordered]@{
                            itemId = [string]$_
                            itemName = [string]$itemMap[[string]$_].name
                        }
                    }
            }
        )
'@
$newRecommendedBuild = @'
        $recommendedBuild = @(
            if ($overviewBuildRow.Count -gt 0) {
                @($overviewBuildRow[0].buildName) |
                    Where-Object { $_ } |
                    ForEach-Object { Resolve-CatalogItemId -ItemId ([string]$_) } |
                    Where-Object { $_ -and $catalogItemIds.ContainsKey([string]$_) -and $itemMap.ContainsKey([string]$_) } |
                    ForEach-Object {
                        [pscustomobject][ordered]@{
                            itemId = [string]$_
                            itemName = [string]$itemMap[[string]$_].name
                        }
                    }
            }
        )
'@
if ($metaText.Contains($newRecommendedBuild)) {
    Write-Output "Recommended overview item IDs already canonicalized."
} elseif ($metaText.Contains($oldRecommendedBuild)) {
    $metaText = $metaText.Replace($oldRecommendedBuild, $newRecommendedBuild)
    Write-Utf8NoBom -Path $metaPath -Text $metaText
    Write-Output "Patched recommended overview item IDs to canonical catalog IDs."
} elseif (
    $metaText.Contains('$canonicalItemId = Resolve-CanonicalPublicationItemId -RawId ([string]$_)') -and
    $metaText.Contains('itemName = [string]$canonicalItemMap[$canonicalItemId].nameJa')
) {
    Write-Output "Recommended overview item IDs use the fail-closed canonical publication resolver."
} else {
    throw "Could not patch recommended overview item ID normalization in refresh-static-meta.ps1"
}

# A full list of 18 compositions is not META_STABLE if the upstream source has
# not published composition-specific augment recommendations yet. Keep the
# snapshot in META_COLLECTING so clients can use comps while quality gates remain.
$metaText = [IO.File]::ReadAllText($metaPath).Replace("`r`n", "`n")
$oldReadiness = @'
$readiness = if (@($compositions).Count -eq 0) {
    'META_COLLECTING'
} elseif (@($compositions).Count -lt $requiredPreferredCompositions) {
    'META_COLLECTING'
} else {
    'META_STABLE'
}
'@
$newReadiness = @'
$hasIncompleteCompositionMetadata = @(
    @($compositions) | Where-Object { @($_.recommendedAugments).Count -eq 0 }
).Count -gt 0
$readiness = if (@($compositions).Count -eq 0) {
    'META_COLLECTING'
} elseif (@($compositions).Count -lt $requiredPreferredCompositions) {
    'META_COLLECTING'
} elseif ($hasIncompleteCompositionMetadata) {
    'META_COLLECTING'
} else {
    'META_STABLE'
}
'@
if ($metaText.Contains($newReadiness)) {
    Write-Output "Composition metadata readiness policy already patched."
} elseif ($metaText.Contains($oldReadiness)) {
    $metaText = $metaText.Replace($oldReadiness, $newReadiness)
    Write-Utf8NoBom -Path $metaPath -Text $metaText
    Write-Output "Patched readiness so missing comp augment metadata remains META_COLLECTING."
} else {
    throw "Could not patch composition metadata readiness policy in refresh-static-meta.ps1"
}

# Validation must accept empty comp-specific augment recommendations only while
# the new set is explicitly in partial readiness. All other composition fields
# remain fully validated, and META_STABLE still requires augment recommendations.
$validatorPath = Join-Path $PSScriptRoot "validate-static-meta.ps1"
$validatorText = [IO.File]::ReadAllText($validatorPath).Replace("`r`n", "`n")
$oldAugmentValidation = '    if ($recommendedAugments.Count -eq 0) { throw "No recommended augments: $($composition.id)" }'
$newAugmentValidation = '    if ($recommendedAugments.Count -eq 0 -and -not $isPartial) { throw "No recommended augments: $($composition.id)" }'
if ($validatorText.Contains($newAugmentValidation)) {
    Write-Output "Partial augment validation policy already patched."
} elseif ($validatorText.Contains($oldAugmentValidation)) {
    $validatorText = $validatorText.Replace($oldAugmentValidation, $newAugmentValidation)
    Write-Utf8NoBom -Path $validatorPath -Text $validatorText
    Write-Output "Patched validator to accept missing comp augment recommendations during partial readiness."
} else {
    throw "Could not patch partial augment validation policy in validate-static-meta.ps1"
}

# Once a new set has been published in CATALOG_READY/META_COLLECTING state it is
# no longer technically a never-published set, but statistics can still be absent.
# Keep AllowPartial enabled until that set actually reaches META_STABLE.
$livePath = Join-Path $PSScriptRoot "refresh-live-data.ps1"
$liveText = [IO.File]::ReadAllText($livePath).Replace("`r`n", "`n")
$oldPolicy = @'
    $isNewSet = -not $existingSetVersion
    if ($isNewSet) {
        & (Join-Path $PSScriptRoot "refresh-static-meta.ps1") -AllowPartial
    } else {
        & (Join-Path $PSScriptRoot "refresh-static-meta.ps1")
    }
'@
$newPolicy = @'
    $existingSetVersionRecord = @($existingSetVersion) | Select-Object -First 1
    $isNewSet = -not $existingSetVersionRecord
    $existingSetReadiness = if ($existingSetVersionRecord -and $existingSetVersionRecord.PSObject.Properties['readiness']) {
        [string]$existingSetVersionRecord.readiness
    } else {
        ''
    }
    $allowPartial = $isNewSet -or $existingSetReadiness -in @('CATALOG_READY', 'META_COLLECTING')
    if ($allowPartial) {
        & (Join-Path $PSScriptRoot "refresh-static-meta.ps1") -AllowPartial
    } else {
        & (Join-Path $PSScriptRoot "refresh-static-meta.ps1")
    }
'@
$rankedPolicy = $newPolicy.Replace('refresh-static-meta.ps1', 'refresh-ranked-compositions.ps1')
if ($liveText.Contains($newPolicy) -or $liveText.Contains($rankedPolicy)) {
    Write-Output "Catalog-first continuation policy already patched."
} elseif ($liveText.Contains($oldPolicy)) {
    $liveText = $liveText.Replace($oldPolicy, $newPolicy)
    Write-Utf8NoBom -Path $livePath -Text $liveText
    Write-Output "Patched catalog-first policy to continue until metadata is stable."
} else {
    throw "Could not patch catalog-first continuation policy in refresh-live-data.ps1"
}
