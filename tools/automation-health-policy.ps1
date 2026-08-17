Set-StrictMode -Version Latest

function Resolve-AutomationHealth {
    param(
        [object[]]$CompletedRuns,
        [AllowNull()][object]$LastSuccessfulAt,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow,
        [int]$FailureThreshold = 4,
        [int]$StaleHours = 6,
        [bool]$PublicOutOfSync = $false
    )

    $consecutiveFailures = 0
    foreach ($run in @($CompletedRuns)) {
        if ([string]$run.conclusion -ne 'failure') { break }
        $consecutiveFailures++
    }
    $lastSuccess = if ($null -eq $LastSuccessfulAt) { $null } else { [DateTimeOffset]$LastSuccessfulAt }
    $stale = $null -eq $lastSuccess -or ($Now - $lastSuccess).TotalHours -ge $StaleHours
    $requiresAttention = $PublicOutOfSync -or $consecutiveFailures -ge $FailureThreshold -or $stale
    $reason = if ($PublicOutOfSync) {
        'PUBLIC_OUT_OF_SYNC'
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
    }
}
