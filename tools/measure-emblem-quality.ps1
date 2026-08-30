param(
    [string]$CatalogPath = 'source/current/tft/tft_catalog.json',
    [string]$CommunityDragonUrl = 'https://raw.communitydragon.org/latest/cdragon/tft/ja_jp.json',
    [string]$OutputPath = 'build/canonical-v2-live/emblem-quality.json',
    [switch]$RequireReady
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'normalize/Get-EmblemMappings.ps1')

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
function Resolve-RepoPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $repositoryRoot $Path))
}
function Get-LiveJson([string]$Url) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            return Invoke-RestMethod -Uri $Url -Headers @{ 'User-Agent' = 'TFT-Mobile-Overlay-Data/2.0 emblem-quality' } -TimeoutSec 120
        } catch {
            if ($attempt -eq 3) { throw }
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}

$catalogFile = Resolve-RepoPath $CatalogPath
$outputFile = Resolve-RepoPath $OutputPath
if (-not (Test-Path -LiteralPath $catalogFile -PathType Leaf)) { throw "Catalog not found: $catalogFile" }
$catalog = Get-Content -Raw -Encoding UTF8 -LiteralPath $catalogFile | ConvertFrom-Json
$setId = [string]$catalog.set.id
$setNumber = [int]$catalog.set.number
if (-not $setId -or $setNumber -le 0) { throw 'Catalog set identity is missing.' }

$live = Get-LiveJson -Url $CommunityDragonUrl
$setDataRows = @($live.setData | Where-Object { [string]$_.mutator -eq $setId } | Select-Object -First 1)
if ($setDataRows.Count -ne 1) { throw "CommunityDragon setData mismatch for $setId." }
$setData = $setDataRows[0]

$itemById = @{}
foreach ($item in @($live.items)) {
    if ($null -ne $item -and $item.apiName) { $itemById[[string]$item.apiName] = $item }
}
$mappingResult = Get-TftEmblemMappings -Traits @($setData.traits) -Items @($live.items) -SetNumber $setNumber

$mappedTraitIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($mapping in @($mappingResult.mappings)) {
    if ($mapping.traitId) { [void]$mappedTraitIds.Add([string]$mapping.traitId) }
}
$eligibleTraitIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($traitId in $mappedTraitIds) { [void]$eligibleTraitIds.Add([string]$traitId) }
foreach ($ambiguous in @($mappingResult.ambiguous)) {
    if ($ambiguous.traitId) { [void]$eligibleTraitIds.Add([string]$ambiguous.traitId) }
}

$missingEligibleTraitIds = @($eligibleTraitIds | Where-Object { -not $mappedTraitIds.Contains([string]$_) } | Sort-Object)
$ambiguousRows = @($mappingResult.ambiguous)
$missingImageIds = [Collections.Generic.List[string]]::new()
foreach ($mapping in @($mappingResult.mappings)) {
    $emblemId = [string]$mapping.emblemId
    if (-not $emblemId -or -not $itemById.ContainsKey($emblemId)) {
        if ($emblemId) { $missingImageIds.Add($emblemId) }
        continue
    }
    $sourceItem = $itemById[$emblemId]
    if (-not $sourceItem.icon) { $missingImageIds.Add($emblemId) }
}
$missingImages = @($missingImageIds | Sort-Object -Unique)

$status = if ($missingEligibleTraitIds.Count -eq 0 -and $ambiguousRows.Count -eq 0 -and $missingImages.Count -eq 0) { 'READY' } else { 'BLOCKED' }
$report = [pscustomobject][ordered]@{
    schemaVersion = 1
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    sourceUrl = $CommunityDragonUrl
    setId = $setId
    setNumber = $setNumber
    status = $status
    eligibleTraits = $eligibleTraitIds.Count
    mappedTraits = $mappedTraitIds.Count
    missingEligible = $missingEligibleTraitIds.Count
    duplicateMappings = $ambiguousRows.Count
    missingImages = $missingImages.Count
    missingEligibleTraitIds = @($missingEligibleTraitIds)
    missingImageEmblemIds = @($missingImages)
    ambiguous = @($ambiguousRows)
    mappings = @($mappingResult.mappings)
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputFile) | Out-Null
[IO.File]::WriteAllText($outputFile, (($report | ConvertTo-Json -Depth 20).Replace("`r`n","`n") + "`n"), [Text.UTF8Encoding]::new($false))

Write-Output "Measured emblem quality: Set=$setId Status=$status Eligible=$($eligibleTraitIds.Count) Mapped=$($mappedTraitIds.Count) MissingEligible=$($missingEligibleTraitIds.Count) Ambiguous=$($ambiguousRows.Count) MissingImages=$($missingImages.Count) Output=$outputFile"
if ($RequireReady -and $status -ne 'READY') {
    throw "EMBLEM_QUALITY_NOT_READY missingEligible=$($missingEligibleTraitIds.Count) duplicateMappings=$($ambiguousRows.Count) missingImages=$($missingImages.Count)"
}
