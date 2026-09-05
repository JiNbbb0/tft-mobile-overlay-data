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
foreach ($preflight in @('ensure-json-array-contract.ps1', 'verify-runtime-hardening.ps1')) {
    & pwsh -NoProfile -File (Join-Path $workspace ('tools/' + $preflight))
    if ($LASTEXITCODE -ne 0) { throw "Isolated production preflight failed: $preflight" }
}
& pwsh -NoProfile -File (Join-Path $workspace 'tools/refresh-live-data.ps1') -Force
if ($LASTEXITCODE -ne 0) { throw 'Isolated production refresh failed; public data is unchanged' }
$snapshot = Get-Content -Raw -LiteralPath (Join-Path $workspace 'source/current/tft_static_snapshot.json') | ConvertFrom-Json
if (-not $snapshot.PSObject.Properties['compositionRanks']) { throw 'Production refresh did not generate rank datasets' }
# The real refresh already published and validated this exact immutable ID.
# Do not regenerate metadata and attempt to publish it a second time.
$indexPath = Join-Path $workspace 'site/data-index.json'
$before = (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash
$snapshot.compositionRanks.datasets[0].snapshot.setId = 'INVALID_TEST_SET'
[IO.File]::WriteAllText((Join-Path $workspace 'source/current/tft_static_snapshot.json'),
    ($snapshot | ConvertTo-Json -Depth 40 -Compress), [Text.UTF8Encoding]::new($false))
$rejected = $false
try { & (Join-Path $workspace 'tools/publish-data-history.ps1') } catch { $rejected = $true }
if (-not $rejected -or (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash -ne $before) {
    throw 'Invalid rank modified last-known-good index in the isolated workspace'
}
Write-Output "Mixed-set rejection preserves index=$before"
Write-Output "Rank production dry-run PASS: Ranks=$(@($snapshot.compositionRanks.options).Count); workspace=$workspace; no public publication"
