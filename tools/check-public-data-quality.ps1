param(
    [Parameter(Mandatory = $true)][ValidatePattern('^https://')][string]$DataIndexUrl,
    [int]$CatalogOnlyGraceHours = 2
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Set-ActionOutput([string]$Name, [string]$Value) {
    if ($env:GITHUB_OUTPUT) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$Name=$Value" -Encoding UTF8 }
}
function Get-Json([uri]$Uri) {
    $client = [Net.Http.HttpClient]::new()
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(45)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('TFT-Mobile-Overlay-Data/1.0 data-quality-watchdog')
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
                try {
                    if (-not $response.IsSuccessStatusCode) { throw "HTTP $([int]$response.StatusCode)" }
                    if ($response.RequestMessage.RequestUri.Scheme -ne 'https') { throw 'Redirect left HTTPS.' }
                    $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                    return $text | ConvertFrom-Json
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

$requiresAttention = $false
$qualityState = 'UNKNOWN'
$reason = 'OK'
try {
    $indexUri = [uri]$DataIndexUrl
    $qualityUri = [uri]::new($indexUri, 'data-quality.json')
    $index = Get-Json $indexUri
    $quality = Get-Json $qualityUri
    if ([int]$quality.schemaVersion -ne 1) { throw "Unsupported data-quality schema: $($quality.schemaVersion)" }
    $qualityState = [string]$quality.qualityState
    if ($qualityState -notin @('READY', 'DEGRADED_OPTIONAL', 'CATALOG_ONLY')) { throw "Unknown quality state: $qualityState" }
    if ([string]$quality.versionId -ne [string]$index.latestVersionId) {
        $requiresAttention = $true
        $reason = 'QUALITY_STATUS_OUT_OF_SYNC'
    } elseif ($qualityState -eq 'CATALOG_ONLY') {
        $generatedAt = [DateTimeOffset]::Parse([string]$quality.generatedAtUtc)
        $ageHours = ([DateTimeOffset]::UtcNow - $generatedAt).TotalHours
        if ($ageHours -ge $CatalogOnlyGraceHours) {
            $requiresAttention = $true
            $reason = 'CATALOG_ONLY_TOO_LONG'
        } else {
            $reason = 'CATALOG_ONLY_WITHIN_GRACE'
        }
    } elseif ($qualityState -eq 'DEGRADED_OPTIONAL') {
        $reason = 'DEGRADED_OPTIONAL_USABLE'
    }
} catch {
    $requiresAttention = $true
    $reason = 'QUALITY_STATUS_UNAVAILABLE_OR_INVALID'
    Write-Warning ($_.Exception.Message -replace '[\r\n]+', ' ')
}

Set-ActionOutput 'requires_attention' $requiresAttention.ToString().ToLowerInvariant()
Set-ActionOutput 'quality_state' $qualityState
Set-ActionOutput 'reason' $reason
Write-Output "Public data quality: State=$qualityState RequiresAttention=$requiresAttention Reason=$reason"
