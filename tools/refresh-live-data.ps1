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
$userAgent = "TFT-Mobile-Overlay-Data/1.0 scheduled-version-check"

function Set-ActionOutput([string]$Name, [string]$Value) {
    if ($env:GITHUB_OUTPUT) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$Name=$Value" -Encoding UTF8 }
}

function Get-WebText([string]$Url) {
    $lines = & curl.exe -L --fail --silent --show-error --retry 2 --retry-delay 5 --retry-all-errors --max-time 120 -A $userAgent $Url
    if ($LASTEXITCODE -ne 0) { throw "Request failed ($LASTEXITCODE): $Url" }
    return ($lines -join "`n")
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

$stage = "detect"
try {
    if (Test-Path -LiteralPath $failureRoot) { Remove-Item -Recurse -Force -LiteralPath $failureRoot }
    $clusterResponse = Get-WebText "https://api-hc.metatft.com/tft-comps-api/latest_cluster_info" | ConvertFrom-Json
    $cluster = $clusterResponse.cluster_info
    if (-not $cluster -or -not $cluster.cluster_id -or -not $cluster.tft_set -or [string]$cluster.state -ne "published" -or [bool]$cluster.is_failed -or [bool]$cluster.is_deleted) {
        throw "Published cluster metadata is incomplete or unsafe"
    }
    $setId = [string]$cluster.tft_set
    $revision = [string]$cluster.cluster_id

    $patchHtml = Get-WebText "https://teamfighttactics.leagueoflegends.com/en-us/news/tags/patch-notes/"
    $patchMatch = [regex]::Match($patchHtml, 'Teamfight Tactics patch\s+([0-9]+\.[0-9]+)', 'IgnoreCase')
    if (-not $patchMatch.Success) { throw "Latest TFT patch could not be read from Riot patch notes" }
    $patch = $patchMatch.Groups[1].Value
    $versionId = (("{0}-{1}-r{2}" -f $setId,$patch,$revision).ToLowerInvariant() -replace '[^a-z0-9._-]','-')

    Set-ActionOutput "detected_version" $versionId
    Set-ActionOutput "detected_set" $setId
    Set-ActionOutput "detected_patch" $patch
    Set-ActionOutput "detected_revision" $revision

    $indexPath = Join-Path $siteRoot "data-index.json"
    $existingVersion = $null
    $existingSetVersion = $null
    if (Test-Path -LiteralPath $indexPath) {
        $index = Get-Content -Raw -Encoding UTF8 -LiteralPath $indexPath | ConvertFrom-Json
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
    $existingFingerprintProperty = if ($existingVersion) {
        $existingVersion.PSObject.Properties['metaFingerprint']
    } else {
        $null
    }
    $previousFingerprint = if ($existingFingerprintProperty -and [string]$existingFingerprintProperty.Value) {
        [string]$existingFingerprintProperty.Value
    } elseif (Test-Path -LiteralPath $previousMetaPath) {
        & (Join-Path $PSScriptRoot "get-meta-fingerprint.ps1") -SnapshotPath $previousMetaPath
    } else {
        ""
    }
    $observationRoot = Join-Path $buildRoot "source-observations"
    if (Test-Path -LiteralPath $observationRoot) { Remove-Item -Recurse -Force -LiteralPath $observationRoot }

    $stage = "resolve-set"
    $ja = Get-WebText "https://raw.communitydragon.org/latest/cdragon/tft/ja_jp.json" | ConvertFrom-Json
    $en = Get-WebText "https://raw.communitydragon.org/latest/cdragon/tft/en_us.json" | ConvertFrom-Json
    $setJa = @($ja.setData | Where-Object { [string]$_.mutator -eq $setId }) | Select-Object -First 1
    $setEn = @($en.setData | Where-Object { [string]$_.mutator -eq $setId }) | Select-Object -First 1
    if (-not $setJa -or -not $setEn) { throw "CommunityDragon does not contain $setId yet" }
    $setNumber = if ($setJa.number) { [int]$setJa.number } else { [int]($setId -replace '\D','') }
    $setNameJa = if ([string]$setJa.name) { [string]$setJa.name } else { "Set $setNumber" }
    $setNameEn = if ([string]$setEn.name) { [string]$setEn.name } else { "Set $setNumber" }

    $stage = "catalog"
    & (Join-Path $PSScriptRoot "refresh-catalog.ps1") -SetId $setId -SetNumber $setNumber -SetNameJa $setNameJa -SetNameEn $setNameEn -TftPatch $patch
    $stage = "statistics"
    # A new patch/revision of an existing set must keep the normal statistics
    # criteria. Only a never-before-published set is allowed to enter catalog-first readiness.
    $isNewSet = -not $existingSetVersion
    if ($isNewSet) {
        & (Join-Path $PSScriptRoot "refresh-static-meta.ps1") -AllowPartial
    } else {
        & (Join-Path $PSScriptRoot "refresh-static-meta.ps1")
    }
    $currentMetaPath = Join-Path $sourceRoot "tft_static_snapshot.json"
    $metaFingerprint = & (Join-Path $PSScriptRoot "get-meta-fingerprint.ps1") -SnapshotPath $currentMetaPath
    if (-not $Force -and $existingVersion -and $previousFingerprint -and $metaFingerprint -eq $previousFingerprint) {
        Remove-Item -Recurse -Force -LiteralPath $sourceRoot
        Move-Item -LiteralPath $backupRoot -Destination $sourceRoot
        Set-ActionOutput "changed" "false"
        Set-ActionOutput "published" "false"
        Set-ActionOutput "result" "NO_CHANGE"
        Set-ActionOutput "detected_version" ([string]$existingVersion.id)
        Set-ActionOutput "detected_kind" ([string]$existingVersion.updateKind)
        Write-Output "No semantic meta change: Version=$($existingVersion.id) Fingerprint=$metaFingerprint"
        exit 0
    }
    $readiness = (Get-Content -Raw -Encoding UTF8 -LiteralPath $currentMetaPath | ConvertFrom-Json).readiness
    if (-not $readiness) { $readiness = "META_STABLE" }
    $stage = "source-manifest"
    & (Join-Path $PSScriptRoot "new-data-source-manifest.ps1")
    $stage = "source-validation"
    & (Join-Path $PSScriptRoot "validate-offline-catalog.ps1")
    & (Join-Path $PSScriptRoot "validate-static-meta.ps1")
    $stage = "change-summary"
    & (Join-Path $PSScriptRoot "new-change-summary.ps1") -SiteDirectory $SiteDirectory
    $stage = "publish"
    & (Join-Path $PSScriptRoot "publish-data-history.ps1") -SiteDirectory $SiteDirectory -MetaFingerprint $metaFingerprint -Readiness $readiness
    $publishedIndex = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $siteRoot "data-index.json") | ConvertFrom-Json
    $publishedVersion = @($publishedIndex.versions | Where-Object { [string]$_.id -eq [string]$publishedIndex.latestVersionId }) | Select-Object -First 1
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
