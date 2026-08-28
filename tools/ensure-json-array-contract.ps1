$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
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
