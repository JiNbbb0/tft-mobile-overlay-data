# Optional tables are independent of composition statistics. A blocked source
# must not invalidate the seven otherwise valid rank datasets.
function Get-ReferenceTimestampText([object]$Value) {
    # PowerShell 7.5 deserializes ISO JSON timestamps into DateTime by default.
    # Preserve the original UTC instant instead of casting to localized text.
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ') }
    return [string]$Value
}
function New-UnavailableReferenceTable([string]$Id, [string]$Title, [string]$SetId, [string]$Patch, [string]$Note) {
    return [pscustomobject][ordered]@{
        id=$Id; title=$Title; setId=$SetId; patch=$Patch; state='UNAVAILABLE'
        columns=@('状態'); rows=@(); sourceName=''; sourceUpdatedAt=''; note=$Note
    }
}

function ConvertTo-CheckedWispTable {
    param([object]$Definition, [string]$PageText, [string]$CsvText, [hashtable]$JapaneseItems,
        [string]$SetId, [string]$Patch)
    if ($Definition.contract -cne 'SOURCE_CHECKED_REFERENCE_V1' -or $Definition.setId -cne $SetId -or $Definition.patch -cne $Patch) {
        throw 'REFERENCE_IDENTITY_MISMATCH'
    }
    if ($PageText -notmatch ('TFT Wisp offer rules\s*\(' + [regex]::Escape($Patch) + '\)')) { throw 'REFERENCE_SOURCE_PATCH_MISMATCH' }
    $records = @($CsvText | ConvertFrom-Csv)
    if ($records.Count -eq 0 -or $records.Count -gt 1000) { throw 'REFERENCE_SOURCE_COUNT_INVALID' }
    $byId = @{}
    foreach ($record in $records) {
        $id = [string]$record.ApiName
        if (-not $id -or $byId.ContainsKey($id)) { throw 'REFERENCE_SOURCE_DUPLICATE_ID' }
        $byId[$id] = $record
    }
    $rows = @($Definition.rows)
    if ($rows.Count -eq 0 -or $rows.Count -gt 500 -or @($rows.id | Select-Object -Unique).Count -ne $rows.Count) { throw 'REFERENCE_ROWS_INVALID' }
    $rendered = foreach ($expected in $rows) {
        $id = [string]$expected.id
        if (-not $byId.ContainsKey($id) -or -not $JapaneseItems.ContainsKey($id) -or [string]$JapaneseItems[$id].name -cne [string]$expected.nameJa) {
            throw 'REFERENCE_EXACT_ID_OR_NAME_MISMATCH'
        }
        $actual = $byId[$id]
        $override = $Definition.conditionOverrides.PSObject.Properties[$id]
        $cooldown = if ($override) { [string]$override.Value.cooldown } else { [string]$Definition.defaultCooldown }
        $exclusions = @(if ($override) { $override.Value.excludedAugmentIds })
        $actualExclusions = @($actual.PSObject.Properties | Where-Object { $_.Name -match '^MutuallyExclusiveItem\d+$' -and $_.Value } | ForEach-Object { [string]$_.Value })
        if ([string]$actual.'Re-offer Cooldown' -cne $cooldown -or ($actualExclusions -join '|') -cne ($exclusions -join '|')) { throw 'REFERENCE_SOURCE_CONDITIONS_CHANGED' }
        $excludedNames = @(foreach ($excludedId in $exclusions) {
            if (-not $JapaneseItems.ContainsKey([string]$excludedId) -or -not $JapaneseItems[[string]$excludedId].name) { throw 'REFERENCE_EXCLUSION_ID_UNRESOLVED' }
            [string]$JapaneseItems[[string]$excludedId].name
        })
        # Curated Japanese paraphrases stay valid only while ALL relevant source
        # fields match. Never replace only the price while keeping an old effect.
        if ([string]$actual.Cost -cne [string]$expected.cost -or [string]$actual.Description -cne [string]$expected.description -or
            [string]$actual.'Round Bands' -cne [string]$expected.bands -or [string]$actual.'Special Conditions' -cne [string]$expected.condition -or
            [string]$actual.Standard -cne 'Yes') { throw 'REFERENCE_SOURCE_CONTENT_CHANGED' }
        [pscustomobject]@{id=$id; cells=@([string]$expected.nameJa, [string]$expected.variant,
            ([string]$expected.cost + ' G'), [string]$expected.effectJa, [string]$expected.bandsJa, [string]$expected.conditionJa,
            $(if ($excludedNames.Count) {$excludedNames -join '・'} else {'なし'}), ($cooldown + ' ショップ'))}
    }
    return [pscustomobject][ordered]@{
        id='wisp_reference'; title='ウィスプ一覧'; setId=$SetId; patch=$Patch; state='READY'
        columns=@('名前','通常／強化','価格','効果','出現時期','盤面などの条件','排他オーグメント','再提示まで'); rows=@($rendered)
        sourceName='Little Buddy Bot・Riot（現行値照合）'; sourceUpdatedAt=(Get-ReferenceTimestampText $Definition.verifiedAt)
        note='一部確認済み：4種類・通常／強化8件。通常モード用で、強さ評価とは別の一覧です。出現時期は提供元の段階区分（ラウンド番号ではありません）。排他オーグメント保有中は提示されません。再提示までは、このウィスプが提示されてから再び出現可能になるまでのウィスプショップ数です。日時はこの表の照合日です。'
    }
}

function Assert-ReferenceTables([object[]]$Tables, [string]$SetId, [string]$Patch) {
    if ($Tables.Count -gt 16 -or ($Tables.Count -gt 0 -and @($Tables.id | Select-Object -Unique).Count -ne $Tables.Count)) { throw 'REFERENCE_TABLE_IDS_INVALID' }
    foreach ($table in $Tables) {
        $timestamp = Get-ReferenceTimestampText $table.sourceUpdatedAt
        if ($table.id -cnotmatch '^[a-z0-9_-]{1,64}$' -or $table.setId -cne $SetId -or $table.patch -cne $Patch -or
            @('READY','UNAVAILABLE') -cnotcontains $table.state -or -not ([string]$table.title).Trim() -or $table.title.Length -gt 120) { throw 'REFERENCE_TABLE_IDENTITY_INVALID' }
        if ($table.columns -isnot [Array] -or $table.rows -isnot [Array] -or @($table.columns).Count -notin 1..8 -or @($table.rows).Count -gt 500 -or
            $table.sourceName.Length -gt 200 -or $timestamp.Length -gt 80 -or $table.note.Length -gt 4000) { throw 'REFERENCE_TABLE_SIZE_INVALID' }
        if ($table.state -eq 'READY') {
            if (@($table.rows).Count -eq 0 -or -not ([string]$table.sourceName).Trim() -or $timestamp -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$' -or
                -not [DateTimeOffset]::TryParse($timestamp, [ref]([DateTimeOffset]::MinValue))) {
                throw 'REFERENCE_READY_PROVENANCE_INVALID'
            }
        } elseif (@($table.rows).Count -ne 0) { throw 'REFERENCE_UNAVAILABLE_HAS_ROWS' }
        if (@($table.rows).Count -gt 0 -and @($table.rows.id | Select-Object -Unique).Count -ne @($table.rows).Count) { throw 'REFERENCE_ROW_IDS_INVALID' }
        foreach ($column in @($table.columns)) {
            if (-not ([string]$column).Trim() -or $column.Length -gt 80) { throw 'REFERENCE_COLUMNS_INVALID' }
        }
        foreach ($value in @($table.title, $table.sourceName, $table.sourceUpdatedAt, $table.note) + @($table.columns)) {
            if ([string]$value -match '\uFFFD|@[A-Za-z][^@]*@' -or ([string]$value).Length -gt 4000) { throw 'REFERENCE_TEXT_INVALID' }
        }
        foreach ($row in @($table.rows)) {
            if (-not ([string]$row.id).Trim() -or $row.id.Length -gt 160 -or $row.cells -isnot [Array] -or @($row.cells).Count -ne @($table.columns).Count) { throw 'REFERENCE_ROW_INVALID' }
            foreach ($cell in @($row.cells)) {
                if (-not ([string]$cell).Trim() -or ([string]$cell).Length -gt 4000 -or [string]$cell -match '\uFFFD|@[A-Za-z][^@]*@') { throw 'REFERENCE_CELL_INVALID' }
            }
        }
    }
}
