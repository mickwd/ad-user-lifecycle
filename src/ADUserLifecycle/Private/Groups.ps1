function Get-LifecycleRoleGroup {
    <#
    .SYNOPSIS
    Calcula los grupos que corresponden a un área y puesto según RoleGroups:
    Common + Areas[area] + Puestos[puesto], sin duplicados (sin distinguir mayúsculas).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()] [AllowEmptyString()] [string] $Area,
        [AllowNull()] [AllowEmptyString()] [string] $Puesto,
        [Parameter(Mandatory)] $Config
    )

    $collected = New-Object System.Collections.Generic.List[string]
    foreach ($group in @($Config.RoleGroups.Common)) { if ($group) { $collected.Add([string]$group) } }

    if ($Area) {
        $areaEntry = $Config.RoleGroups.Areas.PSObject.Properties[$Area]
        if ($areaEntry) { foreach ($group in @($areaEntry.Value)) { if ($group) { $collected.Add([string]$group) } } }
    }
    if ($Puesto) {
        $puestoEntry = $Config.RoleGroups.Puestos.PSObject.Properties[$Puesto]
        if ($puestoEntry) {
            foreach ($group in @($puestoEntry.Value)) { if ($group) { $collected.Add([string]$group) } }
        }
        else {
            Write-Verbose "El puesto '$Puesto' no tiene grupos específicos configurados."
        }
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($group in $collected) {
        if ($seen.Add($group)) { $result.Add($group) }
    }
    # Se devuelve enumerado: los llamadores siempre envuelven con @().
    return $result.ToArray()
}

function Get-LifecycleTargetOU {
    <#
    .SYNOPSIS
    Devuelve la OU destino de un área. Un área desconocida es un error de datos: se corta
    antes de crear nada para no dejar cuentas en una OU equivocada.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Area,
        [Parameter(Mandatory)] $Config
    )

    $entry = $Config.OUs.Areas.PSObject.Properties[$Area]
    if (-not $entry) {
        $known = @($Config.OUs.Areas.PSObject.Properties | ForEach-Object { $_.Name }) -join ', '
        throw "El área '$Area' no está definida en OUs.Areas. Áreas válidas: $known"
    }
    return [string]$entry.Value
}
