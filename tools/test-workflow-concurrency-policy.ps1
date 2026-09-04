$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$refreshPath = Join-Path $repositoryRoot '.github/workflows/refresh-tft-data.yml'
$watchdogPath = Join-Path $repositoryRoot '.github/workflows/automation-watchdog.yml'

foreach ($path in @($refreshPath, $watchdogPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Workflow concurrency fixture is missing: $path"
    }
}

$refresh = Get-Content -Raw -Encoding UTF8 -LiteralPath $refreshPath
$watchdog = Get-Content -Raw -Encoding UTF8 -LiteralPath $watchdogPath

if ($refresh -notmatch '(?m)^\s{2}group:\s+tft-data-publication\s*$') {
    throw 'The refresh workflow must retain the publication lock.'
}
if ($watchdog -notmatch '(?m)^\s{2}group:\s+tft-data-watchdog\s*$') {
    throw 'The watchdog inspection workflow must use an independent concurrency group.'
}
if ($watchdog -notmatch '(?ms)^\s{2}repair-publication:.*?^\s{4}concurrency:\s*\r?\n\s{6}group:\s+tft-data-publication\s*$') {
    throw 'The watchdog repair deployment must acquire the publication lock.'
}

Write-Output 'Workflow concurrency policy passed: scheduled inspection cannot replace a pending data refresh.'
