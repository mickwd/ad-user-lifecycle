<#
.SYNOPSIS
Punto de entrada para ejecutar una solicitud aprobada desde la API (api/executor.py).

.DESCRIPTION
Recibe la solicitud como JSON, llama a la función del módulo que corresponde y escribe
en stdout UNA línea JSON con el resultado. Código de salida 0 = ok, 1 = error.

Formato de entrada:
{
  "id": 12,
  "tipo": "alta" | "baja" | "cambio",
  "ticket": "RRHH-1001",
  "origen": "rrhh",
  "aprobado_por": "mgarcia",
  "datos": { ...campos según el tipo... }
}

La contraseña temporal de un alta NUNCA se devuelve por stdout: no debe quedar en la
base de la API ni en logs. Mesa de ayuda la entrega reseteándola el primer día.

.EXAMPLE
.\run_request.ps1 -RequestJson '{"id":1,"tipo":"baja","ticket":"INC-1","datos":{"usuario":"jperez"}}' -DryRun
#>
[CmdletBinding(DefaultParameterSetName = 'Json')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Json')]
    [string] $RequestJson,

    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string] $RequestFile,

    [string] $ConfigPath,

    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
# Las advertencias ya viajan dentro del resultado; así stdout queda limpio para el JSON.
$WarningPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

function Write-RequestResult {
    param([System.Collections.IDictionary] $Data, [int] $ExitCode)
    [Console]::Out.WriteLine((ConvertTo-Json -InputObject $Data -Compress -Depth 6))
    exit $ExitCode
}

function Get-RequestField {
    param($Object, [string] $Name, [switch] $Required)
    $property = if ($null -ne $Object) { $Object.PSObject.Properties[$Name] } else { $null }
    $value = if ($property) { [string]$property.Value } else { '' }
    if ($Required -and [string]::IsNullOrWhiteSpace($value)) {
        throw "Falta el campo obligatorio '$Name' en la solicitud."
    }
    return $value
}

$request = $null
try {
    if ($PSCmdlet.ParameterSetName -eq 'File') {
        $RequestJson = Get-Content -LiteralPath $RequestFile -Raw -Encoding UTF8
    }
    $request = $RequestJson | ConvertFrom-Json

    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\src\ADUserLifecycle\ADUserLifecycle.psd1'
    Import-Module -Name $modulePath -Force

    $config = if ($ConfigPath) { Import-LifecycleConfig -Path $ConfigPath } else { Import-LifecycleConfig }

    $tipo = (Get-RequestField -Object $request -Name 'tipo' -Required).ToLowerInvariant()
    $ticket = Get-RequestField -Object $request -Name 'ticket' -Required
    $datos = $request.PSObject.Properties['datos']
    if (-not $datos -or $null -eq $datos.Value) { throw "Falta el bloque 'datos' en la solicitud." }
    $datos = $datos.Value

    Set-LifecycleAuditContext -RequestId (Get-RequestField -Object $request -Name 'id') `
        -RequestedBy (Get-RequestField -Object $request -Name 'origen') `
        -ApprovedBy (Get-RequestField -Object $request -Name 'aprobado_por') -Source 'api'

    $common = @{ Ticket = $ticket; Config = $config; WhatIf = [bool]$DryRun; Confirm = $false }
    switch ($tipo) {
        'alta' {
            $outcome = New-LifecycleUser @common `
                -Nombre (Get-RequestField $datos 'nombre' -Required) `
                -Apellido (Get-RequestField $datos 'apellido' -Required) `
                -Legajo (Get-RequestField $datos 'legajo' -Required) `
                -Area (Get-RequestField $datos 'area' -Required) `
                -Puesto (Get-RequestField $datos 'puesto' -Required) `
                -Manager (Get-RequestField $datos 'manager') `
                -FechaIngreso (Get-RequestField $datos 'fecha_ingreso')
        }
        'baja' {
            $outcome = Disable-LifecycleUser @common -Identity (Get-RequestField $datos 'usuario' -Required)
        }
        'cambio' {
            $outcome = Set-LifecycleUserTransfer @common `
                -Identity (Get-RequestField $datos 'usuario' -Required) `
                -NuevaArea (Get-RequestField $datos 'area' -Required) `
                -NuevoPuesto (Get-RequestField $datos 'puesto' -Required)
        }
        default { throw "Tipo de solicitud desconocido: '$tipo'." }
    }

    $detail = [ordered]@{}
    foreach ($property in $outcome.PSObject.Properties) {
        if ($property.Name -in @('TemporaryPassword', 'Warnings')) { continue }
        $detail[$property.Name] = $property.Value
    }

    Write-RequestResult -ExitCode 0 -Data ([ordered]@{
            ok          = $true
            tipo        = $tipo
            estado      = [string]$outcome.Status
            usuario     = [string]$outcome.SamAccountName
            advertencias = @($outcome.Warnings)
            detalle     = $detail
        })
}
catch {
    Write-RequestResult -ExitCode 1 -Data ([ordered]@{
            ok    = $false
            error = $_.Exception.Message
        })
}
