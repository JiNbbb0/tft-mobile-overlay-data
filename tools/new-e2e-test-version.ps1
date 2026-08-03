param(
    [string]$SiteDirectory = "site"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$currentRoot = Join-Path $repositoryRoot "source/current"
$testRoot = Join-Path $repositoryRoot "build/e2e-source"
if (Test-Path -LiteralPath $testRoot) { Remove-Item -Recurse -Force -LiteralPath $testRoot }
Copy-Item -Recurse -Force -LiteralPath $currentRoot -Destination $testRoot

$metaPath = Join-Path $testRoot "tft_static_snapshot.json"
$meta = Get-Content -Raw -Encoding UTF8 -LiteralPath $metaPath | ConvertFrom-Json
$originalRevision = [int]$meta.clusterId
$testRevision = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$meta.clusterId = $testRevision
$meta.fetchedAtUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
$meta.sourceSummary = "E2E TEST - " + [string]$meta.sourceSummary
$firstComposition = @($meta.compositions) | Select-Object -First 1
if (-not $firstComposition) { throw "Cannot create E2E version without compositions" }
$originalName = [string]$firstComposition.name
$testMarker = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("44CQ5pu05paw44OG44K544OI44CR"))
$firstComposition.name = "$originalName $testMarker"
[IO.File]::WriteAllText($metaPath, ($meta | ConvertTo-Json -Depth 100) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

$sourceManifestPath = Join-Path $testRoot "metadata/DATA_SOURCE_MANIFEST.json"
$sourceManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $sourceManifestPath | ConvertFrom-Json
$sourceManifest.revisionId = [string]$testRevision
$sourceManifest.generatedAt = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
foreach ($source in @($sourceManifest.sources)) { $source.revisionId = [string]$testRevision }
[IO.File]::WriteAllText($sourceManifestPath, ($sourceManifest | ConvertTo-Json -Depth 20) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

$summary = [ordered]@{
    schemaVersion = 1
    generatedAt = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    classification = "B_PATCH"
    testOnly = $true
    notice = "Temporary safe E2E revision. It must not remain latest after verification."
    originalRevision = [string]$originalRevision
    testRevision = [string]$testRevision
    displayChange = [ordered]@{ compositionId = [string]$firstComposition.id; before = $originalName; after = [string]$firstComposition.name }
}
$summaryJsonPath = Join-Path $testRoot "metadata/CHANGE_SUMMARY.json"
[IO.File]::WriteAllText($summaryJsonPath, ($summary | ConvertTo-Json -Depth 10) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
$summaryMarkdown = "# E2E TEST CHANGE SUMMARY`n`n- Test only: yes`n- Original revision: $originalRevision`n- Test revision: $testRevision`n- Safe display change: $originalName -> $($firstComposition.name)`n"
[IO.File]::WriteAllText((Join-Path $testRoot "metadata/CHANGE_SUMMARY.md"), $summaryMarkdown, [Text.UTF8Encoding]::new($false))

& (Join-Path $PSScriptRoot "publish-data-history.ps1") -SiteDirectory $SiteDirectory -SourceRoot "build/e2e-source"
$versionId = (("{0}-{1}-r{2}" -f [string]$meta.setId,[string](Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $testRoot "tft/tft_catalog.json") | ConvertFrom-Json).set.tftPatch,$testRevision).ToLowerInvariant() -replace '[^a-z0-9._-]','-')
$siteRoot = if ([IO.Path]::IsPathRooted($SiteDirectory)) { [IO.Path]::GetFullPath($SiteDirectory) } else { [IO.Path]::GetFullPath((Join-Path $repositoryRoot $SiteDirectory)) }
$manifestPath = Join-Path $siteRoot "bundles/$versionId/manifest.json"
$manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
$manifest | Add-Member -NotePropertyName testOnly -NotePropertyValue $true -Force
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 20) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
$indexPath = Join-Path $siteRoot "data-index.json"
$index = Get-Content -Raw -Encoding UTF8 -LiteralPath $indexPath | ConvertFrom-Json
$indexEntry = @($index.versions | Where-Object { [string]$_.id -eq $versionId }) | Select-Object -First 1
if (-not $indexEntry) { throw "Published E2E version is missing from data-index: $versionId" }
$indexEntry | Add-Member -NotePropertyName testOnly -NotePropertyValue $true -Force
[IO.File]::WriteAllText($indexPath, ($index | ConvertTo-Json -Depth 8) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
& (Join-Path $PSScriptRoot "validate-site.ps1") -SiteDirectory $SiteDirectory
Write-Output "E2E_VERSION_ID=$versionId"
Write-Output "E2E_BASELINE_REVISION=$originalRevision"
