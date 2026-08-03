param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9._-]+$')][string]$VersionId,
    [string]$SiteDirectory = "site"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$siteRoot = if ([IO.Path]::IsPathRooted($SiteDirectory)) { [IO.Path]::GetFullPath($SiteDirectory) } else { [IO.Path]::GetFullPath((Join-Path $repositoryRoot $SiteDirectory)) }
$indexPath = Join-Path $siteRoot "data-index.json"
$healthPath = Join-Path $siteRoot "health.json"
$index = Get-Content -Raw -Encoding UTF8 -LiteralPath $indexPath | ConvertFrom-Json
if ([string]$index.latestVersionId -eq $VersionId) { throw "Refusing to remove the current latest version; restore a production version first" }
$remaining = @($index.versions | Where-Object { [string]$_.id -ne $VersionId })
if ($remaining.Count -eq @($index.versions).Count) { throw "Version is not present in data-index: $VersionId" }
if ($remaining.Count -lt 1) { throw "Refusing to remove the only version" }
$index.versions = $remaining
$index.generatedAtUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
[IO.File]::WriteAllText($indexPath, ($index | ConvertTo-Json -Depth 8) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
$health = Get-Content -Raw -Encoding UTF8 -LiteralPath $healthPath | ConvertFrom-Json
$health.versionCount = $remaining.Count
$health.generatedAt = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
$health.workflowRunId = $(if ($env:GITHUB_RUN_ID) { [string]$env:GITHUB_RUN_ID } else { "local-e2e-cleanup" })
[IO.File]::WriteAllText($healthPath, ($health | ConvertTo-Json) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
& (Join-Path $PSScriptRoot "validate-site.ps1") -SiteDirectory $SiteDirectory
Write-Output "Version removed from index; immutable bundle retained: $VersionId"
