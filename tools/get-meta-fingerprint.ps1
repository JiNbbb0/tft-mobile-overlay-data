param(
    [Parameter(Mandatory)]
    [string]$SnapshotPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Exact-Numeric([object]$Value) {
    if ($null -eq $Value) { return $null }
    # Preserve every source-provided numeric change. Returning a round-trip
    # invariant string avoids locale drift and arbitrary display rounding
    # suppressing an otherwise meaningful META_UPDATE.
    return ([double]$Value).ToString('R', [Globalization.CultureInfo]::InvariantCulture)
}

function Names([object[]]$Rows) {
    return @($Rows | ForEach-Object { [string]$_.id } | Sort-Object)
}

function IdsInOrder([object[]]$Rows) {
    return @($Rows | ForEach-Object { [string]$_.id })
}

function Optional([object]$Row, [string]$Property, [object]$Default = $null) {
    if ($null -ne $Row -and $Row.PSObject.Properties[$Property]) { return $Row.$Property }
    return $Default
}

$snapshot = Get-Content -Raw -Encoding UTF8 -LiteralPath $SnapshotPath | ConvertFrom-Json
$scope = Optional $snapshot 'statisticsScope' $null
$normalized = [ordered]@{
    schema = 2
    # All rank-dependent numeric values and ordering affect META_UPDATE identity.
    # Observation clocks are excluded, exactly as on the legacy root snapshot.
    compositionRanks = if ($snapshot.PSObject.Properties['compositionRanks']) {
        $ranked = $snapshot.compositionRanks | ConvertTo-Json -Depth 40 -Compress | ConvertFrom-Json
        foreach ($dataset in @($ranked.datasets)) {
            foreach ($field in @('fetchedAtUtc','statsUpdatedEpochMs','sources')) { $dataset.snapshot.PSObject.Properties.Remove($field) }
            if ($dataset.snapshot.PSObject.Properties['catalogStatistics']) { $dataset.snapshot.catalogStatistics.PSObject.Properties.Remove('sourceUpdatedEpochMs') }
        }
        $ranked
    } else { $null }
    setId = [string]$snapshot.setId
    readiness = [string](Optional $snapshot 'readiness' 'META_STABLE')
    locale = [string](Optional $snapshot 'locale' '')
    disclaimer = [string](Optional $snapshot 'disclaimer' '')
    itemStatBasis = Optional $snapshot 'itemStatBasis' $null
    statisticsScope = if ($scope) {
        [ordered]@{
            preferred = [string](Optional $scope 'preferred' '')
            effective = [string](Optional $scope 'effective' '')
            minimumCompositionSamples = [int](Optional $scope 'minimumCompositionSamples' 0)
            minimumPreferredCompositions = [int](Optional $scope 'minimumPreferredCompositions' 0)
            candidatePoolTarget = [int](Optional $scope 'candidatePoolTarget' 0)
            qualifiedPreferredCompositions = [int](Optional $scope 'qualifiedPreferredCompositions' 0)
            qualifiedEffectiveCompositions = [int](Optional $scope 'qualifiedEffectiveCompositions' 0)
            fallbackAttempted = [bool](Optional $scope 'fallbackAttempted' $false)
            fallbackReason = [string](Optional $scope 'fallbackReason' '')
            implicitFilterAdjustmentAllowed = [bool](Optional $scope 'implicitFilterAdjustmentAllowed' $false)
            preferredRankFilter = [string](Optional $scope 'preferredRankFilter' '')
            fallbackRankFilter = [string](Optional $scope 'fallbackRankFilter' '')
            pageParity = Optional $scope 'pageParity' $null
        }
    } else { $null }
    catalogStatistics = if (Optional $snapshot 'catalogStatistics' $null) {
        $catalogStats = $snapshot.catalogStatistics
        [ordered]@{
            sourceUpdatedEpochMs = [int64](Optional $catalogStats 'sourceUpdatedEpochMs' 0)
            scope = Optional $catalogStats 'scope' $null
            games = Optional $catalogStats 'games' $null
            excludedUnresolvableItemIds = @((Optional $catalogStats 'excludedUnresolvableItemIds' @()) | ForEach-Object { [string]$_ } | Sort-Object)
            units = @(
                @(Optional $catalogStats 'units' @()) | Sort-Object id | ForEach-Object {
                    [ordered]@{
                        id = [string]$_.id
                        tier = [string]$_.tier
                        tierScore = Exact-Numeric $_.tierScore
                        averagePlacement = Exact-Numeric $_.averagePlacement
                        winRate = Exact-Numeric $_.winRate
                        topFourRate = Exact-Numeric $_.topFourRate
                        frequency = Exact-Numeric $_.frequency
                        sampleCount = [int64]$_.sampleCount
                        popularItemIds = @($_.popularItemIds | ForEach-Object { [string]$_ })
                    }
                }
            )
            items = @(
                @(Optional $catalogStats 'items' @()) | Sort-Object id | ForEach-Object {
                    [ordered]@{
                        id = [string]$_.id
                        sourceIds = @((Optional $_ 'sourceIds' @()) | ForEach-Object { [string]$_ } | Sort-Object)
                        type = [string]$_.type
                        tier = [string]$_.tier
                        tierScore = Exact-Numeric $_.tierScore
                        averagePlacement = Exact-Numeric $_.averagePlacement
                        placementDelta = Exact-Numeric $_.placementDelta
                        winRate = Exact-Numeric $_.winRate
                        topFourRate = Exact-Numeric $_.topFourRate
                        frequency = Exact-Numeric $_.frequency
                        sampleCount = [int64]$_.sampleCount
                        popularUnitIds = @($_.popularUnitIds | ForEach-Object { [string]$_ })
                    }
                }
            )
            traits = @(
                @(Optional $catalogStats 'traits' @()) | Sort-Object id | ForEach-Object {
                    [ordered]@{
                        id = [string]$_.id
                        tier = [string]$_.tier
                        tierScore = Exact-Numeric $_.tierScore
                        averagePlacement = Exact-Numeric $_.averagePlacement
                        winRate = Exact-Numeric $_.winRate
                        topFourRate = Exact-Numeric $_.topFourRate
                        frequency = Exact-Numeric $_.frequency
                        sampleCount = [int64]$_.sampleCount
                        variations = @($_.variations | Sort-Object sourceId | ForEach-Object {
                            [ordered]@{
                                sourceId = [string]$_.sourceId
                                level = [int]$_.level
                                averagePlacement = Exact-Numeric $_.averagePlacement
                                winRate = Exact-Numeric $_.winRate
                                frequency = Exact-Numeric $_.frequency
                                sampleCount = [int64]$_.sampleCount
                            }
                        })
                    }
                }
            )
        }
    } else { $null }
    augments = @(
        @(Optional $snapshot 'augments' @()) | Sort-Object id | ForEach-Object {
            [ordered]@{
                id = [string]$_.id
                name = [string](Optional $_ 'name' '')
                tier = [string]$_.tier
                rarity = [string](Optional $_ 'rarity' '')
                stages = @((Optional $_ 'stages' @()) | ForEach-Object { [string]$_ })
                tags = @((Optional $_ 'tags' @()) | ForEach-Object { [string]$_ } | Sort-Object)
                averagePlacement = Exact-Numeric (Optional $_ 'averagePlacement' $null)
                sampleCount = [int64](Optional $_ 'sampleCount' 0)
            }
        }
    )
    compositions = @(
        @($snapshot.compositions) | Sort-Object id | ForEach-Object {
            $composition = $_
            $title = if ($composition.PSObject.Properties['displayNameJa']) {
                [string]$composition.displayNameJa
            } else {
                [string]$composition.name
            }
            [ordered]@{
                id = [string]$composition.id
                displayNameJa = $title
                titleSource = [string](Optional $composition 'titleSource' '')
                titleKey = [string](Optional $composition 'titleKey' '')
                tier = [string]$composition.tier
                averagePlacement = Exact-Numeric $composition.averagePlacement
                sampleCount = [int64](Optional $composition 'sampleCount' 0)
                overviewUnitIds = @((Optional $composition 'overviewUnitIds' @()) | ForEach-Object { [string]$_ })
                itemRecommendations = @(
                    @(Optional $composition 'itemRecommendations' @()) | ForEach-Object {
                        [ordered]@{
                            id = [string]$_.itemId
                            name = [string](Optional $_ 'itemName' '')
                            adoptionRate = Exact-Numeric $_.adoptionRate
                            averagePlacement = Exact-Numeric $_.averagePlacement
                            sampleCount = [int64]$_.sampleCount
                        }
                    }
                )
                rollPlan = $composition.rollPlan
                recommendedAugments = @(
                    @($composition.recommendedAugments) | ForEach-Object {
                        [ordered]@{
                            id = [string]$_.id
                            name = [string](Optional $_ 'name' '')
                            tier = [string]$_.tier
                            rarity = [string](Optional $_ 'rarity' '')
                            averagePlacement = Exact-Numeric (Optional $_ 'averagePlacement' $null)
                            sampleCount = [int64](Optional $_ 'sampleCount' 0)
                        }
                    }
                )
                finalBoard = [ordered]@{
                    averagePlacement = Exact-Numeric (Optional $composition.finalBoard 'averagePlacement' $null)
                    sampleCount = [int64](Optional $composition.finalBoard 'sampleCount' 0)
                    units = @($composition.finalBoard.units | Sort-Object position,id | ForEach-Object {
                        [ordered]@{
                            id = [string]$_.id
                            name = [string]$_.name
                            position = [int]$_.position
                            starLevel = [int]$_.starLevel
                            starRate = Exact-Numeric (Optional $_ 'starRate' $null)
                        }
                    })
                }
                levelBoards = @(
                    @($composition.levelBoards) | Sort-Object level,averagePlacement | ForEach-Object {
                        [ordered]@{
                            level = [int]$_.level
                            source = [string]$_.source
                            averagePlacement = Exact-Numeric $_.averagePlacement
                            sampleCount = [int64](Optional $_ 'sampleCount' 0)
                            units = @($_.units | Sort-Object position,id | ForEach-Object {
                                [ordered]@{
                                    id = [string]$_.id
                                    name = [string]$_.name
                                    position = [int]$_.position
                                    starLevel = [int]$_.starLevel
                                    starRate = Exact-Numeric (Optional $_ 'starRate' $null)
                                }
                            })
                        }
                    }
                )
                units = @(
                    @($composition.units) | Sort-Object id | ForEach-Object {
                        [ordered]@{
                            id = [string]$_.id
                            name = [string]$_.name
                            recommendedBuild = IdsInOrder @(
                                if ($_.PSObject.Properties['recommendedBuild']) {
                                    @($_.recommendedBuild) | ForEach-Object { [pscustomobject]@{ id = $_.itemId } }
                                }
                            )
                            items = @(
                                @($_.itemStats) | Sort-Object itemId | ForEach-Object {
                                    [ordered]@{
                                        id = [string]$_.itemId
                                        name = [string](Optional $_ 'itemName' '')
                                        averagePlacement = Exact-Numeric $_.averagePlacement
                                        placementDelta = Exact-Numeric $_.placementDelta
                                        sampleCount = [int64](Optional $_ 'sampleCount' 0)
                                        bestBuildSampleCount = [int64](Optional $_ 'bestBuildSampleCount' 0)
                                        bestBuild = Names @($_.bestBuild | ForEach-Object { [pscustomobject]@{ id = $_.itemId } })
                                    }
                                }
                            )
                        }
                    }
                )
            }
        }
    )
}

$json = $normalized | ConvertTo-Json -Depth 20 -Compress
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
} finally {
    $sha.Dispose()
}
Write-Output $hash
