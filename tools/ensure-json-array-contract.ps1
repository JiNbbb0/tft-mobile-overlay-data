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
} else {
    throw "Could not patch partial composition candidate policy in refresh-static-meta.ps1"
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
if ($liveText.Contains($newPolicy)) {
    Write-Output "Catalog-first continuation policy already patched."
} elseif ($liveText.Contains($oldPolicy)) {
    $liveText = $liveText.Replace($oldPolicy, $newPolicy)
    Write-Utf8NoBom -Path $livePath -Text $liveText
    Write-Output "Patched catalog-first policy to continue until metadata is stable."
} else {
    throw "Could not patch catalog-first continuation policy in refresh-live-data.ps1"
}
