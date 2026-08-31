$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

& (Join-Path $PSScriptRoot 'ensure-json-array-contract.ps1')
& (Join-Path $PSScriptRoot 'enable-current-set-catalog-universe.ps1')
& (Join-Path $PSScriptRoot 'enable-typed-display-catalog.ps1')
& (Join-Path $PSScriptRoot 'enable-strict-production-source-policy.ps1')
& (Join-Path $PSScriptRoot 'enable-candidate-publication-lifecycle.ps1')
& (Join-Path $PSScriptRoot 'verify-runtime-hardening.ps1')

Write-Output 'Canonical v2 production runtime prepared.'
