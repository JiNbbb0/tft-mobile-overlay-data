param([string]$SnapshotPath = 'build/rank-live/tft_static_snapshot.json')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$snapshotFile = if ([IO.Path]::IsPathRooted($SnapshotPath)) { $SnapshotPath } else { Join-Path $root $SnapshotPath }
if (-not (Test-Path -LiteralPath $snapshotFile)) { throw 'Generate live rank snapshot before this integration test' }
$workspace = Join-Path $root ('build/rank-publication-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workspace -Force | Out-Null
$source = Join-Path $workspace 'source'
$site = Join-Path $workspace 'site'
Copy-Item -LiteralPath (Join-Path $root 'source/current') -Destination $source -Recurse
Copy-Item -LiteralPath (Join-Path $root 'site') -Destination $site -Recurse
Copy-Item -LiteralPath $snapshotFile -Destination (Join-Path $source 'tft_static_snapshot.json')
& (Join-Path $PSScriptRoot 'new-data-source-manifest.ps1') -SourceRoot $source -OutputPath (Join-Path $source 'metadata/DATA_SOURCE_MANIFEST.json')
& (Join-Path $PSScriptRoot 'new-change-summary.ps1') -SourceRoot $source -SiteDirectory $site -OutputDirectory (Join-Path $source 'metadata')
$fingerprint = & (Join-Path $PSScriptRoot 'get-content-fingerprint.ps1') -SnapshotPath (Join-Path $source 'tft_static_snapshot.json') -CatalogPath (Join-Path $source 'tft/tft_catalog.json') -AssetRoot $source
& (Join-Path $PSScriptRoot 'publish-data-history.ps1') -SourceRoot $source -SiteDirectory $site -MetaFingerprint $fingerprint
& (Join-Path $PSScriptRoot 'validate-site.ps1') -SiteDirectory $site
$indexFile = Join-Path $site 'data-index.json'
$before = (Get-FileHash -LiteralPath $indexFile -Algorithm SHA256).Hash
$invalid = Get-Content -Raw -LiteralPath (Join-Path $source 'tft_static_snapshot.json') | ConvertFrom-Json
$invalid.compositionRanks.datasets[0].snapshot.setId = 'TFTSet999'
[IO.File]::WriteAllText((Join-Path $source 'tft_static_snapshot.json'), ($invalid | ConvertTo-Json -Depth 40 -Compress), [Text.UTF8Encoding]::new($false))
$rejected = $false
try { & (Join-Path $PSScriptRoot 'publish-data-history.ps1') -SourceRoot $source -SiteDirectory $site } catch { $rejected = $true }
if (-not $rejected -or (Get-FileHash -LiteralPath $indexFile -Algorithm SHA256).Hash -ne $before) { throw 'Invalid rank modified last-known-good index' }
Write-Output "Rank publication integration PASS: local site=$site; mixed-set rejection preserves index=$before"
