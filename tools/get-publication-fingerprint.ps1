param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string]$ContentFingerprint,
    [Parameter(Mandatory = $true)][string]$SourceTimestampUtc,
    [switch]$ObservationRefresh
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $ObservationRefresh) { Write-Output $ContentFingerprint; exit 0 }
$sourceTimestamp = [DateTimeOffset]::Parse(
    $SourceTimestampUtc,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeUniversal
).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
$identity = "content=$ContentFingerprint|observation=$sourceTimestamp"
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $hash = ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity)) | ForEach-Object { $_.ToString('x2') }) -join ''
} finally {
    $sha.Dispose()
}
Write-Output $hash
