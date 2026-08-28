param(
    [Parameter(Mandatory = $true)][string]$SiteDirectory,
    [Parameter(Mandatory = $true)][string]$ReleaseId,
    [string]$ManifestPath = '',
    [string]$DataQualityPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-Full([string]$Base, [string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $Base $Path))
}
function Assert-UnderRoot([string]$Root, [string]$Path, [string]$Context) {
    $rootPrefix = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "CANDIDATE_PATH_ESCAPE context=$Context path=$full"
    }
}
function Get-Sha256([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}
function Test-ForbiddenDisplayText([string]$Text) {
    return $Text -match '@[^@\r\n]+@|\{\{[^}\r\n]+\}\}|任意の|可変値|戦闘中に変動'
}
function Assert-JsonContract($Node, [string]$Path = '$') {
    if ($null -eq $Node) { return }
    if ($Node -is [string]) {
        if (Test-ForbiddenDisplayText -Text ([string]$Node)) { throw "CANDIDATE_FORBIDDEN_DISPLAY_TEXT path=$Path" }
        return
    }
    if ($Node -is [double] -or $Node -is [single]) {
        $value = [double]$Node
        if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { throw "CANDIDATE_NONFINITE_NUMBER path=$Path" }
        return
    }
    if ($Node -is [pscustomobject]) {
        $arrayNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($name in @('versions','files','champions','traits','items','augments','compositions','recommendedAugments','levelBoards','unitIds','positions','recommended','warnings','tests','sources','compositionIds')) { [void]$arrayNames.Add($name) }
        foreach ($property in $Node.PSObject.Properties) {
            if ($arrayNames.Contains([string]$property.Name) -and $null -eq $property.Value) {
                throw "CANDIDATE_NULL_ARRAY path=$Path.$($property.Name)"
            }
            Assert-JsonContract -Node $property.Value -Path "$Path.$($property.Name)"
        }
        return
    }
    if ($Node -is [Collections.IEnumerable] -and $Node -isnot [string]) {
        $index = 0
        foreach ($item in $Node) {
            Assert-JsonContract -Node $item -Path "$Path[$index]"
            $index++
        }
    }
}

$siteRoot = [IO.Path]::GetFullPath($SiteDirectory)
if (-not (Test-Path -LiteralPath $siteRoot -PathType Container)) { throw "CANDIDATE_SITE_MISSING path=$siteRoot" }
if (-not $ManifestPath) { $ManifestPath = Join-Path $siteRoot "bundles/$ReleaseId/manifest.json" }
if (-not $DataQualityPath) { $DataQualityPath = Join-Path $siteRoot 'data-quality.json' }
$manifestFile = Resolve-Full $siteRoot $ManifestPath
$qualityFile = Resolve-Full $siteRoot $DataQualityPath
Assert-UnderRoot $siteRoot $manifestFile 'manifest'
Assert-UnderRoot $siteRoot $qualityFile 'data-quality'
foreach ($file in @($manifestFile, $qualityFile)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "CANDIDATE_REQUIRED_FILE_MISSING path=$file" }
}

$manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestFile | ConvertFrom-Json
$quality = Get-Content -Raw -Encoding UTF8 -LiteralPath $qualityFile | ConvertFrom-Json
Assert-JsonContract $manifest '$.manifest'
Assert-JsonContract $quality '$.quality'

if ([string]$manifest.id -ne $ReleaseId) { throw "CANDIDATE_MANIFEST_ID_MISMATCH expected=$ReleaseId actual=$($manifest.id)" }
if ([int]$quality.schemaVersion -ne 2) { throw "CANDIDATE_QUALITY_SCHEMA_UNSUPPORTED actual=$($quality.schemaVersion)" }
if ([string]$quality.releaseId -ne $ReleaseId -or [string]$quality.versionId -ne $ReleaseId) {
    throw "CANDIDATE_QUALITY_RELEASE_MISMATCH expected=$ReleaseId releaseId=$($quality.releaseId) versionId=$($quality.versionId)"
}
if ([string]$quality.overall -ne [string]$quality.qualityState) { throw 'CANDIDATE_QUALITY_STATE_MISMATCH' }
if ([string]$quality.features.compositions.filter -ne 'PLATINUM_PLUS' -or [string]$quality.features.compositions.queue -ne 'RANKED' -or [string]$quality.features.compositions.patch -ne 'CURRENT' -or [int]$quality.features.compositions.days -ne 3 -or [bool]$quality.features.compositions.permitFilterAdjustment) {
    throw 'CANDIDATE_COMPOSITION_FILTER_CONTRACT_MISMATCH'
}
if ([int]$quality.features.boards.syntheticBoardCount -ne 0 -or [int]$quality.features.boards.unknownUnitCount -ne 0) { throw 'CANDIDATE_BOARD_CONTRACT_FAILED' }
if ([int]$quality.features.champions.unresolvedTokens -ne 0 -or [int]$quality.features.traits.unresolvedTokens -ne 0 -or [int]$quality.features.recommendedItems.unresolvedItemIds -ne 0 -or [int]$quality.counts.unresolvedTokens -ne 0) {
    throw 'CANDIDATE_UNRESOLVED_CONTENT_PRESENT'
}
if ([int]$quality.features.emblems.missingEligible -ne 0 -or [int]$quality.features.emblems.duplicateMappings -ne 0 -or [int]$quality.features.emblems.missingImages -ne 0) {
    throw 'CANDIDATE_EMBLEM_CONTRACT_FAILED'
}

$manifestDir = Split-Path -Parent $manifestFile
$fileRows = @($manifest.files)
if ($fileRows.Count -eq 0) { throw 'CANDIDATE_MANIFEST_EMPTY' }
$checkedJson = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($row in $fileRows) {
    if (-not $row.url -or -not $row.sha256) { throw 'CANDIDATE_MANIFEST_FILE_FIELDS_MISSING' }
    $urlText = [string]$row.url
    if ([uri]::IsWellFormedUriString($urlText, [UriKind]::Absolute)) { throw "CANDIDATE_LOCAL_MANIFEST_ABSOLUTE_URL url=$urlText" }
    $relativePath = [uri]::UnescapeDataString(($urlText -split '[?#]', 2)[0]).Replace('/', [IO.Path]::DirectorySeparatorChar)
    $target = [IO.Path]::GetFullPath((Join-Path $manifestDir $relativePath))
    Assert-UnderRoot $siteRoot $target ([string]$row.path)
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "CANDIDATE_PAYLOAD_MISSING path=$($row.path) resolved=$target" }
    $length = (Get-Item -LiteralPath $target).Length
    if ($row.PSObject.Properties['bytes'] -and [int64]$row.bytes -ne $length) { throw "CANDIDATE_SIZE_MISMATCH path=$($row.path) expected=$($row.bytes) actual=$length" }
    $hash = Get-Sha256 $target
    if ($hash -ne ([string]$row.sha256).ToLowerInvariant()) { throw "CANDIDATE_HASH_MISMATCH path=$($row.path) expected=$($row.sha256) actual=$hash" }
    if ($target.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase) -and $checkedJson.Add($target)) {
        $json = Get-Content -Raw -Encoding UTF8 -LiteralPath $target | ConvertFrom-Json
        Assert-JsonContract $json "$.payload.$($row.path)"
    }
}

Write-Output "Publish candidate passed: Release=$ReleaseId Files=$($fileRows.Count) Quality=$($quality.overall)"
