<#
.SYNOPSIS
Registra en el Programador de tareas la ejecución diaria del lote de ABM.

.DESCRIPTION
La tarea corre Invoke-ScheduledBatch.ps1 con Windows PowerShell 5.1. Se recomienda
usar una cuenta de servicio administrada de grupo (gMSA) con permisos delegados solo
sobre las OU de usuarios (ver README, sección "Permisos en AD"): no hace falta guardar
ninguna contraseña y la rota el dominio.

Para una gMSA el UserId lleva el "$" final, por ejemplo CONTOSO\gmsa-abm$.

.EXAMPLE
.\Register-ScheduledBatch.ps1 -InboxFolder D:\ABM\entrada -ServiceAccount 'CONTOSO\gmsa-abm$' -At '06:30' -WhatIf

.EXAMPLE
.\Register-ScheduledBatch.ps1 -InboxFolder D:\ABM\entrada -ServiceAccount 'CONTOSO\gmsa-abm$' -PurgeExpired
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $InboxFolder,
    [Parameter(Mandatory)] [ValidatePattern('^[^\\]+\\[^\\]+\$$')] [string] $ServiceAccount,
    [string] $TaskName = 'ADUserLifecycle - Lote ABM diario',
    [string] $TaskPath = '\ADUserLifecycle\',
    [string] $At = '06:30',
    [string] $ConfigPath,
    [switch] $PurgeExpired
)

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-ScheduledBatch.ps1'
$scriptPath = (Resolve-Path -LiteralPath $scriptPath).ProviderPath

$arguments = @(
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'RemoteSigned',
    '-File', ('"{0}"' -f $scriptPath),
    '-InboxFolder', ('"{0}"' -f $InboxFolder)
)
if ($ConfigPath) { $arguments += @('-ConfigPath', ('"{0}"' -f $ConfigPath)) }
if ($PurgeExpired) { $arguments += '-PurgeExpired' }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($arguments -join ' ') -WorkingDirectory (Split-Path -Path $scriptPath -Parent)
$trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::ParseExact($At, 'HH:mm', [System.Globalization.CultureInfo]::InvariantCulture))
# LogonType Password + cuenta terminada en $ = gMSA: el sistema obtiene la contraseña del dominio.
$principal = New-ScheduledTaskPrincipal -UserId $ServiceAccount -LogonType Password -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew -StartWhenAvailable

if ($PSCmdlet.ShouldProcess("$TaskPath$TaskName", "Registrar tarea diaria a las $At como $ServiceAccount")) {
    Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings `
        -Description 'Procesa los CSV de altas, bajas y cambios de RRHH con el módulo ADUserLifecycle.' -Force
}
