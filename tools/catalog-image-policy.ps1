Set-StrictMode -Version Latest

function Remove-UnreferencedCatalogImages {
    param(
        [Parameter(Mandatory = $true)][string]$ImageRoot,
        [Parameter(Mandatory = $true)][string[]]$ReferencedImagePaths
    )

    $resolvedRoot = [IO.Path]::GetFullPath($ImageRoot)
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) { throw "Catalog image root missing: $resolvedRoot" }
    $referencedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($relativePath in @($ReferencedImagePaths | Where-Object { $_ } | Sort-Object -Unique)) {
        $normalized = ([string]$relativePath).Replace('\','/')
        if ($normalized -notmatch '^tft/images/([a-zA-Z0-9._-]+)$') { throw "Unsafe catalog image path: $normalized" }
        $null = $referencedNames.Add($Matches[1])
    }
    $removed = [Collections.Generic.List[string]]::new()
    foreach ($existingAsset in @(Get-ChildItem -LiteralPath $resolvedRoot -File)) {
        if (-not $referencedNames.Contains($existingAsset.Name)) {
            Remove-Item -Force -LiteralPath $existingAsset.FullName
            $removed.Add($existingAsset.Name)
        }
    }
    return @($removed)
}
