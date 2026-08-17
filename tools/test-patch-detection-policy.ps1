$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'patch-detection-policy.ps1')

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "$Message Expected=$Expected Actual=$Actual" }
}

$english = '<a href="/en-us/news/game-updates/teamfight-tactics-patch-17-9-notes/">Teamfight Tactics patch 17.9</a>'
$japanese = '<a href="/ja-jp/news/game-updates/teamfight-tactics-patch-17-10-notes/">パッチ 17.10</a>'
Assert-Equal '17.10' (Resolve-LatestTftPatch -Documents @($english, $japanese)) 'Newest official patch must win across localized documents.'
Assert-Equal '18.1' (Resolve-LatestTftPatch -Documents @('<h2>Teamfight Tactics patch 18.1</h2>')) 'Visible-title fallback must work.'

$failed = $false
try { Resolve-LatestTftPatch -Documents @('<html>format changed</html>') | Out-Null } catch { $failed = $true }
Assert-Equal $true $failed 'Unknown official formats must fail closed.'

Write-Output 'Patch detection policy tests passed.'
