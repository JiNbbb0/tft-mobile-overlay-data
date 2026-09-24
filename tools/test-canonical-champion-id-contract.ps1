$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'metatft/canonical-champion-id-contract.ps1')

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ([string]$Expected -cne [string]$Actual) { throw "$Message Expected=$Expected Actual=$Actual" }
}

$canonical = @{
    'DA_Lux18_Base' = [pscustomobject]@{ id='DA_Lux18_Base' }
    'DA_18_Ornn' = [pscustomobject]@{ id='DA_18_Ornn' }
}
$lookupUnits = @(
    [pscustomobject]@{
        apiName='TFT18_Lux_Base'
        assetNames=@('DA_Lux18_Base','DA_Lux18_Blackthorn','DA_Lux18_Blossom')
    },
    [pscustomobject]@{
        apiName='DA_Ornn18_Base'
        assetNames=@('DA_18_Ornn','DA_Ornn18_Base')
    },
    [pscustomobject]@{
        apiName='TFT18_Ambiguous'
        assetNames=@('DA_Lux18_Base','DA_18_Ornn','DA_AmbiguousVariant')
    }
)

$index = New-MetaTftCanonicalChampionAliasIndex -CanonicalChampionIds $canonical -MetaTftUnits $lookupUnits
Assert-Equal 'DA_Lux18_Base' (Resolve-MetaTftCanonicalChampionId -SourceId 'DA_Lux18_Blackthorn' -CanonicalChampionIds $canonical -Aliases $index.aliases) 'MetaTFT explicit variant asset should resolve to its listed canonical champion.'
Assert-Equal 'DA_Lux18_Base' (Resolve-MetaTftCanonicalChampionId -SourceId 'TFT18_Lux_Base' -CanonicalChampionIds $canonical -Aliases $index.aliases) 'MetaTFT unit apiName should resolve only when its asset list identifies one canonical champion.'
Assert-Equal 'DA_18_Ornn' (Resolve-MetaTftCanonicalChampionId -SourceId 'DA_Ornn18_Base' -CanonicalChampionIds $canonical -Aliases $index.aliases) 'An explicit alternate source asset should resolve to its listed canonical champion.'
Assert-Equal 'DA_Lux18_Base' (Resolve-MetaTftCanonicalChampionId -SourceId 'DA_Lux18_Base' -CanonicalChampionIds $canonical -Aliases $index.aliases) 'Canonical identity should win over alias matching.'
Assert-Equal 1 @($index.ambiguousIds | Where-Object { $_ -eq 'DA_AmbiguousVariant' }).Count 'A lookup row that points at multiple canonical champions must not create aliases.'

$rejected = $false
try {
    Resolve-MetaTftCanonicalChampionId -SourceId 'DA_UnknownFutureVariant' -CanonicalChampionIds $canonical -Aliases $index.aliases | Out-Null
} catch {
    $rejected = $_.Exception.Message -like 'UNRESOLVED_CANONICAL_CHAMPION_ID*'
}
Assert-Equal $true $rejected 'An unlisted source ID must fail closed rather than be guessed by name.'

Write-Output 'Canonical champion identity and exact MetaTFT asset aliases passed.'
