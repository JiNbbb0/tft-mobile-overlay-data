$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'automation-health-policy.ps1')
. (Join-Path $PSScriptRoot '../.github/scripts/independent-clock-health.ps1')
$taskNow = [DateTimeOffset]'2026-10-12T00:00:00Z'
$cases = @(
    @{ name='legacy valid'; valid=$true; health=@{schemaVersion=1;status='CHECKED';checkedAt=$taskNow.ToString('o')} },
    @{ name='clock valid'; valid=$true; health=@{schemaVersion=2;mode='CLOCK_ONLY';dataVerification='GITHUB_WORKFLOW';status='CLOCK_ALIVE';checkedAt=$taskNow.ToString('o');lastAcceptedAt=$taskNow.AddMinutes(-15).ToString('o')} },
    @{ name='stopped clock'; valid=$false; health=@{schemaVersion=2;mode='CLOCK_ONLY';dataVerification='GITHUB_WORKFLOW';status='CLOCK_ALIVE';checkedAt=$taskNow.AddMinutes(-13).ToString('o');lastAcceptedAt=$taskNow.AddMinutes(-15).ToString('o')} },
    @{ name='no accepted trigger'; valid=$false; health=@{schemaVersion=2;mode='CLOCK_ONLY';dataVerification='GITHUB_WORKFLOW';status='CLOCK_ALIVE';checkedAt=$taskNow.ToString('o')} },
    @{ name='trigger overdue'; valid=$false; health=@{schemaVersion=2;mode='CLOCK_ONLY';dataVerification='GITHUB_WORKFLOW';status='CLOCK_ALIVE';checkedAt=$taskNow.ToString('o');lastAcceptedAt=$taskNow.AddMinutes(-31).ToString('o')} },
    @{ name='future trigger'; valid=$false; health=@{schemaVersion=2;mode='CLOCK_ONLY';dataVerification='GITHUB_WORKFLOW';status='CLOCK_ALIVE';checkedAt=$taskNow.ToString('o');lastAcceptedAt=$taskNow.AddMinutes(3).ToString('o')} },
    @{ name='wrong semantics'; valid=$false; health=@{schemaVersion=2;mode='CLOCK_ONLY';dataVerification='ASSUMED';status='CLOCK_ALIVE';checkedAt=$taskNow.ToString('o');lastAcceptedAt=$taskNow.ToString('o')} },
    @{ name='unknown contract'; valid=$false; health=@{schemaVersion=3;status='CHECKED';checkedAt=$taskNow.ToString('o')} }
)
foreach ($case in $cases) {
    if ((Test-IndependentClockHealth -Health ([pscustomobject]$case.health) -Now $taskNow) -ne $case.valid) { throw "Clock contract failed: $($case.name)" }
}
if (Test-IndependentClockHealth -Health ([pscustomobject]$cases[1].health) -Now $taskNow -HttpStatus 503) { throw 'HTTP failure must not be green' }
Write-Output 'Independent clock health: 9/9 PASS'
