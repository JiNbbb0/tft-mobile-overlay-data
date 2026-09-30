param(
    [Parameter(Mandatory=$true)][ValidatePattern('^https://')][string]$DataIndexUrl,
    [string]$SiteDirectory='site',
    [ValidateRange(1,6)][int]$Attempts=6
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

# Shared by refresh, redeploy, rollback and watchdog repair. No workflow is
# permitted to declare success using a weaker remote verification contract.
for ($attempt=1; $attempt -le $Attempts; $attempt++) {
    $separator = if ($DataIndexUrl.Contains('?')) { '&' } else { '?' }
    $checkUrl = "$DataIndexUrl${separator}verification=$([Guid]::NewGuid().ToString('N'))"
    try {
        & (Join-Path $PSScriptRoot 'validate-remote-site.ps1') -DataIndexUrl $checkUrl
        & (Join-Path $PSScriptRoot 'reconcile-publication.ps1') -SiteDirectory $SiteDirectory -DataIndexUrl $checkUrl -FailWhenOutOfSync
        # This checker reports attention rather than throwing; convert an invalid
        # or mismatching status into a publication failure, NOT a false PASS.
        $qualityResult = & (Join-Path $PSScriptRoot 'check-public-data-quality.ps1') -DataIndexUrl $checkUrl -ReturnResult
        if ($qualityResult.reason -in @('QUALITY_STATUS_OUT_OF_SYNC','QUALITY_STATUS_UNAVAILABLE_OR_INVALID')) {
            throw "Public quality verification failed: $($qualityResult.reason)"
        }
        Write-Output 'Publication verification PASS: HTTPS payloads, index/manifest SHA, data-quality alignment.'
        return
    } catch {
        if ($attempt -eq $Attempts) { throw }
        Write-Warning "Publication verification attempt $attempt did not converge; bounded retry."
        Start-Sleep -Seconds ([Math]::Min(50,10*$attempt))
    }
}
