Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Format-TftCanonicalNumber {
    param([Parameter(Mandatory = $true)][double]$Value)
    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) {
        throw "Non-finite TFT numeric value: $Value"
    }
    $rounded = [Math]::Round($Value, 4)
    if ([Math]::Abs($rounded - [Math]::Round($rounded)) -lt 0.0001) {
        return ([int64][Math]::Round($rounded)).ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    return $rounded.ToString('0.####', [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-TftDisplayNumber {
    param(
        [Parameter(Mandatory = $true)][double]$RawValue,
        [ValidateSet('flat','percentFraction','percentPoints','seconds','mana','attackSpeed','range','unknown')]
        [string]$Unit = 'flat'
    )

    switch ($Unit) {
        'percentFraction' { return "$(Format-TftCanonicalNumber -Value ($RawValue * 100.0))%" }
        'percentPoints'   { return "$(Format-TftCanonicalNumber -Value $RawValue)%" }
        'seconds'         { return "$(Format-TftCanonicalNumber -Value $RawValue)秒" }
        'mana'            { return Format-TftCanonicalNumber -Value $RawValue }
        'attackSpeed'     { return Format-TftCanonicalNumber -Value $RawValue }
        'range'           { return Format-TftCanonicalNumber -Value $RawValue }
        default           { return Format-TftCanonicalNumber -Value $RawValue }
    }
}

function Get-TftDynamicTokenKind {
    param([AllowNull()][string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }
    $value = $Token.ToLowerInvariant()
    if ($value -match 'tftunitproperty|current|stage|stack|stacks|combat|missinghealth|targetcount|numtargets|round|elapsed') {
        return 'COMBAT_STATE'
    }
    return $null
}

function Resolve-TftTokenValue {
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [hashtable]$Values = @{},
        [hashtable]$Units = @{}
    )

    $baseToken = $Token
    $multiplier = 1.0
    if ($Token -match '^(.+?)\*([0-9.]+)$') {
        $baseToken = [string]$Matches[1]
        $multiplier = [double]$Matches[2]
    }

    $lookup = @($Values.Keys | Where-Object { [string]$_ -ieq $baseToken } | Select-Object -First 1)
    if ($lookup.Count -gt 0) {
        $key = [string]$lookup[0]
        $rawValues = @($Values[$key])
        if ($rawValues.Count -eq 0) {
            return [pscustomobject][ordered]@{
                status = 'UNRESOLVED'
                token = $Token
                reason = 'EMPTY_VALUE_ARRAY'
                display = $null
                values = @()
            }
        }

        $unit = 'flat'
        $unitKey = @($Units.Keys | Where-Object { [string]$_ -ieq $baseToken } | Select-Object -First 1)
        if ($unitKey.Count -gt 0) { $unit = [string]$Units[[string]$unitKey[0]] }

        $formatted = @(
            foreach ($raw in $rawValues) {
                if ($null -eq $raw -or $raw -is [string]) {
                    throw "Token $baseToken has a non-numeric value."
                }
                ConvertTo-TftDisplayNumber -RawValue ([double]$raw * $multiplier) -Unit $unit
            }
        )
        $display = if (@($formatted | Select-Object -Unique).Count -eq 1) { [string]$formatted[0] } else { $formatted -join '/' }
        return [pscustomobject][ordered]@{
            status = 'STATIC'
            token = $Token
            reason = ''
            display = $display
            values = @($rawValues)
            unit = $unit
        }
    }

    $dynamicKind = Get-TftDynamicTokenKind -Token $baseToken
    if ($dynamicKind) {
        return [pscustomobject][ordered]@{
            status = 'DYNAMIC'
            token = $Token
            reason = $dynamicKind
            display = '戦闘中の状態に応じて変化'
            values = @()
            unit = 'dynamic'
        }
    }

    return [pscustomobject][ordered]@{
        status = 'UNRESOLVED'
        token = $Token
        reason = 'NO_SOURCE_VALUE'
        display = $null
        values = @()
        unit = 'unknown'
    }
}

function Resolve-TftLocalizedDescription {
    param(
        [AllowNull()][string]$Text,
        [hashtable]$Values = @{},
        [hashtable]$Units = @{},
        [hashtable]$KeywordMap = @{}
    )

    if ($null -eq $Text) {
        return [pscustomobject][ordered]@{
            text = ''
            status = 'STATIC'
            unresolvedTokens = @()
            dynamicTokens = @()
            resolvedTokens = @()
        }
    }

    $output = [string]$Text
    $unresolved = [Collections.Generic.List[string]]::new()
    $dynamic = [Collections.Generic.List[string]]::new()
    $resolved = [Collections.Generic.List[string]]::new()

    foreach ($match in @([regex]::Matches($output, '@([^@\r\n]+)@'))) {
        $token = [string]$match.Groups[1].Value
        $result = Resolve-TftTokenValue -Token $token -Values $Values -Units $Units
        switch ([string]$result.status) {
            'STATIC' {
                $output = $output.Replace([string]$match.Value, [string]$result.display)
                $resolved.Add($token)
            }
            'DYNAMIC' {
                $output = $output.Replace([string]$match.Value, [string]$result.display)
                $dynamic.Add($token)
            }
            default {
                $output = $output.Replace([string]$match.Value, '[データ未取得]')
                $unresolved.Add($token)
            }
        }
    }

    foreach ($match in @([regex]::Matches($output, '\{\{([^}\r\n]+)\}\}'))) {
        $token = [string]$match.Groups[1].Value
        $lookup = @($KeywordMap.Keys | Where-Object { [string]$_ -ieq $token } | Select-Object -First 1)
        if ($lookup.Count -gt 0) {
            $output = $output.Replace([string]$match.Value, [string]$KeywordMap[[string]$lookup[0]])
            $resolved.Add($token)
        } else {
            $output = $output.Replace([string]$match.Value, '[データ未取得]')
            $unresolved.Add($token)
        }
    }

    $output = $output -replace '(?i)<br\s*/?>', "`n"
    $output = $output -replace '<[^>]+>', ''
    $output = [Net.WebUtility]::HtmlDecode($output)
    $output = (($output -replace '[ \t]+', ' ') -replace "(`r?`n){3,}", "`n`n").Trim()

    $status = if ($unresolved.Count -gt 0) { 'UNRESOLVED' } elseif ($dynamic.Count -gt 0) { 'DYNAMIC' } else { 'STATIC' }
    return [pscustomobject][ordered]@{
        text = $output
        status = $status
        unresolvedTokens = @($unresolved | Select-Object -Unique)
        dynamicTokens = @($dynamic | Select-Object -Unique)
        resolvedTokens = @($resolved | Select-Object -Unique)
    }
}
