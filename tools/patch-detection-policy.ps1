Set-StrictMode -Version Latest

function Get-TftPatchCandidates {
    param([Parameter(Mandatory = $true)][string]$Document)

    $patterns = @(
        'teamfight-tactics-patch[-\s]+(?<major>[0-9]+)[.-](?<minor>[0-9]+)',
        'Teamfight\s+Tactics\s+patch\s+(?<major>[0-9]+)\.(?<minor>[0-9]+)',
        'パッチ\s*(?<major>[0-9]+)\.(?<minor>[0-9]+)'
    )
    $found = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($pattern in $patterns) {
        foreach ($match in [regex]::Matches($Document, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            $major = [int]$match.Groups['major'].Value
            $minor = [int]$match.Groups['minor'].Value
            if ($major -le 0 -or $minor -lt 0) { continue }
            $value = "$major.$minor"
            if (-not $found.ContainsKey($value)) {
                $found[$value] = [pscustomobject][ordered]@{ value = $value; major = $major; minor = $minor }
            }
        }
    }
    return @($found.Values)
}

function Resolve-LatestTftPatch {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Documents)

    $candidates = @($Documents | ForEach-Object { Get-TftPatchCandidates -Document $_ })
    if ($candidates.Count -eq 0) { throw 'No TFT patch identifier was found in the official patch-note documents.' }
    return [string]($candidates | Sort-Object major, minor -Descending | Select-Object -First 1).value
}
