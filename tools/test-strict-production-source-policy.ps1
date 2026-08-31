$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('tft-strict-source-policy-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
try {
    $fixturePath = Join-Path $tempRoot 'refresh-static-meta.ps1'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'refresh-static-meta.ps1') -Destination $fixturePath -Force

    & (Join-Path $PSScriptRoot 'enable-strict-production-source-policy.ps1') -StaticMetaPath $fixturePath
    $patched = [IO.File]::ReadAllText($fixturePath).Replace("`r`n", "`n")

    foreach ($forbidden in @(
        '$fallbackCompsStatsUrl =',
        'ALL_RANKS_FALLBACK comps_stats',
        'Derived from adjacent MetaTFT public boards',
        '$fallback = 0..27',
        'permit_filter_adjustment=true'
    )) {
        if ($patched.Contains($forbidden)) { throw "Forbidden production source behavior survived: $forbidden" }
    }
    foreach ($required in @(
        '# CANONICAL_V2_STRICT_RANK_SCOPE_BEGIN',
        '-FallbackStats $null',
        'CANONICAL_RANK_SCOPE_WIDENING_REFUSED',
        'permit_filter_adjustment=false',
        'METATFT_BOARD_POSITION_UNAVAILABLE',
        'Missing level boards remain missing; adjacent-level synthesis is forbidden.',
        'synthetic = $false'
    )) {
        if (-not $patched.Contains($required)) { throw "Strict production source behavior missing: $required" }
    }

    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($fixturePath, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) {
        throw "Patched production source script has PowerShell parser errors: $(@($errors | ForEach-Object Message) -join '; ')"
    }

    $firstHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fixturePath).Hash
    & (Join-Path $PSScriptRoot 'enable-strict-production-source-policy.ps1') -StaticMetaPath $fixturePath
    $secondHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fixturePath).Hash
    if ($firstHash -ne $secondHash) { throw 'Strict production source-policy injector is not idempotent.' }

    Write-Output 'Strict production MetaTFT source-policy regression passed.'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
