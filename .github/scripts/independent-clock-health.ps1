function Test-IndependentClockHealth {
    param([object]$Health, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow, [int]$HttpStatus = 200)
    try {
        if ($HttpStatus -ne 200) { return $false }
        foreach ($field in @('schemaVersion', 'checkedAt', 'status')) {
            if (-not $Health.PSObject.Properties[$field]) { return $false }
        }
        $checked = ConvertTo-AutomationTimestamp $Health.checkedAt
        $age = ($Now - $checked).TotalMinutes
        if ($age -lt -2 -or $age -gt 12) { return $false }
        if ([int]$Health.schemaVersion -eq 1) { return [string]$Health.status -ceq 'CHECKED' }
        if ([int]$Health.schemaVersion -ne 2) { return $false }
        foreach ($field in @('mode', 'dataVerification', 'lastAcceptedAt')) {
            if (-not $Health.PSObject.Properties[$field]) { return $false }
        }
        $acceptedAge = ($Now - (ConvertTo-AutomationTimestamp $Health.lastAcceptedAt)).TotalMinutes
        return [string]$Health.mode -ceq 'CLOCK_ONLY' -and [string]$Health.dataVerification -ceq 'GITHUB_WORKFLOW' -and [string]$Health.status -ceq 'CLOCK_ALIVE' -and $acceptedAge -ge -2 -and $acceptedAge -le 30
    } catch { return $false }
}
