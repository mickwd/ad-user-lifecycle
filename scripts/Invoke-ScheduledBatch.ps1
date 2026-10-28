<#
.SYNOPSIS
Acción de la tarea programada: procesa los CSV pendientes de una carpeta de entrada.

.DESCRIPTION
Por cada *.csv en -InboxFolder ejecuta Invoke-LifecycleBatch y mueve el archivo a
"procesados" (o a "con_errores" si alguna fila falló). Opcionalmente ejecuta la
depuración de cuentas deshabilitadas vencidas.

.EXAMPLE
.\Invoke-ScheduledBatch.ps1 -InboxFolder D:\ABM\entrada -PurgeExpired
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $InboxFolder,
    [string] $ConfigPath,
    [switch] $PurgeExpired
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\src\ADUserLifecycle\ADUserLifecycle.psd1'
Import-Module -Name $modulePath -Force
$config = if ($ConfigPath) { Import-LifecycleConfig -Path $ConfigPath } else { Import-LifecycleConfig }
Set-LifecycleAuditContext -Source 'tarea-programada'

$processed = Join-Path -Path $InboxFolder -ChildPath 'procesados'
$failed = Join-Path -Path $InboxFolder -ChildPath 'con_errores'
foreach ($folder in @($processed, $failed)) {
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -Path $folder -ItemType Directory -WhatIf:$false | Out-Null }
}

$files = @(Get-ChildItem -LiteralPath $InboxFolder -Filter '*.csv' -File | Sort-Object -Property LastWriteTime)
foreach ($file in $files) {
    Write-Output "Procesando $($file.Name)..."
    try {
        $summary = Invoke-LifecycleBatch -Path $file.FullName -Config $config -Confirm:$false
        Write-Output ("  OK: {0} | Advertencias: {1} | Errores: {2} | Reporte: {3}" -f $summary.OK, $summary.Advertencias, $summary.Errores, $summary.ReportHtml)
        $destination = if ($summary.Errores -gt 0) { $failed } else { $processed }
    }
    catch {
        Write-Warning "No se pudo procesar $($file.Name): $($_.Exception.Message)"
        $destination = $failed
    }
    if (-not $WhatIfPreference) {
        $target = Join-Path -Path $destination -ChildPath ('{0}_{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $file.Name)
        Move-Item -LiteralPath $file.FullName -Destination $target
    }
}

if ($PurgeExpired) {
    Remove-ExpiredDisabledUsers -Config $config -Confirm:$false | Format-Table -AutoSize | Out-String | Write-Output
}
