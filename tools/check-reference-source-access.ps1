param([string]$DefinitionPath='config/reference-tables/TFTSet18-18.3.json')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'optional-reference-tables.ps1')
function Write-SourceObservation { param([string]$Url,[string]$Text) }
$root=Split-Path -Parent $PSScriptRoot
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
