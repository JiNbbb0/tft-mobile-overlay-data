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
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-PrefixedChampions {
    param(
        [AllowNull()][object]$SetData,
        [Parameter(Mandatory = $true)][int]$SetNumber
    )
    $championsValue = Get-ObjectPropertyValue -Object $SetData -Name 'champions'
    return @(
        @($championsValue) | Where-Object {
            $apiName = [string](Get-ObjectPropertyValue -Object $_ -Name 'apiName')
            $apiName -match "^TFT${SetNumber}_"
        }
    )
}

function Get-PlayableChampions {
    param(
        [AllowNull()][object]$SetData,
        [Parameter(Mandatory = $true)][int]$SetNumber
    )
    return @(
        Get-PrefixedChampions -SetData $SetData -SetNumber $SetNumber | Where-Object {
            $name = [string](Get-ObjectPropertyValue -Object $_ -Name 'name')
            $costValue = Get-ObjectPropertyValue -Object $_ -Name 'cost'
            $traitsValue = Get-ObjectPropertyValue -Object $_ -Name 'traits'
            $abilityValue = Get-ObjectPropertyValue -Object $_ -Name 'ability'
            $statsValue = Get-ObjectPropertyValue -Object $_ -Name 'stats'
            $squareIcon = [string](Get-ObjectPropertyValue -Object $_ -Name 'squareIcon')

            $cost = 0
            $costValid = $null -ne $costValue -and [int]::TryParse([string]$costValue, [ref]$cost)
            $abilityIcon = [string](Get-ObjectPropertyValue -Object $abilityValue -Name 'icon')
            $statsMana = Get-ObjectPropertyValue -Object $statsValue -Name 'mana'

            $name -and
            $costValid -and $cost -ge 1 -and $cost -le 5 -and
            @($traitsValue).Count -gt 0 -and
            $squareIcon -and
            $abilityValue -and $abilityIcon -and
            $statsValue -and $null -ne $statsMana
        }
    )
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

# MetaTFT can announce a new live set slightly before CommunityDragon's localized
# catalog export has converged. Publishing during that window can produce an
# empty/partial catalog. Gate only catalog readiness here; statistics readiness
# remains handled by refresh-live-data.ps1 (catalog-first for a never-published set).
$clusterResponse = Get-WebText "https://api-hc.metatft.com/tft-comps-api/latest_cluster_info" | ConvertFrom-Json
$cluster = $clusterResponse.cluster_info
if (-not $cluster -or -not $cluster.cluster_id -or -not $cluster.tft_set -or [string]$cluster.state -ne "published" -or [bool]$cluster.is_failed -or [bool]$cluster.is_deleted) {
    throw "Published cluster metadata is incomplete or unsafe"
}
$setId = [string]$cluster.tft_set
$revision = [string]$cluster.cluster_id

$ja = Get-WebText "https://raw.communitydragon.org/latest/cdragon/tft/ja_jp.json" | ConvertFrom-Json
$en = Get-WebText "https://raw.communitydragon.org/latest/cdragon/tft/en_us.json" | ConvertFrom-Json
$setJa = @($ja.setData | Where-Object { [string]$_.mutator -eq $setId }) | Select-Object -First 1
$setEn = @($en.setData | Where-Object { [string]$_.mutator -eq $setId }) | Select-Object -First 1

if (-not $setJa -or -not $setEn) {
    Stop-AsSourceNotReady -SetId $setId -Revision $revision -Reason "localized CommunityDragon set data is not present yet"
}

$setNumberValue = Get-ObjectPropertyValue -Object $setJa -Name 'number'
$setNumber = if ($setNumberValue) { [int]$setNumberValue } else { [int]($setId -replace '\D','') }
$jaPrefixed = @(Get-PrefixedChampions -SetData $setJa -SetNumber $setNumber)
$enPrefixed = @(Get-PrefixedChampions -SetData $setEn -SetNumber $setNumber)
$jaPlayable = @(Get-PlayableChampions -SetData $setJa -SetNumber $setNumber)
$enPlayable = @(Get-PlayableChampions -SetData $setEn -SetNumber $setNumber)
$jaTraitCount = Get-CollectionCount -Object $setJa -Name 'traits'
$enTraitCount = Get-CollectionCount -Object $setEn -Name 'traits'
$jaItemCount = Get-CollectionCount -Object $setJa -Name 'items'
$jaAugmentCount = Get-CollectionCount -Object $setJa -Name 'augments'

$minimumChampions = 40
$minimumTraits = 20
$minimumItems = 10
$minimumAugments = 20

if ($jaPrefixed.Count -lt $minimumChampions -or $enPrefixed.Count -lt $minimumChampions) {
    Stop-AsSourceNotReady -SetId $setId -Revision $revision -Reason "champion roster is still partial (ja=$($jaPrefixed.Count), en=$($enPrefixed.Count), minimum=$minimumChampions)"
}

# Once the full-looking roster exists, a large gap between prefixed and usable
# champions is more likely a schema break than normal rollout lag. Fail loudly
# instead of hiding a parser regression as an indefinitely pending source.
$minimumUsable = [Math]::Floor([Math]::Min($jaPrefixed.Count, $enPrefixed.Count) * 0.90)
if ($jaPlayable.Count -lt $minimumUsable -or $enPlayable.Count -lt $minimumUsable) {
    throw "CommunityDragon champion schema is incomplete or unsupported for ${setId}: prefixed ja=$($jaPrefixed.Count)/en=$($enPrefixed.Count), usable ja=$($jaPlayable.Count)/en=$($enPlayable.Count), required=$minimumUsable"
}

if ($jaTraitCount -lt $minimumTraits -or $enTraitCount -lt $minimumTraits) {
    Stop-AsSourceNotReady -SetId $setId -Revision $revision -Reason "trait catalog is still partial (ja=$jaTraitCount, en=$enTraitCount, minimum=$minimumTraits)"
}
if ($jaItemCount -lt $minimumItems) {
    Stop-AsSourceNotReady -SetId $setId -Revision $revision -Reason "set item catalog is still partial (count=$jaItemCount, minimum=$minimumItems)"
}
if ($jaAugmentCount -lt $minimumAugments) {
    Stop-AsSourceNotReady -SetId $setId -Revision $revision -Reason "augment catalog is still partial (count=$jaAugmentCount, minimum=$minimumAugments)"
}

Write-Output "CommunityDragon source readiness passed: Set=$setId Champions=$($jaPlayable.Count)/$($enPlayable.Count) Traits=$jaTraitCount/$enTraitCount Items=$jaItemCount Augments=$jaAugmentCount"

$arguments = @{
    SiteDirectory = $SiteDirectory
}
if ($Force) { $arguments.Force = $true }
& (Join-Path $PSScriptRoot 'refresh-live-data.ps1') @arguments
