$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'metatft/Convert-MetaTftBoards.ps1')

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ([string]$Actual -ne [string]$Expected) { throw "$Message. Expected=$Expected Actual=$Actual" }
}

$details = [pscustomobject]@{
    early_options = [pscustomobject]@{
        '4' = @(
            [pscustomobject]@{ unit_list='A&B&C&D'; count=100; avg=4.2 },
            [pscustomobject]@{ unit_list='E&F&G&H'; count=300; avg=4.8 },
            [pscustomobject]@{ unit_list='I&J&K&L'; count=200; avg=3.9 },
            [pscustomobject]@{ unit_list='M&N&O&P'; count=50; avg=3.2 }
        )
        '6' = @(
            [pscustomobject]@{
                unit_list='A&B&C&D&E&F'
                count=500
                avg=4.0
                positions=@('cell_1','cell_2','cell_3','cell_4','cell_5','cell_6')
            }
        )
    }
    options = [pscustomobject]@{
        '8' = @(
            [pscustomobject]@{ units_list='A&B&C&D&E&F&G&H'; count=600; avg=3.8 }
        )
    }
}

$boards = @(Convert-MetaTftLevelBoards -Details $details)
Assert-Equal @($boards | Where-Object level -eq 4).Count 3 'Only top three popular Lv4 boards should be preserved'
Assert-Equal (@($boards | Where-Object level -eq 4 | Select-Object -First 1).unitIds -join '&') 'E&F&G&H' 'Lv4 boards must rank by popularity/count, not average placement'
Assert-Equal @($boards | Where-Object level -eq 5).Count 0 'Missing Lv5 must stay missing rather than being synthesized'
Assert-Equal @($boards | Where-Object level -eq 7).Count 0 'Missing Lv7 must stay missing rather than being synthesized'
Assert-Equal @($boards | Where-Object synthetic -eq $true).Count 0 'Synthetic boards are forbidden'

$level4 = @($boards | Where-Object level -eq 4 | Select-Object -First 1)[0]
Assert-Equal $level4.positionsAvailable $false 'Aggregate/missing positioning must not be invented for Lv4'
Assert-Equal @($level4.positions).Count 0 'Missing level-specific positions must stay empty'

$level6 = @($boards | Where-Object level -eq 6)[0]
Assert-Equal $level6.positionsAvailable $true 'Explicit level-specific positions should be retained'
Assert-Equal (($level6.positions | ForEach-Object { $_.position }) -join ',') '0,1,2,3,4,5' 'Explicit cells must preserve source coordinate identity without vertical inversion'

Write-Output 'MetaTFT non-synthetic level-board regression passed.'
