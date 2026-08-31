$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$toolsRoot = Join-Path $repoRoot 'tools'
$files = @(
    Get-ChildItem -LiteralPath $toolsRoot -Recurse -File -Filter '*.ps1' |
        Sort-Object FullName
)
if ($files.Count -eq 0) { throw 'No PowerShell scripts found under tools/.' }

# Auto-discovery is deliberate: adding a new hardening, validator, migration,
# or regression script must automatically place it under the parser gate.
$failures = [Collections.Generic.List[string]]::new()
foreach ($file in $files) {
    $relative = [IO.Path]::GetRelativePath($repoRoot, $file.FullName).Replace('\','/')
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    foreach ($parseError in @($errors)) {
        $line = if ($parseError.Extent) { [int]$parseError.Extent.StartLineNumber } else { 0 }
        $column = if ($parseError.Extent) { [int]$parseError.Extent.StartColumnNumber } else { 0 }
        $failures.Add("${relative}:${line}:${column}: $($parseError.Message)")
    }
}

if ($failures.Count -gt 0) {
    throw "Canonical PowerShell syntax validation failed:`n$($failures -join "`n")"
}
Write-Output "Canonical PowerShell syntax passed: Files=$($files.Count)"
