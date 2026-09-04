$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'material-publication-policy.ps1')

function Assert-Decision([bool]$ExpectedPublish, [string]$ExpectedReason, $Decision, [string]$Message) {
    if ([bool]$Decision.publish -ne $ExpectedPublish -or [string]$Decision.reason -ne $ExpectedReason) {
        throw "$Message Publish=$($Decision.publish) Reason=$($Decision.reason)"
    }
}
$a = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$b = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$base = [DateTimeOffset]::Parse('2026-01-01T00:00:00Z')

$under = Resolve-MaterialPublicationDecision -PreviousContentFingerprint $a -CurrentContentFingerprint $a `
    -PreviousSourceTimestampUtc $base -CurrentSourceTimestampUtc $base.AddHours(5.75)
Assert-Decision $false 'NO_CHANGE' $under 'A sub-six-hour timestamp-only observation must be coalesced.'
if ($under.metadataRefreshDue) { throw 'A sub-six-hour identical observation must not refresh metadata yet.' }

$due = Resolve-MaterialPublicationDecision -PreviousContentFingerprint $a -CurrentContentFingerprint $a `
    -PreviousSourceTimestampUtc $base -CurrentSourceTimestampUtc $base.AddHours(6)
Assert-Decision $false 'OBSERVATION_STATUS_REFRESH' $due 'A six-hour source advance must not create a duplicate immutable version.'
if (-not $due.metadataRefreshDue) { throw 'A six-hour source advance did not request a mutable status refresh.' }
if ($due.useObservationIdentity) { throw 'Identical content must never request a second immutable identity.' }

$material = Resolve-MaterialPublicationDecision -PreviousContentFingerprint $a -CurrentContentFingerprint $b `
    -PreviousSourceTimestampUtc $base -CurrentSourceTimestampUtc $base.AddMinutes(15)
Assert-Decision $true 'MATERIAL_CHANGE' $material 'A material change must publish immediately.'

$lastObserved = $base
$publicationCount = 0
$metadataRefreshCount = 0
foreach ($step in 1..200) {
    $current = $base.AddMinutes(15 * $step)
    $decision = Resolve-MaterialPublicationDecision -PreviousContentFingerprint $a -CurrentContentFingerprint $a `
        -PreviousSourceTimestampUtc $lastObserved -CurrentSourceTimestampUtc $current
    if ($decision.publish) { $publicationCount++ }
    if ($decision.metadataRefreshDue) { $metadataRefreshCount++; $lastObserved = $current }
}
if ($publicationCount -ne 0) { throw "Identical content created immutable versions: $publicationCount" }
if ($metadataRefreshCount -ne 8) { throw "Unexpected mutable status refresh count across 200 checks: $metadataRefreshCount" }

$fingerprint = & (Join-Path $PSScriptRoot 'get-publication-fingerprint.ps1') -ContentFingerprint $a `
    -SourceTimestampUtc '2026-01-01T06:00:00Z' -ObservationRefresh
if ($fingerprint -notmatch '^[0-9a-f]{64}$' -or $fingerprint -eq $a) { throw 'Observation fingerprint is not collision-safe.' }
Write-Output 'Content-only immutable publication policy fixtures passed.'
