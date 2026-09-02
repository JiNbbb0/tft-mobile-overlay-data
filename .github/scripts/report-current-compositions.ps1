param(
    [string]$SnapshotPath = 'source/current/tft_static_snapshot.json',
    [string]$OutputPath = 'build/current-compositions.json'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
function Resolve-RepoPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

$snapshotFile = Resolve-RepoPath $SnapshotPath
$outputFile = Resolve-RepoPath $OutputPath
if (-not (Test-Path -LiteralPath $snapshotFile -PathType Leaf)) { throw "Composition snapshot missing: $snapshotFile" }
$snapshot = Get-Content -Raw -Encoding UTF8 -LiteralPath $snapshotFile | ConvertFrom-Json
$comps = @($snapshot.compositions | Where-Object { $_ -is [pscustomobject] })
if ($comps.Count -eq 0) { throw 'Composition snapshot contains no published compositions.' }

$previousAverage = 0.0
$rows = [Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt $comps.Count; $i++) {
    $comp = $comps[$i]
    $average = [double]$comp.averagePlacement
    if ($average -lt 1.0 -or $average -gt 8.0) { throw "Invalid average placement for $($comp.id): $average" }
    if ($i -gt 0 -and $average -lt ($previousAverage - 0.00001)) {
        throw "Composition order is not Avg Placement ascending at rank $($i + 1): $average < $previousAverage"
    }
    $previousAverage = $average
    $rows.Add([pscustomobject][ordered]@{
        rank = $i + 1
        id = [string]$comp.id
        nameJa = [string]$comp.displayNameJa
        tier = [string]$comp.tier
        averagePlacement = [Math]::Round($average, 4)
        sampleCount = [int]$comp.sampleCount
    })
}

$outputDirectory = Split-Path -Parent $outputFile
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$report = [pscustomobject][ordered]@{
    schemaVersion = 1
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    sourceUpdatedEpochMs = [int64]$snapshot.statsUpdatedEpochMs
    setId = [string]$snapshot.setId
    clusterId = [int]$snapshot.clusterId
    rankScope = if ($snapshot.statisticsScope.PSObject.Properties['effective']) { [string]$snapshot.statisticsScope.effective } else { '' }
    sort = 'Avg Placement ASC'
    compositions = @($rows.ToArray())
}
[IO.File]::WriteAllText($outputFile, (($report | ConvertTo-Json -Depth 10).Replace("`r`n","`n") + "`n"), [Text.UTF8Encoding]::new($false))

Write-Output "Current MetaTFT-parity composition ordering: Set=$($report.setId) Cluster=$($report.clusterId) Scope=$($report.rankScope) Count=$($rows.Count)"
foreach ($row in $rows) {
    Write-Output ("#{0:D2} | {1} | {2} | Avg={3:N4} | N={4} | ID={5}" -f $row.rank, $row.tier, $row.nameJa, $row.averagePlacement, $row.sampleCount, $row.id)
}
