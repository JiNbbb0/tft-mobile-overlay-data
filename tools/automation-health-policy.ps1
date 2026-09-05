Set-StrictMode -Version Latest

function ConvertTo-AutomationTimestamp($Value) {
    if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [DateTime]) { return [DateTimeOffset]$Value.ToUniversalTime() }
    return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
}

function Resolve-AutomationHealth {
    param(
        [object[]]$CompletedRuns,
        [AllowNull()][object]$LastSuccessfulAt,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow,
        [int]$FailureThreshold = 4,
        [int]$StaleHours = 6,
        [bool]$PublicOutOfSync = $false,
        [double]$SourceAgeMinutes = -1,
        [bool]$SourceCheckFailed = $false,
        [double]$CapacityPercent = 0,
        [int]$VersionCount = 0
    )

    $consecutiveFailures = 0
    foreach ($run in @($CompletedRuns)) {
        if ([string]$run.conclusion -notin @('failure', 'timed_out', 'cancelled', 'action_required')) { break }
        $consecutiveFailures++
    }
    $lastSuccess = if ($null -eq $LastSuccessfulAt) { $null } else { [DateTimeOffset]$LastSuccessfulAt }
    $stale = $null -eq $lastSuccess -or ($Now - $lastSuccess).TotalHours -ge $StaleHours
    $sourceStale = $SourceAgeMinutes -ge ($StaleHours * 60)
    $capacityWarning = $CapacityPercent -ge 70 -or $VersionCount -ge 70
    $requiresAttention = $PublicOutOfSync -or $consecutiveFailures -ge $FailureThreshold -or $stale -or $sourceStale -or $SourceCheckFailed -or $capacityWarning
    $reason = if ($PublicOutOfSync) {
        'PUBLIC_OUT_OF_SYNC'
    } elseif ($SourceCheckFailed) {
        'SOURCE_CHECK_FAILED'
    } elseif ($SourceAgeMinutes -ge 1440) {
        'SOURCE_STALE_24H'
    } elseif ($sourceStale) {
        'SOURCE_STALE_6H'
    } elseif ($capacityWarning) {
        if ($CapacityPercent -ge 95 -or $VersionCount -ge 95) { 'CAPACITY_95' }
        elseif ($CapacityPercent -ge 85 -or $VersionCount -ge 85) { 'CAPACITY_85' }
        else { 'CAPACITY_70' }
    } elseif ($consecutiveFailures -ge $FailureThreshold -and $stale) {
        'CONSECUTIVE_FAILURES_AND_STALE'
    } elseif ($consecutiveFailures -ge $FailureThreshold) {
        'CONSECUTIVE_FAILURES'
    } elseif ($stale) {
        'SUCCESS_STALE'
    } else {
        'HEALTHY'
    }

    return [pscustomobject][ordered]@{
        requiresAttention = $requiresAttention
        reason = $reason
        consecutiveFailures = $consecutiveFailures
        stale = $stale
        publicOutOfSync = $PublicOutOfSync
        sourceStale = $sourceStale
        sourceAgeMinutes = $SourceAgeMinutes
        capacityWarning = $capacityWarning
    }
}

function Test-RefreshObservation {
    param($Observation, [string]$VersionId, [string]$RunId, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)
    try {
        if ([int]$Observation.schemaVersion -ne 1 -or [string]$Observation.runId -cne $RunId -or
            [string]$Observation.versionId -cne $VersionId -or
            [string]$Observation.result -cnotin @('NO_CHANGE', 'PUBLISHED')) { return $false }
        $at = ConvertTo-AutomationTimestamp $Observation.checkedAtUtc
        return $at -le $Now.AddMinutes(2) -and $at -ge $Now.AddDays(-7)
    } catch { return $false }
}

function Resolve-RecoveryDispatch {
    param([object[]]$Runs, [bool]$NeedsRefresh, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow, [int]$CooldownMinutes = 30)
    if (-not $NeedsRefresh) { return 'NOT_NEEDED' }
    if (@($Runs | Where-Object { $_.status -ne 'completed' }).Count) { return 'ALREADY_PENDING' }
    if (@($Runs | Where-Object { (ConvertTo-AutomationTimestamp $_.created_at) -gt $Now.AddMinutes(-$CooldownMinutes) }).Count) { return 'COOLDOWN' }
    return 'DISPATCH'
}

function Select-AutomationHealthIssue {
    param(
        [AllowNull()][object[]]$Issues,
        [Parameter(Mandatory = $true)][string]$Title
    )

    foreach ($issue in @($Issues)) {
        if ($null -eq $issue) { continue }
        if (-not $issue.PSObject.Properties['title']) { continue }
        if ([string]$issue.title -eq $Title) { return $issue }
    }
    return $null
}
