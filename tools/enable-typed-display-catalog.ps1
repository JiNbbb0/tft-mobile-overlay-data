param(
    [string]$CatalogScriptPath = (Join-Path $PSScriptRoot 'refresh-catalog.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$resolvedPath = [IO.Path]::GetFullPath($CatalogScriptPath)
if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) { throw "Catalog script not found: $resolvedPath" }
$text = [IO.File]::ReadAllText($resolvedPath).Replace("`r`n", "`n")

$moduleAnchor = ". (Join-Path `$PSScriptRoot 'catalog-image-policy.ps1')"
$resolverModule = ". (Join-Path `$PSScriptRoot 'normalize/Resolve-TftDisplayValue.ps1')"
if (-not $text.Contains($resolverModule)) {
    if (-not $text.Contains($moduleAnchor)) { throw 'Typed display resolver module anchor missing.' }
    $text = $text.Replace($moduleAnchor, "$moduleAnchor`n$resolverModule")
}

$typedMarker = '# CANONICAL_V2_TYPED_DISPLAY_BEGIN'
if (-not $text.Contains($typedMarker)) {
    $startMarker = 'function Normalize-Text {'
    $endMarker = 'function Get-PropertyValue {'
    $start = $text.IndexOf($startMarker, [StringComparison]::Ordinal)
    $end = $text.IndexOf($endMarker, $start, [StringComparison]::Ordinal)
    if ($start -lt 0 -or $end -lt 0) { throw 'Normalize-Text replacement markers missing.' }
    $replacement = @'
# CANONICAL_V2_TYPED_DISPLAY_BEGIN
$CanonicalDisplayUnresolved = [Collections.Generic.List[string]]::new()

function Normalize-Text {
    param(
        [AllowNull()][object]$Value,
        [AllowNull()][object]$Effects
    )
    if ($null -eq $Value) { return '' }

    $values = @{}
    if ($null -ne $Effects) {
        foreach ($property in $Effects.PSObject.Properties) {
            $raw = $property.Value
            $numeric = $false
            if ($raw -is [ValueType]) {
                $numeric = $true
            } elseif ($raw -is [Array]) {
                $numeric = @($raw | Where-Object { $null -eq $_ -or $_ -is [string] -or $_ -isnot [ValueType] }).Count -eq 0
            }
            if ($numeric) { $values[[string]$property.Name] = $raw }
        }
    }

    $resolved = Resolve-TftLocalizedDescription -Text ([string]$Value) -Values $values
    foreach ($token in @($resolved.unresolvedTokens)) {
        $CanonicalDisplayUnresolved.Add([string]$token)
    }
    $output = [string]$resolved.text
    $iconLabels = [ordered]@{
        '%i:scaleAP%' = '[魔力]'
        '%i:scaleAD%' = '[攻撃力]'
        '%i:TFTBaseAD%' = '[攻撃力]'
        '%i:scaleArmor%' = '[物理防御]'
        '%i:scaleMR%' = '[魔法防御]'
        '%i:scaleHealth%' = '[体力]'
        '%i:scaleAS%' = '[攻撃速度]'
        '%i:scaleRange%' = '[射程]'
    }
    foreach ($icon in $iconLabels.Keys) { $output = $output.Replace([string]$icon, [string]$iconLabels[$icon]) }
    $output = $output -replace '(?i)%i:goldCoins%', 'ゴールド'
    $output = $output -replace '(?i)%i:[^%]+%', ''
    return (($output -replace '[ \t]+', ' ') -replace "(`r?`n){3,}", "`n`n").Trim()
}
# CANONICAL_V2_TYPED_DISPLAY_END

'@
    $text = $text.Substring(0, $start) + $replacement + $text.Substring($end)
}

$legacyAbilityFallback = @'
        } elseif ($baseToken -match '^TFTUnitProperty') {
            $replacement = '戦闘中に変動'
        } elseif ($baseToken -match '^Augmented') {
            $replacement = ''
        } else {
            # CommunityDragon can expose a new playable unit before every derived
            # tooltip value is available in the champion bin. Never invent a
            # number and never block the entire live-meta publication for it.
            $replacement = '戦闘中に変動'
        }
'@
$typedAbilityFallback = @'
        } elseif (Get-TftDynamicTokenKind -Token $baseToken) {
            $replacement = '戦闘中の状態に応じて変化'
        } elseif ($baseToken -match '^Augmented') {
            $replacement = ''
        } else {
            # Missing source values are not guessed or relabeled as dynamic.
            # Record the unresolved identity and fail the catalog before write.
            $CanonicalDisplayUnresolved.Add("ability:$([string]$Champion.apiName):$baseToken")
            $replacement = '[データ未取得]'
        }
'@
if ($text.Contains($legacyAbilityFallback)) {
    $text = $text.Replace($legacyAbilityFallback, $typedAbilityFallback)
}

$gateMarker = '# CANONICAL_V2_DISPLAY_TOKEN_GATE'
if (-not $text.Contains($gateMarker)) {
    $catalogAnchor = '$catalog = [pscustomobject][ordered]@{'
    if (-not $text.Contains($catalogAnchor)) { throw 'Catalog unresolved-token gate anchor missing.' }
    $gate = @'
# CANONICAL_V2_DISPLAY_TOKEN_GATE
$uniqueUnresolvedDisplayTokens = @($CanonicalDisplayUnresolved | Where-Object { $_ } | Sort-Object -Unique)
if ($uniqueUnresolvedDisplayTokens.Count -gt 0) {
    $sample = @($uniqueUnresolvedDisplayTokens | Select-Object -First 20) -join ','
    throw "CATALOG_UNRESOLVED_DISPLAY_TOKENS count=$($uniqueUnresolvedDisplayTokens.Count) sample=$sample"
}

'@
    $text = $text.Replace($catalogAnchor, $gate + $catalogAnchor)
}

foreach ($forbidden in @("return '可変値'", "return '戦闘中の値'", "'戦闘中に変動'", "'特殊効果'")) {
    if ($text.Contains($forbidden)) { throw "Typed display catalog postcondition failed; legacy placeholder remains: $forbidden" }
}
foreach ($required in @(
    $resolverModule,
    $typedMarker,
    'Resolve-TftLocalizedDescription',
    'Get-TftDynamicTokenKind',
    'CATALOG_UNRESOLVED_DISPLAY_TOKENS',
    $gateMarker
)) {
    if (-not $text.Contains($required)) { throw "Typed display catalog postcondition missing: $required" }
}

[IO.File]::WriteAllText($resolvedPath, $text, [Text.UTF8Encoding]::new($false))
Write-Output "Typed display catalog resolver enabled: $resolvedPath"
