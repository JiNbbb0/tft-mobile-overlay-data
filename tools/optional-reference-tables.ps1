. (Join-Path $PSScriptRoot 'reference-table-contract.ps1')
. (Join-Path $PSScriptRoot 'wisp-strength-contract.ps1')

function Get-OptionalReferenceTables {
    param([string]$RepositoryRoot, [string]$SetId, [string]$Patch, [hashtable]$JapaneseItems, [object]$CurrentSetData=$null)
    $strength = New-UnavailableReferenceTable 'wisp_tiers' 'ウィスプ評価' $SetId $Patch 'MetaTFT以外の現行パッチの強さ評価元は未確認です。価格・出現階級をS/A/B評価に置き換えません。'
    $facts = New-UnavailableReferenceTable 'wisp_reference' 'ウィスプ一覧' $SetId $Patch 'このセット・パッチの価格・効果・条件は未確認です。別パッチの表を流用しません。'
    $coven = New-UnavailableReferenceTable 'coven_cashouts' '魔女の解放' $SetId $Patch '現行パッチの報酬表を検証中です。旧版・PBEの報酬で補完しません。'
    if ($SetId -cnotmatch '^TFTSet[0-9]+$' -or $Patch -cnotmatch '^[0-9]+\.[0-9]+$') { return @() }
    $definitionPath = Join-Path $RepositoryRoot "config/reference-tables/$SetId-$Patch.json"
    if (-not (Test-Path -LiteralPath $definitionPath -PathType Leaf)) { return @() }
    if ($null -ne $CurrentSetData) {
        try {
            $definition = Get-Content -Raw -Encoding UTF8 -LiteralPath $definitionPath | ConvertFrom-Json
            if ([string]$definition.ratingsUrl -cne 'https://api-hc.metatft.com/tft-stat-api/wisp_tiers') { throw 'WISP_STRENGTH_URL_INVALID' }
            $ratings = Get-OptionalReferenceText ([string]$definition.ratingsUrl) 'WISP_STRENGTH' | ConvertFrom-Json
            $strength = ConvertTo-CheckedWispStrengthTable $definition $ratings $CurrentSetData $JapaneseItems $SetId $Patch
            Assert-ReferenceTables @($strength) $SetId $Patch
        } catch {
            Write-Warning ('Optional Wisp strength verification failed; ' + (Get-ReferenceFailureCode $_) + '; no guessed ratings or previous-patch fallback.')
            $strength = New-UnavailableReferenceTable 'wisp_tiers' 'ウィスプ評価' $SetId $Patch '現行セット・パッチに対応する評価を確認できませんでした。別版の評価や推測で補完しません。'
        }
    }
    try {
        $definition = Get-Content -Raw -Encoding UTF8 -LiteralPath $definitionPath | ConvertFrom-Json
        foreach ($url in @($definition.pageUrl, $definition.csvUrl)) {
            if (-not ([uri]$url).IsAbsoluteUri -or ([uri]$url).Scheme -cne 'https') { throw 'REFERENCE_URL_INVALID' }
        }
        # One page plus its explicitly published sheet, once per catalog refresh;
        # no app-to-upstream traffic and no per-rank duplicate requests.
        $page = Get-OptionalReferenceText ([string]$definition.pageUrl) 'WISP_PAGE'
        $csv = Get-OptionalReferenceText ([string]$definition.csvUrl) 'WISP_CSV'
        $facts = ConvertTo-CheckedWispTable $definition $page $csv $JapaneseItems $SetId $Patch
        Assert-ReferenceTables @($strength, $facts, $coven) $SetId $Patch
    } catch {
        Write-Warning ('Optional Wisp reference verification failed; ' + (Get-ReferenceFailureCode $_) + '; keeping compositions available and withholding the table.')
        $facts = New-UnavailableReferenceTable 'wisp_reference' 'ウィスプ一覧' $SetId $Patch '提供元の変更または取得失敗で、この版の表を確認できませんでした。古い値は表示しません。'
    }
    return @($strength, $facts, $coven)
}

function Get-ReferenceFailureCode([object]$Failure) {
    $code = [string]$Failure.Exception.Message
    if ($code -cmatch '^[A-Z][A-Z0-9_:.-]{0,180}$') { return $code }
    # Do not leak response bodies, URLs, local paths or credentials in summaries.
    return 'REFERENCE_VALIDATION_FAILED'
}

function Get-OptionalReferenceText([string]$Url, [ValidatePattern('^[A-Z_]{1,40}$')][string]$SourceLabel='REFERENCE') {
    $lines = @(& curl.exe -L --proto '=https' --proto-redir '=https' --fail --silent --show-error --max-time 25 --max-filesize 4194304 -A 'TFT-Overlay-Reference/1.0' --write-out "`nREFERENCE_HTTP_STATUS:%{http_code}" $Url)
    $curlExit = $LASTEXITCODE
    $status = if ($lines.Count -gt 0 -and $lines[-1] -cmatch '^REFERENCE_HTTP_STATUS:([0-9]{3})$') { $Matches[1] } else { '000' }
    if ($curlExit -ne 0 -or $status -cne '200') { throw "REFERENCE_FETCH_FAILED:${SourceLabel}:HTTP${status}:CURL${curlExit}" }
    $text = if ($lines.Count -gt 1) { $lines[0..($lines.Count-2)] -join "`n" } else { '' }
    if ([Text.Encoding]::UTF8.GetByteCount($text) -gt 4194304) { throw 'REFERENCE_RESPONSE_TOO_LARGE' }
    Write-SourceObservation -Url $Url -Text $text
    return $text
}
