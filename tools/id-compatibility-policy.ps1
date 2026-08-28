$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function ConvertTo-TftLooseIdKey {
    param([AllowNull()][string]$Id)

    if ([string]::IsNullOrWhiteSpace($Id)) { return '' }
    $value = $Id.Trim()
    $value = $value -replace '^(?i:(?:TFT\d+_Item_|TFT_Item_|DA_))', ''
    $value = $value -replace '[^A-Za-z0-9]', ''
    return $value.ToLowerInvariant()
}

function ConvertTo-TftNameKey {
    param([AllowNull()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $value = $Name.Normalize([Text.NormalizationForm]::FormKC).Trim().ToLowerInvariant()
    $value = $value -replace '[^\p{L}\p{Nd}]', ''
    return $value
}

function Add-TftIndexValue {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Index,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Id
    )

    if (-not $Key) { return }
    if (-not $Index.ContainsKey($Key)) {
        $Index[$Key] = [Collections.Generic.List[string]]::new()
    }
    if (-not $Index[$Key].Contains($Id)) {
        $Index[$Key].Add($Id)
    }
}

function New-TftCanonicalIdIndex {
    param(
        [Parameter(Mandatory = $true)][object[]]$Entries,
        [string[]]$NameProperties = @('nameJa', 'nameEn', 'name')
    )

    $exact = @{}
    $byLooseKey = @{}
    $byName = @{}

    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) { continue }
        $idProperty = $entry.PSObject.Properties['id']
        if (-not $idProperty) { $idProperty = $entry.PSObject.Properties['apiName'] }
        if (-not $idProperty) { continue }
        $id = [string]$idProperty.Value
        if (-not $id) { continue }
        if ($exact.ContainsKey($id)) { throw "Duplicate canonical TFT id: $id" }
        $exact[$id] = $id
        Add-TftIndexValue -Index $byLooseKey -Key (ConvertTo-TftLooseIdKey -Id $id) -Id $id

        foreach ($propertyName in $NameProperties) {
            $property = $entry.PSObject.Properties[$propertyName]
            if (-not $property) { continue }
            $nameKey = ConvertTo-TftNameKey -Name ([string]$property.Value)
            Add-TftIndexValue -Index $byName -Key $nameKey -Id $id
        }
    }

    return [pscustomobject][ordered]@{
        exact = $exact
        byLooseKey = $byLooseKey
        byName = $byName
    }
}

function Resolve-TftCanonicalId {
    param(
        [Parameter(Mandatory = $true)]$Index,
        [AllowNull()][string]$SourceId,
        [AllowNull()][string]$SourceName = ''
    )

    if ($SourceId -and $Index.exact.ContainsKey($SourceId)) {
        return [pscustomobject][ordered]@{
            status = 'EXACT'
            canonicalId = [string]$SourceId
            candidates = @([string]$SourceId)
        }
    }

    $looseKey = ConvertTo-TftLooseIdKey -Id $SourceId
    $looseCandidates = if ($looseKey -and $Index.byLooseKey.ContainsKey($looseKey)) {
        @($Index.byLooseKey[$looseKey])
    } else { @() }
    if ($looseCandidates.Count -eq 1) {
        return [pscustomobject][ordered]@{
            status = 'ALIAS'
            canonicalId = [string]$looseCandidates[0]
            candidates = @($looseCandidates)
        }
    }

    $nameKey = ConvertTo-TftNameKey -Name $SourceName
    $nameCandidates = if ($nameKey -and $Index.byName.ContainsKey($nameKey)) {
        @($Index.byName[$nameKey])
    } else { @() }
    if ($nameCandidates.Count -eq 1) {
        if ($looseCandidates.Count -eq 0 -or $looseCandidates -contains [string]$nameCandidates[0]) {
            return [pscustomobject][ordered]@{
                status = 'NAME'
                canonicalId = [string]$nameCandidates[0]
                candidates = @($nameCandidates)
            }
        }
    }

    $ambiguous = @($looseCandidates + $nameCandidates | Sort-Object -Unique)
    if ($ambiguous.Count -gt 1) {
        return [pscustomobject][ordered]@{
            status = 'AMBIGUOUS'
            canonicalId = ''
            candidates = @($ambiguous)
        }
    }

    return [pscustomobject][ordered]@{
        status = 'UNRESOLVED'
        canonicalId = ''
        candidates = @()
    }
}
