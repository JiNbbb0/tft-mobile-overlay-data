Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Convert-MetaTftExplicitPosition {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [ValueType]) {
        $position = [int]$Value
        if ($position -ge 0 -and $position -lt 28) { return $position }
        return $null
    }
    $text = [string]$Value
    if ($text -match '^cell_(\d+)$') {
        $index = [int]$Matches[1] - 1
        if ($index -ge 0 -and $index -lt 28) { return $index }
    }
    return $null
}

function Get-MetaTftCandidateUnits {
    param(
        [Parameter(Mandatory = $true)]$Candidate,
        [Parameter(Mandatory = $true)][int]$Level
    )
    $unitListValue = ''
    foreach ($propertyName in @('unit_list','units_list')) {
        $property = $Candidate.PSObject.Properties[$propertyName]
        if ($property -and $property.Value) { $unitListValue = [string]$property.Value; break }
    }
    if (-not $unitListValue) { return @() }
    return @(
        ($unitListValue -split '&') |
            Where-Object { $_ } |
            ForEach-Object { [string]$_ } |
            Select-Object -First $Level
    )
}

function Get-MetaTftCandidatePositions {
    param(
        [Parameter(Mandatory = $true)]$Candidate,
        [Parameter(Mandatory = $true)][string[]]$UnitIds
    )

    $positionProperty = @('positions','unit_positions','board_positions') |
        ForEach-Object { $Candidate.PSObject.Properties[[string]$_] } |
        Where-Object { $_ -and $null -ne $_.Value } |
        Select-Object -First 1
    if (-not $positionProperty) {
        return [pscustomobject]@{ available = $false; positions = @() }
    }

    $raw = $positionProperty.Value
    $rows = [Collections.Generic.List[object]]::new()
    if ($raw -is [pscustomobject]) {
        foreach ($unitId in $UnitIds) {
            $property = $raw.PSObject.Properties[$unitId]
            if (-not $property) { return [pscustomobject]@{ available = $false; positions = @() } }
            $position = Convert-MetaTftExplicitPosition -Value $property.Value
            if ($null -eq $position) { return [pscustomobject]@{ available = $false; positions = @() } }
            $rows.Add([pscustomobject]@{ id=$unitId; position=[int]$position })
        }
    } elseif ($raw -is [Collections.IEnumerable] -and $raw -isnot [string]) {
        $values = @($raw)
        if ($values.Count -ne $UnitIds.Count) { return [pscustomobject]@{ available = $false; positions = @() } }
        for ($i = 0; $i -lt $UnitIds.Count; $i++) {
            $position = Convert-MetaTftExplicitPosition -Value $values[$i]
            if ($null -eq $position) { return [pscustomobject]@{ available = $false; positions = @() } }
            $rows.Add([pscustomobject]@{ id=$UnitIds[$i]; position=[int]$position })
        }
    } else {
        return [pscustomobject]@{ available = $false; positions = @() }
    }

    if (@($rows.position | Sort-Object -Unique).Count -ne $rows.Count) {
        throw 'METATFT_BOARD_POSITION_COLLISION explicit source positions contain duplicate cells.'
    }
    return [pscustomobject]@{ available = $true; positions = @($rows) }
}

function Convert-MetaTftLevelBoards {
    param(
        [Parameter(Mandatory = $true)]$Details,
        [int]$MaximumBoardsPerLevel = 3
    )

    $boards = [Collections.Generic.List[object]]::new()
    foreach ($level in 4..9) {
        $sourceCollection = if ($level -le 7) { $Details.PSObject.Properties['early_options'] } else { $Details.PSObject.Properties['options'] }
        if (-not $sourceCollection -or -not $sourceCollection.Value) { continue }
        $levelProperty = $sourceCollection.Value.PSObject.Properties[[string]$level]
        if (-not $levelProperty) { continue }

        # MetaTFT's guide describes these as the most popular board variations.
        # Prefer explicit usage count and preserve original source order for ties.
        $indexed = [Collections.Generic.List[object]]::new()
        $sourceIndex = 0
        foreach ($candidate in @($levelProperty.Value)) {
            $unitIds = @(Get-MetaTftCandidateUnits -Candidate $candidate -Level $level)
            if ($unitIds.Count -eq 0) { $sourceIndex++; continue }
            $indexed.Add([pscustomobject]@{
                sourceIndex = $sourceIndex
                count = if ($candidate.PSObject.Properties['count']) { [int]$candidate.count } else { 0 }
                avg = if ($candidate.PSObject.Properties['avg']) { [double]$candidate.avg } else { 0.0 }
                candidate = $candidate
                unitIds = @($unitIds)
            })
            $sourceIndex++
        }

        $selected = @(
            $indexed.ToArray() |
                Sort-Object @{ Expression = { -[int]$_.count } }, sourceIndex |
                Select-Object -First $MaximumBoardsPerLevel
        )
        $rank = 1
        foreach ($row in $selected) {
            $positionResult = Get-MetaTftCandidatePositions -Candidate $row.candidate -UnitIds @($row.unitIds)
            $boards.Add([pscustomobject][ordered]@{
                level = $level
                popularityRank = $rank
                sampleCount = [int]$row.count
                averagePlacement = [Math]::Round([double]$row.avg, 4)
                unitIds = @($row.unitIds)
                positionsAvailable = [bool]$positionResult.available
                positions = @($positionResult.positions)
                synthetic = $false
                source = $(if ($level -le 7) { 'MetaTFT early_options' } else { 'MetaTFT options' })
            })
            $rank++
        }
    }

    # Deliberately do not derive missing levels from adjacent boards.
    return @($boards)
}
