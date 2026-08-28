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
'@
    [IO.File]::WriteAllText($fixturePath, $fixture, [Text.UTF8Encoding]::new($false))

    & (Join-Path $PSScriptRoot 'enable-current-set-catalog-universe.ps1') -CatalogScriptPath $fixturePath

    $patched = [IO.File]::ReadAllText($fixturePath)
    if (-not $patched.Contains("normalize/Get-CurrentSetUniverse.ps1")) {
        throw 'Current-set universe module was not injected.'
    }
    if (-not $patched.Contains('$currentSetUniverse = Get-TftCurrentSetUniverse')) {
        throw 'Canonical item-universe block was not injected.'
    }
    if (-not $patched.Contains('-ExcludedItemIds @($setJa.augments)')) {
        throw 'Augment exclusions were not wired into catalog item discovery.'
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
