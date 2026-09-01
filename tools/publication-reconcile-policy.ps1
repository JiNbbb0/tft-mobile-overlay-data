Set-StrictMode -Version Latest

function Assert-DataQualityReleaseBinding {
    param(
        [Parameter(Mandatory = $true)]$Quality,
        [Parameter(Mandatory = $true)][string]$ExpectedVersionId,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $schemaVersion = [int]$Quality.schemaVersion
    if ($schemaVersion -notin @(1, 2)) {
        throw "$Context data-quality.json has an unsupported schema: $schemaVersion"
    }
    if ([string]$Quality.versionId -ne $ExpectedVersionId) {
        throw "$Context data-quality.json does not describe the expected latest version."
    }
    if ($schemaVersion -eq 2) {
        if ([string]$Quality.releaseId -ne $ExpectedVersionId) {
            throw "$Context Canonical v2 data-quality releaseId does not match the expected latest version."
        }
        if ([string]$Quality.overall -ne [string]$Quality.qualityState) {
            throw "$Context Canonical v2 overall/qualityState mismatch."
        }
    }
}

function Resolve-PublicationRequirement {
    param(
        [Parameter(Mandatory = $true)][string]$LocalVersionId,
        [Parameter(Mandatory = $true)][string]$LocalManifestSha256,
        [Parameter(Mandatory = $true)][bool]$RemoteReachable,
        [AllowEmptyString()][string]$RemoteVersionId = '',
        [AllowEmptyString()][string]$RemoteManifestSha256 = '',
        [AllowEmptyString()][string]$RemoteFailure = ''
    )

    if ($LocalVersionId -notmatch '^[a-z0-9._-]+$') {
        throw "Unsafe local version ID: $LocalVersionId"
    }
    if ($LocalManifestSha256 -notmatch '^[0-9a-f]{64}$') {
        throw 'Local manifest SHA-256 is invalid.'
    }

    if (-not $RemoteReachable) {
        return [pscustomobject][ordered]@{
            publishRequired = $true
            state = 'REMOTE_UNAVAILABLE'
            reason = $(if ($RemoteFailure) { $RemoteFailure } else { 'The public index could not be verified.' })
        }
    }
    if ($RemoteVersionId -ne $LocalVersionId) {
        return [pscustomobject][ordered]@{
            publishRequired = $true
            state = 'VERSION_MISMATCH'
            reason = "Public latest '$RemoteVersionId' does not match tracked latest '$LocalVersionId'."
        }
    }
    if ($RemoteManifestSha256 -notmatch '^[0-9a-f]{64}$') {
        return [pscustomobject][ordered]@{
            publishRequired = $true
            state = 'REMOTE_IDENTITY_MISSING'
            reason = 'The public manifest identity is missing or invalid.'
        }
    }
    if ($RemoteManifestSha256 -ne $LocalManifestSha256) {
        return [pscustomobject][ordered]@{
            publishRequired = $true
            state = 'MANIFEST_MISMATCH'
            reason = 'The public manifest SHA-256 does not match the tracked site.'
        }
    }

    return [pscustomobject][ordered]@{
        publishRequired = $false
        state = 'IN_SYNC'
        reason = 'The public latest version and manifest match the tracked site.'
    }
}
