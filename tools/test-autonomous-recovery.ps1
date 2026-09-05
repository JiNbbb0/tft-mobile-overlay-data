$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'automation-health-policy.ps1')
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "$Message Expected=$Expected Actual=$Actual" }
}
$now = [DateTimeOffset]::Parse('2026-09-05T12:00:00Z')
$recent = @([pscustomobject]@{ conclusion='success' })
$health = Resolve-AutomationHealth -CompletedRuns $recent -LastSuccessfulAt $now.AddMinutes(-5) -Now $now -SourceAgeMinutes 360
Assert-Equal 'SOURCE_STALE_6H' $health.reason 'A green source-not-ready loop must not mask stale data'
Assert-Equal $true $health.requiresAttention 'Source staleness needs an alert independently of workflow success'
Assert-Equal 'SOURCE_STALE_24H' (Resolve-AutomationHealth -CompletedRuns $recent -LastSuccessfulAt $now -Now $now -SourceAgeMinutes 1440).reason 'Escalate prolonged silence'
Assert-Equal 'SOURCE_CHECK_FAILED' (Resolve-AutomationHealth -CompletedRuns $recent -LastSuccessfulAt $now -Now $now -SourceCheckFailed $true).reason 'Failed checks cannot close an alert'
foreach ($threshold in @(70,85,95)) {
    Assert-Equal "CAPACITY_$threshold" (Resolve-AutomationHealth -CompletedRuns $recent -LastSuccessfulAt $now -Now $now -CapacityPercent $threshold).reason 'Byte capacity threshold'
    Assert-Equal "CAPACITY_$threshold" (Resolve-AutomationHealth -CompletedRuns $recent -LastSuccessfulAt $now -Now $now -VersionCount $threshold).reason 'Version capacity threshold'
}
$failedRuns = @('timed_out','cancelled','failure','action_required' | ForEach-Object { [pscustomobject]@{conclusion=$_} })
Assert-Equal 4 (Resolve-AutomationHealth -CompletedRuns $failedRuns -LastSuccessfulAt $now -Now $now).consecutiveFailures 'Count abnormal terminal states'
$observation = [pscustomobject]@{schemaVersion=1;runId='123';versionId='v-current';result='NO_CHANGE';checkedAtUtc=$now.AddMinutes(-10).ToString('o')}
Assert-Equal $true (Test-RefreshObservation $observation 'v-current' '123' $now) 'Verified unchanged data stays fresh without a new version'
$roundTripped = $observation | ConvertTo-Json | ConvertFrom-Json
Assert-Equal $now.AddMinutes(-10) (ConvertTo-AutomationTimestamp $roundTripped.checkedAtUtc) 'JSON dates must retain UTC across Windows timezones'
Assert-Equal $true (Test-RefreshObservation $roundTripped 'v-current' '123' $now) 'Parsed observation preserves its timestamp'
Assert-Equal $false (Test-RefreshObservation $observation 'v-other' '123' $now) 'Different bundle cannot refresh current clock'
Assert-Equal $false (Test-RefreshObservation $observation 'v-current' '999' $now) 'Evidence must be tied to its actual run'
$observation.result = 'SOURCE_NOT_READY'
Assert-Equal $false (Test-RefreshObservation $observation 'v-current' '123' $now) 'Source-not-ready is not successful source verification'
$observation.result = 'PUBLISHED'; $observation.checkedAtUtc = $now.AddHours(1).ToString('o')
Assert-Equal $false (Test-RefreshObservation $observation 'v-current' '123' $now) 'Reject future evidence'
Assert-Equal $false (Test-RefreshObservation ([pscustomobject]@{}) 'v-current' '123' $now) 'Missing evidence is not proof'
$busy = @([pscustomobject]@{status='in_progress';created_at=$now.AddHours(-1).ToString('o')})
Assert-Equal 'ALREADY_PENDING' (Resolve-RecoveryDispatch $busy $true $now) 'Do not replace a pending scheduled refresh'
$recentRun = @([pscustomobject]@{status='completed';created_at=$now.AddMinutes(-5).ToString('o')})
Assert-Equal 'COOLDOWN' (Resolve-RecoveryDispatch $recentRun $true $now) 'Bound automatic recovery rate'
Assert-Equal 'DISPATCH' (Resolve-RecoveryDispatch @() $true $now) 'Missing refresh history permits recovery'
Assert-Equal 'NOT_NEEDED' (Resolve-RecoveryDispatch @() $false $now) 'Fresh source does not trigger another fetch'

# Validate the concurrency topology, not just the presence of a lock string.
$workflow = Get-Content -Raw (Join-Path $PSScriptRoot '../.github/workflows/automation-watchdog.yml')
$inspect = ($workflow -split '(?m)^  repair-publication:')[0]
$repair = ($workflow -split '(?m)^  repair-publication:')[1] -split '(?m)^  verify-repair:' | Select-Object -First 1
if ($inspect -match 'upload-pages-artifact') { throw 'Repair artifacts must not be built before the publication lock' }
if ($repair -notmatch '(?s)group: tft-data-publication.*actions/checkout@v6.*locked-reconcile.*validate-site.ps1.*upload-pages-artifact.*deploy-pages') {
    throw 'Repair must re-read main and revalidate/reconcile/build/deploy under one lock'
}
if ($workflow -notmatch "needs.verify-repair.result != 'success'" -or $workflow -notmatch '-SourceCheckFailed') { throw 'Health reporting must include remote validation and source failures' }
Write-Output 'Autonomous recovery policy PASS: stale/green loop, verified NO_CHANGE, 6h/24h, capacity, failures, cooldown, repair race'
