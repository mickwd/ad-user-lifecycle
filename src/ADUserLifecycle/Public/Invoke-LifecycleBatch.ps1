$script:BatchRequiredFields = @{
    alta   = @('nombre', 'apellido', 'legajo', 'area', 'puesto', 'ticket')
    baja   = @('usuario', 'ticket')
    cambio = @('usuario', 'area', 'puesto', 'ticket')
}

function Get-LifecycleCsvDelimiter {
    <#
    .SYNOPSIS
    Detecta el separador mirando el encabezado: Excel en español exporta con ";".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Path)

    $header = Get-Content -LiteralPath $Path -TotalCount 1 -Encoding UTF8
    if ($header -and $header.Contains(';') -and -not $header.Contains(',')) { return ';' }
    return ','
}

function ConvertTo-LifecycleBatchHtml {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [object[]] $Results,
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [string] $Summary
    )

    $css = @'
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #1f2933; }
h1 { font-size: 20px; }
table { border-collapse: collapse; width: 100%; font-size: 13px; }
th, td { border: 1px solid #d0d7de; padding: 6px 8px; text-align: left; vertical-align: top; }
th { background: #f3f4f6; }
td.estado-OK { color: #116329; font-weight: 600; }
td.estado-Advertencia { color: #9a6700; font-weight: 600; }
td.estado-Error { color: #cf222e; font-weight: 600; }
td.estado-Simulado { color: #0969da; font-weight: 600; }
</style>
'@
    $encodedTitle = [System.Net.WebUtility]::HtmlEncode($Title)
    $encodedSummary = [System.Net.WebUtility]::HtmlEncode($Summary)
    $table = $Results | Select-Object Fila, Accion, Usuario, Legajo, Ticket, Estado, Detalle | ConvertTo-Html -Fragment
    $table = ($table -join "`n") -replace '<td>(OK|Advertencia|Error|Simulado)</td>', '<td class="estado-$1">$1</td>'
    return @"
<!DOCTYPE html>
<html lang="es">
<head><meta charset="utf-8"><title>$encodedTitle</title>
$css
</head>
<body>
<h1>$encodedTitle</h1>
<p>$encodedSummary</p>
$table
</body>
</html>
"@
}

function Invoke-LifecycleBatch {
    <#
    .SYNOPSIS
    Procesa un CSV de altas, bajas y cambios y genera un reporte CSV + HTML.

    .DESCRIPTION
    Columnas: accion (alta|baja|cambio), nombre, apellido, legajo, area, puesto, manager,
    fecha_ingreso, usuario, ticket. Cada fila se procesa en su propio try/catch: un error
    en una fila queda en el reporte y el lote sigue con la siguiente.

    Con -WhatIf no se modifica AD pero sí se genera el reporte (Estado = Simulado), útil
    para validar el archivo de RRHH antes de correrlo en serio.

    .PARAMETER CredentialExportPath
    Opcional. CSV donde se guardan las contraseñas temporales de las altas cifradas con
    DPAPI (solo las puede descifrar la misma cuenta en el mismo equipo).

    .EXAMPLE
    Invoke-LifecycleBatch -Path .\scripts\ejemplo_lote.csv -WhatIf
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'CredentialExportPath', Justification = 'Es una ruta de archivo, no una credencial.')]
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string] $Path,

        [string] $ReportFolder,

        [ValidateSet(',', ';')] [string] $Delimiter,

        [string] $CredentialExportPath,

        [pscustomobject] $Config
    )

    $Config = Resolve-LifecycleConfig -Config $Config
    if (-not $ReportFolder) { $ReportFolder = [string]$Config.Batch.ReportFolder }
    if (-not $Delimiter) { $Delimiter = Get-LifecycleCsvDelimiter -Path $Path }

    $rows = @(Import-Csv -LiteralPath $Path -Delimiter $Delimiter -Encoding UTF8)
    $started = Get-Date
    $results = New-Object System.Collections.Generic.List[object]
    $credentials = New-Object System.Collections.Generic.List[object]
    $rowNumber = 0

    foreach ($row in $rows) {
        $rowNumber++
        $field = @{}
        foreach ($property in $row.PSObject.Properties) {
            $field[$property.Name.Trim().ToLowerInvariant()] = ([string]$property.Value).Trim()
        }
        $accion = if ($field.ContainsKey('accion')) { $field['accion'].ToLowerInvariant() } else { '' }
        $ticket = if ($field.ContainsKey('ticket')) { $field['ticket'] } else { '' }

        $entry = [pscustomobject]@{
            Fila    = $rowNumber
            Accion  = $accion
            Usuario = if ($field.ContainsKey('usuario')) { $field['usuario'] } else { '' }
            Legajo  = if ($field.ContainsKey('legajo')) { $field['legajo'] } else { '' }
            Ticket  = $ticket
            Estado  = ''
            Detalle = ''
        }

        try {
            if (-not $script:BatchRequiredFields.ContainsKey($accion)) {
                throw "Acción desconocida '$accion'. Valores válidos: alta, baja, cambio."
            }
            $missing = @($script:BatchRequiredFields[$accion] | Where-Object { -not $field[$_] })
            if ($missing.Count -gt 0) {
                throw "Faltan campos obligatorios para '$accion': $($missing -join ', ')"
            }

            switch ($accion) {
                'alta' {
                    $outcome = New-LifecycleUser -Nombre $field['nombre'] -Apellido $field['apellido'] `
                        -Legajo $field['legajo'] -Area $field['area'] -Puesto $field['puesto'] `
                        -Manager $field['manager'] -FechaIngreso $field['fecha_ingreso'] `
                        -Ticket $ticket -Config $Config -ErrorAction Stop
                }
                'baja' {
                    $outcome = Disable-LifecycleUser -Identity $field['usuario'] -Ticket $ticket -Config $Config -ErrorAction Stop
                }
                'cambio' {
                    $outcome = Set-LifecycleUserTransfer -Identity $field['usuario'] -NuevaArea $field['area'] `
                        -NuevoPuesto $field['puesto'] -Ticket $ticket -Config $Config -ErrorAction Stop
                }
            }

            $entry.Usuario = [string]$outcome.SamAccountName
            $entry.Estado = [string]$outcome.Status
            $entry.Detalle = (@($outcome.Warnings) -join ' | ')

            $tempPassword = Get-LifecycleObjectProperty -InputObject $outcome -Name 'TemporaryPassword'
            if ($CredentialExportPath -and $tempPassword) {
                $credentials.Add([pscustomobject]@{
                        SamAccountName  = $outcome.SamAccountName
                        PasswordCifrada = ConvertFrom-SecureString -SecureString $tempPassword
                    })
            }
        }
        catch {
            $entry.Estado = 'Error'
            $entry.Detalle = $_.Exception.Message
            Write-LifecycleAuditLog -Action "lote-$accion" -Target $entry.Usuario -Ticket $ticket -Result 'error' -Config $Config -Details @{
                fila = $rowNumber; archivo = $Path; error = $_.Exception.Message
            }
            Write-Warning "Fila ${rowNumber}: $($_.Exception.Message)"
        }
        $results.Add($entry)
    }

    # Los reportes se generan también en -WhatIf: son la salida de la simulación.
    [void][System.IO.Directory]::CreateDirectory($ReportFolder)
    $baseName = 'lote_{0}' -f $started.ToString('yyyyMMdd-HHmmss')
    $csvReport = Join-Path -Path $ReportFolder -ChildPath "$baseName.csv"
    $htmlReport = Join-Path -Path $ReportFolder -ChildPath "$baseName.html"

    $ok = @($results | Where-Object { $_.Estado -eq 'OK' }).Count
    $warn = @($results | Where-Object { $_.Estado -eq 'Advertencia' }).Count
    $errors = @($results | Where-Object { $_.Estado -eq 'Error' }).Count
    $simulated = @($results | Where-Object { $_.Estado -eq 'Simulado' }).Count
    $summaryText = 'Archivo: {0} | Filas: {1} | OK: {2} | Advertencias: {3} | Errores: {4} | Simuladas: {5} | Inicio: {6}' -f `
        (Split-Path -Path $Path -Leaf), $results.Count, $ok, $warn, $errors, $simulated, $started.ToString('yyyy-MM-dd HH:mm:ss')

    $results | Export-Csv -LiteralPath $csvReport -NoTypeInformation -Encoding UTF8 -WhatIf:$false
    $html = ConvertTo-LifecycleBatchHtml -Results $results.ToArray() -Title "Reporte de lote ABM - $baseName" -Summary $summaryText
    [System.IO.File]::WriteAllText($htmlReport, $html, (New-Object System.Text.UTF8Encoding $false))

    if ($CredentialExportPath -and $credentials.Count -gt 0) {
        $credentials | Export-Csv -LiteralPath $CredentialExportPath -NoTypeInformation -Encoding UTF8 -Append -WhatIf:$false
    }

    $auditResult = if ($WhatIfPreference) { 'simulado' } elseif ($errors -gt 0) { 'advertencia' } else { 'ok' }
    Write-LifecycleAuditLog -Action 'lote' -Target (Split-Path -Path $Path -Leaf) -Result $auditResult -Config $Config -Details @{
        total = $results.Count; ok = $ok; advertencias = $warn; errores = $errors; reporte = $csvReport
    }

    return [pscustomobject]@{
        Total        = $results.Count
        OK           = $ok
        Advertencias = $warn
        Errores      = $errors
        Simuladas    = $simulated
        ReportCsv    = $csvReport
        ReportHtml   = $htmlReport
        Results      = $results.ToArray()
    }
}
