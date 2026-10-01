$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# These deterministic regressions protect changes to the generator and
# workflows. Live refreshes validate their actual candidate instead of
# rebuilding the same synthetic fixtures every 15 minutes.
$tests = @(
    'test-composition-condition-contract.ps1',
    'test-reference-table-contract.ps1',
    'test-reference-transport.ps1',
    'test-wisp-strength-contract.ps1',
    'test-board-star-policy.ps1',
    'test-metatft-board-contract.ps1',
    'test-published-data-contract.ps1',
    'test-publication-verification.ps1',
    'test-catalog-image-policy.ps1',
    'test-content-fingerprint.ps1',
    'test-material-publication-policy.ps1',
    'test-release-contract-policy.ps1',
    'test-source-contract.ps1',
    'test-current-set-champion-membership.ps1',
    'test-canonical-champion-id-contract.ps1',
    'test-current-set-name-policy.ps1',
    'test-current-set-universe.ps1',
    'test-emblem-mapping.ps1',
    'test-source-backed-artifact-description.ps1',
    'test-id-compatibility-policy.ps1',
    'test-rank-scope-policy.ps1',
    'test-composition-ranks.ps1',
    'test-metatft-page-parity-policy.ps1',
    'test-metatft-item-ranking-policy.ps1',
    'test-catalog-statistics-contract.ps1',
    'test-patch-detection-policy.ps1',
    'test-data-history-policy.ps1',
    'test-composition-report.ps1',
    'test-publication-state.ps1',
    'test-autonomous-recovery.ps1',
    'test-workflow-concurrency-policy.ps1',
    'test-publication-retention.ps1',
    'test-watchdog-runtime.ps1',
    'test-new-set-readiness.ps1'
)

foreach ($test in $tests) {
    $path = Join-Path $PSScriptRoot $test
    Write-Output "Running $test"
    & $path
    if (-not $?) { throw "$test exited unsuccessfully" }
}

Write-Output "Refresh contract regression PASS: $($tests.Count) tests"
