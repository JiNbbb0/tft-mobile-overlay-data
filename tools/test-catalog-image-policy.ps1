$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'catalog-image-policy.ps1')

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$fixtureRoot = Join-Path $repositoryRoot 'build/catalog-image-policy-fixture'
if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -Recurse -Force -LiteralPath $fixtureRoot }
New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
foreach ($name in @('active.png','shared.png','old-set.png')) {
    [IO.File]::WriteAllBytes((Join-Path $fixtureRoot $name), [byte[]](137,80,78,71,13,10,26,10))
}
$removed = @(Remove-UnreferencedCatalogImages -ImageRoot $fixtureRoot -ReferencedImagePaths @(
    'tft/images/active.png', 'tft/images/shared.png'
))
if ($removed.Count -ne 1 -or $removed[0] -ne 'old-set.png') { throw 'Unexpected prune result.' }
if (-not (Test-Path (Join-Path $fixtureRoot 'active.png')) -or -not (Test-Path (Join-Path $fixtureRoot 'shared.png'))) {
    throw 'A referenced image was removed.'
}
if (Test-Path (Join-Path $fixtureRoot 'old-set.png')) { throw 'The old-set image was not removed.' }
Write-Output 'Catalog image prune fixture passed.'
