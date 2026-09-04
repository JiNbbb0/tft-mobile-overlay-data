Set-StrictMode -Version Latest

$script:TftFeatureStates = @('READY', 'PARTIAL', 'COLLECTING', 'NOT_PROVIDED', 'UNAVAILABLE')
$script:TftStableRequiredFeatures = @(
    'catalog',
    'champions',
    'traits',
    'items',
    'augments',
    'compositions',
    'boards',
    'recommendedItems'
)

function Get-TftObjectProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Default = $null
    )

    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) {
        return $Object.PSObject.Properties[$Name].Value
    }
    return $Default
}

function Get-TftFeatureStatus {
    param(
        [int]$ReadyCount,
        [int]$TotalCount,
        [string]$EmptyState = 'COLLECTING'
    )

    if ($TotalCount -le 0 -or $ReadyCount -le 0) { return $EmptyState }
    if ($ReadyCount -lt $TotalCount) { return 'PARTIAL' }
    return 'READY'
}

function Test-TftSourceEntry {
    param(
        [object[]]$Sources,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ExpectedSetId,
        [Parameter(Mandatory = $true)][string]$ExpectedPatch,
        [Parameter(Mandatory = $true)][string]$ExpectedRevision,
        [switch]$AllowZeroRecords
    )

    $entry = @($Sources | Where-Object { [string]$_.sourceName -eq $Name }) | Select-Object -First 1
    if (-not $entry) { return $false }
    if ([string]$entry.responseHash -notmatch '^[0-9a-f]{64}$') { return $false }
    if ([string](Get-TftObjectProperty $entry 'hashBasis' '') -ne 'source-response') { return $false }
    if ([string](Get-TftObjectProperty $entry 'verdict' '') -ne 'VERIFIED') { return $false }
    if (-not $AllowZeroRecords -and [int](Get-TftObjectProperty $entry 'recordCount' 0) -lt 1) { return $false }
    if ([string](Get-TftObjectProperty $entry 'setId' '') -ne $ExpectedSetId -or
        [string](Get-TftObjectProperty $entry 'patch' '') -ne $ExpectedPatch -or
        [string](Get-TftObjectProperty $entry 'revisionId' '') -ne $ExpectedRevision) { return $false }
    $native = Get-TftObjectProperty $entry 'nativeClaims' $null
    $query = Get-TftObjectProperty $entry 'queryClaims' $null
    switch ($Name) {
        'Riot TFT patch notes' {
            if ([string](Get-TftObjectProperty $native 'patch' '') -ne $ExpectedPatch) { return $false }
        }
        'CommunityDragon TFT Japanese data' {
            if ([string](Get-TftObjectProperty $native 'setId' '') -ne $ExpectedSetId) { return $false }
        }
        'CommunityDragon TFT English data' {
            if ([string](Get-TftObjectProperty $native 'setId' '') -ne $ExpectedSetId) { return $false }
        }
        'MetaTFT cluster information' {
            if ([string](Get-TftObjectProperty $native 'setId' '') -ne $ExpectedSetId -or
                [string](Get-TftObjectProperty $native 'revisionId' '') -ne $ExpectedRevision) { return $false }
        }
        'MetaTFT composition statistics' {
            if ([string](Get-TftObjectProperty $native 'setId' '') -ne $ExpectedSetId -or
                [string](Get-TftObjectProperty $native 'revisionId' '') -ne $ExpectedRevision -or
                [string](Get-TftObjectProperty $query 'patchMode' '') -ne 'current' -or
                [string](Get-TftObjectProperty $query 'permitFilterAdjustment' '') -ne 'false' -or
                [string](Get-TftObjectProperty $query 'rank' '') -ne 'CHALLENGER,DIAMOND,EMERALD,GRANDMASTER,MASTER,PLATINUM') { return $false }
        }
        'MetaTFT Japanese lookup' {
            if (-not ([string](Get-TftObjectProperty $entry 'sourceUrl' '')).Contains("/$ExpectedSetId`_latest_")) { return $false }
        }
        'MetaTFT composition item builds' {
            if ([string](Get-TftObjectProperty $query 'revisionId' '') -ne $ExpectedRevision) { return $false }
        }
        'MetaTFT composition details' {
            if ([string](Get-TftObjectProperty $query 'revisionId' '') -ne $ExpectedRevision) { return $false }
        }
    }
    return $true
}

function Resolve-TftUniverseStatus {
    param(
        [object[]]$ActualRows,
        [object[]]$ExpectedIds
    )

    $expected = @($ExpectedIds | ForEach-Object { ([string]$_).ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique)
    $actual = @($ActualRows | ForEach-Object { ([string](Get-TftObjectProperty $_ 'id' '')).ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique)
    if ($expected.Count -eq 0) { return 'UNAVAILABLE' }
    if ($actual.Count -ne $expected.Count) { return 'PARTIAL' }
    if (@(Compare-Object -ReferenceObject $expected -DifferenceObject $actual).Count -gt 0) { return 'PARTIAL' }
    return 'READY'
}

function Resolve-TftReleaseContract {
    param(
        [Parameter(Mandatory = $true)][object]$Catalog,
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][object]$SourceManifest
    )

    $setId = [string](Get-TftObjectProperty $Catalog.set 'id' '')
    $patch = [string](Get-TftObjectProperty $Catalog.set 'tftPatch' '')
    $revision = [string](Get-TftObjectProperty $Snapshot 'clusterId' '')
    if (-not $setId -or -not $patch -or -not $revision) {
        throw 'Release contract identity is incomplete.'
    }
    if ([string](Get-TftObjectProperty $Snapshot 'setId' '') -ne $setId) {
        throw "Release contract snapshot/catalog set mismatch: $([string]$Snapshot.setId) != $setId"
    }
    foreach ($field in @(
        @{ Name = 'setId'; Expected = $setId },
        @{ Name = 'patch'; Expected = $patch },
        @{ Name = 'revisionId'; Expected = $revision }
    )) {
        $actual = [string](Get-TftObjectProperty $SourceManifest $field.Name '')
        if ($actual -ne [string]$field.Expected) {
            throw "Release contract source manifest $($field.Name) mismatch: $actual != $($field.Expected)"
        }
    }

    $champions = @((Get-TftObjectProperty $Catalog 'champions' @()))
    $traits = @((Get-TftObjectProperty $Catalog 'traits' @()))
    $items = @((Get-TftObjectProperty $Catalog 'items' @()))
    $augments = @((Get-TftObjectProperty $Catalog 'augments' @()))
    $championCount = $champions.Count
    $traitCount = $traits.Count
    $itemCount = $items.Count
    $augmentCount = $augments.Count
    $sourceUniverse = Get-TftObjectProperty $Catalog 'sourceUniverse' $null
    $universeSetMatches = $sourceUniverse -and [string](Get-TftObjectProperty $sourceUniverse 'setId' '') -eq $setId
    $championStatus = if ($universeSetMatches) { Resolve-TftUniverseStatus $champions @((Get-TftObjectProperty $sourceUniverse 'championIds' @())) } else { 'UNAVAILABLE' }
    $traitStatus = if ($universeSetMatches) { Resolve-TftUniverseStatus $traits @((Get-TftObjectProperty $sourceUniverse 'traitIds' @())) } else { 'UNAVAILABLE' }
    $itemStatus = if ($universeSetMatches) { Resolve-TftUniverseStatus $items @((Get-TftObjectProperty $sourceUniverse 'itemIds' @())) } else { 'UNAVAILABLE' }
    $augmentStatus = if ($universeSetMatches) { Resolve-TftUniverseStatus $augments @((Get-TftObjectProperty $sourceUniverse 'augmentIds' @())) } else { 'UNAVAILABLE' }
    $catalogStates = @($championStatus, $traitStatus, $itemStatus, $augmentStatus)
    $catalogReady = @($catalogStates | Where-Object { $_ -ne 'READY' }).Count -eq 0

    $compositions = @((Get-TftObjectProperty $Snapshot 'compositions' @()) | Where-Object { $_ -is [pscustomobject] })
    $targetCompositionCount = 0
    $scope = Get-TftObjectProperty $Snapshot 'statisticsScope' $null
    if ($scope) {
        $effectiveScope = [string](Get-TftObjectProperty $scope 'effective' '')
        if ($effectiveScope -notin @('PLATINUM_PLUS', 'PLATINUM_PLUS_LIMITED')) {
            throw "DATA_QUALITY_FILTER_MISMATCH: effective scope must remain Platinum+ ($effectiveScope)"
        }
        $candidateTarget = [int](Get-TftObjectProperty $scope 'candidatePoolTarget' 0)
        if ($candidateTarget -gt 0) { $targetCompositionCount = $candidateTarget }
    }
    if ($targetCompositionCount -le 0 -and $compositions.Count -gt 0) { $targetCompositionCount = $compositions.Count }
    $compositionStatus = if ($compositions.Count -eq 0) {
        'COLLECTING'
    } elseif ($compositions.Count -lt $targetCompositionCount) {
        'PARTIAL'
    } else {
        'READY'
    }

    $championIds = @{}
    foreach ($champion in $champions) { $championIds[[string]$champion.id] = $true }
    $boardReadyCount = @($compositions | Where-Object {
        $finalBoard = Get-TftObjectProperty $_ 'finalBoard' $null
        $finalUnits = if ($finalBoard) { @((Get-TftObjectProperty $finalBoard 'units' @())) } else { @() }
        $finalSourceValid = $finalBoard -and [string](Get-TftObjectProperty $finalBoard 'source' '') -eq 'MetaTFT aggregate positioning'
        $finalUnitsValid = $finalUnits.Count -gt 0 -and @($finalUnits | Where-Object { -not $championIds.ContainsKey([string](Get-TftObjectProperty $_ 'id' '')) }).Count -eq 0
        $providedLevelBoards = @((Get-TftObjectProperty $_ 'levelBoards' @()))
        $invalidLevelBoards = @($providedLevelBoards | Where-Object {
            $boardSource = [string](Get-TftObjectProperty $_ 'source' '')
            $units = @((Get-TftObjectProperty $_ 'units' @()))
            $boardSource -notin @('MetaTFT early_options', 'MetaTFT options') -or
            $units.Count -eq 0 -or
            @($units | Where-Object { -not $championIds.ContainsKey([string](Get-TftObjectProperty $_ 'id' '')) }).Count -gt 0
        })
        $finalSourceValid -and $finalUnitsValid -and $invalidLevelBoards.Count -eq 0
    }).Count
    $boardStatus = if ($compositionStatus -eq 'COLLECTING') {
        'COLLECTING'
    } else {
        Get-TftFeatureStatus -ReadyCount $boardReadyCount -TotalCount $compositions.Count
    }

    $levelBoardReadiness = [ordered]@{}
    foreach ($level in 4..9) {
        $matchingBoards = @(
            $compositions | ForEach-Object { @((Get-TftObjectProperty $_ 'levelBoards' @())) } | Where-Object {
                [int](Get-TftObjectProperty $_ 'level' 0) -eq $level -and
                [string](Get-TftObjectProperty $_ 'source' '') -in @('MetaTFT early_options', 'MetaTFT options')
            }
        )
        $levelBoardReadiness["lv$level"] = if ($matchingBoards.Count -gt 0) {
            'READY'
        } elseif ($compositionStatus -eq 'READY') {
            'NOT_PROVIDED'
        } else {
            'COLLECTING'
        }
    }

    $recommendedItemReadyCount = @($compositions | Where-Object {
        $summaryItems = @((Get-TftObjectProperty $_ 'itemRecommendations' @()))
        $unitItems = @(
            foreach ($unit in @((Get-TftObjectProperty $_ 'units' @()))) {
                @((Get-TftObjectProperty $unit 'recommendedBuild' @()))
                @((Get-TftObjectProperty $unit 'itemStats' @()))
            }
        )
        $summaryItems.Count -gt 0 -and $unitItems.Count -gt 0
    }).Count
    $recommendedItemStatus = if ($compositionStatus -eq 'COLLECTING') {
        'COLLECTING'
    } else {
        Get-TftFeatureStatus -ReadyCount $recommendedItemReadyCount -TotalCount $compositions.Count
    }

    $compositionAugmentReadyCount = @($compositions | Where-Object {
        @((Get-TftObjectProperty $_ 'recommendedAugments' @())).Count -gt 0
    }).Count
    $compositionAugmentStatus = if ($compositionStatus -eq 'COLLECTING') {
        'COLLECTING'
    } elseif ($compositionAugmentReadyCount -eq 0) {
        'COLLECTING'
    } else {
        Get-TftFeatureStatus -ReadyCount $compositionAugmentReadyCount -TotalCount $compositions.Count
    }

    $featureReadiness = [ordered]@{
        catalog = $(if ($catalogReady) { 'READY' } elseif (@($catalogStates | Where-Object { $_ -eq 'READY' }).Count -gt 0) { 'PARTIAL' } else { 'UNAVAILABLE' })
        champions = $championStatus
        traits = $traitStatus
        items = $itemStatus
        augments = $augmentStatus
        compositions = $compositionStatus
        boards = $boardStatus
        recommendedItems = $recommendedItemStatus
        compositionAugments = $compositionAugmentStatus
    }

    foreach ($property in $featureReadiness.GetEnumerator()) {
        if ([string]$property.Value -notin $script:TftFeatureStates) {
            throw "Unknown feature readiness for $($property.Key): $($property.Value)"
        }
    }

    $sources = @((Get-TftObjectProperty $SourceManifest 'sources' @()) | Where-Object { $_ -is [pscustomobject] })
    $sourceEvidence = Get-TftObjectProperty $SourceManifest 'sourceEvidence' $null
    $sourceEvidenceVerified = [string](Get-TftObjectProperty $SourceManifest 'coherenceStatus' '') -eq 'VERIFIED' -and
        $sourceEvidence -and
        [string](Get-TftObjectProperty (Get-TftObjectProperty $sourceEvidence 'set' $null) 'value' '') -eq $setId -and
        [string](Get-TftObjectProperty (Get-TftObjectProperty $sourceEvidence 'set' $null) 'status' '') -eq 'CROSS_SOURCE_VERIFIED' -and
        [string](Get-TftObjectProperty (Get-TftObjectProperty $sourceEvidence 'patch' $null) 'value' '') -eq $patch -and
        [string](Get-TftObjectProperty (Get-TftObjectProperty $sourceEvidence 'patch' $null) 'status' '') -eq 'AUTHORITY_VERIFIED' -and
        [string](Get-TftObjectProperty (Get-TftObjectProperty $sourceEvidence 'revision' $null) 'value' '') -eq $revision -and
        [string](Get-TftObjectProperty (Get-TftObjectProperty $sourceEvidence 'revision' $null) 'status' '') -eq 'AUTHORITY_VERIFIED'

    $catalogSourceNames = @(
        'Riot TFT patch notes',
        'CommunityDragon TFT Japanese data',
        'CommunityDragon TFT English data',
        'MetaTFT cluster information'
    )
    $stableSourceNames = $catalogSourceNames + @(
        'MetaTFT augment tiers',
        'MetaTFT composition statistics',
        'MetaTFT Japanese lookup',
        'MetaTFT composition item builds',
        'MetaTFT composition details'
    )
    $catalogSourcesReady = [bool]$sourceEvidenceVerified
    $catalogSourceFailures = [Collections.Generic.List[string]]::new()
    if (-not $sourceEvidenceVerified) { $catalogSourceFailures.Add('cross-source-identity') }
    foreach ($name in $catalogSourceNames) {
        if (-not (Test-TftSourceEntry -Sources $sources -Name $name -ExpectedSetId $setId -ExpectedPatch $patch -ExpectedRevision $revision)) {
            $catalogSourcesReady = $false
            $catalogSourceFailures.Add($name)
        }
    }
    $stableSourcesReady = $catalogSourcesReady
    $stableSourceFailures = [Collections.Generic.List[string]]::new()
    foreach ($name in $stableSourceNames) {
        if (-not (Test-TftSourceEntry -Sources $sources -Name $name -ExpectedSetId $setId -ExpectedPatch $patch -ExpectedRevision $revision)) {
            $stableSourcesReady = $false
            $stableSourceFailures.Add($name)
        }
    }
    if (-not $catalogSourcesReady) {
        throw "Required Riot/CommunityDragon/MetaTFT catalog sources are missing, empty, or inconsistent: $($catalogSourceFailures -join ', ')"
    }

    $stableFeaturesReady = $true
    foreach ($featureName in $script:TftStableRequiredFeatures) {
        if ([string]$featureReadiness[$featureName] -ne 'READY') { $stableFeaturesReady = $false }
    }
    $stableEligible = $stableFeaturesReady -and $stableSourcesReady
    $releaseState = if ($stableEligible) { 'STABLE' } else { 'PARTIAL' }
    $sourceAlignment = if ($stableSourcesReady) { 'VERIFIED' } else { 'PARTIAL' }

    return [pscustomobject][ordered]@{
        releaseState = $releaseState
        validationStatus = $(if ($stableEligible) { 'PASS' } else { 'PARTIAL_PASS' })
        sourceAlignment = $sourceAlignment
        stableEligible = [bool]$stableEligible
        featureReadiness = [pscustomobject]$featureReadiness
        levelBoardReadiness = [pscustomobject]$levelBoardReadiness
        counts = [pscustomobject][ordered]@{
            champions = $championCount
            traits = $traitCount
            items = $itemCount
            augments = $augmentCount
            compositions = $compositions.Count
            targetCompositions = $targetCompositionCount
            boardReadyCompositions = $boardReadyCount
            recommendedItemCompositions = $recommendedItemReadyCount
            compositionAugmentCompositions = $compositionAugmentReadyCount
        }
        sourceWarnings = @($stableSourceFailures | Sort-Object -Unique)
    }
}

function Test-TftVersionStable {
    param(
        [Parameter(Mandatory = $true)][object]$Version,
        [AllowNull()][object]$Manifest
    )

    $releaseState = [string](Get-TftObjectProperty $Version 'releaseState' '')
    if (-not $releaseState -and $Manifest) {
        $releaseState = [string](Get-TftObjectProperty $Manifest 'releaseState' '')
    }
    if ($releaseState) { return $releaseState -eq 'STABLE' }
    return [string](Get-TftObjectProperty $Version 'readiness' '') -eq 'META_STABLE'
}
