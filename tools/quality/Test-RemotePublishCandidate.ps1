param(
    [Parameter(Mandatory = $true)][ValidatePattern('^https://')][string]$ManifestUrl,
    [Parameter(Mandatory = $true)][ValidatePattern('^https://')][string]$DataQualityUrl,
    [Parameter(Mandatory = $true)][string]$ReleaseId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-ResponseBytes([uri]$Uri) {
    $client = [Net.Http.HttpClient]::new()
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(60)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('TFT-Mobile-Overlay-Data/2.0 remote-candidate-verifier')
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
                try {
                    if (-not $response.IsSuccessStatusCode) { throw "HTTP $([int]$response.StatusCode)" }
                    if ($response.RequestMessage.RequestUri.Scheme -ne 'https') { throw 'Redirect left HTTPS.' }
                    return [pscustomobject]@{
                        uri = $response.RequestMessage.RequestUri
                        bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                    }
                } finally { $response.Dispose() }
            } catch {
                if ($attempt -eq 3) { throw }
                Start-Sleep -Seconds (2 * $attempt)
            }
        }
    } finally { $client.Dispose() }
}
function Get-Sha256Hex([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Convert-BytesToJson([byte[]]$Bytes, [string]$Context) {
    try { return ([Text.Encoding]::UTF8.GetString($Bytes) | ConvertFrom-Json) }
    catch { throw "REMOTE_CANDIDATE_INVALID_JSON context=$Context" }
}

$manifestResponse = Get-ResponseBytes ([uri]$ManifestUrl)
$manifest = Convert-BytesToJson $manifestResponse.bytes 'manifest'
if ([string]$manifest.id -ne $ReleaseId) { throw "REMOTE_CANDIDATE_MANIFEST_ID_MISMATCH expected=$ReleaseId actual=$($manifest.id)" }

$qualityResponse = Get-ResponseBytes ([uri]$DataQualityUrl)
$quality = Convert-BytesToJson $qualityResponse.bytes 'data-quality'
if ([int]$quality.schemaVersion -ne 2 -or [string]$quality.releaseId -ne $ReleaseId -or [string]$quality.versionId -ne $ReleaseId) {
    throw "REMOTE_CANDIDATE_QUALITY_RELEASE_MISMATCH expected=$ReleaseId"
}

$rows = @($manifest.files)
if ($rows.Count -eq 0) { throw 'REMOTE_CANDIDATE_MANIFEST_EMPTY' }
foreach ($row in $rows) {
    if (-not $row.url -or -not $row.sha256) { throw 'REMOTE_CANDIDATE_MANIFEST_FILE_FIELDS_MISSING' }
    $fileUri = [uri]::new($manifestResponse.uri, [string]$row.url)
    if ($fileUri.Scheme -ne 'https') { throw "REMOTE_CANDIDATE_NON_HTTPS_FILE path=$($row.path)" }
    $response = Get-ResponseBytes $fileUri
    $length = [int64]$response.bytes.Length
    if ($row.PSObject.Properties['bytes'] -and [int64]$row.bytes -ne $length) {
        throw "REMOTE_CANDIDATE_SIZE_MISMATCH path=$($row.path) expected=$($row.bytes) actual=$length"
    }
    $hash = Get-Sha256Hex $response.bytes
    if ($hash -ne ([string]$row.sha256).ToLowerInvariant()) {
        throw "REMOTE_CANDIDATE_HASH_MISMATCH path=$($row.path) expected=$($row.sha256) actual=$hash"
    }
}

Write-Output "Remote publish candidate passed: Release=$ReleaseId Files=$($rows.Count) Manifest=$($manifestResponse.uri)"
