$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('tft-production-runtime-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
try {
    Copy-Item -LiteralPath $PSScriptRoot -Destination $tempRoot -Recurse -Force
    $copiedTools = Join-Path $tempRoot 'tools'
    & (Join-Path $copiedTools 'prepare-production-runtime.ps1')
    & (Join-Path $copiedTools 'test-canonical-script-syntax.ps1')
    Write-Output 'Production runtime preparation regression passed.'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
