param(
    [Parameter(Mandatory = $true)][ValidatePattern('^https://')][string]$ManifestUrl,
    [Parameter(Mandatory = $true)][ValidatePattern('^https://')][string]$DataQualityUrl,
    [Parameter(Mandatory = $true)][string]$ReleaseId,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedManifestSha256,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedDataQualitySha256
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

& (Join-Path $PSScriptRoot 'Test-RemotePublishCandidate.ps1') `
    -ManifestUrl $ManifestUrl `
    -DataQualityUrl $DataQualityUrl `
    -ReleaseId $ReleaseId

function Get-RemoteBytes([uri]$Uri) {
    $client = [Net.Http.HttpClient]::new()
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(60)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('TFT-Mobile-Overlay-Data/2.0 staged-hash-verifier')
        $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode) { throw "REMOTE_STAGED_HTTP status=$([int]$response.StatusCode) uri=$Uri" }
            if ($response.RequestMessage.RequestUri.Scheme -ne 'https') { throw "REMOTE_STAGED_NON_HTTPS_REDIRECT uri=$($response.RequestMessage.RequestUri)" }
            return $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        } finally { $response.Dispose() }
    } finally { $client.Dispose() }
}
function Get-Sha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

$manifestHash = Get-Sha256 (Get-RemoteBytes ([uri]$ManifestUrl))
$qualityHash = Get-Sha256 (Get-RemoteBytes ([uri]$DataQualityUrl))
if ($manifestHash -ne $ExpectedManifestSha256.ToLowerInvariant()) {
    throw "REMOTE_STAGED_MANIFEST_SHA_MISMATCH expected=$ExpectedManifestSha256 actual=$manifestHash"
}
if ($qualityHash -ne $ExpectedDataQualitySha256.ToLowerInvariant()) {
    throw "REMOTE_STAGED_QUALITY_SHA_MISMATCH expected=$ExpectedDataQualitySha256 actual=$qualityHash"
}
Write-Output "Remote staged candidate hashes passed: Release=$ReleaseId ManifestSha=$manifestHash QualitySha=$qualityHash"
