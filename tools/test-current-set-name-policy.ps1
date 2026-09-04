$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'current-set-name-policy.ps1')

$cases = @(
    @{ source='Set10'; number=18; lookup='Enchanted Wilds'; expected='Enchanted Wilds' },
    @{ source='Set 19'; number=19; lookup='Future Set'; expected='Set 19' },
    @{ source=''; number=20; lookup='Future Set'; expected='Future Set' },
    @{ source=''; number=21; lookup=''; expected='Set 21' },
    @{ source='神秘の森'; number=18; lookup='Enchanted Wilds'; expected='神秘の森' }
)
foreach ($case in $cases) {
    $actual = Resolve-CurrentSetDisplayName -CommunityDragonName $case.source -SetNumber $case.number -MetaTftSetName $case.lookup
    if ($actual -ne $case.expected) {
        throw "Set-name policy mismatch: source=$($case.source) number=$($case.number) expected=$($case.expected) actual=$actual"
    }
}

$gate = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'refresh-live-data-gated.ps1'))
if ($gate -match 'setNumber\s+-eq\s+\d+') { throw 'Set readiness gate contains a set-specific name patch.' }

Write-Output 'Current-set name policy regression passed.'
