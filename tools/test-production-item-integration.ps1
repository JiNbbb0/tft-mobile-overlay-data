$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$productionPath = Join-Path $PSScriptRoot 'refresh-static-meta.ps1'
$text = [IO.File]::ReadAllText($productionPath).Replace("`r`n", "`n")

foreach ($required in @(
    "id-compatibility-policy.ps1",
    'New-TftCanonicalIdIndex -Entries @($canonicalCatalog.items)',
    'Resolve-CanonicalPublicationItemId',
    "status -in @('EXACT','ALIAS','NAME')",
    'AMBIGUOUS_CANONICAL_ITEM_ID',
    'UNRESOLVED_CANONICAL_ITEM_ID',
    'itemName = [string]$canonicalItemMap[$itemId].nameJa'
)) {
    if (-not $text.Contains($required)) { throw "Production canonical item integration missing: $required" }
}

foreach ($forbidden in @(
    'Where-Object { $_ -and $itemMap.ContainsKey([string]$_) }'
)) {
    if ($text.Contains($forbidden)) { throw "Production still silently drops unresolved MetaTFT items: $forbidden" }
}

$tokens = $null
$errors = $null
[void][Management.Automation.Language.Parser]::ParseFile($productionPath, [ref]$tokens, [ref]$errors)
if (@($errors).Count -gt 0) {
    throw "Production item integration has parser errors: $(@($errors | ForEach-Object Message) -join '; ')"
}

Write-Output 'Production canonical item integration regression passed.'
