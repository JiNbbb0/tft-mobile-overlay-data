$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$fixtureRoot = Join-Path $repositoryRoot 'build/content-fingerprint-fixture'
if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -Recurse -Force -LiteralPath $fixtureRoot }
$imageRoot = Join-Path $fixtureRoot 'tft/images'
New-Item -ItemType Directory -Force -Path $imageRoot | Out-Null

$catalogPath = Join-Path $fixtureRoot 'tft/tft_catalog.json'
$snapshotPath = Join-Path $fixtureRoot 'tft_static_snapshot.json'
$imagePath = Join-Path $imageRoot 'test.png'
$catalog = [ordered]@{
    schemaVersion=1; fetchedAtUtc='2026-01-01T00:00:00Z'
    set=[ordered]@{ id='TFTSet18'; number=18; nameJa='Set 18'; nameEn='Set 18'; tftPatch='18.1' }
    sources=[ordered]@{ catalog='fixture' }
    champions=@([ordered]@{ id='TFT18_Test'; nameJa='Test Unit'; nameEn='Test'; cost=1; image='tft/images/test.png'; traits=@('Test Trait'); ability=[ordered]@{ nameJa='Test Ability'; descriptionJa='Test description'; icon='tft/images/test.png' } })
    traits=@(); items=@(); augments=@(); systemData=[ordered]@{ status='fixture' }
}
$snapshot = [ordered]@{
    schemaVersion=5; fetchedAtUtc='2026-01-01T00:00:00Z'; setId='TFTSet18'; clusterId=501; statsUpdatedEpochMs=1
    readiness='META_STABLE'; compositions=@([ordered]@{
        id='501001'; displayNameJa='Test Comp'; tier='S'; averagePlacement=4.0; sampleCount=100
        rollPlan=[ordered]@{ label='Lv8リロール' }; recommendedAugments=@()
        finalBoard=[ordered]@{ averagePlacement=4.0; units=@() }; levelBoards=@()
        units=@([ordered]@{
            id='TFT18_Test'; name='Test Unit'
            recommendedBuild=@([ordered]@{ itemId='Item_A' },[ordered]@{ itemId='Item_B' })
            itemStats=@([ordered]@{ itemId='Item_A'; averagePlacement=4.0; placementDelta=0.0; sampleCount=50; bestBuild=@() })
        })
    })
}
[IO.File]::WriteAllBytes($imagePath, [byte[]](137,80,78,71,13,10,26,10,1))
function Write-Fixture {
    [IO.File]::WriteAllText($catalogPath, ($catalog | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($snapshotPath, ($snapshot | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
}
function Fingerprint {
    & (Join-Path $PSScriptRoot 'get-content-fingerprint.ps1') -CatalogPath $catalogPath -SnapshotPath $snapshotPath -AssetRoot $fixtureRoot
}
function Assert-Equal($Expected, $Actual, [string]$Message) { if ($Expected -ne $Actual) { throw $Message } }
function Assert-NotEqual($Expected, $Actual, [string]$Message) { if ($Expected -eq $Actual) { throw $Message } }

Write-Fixture
$baseline = Fingerprint
$catalog.fetchedAtUtc='2026-01-01T01:00:00Z'; $snapshot.fetchedAtUtc='2026-01-01T01:00:00Z'; $snapshot.statsUpdatedEpochMs=2
Write-Fixture
Assert-Equal $baseline (Fingerprint) 'Observation timestamp-only change altered the material fingerprint.'
$snapshot.compositions[0].sampleCount=101
$snapshot.compositions[0].units[0].itemStats[0].sampleCount=51
Write-Fixture
Assert-NotEqual $baseline (Fingerprint) 'A sample-count change was not versioned.'
$snapshot.compositions[0].sampleCount=100; $snapshot.compositions[0].units[0].itemStats[0].sampleCount=50
$snapshot.compositions[0].averagePlacement=4.000001; Write-Fixture
Assert-NotEqual $baseline (Fingerprint) 'A small placement change was rounded out of the version identity.'
$snapshot.compositions[0].averagePlacement=4.0

$snapshot.compositions[0].displayNameJa='Changed Comp'; Write-Fixture
Assert-NotEqual $baseline (Fingerprint) 'Composition title change was not detected.'
$snapshot.compositions[0].displayNameJa='Test Comp'; $catalog.champions[0].nameJa='Changed Unit'; Write-Fixture
Assert-NotEqual $baseline (Fingerprint) 'Catalog change was not detected.'
$catalog.champions[0].nameJa='Test Unit'; Write-Fixture; [IO.File]::WriteAllBytes($imagePath, [byte[]](137,80,78,71,13,10,26,10,2))
Assert-NotEqual $baseline (Fingerprint) 'Referenced image content change was not detected.'
[IO.File]::WriteAllBytes($imagePath, [byte[]](137,80,78,71,13,10,26,10,1))
$snapshot.compositions[0].units[0].recommendedBuild=@([ordered]@{ itemId='Item_B' },[ordered]@{ itemId='Item_A' }); Write-Fixture
Assert-NotEqual $baseline (Fingerprint) 'Recommended item priority change was not detected.'

Write-Output 'Composite material fingerprint fixtures passed.'
