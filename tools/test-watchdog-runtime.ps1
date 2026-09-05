$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Intercept all HTTP calls in this scope. Never call GitHub or require credentials.
& {
    $capture = [Collections.Generic.List[object]]::new()
    $patches = [Collections.Generic.List[object]]::new()
    $fixtureIssues = @()
    function Invoke-RestMethod {
        param($Method, $Uri, $Headers, $TimeoutSec, $ContentType, $Body)
        if ($Uri -notlike 'https://api.github.com/repos/fixture/repo/*') { throw 'Fixture attempted a real request' }
        if ($Method -eq 'Get' -and $Uri -like '*runs?*') {
            return [pscustomobject]@{workflow_runs=@([pscustomobject]@{conclusion='success';updated_at=[DateTimeOffset]::UtcNow.ToString('o');html_url='https://github.com/fixture/repo/actions/runs/1'})}
        }
        if ($Method -eq 'Get' -and $Uri -like '*issues?*') { return @($fixtureIssues) }
        if ($Method -eq 'Post' -and $Uri -like '*/labels') { return [pscustomobject]@{} }
        if ($Method -eq 'Post' -and $Uri -like '*/issues') {
            $capture.Add(($Body | ConvertFrom-Json))
            return [pscustomobject]@{number=1}
        }
        if ($Method -eq 'Patch' -and $Uri -like '*/issues/*') {
            $patches.Add([pscustomobject]@{uri=$Uri; body=($Body | ConvertFrom-Json)})
            return [pscustomobject]@{}
        }
        throw 'Unexpected fixture request'
    }
    $savedSummary = $env:GITHUB_STEP_SUMMARY
    try {
    $env:GITHUB_STEP_SUMMARY = ''
    & (Join-Path $PSScriptRoot 'watch-automation-health.ps1') -Repository fixture/repo -GitHubToken FIXTURE_NOT_A_CREDENTIAL -SourceAgeMinutes 420
    if ($capture.Count -ne 1 -or $capture[0].body -notmatch 'SOURCE_STALE_6H') { throw 'Green workflow and stale source must create one alert' }
    if ($capture[0].body -match 'FIXTURE_NOT_A_CREDENTIAL') { throw 'Credential input leaked into alert' }
    $capture.Clear()
    & (Join-Path $PSScriptRoot 'watch-automation-health.ps1') -Repository fixture/repo -GitHubToken FIXTURE_NOT_A_CREDENTIAL -SourceAgeMinutes 10
    if ($capture.Count -ne 0) { throw 'Healthy verified source must not create alerts' }
    $fixtureIssues = @(1..3 | ForEach-Object { [pscustomobject]@{number=$_;title='[automation-health] TFT data publication requires attention';body='old'} })
    & (Join-Path $PSScriptRoot 'watch-automation-health.ps1') -Repository fixture/repo -GitHubToken FIXTURE_NOT_A_CREDENTIAL -SourceAgeMinutes 10
    if ($patches.Count -ne 3 -or @($patches | Where-Object { $_.body.state -ne 'closed' }).Count) { throw 'Recovery must close every duplicate alert' }
    } finally { $env:GITHUB_STEP_SUMMARY = $savedSummary }
}
Write-Output 'Watchdog runtime fixture PASS: stale alert, healthy silence, duplicate cleanup, sanitized body'
