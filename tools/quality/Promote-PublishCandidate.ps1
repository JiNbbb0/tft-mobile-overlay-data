param(
    [Parameter(Mandatory = $true)][string]$SiteDirectory,
    [Parameter(Mandatory = $true)][string]$ReleaseId,
    [Parameter(Mandatory = $true)][string]$AndroidEvidencePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$siteRoot = [IO.Path]::GetFullPath($SiteDirectory)
$indexPath = Join-Path $siteRoot 'data-index.json'
if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { throw "PROMOTION_INDEX_MISSING path=$indexPath" }

# All fail-closed gates execute before data-index.json is touched. The immutable
# bundle can already exist on staging/public storage, but latestVersionId is the
# final pointer mutation.
& (Join-Path $PSScriptRoot 'Test-PublishCandidate.ps1') `
    -SiteDirectory $siteRoot `
    -ReleaseId $ReleaseId
& (Join-Path $PSScriptRoot 'Test-AndroidE2EEvidence.ps1') `
    -EvidencePath $AndroidEvidencePath `
    -ReleaseId $ReleaseId

$indexTextBefore = Get-Content -Raw -Encoding UTF8 -LiteralPath $indexPath
$index = $indexTextBefore | ConvertFrom-Json
$version = @($index.versions | Where-Object { [string]$_.id -eq $ReleaseId }) | Select-Object -First 1
if (-not $version) { throw "PROMOTION_VERSION_NOT_REGISTERED release=$ReleaseId" }
if ([string]$index.latestVersionId -eq $ReleaseId) {
    Write-Output "Publish candidate already promoted: Release=$ReleaseId"
    return
}

$index.latestVersionId = $ReleaseId
$index.generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$replacement = ($index | ConvertTo-Json -Depth 50).Replace("`r`n","`n") + "`n"
$tempPath = "$indexPath.tmp"
[IO.File]::WriteAllText($tempPath, $replacement, [Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $tempPath -Destination $indexPath -Force
Write-Output "Publish candidate promoted last: Release=$ReleaseId Previous=$([string]($indexTextBefore | ConvertFrom-Json).latestVersionId)"
