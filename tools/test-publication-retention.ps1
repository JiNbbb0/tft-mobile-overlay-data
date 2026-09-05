$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path $root ('build/retention-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workspace | Out-Null
foreach ($directory in @('tools','schema','config','source','site')) {
    Copy-Item -LiteralPath (Join-Path $root $directory) -Destination (Join-Path $workspace $directory) -Recurse
}
$site = Join-Path $workspace 'site'
$indexPath = Join-Path $site 'data-index.json'
$original = Get-Content -Raw -LiteralPath $indexPath | ConvertFrom-Json
$originalHashes = @{}
foreach ($version in $original.versions) {
    $originalHashes[[string]$version.id] = (Get-FileHash -LiteralPath (Join-Path $site $version.manifestUrl) -Algorithm SHA256).Hash
}
& (Join-Path $workspace 'tools/publish-data-history.ps1') -MetaFingerprint ('8' * 64)
$index = Get-Content -Raw -LiteralPath $indexPath | ConvertFrom-Json
if (@($index.versions).Count -gt 5) { throw 'Publisher exceeded five-version window' }
if ($original.latestAvailableVersionId -notin @($index.versions.id)) { throw 'Publisher lost immediate rollback version' }
if ($index.latestStableVersionId -notin @($index.versions.id)) { throw 'Publisher lost stable LKG' }
foreach ($version in $index.versions) {
    if ($originalHashes.ContainsKey([string]$version.id) -and
        (Get-FileHash -LiteralPath (Join-Path $site $version.manifestUrl) -Algorithm SHA256).Hash -ne $originalHashes[[string]$version.id]) {
        throw 'Retention modified a retained immutable manifest'
    }
}
$bundles = @(Get-ChildItem -LiteralPath (Join-Path $site 'bundles') -Directory)
if ($bundles.Count -ne @($index.versions).Count) { throw 'Retired bundle remains in live directory' }
$referenced = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($version in $index.versions) {
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $site $version.manifestUrl) | ConvertFrom-Json
    foreach ($file in $manifest.files) {
        if ([string]$file.url -match '^\.\./\.\./blobs/(.+)$') { [void]$referenced.Add($Matches[1]) }
    }
}
foreach ($blob in Get-ChildItem -LiteralPath (Join-Path $site 'blobs') -File) {
    if (-not $referenced.Contains($blob.Name)) { throw 'Unreferenced image survived retention' }
}
& (Join-Path $workspace 'tools/validate-site.ps1')
$beforeFailure = (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash
# Force failure at the final candidate gate AFTER staged pruning. The public
# directory must remain unchanged, including every retained payload byte.
$beforeFiles = @{}
foreach ($file in Get-ChildItem -LiteralPath $site -File -Recurse) {
    $beforeFiles[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
}
[IO.File]::WriteAllText((Join-Path $workspace 'tools/validate-site.ps1'), "throw 'INJECTED_CANDIDATE_GATE_FAILURE'")
$rejected=$false
try { & (Join-Path $workspace 'tools/publish-data-history.ps1') -MetaFingerprint ('9' * 64) } catch {
    if ($_.Exception.Message -notmatch 'INJECTED_CANDIDATE_GATE_FAILURE') { throw }
    $rejected=$true
}
if (-not $rejected -or (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash -ne $beforeFailure) { throw 'Failed pruning candidate changed live index' }
foreach ($path in $beforeFiles.Keys) {
    if (-not (Test-Path -LiteralPath $path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $beforeFiles[$path]) {
        throw 'Failed candidate removed or modified live data'
    }
}
Write-Output "Publication retention PASS: five versions, protected LKG, immutable survivors, orphan cleanup, failed candidate preserves ALL live files."
