Set-StrictMode -Version Latest

function New-TftTeamPlannerIndex {
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$SetId,
        [Parameter(Mandatory)][string[]]$ChampionIds)
    if ($SetId -cnotmatch '^TFTSet[0-9]+$') { throw 'Invalid planner set ID' }
    $rows = $Document.PSObject.Properties[$SetId]
    if ($null -eq $rows) { throw 'Planner source does not contain the current set' }
    $index = [Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
    $eligible = [Collections.Generic.HashSet[string]]::new([string[]]$ChampionIds, [StringComparer]::Ordinal)
    foreach ($row in @($rows.Value)) {
        if (-not $row.PSObject.Properties['character_id'] -or -not $row.PSObject.Properties['team_planner_code']) { continue }
        $id = [string]$row.character_id
        if (-not $eligible.Contains($id)) { continue }
        $value = $row.team_planner_code
        if ($null -eq $value -or $value -is [string] -or $value -is [bool] -or
            [double]$value -ne [Math]::Truncate([double]$value) -or [double]$value -lt 1 -or [double]$value -gt 4095) {
            throw 'Invalid planner numeric ID'
        }
        if ($index.ContainsKey($id) -and $index[$id] -ne [int]$value) { throw 'Ambiguous planner champion identity' }
        $index[$id] = [int]$value
    }
    return ,$index
}

function Get-TftTeamPlannerCode {
    param([Parameter(Mandatory)][string]$SetId, [AllowEmptyCollection()][string[]]$UnitIds,
        [Parameter(Mandatory)]$Index)
    if ($SetId -cnotmatch '^TFTSet[0-9]+$' -or $UnitIds.Count -lt 1 -or $UnitIds.Count -gt 10) { return '' }
    $slots = foreach ($id in $UnitIds) {
        if (-not $Index.ContainsKey($id)) { return '' }
        $value = [int]$Index[$id]
        if ($value -lt 1 -or $value -gt 4095) { return '' }
        $value.ToString('x3', [Globalization.CultureInfo]::InvariantCulture)
    }
    return '02' + ($slots -join '') + ('000' * (10 - $UnitIds.Count)) + $SetId
}

function Assert-TftTeamPlannerCodes {
    param([Parameter(Mandatory)]$Snapshot)
    foreach ($comp in @($Snapshot.compositions)) {
        if (-not $comp.PSObject.Properties['teamPlannerCode'] -or -not $comp.teamPlannerCode) { continue }
        $code = [string]$comp.teamPlannerCode
        if ($code -cnotmatch ('^02[0-9a-f]{30}' + [regex]::Escape([string]$Snapshot.setId) + '$')) {
            throw 'Invalid planner format/set'
        }
        $count = @($comp.finalBoard.units).Count
        if ($count -lt 1 -or $count -gt 10) { throw 'Planner board exceeds available slots' }
        for ($i = 0; $i -lt 10; $i++) {
            $value = [Convert]::ToInt32($code.Substring(2 + 3 * $i, 3), 16)
            if (($i -lt $count -and $value -eq 0) -or ($i -ge $count -and $value -ne 0)) { throw 'Planner slot count mismatch' }
        }
    }
}
