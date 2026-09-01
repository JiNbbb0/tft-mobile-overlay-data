Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CanonicalStringFindings {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [string]$Path = '$'
    )

    $findings = [Collections.Generic.List[object]]::new()

    function Visit-Node {
        param($Node, [string]$NodePath)

        if ($null -eq $Node) { return }

        if ($Node -is [string]) {
            $text = [string]$Node
            $patterns = @(
                [pscustomobject]@{ code = 'UNRESOLVED_RAW_TOKEN'; regex = '@[^@\r\n]+@' },
                [pscustomobject]@{ code = 'UNRESOLVED_MUSTACHE_TOKEN'; regex = '\{\{[^}\r\n]+\}\}' },
                [pscustomobject]@{ code = 'PSEUDO_VALUE_IN_DESCRIPTION'; regex = '(?:任意の|可変値)' }
            )
            foreach ($pattern in $patterns) {
                if ($text -match $pattern.regex) {
                    $findings.Add([pscustomobject][ordered]@{
                        code = [string]$pattern.code
                        path = $NodePath
                        value = $text
                    })
                }
            }
            return
        }

        # Primitive value types expose synthetic PSObject properties (for example
        # DateTime/number metadata). Recursing into those properties can create
        # self-referential traversal and call-depth overflow on large live JSON.
        # Only strings can contain the textual placeholder patterns checked here.
        if ($Node -is [ValueType]) { return }

        if ($Node -is [Collections.IDictionary]) {
            foreach ($key in $Node.Keys) {
                Visit-Node -Node $Node[$key] -NodePath "$NodePath.$key"
            }
            return
        }

        if ($Node -is [Collections.IEnumerable] -and $Node -isnot [pscustomobject]) {
            $index = 0
            foreach ($entry in $Node) {
                Visit-Node -Node $entry -NodePath "$NodePath[$index]"
                $index++
            }
            return
        }

        foreach ($property in $Node.PSObject.Properties) {
            Visit-Node -Node $property.Value -NodePath "$NodePath.$($property.Name)"
        }
    }

    Visit-Node -Node $Value -NodePath $Path
    return @($findings)
}

function Get-ArrayContractFindings {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [string[]]$RequiredArrayPaths = @('compositions','augments','champions','traits','items')
    )

    $findings = [Collections.Generic.List[object]]::new()
    foreach ($requiredPath in $RequiredArrayPaths) {
        $current = $Value
        $resolved = $true
        foreach ($segment in ($requiredPath -split '\.')) {
            if ($null -eq $current) { $resolved = $false; break }
            $property = $current.PSObject.Properties[$segment]
            if (-not $property) { $resolved = $false; break }
            $current = $property.Value
        }
        if (-not $resolved) { continue }
        if ($null -eq $current -or $current -is [string] -or $current -isnot [Collections.IEnumerable]) {
            $findings.Add([pscustomobject][ordered]@{
                code = 'ARRAY_CONTRACT_NULL_OR_NON_ARRAY'
                path = "$.${requiredPath}"
                valueType = if ($null -eq $current) { 'null' } else { $current.GetType().FullName }
            })
        }
    }
    return @($findings)
}

function Get-NumberFindings {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [string]$Path = '$'
    )

    $findings = [Collections.Generic.List[object]]::new()

    function Visit-NumberNode {
        param($Node, [string]$NodePath)
        if ($null -eq $Node) { return }

        if ($Node -is [double] -or $Node -is [single] -or $Node -is [decimal]) {
            $numeric = [double]$Node
            if ([double]::IsNaN($numeric) -or [double]::IsInfinity($numeric)) {
                $findings.Add([pscustomobject][ordered]@{
                    code = 'NON_FINITE_NUMBER'
                    path = $NodePath
                    value = [string]$Node
                })
            }
            return
        }

        if ($Node -is [string] -or $Node -is [ValueType]) { return }
        if ($Node -is [Collections.IDictionary]) {
            foreach ($key in $Node.Keys) { Visit-NumberNode -Node $Node[$key] -NodePath "$NodePath.$key" }
            return
        }
        if ($Node -is [Collections.IEnumerable] -and $Node -isnot [pscustomobject]) {
            $index = 0
            foreach ($entry in $Node) {
                Visit-NumberNode -Node $entry -NodePath "$NodePath[$index]"
                $index++
            }
            return
        }
        foreach ($property in $Node.PSObject.Properties) {
            Visit-NumberNode -Node $property.Value -NodePath "$NodePath.$($property.Name)"
        }
    }

    Visit-NumberNode -Node $Value -NodePath $Path
    return @($findings)
}

function Test-CanonicalContract {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [string[]]$RequiredArrayPaths = @()
    )

    $findings = [Collections.Generic.List[object]]::new()
    foreach ($finding in @(Get-CanonicalStringFindings -Value $Value)) { $findings.Add($finding) }
    foreach ($finding in @(Get-NumberFindings -Value $Value)) { $findings.Add($finding) }
    if ($RequiredArrayPaths.Count -gt 0) {
        foreach ($finding in @(Get-ArrayContractFindings -Value $Value -RequiredArrayPaths $RequiredArrayPaths)) { $findings.Add($finding) }
    }

    return [pscustomobject][ordered]@{
        passed = ($findings.Count -eq 0)
        findings = @($findings)
    }
}
