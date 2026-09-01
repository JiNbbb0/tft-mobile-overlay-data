$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$catalogPath = Join-Path $PSScriptRoot 'refresh-catalog.ps1'
$text = [IO.File]::ReadAllText($catalogPath).Replace("`r`n", "`n")
if (-not $text.Contains('ForEach-Object { @($_.traits) }')) {
    throw 'Production catalog must flatten champion traits explicitly under StrictMode.'
}
if ($text.Contains('$playableChampions.traits')) {
    throw 'Production catalog still relies on unsafe array property enumeration for champion traits.'
}

$tokens = $null
$errors = $null
[void][Management.Automation.Language.Parser]::ParseFile($catalogPath, [ref]$tokens, [ref]$errors)
if (@($errors).Count -gt 0) {
    throw "Production catalog runtime has parser errors: $(@($errors | ForEach-Object Message) -join '; ')"
}

Write-Output 'Production catalog StrictMode regression passed.'
