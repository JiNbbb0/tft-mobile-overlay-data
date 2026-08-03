param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9._-]+$')][string]$VersionId,
    [string]$SiteDirectory = "site"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$siteRoot = if ([IO.Path]::IsPathRooted($SiteDirectory)) { [IO.Path]::GetFullPath($SiteDirectory) } else { [IO.Path]::GetFullPath((Join-Path $repositoryRoot $SiteDirectory)) }
$indexPath = Join-Path $siteRoot "data-index.json"
$index = Get-Content -Raw -Encoding UTF8 -LiteralPath $indexPath | ConvertFrom-Json
$version = @($index.versions | Where-Object { [string]$_.id -eq $VersionId }) | Select-Object -First 1
if (-not $version) { throw "Version does not exist in data-index: $VersionId" }
$manifestPath = [IO.Path]::GetFullPath((Join-Path $siteRoot ([string]$version.manifestUrl)))
$sitePrefix = $siteRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $manifestPath.StartsWith($sitePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Manifest path escaped site root" }
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Manifest missing for version: $VersionId" }

$oldLatest = [string]$index.latestVersionId
$healthPath = Join-Path $siteRoot "health.json"
$oldHealthText = Get-Content -Raw -Encoding UTF8 -LiteralPath $healthPath
$health = $oldHealthText | ConvertFrom-Json
$index.latestVersionId = $VersionId
$index.generatedAtUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
$nextPath = Join-Path $siteRoot "data-index.next.json"
[IO.File]::WriteAllText($nextPath, ($index | ConvertTo-Json -Depth 8) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
Move-Item -Force -LiteralPath $nextPath -Destination $indexPath
$health.latestSetId = [string]$version.setId
$health.latestPatch = [string]$version.patch
$health.latestRevision = [string]$version.revision
$health.generatedAt = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
$health.workflowRunId = $(if ($env:GITHUB_RUN_ID) { [string]$env:GITHUB_RUN_ID } else { "local-rollback" })
$sourceUpdatedAt = $version.generatedAtUtc
$health.sourceUpdatedAt = if ($sourceUpdatedAt -is [DateTime]) {
    $sourceUpdatedAt.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
} else {
    [string]$sourceUpdatedAt
}
[IO.File]::WriteAllText($healthPath, ($health | ConvertTo-Json) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
try {
    & (Join-Path $PSScriptRoot "validate-site.ps1") -SiteDirectory $SiteDirectory
} catch {
    $index.latestVersionId = $oldLatest
    [IO.File]::WriteAllText($indexPath, ($index | ConvertTo-Json -Depth 8) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($healthPath, $oldHealthText, [Text.UTF8Encoding]::new($false))
    throw
}
Write-Output "Latest changed safely: $oldLatest -> $VersionId"
