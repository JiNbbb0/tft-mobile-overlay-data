$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$targetPath = Join-Path $PSScriptRoot "refresh-static-meta.ps1"
$text = [IO.File]::ReadAllText($targetPath).Replace("`r`n", "`n")

$replacements = [ordered]@{
    '    augments = $augments' = '    augments = @($augments)'
    '    compositions = $compositions' = '    compositions = @($compositions)'
}

$changed = $false
foreach ($entry in $replacements.GetEnumerator()) {
    $old = [string]$entry.Key
    $new = [string]$entry.Value
    if ($text.Contains($new)) { continue }
    if (-not $text.Contains($old)) {
        throw "Could not enforce JSON array contract; expected generator line not found: $old"
    }
    $text = $text.Replace($old, $new)
    $changed = $true
}

if ($changed) {
    [IO.File]::WriteAllText($targetPath, $text, [Text.UTF8Encoding]::new($false))
    Write-Output "Patched static-meta generator so empty collections serialize as JSON arrays."
} else {
    Write-Output "Static-meta generator already preserves JSON array collections."
}
