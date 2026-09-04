Set-StrictMode -Version Latest

function Resolve-CurrentSetDisplayName {
    param(
        [AllowEmptyString()][string]$CommunityDragonName,
        [Parameter(Mandatory = $true)][int]$SetNumber,
        [AllowEmptyString()][string]$MetaTftSetName
    )

    $candidate = $CommunityDragonName.Trim()
    $isMismatchedPlaceholder = $false
    if ($candidate -match '^Set\s*(\d+)$') {
        $isMismatchedPlaceholder = [int]$Matches[1] -ne $SetNumber
    }
    if (-not $candidate -or $isMismatchedPlaceholder) {
        if ($MetaTftSetName.Trim()) { return $MetaTftSetName.Trim() }
        return "Set $SetNumber"
    }
    return $candidate
}
