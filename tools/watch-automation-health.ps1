param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$Repository,
    [Parameter(Mandatory = $true)][string]$GitHubToken,
    [bool]$PublicOutOfSync = $false,
    [bool]$DataQualityRequiresAttention = $false,
    [string]$DataQualityReason = 'OK',
    [int]$FailureThreshold = 4,
    [int]$StaleHours = 6,
    [double]$SourceAgeMinutes = -1,
    [bool]$SourceCheckFailed = $false
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'automation-health-policy.ps1')

$apiRoot = "https://api.github.com/repos/$Repository"
$headers = @{
    Authorization = "Bearer $GitHubToken"
    Accept = 'application/vnd.github+json'
    'User-Agent' = 'TFT-Mobile-Overlay-Data/1.0 automation-watchdog'
    'X-GitHub-Api-Version' = '2022-11-28'
}
$issueTitle = '[automation-health] TFT data publication requires attention'
$issueLabel = 'automation-health'

function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Get','Post','Patch')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [AllowNull()][object]$Body = $null
    )
    $parameters = @{
        Method = $Method
        Uri = $Uri
        Headers = $headers
        TimeoutSec = 45
    }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = $Body | ConvertTo-Json -Depth 8 -Compress
    }
    return Invoke-RestMethod @parameters
}

$completedResponse = Invoke-GitHubApi -Method Get -Uri "$apiRoot/actions/workflows/refresh-tft-data.yml/runs?status=completed&per_page=20"
$completedRuns = @($completedResponse.workflow_runs)
$successResponse = Invoke-GitHubApi -Method Get -Uri "$apiRoot/actions/workflows/refresh-tft-data.yml/runs?status=success&per_page=1"
$lastSuccessRun = @($successResponse.workflow_runs) | Select-Object -First 1
$lastSuccessAt = if ($lastSuccessRun) { ConvertTo-AutomationTimestamp $lastSuccessRun.updated_at } else { $null }
$trackedSite = Join-Path $PSScriptRoot '../site'
$siteBytes = (Get-ChildItem -LiteralPath $trackedSite -File -Recurse | Measure-Object Length -Sum).Sum
$versionCount = @((Get-Content -Raw -LiteralPath (Join-Path $trackedSite 'data-index.json') | ConvertFrom-Json).versions).Count
$health = Resolve-AutomationHealth `
    -CompletedRuns $completedRuns `
    -LastSuccessfulAt $lastSuccessAt `
    -Now ([DateTimeOffset]::UtcNow) `
    -FailureThreshold $FailureThreshold `
    -StaleHours $StaleHours `
    -PublicOutOfSync $PublicOutOfSync `
    -SourceAgeMinutes $SourceAgeMinutes `
    -SourceCheckFailed $SourceCheckFailed `
    -CapacityPercent ($siteBytes / 250MB * 100) `
    -VersionCount $versionCount

$requiresAttention = [bool]$health.requiresAttention -or $DataQualityRequiresAttention
$combinedReason = if ($DataQualityRequiresAttention) {
    "DATA_QUALITY:$DataQualityReason"
} else {
    [string]$health.reason
}

$openIssues = @(Invoke-GitHubApi -Method Get -Uri "$apiRoot/issues?state=open&per_page=100")
$matchingIssues = @($openIssues | Where-Object {
    $_ -and $_.PSObject.Properties['title'] -and [string]$_.title -eq $issueTitle
})
$existingIssue = $matchingIssues | Select-Object -First 1
$duplicateIssues = @($matchingIssues | Select-Object -Skip 1)

if ($requiresAttention) {
    if (-not $existingIssue) {
        try {
            Invoke-GitHubApi -Method Post -Uri "$apiRoot/labels" -Body ([ordered]@{
                name = $issueLabel
                color = 'd73a4a'
                description = 'Sanitized alert for unattended TFT data publication.'
            }) | Out-Null
        } catch {
            $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($status -ne 422) { throw }
        }
        $latestRun = $completedRuns | Select-Object -First 1
        $latestRunUrl = if ($latestRun) { [string]$latestRun.html_url } else { "https://github.com/$Repository/actions" }
        $body = @"
The GitHub-only watchdog detected that unattended TFT data publication needs attention.

- Health reason: $combinedReason
- Consecutive failed refresh runs: $($health.consecutiveFailures)
- No successful refresh within $StaleHours hours: $($health.stale)
- Public site out of sync at watchdog check: $PublicOutOfSync
- Public data quality requires attention: $DataQualityRequiresAttention
- Public data quality reason: $DataQualityReason
- Source verification age (minutes): $SourceAgeMinutes
- Source check failed: $SourceCheckFailed
- Capacity warning (bytes or retained version count): $($health.capacityWarning)
- Latest refresh run: $latestRunUrl

The tracked last-known-good bundle has not been replaced by an unvalidated bundle. Public availability and user-visible data quality are checked separately. This issue intentionally contains no credentials, request headers, local paths, or raw failure logs. It will close automatically after the scheduled pipeline recovers.
"@
        $existingIssue = Invoke-GitHubApi -Method Post -Uri "$apiRoot/issues" -Body ([ordered]@{
            title = $issueTitle
            body = $body
            labels = @($issueLabel)
        })
        Write-Output "Opened automation health issue #$($existingIssue.number)."
    } else {
        foreach ($duplicate in $duplicateIssues) {
            Invoke-GitHubApi -Method Patch -Uri "$apiRoot/issues/$($duplicate.number)" -Body ([ordered]@{ state='closed' }) | Out-Null
        }
        if ([string]$existingIssue.body -notmatch [regex]::Escape("- Health reason: $combinedReason")) {
            $body = @"
The GitHub-only watchdog still requires attention. This is a severity update, not a duplicate alert.

- Health reason: $combinedReason
- Consecutive failed refresh runs: $($health.consecutiveFailures)
- Source verification age (minutes): $SourceAgeMinutes
- Source check failed: $SourceCheckFailed
- Public site out of sync: $PublicOutOfSync
- Public data quality reason: $DataQualityReason
- Capacity warning (bytes or retained version count): $($health.capacityWarning)

Only validated last-known-good data may be served. The bounded live window must retain the current LKG. Review the Actions summary; no credentials, raw request logs or device identifiers are included here.
"@
            Invoke-GitHubApi -Method Patch -Uri "$apiRoot/issues/$($existingIssue.number)" -Body ([ordered]@{ body=$body }) | Out-Null
        }
        Write-Output "Automation health issue #$($existingIssue.number) remains open; no duplicate was created."
    }
} elseif ($matchingIssues.Count) {
    foreach ($resolvedIssue in $matchingIssues) {
        Invoke-GitHubApi -Method Patch -Uri "$apiRoot/issues/$($resolvedIssue.number)" -Body ([ordered]@{ state='closed' }) | Out-Null
    }
    Write-Output "Closed $($matchingIssues.Count) recovered automation health issue(s)."
} else {
    Write-Output 'Automation is healthy; no issue action was needed.'
}

if ($env:GITHUB_STEP_SUMMARY) {
    @"
## TFT automation watchdog

- Result: $combinedReason
- Consecutive refresh failures: $($health.consecutiveFailures)
- Successful refresh stale: $($health.stale)
- Public site out of sync: $PublicOutOfSync
- Public data quality requires attention: $DataQualityRequiresAttention
- Public data quality reason: $DataQualityReason
- Source verification age (minutes): $SourceAgeMinutes
- Source check failed: $SourceCheckFailed
- Capacity warning (bytes or retained version count): $($health.capacityWarning)
- Alert issue open: $requiresAttention
"@ | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding UTF8
}
