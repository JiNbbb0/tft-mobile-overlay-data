$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'publication-reconcile-policy.ps1')
. (Join-Path $PSScriptRoot 'automation-health-policy.ps1')

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "$Message Expected=$Expected Actual=$Actual" }
}

$id = 'tftset17-17.9-r409-m1234567890'
$sha = 'a' * 64
$otherSha = 'b' * 64

$inSync = Resolve-PublicationRequirement -LocalVersionId $id -LocalManifestSha256 $sha -RemoteReachable $true -RemoteVersionId $id -RemoteManifestSha256 $sha
Assert-Equal $false $inSync.publishRequired 'Matching public data must not redeploy.'
Assert-Equal 'IN_SYNC' $inSync.state 'Matching state mismatch.'

$oldPublic = Resolve-PublicationRequirement -LocalVersionId $id -LocalManifestSha256 $sha -RemoteReachable $true -RemoteVersionId 'tftset17-17.9-r409-m0000000000' -RemoteManifestSha256 $otherSha
Assert-Equal $true $oldPublic.publishRequired 'An old public version must redeploy.'
Assert-Equal 'VERSION_MISMATCH' $oldPublic.state 'Old public state mismatch.'

$sameIdWrongContent = Resolve-PublicationRequirement -LocalVersionId $id -LocalManifestSha256 $sha -RemoteReachable $true -RemoteVersionId $id -RemoteManifestSha256 $otherSha
Assert-Equal $true $sameIdWrongContent.publishRequired 'A same-ID manifest mismatch must redeploy.'
Assert-Equal 'MANIFEST_MISMATCH' $sameIdWrongContent.state 'Manifest mismatch state mismatch.'

$identityMissing = Resolve-PublicationRequirement -LocalVersionId $id -LocalManifestSha256 $sha -RemoteReachable $true -RemoteVersionId $id -RemoteManifestSha256 ''
Assert-Equal $true $identityMissing.publishRequired 'A missing public manifest identity must redeploy.'
Assert-Equal 'REMOTE_IDENTITY_MISSING' $identityMissing.state 'Missing identity state mismatch.'

$unavailable = Resolve-PublicationRequirement -LocalVersionId $id -LocalManifestSha256 $sha -RemoteReachable $false -RemoteFailure 'HTTP 404'
Assert-Equal $true $unavailable.publishRequired 'An unavailable public site must redeploy.'
Assert-Equal 'REMOTE_UNAVAILABLE' $unavailable.state 'Unavailable state mismatch.'

$now = [DateTimeOffset]::Parse('2026-08-17T12:00:00Z')
$failures = @(1..4 | ForEach-Object { [pscustomobject]@{ conclusion = 'failure' } })
$failed = Resolve-AutomationHealth -CompletedRuns $failures -LastSuccessfulAt $now.AddHours(-1) -Now $now
Assert-Equal $true $failed.requiresAttention 'Four consecutive failures must require attention.'
Assert-Equal 4 $failed.consecutiveFailures 'Consecutive failure count mismatch.'

$healthy = Resolve-AutomationHealth -CompletedRuns @([pscustomobject]@{ conclusion = 'success' }) -LastSuccessfulAt $now.AddMinutes(-20) -Now $now
Assert-Equal $false $healthy.requiresAttention 'A recent success must be healthy.'

$stale = Resolve-AutomationHealth -CompletedRuns @([pscustomobject]@{ conclusion = 'success' }) -LastSuccessfulAt $now.AddHours(-7) -Now $now
Assert-Equal $true $stale.requiresAttention 'A success older than the SLA must require attention.'
Assert-Equal 'SUCCESS_STALE' $stale.reason 'Stale reason mismatch.'

$neverSuccessful = Resolve-AutomationHealth -CompletedRuns @() -LastSuccessfulAt $null -Now $now
Assert-Equal $true $neverSuccessful.requiresAttention 'Missing success history must require attention.'

$publicBroken = Resolve-AutomationHealth -CompletedRuns @([pscustomobject]@{ conclusion = 'success' }) -LastSuccessfulAt $now.AddMinutes(-5) -Now $now -PublicOutOfSync $true
Assert-Equal $true $publicBroken.requiresAttention 'A remaining public mismatch must require attention.'
Assert-Equal 'PUBLIC_OUT_OF_SYNC' $publicBroken.reason 'Public mismatch reason mismatch.'

Write-Output 'Publication reconciliation and automation health policy tests passed.'
