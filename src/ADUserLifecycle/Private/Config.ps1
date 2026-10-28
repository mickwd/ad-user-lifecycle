function Test-LifecycleConfigKey {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $Key
    )

    $current = $Config
    foreach ($part in $Key.Split('.')) {
        if ($null -eq $current) { return $false }
        $property = $current.PSObject.Properties[$part]
        if (-not $property) { return $false }
        $current = $property.Value
    }
    return ($null -ne $current)
}

function Set-LifecycleConfigDefault {
    <#
    .SYNOPSIS
    Agrega una clave con valor por defecto si no existe (crea la sección si hace falta).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Solo modifica un objeto en memoria.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $Section,
        [Parameter(Mandatory)] [string] $Name,
        [AllowNull()] $Value
    )

    if (-not $Config.PSObject.Properties[$Section]) {
        $Config | Add-Member -NotePropertyName $Section -NotePropertyValue ([pscustomobject]@{})
    }
    $target = $Config.$Section
    if (-not $target.PSObject.Properties[$Name]) {
        $target | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Resolve-LifecyclePath {
    <#
    .SYNOPSIS
    Resuelve rutas relativas contra la carpeta donde está el archivo de configuración.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $BaseDirectory
    )

    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return [System.IO.Path]::GetFullPath((Join-Path -Path $BaseDirectory -ChildPath $Path))
}

function Import-LifecycleConfig {
    <#
    .SYNOPSIS
    Carga y valida el archivo JSON de configuración del módulo.

    .DESCRIPTION
    Valida las claves obligatorias, completa los valores por defecto y resuelve las rutas
    relativas (logs, snapshots de bajas, reportes) contra la carpeta del archivo.
    La configuración queda cacheada en el módulo para las siguientes llamadas.

    .PARAMETER Path
    Ruta al JSON. Si se omite se usa $env:ADLC_CONFIG o config\lifecycle.config.json.

    .EXAMPLE
    $cfg = Import-LifecycleConfig -Path .\config\lifecycle.config.json
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string] $Path)

    if (-not $Path) {
        $Path = if ($env:ADLC_CONFIG) { $env:ADLC_CONFIG } else { $script:DefaultConfigPath }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "No se encontró el archivo de configuración: $Path"
    }

    $fullPath = (Resolve-Path -LiteralPath $Path).ProviderPath
    $baseDirectory = Split-Path -Path $fullPath -Parent
    try {
        $config = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "El archivo de configuración '$fullPath' no es un JSON válido: $($_.Exception.Message)"
    }

    $required = @(
        'Domain.NetBIOS', 'Domain.UpnSuffix', 'OUs.Areas', 'OUs.Bajas', 'RoleGroups',
        'HomeFolders.Root', 'HomeFolders.ArchiveRoot', 'Audit.LogPath', 'Offboarding.SnapshotFolder'
    )
    $missing = @($required | Where-Object { -not (Test-LifecycleConfigKey -Config $config -Key $_) })
    if ($missing.Count -gt 0) {
        throw "Faltan claves obligatorias en la configuración: $($missing -join ', ')"
    }

    Set-LifecycleConfigDefault -Config $config -Section 'Domain' -Name 'Server' -Value $null
    Set-LifecycleConfigDefault -Config $config -Section 'RoleGroups' -Name 'Common' -Value @()
    Set-LifecycleConfigDefault -Config $config -Section 'RoleGroups' -Name 'Areas' -Value ([pscustomobject]@{})
    Set-LifecycleConfigDefault -Config $config -Section 'RoleGroups' -Name 'Puestos' -Value ([pscustomobject]@{})
    Set-LifecycleConfigDefault -Config $config -Section 'Password' -Name 'Length' -Value 16
    Set-LifecycleConfigDefault -Config $config -Section 'HomeFolders' -Name 'Drive' -Value 'H:'
    Set-LifecycleConfigDefault -Config $config -Section 'HomeFolders' -Name 'Rights' -Value 'Modify'
    Set-LifecycleConfigDefault -Config $config -Section 'Offboarding' -Name 'KeepGroups' -Value @('Domain Users', 'Usuarios del dominio')
    Set-LifecycleConfigDefault -Config $config -Section 'Offboarding' -Name 'RetentionDays' -Value 90
    Set-LifecycleConfigDefault -Config $config -Section 'Offboarding' -Name 'RemoveHomeAfterArchive' -Value $false
    Set-LifecycleConfigDefault -Config $config -Section 'Batch' -Name 'ReportFolder' -Value '..\output'

    if ([int]$config.Password.Length -lt 14) {
        throw 'Password.Length debe ser de al menos 14 caracteres.'
    }

    $config.Audit.LogPath = Resolve-LifecyclePath -Path $config.Audit.LogPath -BaseDirectory $baseDirectory
    $config.Offboarding.SnapshotFolder = Resolve-LifecyclePath -Path $config.Offboarding.SnapshotFolder -BaseDirectory $baseDirectory
    $config.Batch.ReportFolder = Resolve-LifecyclePath -Path $config.Batch.ReportFolder -BaseDirectory $baseDirectory

    $script:LifecycleConfig = $config
    return $config
}

function Resolve-LifecycleConfig {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()] $Config)

    if ($null -ne $Config) { return $Config }
    if ($null -ne $script:LifecycleConfig) { return $script:LifecycleConfig }
    return (Import-LifecycleConfig)
}

function Get-LifecycleADConnectionParam {
    <#
    .SYNOPSIS
    Parámetros comunes para los cmdlets de AD. Fijar un DC (Domain.Server) evita
    problemas de replicación entre el alta y los pasos siguientes.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] $Config)

    $params = @{}
    if ($Config.Domain.Server) { $params['Server'] = [string]$Config.Domain.Server }
    return $params
}
