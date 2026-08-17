Set-StrictMode -Version Latest

function Test-RobotsSiteWideBlock {
    param(
        [Parameter(Mandatory = $true)][string]$RobotsText,
        [string]$UserAgent = '*'
    )

    $groupAgents = [Collections.Generic.List[string]]::new()
    $readingDirectives = $false
    foreach ($rawLine in ($RobotsText -split "`r?`n")) {
        $line = ($rawLine -replace '#.*$', '').Trim()
        if (-not $line) { continue }
        $separator = $line.IndexOf(':')
        if ($separator -lt 0) { continue }
        $field = $line.Substring(0, $separator).Trim().ToLowerInvariant()
        $value = $line.Substring($separator + 1).Trim()
        if ($field -eq 'user-agent') {
            if ($readingDirectives) {
                $groupAgents.Clear()
                $readingDirectives = $false
            }
            $groupAgents.Add($value)
            continue
        }
        if ($groupAgents.Count -eq 0) { continue }
        $readingDirectives = $true
        $applies = @($groupAgents | Where-Object {
            $_ -eq '*' -or $_.Equals($UserAgent, [StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
        if ($applies -and $field -eq 'disallow' -and $value -eq '/') { return $true }
    }
    return $false
}

function Assert-MetaTftStatsContract {
    param(
        [Parameter(Mandatory = $true)]$Stats,
        [Parameter(Mandatory = $true)][string]$ExpectedSetId,
        [Parameter(Mandatory = $true)][int]$ExpectedClusterId,
        [AllowEmptyString()][string]$ExpectedRankFilter = '',
        [Parameter(Mandatory = $true)][string]$Context
    )

    if (-not $Stats.PSObject.Properties['results']) { throw "$Context response has no results collection." }
    if ([string]$Stats.tft_set -ne $ExpectedSetId -or [int]$Stats.cluster_id -ne $ExpectedClusterId) {
        throw "$Context response does not match latest cluster."
    }
    $adjustmentProperty = $Stats.PSObject.Properties['filter_adjustment']
    if (-not $adjustmentProperty -or $null -eq $adjustmentProperty.Value) { return }
    $adjustment = $adjustmentProperty.Value
    if ($adjustment.PSObject.Properties['override_applied'] -and [bool]$adjustment.override_applied) {
        throw "$Context applied an implicit filter adjustment."
    }
    $actualRank = if ($adjustment.PSObject.Properties['rank_filter']) { [string]$adjustment.rank_filter } else { '' }
    if ($actualRank -ne $ExpectedRankFilter) {
        throw "$Context rank contract mismatch. Expected='$ExpectedRankFilter' Actual='$actualRank'."
    }
}
