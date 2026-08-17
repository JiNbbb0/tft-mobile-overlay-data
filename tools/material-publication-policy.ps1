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
        publish = [bool]($Force -or $materialChanged -or $observationDue)
        materialChanged = [bool]$materialChanged
        observationDue = [bool]$observationDue
        useObservationIdentity = [bool](($Force -and -not $materialChanged) -or $observationDue)
        reason = if ($Force) { 'FORCED' } elseif ($materialChanged) { 'MATERIAL_CHANGE' } elseif ($observationDue) { 'OBSERVATION_REFRESH' } else { 'NO_CHANGE' }
        sourceAdvanced = [bool]$sourceAdvanced
        sourceAgeDeltaSeconds = [int64][Math]::Max(0, ($currentSource - $previousSource).TotalSeconds)
    }
}
