param(
    [string]$SourceRoot = 'source/current',
    [string]$SiteDirectory = 'site'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$sourcePath = Join-Path $repositoryRoot $SourceRoot
$sitePath = Join-Path $repositoryRoot $SiteDirectory
$testSource = Join-Path $repositoryRoot 'build/new-set-readiness-source'
$testSite = Join-Path $repositoryRoot 'build/new-set-readiness-site'

foreach ($path in @($testSource, $testSite)) {
    if (Test-Path -LiteralPath $path) { Remove-Item -Recurse -Force -LiteralPath $path }
}
Copy-Item -Recurse -Force -LiteralPath $sourcePath -Destination $testSource
Copy-Item -Recurse -Force -LiteralPath $sitePath -Destination $testSite

$catalogPath = Join-Path $testSource 'tft/tft_catalog.json'
$metaPath = Join-Path $testSource 'tft_static_snapshot.json'
$catalog = Get-Content -Raw -Encoding UTF8 -LiteralPath $catalogPath | ConvertFrom-Json
$meta = Get-Content -Raw -Encoding UTF8 -LiteralPath $metaPath | ConvertFrom-Json
$newSetId = 'TFT18_DryRun'
$newRevision = 'dryrun-18'
$catalog.set.id = $newSetId
$catalog.set.number = 18
$catalog.set.nameJa = 'Set 18 読み込み検証'
$catalog.set.nameEn = 'Set 18 Readiness Dry Run'
$meta.schemaVersion = 5
$meta.setId = $newSetId
$meta.clusterId = $newRevision
$meta | Add-Member -NotePropertyName readiness -NotePropertyValue 'META_COLLECTING' -Force
$meta.compositions = @()
$meta.fetchedAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$meta.sourceSummary = 'Dry-run catalog readiness only; no unpublished or PBE data.'
[IO.File]::WriteAllText($catalogPath, ($catalog | ConvertTo-Json -Depth 100) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($metaPath, ($meta | ConvertTo-Json -Depth 100) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

$sourceManifestPath = Join-Path $testSource 'metadata/DATA_SOURCE_MANIFEST.json'
$sourceManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $sourceManifestPath | ConvertFrom-Json
$sourceManifest.setId = $newSetId
$sourceManifest.revisionId = $newRevision
[IO.File]::WriteAllText($sourceManifestPath, ($sourceManifest | ConvertTo-Json -Depth 20) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
$changePath = Join-Path $testSource 'metadata/CHANGE_SUMMARY.json'
$change = [ordered]@{ schemaVersion=1; testOnly=$true; classification='NEW_SET'; notice='Synthetic Set 18 readiness dry run.' }
[IO.File]::WriteAllText($changePath, ($change | ConvertTo-Json) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $testSource 'metadata/CHANGE_SUMMARY.md'), "# NEW SET READINESS DRY RUN`n`nSynthetic local fixture only.`n", [Text.UTF8Encoding]::new($false))

$fingerprint = & (Join-Path $PSScriptRoot 'get-meta-fingerprint.ps1') -SnapshotPath $metaPath
& (Join-Path $PSScriptRoot 'publish-data-history.ps1') -SiteDirectory $testSite -SourceRoot $testSource -MetaFingerprint $fingerprint -Readiness META_COLLECTING
& (Join-Path $PSScriptRoot 'validate-site.ps1') -SiteDirectory $testSite

$index = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $testSite 'data-index.json') | ConvertFrom-Json
$newVersion = [string]$index.latestVersionId
if ([string](@($index.versions | Where-Object id -eq $newVersion | Select-Object -First 1).readiness) -ne 'META_COLLECTING') {
    throw 'New set readiness was not preserved in the data index.'
}
$rollback = @($index.versions | Where-Object { [string]$_.setId -ne $newSetId } | Sort-Object generatedAtUtc -Descending | Select-Object -First 1)
if (-not $rollback) { throw 'No prior version available for rollback check.' }
& (Join-Path $PSScriptRoot 'set-latest-version.ps1') -SiteDirectory $testSite -VersionId ([string]$rollback.id)
& (Join-Path $PSScriptRoot 'validate-site.ps1') -SiteDirectory $testSite
Write-Output "New-set readiness E2E passed: $newVersion then rollback to $($rollback.id)"
