$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$paths = @(
    'tools/normalize/Get-CurrentSetUniverse.ps1',
    'tools/normalize/Get-EmblemMappings.ps1',
    'tools/normalize/Resolve-TftDisplayValue.ps1',
    'tools/measure-emblem-quality.ps1',
    'tools/audit-live-current-set-universe.ps1',
    'tools/enable-current-set-catalog-universe.ps1',
    'tools/test-golden-set-regressions.ps1',
    'tools/test-emblem-mapping.ps1',
    'tools/test-data-quality-v2.ps1',
    'tools/write-data-quality-status.ps1',
    'tools/check-public-data-quality.ps1',
    'tools/metatft/Convert-MetaTftSnapshot.ps1',
    'tools/metatft/Convert-MetaTftBoards.ps1',
    'tools/metatft/Convert-MetaTftItems.ps1',
    'tools/metatft/build-live-canonical-dryrun.ps1',
    'tools/metatft/validate-live-canonical-dryrun.ps1',
    'tools/metatft/capture-live-source-snapshots.ps1',
    'tools/metatft/audit-live-source-shapes.ps1',
    'tools/quality/Test-CanonicalContract.ps1',
    'tools/quality/Test-PublishCandidate.ps1',
    'tools/quality/Test-RemotePublishCandidate.ps1',
    'tools/quality/Test-AndroidE2EEvidence.ps1',
    'tools/quality/Promote-PublishCandidate.ps1'
)

$failures = [Collections.Generic.List[string]]::new()
foreach ($relative in $paths) {
    $file = [IO.Path]::GetFullPath((Join-Path $repoRoot $relative))
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        $failures.Add("${relative}: missing file")
        continue
    }
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
    foreach ($parseError in @($errors)) {
        $line = if ($parseError.Extent) { [int]$parseError.Extent.StartLineNumber } else { 0 }
        $column = if ($parseError.Extent) { [int]$parseError.Extent.StartColumnNumber } else { 0 }
        $failures.Add("${relative}:${line}:${column}: $($parseError.Message)")
    }
}

if ($failures.Count -gt 0) {
    throw "Canonical PowerShell syntax validation failed:`n$($failures -join "`n")"
}
Write-Output "Canonical PowerShell syntax passed: Files=$($paths.Count)"
