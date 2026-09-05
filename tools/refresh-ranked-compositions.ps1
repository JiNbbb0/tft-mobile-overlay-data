param(
    [string]$OutputPath = 'source/current/tft_static_snapshot.json',
    [string]$CatalogPath = 'source/current/tft/tft_catalog.json',
    [switch]$AllowPartial
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'composition-rank-contract.ps1')
$root = Split-Path -Parent $PSScriptRoot
function Resolve-Input([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $root $Path))
}
$output = Resolve-Input $OutputPath
$catalogFile = Resolve-Input $CatalogPath
$catalog = Get-Content -Raw -LiteralPath $catalogFile | ConvertFrom-Json
$registry = Get-Content -Raw -LiteralPath (Join-Path $root 'config/composition-ranks.json') | ConvertFrom-Json
# One batch owns this cache; no prior-run statistics or failures can be reused.
$responses = @{}
$workspace = Join-Path $root ('build/ranked-compositions-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workspace -Force | Out-Null
$snapshots = @{}
foreach ($rank in @($registry.ranks | Sort-Object @{Expression={ if ($_.id -eq $registry.defaultRankId) { 0 } else { 1 } }})) {
    $path = Join-Path $workspace ("$($rank.id.ToLowerInvariant()).json")
    # A sparse high-rank population is valid partial data, never a different rank.
    $partial = $AllowPartial -or [string]$rank.id -ne [string]$registry.defaultRankId
    & (Join-Path $PSScriptRoot 'refresh-static-meta.ps1') -OutputPath $path -RankId ([string]$rank.id) -ResponseCache $responses -AllowPartial:$partial
    & (Join-Path $PSScriptRoot 'validate-static-meta.ps1') -SnapshotPath $path -CatalogPath $catalogFile -RankId ([string]$rank.id)
    $snapshot = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    if ([string]$snapshot.setId -cne [string]$catalog.set.id) { throw 'Rank generation/catalog set mismatch' }
    $snapshots[[string]$rank.id] = $snapshot
}
$base = $snapshots[[string]$registry.defaultRankId]
$envelope = [ordered]@{
    schemaVersion = 1
    setId = [string]$base.setId
    patch = [string]$catalog.set.tftPatch
    revision = [string]$base.clusterId
    defaultRankId = [string]$registry.defaultRankId
    options = @($registry.ranks | ForEach-Object { [ordered]@{ id=[string]$_.id; label=[string]$_.label } })
    datasets = @($registry.ranks | Where-Object id -NE $registry.defaultRankId | ForEach-Object {
        [ordered]@{ rankId=[string]$_.id; snapshot=$snapshots[[string]$_.id] }
    })
}
$base | Add-Member -NotePropertyName compositionRanks -NotePropertyValue ([pscustomobject]$envelope)
Assert-CompositionRanks -Snapshot $base -Patch ([string]$catalog.set.tftPatch)
$json = ($base | ConvertTo-Json -Depth 40 -Compress) + "`n"
if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 30MB) { throw 'Rank snapshot exceeds 30 MiB limit' }
# Old source survives until ALL ranks validate. Pipeline backup/index gates remain unchanged.
New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force | Out-Null
$temporary = "$output.pending"
[IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
[IO.File]::Move($temporary, $output, $true)
Write-Output "Rank generation PASS: Ranks=$($registry.ranks.Count) UniqueRequests=$($responses.Count) Bytes=$([Text.Encoding]::UTF8.GetByteCount($json))"
