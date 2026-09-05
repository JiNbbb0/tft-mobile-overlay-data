$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$workspace = [IO.Path]::GetFullPath((Join-Path $root ('build/rank-production-' + [guid]::NewGuid().ToString('N'))))
if (-not $workspace.StartsWith((Join-Path $root 'build') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Dry-run workspace escaped the repository build directory'
}
New-Item -ItemType Directory -Path $workspace -Force | Out-Null
# Run the REAL production acquisition path in a new workspace. No .git,
# credentials, or earlier source-observation/evidence cache is copied.
foreach ($directory in @('tools', 'schema', 'config', 'source', 'site')) {
    Copy-Item -LiteralPath (Join-Path $root $directory) -Destination (Join-Path $workspace $directory) -Recurse
}
& pwsh -NoProfile -File (Join-Path $workspace 'tools/refresh-live-data.ps1') -Force
if ($LASTEXITCODE -ne 0) { throw 'Isolated production refresh failed; public data is unchanged' }
$snapshot = Get-Content -Raw -LiteralPath (Join-Path $workspace 'source/current/tft_static_snapshot.json') | ConvertFrom-Json
if (-not $snapshot.PSObject.Properties['compositionRanks']) { throw 'Production refresh did not generate rank datasets' }
& pwsh -NoProfile -File (Join-Path $workspace 'tools/test-ranked-publication.ps1') -SnapshotPath 'source/current/tft_static_snapshot.json'
if ($LASTEXITCODE -ne 0) { throw 'Isolated publication/LKG regression failed; public data is unchanged' }
Write-Output "Rank production dry-run PASS: Ranks=$(@($snapshot.compositionRanks.options).Count); workspace=$workspace; no public publication"
