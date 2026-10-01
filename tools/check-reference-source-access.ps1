param([string]$DefinitionPath='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'optional-reference-tables.ps1')
function Write-SourceObservation { param([string]$Url,[string]$Text) }
$root=Split-Path -Parent $PSScriptRoot
if (-not $DefinitionPath) {
    $catalog=Get-Content -Raw -LiteralPath (Join-Path $root 'source/current/tft/tft_catalog.json') | ConvertFrom-Json
    $DefinitionPath="config/reference-tables/$($catalog.set.id)-$($catalog.set.tftPatch).json"
}
if (-not (Test-Path -LiteralPath (Join-Path $root $DefinitionPath))) {
    Write-Output 'NO_CURRENT_REFERENCE_DEFINITION: no previous-set source request.'
    return
}
$definition=Get-Content -Raw -LiteralPath (Join-Path $root $DefinitionPath) | ConvertFrom-Json
# Read each explicitly public source once. No authentication, proxies, browser
# impersonation, response-body logging, or retries against a rejection.
foreach ($source in @(@('WISP_PAGE',$definition.pageUrl),@('WISP_CSV',$definition.csvUrl))) {
    try {
        $body=Get-OptionalReferenceText ([string]$source[1]) ([string]$source[0])
        Write-Output "$($source[0]): HTTP200; Bytes=$([Text.Encoding]::UTF8.GetByteCount($body))"
    } catch {
        Write-Warning (Get-ReferenceFailureCode $_)
    }
}
