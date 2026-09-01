$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-TftSourceBackedArtifactDescriptionCandidate {
    param(
        [Parameter(Mandatory = $true)][object]$TargetItem,
        [Parameter(Mandatory = $true)][object[]]$AllItems
    )

    $targetId = [string]$TargetItem.apiName
    if ($targetId -notmatch '(?i)^DA_Artifact_') {
        throw "SOURCE_BACKED_ARTIFACT_TARGET_INVALID id=$targetId"
    }

    $candidates = @(
        $AllItems |
            Where-Object {
                [string]$_.name -eq [string]$TargetItem.name -and
                [string]$_.icon -eq [string]$TargetItem.icon -and
                $_.desc -and
                [string]$_.apiName -notmatch '(?i)(_HR|_Radiant|_Revival)$'
            }
    )
    if ($candidates.Count -ne 1) {
        throw "SOURCE_BACKED_ARTIFACT_DESCRIPTION_AMBIGUOUS id=$targetId candidates=$($candidates.Count)"
    }
    return $candidates[0]
}
