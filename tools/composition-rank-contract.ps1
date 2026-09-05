Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'statistics-scope-contract.ps1')

function Assert-CompositionRanks {
    param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)][string]$Patch)
    if (-not $Snapshot.PSObject.Properties['compositionRanks']) { return }
    $ranks = $Snapshot.compositionRanks
    $schema = Join-Path $PSScriptRoot '../schema/composition-ranks.schema.json'
    if (-not (($ranks | ConvertTo-Json -Depth 40 -Compress) | Test-Json -SchemaFile $schema -ErrorAction Stop)) { throw 'Rank extension JSON schema failed' }
    if ([int]$ranks.schemaVersion -ne 1 -or [string]$ranks.defaultRankId -cne [string]$Snapshot.statisticsScope.preferred) { throw 'Invalid composition rank schema/default' }
    if ([string]$ranks.setId -cne [string]$Snapshot.setId -or [string]$ranks.patch -cne $Patch -or [string]$ranks.revision -cne [string]$Snapshot.clusterId) { throw 'Composition rank set/patch/revision mismatch' }
    $options = @($ranks.options)
    $ids = @($options | ForEach-Object { [string]$_.id })
    if ($ids.Count -lt 1 -or $ids.Count -gt 16 -or @($ids | Sort-Object -Unique).Count -ne $ids.Count -or $ranks.defaultRankId -cnotin $ids) { throw 'Invalid/duplicate rank options' }
    foreach ($option in $options) {
        $contract = Get-TftStatisticsScopeContract -RankId ([string]$option.id)
        if ([string]$option.label -cne [string]$contract.displayName) { throw 'Rank label mismatch' }
    }
    $datasets = @($ranks.datasets)
    $datasetIds = @($datasets | ForEach-Object { [string]$_.rankId })
    if ($datasets.Count -ne ($ids.Count - 1) -or @($datasetIds | Sort-Object -Unique).Count -ne $datasets.Count) { throw 'Missing/duplicate rank dataset' }
    foreach ($dataset in $datasets) {
        $id = [string]$dataset.rankId
        $child = $dataset.snapshot
        if ($id -ceq [string]$ranks.defaultRankId -or $id -cnotin $ids -or $child.PSObject.Properties['compositionRanks']) { throw 'Unexpected/nested rank dataset' }
        if ([string]$child.setId -cne [string]$Snapshot.setId -or [string]$child.clusterId -cne [string]$Snapshot.clusterId) { throw 'Mixed rank dataset identity' }
        if ([string]$child.statisticsScope.preferred -cne $id -or -not (Test-TftStatisticsScopeName ([string]$child.statisticsScope.effective) -RankId $id)) { throw 'Rank dataset scope mismatch' }
        $compIds = @($child.compositions | ForEach-Object { [string]$_.id })
        if (@($compIds | Sort-Object -Unique).Count -ne $compIds.Count) { throw 'Duplicate ranked composition' }
    }
}
