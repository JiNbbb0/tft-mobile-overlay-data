param(
    [switch]$Force,
    [string]$SiteDirectory = "site"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

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
        $null -ne $cost -and [int]$cost -ge 1 -and [int]$cost -le 5 -and $name -and @($traits | Where-Object { $_ }).Count -gt 0
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
    Write-Warning "Derived CommunityDragon champion block is incomplete for $setId ($($derivedPlayable.Count) playable). The catalog generator will use its source-backed raw LIVE fallback."
} else {
    Write-Output "CommunityDragon source readiness passed: Set=$setId Champions=$($derivedPlayable.Count) Traits=$jaTraitCount/$enTraitCount Items=$jaItemCount Augments=$jaAugmentCount"
}

$arguments = @{ SiteDirectory = $SiteDirectory }
if ($Force) { $arguments.Force = $true }
& (Join-Path $PSScriptRoot 'refresh-live-data.ps1') @arguments
