param(
    [Parameter(Mandatory = $true)][ValidatePattern('^https://')][string]$DataIndexUrl,
    [int64]$MaximumIndexBytes = 1048576,
    [int64]$MaximumFileBytes = 31457280,
    [switch]$Full
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Net.Http
$client = [Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(60)
$client.DefaultRequestHeaders.UserAgent.ParseAdd("TFT-Mobile-Overlay-Data/1.0 remote-validator")

function Get-RemoteBytes([uri]$Uri, [int64]$Limit, [string[]]$AllowedContentTypes) {
    if ($Uri.Scheme -ne "https") { throw "Non-HTTPS URL refused: $Uri" }
    $response = $client.GetAsync($Uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    if (-not $response.IsSuccessStatusCode) { throw "HTTP $([int]$response.StatusCode): $Uri" }
    if ($response.RequestMessage.RequestUri.Scheme -ne "https") { throw "Redirect left HTTPS: $Uri" }
    $length = $response.Content.Headers.ContentLength
    if ($length -and $length -gt $Limit) { throw "Content-Length exceeds limit: $Uri" }
    $contentType = [string]$response.Content.Headers.ContentType.MediaType
    if ($AllowedContentTypes.Count -gt 0 -and $contentType -notin $AllowedContentTypes) { throw "Unexpected Content-Type '$contentType': $Uri" }
    $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    if ($bytes.LongLength -gt $Limit) { throw "Downloaded content exceeds limit: $Uri" }
    return $bytes
}

function Get-Json([uri]$Uri, [int64]$Limit) {
    $bytes = Get-RemoteBytes $Uri $Limit @('application/json','text/json','text/plain','application/octet-stream')
    try { return [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json } catch { throw "Invalid JSON: $Uri" }
}

function Get-Sha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '' } finally { $sha.Dispose() }
}

try {
    $indexUri = [uri]$DataIndexUrl
    if (-not $indexUri.AbsolutePath.EndsWith('/data-index.json', [StringComparison]::Ordinal)) { throw "URL must end with data-index.json" }
    $index = Get-Json $indexUri $MaximumIndexBytes
    if ([int]$index.schemaVersion -ne 1 -or -not $index.latestVersionId -or @($index.versions).Count -lt 1 -or @($index.versions).Count -gt 100) { throw "Invalid data-index structure" }
    $latest = @($index.versions | Where-Object { [string]$_.id -eq [string]$index.latestVersionId }) | Select-Object -First 1
    if (-not $latest) { throw "Latest version is missing" }
    $manifestUri = [uri]::new($indexUri, [string]$latest.manifestUrl)
    $manifest = Get-Json $manifestUri $MaximumIndexBytes
    if ([string]$manifest.id -ne [string]$latest.id -or [string]$manifest.setId -ne [string]$latest.setId -or [string]$manifest.patch -ne [string]$latest.patch -or [string]$manifest.revision -ne [string]$latest.revision) { throw "Index and manifest identity mismatch" }
    if (@($manifest.files).Count -lt 1 -or @($manifest.files).Count -gt 1500) { throw "Manifest file count is invalid" }
    $checks = @($manifest.files | Where-Object { $_.path -in @('tft/tft_catalog.json','tft_static_snapshot.json') })
    $image = @($manifest.files | Where-Object { [string]$_.path -like 'tft/images/*' }) | Select-Object -First 1
    if ($image) { $checks += $image }
    if ($Full) { $checks = @($manifest.files) }
    foreach ($entry in $checks) {
        if ([int64]$entry.bytes -gt $MaximumFileBytes) { throw "Manifest size exceeds limit: $($entry.path)" }
        $fileUri = [uri]::new($manifestUri, [string]$entry.url)
        $allowed = if ([string]$entry.path -match '\.json$') { @('application/json','text/json','text/plain','application/octet-stream') } elseif ([string]$entry.path -match '\.(png|jpg|jpeg|webp)$') { @('image/png','image/jpeg','image/webp','application/octet-stream') } else { @('text/plain','text/markdown','application/octet-stream') }
        $bytes = Get-RemoteBytes $fileUri ([int64]$entry.bytes) $allowed
        if ($bytes.LongLength -ne [int64]$entry.bytes) { throw "Downloaded size mismatch: $($entry.path)" }
        if ((Get-Sha256 $bytes) -ne [string]$entry.sha256) { throw "SHA-256 mismatch: $($entry.path)" }
    }
    Write-Output "Remote validation passed: Latest=$($latest.id) Files=$(@($manifest.files).Count) Checked=$($checks.Count) URL=$DataIndexUrl"
} finally {
    $client.Dispose()
}
