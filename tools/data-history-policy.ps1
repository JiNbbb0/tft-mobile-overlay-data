Set-StrictMode -Version Latest

function ConvertTo-DataUtcTimestamp {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return "" }
    if ($Value -is [DateTimeOffset]) {
        return $Value.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ", [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [DateTime]) {
        $dateTime = [DateTime]$Value
        if ($dateTime.Kind -eq [DateTimeKind]::Unspecified) {
            $dateTime = [DateTime]::SpecifyKind($dateTime, [DateTimeKind]::Utc)
        }
        return $dateTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", [Globalization.CultureInfo]::InvariantCulture)
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return "" }
    $parsed = [DateTimeOffset]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if (-not [DateTimeOffset]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        throw "Invalid data history timestamp: $text"
    }
    return $parsed.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ", [Globalization.CultureInfo]::InvariantCulture)
}

function Normalize-DataVersionTimestamps {
    param([object[]]$Versions)

    foreach ($version in @($Versions)) {
        foreach ($propertyName in @('generatedAtUtc', 'sourceTimestampUtc')) {
            if ($version.PSObject.Properties[$propertyName]) {
                $normalized = ConvertTo-DataUtcTimestamp $version.PSObject.Properties[$propertyName].Value
                $version | Add-Member -NotePropertyName $propertyName -NotePropertyValue $normalized -Force
            }
        }
    }
    return @($Versions)
}

function Get-PreviousDataVersion {
    param(
        [AllowNull()][object]$Index,
        [object[]]$Versions
    )

    $allVersions = @($Versions)
    if ($allVersions.Count -eq 0) { return $null }

    if ($null -ne $Index -and ($Index.PSObject.Properties['latestAvailableVersionId'] -or $Index.PSObject.Properties['latestVersionId'])) {
        # Publication identity always follows the newest atomically usable
        # bundle. latestVersionId is the legacy stable alias in the ideal
        # contract and must not make a partial -> partial transition compare
        # against an older stable bundle.
        $latestVersionId = if ($Index.PSObject.Properties['latestAvailableVersionId']) {
            [string]$Index.latestAvailableVersionId
        } else {
            [string]$Index.latestVersionId
        }
        $declaredLatest = @($allVersions | Where-Object { [string]$_.id -eq $latestVersionId }) | Select-Object -First 1
        if ($declaredLatest) { return $declaredLatest }
        throw "data-index latest available version is missing from versions: $latestVersionId"
    }

    return @($allVersions | Sort-Object { ConvertTo-DataUtcTimestamp $_.generatedAtUtc } -Descending) | Select-Object -First 1
}

function Resolve-DataPublicationIdentity {
    param(
        [AllowNull()][object]$Previous,
        [Parameter(Mandatory = $true)][string]$SetId,
        [Parameter(Mandatory = $true)][string]$Patch,
        [Parameter(Mandatory = $true)][string]$Revision,
        [Parameter(Mandatory = $true)][string]$MetaFingerprint,
        [Parameter(Mandatory = $true)][string]$BaseVersionId
    )

    $previousFingerprint = if ($Previous -and $Previous.PSObject.Properties['metaFingerprint']) {
        [string]$Previous.metaFingerprint
    } else { "" }
    $sameContent = $Previous -and
        [string]$Previous.setId -eq $SetId -and
        [string]$Previous.patch -eq $Patch -and
        [string]$Previous.revision -eq $Revision -and
        $previousFingerprint -eq $MetaFingerprint
    if ($sameContent) {
        return [pscustomobject][ordered]@{
            updateKind = [string]$Previous.updateKind
            versionId = [string]$Previous.id
            samePublishedContent = $true
        }
    }

    $kind = if (-not $Previous -or [string]$Previous.setId -ne $SetId) {
        'NEW_SET'
    } elseif ([string]$Previous.patch -eq $Patch -and [string]$Previous.revision -ne $Revision) {
        'B_PATCH'
    } elseif ([string]$Previous.patch -eq $Patch -and [string]$Previous.revision -eq $Revision -and $previousFingerprint -ne $MetaFingerprint) {
        'META_UPDATE'
    } else {
        'PATCH'
    }
    $id = if ($kind -eq 'META_UPDATE') { "$BaseVersionId-m$($MetaFingerprint.Substring(0, 10))" } else { $BaseVersionId }
    return [pscustomobject][ordered]@{
        updateKind = $kind
        versionId = $id
        samePublishedContent = $false
    }
}

function Select-ActiveDataHistory {
    param(
        [Parameter(Mandatory = $true)][object[]]$Versions,
        [Parameter(Mandatory = $true)][string]$LatestVersionId,
        [string[]]$ProtectedVersionIds = @(),
        [int]$MaxActiveVersions = 20,
        [int]$MaxRecentMetaUpdates = 5
    )

    if ($MaxActiveVersions -lt 2) { throw "MaxActiveVersions must be at least 2" }
    if ($MaxRecentMetaUpdates -lt 1 -or $MaxRecentMetaUpdates -ge $MaxActiveVersions) {
        throw "MaxRecentMetaUpdates must be inside 1..MaxActiveVersions-1"
    }

    $ordered = @($Versions | Sort-Object { ConvertTo-DataUtcTimestamp $_.generatedAtUtc } -Descending)
    $latest = @($ordered | Where-Object { [string]$_.id -eq $LatestVersionId }) | Select-Object -First 1
    if (-not $latest) { throw "Latest version is missing before retention: $LatestVersionId" }

    $keep = [ordered]@{}
    $keep[[string]$latest.id] = $latest

    # The formal stable LKG may be older than the newest catalog-first bundle.
    # It must survive the rolling META_UPDATE window until a newer stable
    # bundle is fully validated.
    foreach ($protectedId in @($ProtectedVersionIds | Where-Object { $_ })) {
        $protected = @($ordered | Where-Object { [string]$_.id -eq [string]$protectedId }) | Select-Object -First 1
        if (-not $protected) { throw "Protected history version is missing: $protectedId" }
        $keep[[string]$protected.id] = $protected
    }

    # Frequent META_UPDATE snapshots are a rolling live window. Their immutable
    # IDs remain cache-safe while the public site stays bounded.
    @($ordered | Where-Object { [string]$_.updateKind -eq 'META_UPDATE' } | Select-Object -First $MaxRecentMetaUpdates) |
        ForEach-Object { $keep[[string]$_.id] = $_ }

    # NEW_SET/PATCH/B_PATCH records are recovery anchors. Keep the newest ones
    # that fit in the active window; older anchors remain recoverable from Git.
    foreach ($anchor in @($ordered | Where-Object { [string]$_.updateKind -ne 'META_UPDATE' })) {
        if ($keep.Count -ge $MaxActiveVersions) { break }
        $keep[[string]$anchor.id] = $anchor
    }

    $retained = @($keep.Values | Sort-Object { ConvertTo-DataUtcTimestamp $_.generatedAtUtc } -Descending)
    $archived = @($ordered | Where-Object { -not $keep.Contains([string]$_.id) })
    return [pscustomobject][ordered]@{
        retained = $retained
        archived = $archived
    }
}
