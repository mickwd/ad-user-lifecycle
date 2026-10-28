function Get-LifecycleObjectProperty {
    <#
    .SYNOPSIS
    Devuelve el valor de una propiedad o $null si no existe (seguro con StrictMode).
    Sirve para objetos de AD, filas de Import-Csv, PSCustomObject y hashtables.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()] $InputObject,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-LifecycleParentDN {
    <#
    .SYNOPSIS
    Devuelve el DN del contenedor padre (la OU) a partir del DN de un objeto.
    Contempla comas escapadas dentro del CN, por ejemplo "CN=Pérez\, Juan,OU=...".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $DistinguishedName)

    return ($DistinguishedName -replace '^.+?(?<!\\),', '')
}

function ConvertTo-LifecycleAsciiName {
    <#
    .SYNOPSIS
    Normaliza un texto a minúsculas ASCII: quita tildes, convierte ñ en n y elimina
    todo lo que no sea letra o espacio. Los guiones se tratan como separadores.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

    $decomposed = $Text.Normalize([System.Text.NormalizationForm]::FormD)
    $builder = New-Object System.Text.StringBuilder
    foreach ($char in $decomposed.ToCharArray()) {
        $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($char)
        if ($category -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($char)
        }
    }
    $clean = $builder.ToString().ToLowerInvariant() -replace '-', ' '
    $clean = $clean -replace '[^a-z ]', ''
    return ($clean -replace '\s+', ' ').Trim()
}

function ConvertTo-LifecycleDate {
    <#
    .SYNOPSIS
    Convierte una fecha en formato yyyy-MM-dd o dd/MM/yyyy. Devuelve $null si viene vacía.
    #>
    [CmdletBinding()]
    param([AllowNull()] [AllowEmptyString()] [string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $formats = [string[]]@('yyyy-MM-dd', 'dd/MM/yyyy', 'd/M/yyyy', 'yyyy-MM-ddTHH:mm:ss')
    $parsed = [datetime]::MinValue
    $ok = [datetime]::TryParseExact(
        $Value.Trim(), $formats, [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None, [ref]$parsed)
    if (-not $ok) { throw "Fecha inválida '$Value'. Formatos aceptados: yyyy-MM-dd o dd/MM/yyyy." }
    return $parsed
}

function ConvertTo-LifecycleSecureString {
    <#
    .SYNOPSIS
    Arma un SecureString carácter por carácter (evita ConvertTo-SecureString -AsPlainText).
    #>
    [CmdletBinding()]
    [OutputType([securestring])]
    param([Parameter(Mandatory)] [string] $Text)

    $secure = New-Object System.Security.SecureString
    foreach ($char in $Text.ToCharArray()) { $secure.AppendChar($char) }
    $secure.MakeReadOnly()
    return $secure
}

function Assert-LifecycleADModule {
    <#
    .SYNOPSIS
    Verifica que los cmdlets de ActiveDirectory estén disponibles (RSAT).
    En los tests se reemplazan por stubs, así que nunca se toca un AD real.
    #>
    [CmdletBinding()]
    param()

    if (Get-Command -Name 'Get-ADUser' -ErrorAction SilentlyContinue) { return }
    try {
        Import-Module -Name ActiveDirectory -ErrorAction Stop
    }
    catch {
        throw 'No se encontró el módulo ActiveDirectory. Instalar RSAT (RSAT-AD-PowerShell) en el equipo que ejecuta la automatización.'
    }
}

function Get-LifecycleOperator {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    }
    catch {
        return ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME)
    }
}
