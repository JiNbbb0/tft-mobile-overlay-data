$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'metatft-item-ranking-policy.ps1')

$rows = @(
    [pscustomobject]@{ itemId='low-placement'; itemName='Low placement'; adoptionRate=0.40; averagePlacement=3.10; sampleCount=400 },
    [pscustomobject]@{ itemId='most-played'; itemName='Most played'; adoptionRate=0.77; averagePlacement=3.83; sampleCount=770 },
    [pscustomobject]@{ itemId='second'; itemName='Second'; adoptionRate=0.54; averagePlacement=3.70; sampleCount=540 }
)
$ranked = @(Sort-MetaTftCompositionItemRanking -Rows $rows -CompositionId 'fixture')
if (($ranked.itemId -join ',') -ne 'most-played,second,low-placement') {
    throw "MetaTFT item ranking must be adoption-rate descending, got: $($ranked.itemId -join ',')"
}

$duplicateFailed = $false
try {
    Sort-MetaTftCompositionItemRanking -Rows @($rows[0], $rows[0]) -CompositionId 'duplicate' | Out-Null
} catch {
    $duplicateFailed = $_.Exception.Message -match 'duplicate canonical IDs'
}
if (-not $duplicateFailed) { throw 'Duplicate canonical item IDs must fail closed.' }

Write-Output 'MetaTFT composition item ranking policy: PASS'
