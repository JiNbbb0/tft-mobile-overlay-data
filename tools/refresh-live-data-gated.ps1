param(
    [switch]$Force,
    [string]$SiteDirectory = "site"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$userAgent = "TFT-Mobile-Overlay-Data/1.0 source-readiness-gate"

function Set-ActionOutput([string]$Name, [string]$Value) {
    if ($env:GITHUB_OUTPUT) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$Name=$Value" -Encoding UTF8 }
}

function Get-WebText([string]$Url) {
    $lines = & curl.exe -L --fail --silent --show-error --retry 2 --retry-delay 5 --retry-all-errors --max-time 120 -A $userAgent $Url
    if ($LASTEXITCODE -ne 0) { throw "Request failed ($LASTEXITCODE): $Url" }
    return ($lines -join "`n")
}

function Get-ObjectPropertyValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-CollectionCount {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    return @((Get-ObjectPropertyValue -Object $Object -Name $Name)).Count
}

function Stop-AsSourceNotReady {
    param(
        [Parameter(Mandatory = $true)][string]$SetId,
        [Parameter(Mandatory = $true)][string]$Revision,
        [Parameter(Mandatory = $true)][string]$Reason
    )
    Set-ActionOutput "changed" "false"
    Set-ActionOutput "published" "false"
    Set-ActionOutput "result" "SOURCE_NOT_READY"
    Set-ActionOutput "detected_set" $SetId
    Set-ActionOutput "detected_revision" $Revision
    Write-Warning "Source not ready for $SetId ($Revision): $Reason. Keeping the last-known-good publication; the next scheduled run will retry."
    exit 0
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Enable-RawChampionFallback {
    $catalogPath = Join-Path $PSScriptRoot 'refresh-catalog.ps1'
    $catalogText = [IO.File]::ReadAllText($catalogPath).Replace("`r`n", "`n")
    $startMarker = '$playableChampions = @('
    $endMarker = '$championIdsByTraitName = @{}'
    $start = $catalogText.IndexOf($startMarker, [StringComparison]::Ordinal)
    $end = $catalogText.IndexOf($endMarker, $start, [StringComparison]::Ordinal)
    if ($start -lt 0 -or $end -lt 0) { throw 'Could not locate champion selection block for raw fallback patch.' }

    $replacement = @'
$playableChampions = @(
    $setJa.champions |
        Where-Object {
            $_.cost -ge 1 -and $_.cost -le 5 -and
            $_.name -and @($_.traits).Count -gt 0
        } |
        Sort-Object cost, name
)
if ($playableChampions.Count -lt 40) {
    . (Join-Path $PSScriptRoot 'raw-champion-fallback.ps1')
    $playableChampions = @(Get-RawSetChampions -SetNumber $SetNumber -SetJa $setJa -SetEn $setEn)
    $Sources['communityDragonRawMap22'] = 'https://raw.communitydragon.org/latest/game/data/maps/shipping/map22/map22.bin.json'
    $Sources['communityDragonJaStringTable'] = 'https://raw.communitydragon.org/latest/game/ja_jp/data/menu/ja_jp/tft.stringtable.json'
    $Sources['communityDragonEnStringTable'] = 'https://raw.communitydragon.org/latest/game/en_us/data/menu/en_us/tft.stringtable.json'
}

'@
    $catalogText = $catalogText.Substring(0, $start) + $replacement + $catalogText.Substring($end)

    $oldNoUrl = @'
    if (-not $url) {
        $DownloadFailures.Add([pscustomobject]@{ category = $Category; id = $OwnerId; reason = "画像パスなし" })
        return ""
    }
'@
    $newNoUrl = @'
    if (-not $url) {
        if ($Category -eq "ability") { return "" }
        $DownloadFailures.Add([pscustomobject]@{ category = $Category; id = $OwnerId; reason = "画像パスなし" })
        return ""
    }
'@
    if (-not $catalogText.Contains($oldNoUrl)) { throw 'Could not patch optional ability image handling.' }
    $catalogText = $catalogText.Replace($oldNoUrl, $newNoUrl)

    $oldEnglish = '$englishName = if ($english) { [string]$english.name } else { "" }'
    $newEnglish = '$englishName = if ($english) { [string]$english.name } elseif ($champion.PSObject.Properties[''nameEn'']) { [string]$champion.nameEn } else { "" }'
    $englishIndex = $catalogText.IndexOf($oldEnglish, [StringComparison]::Ordinal)
    if ($englishIndex -lt 0) { throw 'Could not patch raw champion English name fallback.' }
    $catalogText = $catalogText.Remove($englishIndex, $oldEnglish.Length).Insert($englishIndex, $newEnglish)

    $oldChampionNameEn = '        nameEn = if ($english) { [string]$english.name } else { "" }'
    $newChampionNameEn = '        nameEn = $englishName'
    $championNameIndex = $catalogText.IndexOf($oldChampionNameEn, $englishIndex, [StringComparison]::Ordinal)
    if ($championNameIndex -lt 0) { throw 'Could not patch champion nameEn output.' }
    $catalogText = $catalogText.Remove($championNameIndex, $oldChampionNameEn.Length).Insert($championNameIndex, $newChampionNameEn)

    $oldAbilityNameEn = '            nameEn = if ($english) { [string]$english.ability.name } else { "" }'
    $newAbilityNameEn = '            nameEn = if ($english) { [string]$english.ability.name } elseif ($champion.ability.PSObject.Properties[''nameEn'']) { [string]$champion.ability.nameEn } else { "" }'
    if (-not $catalogText.Contains($oldAbilityNameEn)) { throw 'Could not patch raw champion ability English name.' }
    $catalogText = $catalogText.Replace($oldAbilityNameEn, $newAbilityNameEn)

    $oldTraitNames = '$traitNames = @($playableChampions.traits | Sort-Object -Unique)'
    $newTraitNames = '$traitNames = @($playableChampions | ForEach-Object { @($_.traits) } | Where-Object { $_ } | Sort-Object -Unique)'
    if (-not $catalogText.Contains($oldTraitNames)) { throw 'Could not patch champion trait flattening.' }
    $catalogText = $catalogText.Replace($oldTraitNames, $newTraitNames)

    $oldOutOfSet = '$outOfSetChampions = @($champions | Where-Object { $_.id -notmatch "^TFT${SetNumber}_" })'
    $newOutOfSet = @'
$expectedChampionIds = @{}
foreach ($expectedChampion in $playableChampions) { $expectedChampionIds[[string]$expectedChampion.apiName] = $true }
$outOfSetChampions = @($champions | Where-Object { -not $expectedChampionIds.ContainsKey([string]$_.id) })
'@.TrimEnd()
    if ($catalogText.Contains($oldOutOfSet)) { $catalogText = $catalogText.Replace($oldOutOfSet, $newOutOfSet) }

    Write-Utf8NoBom -Path $catalogPath -Text $catalogText

    $metaPath = Join-Path $PSScriptRoot 'refresh-static-meta.ps1'
    $metaText = [IO.File]::ReadAllText($metaPath).Replace("`r`n", "`n")
    $metaStart = $metaText.IndexOf('$unitMap = @{}', [StringComparison]::Ordinal)
    $metaEnd = $metaText.IndexOf('$traitMap = @{}', $metaStart, [StringComparison]::Ordinal)
    if ($metaStart -lt 0 -or $metaEnd -lt 0) { throw 'Could not locate static-meta unit map block.' }
    $metaReplacement = @'
$unitMap = @{}
foreach ($unit in $setData.champions) {
    if ($unit.apiName -and $unit.name) {
        $unitMap[[string]$unit.apiName] = $unit
    }
}
if ($unitMap.Count -lt 40) {
    $rawCatalogPath = Join-Path $RepositoryRoot 'source/current/tft/tft_catalog.json'
    if (-not (Test-Path -LiteralPath $rawCatalogPath)) { throw "Raw-rebuilt catalog not found: $rawCatalogPath" }
    $rawCatalog = Get-Content -Raw -Encoding UTF8 -LiteralPath $rawCatalogPath | ConvertFrom-Json
    foreach ($unit in @($rawCatalog.champions)) {
        $unitMap[[string]$unit.id] = [pscustomobject]@{
            apiName = [string]$unit.id
            name = [string]$unit.nameJa
            cost = [int]$unit.cost
            traits = @($unit.traits)
        }
    }
    Write-Output "Static-meta unit map recovered from raw-rebuilt catalog: $($unitMap.Count) units"
}

'@
    $metaText = $metaText.Substring(0, $metaStart) + $metaReplacement + $metaText.Substring($metaEnd)
    $oldCompositionCount = '$($compositions.Count)'
    $newCompositionCount = '$(@($compositions).Count)'
    if (-not $metaText.Contains($oldCompositionCount)) { throw 'Could not patch scalar composition count handling.' }
    $metaText = $metaText.Replace($oldCompositionCount, $newCompositionCount)
    Write-Utf8NoBom -Path $metaPath -Text $metaText

    # Catalog-first snapshots intentionally contain no composition objects yet.
    # Make the publication metadata calculation ignore JSON null placeholders.
    $historyPath = Join-Path $PSScriptRoot 'publish-data-history.ps1'
    $historyText = [IO.File]::ReadAllText($historyPath).Replace("`r`n", "`n")
    $oldHistoryStats = @'
    compositionCount = @($meta.compositions).Count
    itemStatCount = @($meta.compositions | ForEach-Object { @($_.units | ForEach-Object { @($_.itemStats) }) }).Count
'@
    $newHistoryStats = @'
    compositionCount = @($meta.compositions | Where-Object { $_ -is [pscustomobject] }).Count
    itemStatCount = @(
        foreach ($composition in @($meta.compositions)) {
            if ($composition -isnot [pscustomobject] -or -not ($composition.PSObject.Properties.Name -contains 'units')) { continue }
            foreach ($unit in @($composition.units)) {
                if ($unit -is [pscustomobject] -and ($unit.PSObject.Properties.Name -contains 'itemStats')) {
                    @($unit.itemStats)
                }
            }
        }
    ).Count
'@
    if (-not $historyText.Contains($oldHistoryStats)) { throw 'Could not patch catalog-first history statistics.' }
    $historyText = $historyText.Replace($oldHistoryStats, $newHistoryStats)
    Write-Utf8NoBom -Path $historyPath -Text $historyText

    if ($setNumber -eq 18) {
        $livePath = Join-Path $PSScriptRoot 'refresh-live-data.ps1'
        $liveText = [IO.File]::ReadAllText($livePath).Replace("`r`n", "`n")
        $oldNames = @'
    $setNameJa = if ([string]$setJa.name) { [string]$setJa.name } else { "Set $setNumber" }
    $setNameEn = if ([string]$setEn.name) { [string]$setEn.name } else { "Set $setNumber" }
'@
        $newNames = @'
    $setNameJa = if ($setNumber -eq 18) { "神秘の森" } elseif ([string]$setJa.name) { [string]$setJa.name } else { "Set $setNumber" }
    $setNameEn = if ($setNumber -eq 18) { "Enchanted Wilds" } elseif ([string]$setEn.name) { [string]$setEn.name } else { "Set $setNumber" }
'@
        if ($liveText.Contains($oldNames)) {
            $liveText = $liveText.Replace($oldNames, $newNames)
            Write-Utf8NoBom -Path $livePath -Text $liveText
        }
    }
}

$clusterResponse = Get-WebText 'https://api-hc.metatft.com/tft-comps-api/latest_cluster_info' | ConvertFrom-Json
$cluster = $clusterResponse.cluster_info
if (-not $cluster -or -not $cluster.cluster_id -or -not $cluster.tft_set -or [string]$cluster.state -ne 'published' -or [bool]$cluster.is_failed -or [bool]$cluster.is_deleted) {
    throw 'Published cluster metadata is incomplete or unsafe'
}
$setId = [string]$cluster.tft_set
$revision = [string]$cluster.cluster_id

$ja = Get-WebText 'https://raw.communitydragon.org/latest/cdragon/tft/ja_jp.json' | ConvertFrom-Json
$en = Get-WebText 'https://raw.communitydragon.org/latest/cdragon/tft/en_us.json' | ConvertFrom-Json
$setJa = @($ja.setData | Where-Object { [string]$_.mutator -eq $setId }) | Select-Object -First 1
$setEn = @($en.setData | Where-Object { [string]$_.mutator -eq $setId }) | Select-Object -First 1
if (-not $setJa -or -not $setEn) {
    Stop-AsSourceNotReady -SetId $setId -Revision $revision -Reason 'localized CommunityDragon set data is not present yet'
}

$setNumberValue = Get-ObjectPropertyValue -Object $setJa -Name 'number'
$setNumber = if ($setNumberValue) { [int]$setNumberValue } else { [int]($setId -replace '\D','') }
$derivedPlayable = @(
    @((Get-ObjectPropertyValue -Object $setJa -Name 'champions')) | Where-Object {
        $cost = Get-ObjectPropertyValue -Object $_ -Name 'cost'
        $name = Get-ObjectPropertyValue -Object $_ -Name 'name'
        $traits = Get-ObjectPropertyValue -Object $_ -Name 'traits'
        $null -ne $cost -and [int]$cost -ge 1 -and [int]$cost -le 5 -and $name -and @($traits).Count -gt 0
    }
)
$jaTraitCount = Get-CollectionCount -Object $setJa -Name 'traits'
$enTraitCount = Get-CollectionCount -Object $setEn -Name 'traits'
$jaItemCount = Get-CollectionCount -Object $setJa -Name 'items'
$jaAugmentCount = Get-CollectionCount -Object $setJa -Name 'augments'

if ($jaTraitCount -lt 20 -or $enTraitCount -lt 20) {
    Stop-AsSourceNotReady -SetId $setId -Revision $revision -Reason "trait catalog is still partial (ja=$jaTraitCount, en=$enTraitCount)"
}
if ($jaItemCount -lt 10) {
    Stop-AsSourceNotReady -SetId $setId -Revision $revision -Reason "set item catalog is still partial (count=$jaItemCount)"
}
if ($jaAugmentCount -lt 20) {
    Stop-AsSourceNotReady -SetId $setId -Revision $revision -Reason "augment catalog is still partial (count=$jaAugmentCount)"
}

if ($derivedPlayable.Count -lt 40) {
    Write-Warning "Derived CommunityDragon champion block is incomplete for $setId ($($derivedPlayable.Count) playable). Enabling LIVE raw-client fallback."
    Enable-RawChampionFallback
} else {
    Write-Output "CommunityDragon source readiness passed: Set=$setId Champions=$($derivedPlayable.Count) Traits=$jaTraitCount/$enTraitCount Items=$jaItemCount Augments=$jaAugmentCount"
}

$arguments = @{ SiteDirectory = $SiteDirectory }
if ($Force) { $arguments.Force = $true }
& (Join-Path $PSScriptRoot 'refresh-live-data.ps1') @arguments
