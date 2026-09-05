$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path $root ('build/report-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workspace | Out-Null
$snapshotPath = Join-Path $workspace 'snapshot.json'
$outputPath = Join-Path $workspace 'report.json'
$snapshot = [ordered]@{
    setId='TFTFutureSet'; clusterId='future-revision'; statsUpdatedEpochMs=0
    statisticsScope=@{effective='DIAMOND_PLUS'}; compositions=@(); readiness='CATALOG_READY'
}
foreach ($readiness in @('CATALOG_READY','META_COLLECTING')) {
    $snapshot.readiness=$readiness
    [IO.File]::WriteAllText($snapshotPath, ($snapshot | ConvertTo-Json -Depth 5))
    & (Join-Path $root '.github/scripts/report-current-compositions.ps1') -SnapshotPath $snapshotPath -OutputPath $outputPath
    $report=Get-Content -Raw $outputPath | ConvertFrom-Json
    if ($report.compositionState -ne 'COLLECTING' -or @($report.compositions).Count -ne 0 -or $report.clusterId -ne 'future-revision') {
        throw 'Catalog-first report misrepresented missing statistics'
    }
}
$snapshot.readiness='META_STABLE'
[IO.File]::WriteAllText($snapshotPath, ($snapshot | ConvertTo-Json -Depth 5))
$rejected=$false
try { & (Join-Path $root '.github/scripts/report-current-compositions.ps1') -SnapshotPath $snapshotPath -OutputPath $outputPath } catch { $rejected=$true }
if (-not $rejected) { throw 'Empty stable data must still be rejected' }
Write-Output 'Composition report PASS: catalog-first allowed explicitly; empty stable rejected; revision treated as identity'
