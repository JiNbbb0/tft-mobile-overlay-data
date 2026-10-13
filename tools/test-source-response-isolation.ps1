$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Fault-inject curl's documented retry behavior: stdout cannot be rewound,
# whereas --output replaces the partial response before a successful retry.
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('tft-source-isolation-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$observationRoot = Join-Path $testRoot 'observations'
$userAgent = 'isolated-test'
$script:responseBody = '{"name":"魔女","value":7}'
$script:transportFails = $false
$script:downloadPath = ''
function curl.exe {
    $outputIndex = [Array]::IndexOf($args, '--output')
    $global:LASTEXITCODE = if ($script:transportFails) { 28 } else { 0 }
    if ($outputIndex -lt 0) {
        # Partial first transfer followed by the complete successful retry.
        '{"name":"partial'
        $script:responseBody
    } else {
        $script:downloadPath = [string]$args[$outputIndex + 1]
        [IO.File]::WriteAllText($script:downloadPath, '{"name":"partial', [Text.UTF8Encoding]::new($false))
        if (-not $script:transportFails) {
            [IO.File]::WriteAllText($script:downloadPath, $script:responseBody, [Text.UTF8Encoding]::new($false))
        }
    }
}
try {
    foreach ($scriptName in @('refresh-live-data.ps1', 'refresh-live-data-gated.ps1')) {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $scriptName), [ref]$tokens, [ref]$errors)
        $fn = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-WebText' }, $true)
        if (-not $fn -or $errors.Count) { throw "Cannot extract $scriptName transport" }
        Invoke-Expression $fn.Extent.Text
        $script:transportFails = $false
        $script:downloadPath = ''
        $body = Get-WebText 'https://example.test/catalog.json'
        if ($body -cne $script:responseBody -or ($body | ConvertFrom-Json).name -cne '魔女') { throw "$scriptName mixed or altered response bytes" }
        if (-not $script:downloadPath -or (Test-Path -LiteralPath $script:downloadPath)) { throw "$scriptName leaked successful download" }
        if ($scriptName -eq 'refresh-live-data.ps1') {
            $proof = Get-ChildItem -LiteralPath $observationRoot -Filter '*.json' | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
            $expectedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($body))).ToLowerInvariant()
            if ($proof.responseHash -ne $expectedHash -or $proof.bytes -ne [Text.Encoding]::UTF8.GetByteCount($body)) { throw 'Source evidence hash differs from successful response' }
        }
        $proofCount = @(Get-ChildItem -LiteralPath $observationRoot -Filter '*.json').Count
        $script:transportFails = $true
        $failed = $false
        try { Get-WebText 'https://example.test/failure.json' | Out-Null } catch { $failed = $true }
        if (-not $failed -or (Test-Path -LiteralPath $script:downloadPath)) { throw "$scriptName accepted failed transfer or leaked partial file" }
        if (@(Get-ChildItem -LiteralPath $observationRoot -Filter '*.json').Count -ne $proofCount) { throw 'Failed transfer wrote trusted source evidence' }
    }
    Write-Output 'Source response isolation PASS: both production paths, retry, UTF-8, hash, failure and cleanup'
} finally {
    Remove-Item Function:\curl.exe
    # Only the GUID-named fixture directory created above is disposable.
    if ([IO.Path]::GetFullPath($testRoot).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
