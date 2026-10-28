# Partículas que se unen a la palabra siguiente del apellido ("de la Fuente" -> "delafuente").
$script:SurnameParticles = @('de', 'del', 'la', 'las', 'los', 'da', 'das', 'do', 'dos', 'di', 'van', 'von', 'y', 'e')

# Límite de sAMAccountName para cuentas de usuario.
$script:SamAccountNameMaxLength = 20

function Get-LifecycleSurnameKey {
    <#
    .SYNOPSIS
    Toma el primer apellido normalizado, uniendo partículas iniciales.
    "Pérez García" -> "perez", "de la Fuente" -> "delafuente".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Apellido)

    $words = @((ConvertTo-LifecycleAsciiName -Text $Apellido).Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries))
    $key = ''
    foreach ($word in $words) {
        $key += $word
        if ($script:SurnameParticles -notcontains $word) { break }
    }
    return $key
}

function Test-LifecycleSamAccountNameInUse {
    <#
    .SYNOPSIS
    Indica si un sAMAccountName (o el UPN derivado) ya existe en el dominio.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9]+$')] [string] $SamAccountName,
        [Parameter(Mandatory)] $Config
    )

    $ad = Get-LifecycleADConnectionParam -Config $Config
    $upn = '{0}@{1}' -f $SamAccountName, $Config.Domain.UpnSuffix
    $filter = "sAMAccountName -eq '$SamAccountName' -or UserPrincipalName -eq '$upn'"
    $found = Get-ADUser -Filter $filter @ad
    return [bool]$found
}

function New-LifecycleSamAccountName {
    <#
    .SYNOPSIS
    Genera un sAMAccountName único: inicial del nombre + primer apellido (jperez).
    Si ya existe prueba jperez2, jperez3, ... respetando el máximo de 20 caracteres.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Solo calcula un nombre, no modifica AD.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Nombre,
        [Parameter(Mandatory)] [string] $Apellido,
        [Parameter(Mandatory)] $Config,
        [ValidateRange(2, 999)] [int] $MaxAttempts = 99
    )

    $first = ConvertTo-LifecycleAsciiName -Text $Nombre
    $surname = Get-LifecycleSurnameKey -Apellido $Apellido
    if (-not $first -or -not $surname) {
        throw "No se puede generar un usuario a partir de '$Nombre $Apellido': quedan vacíos luego de normalizar."
    }

    $base = $first.Substring(0, 1) + $surname
    if ($base.Length -gt $script:SamAccountNameMaxLength) {
        $base = $base.Substring(0, $script:SamAccountNameMaxLength)
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if ($attempt -eq 1) {
            $candidate = $base
        }
        else {
            $suffix = [string]$attempt
            $room = $script:SamAccountNameMaxLength - $suffix.Length
            $prefix = if ($base.Length -gt $room) { $base.Substring(0, $room) } else { $base }
            $candidate = $prefix + $suffix
        }

        if (-not (Test-LifecycleSamAccountNameInUse -SamAccountName $candidate -Config $Config)) {
            return $candidate
        }
        Write-Verbose "El usuario '$candidate' ya existe, se prueba el siguiente."
    }

    throw "No se encontró un sAMAccountName libre para '$Nombre $Apellido' luego de $MaxAttempts intentos."
}
