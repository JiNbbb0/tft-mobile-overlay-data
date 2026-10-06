param([string]$MonitorUrl = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Set-Output([string]$Name, [string]$Value) {
    if ($env:GITHUB_OUTPUT) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$Name=$Value" -Encoding UTF8 }
}

# Optional until the independent service is provisioned. Its public health route
# is read-only and contains no credentials. Do not echo account-specific URLs.
if (-not $MonitorUrl) {
    Set-Output 'requires_attention' 'false'
    Set-Output 'reason' 'NOT_CONFIGURED'
    Write-Output 'Independent clock: NOT_CONFIGURED (not evidence of autonomous operation).'
    exit 0
}

$attention = $true
$reason = 'INDEPENDENT_MONITOR_UNAVAILABLE'
try {
    $uri = [uri]$MonitorUrl
    if ($uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.AbsolutePath -ne '/health' -or
        $uri.Host -notmatch '^[a-z0-9.-]+\.workers\.dev$') { throw 'Invalid monitor endpoint.' }
    $reply = Invoke-WebRequest -Uri $uri -TimeoutSec 20 -SkipHttpErrorCheck -MaximumRedirection 0
    $health = $reply.Content | ConvertFrom-Json
    if ([int]$health.schemaVersion -ne 1) { throw 'Invalid health contract.' }
    . (Join-Path $PSScriptRoot '../../tools/automation-health-policy.ps1')
    $checkedAt = ConvertTo-AutomationTimestamp $health.checkedAt
    $age = ([DateTimeOffset]::UtcNow - $checkedAt).TotalMinutes
    $attention = $age -lt -2 -or $age -gt 12 -or [string]$health.status -ne 'CHECKED'
    $reason = if ($attention) { 'INDEPENDENT_MONITOR_REQUIRES_ATTENTION' } else { 'INDEPENDENT_MONITOR_CHECKED' }
} catch {
    # Only stable diagnostic codes are exposed, never exception/endpoint text.
}
Set-Output 'requires_attention' $attention.ToString().ToLowerInvariant()
Set-Output 'reason' $reason
Write-Output "Independent clock: $reason"
