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

function Get-MetaTftDefaultAllowedUnitIds {
    $catalogPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\source\current\tft\tft_catalog.json'))
    if (-not (Test-Path -LiteralPath $catalogPath)) {
        throw "METATFT_BOARD_CATALOG_NOT_FOUND path=$catalogPath"
    }

    try {
        $catalog = Get-Content -Raw -Encoding UTF8 -LiteralPath $catalogPath | ConvertFrom-Json
    } catch {
        throw "METATFT_BOARD_CATALOG_INVALID path=$catalogPath"
    }

    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($champion in @($catalog.champions)) {
        if ($null -ne $champion -and $champion.id) {
            [void]$allowed.Add([string]$champion.id)
        }
    }
    if ($allowed.Count -eq 0) {
        throw "METATFT_BOARD_CATALOG_EMPTY path=$catalogPath"
    }
    return $allowed
}

function ConvertTo-MetaTftAllowedUnitSet {
    param([AllowNull()]$AllowedUnitIds)

    if ($null -eq $AllowedUnitIds) {
        return Get-MetaTftDefaultAllowedUnitIds
    }

    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($AllowedUnitIds)) {
        if ($id) { [void]$allowed.Add([string]$id) }
    }
    if ($allowed.Count -eq 0) {
        throw 'METATFT_BOARD_ALLOWED_UNIT_SET_EMPTY'
    }
    return $allowed
}

function Get-MetaTftCandidateUnitRows {
    param(
        [Parameter(Mandatory = $true)]$Candidate,
        [Parameter(Mandatory = $true)][int]$Level,
        [Parameter(Mandatory = $true)]$AllowedUnitSet
    )

    $unitListValue = ''
    foreach ($propertyName in @('unit_list','units_list')) {
        $property = $Candidate.PSObject.Properties[$propertyName]
        if ($property -and $property.Value) { $unitListValue = [string]$property.Value; break }
    }
    if (-not $unitListValue) { return @() }

    $rawUnitIds = @(
        ($unitListValue -split '&') |
            ForEach-Object { [string]$_ }
    )
    $rows = [Collections.Generic.List[object]]::new()
    for ($sourceIndex = 0; $sourceIndex -lt $rawUnitIds.Count; $sourceIndex++) {
        $unitId = [string]$rawUnitIds[$sourceIndex]
        if (-not $unitId) { continue }
        if (-not $AllowedUnitSet.Contains($unitId)) { continue }

        $rows.Add([pscustomobject][ordered]@{
            id = $unitId
            sourceIndex = $sourceIndex
        })
        if ($rows.Count -ge $Level) { break }
    }
    return @($rows)
}

function Get-MetaTftCandidateUnits {
    param(
        [Parameter(Mandatory = $true)]$Candidate,
        [Parameter(Mandatory = $true)][int]$Level,
        [AllowNull()]$AllowedUnitIds = $null
    )

    $allowedUnitSet = ConvertTo-MetaTftAllowedUnitSet -AllowedUnitIds $AllowedUnitIds
    return @(
        Get-MetaTftCandidateUnitRows -Candidate $Candidate -Level $Level -AllowedUnitSet $allowedUnitSet |
            ForEach-Object { [string]$_.id }
    )
}

function Get-MetaTftCandidatePositions {
    param(
        [Parameter(Mandatory = $true)]$Candidate,
        [Parameter(Mandatory = $true)][string[]]$UnitIds,
        [int[]]$SourceIndexes = @()
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
        if ($SourceIndexes.Count -gt 0) {
            if ($SourceIndexes.Count -ne $UnitIds.Count) { return [pscustomobject]@{ available = $false; positions = @() } }
            for ($i = 0; $i -lt $UnitIds.Count; $i++) {
                $sourceIndex = [int]$SourceIndexes[$i]
                if ($sourceIndex -lt 0 -or $sourceIndex -ge $values.Count) {
                    return [pscustomobject]@{ available = $false; positions = @() }
                }
                $position = Convert-MetaTftExplicitPosition -Value $values[$sourceIndex]
                if ($null -eq $position) { return [pscustomobject]@{ available = $false; positions = @() } }
                $rows.Add([pscustomobject]@{ id=$UnitIds[$i]; position=[int]$position })
            }
        } else {
            if ($values.Count -ne $UnitIds.Count) { return [pscustomobject]@{ available = $false; positions = @() } }
            for ($i = 0; $i -lt $UnitIds.Count; $i++) {
                $position = Convert-MetaTftExplicitPosition -Value $values[$i]
                if ($null -eq $position) { return [pscustomobject]@{ available = $false; positions = @() } }
                $rows.Add([pscustomobject]@{ id=$UnitIds[$i]; position=[int]$position })
            }
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
        [int]$MaximumBoardsPerLevel = 3,
        [AllowNull()]$AllowedUnitIds = $null
    )

    # Board rows may include source-side summons, helper entities, or other
    # non-placeable identities. Canonical v2 only publishes champion IDs that
    # exist in the current catalog. Source indexes are retained so explicit
    # position arrays still map to the correct cells after filtering.
    $allowedUnitSet = ConvertTo-MetaTftAllowedUnitSet -AllowedUnitIds $AllowedUnitIds

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
            $unitRows = @(Get-MetaTftCandidateUnitRows -Candidate $candidate -Level $level -AllowedUnitSet $allowedUnitSet)
            $unitIds = @($unitRows | ForEach-Object { [string]$_.id })
            if ($unitIds.Count -eq 0) { $sourceIndex++; continue }
            $indexed.Add([pscustomobject]@{
                sourceIndex = $sourceIndex
                count = if ($candidate.PSObject.Properties['count']) { [int]$candidate.count } else { 0 }
                avg = if ($candidate.PSObject.Properties['avg']) { [double]$candidate.avg } else { 0.0 }
                candidate = $candidate
                unitIds = @($unitIds)
                unitSourceIndexes = @($unitRows | ForEach-Object { [int]$_.sourceIndex })
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
            $positionResult = Get-MetaTftCandidatePositions `
                -Candidate $row.candidate `
                -UnitIds @($row.unitIds) `
                -SourceIndexes @($row.unitSourceIndexes)
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
