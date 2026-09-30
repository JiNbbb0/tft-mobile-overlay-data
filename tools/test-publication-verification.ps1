$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
foreach ($workflow in @('refresh-tft-data.yml','deploy-pages.yml','rollback-latest.yml','automation-watchdog.yml')) {
    $text = Get-Content -Raw -LiteralPath (Join-Path $root ".github/workflows/$workflow")
    if ($text -notmatch 'run: ./tools/verify-publication.ps1 -DataIndexUrl \$env:DATA_INDEX_URL') { throw "Shared remote contract missing: $workflow" }
}
$rollback = Get-Content -Raw -LiteralPath (Join-Path $root '.github/workflows/rollback-latest.yml')
if ($rollback -notmatch 'git add site/data-index.json site/health.json site/data-quality.json' -or
    $rollback -notmatch 'VersionId \$env:RESTORE_VERSION') { throw 'Rollback must persist matching quality and pass input as data, not executable code.' }

# Isolated mocks exercise the actual shared entrypoint without network retries.
$fixture = Join-Path $root ('build/verification-test-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
try {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'verify-publication.ps1') -Destination $fixture
    foreach ($name in @('validate-remote-site.ps1','reconcile-publication.ps1')) {
        [IO.File]::WriteAllText((Join-Path $fixture $name), 'param($DataIndexUrl,$SiteDirectory,[switch]$FailWhenOutOfSync)')
    }
    foreach ($reason in @('OK','DEGRADED_OPTIONAL_USABLE','CATALOG_ONLY_WITHIN_GRACE','QUALITY_STATUS_OUT_OF_SYNC','QUALITY_STATUS_UNAVAILABLE_OR_INVALID')) {
        [IO.File]::WriteAllText((Join-Path $fixture 'check-public-data-quality.ps1'), "param(`$DataIndexUrl,[switch]`$ReturnResult) [pscustomobject]@{ reason='$reason' }")
        $rejected=$false
        try { & (Join-Path $fixture 'verify-publication.ps1') -DataIndexUrl 'https://fixture.invalid/data-index.json' -Attempts 1 | Out-Null } catch { $rejected=$true }
        if ($rejected -ne ($reason -like 'QUALITY_STATUS_*')) { throw "Publication returned false result: $reason" }
    }
} finally { Remove-Item -LiteralPath $fixture -Recurse -Force }
Write-Output 'Publication verification PASS: four workflows share gates; bad quality fails; honest collecting remains publishable.'
