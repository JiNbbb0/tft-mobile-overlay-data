$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('tft-typed-display-catalog-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
try {
    $fixturePath = Join-Path $tempRoot 'refresh-catalog.ps1'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'refresh-catalog.ps1') -Destination $fixturePath -Force

    # Match production patch order: current-set universe first, typed display
    # resolver second. Both injectors must remain compatible and idempotent.
    & (Join-Path $PSScriptRoot 'enable-current-set-catalog-universe.ps1') -CatalogScriptPath $fixturePath
    & (Join-Path $PSScriptRoot 'enable-typed-display-catalog.ps1') -CatalogScriptPath $fixturePath

    $patched = [IO.File]::ReadAllText($fixturePath).Replace("`r`n", "`n")
    foreach ($required in @(
        "normalize/Resolve-TftDisplayValue.ps1",
        '# CANONICAL_V2_TYPED_DISPLAY_BEGIN',
        'Resolve-TftLocalizedDescription',
        'Get-TftDynamicTokenKind',
        '# CANONICAL_V2_DISPLAY_TOKEN_GATE',
        'CATALOG_UNRESOLVED_DISPLAY_TOKENS',
        '$CanonicalDisplayUnresolved.Add',
        "'[データ未取得]'"
    )) {
        if (-not $patched.Contains($required)) { throw "Typed display production integration missing: $required" }
    }
    foreach ($forbidden in @(
        "return '可変値'",
        "return '戦闘中の値'",
        "'戦闘中に変動'",
        "'特殊効果'"
    )) {
        if ($patched.Contains($forbidden)) { throw "Legacy display placeholder survived production patch: $forbidden" }
    }

    # [データ未取得] may exist only as the transient sentinel immediately
    # before the fail-closed unresolved-token gate. It must never be treated as
    # a valid fallback value in Normalize-Text.
    if (-not $patched.Contains('throw "CATALOG_UNRESOLVED_DISPLAY_TOKENS')) {
        throw 'Transient unresolved display sentinel is not guarded by a fail-closed gate.'
    }

    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($fixturePath, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) {
        throw "Typed display production patch has parser errors: $(@($errors | ForEach-Object Message) -join '; ')"
    }

    $firstHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fixturePath).Hash
    & (Join-Path $PSScriptRoot 'enable-typed-display-catalog.ps1') -CatalogScriptPath $fixturePath
    $secondHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fixturePath).Hash
    if ($firstHash -ne $secondHash) { throw 'Typed display catalog injector is not idempotent.' }

    Write-Output 'Typed display production catalog integration regression passed.'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
