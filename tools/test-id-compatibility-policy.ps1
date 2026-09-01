$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'id-compatibility-policy.ps1')

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ([string]$Actual -ne [string]$Expected) {
        throw "$Message. Expected=$Expected Actual=$Actual"
    }
}

$entries = @(
    [pscustomobject]@{ id = 'TFT_Item_ArchangelsStaff'; nameJa = 'アークエンジェル スタッフ'; nameEn = "Archangel's Staff" },
    [pscustomobject]@{ id = 'TFT_Item_GuinsoosRageblade'; nameJa = 'グインソー レイジブレード'; nameEn = "Guinsoo's Rageblade" }
)
$index = New-TftCanonicalIdIndex -Entries $entries

$exact = Resolve-TftCanonicalId -Index $index -SourceId 'TFT_Item_ArchangelsStaff'
Assert-Equal $exact.status 'EXACT' 'Exact canonical item should stay exact'
Assert-Equal $exact.canonicalId 'TFT_Item_ArchangelsStaff' 'Exact canonical item changed unexpectedly'

$daAlias = Resolve-TftCanonicalId -Index $index -SourceId 'DA_ArchangelsStaff'
Assert-Equal $daAlias.status 'ALIAS' 'DA alias should resolve through loose-key compatibility'
Assert-Equal $daAlias.canonicalId 'TFT_Item_ArchangelsStaff' 'DA alias resolved to the wrong item'

$futureSetAlias = Resolve-TftCanonicalId -Index $index -SourceId 'TFT19_Item_ArchangelsStaff'
Assert-Equal $futureSetAlias.status 'ALIAS' 'Future set-scoped item prefix should resolve without code changes'
Assert-Equal $futureSetAlias.canonicalId 'TFT_Item_ArchangelsStaff' 'Future set-scoped alias resolved incorrectly'

$caseAlias = Resolve-TftCanonicalId -Index $index -SourceId 'tft19_item_archangelsstaff'
Assert-Equal $caseAlias.canonicalId 'TFT_Item_ArchangelsStaff' 'Case differences should not break canonicalization'

$nameFallback = Resolve-TftCanonicalId -Index $index -SourceId 'UNKNOWN_PROVIDER_ID' -SourceName 'アークエンジェル スタッフ'
Assert-Equal $nameFallback.status 'NAME' 'Localized-name fallback should resolve a provider ID change'
Assert-Equal $nameFallback.canonicalId 'TFT_Item_ArchangelsStaff' 'Localized-name fallback resolved incorrectly'

$unresolved = Resolve-TftCanonicalId -Index $index -SourceId 'UNKNOWN_PROVIDER_ID' -SourceName '存在しないアイテム'
Assert-Equal $unresolved.status 'UNRESOLVED' 'Unknown items must fail closed rather than guessing'

$reusedIdEntries = @(
    [pscustomobject]@{ id = 'TFT_Item_RedBuff'; nameJa = 'サンファイア ケープ' },
    [pscustomobject]@{ id = 'TFT_Item_RapidFireCannon'; nameJa = 'レッドバフ' }
)
$reusedIdIndex = New-TftCanonicalIdIndex -Entries $reusedIdEntries
$reusedId = Resolve-TftCanonicalId -Index $reusedIdIndex -SourceId 'DA_RedBuff' -SourceName 'レッドバフ'
Assert-Equal $reusedId.status 'NAME' 'Current-set name evidence must override a conflicting historical ID suffix'
Assert-Equal $reusedId.canonicalId 'TFT_Item_RapidFireCannon' 'Reused legacy item ID resolved to the wrong current item'

$ambiguousEntries = @(
    [pscustomobject]@{ id = 'TFT_Item_TestBlade'; nameJa = 'テストブレード A' },
    [pscustomobject]@{ id = 'DA_TestBlade'; nameJa = 'テストブレード B' }
)
$ambiguousIndex = New-TftCanonicalIdIndex -Entries $ambiguousEntries
$ambiguous = Resolve-TftCanonicalId -Index $ambiguousIndex -SourceId 'TFT20_Item_TestBlade'
Assert-Equal $ambiguous.status 'AMBIGUOUS' 'Ambiguous aliases must not be auto-selected'

Write-Output 'Cross-source TFT ID compatibility policy tests passed.'
