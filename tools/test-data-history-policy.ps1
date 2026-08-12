$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "data-history-policy.ps1")

function Assert-Equal {
    param([object]$Expected, [object]$Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "$Message Expected=$Expected Actual=$Actual" }
}

$versions = @(
    [pscustomobject]@{ id = 'old-iso'; generatedAtUtc = '2026-08-09T16:40:51Z'; sourceTimestampUtc = '2026-08-09T16:40:51Z' },
    [pscustomobject]@{ id = 'latest-localized'; generatedAtUtc = '08/11/2026 19:49:44'; sourceTimestampUtc = '08/11/2026 19:48:00' }
)
$index = [pscustomobject]@{ latestVersionId = 'latest-localized'; versions = $versions }
$previous = Get-PreviousDataVersion -Index $index -Versions $versions
Assert-Equal 'latest-localized' $previous.id 'Declared latest must win over string sorting.'

$normalized = @(Normalize-DataVersionTimestamps -Versions $versions)
Assert-Equal '2026-08-11T19:49:44Z' $normalized[1].generatedAtUtc 'Localized GitHub timestamp must normalize to UTC ISO.'
Assert-Equal '2026-08-11T19:48:00Z' $normalized[1].sourceTimestampUtc 'Source timestamp must normalize to UTC ISO.'

$fallback = Get-PreviousDataVersion -Index ([pscustomobject]@{}) -Versions $normalized
Assert-Equal 'latest-localized' $fallback.id 'Timestamp fallback must compare normalized instants.'

$missingLatestFailed = $false
try {
    Get-PreviousDataVersion -Index ([pscustomobject]@{ latestVersionId = 'missing' }) -Versions $normalized | Out-Null
} catch {
    $missingLatestFailed = $true
}
Assert-Equal $true $missingLatestFailed 'A dangling latestVersionId must fail closed.'

$oldFingerprint = '1' * 64
$newFingerprint = '2' * 64
$publishedMeta = [pscustomobject]@{
    id = 'tftset17-17.9-r409-m1111111111'
    setId = 'TFTSet17'
    patch = '17.9'
    revision = '409'
    metaFingerprint = $oldFingerprint
    updateKind = 'META_UPDATE'
}
$same = Resolve-DataPublicationIdentity -Previous $publishedMeta -SetId 'TFTSet17' -Patch '17.9' -Revision '409' -MetaFingerprint $oldFingerprint -BaseVersionId 'tftset17-17.9-r409'
Assert-Equal 'tftset17-17.9-r409-m1111111111' $same.versionId 'Same content must keep its published META_UPDATE id.'
Assert-Equal $true $same.samePublishedContent 'Same fingerprint must be identified explicitly.'

$metaUpdate = Resolve-DataPublicationIdentity -Previous $publishedMeta -SetId 'TFTSet17' -Patch '17.9' -Revision '409' -MetaFingerprint $newFingerprint -BaseVersionId 'tftset17-17.9-r409'
Assert-Equal 'META_UPDATE' $metaUpdate.updateKind 'Changed fingerprint in the same revision must be META_UPDATE.'
Assert-Equal 'tftset17-17.9-r409-m2222222222' $metaUpdate.versionId 'META_UPDATE id must include the new fingerprint.'

Write-Output "Data history policy tests passed."
