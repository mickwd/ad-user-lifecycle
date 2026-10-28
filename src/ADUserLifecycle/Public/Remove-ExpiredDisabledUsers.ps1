function Remove-ExpiredDisabledUsers {
    <#
    .SYNOPSIS
    Elimina las cuentas de la OU de Bajas que llevan más de N días deshabilitadas.

    .DESCRIPTION
    La fecha de baja se toma de la descripción que escribe Disable-LifecycleUser
    ("Baja yyyy-MM-dd | ..."). Por seguridad se omiten:
    - cuentas sin fecha de baja reconocible (no se adivina con whenChanged),
    - cuentas privilegiadas (adminCount = 1),
    - cuentas que siguen habilitadas.
    Se usa Remove-ADObject -Recursive porque algunas cuentas tienen objetos hijos
    (por ejemplo dispositivos de ActiveSync) y Remove-ADUser falla en ese caso.

    .EXAMPLE
    Remove-ExpiredDisabledUsers -Days 90 -WhatIf

    .EXAMPLE
    Remove-ExpiredDisabledUsers -Confirm:$false   # para la tarea programada
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Nombre pedido por el proceso: opera sobre un conjunto de cuentas.')]
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [ValidateRange(1, 3650)] [int] $Days,
        [datetime] $ReferenceDate = (Get-Date),
        [pscustomobject] $Config
    )

    $Config = Resolve-LifecycleConfig -Config $Config
    Assert-LifecycleADModule
    $ad = Get-LifecycleADConnectionParam -Config $Config
    if (-not $PSBoundParameters.ContainsKey('Days')) { $Days = [int]$Config.Offboarding.RetentionDays }

    $users = @(Get-ADUser -Filter 'Enabled -eq $false' -SearchBase $Config.OUs.Bajas -SearchScope OneLevel `
            -Properties Description, adminCount @ad)

    foreach ($user in $users) {
        $sam = [string]$user.SamAccountName
        $item = [pscustomobject]@{
            SamAccountName = $sam
            FechaBaja      = $null
            DiasBaja       = $null
            Estado         = $null
            Detalle        = ''
        }

        if ([int](Get-LifecycleObjectProperty -InputObject $user -Name 'adminCount') -eq 1) {
            $item.Estado = 'Omitido'
            $item.Detalle = 'Cuenta privilegiada (adminCount = 1): revisar manualmente.'
            Write-Warning "$sam omitido: $($item.Detalle)"
            $item
            continue
        }

        $description = [string](Get-LifecycleObjectProperty -InputObject $user -Name 'Description')
        if ($description -notmatch '^Baja (\d{4}-\d{2}-\d{2})') {
            $item.Estado = 'Omitido'
            $item.Detalle = 'Sin fecha de baja en la descripción.'
            Write-Warning "$sam omitido: $($item.Detalle)"
            $item
            continue
        }

        $fechaBaja = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        $age = [int][math]::Floor(($ReferenceDate.Date - $fechaBaja).TotalDays)
        $item.FechaBaja = $fechaBaja.ToString('yyyy-MM-dd')
        $item.DiasBaja = $age

        if ($age -lt $Days) {
            $item.Estado = 'Vigente'
            $item
            continue
        }

        if ($PSCmdlet.ShouldProcess($sam, "Eliminar cuenta deshabilitada hace $age días")) {
            try {
                Remove-ADObject -Identity $user.DistinguishedName -Recursive -Confirm:$false @ad -ErrorAction Stop
                $item.Estado = 'Eliminado'
                Write-LifecycleAuditLog -Action 'eliminacion' -Target $sam -Result 'ok' -Config $Config -Details @{
                    fechaBaja = $item.FechaBaja; dias = $age; retencion = $Days
                }
            }
            catch {
                $item.Estado = 'Error'
                $item.Detalle = $_.Exception.Message
                Write-LifecycleAuditLog -Action 'eliminacion' -Target $sam -Result 'error' -Config $Config -Details @{
                    error = $_.Exception.Message
                }
            }
        }
        elseif ($WhatIfPreference) {
            $item.Estado = 'Simulado'
        }
        else {
            $item.Estado = 'Omitido'
            $item.Detalle = 'El operador no confirmó la eliminación.'
        }
        $item
    }
}
