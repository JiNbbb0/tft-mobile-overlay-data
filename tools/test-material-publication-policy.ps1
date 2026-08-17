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
Assert-Decision $false 'NO_CHANGE' $under 'A sub-six-hour sample-only change must be coalesced.'

$due = Resolve-MaterialPublicationDecision -PreviousContentFingerprint $a -CurrentContentFingerprint $a `
    -PreviousSourceTimestampUtc $base -CurrentSourceTimestampUtc $base.AddHours(6)
Assert-Decision $true 'OBSERVATION_REFRESH' $due 'A six-hour source advance must refresh freshness evidence.'
if (-not $due.useObservationIdentity) { throw 'Observation refresh did not request a collision-safe identity.' }

$material = Resolve-MaterialPublicationDecision -PreviousContentFingerprint $a -CurrentContentFingerprint $b `
    -PreviousSourceTimestampUtc $base -CurrentSourceTimestampUtc $base.AddMinutes(15)
Assert-Decision $true 'MATERIAL_CHANGE' $material 'A material change must publish immediately.'

$lastPublished = $base
$publicationCount = 0
foreach ($step in 1..200) {
    $current = $base.AddMinutes(15 * $step)
    $decision = Resolve-MaterialPublicationDecision -PreviousContentFingerprint $a -CurrentContentFingerprint $a `
        -PreviousSourceTimestampUtc $lastPublished -CurrentSourceTimestampUtc $current
    if ($decision.publish) { $publicationCount++; $lastPublished = $current }
}
if ($publicationCount -ne 8) { throw "Unexpected publication count across 200 checks: $publicationCount" }

$fingerprint = & (Join-Path $PSScriptRoot 'get-publication-fingerprint.ps1') -ContentFingerprint $a `
    -SourceTimestampUtc '2026-01-01T06:00:00Z' -ObservationRefresh
if ($fingerprint -notmatch '^[0-9a-f]{64}$' -or $fingerprint -eq $a) { throw 'Observation fingerprint is not collision-safe.' }
Write-Output 'Six-hour material publication policy fixtures passed.'
