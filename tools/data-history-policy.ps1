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

    if ($null -ne $Index -and $Index.PSObject.Properties['latestVersionId']) {
        $latestVersionId = [string]$Index.latestVersionId
        $declaredLatest = @($allVersions | Where-Object { [string]$_.id -eq $latestVersionId }) | Select-Object -First 1
        if ($declaredLatest) { return $declaredLatest }
        throw "data-index latestVersionId is missing from versions: $latestVersionId"
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
