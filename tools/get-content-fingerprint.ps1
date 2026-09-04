param(
    [string]$CatalogPath = "source/current/tft/tft_catalog.json",
    [string]$SnapshotPath = "source/current/tft_static_snapshot.json",
    [string]$AssetRoot = "source/current"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
function Resolve-RepositoryPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $repositoryRoot $Path))
}
function Get-Sha256Bytes([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    } finally {
        $sha.Dispose()
    }
}

$resolvedCatalog = Resolve-RepositoryPath $CatalogPath
$resolvedSnapshot = Resolve-RepositoryPath $SnapshotPath
$resolvedAssetRoot = Resolve-RepositoryPath $AssetRoot
foreach ($required in @($resolvedCatalog, $resolvedSnapshot)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Fingerprint input missing: $required" }
}
$assetPrefix = $resolvedAssetRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$catalog = Get-Content -Raw -Encoding UTF8 -LiteralPath $resolvedCatalog | ConvertFrom-Json
$metaFingerprint = & (Join-Path $PSScriptRoot 'get-meta-fingerprint.ps1') -SnapshotPath $resolvedSnapshot

# fetchedAtUtc and source URLs describe the observation, not user-visible
# content. Everything rendered by the catalog remains part of the identity.
$catalogSemantic = [ordered]@{
    schemaVersion = [int]$catalog.schemaVersion
    set = $catalog.set
    sourceUniverse = $(if ($catalog.PSObject.Properties['sourceUniverse']) { $catalog.sourceUniverse } else { $null })
    champions = @($catalog.champions | Sort-Object id)
    traits = @($catalog.traits | Sort-Object id)
    items = @($catalog.items | Sort-Object id)
    augments = @($catalog.augments | Sort-Object id)
    systemData = $catalog.systemData
}

$imagePaths = @(
    @($catalog.champions | ForEach-Object { [string]$_.image; [string]$_.ability.icon }) +
    @($catalog.traits | ForEach-Object { [string]$_.image }) +
    @($catalog.items | ForEach-Object { [string]$_.image }) +
    @($catalog.augments | ForEach-Object { [string]$_.image }) |
        Where-Object { $_ } |
        Sort-Object -Unique
)
$images = foreach ($relativePath in $imagePaths) {
    $normalized = ([string]$relativePath).Replace('\','/')
    if ($normalized -notmatch '^tft/images/[a-zA-Z0-9._-]+$') { throw "Unsafe catalog image path: $normalized" }
    $physicalPath = [IO.Path]::GetFullPath((Join-Path $resolvedAssetRoot ($normalized -replace '/', [IO.Path]::DirectorySeparatorChar)))
    if (-not $physicalPath.StartsWith($assetPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Catalog image escapes asset root: $normalized" }
    if (-not (Test-Path -LiteralPath $physicalPath -PathType Leaf)) { throw "Catalog image missing: $normalized" }
    [ordered]@{
        path = $normalized
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $physicalPath).Hash.ToLowerInvariant()
    }
}

$identity = [ordered]@{
    schema = 1
    catalog = $catalogSemantic
    metaFingerprint = $metaFingerprint
    images = @($images)
}
$json = $identity | ConvertTo-Json -Depth 100 -Compress
Write-Output (Get-Sha256Bytes ([Text.Encoding]::UTF8.GetBytes($json)))
