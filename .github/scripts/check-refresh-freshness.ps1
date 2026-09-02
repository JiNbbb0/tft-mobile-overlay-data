param(
    [Parameter(Mandatory = $true)][ValidatePattern('^https://')][string]$DataIndexUrl,
    [int]$MaxSourceAgeMinutes = 45
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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
try {
    $indexUri = [uri]$DataIndexUrl
    $qualityUri = [uri]::new($indexUri, 'data-quality.json')
    $index = Get-Json $indexUri
    $quality = Get-Json $qualityUri

    $latestVersionId = [string]$index.latestVersionId
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
            [string]$quality.sourceTimestampUtc
        } elseif ($quality.PSObject.Properties['sourceUpdatedAtUtc']) {
            [string]$quality.sourceUpdatedAtUtc
        } elseif ($quality.PSObject.Properties['generatedAtUtc']) {
            [string]$quality.generatedAtUtc
        } else {
            ''
        }
        if (-not $timestampValue) { throw 'No source timestamp is available in data-quality.json.' }
        $sourceTime = [DateTimeOffset]::Parse($timestampValue).ToUniversalTime()
        $sourceTimestamp = $sourceTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
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
Write-Output "Refresh freshness: NeedsRefresh=$needsRefresh Reason=$reason Source=$sourceTimestamp AgeMinutes=$([Math]::Round($ageMinutes, 1)) Limit=$MaxSourceAgeMinutes"
