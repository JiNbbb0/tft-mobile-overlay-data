param(
    [string]$OutputPath = "source/current/metadata/DATA_SOURCE_MANIFEST.json"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'statistics-scope-contract.ps1')

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$catalogPath = Join-Path $repositoryRoot "source/current/tft/tft_catalog.json"
$metaPath = Join-Path $repositoryRoot "source/current/tft_static_snapshot.json"
$observationRoot = Join-Path $repositoryRoot "build/source-observations"
$identityEvidenceRoot = Join-Path $repositoryRoot "build/source-identity-evidence"
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
$identityEvidence = @(
    if (Test-Path -LiteralPath $identityEvidenceRoot) {
        Get-ChildItem -LiteralPath $identityEvidenceRoot -Filter *.json -File | ForEach-Object {
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
    $matching = @($observations | Where-Object { [string]$_.sourceUrl -eq $Url -or ([string]$_.sourceUrl).StartsWith("${Url}?", [StringComparison]::Ordinal) })
    if ($matching.Count -gt 0) {
        $joined = (@($matching.responseHash | Sort-Object) -join "`n")
        return [pscustomobject]@{
            fetchedAt = [string](@($matching | Sort-Object fetchedAt -Descending)[0].fetchedAt)
            responseHash = $(if ($matching.Count -eq 1) { [string]$matching[0].responseHash } else { Get-Sha256Text $joined })
            hashBasis = "source-response"
            finalUrl = [string](@($matching | Sort-Object fetchedAt -Descending)[0].finalUrl)
            responseHashes = @($matching.responseHash | Sort-Object -Unique)
        }
    }
    return [pscustomobject]@{
        fetchedAt = [string]$meta.fetchedAtUtc
        responseHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $FallbackPath).Hash.ToLowerInvariant()
        hashBasis = "generated-output-fallback"
        finalUrl = $Url
        responseHashes = @()
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
    [ordered]@{ sourceName = "Riot TFT patch notes"; role='PATCH_AUTHORITY'; sourceUrl = [string]$catalog.sources.riotPatch; terms = "Riot website terms and Riot Legal Notices"; count = 1; fallback = $catalogPath },
    [ordered]@{ sourceName = "CommunityDragon TFT Japanese data"; role='CURRENT_SET_CATALOG'; sourceUrl = [string]$catalog.sources.communityDragonJa; terms = "Riot Legal Jibber Jabber; CommunityDragon is not endorsed by Riot"; count = $catalogCount; fallback = $catalogPath },
    [ordered]@{ sourceName = "CommunityDragon TFT English data"; role='CURRENT_SET_CATALOG'; sourceUrl = [string]$catalog.sources.communityDragonEn; terms = "Riot Legal Jibber Jabber; CommunityDragon is not endorsed by Riot"; count = $catalogCount; fallback = $catalogPath },
    [ordered]@{ sourceName = "CommunityDragon image assets"; role='CURRENT_SET_ASSETS'; sourceUrl = "https://raw.communitydragon.org/latest/game/"; terms = "Riot Legal Jibber Jabber; CommunityDragon is not endorsed by Riot"; count = $imageCount; fallback = $catalogPath },
    [ordered]@{ sourceName = "MetaTFT cluster information"; role='SET_REVISION_AUTHORITY'; sourceUrl = [string]$meta.sources.clusterInfo; terms = "Public endpoint; availability and terms must be monitored"; count = 1; fallback = $metaPath },
    [ordered]@{ sourceName = "MetaTFT augment tiers"; role='AUGMENT_STATISTICS'; sourceUrl = [string]$meta.sources.augmentTiers; terms = "Public endpoint; availability and terms must be monitored"; count = @($meta.augments).Count; fallback = $metaPath },
    [ordered]@{ sourceName = "MetaTFT composition statistics"; role='COMPOSITION_STATISTICS'; sourceUrl = [string]$meta.sources.compositionStats; terms = "Public endpoint; availability and terms must be monitored"; count = @($meta.compositions | Where-Object { $_ -is [pscustomobject] }).Count; fallback = $metaPath },
    [ordered]@{ sourceName = "MetaTFT Japanese lookup"; role='LOCALIZATION'; sourceUrl = [string]$meta.sources.metaTftJapaneseLookup; terms = "Public endpoint; availability and terms must be monitored"; count = @($meta.compositions | Where-Object { $_ -is [pscustomobject] }).Count; fallback = $metaPath },
    [ordered]@{ sourceName = "MetaTFT composition item builds"; role='RECOMMENDED_ITEMS'; sourceUrl = [string]$meta.sources.compositionItemBuilds; terms = "Public endpoint; availability and terms must be monitored"; count = $itemStatCount; fallback = $metaPath },
    [ordered]@{ sourceName = "MetaTFT composition augment tiers"; role='OPTIONAL_COMPOSITION_AUGMENTS'; sourceUrl = [string]$meta.sources.compositionAugmentTiers; terms = "Public endpoint; availability and terms must be monitored"; count = @($meta.compositions | Where-Object { $_ -is [pscustomobject] }).Count; fallback = $metaPath },
    [ordered]@{ sourceName = "MetaTFT composition details"; role='BOARDS_AND_DETAILS'; sourceUrl = [string]$meta.sources.compositionDetails; terms = "Public endpoint; availability and terms must be monitored"; count = @($meta.compositions | Where-Object { $_ -is [pscustomobject] }).Count; fallback = $metaPath }
)

$sourceRecords = foreach ($definition in $definitions) {
    $observation = Get-ObservationAggregate -Url $definition.sourceUrl -FallbackPath $definition.fallback
    $matchedEvidence = @($identityEvidence | Where-Object {
        ([string]$_.sourceUrl -eq [string]$definition.sourceUrl -or ([string]$_.sourceUrl).StartsWith("$($definition.sourceUrl)?", [StringComparison]::Ordinal)) -and
        [string]$_.responseHash -in @($observation.responseHashes)
    })
    $nativeClaims = [ordered]@{}
    $queryClaims = [ordered]@{}
    foreach ($evidence in $matchedEvidence) {
        if ($evidence.PSObject.Properties['nativeClaims']) {
            foreach ($property in $evidence.nativeClaims.PSObject.Properties) {
                if ($nativeClaims.Contains($property.Name) -and [string]$nativeClaims[$property.Name] -ne [string]$property.Value) { $nativeClaims[$property.Name] = '__CONFLICT__' }
                else { $nativeClaims[$property.Name] = $property.Value }
            }
        }
        if ($evidence.PSObject.Properties['queryClaims']) {
            foreach ($property in $evidence.queryClaims.PSObject.Properties) { $queryClaims[$property.Name] = $property.Value }
        }
    }
    $identityValid = switch ([string]$definition.role) {
        'PATCH_AUTHORITY' { [string]$nativeClaims.patch -eq [string]$catalog.set.tftPatch }
        'CURRENT_SET_CATALOG' { [string]$nativeClaims.setId -eq [string]$meta.setId }
        'SET_REVISION_AUTHORITY' { [string]$nativeClaims.setId -eq [string]$meta.setId -and [string]$nativeClaims.revisionId -eq [string]$meta.clusterId }
        'COMPOSITION_STATISTICS' {
            [string]$nativeClaims.setId -eq [string]$meta.setId -and
            [string]$nativeClaims.revisionId -eq [string]$meta.clusterId -and
            [string]$queryClaims.patchMode -eq 'current' -and
            [string]$queryClaims.permitFilterAdjustment -eq 'false' -and
            (Test-TftStatisticsRankFilter ([string]$queryClaims.rank))
        }
        'LOCALIZATION' { ([string]$definition.sourceUrl).Contains("/$($meta.setId)_latest_") }
        'RECOMMENDED_ITEMS' { [string]$queryClaims.revisionId -eq [string]$meta.clusterId }
        'BOARDS_AND_DETAILS' { [string]$queryClaims.revisionId -eq [string]$meta.clusterId }
        'OPTIONAL_COMPOSITION_AUGMENTS' { [string]$queryClaims.revisionId -eq [string]$meta.clusterId }
        'AUGMENT_STATISTICS' { $matchedEvidence.Count -gt 0 }
        'CURRENT_SET_ASSETS' { [int]$definition.count -gt 0 }
        default { $false }
    }
    $verdict = if ($observation.hashBasis -ne 'source-response') { 'UNVERIFIED' } elseif ($identityValid) { 'VERIFIED' } else { 'UNVERIFIED' }
    [pscustomobject][ordered]@{
        sourceName = $definition.sourceName
        role = $definition.role
        sourceUrl = $definition.sourceUrl
        finalUrl = $(if ($observation.finalUrl) { $observation.finalUrl } else { $definition.sourceUrl })
        fetchedAt = $observation.fetchedAt
        setId = [string]$meta.setId
        patch = [string]$catalog.set.tftPatch
        revisionId = [string]$meta.clusterId
        termsOrLicenseNote = $definition.terms
        responseHash = $observation.responseHash
        hashBasis = $observation.hashBasis
        evidenceKind = $(if ($matchedEvidence.Count -gt 0) { (@($matchedEvidence.evidenceKind | Sort-Object -Unique) -join '+') } else { 'NONE' })
        nativeClaims = [pscustomobject]$nativeClaims
        queryClaims = [pscustomobject]$queryClaims
        verdict = $verdict
        recordCount = [int]$definition.count
    }
}

$byName = @{}; foreach ($entry in $sourceRecords) { $byName[[string]$entry.sourceName] = $entry }
$setVerified = [string]$byName['MetaTFT cluster information'].nativeClaims.setId -eq [string]$meta.setId -and
    [string]$byName['CommunityDragon TFT Japanese data'].nativeClaims.setId -eq [string]$meta.setId -and
    [string]$byName['CommunityDragon TFT English data'].nativeClaims.setId -eq [string]$meta.setId
$patchVerified = [string]$byName['Riot TFT patch notes'].nativeClaims.patch -eq [string]$catalog.set.tftPatch -and
    [string]$byName['MetaTFT composition statistics'].queryClaims.patchMode -eq 'current'
$revisionVerified = [string]$byName['MetaTFT cluster information'].nativeClaims.revisionId -eq [string]$meta.clusterId -and
    [string]$byName['MetaTFT composition statistics'].nativeClaims.revisionId -eq [string]$meta.clusterId
$coherenceStatus = if ($setVerified -and $patchVerified -and $revisionVerified) { 'VERIFIED' } else { 'BLOCKED' }

$manifest = [pscustomobject][ordered]@{
    schemaVersion = 2
    generatedAt = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    setId = [string]$meta.setId
    patch = [string]$catalog.set.tftPatch
    revisionId = [string]$meta.clusterId
    coherenceStatus = $coherenceStatus
    sourceEvidence = [pscustomobject][ordered]@{
        set = [pscustomobject][ordered]@{ value=[string]$meta.setId; status=$(if ($setVerified) { 'CROSS_SOURCE_VERIFIED' } else { 'BLOCKED' }) }
        patch = [pscustomobject][ordered]@{ value=[string]$catalog.set.tftPatch; status=$(if ($patchVerified) { 'AUTHORITY_VERIFIED' } else { 'BLOCKED' }) }
        revision = [pscustomobject][ordered]@{ value=[string]$meta.clusterId; status=$(if ($revisionVerified) { 'AUTHORITY_VERIFIED' } else { 'BLOCKED' }) }
    }
    sources = @($sourceRecords)
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
[IO.File]::WriteAllText($resolvedOutput, (($manifest | ConvertTo-Json -Depth 8).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
Write-Output "Data source manifest: $resolvedOutput Sources=$($sourceRecords.Count)"
