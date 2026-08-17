param(
    [Parameter(Mandatory)]
    [string]$SnapshotPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Round-Semantic([object]$Value) {
    if ($null -eq $Value) { return $null }
    return [Math]::Round([double]$Value, 2, [MidpointRounding]::AwayFromZero)
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
    schema = 1
    setId = [string]$snapshot.setId
    readiness = [string](Optional $snapshot 'readiness' 'META_STABLE')
    statisticsScope = if ($scope) {
        [ordered]@{
            preferred = [string](Optional $scope 'preferred' '')
            effective = [string](Optional $scope 'effective' '')
            minimumCompositionSamples = [int](Optional $scope 'minimumCompositionSamples' 0)
            minimumPreferredCompositions = [int](Optional $scope 'minimumPreferredCompositions' 0)
            fallbackAttempted = [bool](Optional $scope 'fallbackAttempted' $false)
            implicitFilterAdjustmentAllowed = [bool](Optional $scope 'implicitFilterAdjustmentAllowed' $false)
            preferredRankFilter = [string](Optional $scope 'preferredRankFilter' '')
            fallbackRankFilter = [string](Optional $scope 'fallbackRankFilter' '')
        }
    } else { $null }
    augments = @(
        @(Optional $snapshot 'augments' @()) | Sort-Object id | ForEach-Object {
            [ordered]@{ id = [string]$_.id; name = [string](Optional $_ 'name' ''); tier = [string]$_.tier }
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
                tier = [string]$composition.tier
                averagePlacement = Round-Semantic $composition.averagePlacement
                rollPlan = $composition.rollPlan
                recommendedAugments = @(
                    @($composition.recommendedAugments) | ForEach-Object {
                        [ordered]@{
                            id = [string]$_.id
                            name = [string](Optional $_ 'name' '')
                            tier = [string]$_.tier
                            rarity = [string](Optional $_ 'rarity' '')
                            averagePlacement = Round-Semantic (Optional $_ 'averagePlacement' $null)
                        }
                    }
                )
                finalBoard = [ordered]@{
                    averagePlacement = Round-Semantic $composition.finalBoard.averagePlacement
                    units = @($composition.finalBoard.units | Sort-Object position,id | ForEach-Object {
                        [ordered]@{ id = [string]$_.id; name = [string]$_.name; position = [int]$_.position; starLevel = [int]$_.starLevel }
                    })
                }
                levelBoards = @(
                    @($composition.levelBoards) | Sort-Object level,averagePlacement | ForEach-Object {
                        [ordered]@{
                            level = [int]$_.level
                            source = [string]$_.source
                            averagePlacement = Round-Semantic $_.averagePlacement
                            units = @($_.units | Sort-Object position,id | ForEach-Object {
                                [ordered]@{ id = [string]$_.id; name = [string]$_.name; position = [int]$_.position; starLevel = [int]$_.starLevel }
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
                                        averagePlacement = Round-Semantic $_.averagePlacement
                                        placementDelta = Round-Semantic $_.placementDelta
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
