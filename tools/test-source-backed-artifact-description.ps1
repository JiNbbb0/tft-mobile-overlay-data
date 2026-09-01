$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'normalize/Resolve-SourceBackedArtifactDescription.ps1')

$target = [pscustomobject]@{
    apiName = 'DA_Artifact_MogulsMail'
    name = 'モーグル メイル'
    icon = 'same/icon.tex'
    desc = $null
}
$items = @(
    $target,
    [pscustomobject]@{ apiName='TFT7_Item_ShimmerscaleMogulsMail'; name='モーグル メイル'; icon='same/icon.tex'; desc='source text' },
    [pscustomobject]@{ apiName='TFT_Item_MogulsMail_Radiant'; name='モーグル メイル'; icon='same/icon.tex'; desc='radiant text' },
    [pscustomobject]@{ apiName='TFT_Item_Other'; name='別の名前'; icon='same/icon.tex'; desc='other text' }
)

$resolved = Get-TftSourceBackedArtifactDescriptionCandidate -TargetItem $target -AllItems $items
if ([string]$resolved.apiName -ne 'TFT7_Item_ShimmerscaleMogulsMail') {
    throw "Expected exact source-backed artifact description candidate."
}

$ambiguous = @($items) + [pscustomobject]@{
    apiName = 'TFT_Item_MogulsMail_Copy'
    name = 'モーグル メイル'
    icon = 'same/icon.tex'
    desc = 'ambiguous text'
}
$failedClosed = $false
try {
    Get-TftSourceBackedArtifactDescriptionCandidate -TargetItem $target -AllItems $ambiguous | Out-Null
} catch {
    $failedClosed = $_.Exception.Message -match 'SOURCE_BACKED_ARTIFACT_DESCRIPTION_AMBIGUOUS'
}
if (-not $failedClosed) { throw 'Ambiguous artifact descriptions must fail closed.' }

Write-Output 'Source-backed artifact description regression passed.'
