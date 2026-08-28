Set-StrictMode -Version Latest

function Get-RawFallbackPropertyValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Convert-RawFallbackStringTable {
    param([Parameter(Mandatory = $true)][object]$Json)
    $root = if ($Json.PSObject.Properties['entries']) { $Json.entries } else { $Json }
    $map = @{}
    foreach ($property in $root.PSObject.Properties) {
        $map[[string]$property.Name.ToLowerInvariant()] = [string]$property.Value
    }
    return $map
}

function Get-RawFallbackBaseValue {
    param(
        [AllowNull()][object]$Object,
        [double]$Default = 0.0
    )
    if ($null -eq $Object) { return $Default }
    $baseValue = Get-RawFallbackPropertyValue -Object $Object -Name 'baseValue'
    if ($null -eq $baseValue) { $baseValue = Get-RawFallbackPropertyValue -Object $Object -Name 'BaseValue' }
    if ($null -eq $baseValue) { return $Default }
    return [double]$baseValue
}

function Get-RawSetChampions {
    param(
        [Parameter(Mandatory = $true)][int]$SetNumber,
        [Parameter(Mandatory = $true)][object]$SetJa,
        [Parameter(Mandatory = $true)][object]$SetEn
    )

    $map22Url = 'https://raw.communitydragon.org/latest/game/data/maps/shipping/map22/map22.bin.json'
    # Locale overlays keep Riot's internal menu folder named en_us.
    $jaStringUrl = 'https://raw.communitydragon.org/latest/game/ja_jp/data/menu/en_us/tft.stringtable.json'
    $enStringUrl = 'https://raw.communitydragon.org/latest/game/en_us/data/menu/en_us/tft.stringtable.json'

    Write-Host "Derived champion block is incomplete; rebuilding Set $SetNumber champions from LIVE raw client data."
    $map22 = Get-Json -Url $map22Url
    $jaStrings = Convert-RawFallbackStringTable -Json (Get-Json -Url $jaStringUrl)
    $enStrings = Convert-RawFallbackStringTable -Json (Get-Json -Url $enStringUrl)

    $jaTraitNames = @{}
    foreach ($trait in @($SetJa.traits)) {
        if ($trait.apiName -and $trait.name) { $jaTraitNames[[string]$trait.apiName.ToLowerInvariant()] = [string]$trait.name }
    }

    $shopPattern = "Sets/TFTSet${SetNumber}/Shop/"
    $shopRows = @(
        $map22.PSObject.Properties |
            Where-Object {
                $_.Name -match [regex]::Escape($shopPattern) -and
                $_.Value -and
                (Get-RawFallbackPropertyValue -Object $_.Value -Name 'mName')
            } |
            ForEach-Object { $_.Value }
    )
    if ($shopRows.Count -lt 40) {
        throw "Raw Map22 Set $SetNumber shop is incomplete: $($shopRows.Count) entries"
    }

    $traitPattern = "Sets/TFTSet${SetNumber}/Traits/"
    $champions = [Collections.Generic.List[object]]::new()
    $seen = @{}
    $failedBins = [Collections.Generic.List[string]]::new()
    $unknownTraits = [Collections.Generic.List[string]]::new()

    foreach ($shop in $shopRows) {
        $id = [string](Get-RawFallbackPropertyValue -Object $shop -Name 'mName')
        if (-not $id -or $seen.ContainsKey($id.ToLowerInvariant())) { continue }

        $baseCostValue = Get-RawFallbackPropertyValue -Object $shop -Name 'BaseCost'
        $baseCost = if ($null -ne $baseCostValue) { [int]$baseCostValue } else { 0 }
        if ($baseCost -lt 1 -or $baseCost -gt 5) { continue }

        $binUrl = "https://raw.communitydragon.org/latest/game/characters/$($id.ToLowerInvariant()).cdtb.bin.json"
        try {
            $bin = Get-Json -Url $binUrl
        } catch {
            $failedBins.Add($id)
            continue
        }
        $recordProperty = @(
            $bin.PSObject.Properties | Where-Object { $_.Name -match 'CharacterRecords/Root$' }
        ) | Select-Object -First 1
        if (-not $recordProperty) { continue }
        $record = $recordProperty.Value

        $traitNames = [Collections.Generic.List[string]]::new()
        foreach ($linkedTrait in @((Get-RawFallbackPropertyValue -Object $record -Name 'mLinkedTraits'))) {
            $traitPath = [string](Get-RawFallbackPropertyValue -Object $linkedTrait -Name 'TraitData')
            if (-not $traitPath -or $traitPath -notmatch [regex]::Escape($traitPattern)) { continue }
            $traitApiName = ($traitPath -split '/')[-1]
            $traitKey = $traitApiName.ToLowerInvariant()
            if ($jaTraitNames.ContainsKey($traitKey)) {
                $traitNames.Add([string]$jaTraitNames[$traitKey])
            } else {
                $unknownTraits.Add("$id->$traitApiName")
            }
        }
        $traitNames = @($traitNames | Select-Object -Unique)
        if ($traitNames.Count -eq 0) { continue }

        $displayNameKey = [string](Get-RawFallbackPropertyValue -Object $shop -Name 'mDisplayNameTra')
        $abilityNameKey = [string](Get-RawFallbackPropertyValue -Object $shop -Name 'mAbilityNameTra')
        $abilityDescKey = [string](Get-RawFallbackPropertyValue -Object $shop -Name 'mDescriptionTra')
        $displayNameLookup = if ($displayNameKey) { $displayNameKey.ToLowerInvariant() } else { '' }
        $abilityNameLookup = if ($abilityNameKey) { $abilityNameKey.ToLowerInvariant() } else { '' }
        $abilityDescLookup = if ($abilityDescKey) { $abilityDescKey.ToLowerInvariant() } else { '' }
        $nameJa = if ($displayNameLookup -and $jaStrings.ContainsKey($displayNameLookup)) { [string]$jaStrings[$displayNameLookup] } else { '' }
        $nameEn = if ($displayNameLookup -and $enStrings.ContainsKey($displayNameLookup)) { [string]$enStrings[$displayNameLookup] } else { '' }
        $abilityNameJa = if ($abilityNameLookup -and $jaStrings.ContainsKey($abilityNameLookup)) { [string]$jaStrings[$abilityNameLookup] } else { '' }
        $abilityNameEn = if ($abilityNameLookup -and $enStrings.ContainsKey($abilityNameLookup)) { [string]$enStrings[$abilityNameLookup] } else { '' }
        $abilityDescJa = if ($abilityDescLookup -and $jaStrings.ContainsKey($abilityDescLookup)) { [string]$jaStrings[$abilityDescLookup] } else { '' }
        if (-not $nameJa -or -not $abilityDescJa) { continue }

        $squareIcon = [string](Get-RawFallbackPropertyValue -Object $shop -Name 'SquareSplashPath')
        if (-not $squareIcon) { $squareIcon = [string](Get-RawFallbackPropertyValue -Object $shop -Name 'TeamPlannerPortraitPath') }
        if (-not $squareIcon) { continue }

        $hp = Get-RawFallbackBaseValue -Object (Get-RawFallbackPropertyValue -Object $record -Name 'baseHPModifiable')
        if ($hp -eq 0) { $hp = [double](Get-RawFallbackPropertyValue -Object $record -Name 'baseHP') }
        $damage = Get-RawFallbackBaseValue -Object (Get-RawFallbackPropertyValue -Object $record -Name 'baseDamageModifiable')
        if ($damage -eq 0) { $damage = [double](Get-RawFallbackPropertyValue -Object $record -Name 'BaseDamage') }
        $armor = Get-RawFallbackBaseValue -Object (Get-RawFallbackPropertyValue -Object $record -Name 'baseArmorModifiable')
        if ($armor -eq 0) { $armor = [double](Get-RawFallbackPropertyValue -Object $record -Name 'baseArmor') }
        $mr = Get-RawFallbackBaseValue -Object (Get-RawFallbackPropertyValue -Object $record -Name 'baseMR')
        if ($mr -eq 0) { $mr = [double](Get-RawFallbackPropertyValue -Object $record -Name 'baseSpellBlock') }
        $attackSpeed = Get-RawFallbackBaseValue -Object (Get-RawFallbackPropertyValue -Object $record -Name 'attackSpeedModifiable')
        if ($attackSpeed -eq 0) { $attackSpeed = [double](Get-RawFallbackPropertyValue -Object $record -Name 'attackSpeed') }
        $rangeRaw = Get-RawFallbackBaseValue -Object (Get-RawFallbackPropertyValue -Object $record -Name 'attackRangeModifiable')
        if ($rangeRaw -eq 0) { $rangeRaw = [double](Get-RawFallbackPropertyValue -Object $record -Name 'attackRange') }
        $range = [Math]::Floor($rangeRaw / 180.0)

        $initialManaValue = Get-RawFallbackPropertyValue -Object $record -Name 'mInitialMana'
        $initialMana = if ($null -ne $initialManaValue) { [int][Math]::Round([double]$initialManaValue) } else { 0 }
        $mana = 100
        $resource = Get-RawFallbackPropertyValue -Object $record -Name 'primaryAbilityResource'
        if ($resource) {
            $manaStruct = Get-RawFallbackPropertyValue -Object $resource -Name '{726ee5cd}'
            if ($manaStruct) {
                $mana = [int][Math]::Round((Get-RawFallbackBaseValue -Object $manaStruct -Default 100))
            } else {
                $arBase = Get-RawFallbackPropertyValue -Object $resource -Name 'arBase'
                if ($null -ne $arBase) { $mana = [int][Math]::Round([double]$arBase) }
            }
        }

        $champions.Add([pscustomobject][ordered]@{
            apiName = $id
            characterName = if (Get-RawFallbackPropertyValue -Object $record -Name 'mCharacterName') { [string](Get-RawFallbackPropertyValue -Object $record -Name 'mCharacterName') } else { $id }
            name = $nameJa
            nameEn = $nameEn
            cost = $baseCost
            squareIcon = $squareIcon
            traits = @($traitNames)
            ability = [pscustomobject][ordered]@{
                name = $abilityNameJa
                nameEn = $abilityNameEn
                desc = $abilityDescJa
                variables = @()
                icon = ''
            }
            stats = [pscustomobject][ordered]@{
                hp = $hp
                mana = $mana
                initialMana = $initialMana
                damage = $damage
                armor = $armor
                magicResist = $mr
                attackSpeed = $attackSpeed
                range = $range
            }
        })
        $seen[$id.ToLowerInvariant()] = $true
    }

    $result = @($champions | Sort-Object cost, name)
    Write-Host "LIVE raw champion fallback: Shop=$($shopRows.Count) Playable=$($result.Count) FailedBins=$($failedBins.Count) UnknownTraits=$($unknownTraits.Count)"
    if ($result.Count -lt 40) {
        throw "LIVE raw champion fallback is incomplete for Set ${SetNumber}: $($result.Count) playable champions"
    }
    if ($unknownTraits.Count -gt 0) {
        Write-Warning "Raw champion fallback skipped unknown trait links: $(@($unknownTraits | Select-Object -First 10) -join ', ')"
    }
    return $result
}
