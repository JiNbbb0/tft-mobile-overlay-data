param(
    [string]$OutputPath = "source/current/metadata/DATA_SOURCE_MANIFEST.json"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$catalogPath = Join-Path $repositoryRoot "source/current/tft/tft_catalog.json"
$metaPath = Join-Path $repositoryRoot "source/current/tft_static_snapshot.json"
$observationRoot = Join-Path $repositoryRoot "build/source-observations"
$resolvedOutput = if ([IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path $repositoryRoot $OutputPath }

$catalog = Get-Content -Raw -Encoding UTF8 -LiteralPath $catalogPath | ConvertFrom-Json
$meta = Get-Content -Raw -Encoding UTF8 -LiteralPath $metaPath | ConvertFrom-Json
$observations = @(
    if (Test-Path -LiteralPath $observationRoot) {
        Get-ChildItem -LiteralPath $observationRoot -Filter *.json -File | ForEach-Object {
            Get-Content -Raw -Encoding UTF8 -LiteralPath $_.FullName | ConvertFrom-Json
        }
    }
)

function Get-Sha256Text([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) -join ''
    } finally {
        $sha.Dispose()
    }
}

function Get-ObservationAggregate {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$FallbackPath
    )
    $matching = @($observations | Where-Object { [string]$_.sourceUrl -eq $Url -or [string]$_.sourceUrl -like "${Url}?*" })
    if ($matching.Count -gt 0) {
        $joined = (@($matching.responseHash | Sort-Object) -join "`n")
        return [pscustomobject]@{
            fetchedAt = [string](@($matching | Sort-Object fetchedAt -Descending)[0].fetchedAt)
            responseHash = $(if ($matching.Count -eq 1) { [string]$matching[0].responseHash } else { Get-Sha256Text $joined })
            hashBasis = "source-response"
        }
    }
    return [pscustomobject]@{
        fetchedAt = [string]$meta.fetchedAtUtc
        responseHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $FallbackPath).Hash.ToLowerInvariant()
        hashBasis = "generated-output-fallback"
    }
}

$catalogCount = @($catalog.champions).Count + @($catalog.traits).Count + @($catalog.items).Count + @($catalog.augments).Count
$itemStatCount = 0
foreach ($composition in @($meta.compositions)) {
    if ($composition -isnot [pscustomobject]) { continue }
    if (-not ($composition.PSObject.Properties.Name -contains 'units')) { continue }
    foreach ($unit in @($composition.units)) {
        if ($unit -isnot [pscustomobject]) { continue }
        if (-not ($unit.PSObject.Properties.Name -contains 'itemStats')) { continue }
        $itemStatCount += @($unit.itemStats).Count
    }
}
$imageCount = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot "source/current/tft/images") -File).Count
$definitions = @(
    [ordered]@{ sourceName = "Riot TFT patch notes"; sourceUrl = [string]$catalog.sources.riotPatch; terms = "Riot website terms and Riot Legal Notices"; count = 1; fallback = $catalogPath },
    [ordered]@{ sourceName = "CommunityDragon TFT Japanese data"; sourceUrl = [string]$catalog.sources.communityDragonJa; terms = "Riot Legal Jibber Jabber; CommunityDragon is not endorsed by Riot"; count = $catalogCount; fallback = $catalogPath },
    [ordered]@{ sourceName = "CommunityDragon TFT English data"; sourceUrl = [string]$catalog.sources.communityDragonEn; terms = "Riot Legal Jibber Jabber; CommunityDragon is not endorsed by Riot"; count = $catalogCount; fallback = $catalogPath },
    [ordered]@{ sourceName = "CommunityDragon image assets"; sourceUrl = "https://raw.communitydragon.org/latest/game/"; terms = "Riot Legal Jibber Jabber; CommunityDragon is not endorsed by Riot"; count = $imageCount; fallback = $catalogPath },
    [ordered]@{ sourceName = "MetaTFT cluster information"; sourceUrl = [string]$meta.sources.clusterInfo; terms = "Public endpoint; availability and terms must be monitored"; count = 1; fallback = $metaPath },
    [ordered]@{ sourceName = "MetaTFT augment tiers"; sourceUrl = [string]$meta.sources.augmentTiers; terms = "Public endpoint; availability and terms must be monitored"; count = @($meta.augments).Count; fallback = $metaPath },
    [ordered]@{ sourceName = "MetaTFT composition statistics"; sourceUrl = [string]$meta.sources.compositionStats; terms = "Public endpoint; availability and terms must be monitored"; count = @($meta.compositions | Where-Object { $_ -is [pscustomobject] }).Count; fallback = $metaPath },
    [ordered]@{ sourceName = "MetaTFT composition item builds"; sourceUrl = [string]$meta.sources.compositionItemBuilds; terms = "Public endpoint; availability and terms must be monitored"; count = $itemStatCount; fallback = $metaPath },
    [ordered]@{ sourceName = "MetaTFT composition augment tiers"; sourceUrl = [string]$meta.sources.compositionAugmentTiers; terms = "Public endpoint; availability and terms must be monitored"; count = @($meta.compositions | Where-Object { $_ -is [pscustomobject] }).Count; fallback = $metaPath },
    [ordered]@{ sourceName = "MetaTFT composition details"; sourceUrl = [string]$meta.sources.compositionDetails; terms = "Public endpoint; availability and terms must be monitored"; count = @($meta.compositions | Where-Object { $_ -is [pscustomobject] }).Count; fallback = $metaPath }
)

$sourceRecords = foreach ($definition in $definitions) {
    $observation = Get-ObservationAggregate -Url $definition.sourceUrl -FallbackPath $definition.fallback
    [pscustomobject][ordered]@{
        sourceName = $definition.sourceName
        sourceUrl = $definition.sourceUrl
        fetchedAt = $observation.fetchedAt
        setId = [string]$meta.setId
        patch = [string]$catalog.set.tftPatch
        revisionId = [string]$meta.clusterId
        termsOrLicenseNote = $definition.terms
        responseHash = $observation.responseHash
        hashBasis = $observation.hashBasis
        recordCount = [int]$definition.count
    }
}

$manifest = [pscustomobject][ordered]@{
    schemaVersion = 1
    generatedAt = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    setId = [string]$meta.setId
    patch = [string]$catalog.set.tftPatch
    revisionId = [string]$meta.clusterId
    sources = @($sourceRecords)
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
[IO.File]::WriteAllText($resolvedOutput, (($manifest | ConvertTo-Json -Depth 8).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
Write-Output "Data source manifest: $resolvedOutput Sources=$($sourceRecords.Count)"
