$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ([string]$Actual -ne [string]$Expected) {
        throw "$Message. Expected=$Expected Actual=$Actual"
    }
}
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("tft-quality-v2-" + [Guid]::NewGuid().ToString('N'))
$siteRoot = Join-Path $tempRoot 'site'
$sourceRoot = Join-Path $tempRoot 'source'
New-Item -ItemType Directory -Force -Path $siteRoot, $sourceRoot | Out-Null
try {
    $catalogPath = Join-Path $sourceRoot 'tft_catalog.json'
    $snapshotPath = Join-Path $sourceRoot 'tft_static_snapshot.json'
    $indexPath = Join-Path $siteRoot 'data-index.json'

    $catalog = [ordered]@{
        set = [ordered]@{
            id = 'TFTSet99'
            number = 99
            nameJa = '品質テスト'
            tftPatch = '99.1'
        }
        champions = @(
            [ordered]@{ id='TFT99_A'; nameJa='A'; desc='有効な説明' },
            [ordered]@{ id='TFT99_B'; nameJa='B'; desc='有効な説明' }
        )
        traits = @([ordered]@{ id='TFT99_Trait'; nameJa='特性'; desc='有効な説明' })
        items = @([ordered]@{ id='TFT_Item_Test'; nameJa='テスト装備'; desc='有効な説明' })
        augments = @([ordered]@{ id='TFT99_Augment'; nameJa='テストオーグメント'; desc='有効な説明' })
    }
    $snapshot = [ordered]@{
        setId = 'TFTSet99'
        clusterId = 99001
        fetchedAtUtc = '2026-08-29T00:00:00Z'
        statsUpdatedEpochMs = 1787961600000
        readiness = 'META_STABLE'
        statisticsScope = [ordered]@{
            effective = 'PLATINUM_PLUS'
            minimumPreferredCompositions = 1
            qualifiedEffectiveCompositions = 1
        }
        compositions = @(
            [ordered]@{
                id = '99001'
                recommendedAugments = @([ordered]@{ id='TFT99_Augment' })
                levelBoards = @(
                    [ordered]@{
                        level = 4
                        synthetic = $false
                        unitIds = @('TFT99_A','TFT99_B')
                    }
                )
                itemData = @(
                    [ordered]@{
                        unitId = 'TFT99_A'
                        recommended = @(
                            [ordered]@{ itemIds = @('TFT_Item_Test') }
                        )
                    }
                )
            }
        )
        itemStats = @([ordered]@{ unitId='TFT99_A'; itemId='TFT_Item_Test' })
    }
    $index = [ordered]@{
        latestVersionId = 'tftset99-99.1-test'
        versions = @(
            [ordered]@{ id='tftset99-99.1-test'; setId='TFTSet99'; patch='99.1' }
        )
    }

    [IO.File]::WriteAllText($catalogPath, ($catalog | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($snapshotPath, ($snapshot | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($indexPath, ($index | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))

    & (Join-Path $PSScriptRoot 'write-data-quality-status.ps1') `
        -SiteDirectory $siteRoot `
        -SnapshotPath $snapshotPath `
        -CatalogPath $catalogPath

    $qualityPath = Join-Path $siteRoot 'data-quality.json'
    Assert-True (Test-Path -LiteralPath $qualityPath -PathType Leaf) 'data-quality.json was not generated.'
    $quality = Get-Content -Raw -Encoding UTF8 -LiteralPath $qualityPath | ConvertFrom-Json
    Assert-Equal $quality.schemaVersion 2 'Schema version must be v2'
    Assert-Equal $quality.releaseId 'tftset99-99.1-test' 'releaseId must match latest candidate identity'
    Assert-Equal $quality.versionId $quality.releaseId 'versionId/releaseId must remain identical'
    Assert-Equal $quality.overall 'READY' 'Fully populated fixture must be READY'
    Assert-Equal $quality.features.compositions.filter 'PLATINUM_PLUS' 'Composition filter contract changed'
    Assert-Equal $quality.features.compositions.queue 'RANKED' 'Composition queue contract changed'
    Assert-Equal $quality.features.compositions.patch 'CURRENT' 'Composition patch contract changed'
    Assert-Equal $quality.features.compositions.days 3 'Composition window contract changed'
    Assert-Equal $quality.features.compositions.permitFilterAdjustment $false 'Filter adjustment must stay disabled'
    Assert-Equal $quality.features.boards.syntheticBoardCount 0 'Synthetic board count must be zero'
    Assert-Equal $quality.features.boards.unknownUnitCount 0 'Unknown board unit count must be zero'
    Assert-Equal $quality.counts.unresolvedTokens 0 'Unresolved display token count must be zero'

    $badSnapshot = $snapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $badSnapshot.statisticsScope.effective = 'ALL_RANKS'
    [IO.File]::WriteAllText($snapshotPath, ($badSnapshot | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    $threw = $false
    try {
        & (Join-Path $PSScriptRoot 'write-data-quality-status.ps1') `
            -SiteDirectory $siteRoot `
            -SnapshotPath $snapshotPath `
            -CatalogPath $catalogPath
    } catch {
        $threw = $_.Exception.Message -match 'DATA_QUALITY_FILTER_MISMATCH'
    }
    Assert-True $threw 'ALL_RANKS fixture must fail closed instead of degrading silently.'

    $badSnapshot.statisticsScope.effective = 'PLATINUM_PLUS'
    $badSnapshot.compositions[0].levelBoards[0].synthetic = $true
    [IO.File]::WriteAllText($snapshotPath, ($badSnapshot | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    $threw = $false
    try {
        & (Join-Path $PSScriptRoot 'write-data-quality-status.ps1') `
            -SiteDirectory $siteRoot `
            -SnapshotPath $snapshotPath `
            -CatalogPath $catalogPath
    } catch {
        $threw = $_.Exception.Message -match 'DATA_QUALITY_SYNTHETIC_BOARDS'
    }
    Assert-True $threw 'Synthetic boards must fail closed.'

    Write-Output 'Data quality v2 regression passed.'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
