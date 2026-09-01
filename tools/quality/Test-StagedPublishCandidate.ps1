param(
    [Parameter(Mandatory = $true)][string]$SiteDirectory,
    [Parameter(Mandatory = $true)][string]$ReleaseId,
    [string]$DataQualityPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$siteRoot = [IO.Path]::GetFullPath($SiteDirectory)
if (-not $DataQualityPath) { $DataQualityPath = Join-Path $siteRoot "bundles/$ReleaseId/data-quality.json" }
$qualityFull = if ([IO.Path]::IsPathRooted($DataQualityPath)) { [IO.Path]::GetFullPath($DataQualityPath) } else { [IO.Path]::GetFullPath((Join-Path $siteRoot $DataQualityPath)) }

& (Join-Path $PSScriptRoot 'Test-PublishCandidate.ps1') `
    -SiteDirectory $siteRoot `
    -ReleaseId $ReleaseId `
    -DataQualityPath $qualityFull

$indexPath = Join-Path $siteRoot 'data-index.json'
$index = Get-Content -Raw -Encoding UTF8 -LiteralPath $indexPath | ConvertFrom-Json
if ([string]$index.latestVersionId -eq $ReleaseId) {
    throw "STAGED_CANDIDATE_ALREADY_LATEST release=$ReleaseId"
}
$version = @($index.versions | Where-Object { [string]$_.id -eq $ReleaseId }) | Select-Object -First 1
if (-not $version) { throw "STAGED_CANDIDATE_NOT_REGISTERED release=$ReleaseId" }
if (-not $index.latestVersionId) { throw 'STAGED_CANDIDATE_LKG_MISSING' }
$lkg = @($index.versions | Where-Object { [string]$_.id -eq [string]$index.latestVersionId }) | Select-Object -First 1
if (-not $lkg) { throw "STAGED_CANDIDATE_LKG_NOT_REGISTERED release=$($index.latestVersionId)" }

$manifestPath = Join-Path $siteRoot "bundles/$ReleaseId/manifest.json"
$manifestHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant()
if (-not $version.manifestSha256 -or $manifestHash -ne ([string]$version.manifestSha256).ToLowerInvariant()) {
    throw "STAGED_CANDIDATE_MANIFEST_INDEX_HASH_MISMATCH expected=$($version.manifestSha256) actual=$manifestHash"
}
$qualityHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $qualityFull).Hash.ToLowerInvariant()
if ($env:GITHUB_OUTPUT) {
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding UTF8 -Value "manifest_sha256=$manifestHash"
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding UTF8 -Value "quality_sha256=$qualityHash"
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding UTF8 -Value "lkg_version=$($index.latestVersionId)"
}
Write-Output "Staged publish candidate passed: Release=$ReleaseId LKG=$($index.latestVersionId) ManifestSha=$manifestHash QualitySha=$qualityHash"
