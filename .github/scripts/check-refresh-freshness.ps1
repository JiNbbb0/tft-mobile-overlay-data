param(
    [Parameter(Mandatory = $true)][ValidatePattern('^https://')][string]$DataIndexUrl,
    [int]$MaxSourceAgeMinutes = 45,
    [string]$Repository = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../../tools/automation-health-policy.ps1')

# A NO_CHANGE run is fresh evidence, not a new immutable data version. Only
# completed successful main runs and matching-version observations may extend
# the verification clock. SOURCE_NOT_READY must never reset it.
function Get-VerifiedObservationTime([string]$VersionId) {
    if (-not $Repository) { return $null }
    if ($Repository -notmatch '^[\w.-]+/[\w.-]+$') { throw 'Invalid repository' }
    $raw = gh api "repos/$Repository/actions/workflows/refresh-tft-data.yml/runs?status=success&per_page=10"
    if ($LASTEXITCODE -ne 0) { throw 'Observation run lookup failed' }
    foreach ($run in @((($raw -join "`n") | ConvertFrom-Json).workflow_runs)) {
        if ($run.head_branch -ne 'main' -or $run.status -ne 'completed' -or $run.conclusion -ne 'success') { continue }
        $runId = [string]$run.id
        if ($runId -notmatch '^\d+$') { continue }
        $artifactName = "refresh-observation-$runId"
        $rawArtifacts = gh api "repos/$Repository/actions/runs/$runId/artifacts?per_page=30"
        if ($LASTEXITCODE -ne 0) { throw 'Observation artifact lookup failed' }
        $artifact = @((($rawArtifacts -join "`n") | ConvertFrom-Json).artifacts | Where-Object {
            $_.name -ceq $artifactName -and -not $_.expired -and $_.size_in_bytes -lt 65536
        }) | Select-Object -First 1
        if (-not $artifact) { continue }
        $directory = Join-Path $PSScriptRoot ("../../build/watch-observation-" + [guid]::NewGuid().ToString('N'))
        gh run download $runId --repo $Repository --name $artifactName --dir $directory
        if ($LASTEXITCODE -ne 0) { throw 'Observation download failed' }
        $observation = Get-Content -Raw -LiteralPath (Join-Path $directory 'refresh-observation.json') | ConvertFrom-Json
        if (Test-RefreshObservation -Observation $observation -VersionId $VersionId -RunId $runId) {
            return ConvertTo-AutomationTimestamp $observation.checkedAtUtc
        }
    }
    return $null
}

function Set-ActionOutput([string]$Name, [string]$Value) {
    if ($env:GITHUB_OUTPUT) {
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$Name=$Value" -Encoding UTF8
    }
}

function Get-Json([uri]$Uri) {
    $client = [Net.Http.HttpClient]::new()
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(45)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('TFT-Mobile-Overlay-Data/2.0 freshness-watchdog')
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
                try {
                    if (-not $response.IsSuccessStatusCode) { throw "HTTP $([int]$response.StatusCode)" }
                    if ($response.RequestMessage.RequestUri.Scheme -ne 'https') { throw 'Redirect left HTTPS.' }
                    return ($response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json)
                } finally {
                    $response.Dispose()
                }
            } catch {
                if ($attempt -eq 3) { throw }
                Start-Sleep -Seconds (2 * $attempt)
            }
        }
    } finally {
        $client.Dispose()
    }
}

$needsRefresh = $true
$reason = 'UNKNOWN'
$sourceTimestamp = ''
$ageMinutes = -1.0
$verificationBasis = 'PUBLISHED_SOURCE_TIMESTAMP'
try {
    $indexUri = [uri]$DataIndexUrl
    $qualityUri = [uri]::new($indexUri, 'data-quality.json')
    $index = Get-Json $indexUri
    $quality = Get-Json $qualityUri

    $latestVersionId = if ($index.PSObject.Properties['latestAvailableVersionId']) { [string]$index.latestAvailableVersionId } else { [string]$index.latestVersionId }
    if (-not $latestVersionId) { throw 'data-index latestVersionId is empty.' }

    $qualityVersionId = if ($quality.PSObject.Properties['releaseId']) {
        [string]$quality.releaseId
    } elseif ($quality.PSObject.Properties['versionId']) {
        [string]$quality.versionId
    } else {
        ''
    }
    if (-not $qualityVersionId -or $qualityVersionId -ne $latestVersionId) {
        $reason = 'QUALITY_OUT_OF_SYNC'
    } else {
        $timestampValue = if ($quality.PSObject.Properties['sourceTimestampUtc']) {
            $quality.sourceTimestampUtc
        } elseif ($quality.PSObject.Properties['sourceUpdatedAtUtc']) {
            $quality.sourceUpdatedAtUtc
        } elseif ($quality.PSObject.Properties['generatedAtUtc']) {
            $quality.generatedAtUtc
        } else {
            ''
        }
        if (-not $timestampValue) { throw 'No source timestamp is available in data-quality.json.' }
        $sourceTime = ConvertTo-AutomationTimestamp $timestampValue
        $sourceTimestamp = $sourceTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $observationTime = Get-VerifiedObservationTime $latestVersionId
        if ($null -ne $observationTime -and $observationTime -gt $sourceTime) {
            $sourceTime = $observationTime
            $verificationBasis = 'VERIFIED_REFRESH_OBSERVATION'
        }
        $ageMinutes = ([DateTimeOffset]::UtcNow - $sourceTime).TotalMinutes
        if ($ageMinutes -lt -2) { throw 'Source timestamp is unexpectedly in the future.' }
        if ($ageMinutes -gt $MaxSourceAgeMinutes) {
            $reason = 'SOURCE_STALE'
        } else {
            $needsRefresh = $false
            $reason = 'FRESH'
        }
    }
} catch {
    $reason = 'FRESHNESS_CHECK_FAILED'
    Write-Warning ($_.Exception.Message -replace '[\r\n]+', ' ')
}

Set-ActionOutput 'needs_refresh' $needsRefresh.ToString().ToLowerInvariant()
Set-ActionOutput 'reason' $reason
Set-ActionOutput 'source_timestamp_utc' $sourceTimestamp
Set-ActionOutput 'age_minutes' ([Math]::Round($ageMinutes, 1).ToString([Globalization.CultureInfo]::InvariantCulture))
Set-ActionOutput 'verification_basis' $verificationBasis
Write-Output "Refresh freshness: NeedsRefresh=$needsRefresh Reason=$reason Source=$sourceTimestamp VerificationBasis=$verificationBasis AgeMinutes=$([Math]::Round($ageMinutes, 1)) Limit=$MaxSourceAgeMinutes"
