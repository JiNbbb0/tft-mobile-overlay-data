Set-StrictMode -Version Latest

function ConvertTo-PublicationTimestamp([object]$Value) {
    if ($Value -is [DateTime]) { return [DateTimeOffset]$Value.ToUniversalTime() }
    return [DateTimeOffset]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal
    ).ToUniversalTime()
}

function Resolve-MaterialPublicationDecision {
    param(
        [Parameter(Mandatory = $true)][string]$PreviousContentFingerprint,
        [Parameter(Mandatory = $true)][string]$CurrentContentFingerprint,
        [Parameter(Mandatory = $true)]$PreviousSourceTimestampUtc,
        [Parameter(Mandatory = $true)]$CurrentSourceTimestampUtc,
        [int]$ObservationIntervalHours = 6,
        [switch]$Force
    )

    if ($ObservationIntervalHours -lt 1) { throw 'ObservationIntervalHours must be positive.' }
    $previousSource = ConvertTo-PublicationTimestamp $PreviousSourceTimestampUtc
    $currentSource = ConvertTo-PublicationTimestamp $CurrentSourceTimestampUtc
    $materialChanged = $PreviousContentFingerprint -ne $CurrentContentFingerprint
    $sourceAdvanced = $currentSource -gt $previousSource
    $observationDue = -not $materialChanged -and $sourceAdvanced -and
        ($currentSource - $previousSource).TotalHours -ge $ObservationIntervalHours
    return [pscustomobject][ordered]@{
        # An immutable version represents content, not a polling observation.
        # Force may refresh mutable status metadata, but it must never create a
        # second version for identical content.
        publish = [bool]$materialChanged
        metadataRefreshDue = [bool]($Force -or $observationDue)
        materialChanged = [bool]$materialChanged
        observationDue = [bool]$observationDue
        useObservationIdentity = $false
        reason = if ($materialChanged) { 'MATERIAL_CHANGE' } elseif ($Force -or $observationDue) { 'OBSERVATION_STATUS_REFRESH' } else { 'NO_CHANGE' }
        sourceAdvanced = [bool]$sourceAdvanced
        sourceAgeDeltaSeconds = [int64][Math]::Max(0, ($currentSource - $previousSource).TotalSeconds)
    }
}
