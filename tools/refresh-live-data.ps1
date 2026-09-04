param(
    [switch]$Force,
    [string]$SiteDirectory = "site"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$siteRoot = if ([IO.Path]::IsPathRooted($SiteDirectory)) { [IO.Path]::GetFullPath($SiteDirectory) } else { [IO.Path]::GetFullPath((Join-Path $repositoryRoot $SiteDirectory)) }
$buildRoot = Join-Path $repositoryRoot "build"
$backupRoot = Join-Path $buildRoot "source-backup"
$failureRoot = Join-Path $buildRoot "failure-report"
$sourceRoot = Join-Path $repositoryRoot "source/current"
$observationRoot = Join-Path $buildRoot "source-observations"
$identityEvidenceRoot = Join-Path $buildRoot "source-identity-evidence"
$userAgent = "TFT-Mobile-Overlay-Data/1.0 scheduled-version-check"
. (Join-Path $PSScriptRoot 'material-publication-policy.ps1')
. (Join-Path $PSScriptRoot 'patch-detection-policy.ps1')
. (Join-Path $PSScriptRoot 'current-set-name-policy.ps1')

function Set-ActionOutput([string]$Name, [string]$Value) {
    if ($env:GITHUB_OUTPUT) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$Name=$Value" -Encoding UTF8 }
}

function Get-WebText([string]$Url) {
    $lines = & curl.exe -L --fail --silent --show-error --retry 2 --retry-delay 5 --retry-all-errors --max-time 120 -A $userAgent $Url
    if ($LASTEXITCODE -ne 0) { throw "Request failed ($LASTEXITCODE): $Url" }
    $text = ($lines -join "`n")
    New-Item -ItemType Directory -Force -Path $observationRoot | Out-Null
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $urlKey = ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Url)) | ForEach-Object { $_.ToString('x2') }) -join ''
        $bytes = [Text.Encoding]::UTF8.GetBytes($text)
        $responseHash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    } finally { $sha.Dispose() }
    $record = [ordered]@{ sourceUrl=$Url; finalUrl=$Url; fetchedAt=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); responseHash=$responseHash; bytes=[int64]$bytes.Length }
    [IO.File]::WriteAllText((Join-Path $observationRoot "$urlKey-$responseHash.json"), (($record | ConvertTo-Json -Depth 6) + "`n"), [Text.UTF8Encoding]::new($false))
    return $text
}

function Write-SourceIdentityEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$ResponseText,
        [Parameter(Mandatory = $true)][hashtable]$NativeClaims,
        [Parameter(Mandatory = $true)][string]$EvidenceKind
    )
    New-Item -ItemType Directory -Force -Path $identityEvidenceRoot | Out-Null
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $urlKey = ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Url)) | ForEach-Object { $_.ToString('x2') }) -join ''
        $responseHash = ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($ResponseText)) | ForEach-Object { $_.ToString('x2') }) -join ''
    } finally { $sha.Dispose() }
    $evidence = [ordered]@{
        sourceUrl = $Url
        responseHash = $responseHash
        evidenceKind = $EvidenceKind
        nativeClaims = $NativeClaims
        observedAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    [IO.File]::WriteAllText((Join-Path $identityEvidenceRoot "$urlKey-$responseHash.json"), (($evidence | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
}

function Write-FailureReport([string]$Stage, [string]$Message) {
    New-Item -ItemType Directory -Force -Path $failureRoot | Out-Null
    $safeMessage = $Message -replace '(?i)(token|cookie|authorization|password)\s*[:=]\s*\S+', '$1=[REDACTED]'
    $report = [ordered]@{
        status = "failed"
        generatedAt = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        stage = $Stage
        message = $safeMessage
        repository = $(if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } else { "local" })
        workflowRunId = $(if ($env:GITHUB_RUN_ID) { $env:GITHUB_RUN_ID } else { "local" })
    }
    [IO.File]::WriteAllText((Join-Path $failureRoot "failure.json"), ($report | ConvertTo-Json) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

function Get-SnapshotSourceTimestamp([string]$SnapshotPath) {
    $snapshot = Get-Content -Raw -Encoding UTF8 -LiteralPath $SnapshotPath | ConvertFrom-Json
    if ($snapshot.PSObject.Properties['statsUpdatedEpochMs'] -and [int64]$snapshot.statsUpdatedEpochMs -gt 0) {
        return [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$snapshot.statsUpdatedEpochMs).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    return [string]$snapshot.fetchedAtUtc
}

$stage = "detect"
try {
    if (Test-Path -LiteralPath $failureRoot) { Remove-Item -Recurse -Force -LiteralPath $failureRoot }
    foreach ($path in @($observationRoot, $identityEvidenceRoot)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -Recurse -Force -LiteralPath $path }
    }
    $clusterUrl = "https://api-hc.metatft.com/tft-comps-api/latest_cluster_info"
    $clusterText = Get-WebText $clusterUrl
    $clusterResponse = $clusterText | ConvertFrom-Json
    $cluster = $clusterResponse.cluster_info
    if (-not $cluster -or -not $cluster.cluster_id -or -not $cluster.tft_set -or [string]$cluster.state -ne "published" -or [bool]$cluster.is_failed -or [bool]$cluster.is_deleted) {
        throw "Published cluster metadata is incomplete or unsafe"
    }
    $setId = [string]$cluster.tft_set
    $revision = [string]$cluster.cluster_id
    Write-SourceIdentityEvidence -Url $clusterUrl -ResponseText $clusterText -EvidenceKind 'RESPONSE_NATIVE_IDENTITY' -NativeClaims @{ setId=$setId; revisionId=$revision }

    # Riot occasionally changes localized title text while keeping the article
    # slug stable. Read two official locale indexes and accept URL slugs,
    # English titles, or Japanese titles. A total format break fails closed and
    # leaves the last-known-good publication active.
    $patchDocuments = @()
    $patchResponses = @()
    foreach ($patchIndexUrl in @(
        'https://teamfighttactics.leagueoflegends.com/en-us/news/tags/patch-notes/',
        'https://teamfighttactics.leagueoflegends.com/ja-jp/news/tags/patch-notes/'
    )) {
        try {
            $patchText = Get-WebText $patchIndexUrl
            $patchDocuments += $patchText
            $patchResponses += [pscustomobject]@{ url=$patchIndexUrl; text=$patchText }
        } catch { Write-Warning "Official patch index unavailable: $patchIndexUrl" }
    }
    $patch = Resolve-LatestTftPatch -Documents $patchDocuments
    foreach ($patchResponse in $patchResponses) {
        Write-SourceIdentityEvidence -Url ([string]$patchResponse.url) -ResponseText ([string]$patchResponse.text) -EvidenceKind 'RIOT_PATCH_AUTHORITY' -NativeClaims @{ patch=$patch }
    }
    $versionId = (("{0}-{1}-r{2}" -f $setId,$patch,$revision).ToLowerInvariant() -replace '[^a-z0-9._-]','-')

    Set-ActionOutput "detected_version" $versionId
    Set-ActionOutput "detected_set" $setId
    Set-ActionOutput "detected_patch" $patch
    Set-ActionOutput "detected_revision" $revision

    $indexPath = Join-Path $siteRoot "data-index.json"
    $existingVersion = $null
    $existingSetVersion = $null
    $previousAvailableVersion = $null
    if (Test-Path -LiteralPath $indexPath) {
        $index = Get-Content -Raw -Encoding UTF8 -LiteralPath $indexPath | ConvertFrom-Json
        $previousAvailableId = if ($index.PSObject.Properties['latestAvailableVersionId']) { [string]$index.latestAvailableVersionId } else { [string]$index.latestVersionId }
        $previousAvailableVersion = @($index.versions | Where-Object { [string]$_.id -eq $previousAvailableId }) | Select-Object -First 1
        $existingSetVersion = @($index.versions | Where-Object {
            [string]$_.setId -eq $setId
        } | Sort-Object generatedAtUtc -Descending | Select-Object -First 1)
        $existingVersion = @($index.versions | Where-Object {
            [string]$_.setId -eq $setId -and [string]$_.patch -eq $patch -and [string]$_.revision -eq $revision
        } | Sort-Object generatedAtUtc -Descending | Select-Object -First 1)
    }

    $stage = "prepare"
    if (Test-Path -LiteralPath $backupRoot) { Remove-Item -Recurse -Force -LiteralPath $backupRoot }
    Copy-Item -Recurse -Force -LiteralPath $sourceRoot -Destination $backupRoot
    $previousMetaPath = Join-Path $backupRoot "tft_static_snapshot.json"
    $previousCatalogPath = Join-Path $backupRoot "tft/tft_catalog.json"
    $previousContentFingerprint = if ($previousAvailableVersion -and $previousAvailableVersion.PSObject.Properties['metaFingerprint'] -and [string]$previousAvailableVersion.metaFingerprint -match '^[0-9a-f]{64}$') {
        [string]$previousAvailableVersion.metaFingerprint
    } elseif ((Test-Path -LiteralPath $previousMetaPath) -and (Test-Path -LiteralPath $previousCatalogPath)) {
        & (Join-Path $PSScriptRoot "get-content-fingerprint.ps1") `
            -CatalogPath $previousCatalogPath `
            -SnapshotPath $previousMetaPath `
            -AssetRoot $backupRoot
    } else {
        ""
    }
    $stage = "resolve-set"
    $jaUrl = "https://raw.communitydragon.org/latest/cdragon/tft/ja_jp.json"
    $enUrl = "https://raw.communitydragon.org/latest/cdragon/tft/en_us.json"
    $jaText = Get-WebText $jaUrl
    $enText = Get-WebText $enUrl
    $ja = $jaText | ConvertFrom-Json
    $en = $enText | ConvertFrom-Json
    $setJa = @($ja.setData | Where-Object { [string]$_.mutator -eq $setId }) | Select-Object -First 1
    $setEn = @($en.setData | Where-Object { [string]$_.mutator -eq $setId }) | Select-Object -First 1
    if (-not $setJa -or -not $setEn) { throw "CommunityDragon does not contain $setId yet" }
    Write-SourceIdentityEvidence -Url $jaUrl -ResponseText $jaText -EvidenceKind 'RESPONSE_CURRENT_SET_MEMBERSHIP' -NativeClaims @{ setId=$setId }
    Write-SourceIdentityEvidence -Url $enUrl -ResponseText $enText -EvidenceKind 'RESPONSE_CURRENT_SET_MEMBERSHIP' -NativeClaims @{ setId=$setId }
    $setNumber = if ($setJa.number) { [int]$setJa.number } else { [int]($setId -replace '\D','') }
    $lookupUrl = "https://data.metatft.com/lookups/$($setId)_latest_ja_jp.json"
    $lookupText = Get-WebText $lookupUrl
    $lookup = $lookupText | ConvertFrom-Json
    if (-not $lookup._metadata -or [string]$lookup._metadata.set -ne $setId) {
        throw "MetaTFT lookup does not match detected current set $setId"
    }
    Write-SourceIdentityEvidence -Url $lookupUrl -ResponseText $lookupText -EvidenceKind 'RESPONSE_CURRENT_SET_MEMBERSHIP' -NativeClaims @{ setId=$setId }
    $lookupSetName = [string]$lookup._metadata.setName
    $setNameJa = Resolve-CurrentSetDisplayName -CommunityDragonName ([string]$setJa.name) -SetNumber $setNumber -MetaTftSetName $lookupSetName
    $setNameEn = Resolve-CurrentSetDisplayName -CommunityDragonName ([string]$setEn.name) -SetNumber $setNumber -MetaTftSetName $lookupSetName

    $stage = "catalog"
    & (Join-Path $PSScriptRoot "refresh-catalog.ps1") -SetId $setId -SetNumber $setNumber -SetNameJa $setNameJa -SetNameEn $setNameEn -TftPatch $patch
    $stage = "statistics"
    # A new patch/revision of an existing set must keep the normal statistics
    # criteria. Only a never-before-published set is allowed to enter catalog-first readiness.
    $existingSetVersionRecord = @($existingSetVersion) | Select-Object -First 1
    $isNewSet = -not $existingSetVersionRecord
    $existingSetReadiness = if ($existingSetVersionRecord -and $existingSetVersionRecord.PSObject.Properties['readiness']) {
        [string]$existingSetVersionRecord.readiness
    } else {
        ''
    }
    $allowPartial = $isNewSet -or $existingSetReadiness -in @('CATALOG_READY', 'META_COLLECTING')
    if ($allowPartial) {
        & (Join-Path $PSScriptRoot "refresh-static-meta.ps1") -AllowPartial
    } else {
        & (Join-Path $PSScriptRoot "refresh-static-meta.ps1")
    }
    $currentMetaPath = Join-Path $sourceRoot "tft_static_snapshot.json"
    # Publication identity covers every user-visible catalog/meta field and the
    # bytes of referenced images. Observation timestamps and raw sample growth
    # alone are intentionally excluded to avoid a new immutable version every
    # 15 minutes.
    $contentFingerprint = & (Join-Path $PSScriptRoot "get-content-fingerprint.ps1") `
        -CatalogPath (Join-Path $sourceRoot "tft/tft_catalog.json") `
        -SnapshotPath $currentMetaPath `
        -AssetRoot $sourceRoot
    $currentSourceTimestamp = Get-SnapshotSourceTimestamp $currentMetaPath
    $publicationDecision = if ($previousAvailableVersion -and $previousContentFingerprint) {
        Resolve-MaterialPublicationDecision `
            -PreviousContentFingerprint $previousContentFingerprint `
            -CurrentContentFingerprint $contentFingerprint `
            -PreviousSourceTimestampUtc (Get-SnapshotSourceTimestamp $previousMetaPath) `
            -CurrentSourceTimestampUtc $currentSourceTimestamp `
            -Force:$Force
    } else {
        [pscustomobject][ordered]@{
            publish = $true
            materialChanged = $true
            observationDue = $false
            useObservationIdentity = $false
            reason = 'NEW_VERSION'
        }
    }
    if (-not $publicationDecision.publish) {
        Remove-Item -Recurse -Force -LiteralPath $sourceRoot
        Move-Item -LiteralPath $backupRoot -Destination $sourceRoot
        Set-ActionOutput "changed" "false"
        Set-ActionOutput "published" "false"
        Set-ActionOutput "result" "NO_CHANGE"
        Set-ActionOutput "detected_version" ([string]$previousAvailableVersion.id)
        Set-ActionOutput "detected_kind" ([string]$previousAvailableVersion.updateKind)
        Write-Output "No material catalog/meta/image change: Version=$($previousAvailableVersion.id) Fingerprint=$contentFingerprint"
        exit 0
    }
    $publicationFingerprint = & (Join-Path $PSScriptRoot 'get-publication-fingerprint.ps1') `
        -ContentFingerprint $contentFingerprint `
        -SourceTimestampUtc $currentSourceTimestamp `
        -ObservationRefresh:$publicationDecision.useObservationIdentity
    Write-Output "Publication decision: $($publicationDecision.reason) Content=$contentFingerprint Identity=$publicationFingerprint"
    $readiness = (Get-Content -Raw -Encoding UTF8 -LiteralPath $currentMetaPath | ConvertFrom-Json).readiness
    if (-not $readiness) { $readiness = "META_STABLE" }
    $stage = "source-manifest"
    & (Join-Path $PSScriptRoot "new-data-source-manifest.ps1")
    $stage = "source-validation"
    & (Join-Path $PSScriptRoot "validate-offline-catalog.ps1")
    & (Join-Path $PSScriptRoot "validate-static-meta.ps1")
    & (Join-Path $PSScriptRoot "validate-data-compatibility.ps1")
    $stage = "change-summary"
    & (Join-Path $PSScriptRoot "new-change-summary.ps1") -SiteDirectory $SiteDirectory
    $stage = "publish"
    & (Join-Path $PSScriptRoot "publish-data-history.ps1") -SiteDirectory $SiteDirectory -MetaFingerprint $publicationFingerprint -Readiness $readiness
    $publishedIndex = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $siteRoot "data-index.json") | ConvertFrom-Json
    $publishedAvailableId = if ($publishedIndex.PSObject.Properties['latestAvailableVersionId']) { [string]$publishedIndex.latestAvailableVersionId } else { [string]$publishedIndex.latestVersionId }
    $publishedVersion = @($publishedIndex.versions | Where-Object { [string]$_.id -eq $publishedAvailableId }) | Select-Object -First 1
    Set-ActionOutput "detected_version" ([string]$publishedVersion.id)
    Set-ActionOutput "detected_kind" ([string]$publishedVersion.updateKind)
    $stage = "final-validation"
    & (Join-Path $PSScriptRoot "validate-site.ps1") -SiteDirectory $SiteDirectory

    if (Test-Path -LiteralPath $backupRoot) { Remove-Item -Recurse -Force -LiteralPath $backupRoot }
    Set-ActionOutput "changed" "true"
    Set-ActionOutput "published" "true"
    Set-ActionOutput "result" "PUBLISHED"
    Write-Output "Refresh complete: Version=$versionId"
} catch {
    $message = $_.Exception.Message
    Write-FailureReport -Stage $stage -Message $message
    if (Test-Path -LiteralPath $backupRoot) {
        if (Test-Path -LiteralPath $sourceRoot) { Remove-Item -Recurse -Force -LiteralPath $sourceRoot }
        Move-Item -LiteralPath $backupRoot -Destination $sourceRoot
    }
    Set-ActionOutput "changed" "false"
    Set-ActionOutput "published" "false"
    Set-ActionOutput "result" "FAILED"
    Set-ActionOutput "failed_stage" $stage
    throw
}
