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
# Fail with the site's own integrity diagnostics before copying a broken
# retained-history graph into the synthetic new-set fixture.
& (Join-Path $PSScriptRoot 'validate-site.ps1') -SiteDirectory $sitePath
Copy-Item -Recurse -Force -LiteralPath $sourcePath -Destination $testSource
Copy-Item -Recurse -Force -LiteralPath $sitePath -Destination $testSite

$catalogPath = Join-Path $testSource 'tft/tft_catalog.json'
$metaPath = Join-Path $testSource 'tft_static_snapshot.json'
$sourceManifestPath = Join-Path $testSource 'metadata/DATA_SOURCE_MANIFEST.json'
$catalog = Get-Content -Raw -Encoding UTF8 -LiteralPath $catalogPath | ConvertFrom-Json
$meta = Get-Content -Raw -Encoding UTF8 -LiteralPath $metaPath | ConvertFrom-Json
$sourceManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $sourceManifestPath | ConvertFrom-Json

function Set-VerifiedFixtureManifest {
    param([object]$Document, [string]$SetId, [string]$Patch, [string]$Revision)
    $Document.setId = $SetId
    $Document.patch = $Patch
    $Document.revisionId = $Revision
    $Document | Add-Member -NotePropertyName schemaVersion -NotePropertyValue 2 -Force
    $Document | Add-Member -NotePropertyName coherenceStatus -NotePropertyValue 'VERIFIED' -Force
    $Document | Add-Member -NotePropertyName sourceEvidence -NotePropertyValue ([pscustomobject][ordered]@{
        set = [pscustomobject][ordered]@{ value=$SetId; status='CROSS_SOURCE_VERIFIED' }
        patch = [pscustomobject][ordered]@{ value=$Patch; status='AUTHORITY_VERIFIED' }
        revision = [pscustomobject][ordered]@{ value=$Revision; status='AUTHORITY_VERIFIED' }
    }) -Force
    foreach ($source in @($Document.sources)) {
        $source.setId = $SetId
        $source.patch = $Patch
        $source.revisionId = $Revision
        $source | Add-Member -NotePropertyName hashBasis -NotePropertyValue 'source-response' -Force
        $source | Add-Member -NotePropertyName verdict -NotePropertyValue 'VERIFIED' -Force
        if ([string]$source.responseHash -notmatch '^[0-9a-f]{64}$') { $source.responseHash = 'a' * 64 }
        if ([int]$source.recordCount -lt 1) { $source.recordCount = 1 }
        $native = [ordered]@{}
        $query = [ordered]@{}
        switch ([string]$source.sourceName) {
            'Riot TFT patch notes' { $native.patch=$Patch }
            'CommunityDragon TFT Japanese data' { $native.setId=$SetId }
            'CommunityDragon TFT English data' { $native.setId=$SetId }
            'MetaTFT cluster information' { $native.setId=$SetId; $native.revisionId=$Revision }
            'MetaTFT composition statistics' {
                $native.setId=$SetId; $native.revisionId=$Revision
                $query.patchMode='current'; $query.permitFilterAdjustment='false'
                $query.rank='CHALLENGER,DIAMOND,GRANDMASTER,MASTER'
            }
            'MetaTFT Japanese lookup' { $source.sourceUrl="https://fixture.invalid/lookups/$($SetId)_latest_ja_jp.json" }
            'MetaTFT composition item builds' { $query.revisionId=$Revision }
            'MetaTFT composition details' { $query.revisionId=$Revision }
        }
        $source | Add-Member -NotePropertyName nativeClaims -NotePropertyValue ([pscustomobject]$native) -Force
        $source | Add-Member -NotePropertyName queryClaims -NotePropertyValue ([pscustomobject]$query) -Force
    }
    return $Document
}

# First migrate the legacy fixture to one complete v2 STABLE baseline. Future
# catalog-first sets are allowed only while this verified LKG remains intact.
$baseSetId = [string]$catalog.set.id
$baseRevision = [string]$meta.clusterId
$catalog | Add-Member -NotePropertyName sourceUniverse -NotePropertyValue ([pscustomobject][ordered]@{
    evidenceKind = 'TEST_CURRENT_SET_UNIVERSE'
    setId = $baseSetId
    championIds = @($catalog.champions.id)
    traitIds = @($catalog.traits.id)
    itemIds = @($catalog.items.id)
    augmentIds = @($catalog.augments.id)
}) -Force
$meta | Add-Member -NotePropertyName readiness -NotePropertyValue 'META_STABLE' -Force
$meta.statisticsScope.preferred = 'DIAMOND_PLUS'
$meta.statisticsScope.effective = 'DIAMOND_PLUS'
$meta.statisticsScope.preferredRankFilter = 'CHALLENGER,DIAMOND,GRANDMASTER,MASTER'
$meta.statisticsScope.candidatePoolTarget = @($meta.compositions).Count
foreach ($composition in @($meta.compositions)) {
    $composition.levelBoards = @($composition.levelBoards | Where-Object {
        [string]$_.source -in @('MetaTFT early_options', 'MetaTFT options')
    })
}
$sourceManifest = Set-VerifiedFixtureManifest $sourceManifest $baseSetId ([string]$catalog.set.tftPatch) $baseRevision
[IO.File]::WriteAllText($catalogPath, ($catalog | ConvertTo-Json -Depth 100) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($metaPath, ($meta | ConvertTo-Json -Depth 100) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($sourceManifestPath, ($sourceManifest | ConvertTo-Json -Depth 20) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
$baselineFingerprint = & (Join-Path $PSScriptRoot 'get-content-fingerprint.ps1') -CatalogPath $catalogPath -SnapshotPath $metaPath -AssetRoot $testSource
& (Join-Path $PSScriptRoot 'publish-data-history.ps1') -SiteDirectory $testSite -SourceRoot $testSource -MetaFingerprint $baselineFingerprint -Readiness META_STABLE
$baselineIndex = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $testSite 'data-index.json') | ConvertFrom-Json
if ([string]$baselineIndex.latestVersionId -ne [string]$baselineIndex.latestStableVersionId -or
    [string]$baselineIndex.latestStableVersionId -ne [string]$baselineIndex.latestAvailableVersionId) {
    throw 'Contract migration did not establish one stable baseline.'
}

$newSetId = 'TFT18_DryRun'
$newRevision = 'dryrun-18'
$catalog.set.id = $newSetId
$catalog.set.number = 18
$catalog.set.nameJa = 'Set 18 読み込み検証'
$catalog.set.nameEn = 'Set 18 Readiness Dry Run'
$catalog | Add-Member -NotePropertyName sourceUniverse -NotePropertyValue ([pscustomobject][ordered]@{
    evidenceKind = 'TEST_CURRENT_SET_UNIVERSE'
    setId = $newSetId
    championIds = @($catalog.champions.id)
    traitIds = @($catalog.traits.id)
    itemIds = @($catalog.items.id)
    augmentIds = @($catalog.augments.id)
}) -Force
$meta.schemaVersion = 5
$meta.setId = $newSetId
$meta.clusterId = $newRevision
$meta | Add-Member -NotePropertyName readiness -NotePropertyValue 'META_COLLECTING' -Force
$meta.compositions = @()
$meta.fetchedAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$meta.sourceSummary = 'Dry-run catalog readiness only; no unpublished or PBE data.'
$sourceManifest = Set-VerifiedFixtureManifest $sourceManifest $newSetId ([string]$catalog.set.tftPatch) $newRevision
[IO.File]::WriteAllText($catalogPath, ($catalog | ConvertTo-Json -Depth 100) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($metaPath, ($meta | ConvertTo-Json -Depth 100) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($sourceManifestPath, ($sourceManifest | ConvertTo-Json -Depth 20) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
$changePath = Join-Path $testSource 'metadata/CHANGE_SUMMARY.json'
$change = [ordered]@{ schemaVersion=1; testOnly=$true; classification='NEW_SET'; notice='Synthetic Set 18 readiness dry run.' }
[IO.File]::WriteAllText($changePath, ($change | ConvertTo-Json) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $testSource 'metadata/CHANGE_SUMMARY.md'), "# NEW SET READINESS DRY RUN`n`nSynthetic local fixture only.`n", [Text.UTF8Encoding]::new($false))

$fingerprint = & (Join-Path $PSScriptRoot 'get-content-fingerprint.ps1') -CatalogPath $catalogPath -SnapshotPath $metaPath -AssetRoot $testSource
& (Join-Path $PSScriptRoot 'publish-data-history.ps1') -SiteDirectory $testSite -SourceRoot $testSource -MetaFingerprint $fingerprint -Readiness META_COLLECTING
& (Join-Path $PSScriptRoot 'validate-site.ps1') -SiteDirectory $testSite

$index = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $testSite 'data-index.json') | ConvertFrom-Json
$newVersion = [string]$index.latestAvailableVersionId
$stableVersion = [string]$index.latestStableVersionId
if ([string]$index.latestVersionId -ne $stableVersion) {
    throw 'Legacy latestVersionId did not remain on the formal stable version.'
}
if ($newVersion -eq $stableVersion) {
    throw 'Catalog-first new set incorrectly replaced the formal stable LKG.'
}
$newVersionRecord = @($index.versions | Where-Object id -eq $newVersion | Select-Object -First 1)
if ([string]$newVersionRecord.readiness -ne 'META_COLLECTING' -or [string]$newVersionRecord.releaseState -ne 'PARTIAL') {
    throw 'New set readiness was not preserved in the data index.'
}
$newManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $testSite ([string]$newVersionRecord.manifestUrl)) | ConvertFrom-Json
if ([string]$newManifest.featureReadiness.compositions -ne 'COLLECTING') {
    throw 'Catalog-first new set did not expose compositions as COLLECTING.'
}
$rollback = @($index.versions | Where-Object { [string]$_.setId -ne $newSetId } | Sort-Object generatedAtUtc -Descending | Select-Object -First 1)
if (-not $rollback) { throw 'No prior version available for rollback check.' }
& (Join-Path $PSScriptRoot 'set-latest-version.ps1') -SiteDirectory $testSite -VersionId ([string]$rollback.id)
& (Join-Path $PSScriptRoot 'validate-site.ps1') -SiteDirectory $testSite
$postRollbackIndex = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $testSite 'data-index.json') | ConvertFrom-Json
if ([string]$postRollbackIndex.latestVersionId -ne [string]$rollback.id -or
    [string]$postRollbackIndex.latestStableVersionId -ne [string]$rollback.id -or
    [string]$postRollbackIndex.latestAvailableVersionId -ne [string]$rollback.id) {
    throw 'Rollback did not atomically restore stable and available pointers.'
}
Write-Output "New-set readiness E2E passed: $newVersion remained behind stable $stableVersion, then rollback to $($rollback.id)"
