param(
    [string]$SiteDirectory = 'site',
    [Parameter(Mandatory = $true)][ValidatePattern('^https://')][string]$DataIndexUrl,
    [switch]$FailWhenOutOfSync
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Net.Http
. (Join-Path $PSScriptRoot 'publication-reconcile-policy.ps1')

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$siteRoot = if ([IO.Path]::IsPathRooted($SiteDirectory)) {
    [IO.Path]::GetFullPath($SiteDirectory)
} else {
    [IO.Path]::GetFullPath((Join-Path $repositoryRoot $SiteDirectory))
}
$repositoryPrefix = $repositoryRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $siteRoot.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'SiteDirectory must stay inside the repository.'
}

function Set-ActionOutput([string]$Name, [string]$Value) {
    if ($env:GITHUB_OUTPUT) {
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$Name=$Value" -Encoding UTF8
    }
}

function Get-Sha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    } finally {
        $sha.Dispose()
    }
}

function Get-RemoteBytes([uri]$Uri, [int64]$MaximumBytes) {
    $client = [Net.Http.HttpClient]::new()
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(45)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('TFT-Mobile-Overlay-Data/1.0 publication-reconciler')
        $lastFailure = ''
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                $response = $client.GetAsync($Uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                try {
                    if (-not $response.IsSuccessStatusCode) {
                        $lastFailure = "HTTP $([int]$response.StatusCode)"
                        if ([int]$response.StatusCode -notin @(408, 429, 500, 502, 503, 504)) { break }
                    } else {
                        if ($response.RequestMessage.RequestUri.Scheme -ne 'https') { throw 'Redirect left HTTPS.' }
                        $length = $response.Content.Headers.ContentLength
                        if ($length -and $length -gt $MaximumBytes) { throw 'Content-Length exceeds the safety limit.' }
                        $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                        if ($bytes.LongLength -gt $MaximumBytes) { throw 'Downloaded content exceeds the safety limit.' }
                        return $bytes
                    }
                } finally {
                    $response.Dispose()
                }
            } catch {
                $lastFailure = $_.Exception.Message
            }
            if ($attempt -lt 3) { Start-Sleep -Seconds (2 * $attempt) }
        }
        throw "Remote request failed after 3 attempts: $lastFailure"
    } finally {
        $client.Dispose()
    }
}

$indexPath = Join-Path $siteRoot 'data-index.json'
if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { throw 'Tracked data-index.json is missing.' }
$localIndex = Get-Content -Raw -Encoding UTF8 -LiteralPath $indexPath | ConvertFrom-Json
$localVersion = @($localIndex.versions | Where-Object { [string]$_.id -eq [string]$localIndex.latestVersionId }) | Select-Object -First 1
if (-not $localVersion) { throw 'Tracked latest version is missing from data-index.json.' }
$localManifestPath = Join-Path $siteRoot ([string]$localVersion.manifestUrl).Replace('/', [IO.Path]::DirectorySeparatorChar)
$localManifestPath = [IO.Path]::GetFullPath($localManifestPath)
if (-not $localManifestPath.StartsWith($siteRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Tracked manifest path escaped the site root.'
}
if (-not (Test-Path -LiteralPath $localManifestPath -PathType Leaf)) { throw 'Tracked latest manifest is missing.' }
$localManifestBytes = [IO.File]::ReadAllBytes($localManifestPath)
$localManifestSha = Get-Sha256 $localManifestBytes
if ($localVersion.PSObject.Properties['manifestSha256'] -and [string]$localVersion.manifestSha256 -and [string]$localVersion.manifestSha256 -ne $localManifestSha) {
    throw 'Tracked index manifest SHA-256 does not match the tracked manifest.'
}

$remoteReachable = $false
$remoteVersionId = ''
$remoteManifestSha = ''
$remoteFailure = ''
try {
    $indexUri = [uri]$DataIndexUrl
    $remoteIndexBytes = Get-RemoteBytes -Uri $indexUri -MaximumBytes 1MB
    $remoteIndex = [Text.Encoding]::UTF8.GetString($remoteIndexBytes) | ConvertFrom-Json
    $remoteVersion = @($remoteIndex.versions | Where-Object { [string]$_.id -eq [string]$remoteIndex.latestVersionId }) | Select-Object -First 1
    if (-not $remoteVersion) { throw 'Public latest version is missing from its index.' }
    $remoteVersionId = [string]$remoteVersion.id
    $manifestUri = [uri]::new($indexUri, [string]$remoteVersion.manifestUrl)
    if ($manifestUri.Scheme -ne 'https' -or -not $manifestUri.Host.Equals($indexUri.Host, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Public manifest URL left the configured HTTPS host.'
    }
    $remoteManifestSha = Get-Sha256 (Get-RemoteBytes -Uri $manifestUri -MaximumBytes 1MB)
    if ($remoteVersion.PSObject.Properties['manifestSha256'] -and [string]$remoteVersion.manifestSha256) {
        if ([string]$remoteVersion.manifestSha256 -ne $remoteManifestSha) {
            throw 'Public index manifest SHA-256 does not match the public manifest.'
        }
    }
    $remoteReachable = $true
} catch {
    $remoteFailure = $_.Exception.Message -replace '[\r\n]+', ' '
}

$decision = Resolve-PublicationRequirement `
    -LocalVersionId ([string]$localVersion.id) `
    -LocalManifestSha256 $localManifestSha `
    -RemoteReachable $remoteReachable `
    -RemoteVersionId $remoteVersionId `
    -RemoteManifestSha256 $remoteManifestSha `
    -RemoteFailure $remoteFailure

Set-ActionOutput 'publish_required' $decision.publishRequired.ToString().ToLowerInvariant()
Set-ActionOutput 'public_state' ([string]$decision.state)
Set-ActionOutput 'local_version' ([string]$localVersion.id)
Set-ActionOutput 'public_version' $remoteVersionId
Set-ActionOutput 'local_manifest_sha256' $localManifestSha
Set-ActionOutput 'public_manifest_sha256' $remoteManifestSha

Write-Output "Publication reconciliation: Required=$($decision.publishRequired) State=$($decision.state) Local=$($localVersion.id) Public=$remoteVersionId"
Write-Output "Reason=$($decision.reason)"
if ($FailWhenOutOfSync -and $decision.publishRequired) {
    throw "Public publication remains out of sync: $($decision.state)"
}
