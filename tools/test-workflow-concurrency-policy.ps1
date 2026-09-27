$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$refreshPath = Join-Path $repositoryRoot '.github/workflows/refresh-tft-data.yml'
$watchdogPath = Join-Path $repositoryRoot '.github/workflows/automation-watchdog.yml'
$validationPath = Join-Path $repositoryRoot '.github/workflows/validate-ranked-compositions.yml'
$contractRunnerPath = Join-Path $repositoryRoot 'tools/test-refresh-contracts.ps1'

foreach ($path in @($refreshPath, $watchdogPath, $validationPath, $contractRunnerPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Workflow concurrency fixture is missing: $path"
    }
}

$refresh = Get-Content -Raw -Encoding UTF8 -LiteralPath $refreshPath
$watchdog = Get-Content -Raw -Encoding UTF8 -LiteralPath $watchdogPath
$validation = Get-Content -Raw -Encoding UTF8 -LiteralPath $validationPath
$contractRunner = Get-Content -Raw -Encoding UTF8 -LiteralPath $contractRunnerPath

if ($refresh -notmatch '(?m)^\s{2}group:\s+tft-data-publication\s*$') {
    throw 'The refresh workflow must retain the publication lock.'
}
if ($watchdog -notmatch '(?m)^\s{2}group:\s+tft-data-watchdog\s*$') {
    throw 'The watchdog inspection workflow must use an independent concurrency group.'
}
if ($watchdog -notmatch '(?ms)^\s{2}repair-publication:.*?^\s{4}concurrency:\s*\r?\n\s{6}group:\s+tft-data-publication\s*$') {
    throw 'The watchdog repair deployment must acquire the publication lock.'
}
if ($refresh -match 'test-new-set-readiness\.ps1' -or $refresh -match 'test-refresh-contracts\.ps1') {
    throw 'Synthetic contract fixtures must not delay every scheduled live refresh.'
}
if ($validation -notmatch '(?ms)^\s{2}push:\s*\r?\n\s{4}branches:\s*\r?\n\s{6}- main' -or
    $validation -notmatch 'run: ./tools/test-refresh-contracts\.ps1' -or
    $contractRunner -notmatch "'test-new-set-readiness\.ps1'") {
    throw 'Code changes must retain the full new-set regression gate on PRs and main pushes.'
}
if ($watchdog -notmatch "(?m)^\s{4}if: github.event_name != 'workflow_run' \|\| github.event.workflow_run.conclusion != 'success'" -or
    $watchdog -notmatch "needs.inspect.outputs.publish_required == 'true' && needs.repair-publication.result == 'success'" -or
    $watchdog -notmatch "\(needs.inspect.outputs.publish_required == 'true' && needs.verify-repair.result != 'success'\)") {
    throw 'Successful refreshes and no-op watchdog checks must not launch redundant verification jobs.'
}

Write-Output 'Workflow concurrency/preflight policy passed: publication lock, change-time fixture tests, bounded watchdog jobs.'
