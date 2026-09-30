$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'published-data-contract.ps1')
$qualityUri = Get-TftPublicDataQualityUri ([uri]'https://fixture.invalid/data/data-index.json?verification=fresh')
if ($qualityUri.AbsoluteUri -cne 'https://fixture.invalid/data/data-quality.json?verification=fresh') { throw 'Quality verification lost its cache-buster.' }
$root = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path $root ('build/published-contract-test-' + [Guid]::NewGuid().ToString('N'))
$site = Join-Path $fixture 'site'
$bundle = Join-Path $site 'bundles/test-version'
function Write-FixtureJson([string]$Path, $Data) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, ($Data | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
}
function Assert-Rejected($Block, [string]$Reason) {
    $rejected=$false
    try { & $Block | Out-Null } catch { $rejected=$true }
    if (-not $rejected) { throw "Expected fail-closed: $Reason" }
}
try {
    $catalogPath=Join-Path $bundle 'files/catalog/tft_catalog.json'
    $snapshotPath=Join-Path $bundle 'files/comps/tft_static_snapshot.json'
    $catalog=[ordered]@{set=@{id='TFTSet20';tftPatch='20.1'};champions=@(@{id='one'});traits=@();items=@();augments=@()}
    $snapshot=[ordered]@{setId='TFTSet20';clusterId='500';fetchedAtUtc='2026-10-01T00:00:00Z';compositions=@();statisticsScope=@{candidatePoolTarget=18;qualifiedEffectiveCompositions=0}}
    Write-FixtureJson $catalogPath $catalog
    Write-FixtureJson $snapshotPath $snapshot
    $entries = @(
        [pscustomobject]@{path='tft/tft_catalog.json';url='files/catalog/tft_catalog.json';sha256=(Get-FileHash $catalogPath).Hash.ToLowerInvariant();bytes=(Get-Item $catalogPath).Length},
        [pscustomobject]@{path='tft_static_snapshot.json';url='files/comps/tft_static_snapshot.json';sha256=(Get-FileHash $snapshotPath).Hash.ToLowerInvariant();bytes=(Get-Item $snapshotPath).Length}
    )
    $manifest=[ordered]@{id='test-version';setId='TFTSet20';patch='20.1';revision='500';files=$entries}
    $manifestPath=Join-Path $bundle 'manifest.json'
    Write-FixtureJson $manifestPath $manifest
    $version=[ordered]@{id='test-version';setId='TFTSet20';setNumber=20;setName='Fixture';patch='20.1';revision='500';manifestUrl='bundles/test-version/manifest.json';manifestSha256=(Get-FileHash $manifestPath).Hash.ToLowerInvariant();sourceTimestampUtc='2026-10-01T00:00:00Z';readiness='META_COLLECTING'}
    $index=[ordered]@{latestVersionId='test-version';generatedAtUtc='2026-10-01T00:00:00Z';versions=@($version)}
    $indexPath=Join-Path $site 'data-index.json'
    Write-FixtureJson $indexPath $index
    $published=Get-TftPublishedDataInputs $site
    if ($published.version.id -ne 'test-version' -or $published.catalog.champions.Count -ne 1) { throw 'Bundle resolution failed.' }
    foreach ($unsafeId in @('..','test..version','.hidden','TEST-VERSION')) {
        $index.latestVersionId=$unsafeId
        $version.id=$unsafeId
        $version.manifestUrl="bundles/$unsafeId/manifest.json"
        Write-FixtureJson $indexPath $index
        Assert-Rejected { Get-TftPublishedDataInputs $site } 'unsafe bundle identity'
    }
    $index.latestVersionId='test-version'
    $version.id='test-version'
    $version.manifestUrl='bundles/test-version/manifest.json'
    Write-FixtureJson $indexPath $index
    & (Join-Path $PSScriptRoot 'write-data-quality-status.ps1') -SiteDirectory $site | Out-Null
    $qualityPath=Join-Path $site 'data-quality.json'
    $oldQuality=Get-Content -Raw -LiteralPath $qualityPath
    $quality=$oldQuality | ConvertFrom-Json
    if ($quality.qualityState -ne 'CATALOG_ONLY' -or [string]$quality.sourceUpdatedAtUtc -notmatch '2026|10/01') { throw 'Catalog-first status failed.' }
    if ($oldQuality -notmatch '2026-10-01T00:00:00Z' -or $quality.payloadSha256.snapshot -cne $entries[1].sha256) { throw 'Timestamp/hash contract failed.' }
    $wrongSource=Join-Path $fixture 'wrong-snapshot.json'
    Write-FixtureJson $wrongSource @{setId='TFTSet20';clusterId='499';compositions=@()}
    Assert-Rejected { & (Join-Path $PSScriptRoot 'write-data-quality-status.ps1') -SiteDirectory $site -SnapshotPath $wrongSource } 'same-set wrong revision workspace'
    if ((Get-Content -Raw -LiteralPath $qualityPath) -cne $oldQuality) { throw 'Failed writer changed existing quality.' }
    $manifest.files[1].url='../../outside.json'
    Write-FixtureJson $manifestPath $manifest
    $version.manifestSha256=(Get-FileHash $manifestPath).Hash.ToLowerInvariant()
    Write-FixtureJson $indexPath $index
    Assert-Rejected { Get-TftPublishedDataInputs $site } 'path traversal'
    $manifest.files[1].url='files/comps/tft_static_snapshot.json'
    $manifest.patch='20.2'
    Write-FixtureJson $manifestPath $manifest
    $version.manifestSha256=(Get-FileHash $manifestPath).Hash.ToLowerInvariant()
    Write-FixtureJson $indexPath $index
    Assert-Rejected { Get-TftPublishedDataInputs $site } 'mixed patch'
    $manifest.patch='20.1'
    Write-FixtureJson $manifestPath $manifest
    $version.manifestSha256=(Get-FileHash $manifestPath).Hash.ToLowerInvariant()
    Write-FixtureJson $indexPath $index
    [IO.File]::AppendAllText($snapshotPath,' ')
    Assert-Rejected { Get-TftPublishedDataInputs $site } 'payload corruption'
} finally { if(Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force } }
Write-Output 'Published data contract PASS: bundle-owned status, UTC, hash, mixed identity, traversal, failure preserves LKG.'
