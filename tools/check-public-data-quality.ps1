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
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('TFT-Mobile-Overlay-Data/2.0 data-quality-watchdog')
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
function Require-Property($Object, [string]$Name) {
    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) { throw "Missing data-quality property: $Name" }
    return $Object.PSObject.Properties[$Name].Value
}
function Assert-FeatureStatus($Features, [string]$Name) {
    $feature = Require-Property $Features $Name
    $status = [string](Require-Property $feature 'status')
    if ($status -notin @('READY','PARTIAL','COLLECTING','UNAVAILABLE','BLOCKED')) {
        throw "Unknown feature status: $Name=$status"
    }
    return $feature
}

$requiresAttention = $false
$qualityState = 'UNKNOWN'
$reason = 'OK'
try {
    $indexUri = [uri]$DataIndexUrl
    $qualityUri = [uri]::new($indexUri, 'data-quality.json')
    $index = Get-Json $indexUri
    $quality = Get-Json $qualityUri

    if ([int](Require-Property $quality 'schemaVersion') -ne 2) { throw "Unsupported data-quality schema: $($quality.schemaVersion)" }
    $releaseId = [string](Require-Property $quality 'releaseId')
    $versionId = [string](Require-Property $quality 'versionId')
    $latestVersionId = [string](Require-Property $index 'latestVersionId')
    if (-not $releaseId -or $releaseId -ne $versionId -or $releaseId -ne $latestVersionId) {
        $requiresAttention = $true
        $reason = 'QUALITY_STATUS_OUT_OF_SYNC'
    }

    $qualityState = [string](Require-Property $quality 'qualityState')
    $overall = [string](Require-Property $quality 'overall')
    if ($qualityState -notin @('READY', 'DEGRADED_OPTIONAL', 'CATALOG_ONLY')) { throw "Unknown quality state: $qualityState" }
    if ($overall -ne $qualityState) { throw "overall/qualityState mismatch: overall=$overall qualityState=$qualityState" }

    $features = Require-Property $quality 'features'
    $champions = Assert-FeatureStatus $features 'champions'
    $traits = Assert-FeatureStatus $features 'traits'
    $emblems = Assert-FeatureStatus $features 'emblems'
    $compositions = Assert-FeatureStatus $features 'compositions'
    $boards = Assert-FeatureStatus $features 'boards'
    $recommendedItems = Assert-FeatureStatus $features 'recommendedItems'
    $compositionAugments = Assert-FeatureStatus $features 'compositionAugments'

    if ([int](Require-Property $champions 'unresolvedTokens') -ne 0) { throw 'Champion unresolved tokens are non-zero.' }
    if ([int](Require-Property $traits 'unresolvedTokens') -ne 0) { throw 'Trait unresolved tokens are non-zero.' }
    if ([int](Require-Property $emblems 'missingEligible') -ne 0) { throw 'Eligible emblem mappings are missing.' }
    if ([int](Require-Property $emblems 'duplicateMappings') -ne 0) { throw 'Duplicate/ambiguous emblem mappings are present.' }
    if ([int](Require-Property $emblems 'missingImages') -ne 0) { throw 'Mapped emblems are missing images.' }

    if ([string](Require-Property $compositions 'filter') -ne 'PLATINUM_PLUS') { throw 'Composition filter is not PLATINUM_PLUS.' }
    $compositionSourceScope = [string](Require-Property $compositions 'sourceScope')
    $compositionCoverage = [string](Require-Property $compositions 'coverage')
    if ($compositionSourceScope -notin @('PLATINUM_PLUS','PLATINUM_PLUS_LIMITED')) { throw "Unknown composition source scope: $compositionSourceScope" }
    if ($compositionCoverage -notin @('SUFFICIENT','LIMITED')) { throw "Unknown composition coverage: $compositionCoverage" }
    if (($compositionSourceScope -eq 'PLATINUM_PLUS_LIMITED') -ne ($compositionCoverage -eq 'LIMITED')) { throw 'Composition source scope/coverage mismatch.' }
    if ($compositionCoverage -eq 'LIMITED') {
        if ([string]$compositions.status -ne 'PARTIAL' -or $qualityState -ne 'DEGRADED_OPTIONAL') { throw 'Limited Platinum+ coverage was not surfaced as PARTIAL/DEGRADED_OPTIONAL.' }
        if (@(Require-Property $quality 'warnings') -notcontains 'PLATINUM_PLUS_COVERAGE_LIMITED') { throw 'Limited Platinum+ coverage warning is missing.' }
    }
    if ([string](Require-Property $compositions 'queue') -ne 'RANKED') { throw 'Composition queue is not RANKED.' }
    if ([string](Require-Property $compositions 'patch') -ne 'CURRENT') { throw 'Composition patch scope is not CURRENT.' }
    if ([int](Require-Property $compositions 'days') -ne 3) { throw 'Composition statistics window is not 3 days.' }
    if ([bool](Require-Property $compositions 'permitFilterAdjustment')) { throw 'Composition filter adjustment must remain disabled.' }

    if ([int](Require-Property $boards 'syntheticBoardCount') -ne 0) { throw 'Synthetic boards are present.' }
    if ([int](Require-Property $boards 'unknownUnitCount') -ne 0) { throw 'Unknown board units are present.' }
    if ([int](Require-Property $recommendedItems 'unresolvedItemIds') -ne 0) { throw 'Recommended item IDs are unresolved.' }

    $counts = Require-Property $quality 'counts'
    if ([int](Require-Property $counts 'unresolvedTokens') -ne 0) { throw 'Global unresolved token count is non-zero.' }

    if (-not $requiresAttention) {
        if ($qualityState -eq 'CATALOG_ONLY') {
            $generatedAt = [DateTimeOffset]::Parse([string](Require-Property $quality 'generatedAtUtc'))
            $ageHours = ([DateTimeOffset]::UtcNow - $generatedAt).TotalHours
            if ($ageHours -ge $CatalogOnlyGraceHours) {
                $requiresAttention = $true
                $reason = 'CATALOG_ONLY_TOO_LONG'
            } else {
                $reason = 'CATALOG_ONLY_WITHIN_GRACE'
            }
        } elseif ($qualityState -eq 'DEGRADED_OPTIONAL') {
            $blockingStatuses = @(
                [string]$champions.status,
                [string]$traits.status,
                [string]$emblems.status,
                [string]$compositions.status
            ) | Where-Object { $_ -in @('UNAVAILABLE','BLOCKED') }
            if ($blockingStatuses.Count -gt 0) {
                $requiresAttention = $true
                $reason = 'DEGRADED_REQUIRED_FEATURE_BLOCKED'
            } else {
                $reason = 'DEGRADED_OPTIONAL_USABLE'
            }
        } else {
            $notReady = @($features.PSObject.Properties | ForEach-Object { [string]$_.Value.status } | Where-Object { $_ -ne 'READY' })
            if ($notReady.Count -gt 0) { throw 'overall READY but at least one feature is not READY.' }
            $reason = 'READY'
        }
    }
} catch {
    $requiresAttention = $true
    $reason = 'QUALITY_STATUS_UNAVAILABLE_OR_INVALID'
    Write-Warning ($_.Exception.Message -replace '[\r\n]+', ' ')
}

Set-ActionOutput 'requires_attention' $requiresAttention.ToString().ToLowerInvariant()
Set-ActionOutput 'quality_state' $qualityState
Set-ActionOutput 'reason' $reason
Write-Output "Public data quality v2: State=$qualityState RequiresAttention=$requiresAttention Reason=$reason"
