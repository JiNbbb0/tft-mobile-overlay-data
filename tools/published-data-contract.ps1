# Resolve status inputs from the immutable bundle selected by data-index.
# source/current is a generation workspace, never the authority for published status.
function Convert-TftUtcTimestamp($Value) {
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Get-TftPublishedDataInputs([string]$SiteRoot) {
    $SiteRoot = [IO.Path]::GetFullPath($SiteRoot)
    $index = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $SiteRoot 'data-index.json') | ConvertFrom-Json
    $availableId = if ($index.PSObject.Properties['latestAvailableVersionId']) { [string]$index.latestAvailableVersionId } else { [string]$index.latestVersionId }
    $versions = @($index.versions | Where-Object { [string]$_.id -ceq $availableId })
    if ($versions.Count -ne 1 -or $availableId -notmatch '^[a-z0-9._-]+$') { throw 'Published available identity is missing, duplicated, or unsafe.' }
    $version = $versions[0]
    if ([string]$version.manifestUrl -cne "bundles/$availableId/manifest.json") { throw 'Published manifest URL differs from bundle identity.' }
    $manifestPath = Join-Path $SiteRoot ([string]$version.manifestUrl)
    $manifestSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant()
    if ([string]$version.manifestSha256 -cne $manifestSha) { throw 'Published manifest SHA-256 mismatch.' }
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
    foreach ($field in @('id','setId','patch','revision')) {
        if ([string]$manifest.$field -cne [string]$version.$field) { throw "Published manifest/index identity mismatch: $field" }
    }
    $bundleRoot = Split-Path -Parent $manifestPath
    $payloads = @{}
    foreach ($logicalPath in @('tft/tft_catalog.json','tft_static_snapshot.json')) {
        $entries = @($manifest.files | Where-Object { [string]$_.path -ceq $logicalPath })
        if ($entries.Count -ne 1) { throw "Published required payload is missing or duplicated: $logicalPath" }
        $entry = $entries[0]
        $url = [string]$entry.url
        if ($url -cnotmatch '^files/[a-z0-9._/-]+\.json$' -or @($url.Split('/') | Where-Object { $_ -in @('','.', '..') }).Count) { throw 'Unsafe published payload URL.' }
        $path = [IO.Path]::GetFullPath((Join-Path $bundleRoot $url))
        if (-not $path.StartsWith($bundleRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)) { throw 'Published payload escaped bundle.' }
        $file = Get-Item -LiteralPath $path
        if ($file.Length -ne [int64]$entry.bytes -or $file.Length -lt 1 -or $file.Length -gt 30MB) { throw 'Published payload size mismatch.' }
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
        if ($hash -cne [string]$entry.sha256) { throw "Published payload SHA-256 mismatch: $logicalPath" }
        $payloads[$logicalPath] = [pscustomobject]@{ path=$path; sha256=$hash; data=(Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json) }
    }
    $catalog = $payloads['tft/tft_catalog.json'].data
    $snapshot = $payloads['tft_static_snapshot.json'].data
    if ([string]$catalog.set.id -cne [string]$version.setId -or [string]$catalog.set.tftPatch -cne [string]$version.patch -or
        [string]$snapshot.setId -cne [string]$version.setId -or [string]$snapshot.clusterId -cne [string]$version.revision) {
        throw 'Published catalog/snapshot/version identity mismatch.'
    }
    if ($snapshot.PSObject.Properties['compositionRanks']) {
        foreach ($field in @('setId','patch','revision')) {
            if ([string]$snapshot.compositionRanks.$field -cne [string]$version.$field) { throw "Published rank identity mismatch: $field" }
        }
    }
    return [pscustomobject]@{ index=$index; version=$version; catalog=$catalog; snapshot=$snapshot; payloads=$payloads }
}
