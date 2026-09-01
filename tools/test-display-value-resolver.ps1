$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'normalize/Resolve-TftDisplayValue.ps1')

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ([string]$Actual -ne [string]$Expected) {
        throw "$Message. Expected=$Expected Actual=$Actual"
    }
}

$values = @{
    Damage = @(100, 150, 225)
    HealThreshold = @(0.5)
    Duration = @(1.5)
}
$units = @{
    HealThreshold = 'percentFraction'
    Duration = 'seconds'
}

$static = Resolve-TftLocalizedDescription -Text 'ダメージ:@Damage@ / 閾値:@HealThreshold@ / @Duration@' -Values $values -Units $units
Assert-Equal $static.status 'STATIC' 'Static description should fully resolve'
Assert-Equal $static.text 'ダメージ:100/150/225 / 閾値:50% / 1.5秒' 'Static description formatting differs'

$dynamic = Resolve-TftLocalizedDescription -Text '現在値:@TFTUnitProperty_CurrentStacks@' -Values @{}
Assert-Equal $dynamic.status 'DYNAMIC' 'Combat-state token should be classified as dynamic'
if ($dynamic.text -match '可変値|任意の|@') { throw 'Dynamic output leaked a pseudo/raw token.' }

$unresolved = Resolve-TftLocalizedDescription -Text '未知:@CompletelyNewToken@' -Values @{}
Assert-Equal $unresolved.status 'UNRESOLVED' 'Unknown token should fail closed'
Assert-Equal $unresolved.text '未知:[データ未取得]' 'Unknown token must not become a fabricated numeric phrase'

$keyword = Resolve-TftLocalizedDescription -Text '{{TFT_Keyword_Chill}}を付与' -KeywordMap @{ TFT_Keyword_Chill = '冷気' }
Assert-Equal $keyword.status 'STATIC' 'Known keyword should resolve'
Assert-Equal $keyword.text '冷気を付与' 'Known keyword replacement differs'

Assert-Equal (ConvertTo-TftDisplayNumber -RawValue 0.5 -Unit percentFraction) '50%' 'Percent fraction formatting failed'
Assert-Equal (ConvertTo-TftDisplayNumber -RawValue 50 -Unit percentPoints) '50%' 'Percent point formatting failed'
Assert-Equal (ConvertTo-TftDisplayNumber -RawValue 0.5 -Unit seconds) '0.5秒' 'Seconds formatting failed'

Write-Output 'Typed TFT display value resolver tests passed.'
