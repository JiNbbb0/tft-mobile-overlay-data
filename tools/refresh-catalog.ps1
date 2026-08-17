param(
    [string]$SetId = "TFTSet17",
    [int]$SetNumber = 17,
    [string]$SetNameJa = "スペースゴッズ",
    [string]$SetNameEn = "Space Gods",
    [string]$TftPatch = "17.8",
    [string]$RepositoryRootOverride = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Net.Http
. (Join-Path $PSScriptRoot 'catalog-image-policy.ps1')

$RepositoryRoot = if ($RepositoryRootOverride) {
    [IO.Path]::GetFullPath($RepositoryRootOverride)
} else {
    Split-Path -Parent $PSScriptRoot
}
$AssetRoot = Join-Path $RepositoryRoot "source/current/tft"
$ImageRoot = Join-Path $AssetRoot "images"
$ReportRoot = Join-Path $RepositoryRoot "reports"
$CatalogPath = Join-Path $AssetRoot "tft_catalog.json"
$ManifestPath = Join-Path $RepositoryRoot "source/current/DATA_SOURCE_MANIFEST.json"
$ObservationRoot = Join-Path $RepositoryRoot "build/source-observations"
$FetchedAtUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
$UserAgent = "TFT-Mobile-Overlay-Data/1.0 public-catalog-refresh"

$Sources = [ordered]@{
    riotVersions = "https://ddragon.leagueoflegends.com/api/versions.json"
    riotPatch = "https://teamfighttactics.leagueoflegends.com/en-us/news/tags/patch-notes/"
    riotSetOverview = "https://teamfighttactics.leagueoflegends.com/en-us/news/"
    riotTftPolicy = "https://developer.riotgames.com/docs/tft"
    riotLegal = "https://www.riotgames.com/en/legal"
    communityDragonDocs = "https://communitydragon.org/documentation/assets"
    communityDragonJa = "https://raw.communitydragon.org/latest/cdragon/tft/ja_jp.json"
    communityDragonEn = "https://raw.communitydragon.org/latest/cdragon/tft/en_us.json"
    communityDragonChampionBinTemplate = "https://raw.communitydragon.org/latest/game/characters/{0}.cdtb.bin.json"
}

$Client = [Net.Http.HttpClient]::new()
$Client.Timeout = [TimeSpan]::FromSeconds(120)
$Client.DefaultRequestHeaders.UserAgent.ParseAdd($UserAgent)

function Get-Text {
    param([Parameter(Mandatory = $true)][string]$Url)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $text = $Client.GetStringAsync($Url).GetAwaiter().GetResult()
            Write-SourceObservation -Url $Url -Text $text
            return $text
        } catch {
            if ($attempt -eq 3) { throw }
            Start-Sleep -Seconds $attempt
        }
    }
}

function Write-SourceObservation {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Text
    )
    New-Item -ItemType Directory -Force -Path $ObservationRoot | Out-Null
    $sha = [Security.Cryptography.SHA256]::Create()
    $urlBytes = [Text.Encoding]::UTF8.GetBytes($Url)
    $urlKey = ($sha.ComputeHash($urlBytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $responseHash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    $sha.Dispose()
    $record = [ordered]@{
        sourceUrl = $Url
        fetchedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        responseHash = $responseHash
        bytes = [int64]$bytes.Length
    }
    [IO.File]::WriteAllText(
        (Join-Path $ObservationRoot "$urlKey.json"),
        (($record | ConvertTo-Json).Replace("`r`n", "`n") + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
}

function Get-Json {
    param([Parameter(Mandatory = $true)][string]$Url)
    return (Get-Text -Url $Url) | ConvertFrom-Json
}

function Normalize-Text {
    param(
        [AllowNull()][object]$Value,
        [AllowNull()][object]$Effects
    )
    if ($null -eq $Value) { return "" }
    $text = [string]$Value
    $effectValues = @{}
    if ($null -ne $Effects) {
        foreach ($property in $Effects.PSObject.Properties) {
            $effectValues[[string]$property.Name.ToLowerInvariant()] = $property.Value
            $replacement = if ($property.Value -is [Array]) {
                (@($property.Value) | ForEach-Object { Format-AbilityNumber -Value ([double]$_) }) -join "/"
            } elseif ($property.Value -is [ValueType]) {
                Format-AbilityNumber -Value ([double]$property.Value)
            } else {
                [string]$property.Value
            }
            $text = $text -replace [regex]::Escape("@$($property.Name)@"), $replacement
        }
    }
    $text = [regex]::Replace($text, '@([^@]+)@', {
        param($match)
        $expression = [string]$match.Groups[1].Value
        if ($expression -match '^([A-Za-z0-9_]+)(?:\*([0-9.]+))?$') {
            $key = [string]$Matches[1].ToLowerInvariant()
            $multiplier = if ($Matches[2]) { [double]$Matches[2] } else { 1.0 }
            if ($effectValues.ContainsKey($key)) {
                $rawValues = @($effectValues[$key])
                return (@($rawValues | ForEach-Object {
                    Format-AbilityNumber -Value ([double]$_ * $multiplier)
                }) -join '/')
            }
        }
        if ($expression -match '(?i)TFTUnitProperty|Stage|Current') { return '戦闘中の値' }
        return '可変値'
    })
    $text = $text -replace '(?i)<br\s*/?>', "`n"
    $text = $text -replace '<[^>]+>', ''
    $text = $text -replace '\{\{TFT17_SpaceGroove_TheGroove\}\}', '「グルーヴ」'
    $text = $text -replace '\{\{TFT_Keyword_Chill\}\}', '冷気'
    $text = $text -replace '\{\{[^}]+\}\}', '特殊効果'
    $iconLabels = [ordered]@{
        '%i:scaleAP%' = '[魔力]'
        '%i:scaleAD%' = '[攻撃力]'
        '%i:TFTBaseAD%' = '[攻撃力]'
        '%i:scaleArmor%' = '[物理防御]'
        '%i:scaleMR%' = '[魔法防御]'
        '%i:scaleHealth%' = '[体力]'
        '%i:scaleAS%' = '[攻撃速度]'
        '%i:scaleRange%' = '[射程]'
        '%i:set14AmpIcon%' = '[ミィプ]'
    }
    foreach ($icon in $iconLabels.Keys) {
        $text = $text.Replace([string]$icon, [string]$iconLabels[$icon])
    }
    $text = $text -replace '(?i)%i:goldCoins%', 'ゴールド'
    $text = $text -replace '(?i)%i:[^%]+%', ''
    $text = [Net.WebUtility]::HtmlDecode($text)
    return (($text -replace '[ \t]+', ' ') -replace "(`r?`n){3,}", "`n`n").Trim()
}

function Get-PropertyValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Format-AbilityNumber {
    param([Parameter(Mandatory = $true)][double]$Value)
    $rounded = [Math]::Round($Value, 2)
    if ([Math]::Abs($rounded - [Math]::Round($rounded)) -lt 0.0001) {
        return ([int][Math]::Round($rounded)).ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    return $rounded.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)
}

function Format-AbilityValues {
    param(
        [AllowNull()][object]$Values,
        [double]$Multiplier = 1.0,
        [switch]$ScaleStatRatio
    )
    $all = @($Values)
    if ($all.Count -eq 0) { return '' }
    $starValues = if ($all.Count -ge 5) { @($all[1..4]) } elseif ($all.Count -ge 4) { @($all[0..3]) } else { @($all) }
    $formatted = @($starValues | ForEach-Object {
        $numeric = [double]$_
        $statMultiplier = if ($ScaleStatRatio -and [Math]::Abs($numeric) -le 10) { 100.0 } else { 1.0 }
        Format-AbilityNumber -Value ($numeric * $Multiplier * $statMultiplier)
    })
    if (@($formatted | Select-Object -Unique).Count -eq 1) { return [string]$formatted[0] }
    return ($formatted -join '/')
}

function Resolve-FormulaNode {
    param(
        [AllowNull()][object]$Node,
        [Parameter(Mandatory = $true)][hashtable]$DataValues,
        [Parameter(Mandatory = $true)][object]$Calculations,
        [Parameter(Mandatory = $true)][hashtable]$Seen
    )
    if ($null -eq $Node) { return '' }
    if ($Node -is [Array]) {
        return (@($Node | ForEach-Object { Resolve-FormulaNode -Node $_ -DataValues $DataValues -Calculations $Calculations -Seen $Seen } | Where-Object { $_ }) -join ' + ')
    }
    if ($Node -isnot [pscustomobject]) {
        if ($Node -is [ValueType]) { return Format-AbilityNumber -Value ([double]$Node) }
        return ''
    }

    $dataValueName = Get-PropertyValue -Object $Node -Name 'mDataValue'
    if ($dataValueName -and $DataValues.ContainsKey([string]$dataValueName)) {
        $hasStatScale = $null -ne (Get-PropertyValue -Object $Node -Name 'mStat')
        return Format-AbilityValues -Values $DataValues[[string]$dataValueName] -ScaleStatRatio:$hasStatScale
    }
    $calculationKey = Get-PropertyValue -Object $Node -Name 'mSpellCalculationKey'
    if ($calculationKey) {
        return Resolve-Calculation -Key ([string]$calculationKey) -DataValues $DataValues -Calculations $Calculations -Seen $Seen
    }
    $number = Get-PropertyValue -Object $Node -Name 'mNumber'
    if ($null -ne $number) { return Format-AbilityNumber -Value ([double]$number) }

    $subpart = Get-PropertyValue -Object $Node -Name 'mSubpart'
    if ($subpart) {
        $subpartDataValue = Get-PropertyValue -Object $subpart -Name 'mDataValue'
        $hasStatScale = $null -ne (Get-PropertyValue -Object $Node -Name 'mStat')
        if ($hasStatScale -and $subpartDataValue -and $DataValues.ContainsKey([string]$subpartDataValue)) {
            return Format-AbilityValues -Values $DataValues[[string]$subpartDataValue] -ScaleStatRatio
        }
        return Resolve-FormulaNode -Node $subpart -DataValues $DataValues -Calculations $Calculations -Seen $Seen
    }
    $subparts = Get-PropertyValue -Object $Node -Name 'mSubparts'
    if ($subparts) {
        return (@($subparts | ForEach-Object { Resolve-FormulaNode -Node $_ -DataValues $DataValues -Calculations $Calculations -Seen $Seen } | Where-Object { $_ }) -join ' + ')
    }

    $left = Get-PropertyValue -Object $Node -Name 'mPart1'
    if (-not $left) { $left = Get-PropertyValue -Object $Node -Name 'part1' }
    $right = Get-PropertyValue -Object $Node -Name 'mPart2'
    if (-not $right) { $right = Get-PropertyValue -Object $Node -Name 'part2' }
    if ($left -or $right) {
        $leftText = Resolve-FormulaNode -Node $left -DataValues $DataValues -Calculations $Calculations -Seen $Seen
        $rightText = Resolve-FormulaNode -Node $right -DataValues $DataValues -Calculations $Calculations -Seen $Seen
        if ($leftText -and $rightText) { return "($leftText)×($rightText)" }
        return "$leftText$rightText"
    }
    return ''
}

function Resolve-Calculation {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][hashtable]$DataValues,
        [Parameter(Mandatory = $true)][object]$Calculations,
        [Parameter(Mandatory = $true)][hashtable]$Seen
    )
    if ($Seen.ContainsKey($Key)) { return '' }
    $property = $Calculations.PSObject.Properties[$Key]
    if (-not $property) { return '' }
    $nextSeen = @{} + $Seen
    $nextSeen[$Key] = $true
    $calculation = $property.Value

    $modifiedKey = Get-PropertyValue -Object $calculation -Name 'mModifiedGameCalculation'
    if ($modifiedKey) {
        $base = Resolve-Calculation -Key ([string]$modifiedKey) -DataValues $DataValues -Calculations $Calculations -Seen $nextSeen
        $multiplier = Resolve-FormulaNode -Node (Get-PropertyValue -Object $calculation -Name 'mMultiplier') -DataValues $DataValues -Calculations $Calculations -Seen $nextSeen
        if ($base -and $multiplier) { return "($base)×($multiplier)" }
        return "$base$multiplier"
    }
    return Resolve-FormulaNode -Node (Get-PropertyValue -Object $calculation -Name 'mFormulaParts') -DataValues $DataValues -Calculations $Calculations -Seen $nextSeen
}

function Get-PrimarySpellContext {
    param([Parameter(Mandatory = $true)][object]$BinJson)
    $entries = @($BinJson.PSObject.Properties.Value)
    $record = @($entries | Where-Object { Get-PropertyValue -Object $_ -Name 'spells' } | Select-Object -First 1)
    $spellEntry = $null
    if ($record.Count -gt 0) {
        $spellRef = @((Get-PropertyValue -Object $record[0] -Name 'spells')) | Where-Object { $_ -and [string]$_ -ne '{00000000}' } | Select-Object -First 1
        if ($spellRef) {
            $spellProperty = $BinJson.PSObject.Properties[[string]$spellRef]
            if ($spellProperty) { $spellEntry = $spellProperty.Value }
        }
    }
    if (-not $spellEntry) {
        $spellEntry = @($entries | Where-Object {
            $spell = Get-PropertyValue -Object $_ -Name 'mSpell'
            $spell -and (Get-PropertyValue -Object $spell -Name 'mSpellCalculations')
        } | Select-Object -First 1)
        if ($spellEntry -is [Array]) { $spellEntry = $spellEntry | Select-Object -First 1 }
    }
    if (-not $spellEntry) { return $null }
    $spell = Get-PropertyValue -Object $spellEntry -Name 'mSpell'
    return [pscustomobject]@{
        dataValues = @(Get-PropertyValue -Object $spell -Name 'DataValues') + @(Get-PropertyValue -Object $spell -Name 'mDataValues')
        calculations = Get-PropertyValue -Object $spell -Name 'mSpellCalculations'
    }
}

function Resolve-AbilityDescription {
    param(
        [Parameter(Mandatory = $true)][object]$Champion,
        [Parameter(Mandatory = $true)][string]$BinUrl
    )
    $bin = Get-Json -Url $BinUrl
    $spellContext = Get-PrimarySpellContext -BinJson $bin
    $dataValues = @{}
    $spellVariables = if ($spellContext) { @($spellContext.dataValues) } else { @() }
    foreach ($variable in @($Champion.ability.variables) + $spellVariables) {
        $name = Get-PropertyValue -Object $variable -Name 'name'
        if (-not $name) { $name = Get-PropertyValue -Object $variable -Name 'mName' }
        $values = Get-PropertyValue -Object $variable -Name 'value'
        if ($null -eq $values) { $values = Get-PropertyValue -Object $variable -Name 'values' }
        if ($null -eq $values) { $values = Get-PropertyValue -Object $variable -Name 'mValues' }
        if ($name -and $null -ne $values) { $dataValues[[string]$name] = @($values) }
    }

    $description = [string]$Champion.ability.desc
    foreach ($match in @([regex]::Matches($description, '@([^@]+)@'))) {
        $token = [string]$match.Groups[1].Value
        $baseToken = $token
        $multiplier = 1.0
        if ($token -match '^(.+)\*100$') { $baseToken = [string]$Matches[1]; $multiplier = 100.0 }
        $replacement = ''
        if ($dataValues.ContainsKey($baseToken)) {
            $replacement = Format-AbilityValues -Values $dataValues[$baseToken] -Multiplier $multiplier
        } elseif ($spellContext -and $spellContext.calculations -and $spellContext.calculations.PSObject.Properties[$baseToken]) {
            $replacement = Resolve-Calculation -Key $baseToken -DataValues $dataValues -Calculations $spellContext.calculations -Seen @{}
        } elseif ($baseToken.StartsWith('Modified') -and $dataValues.ContainsKey($baseToken.Substring('Modified'.Length))) {
            $replacement = Format-AbilityValues -Values $dataValues[$baseToken.Substring('Modified'.Length)] -Multiplier $multiplier
        } elseif ($baseToken -match '^TFTUnitProperty') {
            $replacement = '戦闘中に変動'
        } elseif ($baseToken -match '^Augmented') {
            $replacement = ''
        } else {
            # CommunityDragon can expose a new playable unit before every derived
            # tooltip value is available in the champion bin. Never invent a
            # number and never block the entire live-meta publication for it.
            $replacement = '戦闘中に変動'
        }
        $description = $description.Replace([string]$match.Value, [string]$replacement)
    }
    return Normalize-Text -Value $description -Effects $null
}

function Convert-AssetUrl {
    param([AllowNull()][string]$AssetPath)
    if (-not $AssetPath) { return "" }
    $normalized = $AssetPath.Replace('\', '/').TrimStart('/').ToLowerInvariant()
    $normalized = $normalized -replace '\.(tex|dds)$', '.png'
    if ($normalized.StartsWith('lol-game-data/assets/')) {
        $relative = $normalized.Substring('lol-game-data/assets/'.Length)
        return "https://raw.communitydragon.org/latest/plugins/rcp-be-lol-game-data/global/default/$relative"
    }
    if ($normalized.StartsWith('assets/')) {
        return "https://raw.communitydragon.org/latest/game/$normalized"
    }
    return "https://raw.communitydragon.org/latest/game/$normalized"
}

function Get-UrlHash {
    param([Parameter(Mandatory = $true)][string]$Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').Substring(0, 24).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

$DownloadedByUrl = @{}
$DownloadFailures = [Collections.Generic.List[object]]::new()
$PendingDownloads = [Collections.Generic.List[object]]::new()

function Complete-PendingDownloads {
    if ($PendingDownloads.Count -eq 0) { return }

    $tasks = [Threading.Tasks.Task[]]@($PendingDownloads | ForEach-Object { $_.task })
    try {
        [Threading.Tasks.Task]::WaitAll($tasks)
    } catch {
        # Individual failures are retried below so one missing asset does not cancel the batch.
    }

    foreach ($pending in @($PendingDownloads)) {
        $bytes = if ($pending.task.Status -eq [Threading.Tasks.TaskStatus]::RanToCompletion) {
            [byte[]]$pending.task.Result
        } else {
            $null
        }
        for ($attempt = 1; $attempt -le 2 -and ($null -eq $bytes -or $bytes.Length -lt 8); $attempt++) {
            try {
                $bytes = $Client.GetByteArrayAsync([string]$pending.url).GetAwaiter().GetResult()
            } catch {
                if ($attempt -lt 2) { Start-Sleep -Milliseconds 250 }
            }
        }
        if ($null -eq $bytes -or $bytes.Length -lt 8) {
            $DownloadFailures.Add([pscustomobject]@{
                category = [string]$pending.category
                id = [string]$pending.id
                reason = "取得失敗"
                url = [string]$pending.url
            })
            continue
        }
        [IO.File]::WriteAllBytes([string]$pending.destination, $bytes)
    }
    $PendingDownloads.Clear()
}

function Save-Asset {
    param(
        [AllowNull()][string]$AssetPath,
        [Parameter(Mandatory = $true)][string]$OwnerId,
        [Parameter(Mandatory = $true)][string]$Category
    )
    $url = Convert-AssetUrl -AssetPath $AssetPath
    if (-not $url) {
        $DownloadFailures.Add([pscustomobject]@{ category = $Category; id = $OwnerId; reason = "画像パスなし" })
        return ""
    }
    if ($DownloadedByUrl.ContainsKey($url)) { return [string]$DownloadedByUrl[$url] }

    $fileName = (Get-UrlHash -Value $url) + ".png"
    $relativePath = "tft/images/$fileName"
    $destination = Join-Path $ImageRoot $fileName
    if (-not (Test-Path -LiteralPath $destination)) {
        $PendingDownloads.Add([pscustomobject]@{
            category = $Category
            id = $OwnerId
            url = $url
            destination = $destination
            task = $Client.GetByteArrayAsync($url)
        })
    }
    $DownloadedByUrl[$url] = $relativePath
    if ($PendingDownloads.Count -ge 8) { Complete-PendingDownloads }
    return $relativePath
}

function Get-ItemCategory {
    param([Parameter(Mandatory = $true)][object]$Item)
    $id = [string]$Item.apiName
    $name = [string]$Item.name
    if ($id -match 'Consumable|Remover|Reroller|Duplicator|Reforger|Armory|Anvil') { return "消耗品" }
    if ($name -match '紋章' -or $id -match 'Emblem') { return "紋章" }
    if ($id -match 'Radiant|TFT5_Radiant') { return "レディアント" }
    if ($id -match 'Ornn|Artifact') { return "アーティファクト" }
    if ($id -match 'Support') { return "サポート" }
    if (@($Item.from).Count -eq 2) { return "通常完成アイテム" }
    if ($id -match '^TFT_Item_(BFSword|RecurveBow|NeedlesslyLargeRod|TearOfTheGoddess|ChainVest|NegatronCloak|GiantsBelt|SparringGloves|Spatula)$') { return "素材アイテム" }
    if ($id -match ("^TFT{0}_" -f $SetNumber)) { return "セット固有" }
    return "その他"
}

function Get-AugmentRarity {
    param([Parameter(Mandatory = $true)][object]$Augment)
    $icon = [string]$Augment.icon
    if ($icon -match '(?i)(_III|Prismatic|3)\.tex$') { return "プリズム" }
    if ($icon -match '(?i)(_II|Gold|2)\.tex$') { return "ゴールド" }
    if ($icon -match '(?i)(_I|Silver|1)\.tex$') { return "シルバー" }
    return "分類未取得"
}

function To-SearchKeywords {
    param([string[]]$Values)
    return (@($Values | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique) -join ' ')
}

New-Item -ItemType Directory -Force -Path $AssetRoot, $ImageRoot | Out-Null

$versions = Get-Json -Url $Sources.riotVersions
$dataDragonVersion = [string]@($versions)[0]
$ja = Get-Json -Url $Sources.communityDragonJa
$en = Get-Json -Url $Sources.communityDragonEn
$setJa = $ja.setData | Where-Object { $_.mutator -eq $SetId } | Select-Object -First 1
$setEn = $en.setData | Where-Object { $_.mutator -eq $SetId } | Select-Object -First 1
if (-not $setJa -or -not $setEn) { throw "Set $SetId was not found in CommunityDragon." }

$enChampionMap = @{}
foreach ($entry in $setEn.champions) { $enChampionMap[[string]$entry.apiName] = $entry }
$enTraitMap = @{}
foreach ($entry in $setEn.traits) { $enTraitMap[[string]$entry.apiName] = $entry }
$jaItemMap = @{}
foreach ($entry in $ja.items) { if ($entry.apiName) { $jaItemMap[[string]$entry.apiName] = $entry } }
$enItemMap = @{}
foreach ($entry in $en.items) { if ($entry.apiName) { $enItemMap[[string]$entry.apiName] = $entry } }

$playableChampions = @(
    $setJa.champions |
        Where-Object {
            $_.apiName -match "^TFT${SetNumber}_" -and
            $_.cost -ge 1 -and $_.cost -le 5 -and
            $_.name -and @($_.traits).Count -gt 0
        } |
        Sort-Object cost, name
)
$championIdsByTraitName = @{}
foreach ($champion in $playableChampions) {
    foreach ($traitName in @($champion.traits)) {
        if (-not $championIdsByTraitName.ContainsKey([string]$traitName)) {
            $championIdsByTraitName[[string]$traitName] = [Collections.Generic.List[string]]::new()
        }
        $championIdsByTraitName[[string]$traitName].Add([string]$champion.apiName)
    }
}

$champions = [Collections.Generic.List[object]]::new()
$processed = 0
foreach ($champion in $playableChampions) {
    $id = [string]$champion.apiName
    $english = if ($enChampionMap.ContainsKey($id)) { $enChampionMap[$id] } else { $null }
    $image = Save-Asset -AssetPath ([string]$champion.squareIcon) -OwnerId $id -Category "champion"
    $abilityIcon = Save-Asset -AssetPath ([string]$champion.ability.icon) -OwnerId "$id-ability" -Category "ability"
    $englishName = if ($english) { [string]$english.name } else { "" }
    $championBinUrl = [string]::Format(
        [string]$Sources.communityDragonChampionBinTemplate,
        $id.ToLowerInvariant()
    )
    $abilityDescription = Resolve-AbilityDescription -Champion $champion -BinUrl $championBinUrl
    $searchValues = @([string]$champion.name, $englishName, $id) + @($champion.traits)
    $champions.Add([pscustomobject][ordered]@{
        id = $id
        nameJa = [string]$champion.name
        nameEn = if ($english) { [string]$english.name } else { "" }
        cost = [int]$champion.cost
        image = $image
        traits = @($champion.traits | Where-Object { $_ })
        ability = [ordered]@{
            nameJa = [string]$champion.ability.name
            nameEn = if ($english) { [string]$english.ability.name } else { "" }
            descriptionJa = $abilityDescription
            valuesSource = 'CommunityDragon latest TFT JSON + champion game bin calculations'
            icon = $abilityIcon
        }
        mana = [ordered]@{ initial = [int]$champion.stats.initialMana; maximum = [int]$champion.stats.mana }
        stats = [ordered]@{
            hp = [double]$champion.stats.hp
            attackDamage = [double]$champion.stats.damage
            attackSpeed = [double]$champion.stats.attackSpeed
            armor = [double]$champion.stats.armor
            magicResist = [double]$champion.stats.magicResist
            range = [double]$champion.stats.range
        }
        searchKeywords = To-SearchKeywords -Values $searchValues
    })
    $processed++
    if ($processed % 25 -eq 0) { Write-Output "Champion assets: $processed/$($playableChampions.Count)" }
}

$traitNames = @($playableChampions.traits | Sort-Object -Unique)
$traits = [Collections.Generic.List[object]]::new()
foreach ($traitName in $traitNames) {
    $trait = $setJa.traits | Where-Object { $_.name -eq $traitName } | Select-Object -First 1
    if (-not $trait) { continue }
    $id = [string]$trait.apiName
    $english = if ($enTraitMap.ContainsKey($id)) { $enTraitMap[$id] } else { $null }
    $englishName = if ($english) { [string]$english.name } else { "" }
    $image = Save-Asset -AssetPath ([string]$trait.icon) -OwnerId $id -Category "trait"
    $steps = foreach ($effect in @($trait.effects)) {
        [pscustomobject][ordered]@{
            minimumUnits = [int]$effect.minUnits
            maximumUnits = [int]$effect.maxUnits
            style = [int]$effect.style
            variables = $effect.variables
        }
    }
    $traits.Add([pscustomobject][ordered]@{
        id = $id
        nameJa = [string]$trait.name
        nameEn = if ($english) { [string]$english.name } else { "" }
        image = $image
        descriptionJa = Normalize-Text -Value $trait.desc -Effects $null
        activationLevels = @($steps)
        championIds = @($championIdsByTraitName[[string]$traitName])
        searchKeywords = To-SearchKeywords -Values @([string]$trait.name, $englishName, $id)
    })
}

$setItemIds = @{}
foreach ($id in @($setJa.items)) { $setItemIds[[string]$id] = $true }
$augmentIds = @{}
foreach ($id in @($setJa.augments)) { $augmentIds[[string]$id] = $true }
$candidateItems = @(
    $ja.items |
        Where-Object {
            $setItemIds.ContainsKey([string]$_.apiName) -and
            -not $augmentIds.ContainsKey([string]$_.apiName) -and
            $_.name -and $_.desc -and $_.icon
        } |
        Sort-Object name, apiName
)

$items = [Collections.Generic.List[object]]::new()
$processed = 0
foreach ($item in $candidateItems) {
    $id = [string]$item.apiName
    $english = if ($enItemMap.ContainsKey($id)) { $enItemMap[$id] } else { $null }
    $englishName = if ($english) { [string]$english.name } else { "" }
    $image = Save-Asset -AssetPath ([string]$item.icon) -OwnerId $id -Category "item"
    $items.Add([pscustomobject][ordered]@{
        id = $id
        nameJa = Normalize-Text -Value $item.name -Effects $item.effects
        nameEn = if ($english) { Normalize-Text -Value $english.name -Effects $english.effects } else { "" }
        image = $image
        descriptionJa = Normalize-Text -Value $item.desc -Effects $item.effects
        stats = $item.effects
        recipe = @($item.from | Where-Object { $_ })
        restrictions = [ordered]@{
            unique = [bool]$item.unique
            composition = @($item.composition | Where-Object { $_ })
            incompatibleTraits = @($item.incompatibleTraits | Where-Object { $_ })
        }
        category = Get-ItemCategory -Item $item
        searchKeywords = To-SearchKeywords -Values @([string]$item.name, $englishName, $id)
    })
    $processed++
    if ($processed % 100 -eq 0) { Write-Output "Item assets: $processed/$($candidateItems.Count)" }
}

$augments = [Collections.Generic.List[object]]::new()
$skippedAugments = [Collections.Generic.List[object]]::new()
$processed = 0
foreach ($augmentId in @($setJa.augments | Sort-Object -Unique)) {
    $id = [string]$augmentId
    if (-not $jaItemMap.ContainsKey($id)) {
        $skippedAugments.Add([pscustomobject]@{ id = $id; reason = "日本語データに定義なし" })
        continue
    }
    $augment = $jaItemMap[$id]
    if (-not $augment.name -or -not $augment.desc -or -not $augment.icon) {
        $skippedAugments.Add([pscustomobject]@{ id = $id; reason = "名前・説明・画像のいずれかが欠損" })
        continue
    }
    $english = if ($enItemMap.ContainsKey($id)) { $enItemMap[$id] } else { $null }
    $englishName = if ($english) { [string]$english.name } else { "" }
    $searchValues = @([string]$augment.name, $englishName, $id) + @($augment.associatedTraits)
    $image = Save-Asset -AssetPath ([string]$augment.icon) -OwnerId $id -Category "augment"
    $augments.Add([pscustomobject][ordered]@{
        id = $id
        nameJa = Normalize-Text -Value $augment.name -Effects $augment.effects
        nameEn = if ($english) { Normalize-Text -Value $english.name -Effects $english.effects } else { "" }
        image = $image
        rarity = Get-AugmentRarity -Augment $augment
        descriptionJa = Normalize-Text -Value $augment.desc -Effects $augment.effects
        associatedTraits = @($augment.associatedTraits | Where-Object { $_ })
        associatedChampionIds = @()
        associatedItemIds = @($augment.composition | Where-Object { $_ })
        searchKeywords = To-SearchKeywords -Values $searchValues
    })
    $processed++
    if ($processed % 75 -eq 0) { Write-Output "Augment assets: $processed/$(@($setJa.augments).Count)" }
}

Complete-PendingDownloads

$catalog = [pscustomobject][ordered]@{
    schemaVersion = 1
    fetchedAtUtc = $FetchedAtUtc
    set = [ordered]@{
        id = $SetId
        number = $SetNumber
        nameJa = $SetNameJa
        nameEn = $SetNameEn
        tftPatch = $TftPatch
        dataDragonVersion = $dataDragonVersion
        modes = @("通常", "ハイパーロール", "ダブルアップ", "トッカーの試練を含むPvE")
        mechanics = @()
    }
    sources = $Sources
    champions = @($champions)
    traits = @($traits)
    items = @($items)
    augments = @($augments)
    systemData = [ordered]@{
        shopOdds = @()
        experienceTable = @()
        stageDefinitions = @()
        status = "公式またはCommunityDragonの統一構造から未取得"
    }
}

$json = $catalog | ConvertTo-Json -Depth 30
[IO.File]::WriteAllText($CatalogPath, ($json.Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))

$allRecords = @($champions) + @($traits) + @($items) + @($augments)
$missingName = @($allRecords | Where-Object { -not $_.nameJa })
$missingDescription = @($champions | Where-Object { -not $_.ability.descriptionJa }) +
    @($traits | Where-Object { -not $_.descriptionJa }) +
    @($items | Where-Object { -not $_.descriptionJa }) +
    @($augments | Where-Object { -not $_.descriptionJa })
$missingImage = @(
    $allRecords | Where-Object {
        -not $_.image -or
        -not (Test-Path -LiteralPath (Join-Path $AssetRoot ([string]$_.image -replace '^tft/', '')))
    }
)
$referencedImagePaths = @(
    @($champions.image) + @($champions | ForEach-Object { $_.ability.icon }) +
    @($traits.image) + @($items.image) + @($augments.image)
) | Where-Object { $_ } | Sort-Object -Unique

# Reuse unchanged assets during generation, then remove only files that the
# newly generated catalog no longer references. The refresh coordinator keeps
# a complete source backup, so a later validation failure still restores the
# previous known-good set atomically.
if ($missingImage.Count -gt 0 -or $DownloadFailures.Count -gt 0) {
    throw "Catalog images are incomplete; refusing to prune the previous asset set. Missing=$($missingImage.Count) Downloads=$($DownloadFailures.Count)"
}
$prunedImageNames = @(Remove-UnreferencedCatalogImages -ImageRoot $ImageRoot -ReferencedImagePaths $referencedImagePaths)
$assetFiles = @(Get-ChildItem -LiteralPath $ImageRoot -File -Filter *.png)
$badPng = [Collections.Generic.List[string]]::new()
foreach ($file in $assetFiles) {
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    if ($bytes.Length -lt 8 -or $bytes[0] -ne 137 -or $bytes[1] -ne 80 -or $bytes[2] -ne 78 -or $bytes[3] -ne 71) {
        $badPng.Add($file.Name)
    }
}
$duplicateIds = @($allRecords | Group-Object id | Where-Object Count -gt 1)
$duplicateContentHashes = @(
    $assetFiles |
        ForEach-Object { [pscustomobject]@{ path = $_.Name; hash = (Get-FileHash -Algorithm SHA256 $_.FullName).Hash } } |
        Group-Object hash |
        Where-Object Count -gt 1
)
$catalogRoundTripValid = $true
try {
    $null = $json | ConvertFrom-Json
} catch {
    $catalogRoundTripValid = $false
}
$mojibakeMatches = @([regex]::Matches($json, [char]0xFFFD))
$championIdSet = @{}
foreach ($champion in $champions) { $championIdSet[[string]$champion.id] = $true }
$traitNameSet = @{}
foreach ($trait in $traits) { $traitNameSet[[string]$trait.nameJa] = $true }
$invalidChampionTraitReferences = @(
    $champions | ForEach-Object {
        $champion = $_
        @($champion.traits) | Where-Object { -not $traitNameSet.ContainsKey([string]$_) } | ForEach-Object {
            "$($champion.id) -> $_"
        }
    }
)
$invalidTraitChampionReferences = @(
    $traits | ForEach-Object {
        $trait = $_
        @($trait.championIds) | Where-Object { -not $championIdSet.ContainsKey([string]$_) } | ForEach-Object {
            "$($trait.id) -> $_"
        }
    }
)
$invalidRecipeReferences = @(
    $items | ForEach-Object {
        $item = $_
        @($item.recipe) | Where-Object { -not $jaItemMap.ContainsKey([string]$_) } | ForEach-Object {
            "$($item.id) -> $_"
        }
    }
)
$outOfSetChampions = @($champions | Where-Object { $_.id -notmatch "^TFT${SetNumber}_" })
$missingReferencedImagePaths = @(
    $referencedImagePaths | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $AssetRoot ([string]$_ -replace '^tft/', '')))
    }
)
$unreferencedAssetFiles = @(
    $assetFiles | Where-Object { "tft/images/$($_.Name)" -notin $referencedImagePaths }
)
$categoryCoverage = @($items | Group-Object category | Sort-Object Name | ForEach-Object { "- $($_.Name): $($_.Count)件" }) -join [Environment]::NewLine

$coverage = @"
# DATA COVERAGE REPORT

生成日時: $FetchedAtUtc
対象: $SetNameJa / Set $SetNumber / TFT patch $TftPatch
Data Dragon配布版: $dataDragonVersion

| カテゴリ | 取得元件数 | 組み込み件数 | 欠損件数 | 画像欠損 | 日本語説明欠損 |
|---|---:|---:|---:|---:|---:|
| チャンピオン | $($playableChampions.Count) | $($champions.Count) | $($playableChampions.Count - $champions.Count) | $(@($champions | Where-Object {-not $_.image}).Count) | $(@($champions | Where-Object {-not $_.ability.descriptionJa}).Count) |
| 特性 | $($traitNames.Count) | $($traits.Count) | $($traitNames.Count - $traits.Count) | $(@($traits | Where-Object {-not $_.image}).Count) | $(@($traits | Where-Object {-not $_.descriptionJa}).Count) |
| アイテム | $($candidateItems.Count) | $($items.Count) | $($candidateItems.Count - $items.Count) | $(@($items | Where-Object {-not $_.image}).Count) | $(@($items | Where-Object {-not $_.descriptionJa}).Count) |
| オーグメント | $(@($setJa.augments).Count) | $($augments.Count) | $(@($setJa.augments).Count - $augments.Count) | $(@($augments | Where-Object {-not $_.image}).Count) | $(@($augments | Where-Object {-not $_.descriptionJa}).Count) |

統計値はこの静的カタログへ混在させず、``source/current/tft_static_snapshot.json``で扱う。

## アイテムカテゴリ内訳

$categoryCoverage
"@
[IO.File]::WriteAllText((Join-Path $RepositoryRoot "DATA_COVERAGE_REPORT.md"), $coverage, [Text.UTF8Encoding]::new($false))

$sourceManifest = [pscustomobject][ordered]@{
    generatedAtUtc = $FetchedAtUtc
    targetSet = $catalog.set
    sources = @(
        [ordered]@{ name = "Riot Data Dragon versions"; url = $Sources.riotVersions; type = "Riot公式"; use = "最新配布版番号"; terms = "Riot Developer Policy / Legal Notices" },
        [ordered]@{ name = "TFT patch $TftPatch"; url = $Sources.riotPatch; type = "Riot公式"; use = "現行パッチ確認"; terms = "Riot website terms" },
        [ordered]@{ name = "TFT Set $SetNumber news"; url = $Sources.riotSetOverview; type = "Riot公式"; use = "セット情報の確認先"; terms = "Riot website terms" },
        [ordered]@{ name = "Riot TFT Developer Policy"; url = $Sources.riotTftPolicy; type = "Riot公式"; use = "製品登録・許容機能・ゲーム整合性の確認"; terms = "Riot Developer Policy" },
        [ordered]@{ name = "Riot Legal"; url = $Sources.riotLegal; type = "Riot公式"; use = "知的財産・利用条件へのリンク"; terms = "Riot Legal Notices" },
        [ordered]@{ name = "CommunityDragon asset documentation"; url = $Sources.communityDragonDocs; type = "CommunityDragon公式文書"; use = "静的JSON・画像の取得規則"; terms = "Riot Legal Jibber Jabber; CommunityDragon is not endorsed by Riot" },
        [ordered]@{ name = "CommunityDragon TFT ja_jp"; url = $Sources.communityDragonJa; type = "Riotクライアント抽出コミュニティ配布"; use = "日本語静的データと画像パス"; terms = "Riot Legal Jibber Jabber; CommunityDragon is not endorsed by Riot" },
        [ordered]@{ name = "CommunityDragon TFT en_us"; url = $Sources.communityDragonEn; type = "Riotクライアント抽出コミュニティ配布"; use = "英語名"; terms = "Riot Legal Jibber Jabber; CommunityDragon is not endorsed by Riot" }
        [ordered]@{ name = "CommunityDragon champion calculation bins"; url = $Sources.communityDragonChampionBinTemplate; type = "Riotクライアント抽出コミュニティ配布"; use = "チャンピオンスキル数式の現在値解決"; terms = "Riot Legal Jibber Jabber; CommunityDragon is not endorsed by Riot" }
    )
}
[IO.File]::WriteAllText($ManifestPath, (($sourceManifest | ConvertTo-Json -Depth 10).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))

$missing = @"
# MISSING DATA REPORT

生成日時: $FetchedAtUtc

- 名前欠損: $($missingName.Count)
- 日本語説明欠損: $($missingDescription.Count)
- 画像参照欠損: $($missingImage.Count)
- 画像取得失敗: $($DownloadFailures.Count)
- ID重複: $($duplicateIds.Count)
- JSON再解析エラー: $(if ($catalogRoundTripValid) { 0 } else { 1 })
- Unicode置換文字: $($mojibakeMatches.Count)
- チャンピオン→特性の不正参照: $($invalidChampionTraitReferences.Count)
- 特性→チャンピオンの不正参照: $($invalidTraitChampionReferences.Count)
- 合成レシピの存在しない参照: $($invalidRecipeReferences.Count)
- 対象セット外チャンピオン: $($outOfSetChampions.Count)
- ショップ確率: 未取得
- 必要経験値: 未取得
- ステージ・ラウンド定義: 未取得
- オーグメント平均順位・使用率・Top4率・勝率: Riot方針変更後の信頼できる公開値を確認できず未取得

## 除外されたオーグメント

$(@($skippedAugments | ForEach-Object { "- $($_.id): $($_.reason)" }) -join [Environment]::NewLine)

欠損はUIで「未取得」と表示し、架空値で補完しない。
"@
[IO.File]::WriteAllText((Join-Path $RepositoryRoot "MISSING_DATA_REPORT.md"), $missing, [Text.UTF8Encoding]::new($false))

$assetReport = @"
# ASSET VALIDATION REPORT

生成日時: $FetchedAtUtc

- PNGファイル数: $($assetFiles.Count)
- PNGシグネチャ不正: $($badPng.Count)
- 同一内容の重複画像グループ: $($duplicateContentHashes.Count)
- 参照画像欠損: $($missingImage.Count)
- 全画像参照数（スキル画像を含む）: $($referencedImagePaths.Count)
- 実ファイルがない参照: $($missingReferencedImagePaths.Count)
- 未参照のカタログ画像: $($unreferencedAssetFiles.Count)
- 今回安全に削除した旧画像: $($prunedImageNames.Count)
- ダウンロード失敗: $($DownloadFailures.Count)
- カタログJSON: ``source/current/tft/tft_catalog.json``
- 画像ディレクトリ: ``source/current/tft/images/``

画像URL単位でファイルを共有し、同一URLの重複保存を防止した。内容ハッシュ重複はレポート対象とする。
"@
[IO.File]::WriteAllText((Join-Path $RepositoryRoot "ASSET_VALIDATION_REPORT.md"), $assetReport, [Text.UTF8Encoding]::new($false))

Write-Output "Catalog: $CatalogPath"
Write-Output "Set=$SetId Patch=$TftPatch DataDragon=$dataDragonVersion"
Write-Output "Champions=$($champions.Count) Traits=$($traits.Count) Items=$($items.Count) Augments=$($augments.Count) Images=$($assetFiles.Count)"
Write-Output "MissingImages=$($missingImage.Count) DownloadFailures=$($DownloadFailures.Count) BadPng=$($badPng.Count)"

$Client.Dispose()
