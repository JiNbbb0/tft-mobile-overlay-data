$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'release-contract-policy.ps1')

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "$Message Expected=$Expected Actual=$Actual" }
}

$catalog = [pscustomobject][ordered]@{
    set = [pscustomobject]@{ id='TFTSet99'; tftPatch='99.1' }
    sourceUniverse = [pscustomobject]@{
        setId='TFTSet99'; championIds=@('unit-a'); traitIds=@('trait-a'); itemIds=@('item-a'); augmentIds=@('augment-a')
    }
    champions = @([pscustomobject]@{ id='unit-a' })
    traits = @([pscustomobject]@{ id='trait-a' })
    items = @([pscustomobject]@{ id='item-a' })
    augments = @([pscustomobject]@{ id='augment-a' })
}
$composition = [pscustomobject][ordered]@{
    id='comp-a'
    finalBoard=[pscustomobject]@{ source='MetaTFT aggregate positioning'; units=@([pscustomobject]@{ id='unit-a' }) }
    levelBoards=@([pscustomobject]@{ level=7; source='MetaTFT options'; units=@([pscustomobject]@{ id='unit-a' }) })
    itemRecommendations=@([pscustomobject]@{ itemId='item-a' })
    units=@([pscustomobject]@{ id='unit-a'; recommendedBuild=@([pscustomobject]@{ itemId='item-a' }); itemStats=@([pscustomobject]@{ itemId='item-a' }) })
    recommendedAugments=@()
}
$snapshot = [pscustomobject][ordered]@{
    setId='TFTSet99'; clusterId='999'
    statisticsScope=[pscustomobject]@{ effective='PLATINUM_PLUS'; candidatePoolTarget=1; qualifiedEffectiveCompositions=1 }
    compositions=@($composition)
}
$requiredSources = @(
    'Riot TFT patch notes',
    'CommunityDragon TFT Japanese data',
    'CommunityDragon TFT English data',
    'MetaTFT cluster information',
    'MetaTFT augment tiers',
    'MetaTFT composition statistics',
    'MetaTFT Japanese lookup',
    'MetaTFT composition item builds',
    'MetaTFT composition details'
)
$sources = @($requiredSources | ForEach-Object {
    $name = [string]$_
    $native = [ordered]@{}
    $query = [ordered]@{}
    $url = 'https://fixture.invalid/source'
    switch ($name) {
        'Riot TFT patch notes' { $native.patch='99.1' }
        'CommunityDragon TFT Japanese data' { $native.setId='TFTSet99' }
        'CommunityDragon TFT English data' { $native.setId='TFTSet99' }
        'MetaTFT cluster information' { $native.setId='TFTSet99'; $native.revisionId='999' }
        'MetaTFT composition statistics' {
            $native.setId='TFTSet99'; $native.revisionId='999'
            $query.patchMode='current'; $query.permitFilterAdjustment='false'
            $query.rank='CHALLENGER,DIAMOND,EMERALD,GRANDMASTER,MASTER,PLATINUM'
        }
        'MetaTFT Japanese lookup' { $url='https://fixture.invalid/lookups/TFTSet99_latest_ja_jp.json' }
        'MetaTFT composition item builds' { $query.revisionId='999' }
        'MetaTFT composition details' { $query.revisionId='999' }
    }
    [pscustomobject]@{
        sourceName=$name; sourceUrl=$url; setId='TFTSet99'; patch='99.1'; revisionId='999'
        responseHash=('a' * 64); hashBasis='source-response'; verdict='VERIFIED'; recordCount=1
        nativeClaims=[pscustomobject]$native; queryClaims=[pscustomobject]$query
    }
})
$sourceManifest = [pscustomobject][ordered]@{
    setId='TFTSet99'; patch='99.1'; revisionId='999'; coherenceStatus='VERIFIED'
    sourceEvidence=[pscustomobject]@{
        set=[pscustomobject]@{ value='TFTSet99'; status='CROSS_SOURCE_VERIFIED' }
        patch=[pscustomobject]@{ value='99.1'; status='AUTHORITY_VERIFIED' }
        revision=[pscustomobject]@{ value='999'; status='AUTHORITY_VERIFIED' }
    }
    sources=$sources
}

$stable = Resolve-TftReleaseContract -Catalog $catalog -Snapshot $snapshot -SourceManifest $sourceManifest
Assert-Equal 'STABLE' $stable.releaseState 'Complete verified data was not stable.'
Assert-Equal 'PASS' $stable.validationStatus 'Stable validation did not pass.'
Assert-Equal 'COLLECTING' $stable.featureReadiness.compositionAugments 'Optional augment collection state was lost.'

$limitedSnapshot = $snapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$limitedSnapshot.statisticsScope.effective = 'PLATINUM_PLUS_LIMITED'
$limitedSnapshot.statisticsScope.candidatePoolTarget = 2
$limited = Resolve-TftReleaseContract -Catalog $catalog -Snapshot $limitedSnapshot -SourceManifest $sourceManifest
Assert-Equal 'PARTIAL' $limited.releaseState 'Limited Platinum+ coverage was incorrectly certified stable.'
Assert-Equal 'PARTIAL' $limited.featureReadiness.compositions 'Limited Platinum+ coverage was not exposed as partial.'

$collectingSnapshot = $snapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$collectingSnapshot.statisticsScope.effective = 'PLATINUM_PLUS_LIMITED'
$collectingSnapshot.compositions = @()
$collecting = Resolve-TftReleaseContract -Catalog $catalog -Snapshot $collectingSnapshot -SourceManifest $sourceManifest
Assert-Equal 'PARTIAL' $collecting.releaseState 'Catalog-first new set was incorrectly certified stable.'
Assert-Equal 'COLLECTING' $collecting.featureReadiness.compositions 'Catalog-first new set did not remain collecting.'

$unsafeSnapshot = $snapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$unsafeSnapshot.statisticsScope.effective = 'ALL_RANKS_FALLBACK'
$blocked = $false
try { Resolve-TftReleaseContract -Catalog $catalog -Snapshot $unsafeSnapshot -SourceManifest $sourceManifest | Out-Null } catch { $blocked = $true }
Assert-Equal $true $blocked 'ALL_RANKS fallback was not rejected.'

$unverifiedManifest = $sourceManifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$unverifiedManifest.sources[0].hashBasis = 'generated-output-fallback'
$blocked = $false
try { Resolve-TftReleaseContract -Catalog $catalog -Snapshot $snapshot -SourceManifest $unverifiedManifest | Out-Null } catch { $blocked = $true }
Assert-Equal $true $blocked 'Missing source-response evidence was not rejected.'

Write-Output 'Release contract policy fixtures passed.'
