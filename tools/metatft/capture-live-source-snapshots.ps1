param(
    [string]$DryRunPath = 'build/canonical-v2-live/live-canonical-dryrun.json',
    [string]$OutputDirectory = 'build/canonical-v2-live/sources'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
function Resolve-RepoPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}
function Get-SafeName([string]$Value) {
    return [regex]::Replace($Value, '[^A-Za-z0-9._-]+', '_')
}
function Get-Sha256Hex([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Get-FirstHeaderValue([System.Net.Http.Headers.HttpHeaders]$Headers, [string]$Name) {
    if ($null -eq $Headers -or -not $Headers.Contains($Name)) { return '' }
    $values = @($Headers.GetValues($Name))
    if ($values.Count -eq 0) { return '' }
    return [string]$values[0]
}
function Capture-Source([string]$Name, [uri]$Uri, [string]$TargetPath) {
    $client = [Net.Http.HttpClient]::new()
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(120)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('TFT-Mobile-Overlay-Data/2.0 canonical-source-snapshot')
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
                try {
                    if (-not $response.IsSuccessStatusCode) { throw "HTTP $([int]$response.StatusCode)" }
                    if ($response.RequestMessage.RequestUri.Scheme -ne 'https') { throw 'Redirect left HTTPS.' }
                    $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                    $etag = Get-FirstHeaderValue -Headers $response.Headers -Name 'ETag'
                    if (-not $etag) { $etag = Get-FirstHeaderValue -Headers $response.Content.Headers -Name 'ETag' }
                    [IO.File]::WriteAllBytes($TargetPath, $bytes)
                    return [pscustomobject][ordered]@{
                        name = $Name
                        url = [string]$response.RequestMessage.RequestUri
                        fetchedAtUtc = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                        etag = $etag
                        sha256 = Get-Sha256Hex -Bytes $bytes
                        bytes = $bytes.Length
                        file = [IO.Path]::GetRelativePath((Resolve-RepoPath $OutputDirectory), $TargetPath).Replace('\\','/')
                        statusCode = [int]$response.StatusCode
                    }
                } finally { $response.Dispose() }
            } catch {
                if ($attempt -eq 3) { throw "Source snapshot failed for ${Name}: $($_.Exception.Message)" }
                Start-Sleep -Seconds (2 * $attempt)
            }
        }
    } finally { $client.Dispose() }
}

$dryRunFile = Resolve-RepoPath $DryRunPath
$outputRoot = Resolve-RepoPath $OutputDirectory
if (-not (Test-Path -LiteralPath $dryRunFile -PathType Leaf)) { throw "Canonical dry-run not found: $dryRunFile" }
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$dryRun = Get-Content -Raw -Encoding UTF8 -LiteralPath $dryRunFile | ConvertFrom-Json
if (-not $dryRun.PSObject.Properties['set'] -or $null -eq $dryRun.set) {
    throw 'Canonical dry-run is missing the set identity object.'
}
$clusterId = [int]$dryRun.set.clusterId
$setId = [string]$dryRun.set.id
if ($clusterId -le 0 -or -not $setId) { throw 'Canonical dry-run set identity is missing set.id/set.clusterId.' }
$compositionIds = @($dryRun.compositions | ForEach-Object { [string]$_.id } | Where-Object { $_ } | Sort-Object -Unique)
if ($compositionIds.Count -eq 0) { throw 'Canonical dry-run contains no compositions for source snapshotting.' }

$rankFilter = 'CHALLENGER,DIAMOND,EMERALD,GRANDMASTER,MASTER,PLATINUM'
$baseSources = @(
    [pscustomobject]@{ name='metatft-robots'; url='https://www.metatft.com/robots.txt'; extension='txt' },
    [pscustomobject]@{ name='communitydragon-ja-jp'; url='https://raw.communitydragon.org/latest/cdragon/tft/ja_jp.json'; extension='json' },
    [pscustomobject]@{ name='communitydragon-en-us'; url='https://raw.communitydragon.org/latest/cdragon/tft/en_us.json'; extension='json' },
    [pscustomobject]@{ name='metatft-latest-cluster-info'; url='https://api-hc.metatft.com/tft-comps-api/latest_cluster_info'; extension='json' },
    [pscustomobject]@{ name='metatft-comps-data'; url='https://api-hc.metatft.com/tft-comps-api/comps_data'; extension='json' },
    [pscustomobject]@{ name='metatft-comps-stats-platinum-plus-current-3d'; url="https://api-hc.metatft.com/tft-comps-api/comps_stats?queue=1100&patch=current&days=3&rank=$rankFilter&permit_filter_adjustment=false"; extension='json' }
)

$rows = [Collections.Generic.List[object]]::new()
foreach ($source in $baseSources) {
    $fileName = "$(Get-SafeName $source.name).$($source.extension)"
    $rows.Add((Capture-Source -Name ([string]$source.name) -Uri ([uri]$source.url) -TargetPath (Join-Path $outputRoot $fileName)))
}
foreach ($compositionId in $compositionIds) {
    $name = "metatft-comp-details-$compositionId"
    $url = "https://api-hc.metatft.com/tft-comps-api/comp_details?comp=$compositionId&cluster_id=$clusterId"
    $fileName = "$(Get-SafeName $name).json"
    $rows.Add((Capture-Source -Name $name -Uri ([uri]$url) -TargetPath (Join-Path $outputRoot $fileName)))
}

$clusterRow = @($rows | Where-Object { $_.name -eq 'metatft-latest-cluster-info' })[0]
$clusterJson = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $outputRoot $clusterRow.file) | ConvertFrom-Json
$capturedCluster = $clusterJson.cluster_info
if ([int]$capturedCluster.cluster_id -ne $clusterId -or [string]$capturedCluster.tft_set -ne $setId) {
    throw "SOURCE_SNAPSHOT_CLUSTER_DRIFT dryRun=$setId/$clusterId captured=$($capturedCluster.tft_set)/$($capturedCluster.cluster_id)"
}

$manifest = [pscustomobject][ordered]@{
    schemaVersion = 1
    setId = $setId
    clusterId = $clusterId
    capturedAtUtc = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    filter = [ordered]@{
        queue = 'RANKED'
        rank = 'PLATINUM_PLUS'
        patch = 'CURRENT'
        days = 3
        permitFilterAdjustment = $false
    }
    compositionIds = @($compositionIds)
    sources = @($rows.ToArray())
}
$manifestPath = Join-Path $outputRoot 'source-snapshot-manifest.json'
[IO.File]::WriteAllText($manifestPath, (($manifest | ConvertTo-Json -Depth 20).Replace("`r`n","`n") + "`n"), [Text.UTF8Encoding]::new($false))
Write-Output "Captured canonical source snapshots: Set=$setId Cluster=$clusterId Compositions=$($compositionIds.Count) Sources=$($rows.Count) Manifest=$manifestPath"
