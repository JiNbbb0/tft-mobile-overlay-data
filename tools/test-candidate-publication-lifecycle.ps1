$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('tft-candidate-lifecycle-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
try {
    $publishPath = Join-Path $tempRoot 'publish-data-history.ps1'
    $refreshPath = Join-Path $tempRoot 'refresh-live-data.ps1'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'publish-data-history.ps1') -Destination $publishPath -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'refresh-live-data.ps1') -Destination $refreshPath -Force

    & (Join-Path $PSScriptRoot 'enable-candidate-publication-lifecycle.ps1') `
        -PublishHistoryPath $publishPath `
        -RefreshLivePath $refreshPath

    $publish = [IO.File]::ReadAllText($publishPath).Replace("`r`n", "`n")
    $refresh = [IO.File]::ReadAllText($refreshPath).Replace("`r`n", "`n")

    foreach ($required in @(
        '# CANONICAL_V2_CANDIDATE_STAGE_BEGIN',
        '-LatestVersionId $candidatePreviousLatestVersionId',
        'latestVersionId = $candidatePreviousLatestVersionId',
        '# CANONICAL_V2_CANDIDATE_DESCRIPTOR_BEGIN',
        'previousLatestVersionId = $candidatePreviousLatestVersionId'
    )) {
        if (-not $publish.Contains($required)) { throw "Candidate publisher hardening missing: $required" }
    }
    foreach ($required in @(
        '# CANONICAL_V2_CANDIDATE_REFRESH_BEGIN',
        'candidateDescriptor.releaseId',
        'CANDIDATE_WAS_PROMOTED_EARLY'
    )) {
        if (-not $refresh.Contains($required)) { throw "Candidate refresh hardening missing: $required" }
    }
    if ($publish.Contains('    latestVersionId = $versionId')) { throw 'Publisher still moves latestVersionId during candidate creation.' }
    if ($refresh.Contains('Where-Object { [string]$_.id -eq [string]$publishedIndex.latestVersionId }')) {
        throw 'Refresh still reports the active LKG as the generated candidate.'
    }

    foreach ($path in @($publishPath, $refreshPath)) {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        if (@($errors).Count -gt 0) {
            throw "Candidate lifecycle patch produced parser errors in $path: $(@($errors | ForEach-Object Message) -join '; ')"
        }
    }

    $firstPublishHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $publishPath).Hash
    $firstRefreshHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $refreshPath).Hash
    & (Join-Path $PSScriptRoot 'enable-candidate-publication-lifecycle.ps1') `
        -PublishHistoryPath $publishPath `
        -RefreshLivePath $refreshPath
    if ($firstPublishHash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $publishPath).Hash -or
        $firstRefreshHash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $refreshPath).Hash) {
        throw 'Candidate publication lifecycle injector is not idempotent.'
    }

    Write-Output 'Candidate publication lifecycle regression passed.'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
