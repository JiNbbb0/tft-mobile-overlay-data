$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("tft-catalog-integration-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
try {
    $fixturePath = Join-Path $tempRoot 'refresh-catalog.ps1'
    $fixture = @'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'catalog-image-policy.ps1')

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

$items = [Collections.Generic.List[object]]::new()
foreach ($item in $candidateItems) {
    $id = [string]$item.apiName
    $image = Save-Asset -AssetPath ([string]$item.icon) -OwnerId $id -Category "item"
    $items.Add([pscustomobject][ordered]@{
        id = $id
        descriptionJa = Normalize-Text -Value $item.desc -Effects $item.effects
    })
}
'@
    [IO.File]::WriteAllText($fixturePath, $fixture, [Text.UTF8Encoding]::new($false))

    & (Join-Path $PSScriptRoot 'enable-current-set-catalog-universe.ps1') -CatalogScriptPath $fixturePath

    $patched = [IO.File]::ReadAllText($fixturePath)
    if (-not $patched.Contains("normalize/Get-CurrentSetUniverse.ps1")) {
        throw 'Current-set universe module was not injected.'
    }
    if (-not $patched.Contains("normalize/Get-EmblemMappings.ps1")) {
        throw 'Emblem mapping module was not injected.'
    }
    if (-not $patched.Contains('$emblemMappingResult = Get-TftEmblemMappings')) {
        throw 'Trait-to-emblem resolver was not wired into catalog discovery.'
    }
    if (-not $patched.Contains('-AdditionalItemIds @($emblemMappingResult.mappings')) {
        throw 'Mapped emblem IDs were not supplied as validated supplemental seeds.'
    }
    if (-not $patched.Contains('-ExcludedItemIds @($setJa.augments)')) {
        throw 'Augment exclusions were not wired into catalog item discovery.'
    }
    if (-not $patched.Contains('$mappedEmblemIds.Contains($id)')) {
        throw 'Mapped emblems without CommunityDragon descriptions would still be discarded.'
    }
    if (-not $patched.Contains('$itemDescriptionJa = "装備者に「$([string]$emblemTraitNameByItemId[$id])」特性を付与する。"')) {
        throw 'Mapped emblem description fallback was not injected.'
    }
    if (-not $patched.Contains('descriptionJa = $itemDescriptionJa')) {
        throw 'Catalog item output does not use the normalized/fallback description.'
    }
    if ($patched.Contains('$ja.items |' + "`n" + '        Where-Object {' + "`n" + '            $setItemIds.ContainsKey')) {
        throw 'Legacy candidate-item scan survived the integration patch.'
    }

    $firstHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fixturePath).Hash
    & (Join-Path $PSScriptRoot 'enable-current-set-catalog-universe.ps1') -CatalogScriptPath $fixturePath
    $secondHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fixturePath).Hash
    if ($firstHash -ne $secondHash) {
        throw 'Catalog universe patcher is not idempotent.'
    }

    Write-Output 'Current-set catalog integration regression passed.'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
