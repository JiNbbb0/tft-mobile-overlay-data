$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'statistics-scope-contract.ps1')

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$snapshotPath = Join-Path $repositoryRoot 'source/current/tft_static_snapshot.json'
$snapshot = Get-Content -Raw -Encoding UTF8 -LiteralPath $snapshotPath | ConvertFrom-Json
$stats = $snapshot.catalogStatistics
$scope = Get-TftStatisticsScopeContract

if (-not $stats) { throw 'Catalog statistics are required.' }
if ([string]$stats.scope.patch -ne 'current' -or [int]$stats.scope.days -ne 3) {
    throw 'Catalog statistics must use current patch and three-day window.'
}
if ([string]$stats.scope.rank -ne [string]$scope.preferredRankFilter -or [string]$stats.scope.displayRank -ne [string]$scope.displayName) {
    throw 'Catalog statistics rank scope drifted from the Diamond+ contract.'
}

foreach ($category in @('units', 'items', 'traits')) {
    $records = @($stats.$category)
    if ($records.Count -eq 0) { throw "Catalog statistics category is empty: $category" }
    $ids = @($records | ForEach-Object { [string]$_.id })
    if (@($ids | Group-Object | Where-Object Count -gt 1).Count -gt 0) { throw "Duplicate catalog statistics IDs: $category" }
    foreach ($record in $records) {
        if ([string]::IsNullOrWhiteSpace([string]$record.id)) { throw "Empty catalog statistics ID: $category" }
        if ([string]$record.tier -notin @('S','A','B','C','D')) { throw "Invalid MetaTFT tier: $category/$($record.id)" }
        if ([double]$record.averagePlacement -lt 1 -or [double]$record.averagePlacement -gt 8) { throw "Invalid average placement: $category/$($record.id)" }
        foreach ($rateName in @('winRate','topFourRate','frequency')) {
            if ([double]$record.$rateName -lt 0) { throw "Invalid $rateName`: $category/$($record.id)" }
        }
        if ([int64]$record.sampleCount -le 0) { throw "Invalid sample count: $category/$($record.id)" }
    }
}

$publishedItemIds = @($stats.items | ForEach-Object { [string]$_.id })
$excludedItemIds = @($stats.excludedUnresolvableItemIds | ForEach-Object { [string]$_ })
if (@($publishedItemIds | Where-Object { $_ -in $excludedItemIds }).Count -gt 0) {
    throw 'An unresolved MetaTFT item was published instead of failing closed.'
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("tft-catalog-statistics-contract-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
try {
    $changedPath = Join-Path $temporaryRoot 'changed.json'
    $originalFingerprint = & (Join-Path $PSScriptRoot 'get-meta-fingerprint.ps1') -SnapshotPath $snapshotPath
    $snapshot.catalogStatistics.units[0].averagePlacement = [double]$snapshot.catalogStatistics.units[0].averagePlacement + 0.001
    [IO.File]::WriteAllText($changedPath, (($snapshot | ConvertTo-Json -Depth 100).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    $changedFingerprint = & (Join-Path $PSScriptRoot 'get-meta-fingerprint.ps1') -SnapshotPath $changedPath
    if ($originalFingerprint -eq $changedFingerprint) { throw 'Catalog statistic changes must change the publication fingerprint.' }
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -Recurse -Force -LiteralPath $temporaryRoot }
}

Write-Output "Catalog statistics contract: PASS Units=$(@($stats.units).Count) Items=$(@($stats.items).Count) Traits=$(@($stats.traits).Count) Scope=$($stats.scope.displayRank)"
