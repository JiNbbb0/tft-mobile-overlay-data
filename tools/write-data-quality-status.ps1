param(
    [string]$SiteDirectory = 'site',
    [string]$SnapshotPath = 'source/current/tft_static_snapshot.json',
    [string]$CatalogPath = 'source/current/tft/tft_catalog.json'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
function Resolve-RepoPath([string]$Path) { if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }; return [IO.Path]::GetFullPath((Join-Path $repositoryRoot $Path)) }
function Get-Field($Object, [string]$Name, $Default = $null) { if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.PSObject.Properties[$Name].Value }; return $Default }

$siteRoot = Resolve-RepoPath $SiteDirectory
$snapshotFile = Resolve-RepoPath $SnapshotPath
$catalogFile = Resolve-RepoPath $CatalogPath
$indexFile = Join-Path $siteRoot 'data-index.json'
foreach ($file in @($snapshotFile, $catalogFile, $indexFile)) { if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Required data-quality input missing: $file" } }
$snapshot = Get-Content -Raw -Encoding UTF8 -LiteralPath $snapshotFile | ConvertFrom-Json
$catalog = Get-Content -Raw -Encoding UTF8 -LiteralPath $catalogFile | ConvertFrom-Json
$index = Get-Content -Raw -Encoding UTF8 -LiteralPath $indexFile | ConvertFrom-Json
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
if ([string]$features.compositions -eq 'PARTIAL') { $warnings.Add('PLATINUM_PLUS_COVERAGE_LIMITED') }
if ([string]$features.compositionAugments -ne 'READY') { $warnings.Add('COMPOSITION_AUGMENTS_COLLECTING') }
if ($sourceAlignment -ne 'VERIFIED') { $warnings.Add('SOURCE_ALIGNMENT_PARTIAL') }

$sourceUpdatedAt = if ($available.PSObject.Properties['sourceTimestampUtc'] -and [string]$available.sourceTimestampUtc) { [string]$available.sourceTimestampUtc } else { [string]$snapshot.fetchedAtUtc }
$warningAfter = if ($index.PSObject.Properties['freshnessPolicy']) { [int]$index.freshnessPolicy.warningAfterSeconds } else { 21600 }
$criticalAfter = if ($index.PSObject.Properties['freshnessPolicy']) { [int]$index.freshnessPolicy.criticalAfterSeconds } else { 86400 }
$ageSeconds = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($sourceUpdatedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)).TotalSeconds
$freshnessStatus = if ($ageSeconds -lt -60 -or $ageSeconds -ge $criticalAfter) { 'CRITICAL' } elseif ($ageSeconds -ge $warningAfter) { 'WARNING' } else { 'FRESH' }
$scope = Get-Field $snapshot 'statisticsScope' $null
$target = [int](Get-Field $scope 'candidatePoolTarget' $compositions.Count); if ($target -lt 1) { $target = [Math]::Max(1, $compositions.Count) }
$qualified = [int](Get-Field $scope 'qualifiedEffectiveCompositions' 0)
$missingAugments = @($compositions | Where-Object { @($_.recommendedAugments).Count -eq 0 }).Count
$messageJa = switch ($qualityState) { 'CATALOG_ONLY' { '図鑑は利用できます。構成統計は収集中です。' }; 'DEGRADED_CORE' { 'Platinum+の構成統計が十分に集まっていないため、一部のみ利用できます。' }; 'DEGRADED_OPTIONAL' { '主要データは利用できます。一部のおすすめ情報は収集中です。' }; default { '' } }
$messageEn = switch ($qualityState) { 'CATALOG_ONLY' { 'The catalog is available. Composition statistics are still being collected.' }; 'DEGRADED_CORE' { 'Some Platinum+ composition statistics are still being collected.' }; 'DEGRADED_OPTIONAL' { 'Core data is ready. Some optional recommendations are still being collected.' }; default { '' } }

$status = [pscustomobject][ordered]@{
    schemaVersion=2; generatedAtUtc=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); sourceUpdatedAtUtc=$sourceUpdatedAt
    sourceCheckedAtUtc=$(if ($index.PSObject.Properties['sourceCheckedAtUtc']) { [string]$index.sourceCheckedAtUtc } else { [string]$index.generatedAtUtc })
    freshnessStatus=$freshnessStatus; freshnessPolicy=[pscustomobject][ordered]@{ warningAfterSeconds=$warningAfter; criticalAfterSeconds=$criticalAfter }
    versionId=$availableId; latestStableVersionId=$stableId; latestAvailableVersionId=$availableId
    setId=[string]$available.setId; setNumber=[int]$available.setNumber; setName=[string]$available.setName; patch=[string]$available.patch; revision=[string]$available.revision
    readiness=[string]$available.readiness; releaseState=$releaseState; validationStatus=$validationStatus; sourceAlignment=$sourceAlignment
    qualityState=$qualityState; userMessageJa=$messageJa; userMessageEn=$messageEn; features=$features; levelBoardReadiness=$levelBoards
    counts=[pscustomobject][ordered]@{ champions=@($catalog.champions).Count; traits=@($catalog.traits).Count; items=@($catalog.items).Count; augments=@($catalog.augments).Count; compositions=$compositions.Count; targetCompositions=$target; qualifiedSourceCompositions=$qualified; missingAugmentCompositions=$missingAugments }
    warnings=@($warnings.ToArray())
}
$outputPath = Join-Path $siteRoot 'data-quality.json'
[IO.File]::WriteAllText($outputPath, (($status | ConvertTo-Json -Depth 12).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
Write-Output "Wrote data quality status: Available=$availableId Stable=$stableId Quality=$qualityState Freshness=$freshnessStatus"
