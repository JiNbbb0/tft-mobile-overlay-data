$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'composition-rank-contract.ps1')
. (Join-Path $PSScriptRoot 'source-contract.ps1')
$root = Split-Path -Parent $PSScriptRoot
$registry = Get-Content -Raw -LiteralPath (Join-Path $root 'config/composition-ranks.json') | ConvertFrom-Json
$base = Get-Content -Raw -LiteralPath (Join-Path $root 'source/current/tft_static_snapshot.json') | ConvertFrom-Json
$base.PSObject.Properties.Remove('compositionRanks')
$patch = [string](Get-Content -Raw -LiteralPath (Join-Path $root 'source/current/tft/tft_catalog.json') | ConvertFrom-Json).set.tftPatch
# Synthetic copies ONLY for contract regression, never published/generated statistics.
$children = @($registry.ranks | Where-Object id -NE $registry.defaultRankId | ForEach-Object {
    $child = $base | ConvertTo-Json -Depth 40 | ConvertFrom-Json
    $child.statisticsScope.preferred = [string]$_.id
    $child.statisticsScope.effective = [string]$_.id
    [pscustomobject]@{ rankId=[string]$_.id; snapshot=$child }
})
$base | Add-Member -NotePropertyName compositionRanks -NotePropertyValue ([pscustomobject]@{
    schemaVersion=1; setId=[string]$base.setId; patch=$patch; revision=[string]$base.clusterId; defaultRankId=[string]$registry.defaultRankId
    options=@($registry.ranks | ForEach-Object { [pscustomobject]@{ id=[string]$_.id; label=[string]$_.label } }); datasets=$children
})
$testCount = 0
function Valid { Assert-CompositionRanks -Snapshot $base -Patch $patch; $script:testCount++ }
function Reject([scriptblock]$Block) {
    $rejected = $false
    try { & $Block } catch { $rejected = $true }
    if (-not $rejected) { throw 'Invalid rank contract was accepted' }
    $script:testCount++
}
Valid
if ((Resolve-MetaTftCompositionGameCount -Stats ([pscustomobject]@{results=@()}) -AllowPartial) -ne 0) { throw 'New-set empty rank was not recognized' }; $testCount++
Reject { Resolve-MetaTftCompositionGameCount -Stats ([pscustomobject]@{results=@()}) }
Reject { Resolve-MetaTftCompositionGameCount -Stats ([pscustomobject]@{results=@([pscustomobject]@{cluster='fixture';places=@(1,2,3,4,5,6,7,8,20)})}) -AllowPartial }
$originalSet = $base.compositionRanks.setId
$base.compositionRanks.setId='TFTSet999'; Reject { Valid }; $base.compositionRanks.setId=$originalSet
$base.compositionRanks.patch='invalid'; Reject { Valid }; $base.compositionRanks.patch=$patch
$originalRevision=$base.compositionRanks.revision
$base.compositionRanks.revision='999'; Reject { Valid }; $base.compositionRanks.revision=$originalRevision
$originalScope=$children[0].snapshot.statisticsScope.effective
$children[0].snapshot.statisticsScope.effective='ALL_RANKS_FALLBACK'; Reject { Valid }
$children[0].snapshot.statisticsScope.effective="$($children[0].rankId)_LIMITED"; Valid
$children[0].snapshot.statisticsScope.effective=$originalScope
$originalId=$children[0].rankId; $children[0].rankId=$children[1].rankId; Reject { Valid }; $children[0].rankId=$originalId
$options=$base.compositionRanks.options; $base.compositionRanks.options=@($options)+@($options[0]); Reject { Valid }; $base.compositionRanks.options=$options
$temp = Join-Path $root ('build/rank-contract-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
$path=Join-Path $temp 'fixture.json'
function Fingerprint {
    [IO.File]::WriteAllText($path, ($base | ConvertTo-Json -Depth 40 -Compress), [Text.UTF8Encoding]::new($false))
    & (Join-Path $PSScriptRoot 'get-meta-fingerprint.ps1') -SnapshotPath $path
}
$before=Fingerprint
$children[0].snapshot.fetchedAtUtc='2026-01-01T00:00:00Z'; $children[0].snapshot.statsUpdatedEpochMs=1
if ((Fingerprint) -ne $before) { throw 'Observation-only change versioned rank data' }; $testCount++
$children[0].snapshot.compositions[0].averagePlacement += 0.000001
if ((Fingerprint) -eq $before) { throw 'Non-default rank content change did not change fingerprint' }; $testCount++
$generator=Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'refresh-static-meta.ps1')
if (-not $generator.Contains('$ResponseCache.ContainsKey($Url)') -or -not $generator.Contains('permit_filter_adjustment=false')) { throw 'Source request cache/strict rank contract missing' }
Write-Output "Composition rank regression: PASS Checks=$testCount Ranks=$($registry.ranks.Count)"
