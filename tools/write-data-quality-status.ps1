param(
    [string]$SiteDirectory = 'site',
    [string]$SnapshotPath = '',
    [string]$CatalogPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'statistics-scope-contract.ps1')
. (Join-Path $PSScriptRoot 'published-data-contract.ps1')
$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
function Resolve-RepoPath([string]$Path) { if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }; return [IO.Path]::GetFullPath((Join-Path $repositoryRoot $Path)) }
function Get-Field($Object, [string]$Name, $Default = $null) { if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.PSObject.Properties[$Name].Value }; return $Default }

$siteRoot = Resolve-RepoPath $SiteDirectory
$published = Get-TftPublishedDataInputs $siteRoot
# Existing callers may supply acquisition paths, but mismatching content is
# rejected BEFORE writing status. Status itself always uses verified bundle bytes.
foreach ($inputPair in @(@($SnapshotPath,'tft_static_snapshot.json'), @($CatalogPath,'tft/tft_catalog.json'))) {
    if (-not [string]::IsNullOrWhiteSpace([string]$inputPair[0])) {
        $inputHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Resolve-RepoPath ([string]$inputPair[0]))).Hash.ToLowerInvariant()
        if ($inputHash -cne $published.payloads[[string]$inputPair[1]].sha256) { throw 'Data-quality input does not match the published bundle.' }
    }
}
$snapshot = $published.snapshot
$catalog = $published.catalog
$index = $published.index
$availableId = if ($index.PSObject.Properties['latestAvailableVersionId']) { [string]$index.latestAvailableVersionId } else { [string]$index.latestVersionId }
$stableId = if ($index.PSObject.Properties['latestStableVersionId']) { [string]$index.latestStableVersionId } else { [string]$index.latestVersionId }
$available = @($index.versions | Where-Object { [string]$_.id -eq $availableId }) | Select-Object -First 1
if (-not $available) { throw 'Latest available version is missing from data-index.json.' }
if ([string]$snapshot.setId -ne [string]$catalog.set.id -or [string]$available.setId -ne [string]$snapshot.setId) { throw 'Available version, snapshot, and catalog identities do not match while writing data quality.' }

$compositions = @($snapshot.compositions | Where-Object { $_ -is [pscustomobject] })
$features = Get-Field $available 'featureReadiness' $null
if (-not $features) {
    $features = [pscustomobject][ordered]@{ catalog='READY'; champions='READY'; traits='READY'; items='READY'; augments='READY'; compositions=$(if ($compositions.Count) { 'READY' } else { 'COLLECTING' }); boards=$(if ($compositions.Count) { 'READY' } else { 'COLLECTING' }); recommendedItems=$(if ($compositions.Count) { 'READY' } else { 'COLLECTING' }); compositionAugments=$(if (@($compositions | Where-Object { @($_.recommendedAugments).Count -gt 0 }).Count -eq $compositions.Count -and $compositions.Count) { 'READY' } else { 'COLLECTING' }) }
}
$levelBoards = Get-Field $available 'levelBoardReadiness' ([pscustomobject][ordered]@{ lv4='UNAVAILABLE';lv5='UNAVAILABLE';lv6='UNAVAILABLE';lv7='UNAVAILABLE';lv8='UNAVAILABLE';lv9='UNAVAILABLE' })
$releaseState = [string](Get-Field $available 'releaseState' $(if ([string]$available.readiness -eq 'META_STABLE') { 'STABLE' } else { 'PARTIAL' }))
$validationStatus = [string](Get-Field $available 'validationStatus' $(if ($releaseState -eq 'STABLE') { 'PASS' } else { 'PARTIAL_PASS' }))
$sourceAlignment = [string](Get-Field $available 'sourceAlignment' 'PARTIAL')
$qualityState = if ($releaseState -eq 'STABLE' -and [string]$features.compositionAugments -eq 'READY') { 'READY' } elseif ($releaseState -eq 'STABLE') { 'DEGRADED_OPTIONAL' } elseif ([string]$features.compositions -eq 'COLLECTING') { 'CATALOG_ONLY' } else { 'DEGRADED_CORE' }
$warnings = [Collections.Generic.List[string]]::new()
if ([string]$features.compositions -eq 'COLLECTING') { $warnings.Add('COMPOSITIONS_COLLECTING') }
$rankContract = Get-TftStatisticsScopeContract
if ([string]$features.compositions -eq 'PARTIAL') { $warnings.Add([string]$rankContract.limitedWarningCode) }
if ([string]$features.compositionAugments -ne 'READY') { $warnings.Add('COMPOSITION_AUGMENTS_COLLECTING') }
if ($sourceAlignment -ne 'VERIFIED') { $warnings.Add('SOURCE_ALIGNMENT_PARTIAL') }

$sourceUpdatedAt = Convert-TftUtcTimestamp $(if ($available.PSObject.Properties['sourceTimestampUtc'] -and $available.sourceTimestampUtc) { $available.sourceTimestampUtc } else { $snapshot.fetchedAtUtc })
$warningAfter = if ($index.PSObject.Properties['freshnessPolicy']) { [int]$index.freshnessPolicy.warningAfterSeconds } else { 21600 }
$criticalAfter = if ($index.PSObject.Properties['freshnessPolicy']) { [int]$index.freshnessPolicy.criticalAfterSeconds } else { 86400 }
$ageSeconds = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($sourceUpdatedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)).TotalSeconds
$freshnessStatus = if ($ageSeconds -lt -60 -or $ageSeconds -ge $criticalAfter) { 'CRITICAL' } elseif ($ageSeconds -ge $warningAfter) { 'WARNING' } else { 'FRESH' }
$scope = Get-Field $snapshot 'statisticsScope' $null
$target = [int](Get-Field $scope 'candidatePoolTarget' $compositions.Count); if ($target -lt 1) { $target = [Math]::Max(1, $compositions.Count) }
$qualified = [int](Get-Field $scope 'qualifiedEffectiveCompositions' 0)
$missingAugments = @($compositions | Where-Object { @($_.recommendedAugments).Count -eq 0 }).Count
$messageJa = switch ($qualityState) { 'CATALOG_ONLY' { '図鑑は利用できます。構成統計は収集中です。' }; 'DEGRADED_CORE' { "$($rankContract.displayName)の構成統計が十分に集まっていないため、一部のみ利用できます。" }; 'DEGRADED_OPTIONAL' { '主要データは利用できます。一部のおすすめ情報は収集中です。' }; default { '' } }
$messageEn = switch ($qualityState) { 'CATALOG_ONLY' { 'The catalog is available. Composition statistics are still being collected.' }; 'DEGRADED_CORE' { "Some $($rankContract.displayName) composition statistics are still being collected." }; 'DEGRADED_OPTIONAL' { 'Core data is ready. Some optional recommendations are still being collected.' }; default { '' } }

$status = [pscustomobject][ordered]@{
    schemaVersion=2; generatedAtUtc=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); sourceUpdatedAtUtc=$sourceUpdatedAt
    sourceCheckedAtUtc=(Convert-TftUtcTimestamp $(if ($index.PSObject.Properties['sourceCheckedAtUtc']) { $index.sourceCheckedAtUtc } else { $index.generatedAtUtc }))
    freshnessStatus=$freshnessStatus; freshnessPolicy=[pscustomobject][ordered]@{ warningAfterSeconds=$warningAfter; criticalAfterSeconds=$criticalAfter }
    versionId=$availableId; latestStableVersionId=$stableId; latestAvailableVersionId=$availableId
    setId=[string]$available.setId; setNumber=[int]$available.setNumber; setName=[string]$available.setName; patch=[string]$available.patch; revision=[string]$available.revision
    readiness=[string]$available.readiness; releaseState=$releaseState; validationStatus=$validationStatus; sourceAlignment=$sourceAlignment
    qualityState=$qualityState; userMessageJa=$messageJa; userMessageEn=$messageEn; features=$features; levelBoardReadiness=$levelBoards
    payloadSha256=[pscustomobject][ordered]@{ catalog=$published.payloads['tft/tft_catalog.json'].sha256; snapshot=$published.payloads['tft_static_snapshot.json'].sha256 }
    counts=[pscustomobject][ordered]@{ champions=@($catalog.champions).Count; traits=@($catalog.traits).Count; items=@($catalog.items).Count; augments=@($catalog.augments).Count; compositions=$compositions.Count; targetCompositions=$target; qualifiedSourceCompositions=$qualified; missingAugmentCompositions=$missingAugments }
    warnings=@($warnings.ToArray())
}
$outputPath = Join-Path $siteRoot 'data-quality.json'
$temporaryPath = Join-Path $siteRoot ('.data-quality-' + [Guid]::NewGuid().ToString('N') + '.tmp')
try {
    [IO.File]::WriteAllText($temporaryPath, (($status | ConvertTo-Json -Depth 12).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporaryPath, $outputPath, $true)
} finally {
    if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath }
}
Write-Output "Wrote data quality status: Available=$availableId Stable=$stableId Quality=$qualityState Freshness=$freshnessStatus"
