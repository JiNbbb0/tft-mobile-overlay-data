. (Join-Path $PSScriptRoot 'reference-table-contract.ps1')

function ConvertTo-CheckedWispStrengthTable {
    param([object]$Definition, [object]$Ratings, [object]$CurrentSetData, [hashtable]$JapaneseItems,
        [string]$SetId, [string]$Patch)
    if ($Definition.setId -cne $SetId -or $Definition.patch -cne $Patch -or $CurrentSetData.mutator -cne $SetId) { throw 'WISP_STRENGTH_IDENTITY_MISMATCH' }
    if ($Ratings.content.content.tierListType -cne 'Wisps') { throw 'WISP_STRENGTH_TYPE_MISMATCH' }
    $updatedText = Get-ReferenceTimestampText $Ratings.content.updated_at
    $publishedText = Get-ReferenceTimestampText $Definition.patchPublishedAt
    $updated = [DateTimeOffset]::Parse($updatedText)
    $published = [DateTimeOffset]::Parse($publishedText)
    if ($updated -lt $published -or $updated -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) { throw 'WISP_STRENGTH_PATCH_FRESHNESS_UNPROVEN' }
    $current = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($id in @($CurrentSetData.items)) { [void]$current.Add([string]$id) }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $labels = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $rows = [Collections.Generic.List[object]]::new()
    $outside = 0; $disabled = 0
    $groups = @($Ratings.content.content.tierList)
    if ($groups.Count -notin 1..16) { throw 'WISP_STRENGTH_GROUPS_INVALID' }
    foreach ($group in $groups) {
        $label = [string]$group.label
        if ($label -cnotmatch '^[A-Z][+-]?$' -or -not $labels.Add($label)) { throw 'WISP_STRENGTH_LABEL_INVALID' }
        foreach ($item in @($group.content)) {
            $id = [string]$item.id
            if ($item.type -cne 'wisp' -or $id -cnotmatch '^[A-Za-z0-9_-]{1,160}$' -or -not $seen.Add($id)) { throw 'WISP_STRENGTH_ROW_INVALID' }
            if (-not $current.Contains($id)) { $outside++; continue }
            if (@($Definition.disabledWispIds) -ccontains $id) { $disabled++; continue }
            if (-not $JapaneseItems.ContainsKey($id) -or -not ([string]$JapaneseItems[$id].name).Trim()) { throw 'WISP_STRENGTH_NAME_UNRESOLVED' }
            $rows.Add([pscustomobject]@{id=$id;cells=@($label,[string]$JapaneseItems[$id].name)})
        }
    }
    if ($seen.Count -eq 0 -or $seen.Count -gt 500 -or $rows.Count -eq 0 -or ($seen.Count-$outside)/$seen.Count -lt 0.9) {
        throw 'WISP_STRENGTH_COVERAGE_DEGRADED'
    }
    return [pscustomobject][ordered]@{
        id='wisp_tiers';title='ウィスプ評価';setId=$SetId;patch=$Patch;state='READY'
        columns=@('強さ評価','名前');rows=@($rows.ToArray())
        sourceName='MetaTFT 編集評価';sourceUpdatedAt=$updatedText
        note="一部確認済み：提供元$($seen.Count)件／現行セット照合$($seen.Count-$outside)件／無効化$disabled 件を除外／表示$($rows.Count)件。編集者の評価で、勝率統計・価格・出現階級ではありません。未確認IDは推測しません。提供元に明示的なパッチ番号はないため、現行セットのID照合とパッチ公開後の評価更新を確認しています。"
    }
}
