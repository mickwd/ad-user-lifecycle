function Write-LifecycleAuditLog {
    <#
    .SYNOPSIS
    Agrega una línea JSON al log de auditoría (formato JSON lines, UTF-8 sin BOM).
    Se escribe también en modo -WhatIf (con result = "simulado") para dejar registro
    de las simulaciones.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Action,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Target,
        [AllowEmptyString()] [string] $Ticket = '',
        [ValidateSet('ok', 'advertencia', 'error', 'simulado')] [string] $Result = 'ok',
        [System.Collections.IDictionary] $Details = @{},
        [Parameter(Mandatory)] $Config
    )

    $entry = [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        operator  = Get-LifecycleOperator
        host      = $env:COMPUTERNAME
        action    = $Action
        target    = $Target
        ticket    = $Ticket
        result    = $Result
        details   = $Details
        context   = $script:AuditContext
    }
    $line = ConvertTo-Json -InputObject $entry -Compress -Depth 6

    $logPath = [string]$Config.Audit.LogPath
    $directory = Split-Path -Path $logPath -Parent
    if ($directory) { [void][System.IO.Directory]::CreateDirectory($directory) }
    $encoding = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::AppendAllText($logPath, $line + "`n", $encoding)
}

function Set-LifecycleAuditContext {
    <#
    .SYNOPSIS
    Define datos de contexto que se agregan a cada línea de auditoría (id de solicitud,
    quién la pidió, quién la aprobó, origen). Lo usa run_request.ps1 al ejecutar
    solicitudes que vienen de la API.

    .EXAMPLE
    Set-LifecycleAuditContext -RequestId 42 -ApprovedBy 'mgarcia' -Source 'api'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Solo modifica estado en memoria del módulo.')]
    [CmdletBinding()]
    param(
        [string] $RequestId,
        [string] $RequestedBy,
        [string] $ApprovedBy,
        [string] $Source
    )

    $context = [ordered]@{}
    if ($RequestId) { $context['request_id'] = $RequestId }
    if ($RequestedBy) { $context['requested_by'] = $RequestedBy }
    if ($ApprovedBy) { $context['approved_by'] = $ApprovedBy }
    if ($Source) { $context['source'] = $Source }
    $script:AuditContext = $context
}
