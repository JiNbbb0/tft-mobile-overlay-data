$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'optional-reference-tables.ps1')
$script:curlCalls=0; $script:observations=0
$script:response=@('verified-body','REFERENCE_HTTP_STATUS:200'); $script:curlResult=0
function curl.exe {
    $script:curlCalls++
    if ($args -ccontains '--retry-all-errors') { throw 'Unsafe rejection retry policy' }
    if (($args -join ' ') -notmatch '--retry 1 --retry-delay 2 --retry-max-time 30') { throw 'Unbounded transient retry policy' }
    $global:LASTEXITCODE=$script:curlResult
    return $script:response
}
function Write-SourceObservation { param([string]$Url,[string]$Text); $script:observations++ }
function Expect-Rejection([string]$ExpectedCode,[scriptblock]$Action) {
    $actual=''
    try { & $Action | Out-Null } catch { $actual=Get-ReferenceFailureCode $_ }
    if ($actual -cne $ExpectedCode) { throw "Expected $ExpectedCode; got $actual" }
}
if ((Get-OptionalReferenceText 'https://public.test/data' 'WISP_CSV') -cne 'verified-body' -or $script:observations -ne 1) { throw 'Response status contaminated payload or observation' }
$script:response=@('REFERENCE_HTTP_STATUS:403'); $script:curlResult=22
Expect-Rejection 'REFERENCE_FETCH_FAILED:WISP_CSV:HTTP403:CURL22' { Get-OptionalReferenceText 'https://public.test/data' 'WISP_CSV' }
$script:response=@('REFERENCE_HTTP_STATUS:500')
Expect-Rejection 'REFERENCE_FETCH_FAILED:WISP_PAGE:HTTP500:CURL22' { Get-OptionalReferenceText 'https://public.test/data' 'WISP_PAGE' }
$script:response=@('REFERENCE_HTTP_STATUS:000'); $script:curlResult=28
Expect-Rejection 'REFERENCE_FETCH_FAILED:WISP_CSV:HTTP000:CURL28' { Get-OptionalReferenceText 'https://public.test/data' 'WISP_CSV' }
if ($script:curlCalls -ne 4 -or $script:observations -ne 1) { throw 'Failures were retried by the wrapper or recorded as success' }
foreach ($url in @('http://public.test/data','file:///etc/passwd','https://user:password@public.test/data','relative/data')) {
    Expect-Rejection 'REFERENCE_URL_INVALID' { Get-OptionalReferenceText $url }
}
if ($script:curlCalls -ne 4) { throw 'Unsafe URL reached the transport' }
try { throw 'https://private.test/?token=secret /local/path' } catch {
    if ((Get-ReferenceFailureCode $_) -cne 'REFERENCE_VALIDATION_FAILED') { throw 'Failure sanitization leaked private text' }
}
Write-Output 'Reference transport PASS: HTTPS-only, sanitized source/status codes, bounded transient policy, no 403 bypass, no false success.'
