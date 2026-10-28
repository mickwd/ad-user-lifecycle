function Set-LifecycleUserTransfer {
    <#
    .SYNOPSIS
    Cambio de área o puesto: recalcula grupos del rol y mueve la cuenta de OU.

    .DESCRIPTION
    Solo se tocan los grupos "administrados" por el mapeo de roles: se quitan los que
    correspondían al rol anterior y ya no corresponden al nuevo, y se agregan los que
    faltan. Los grupos asignados a mano (fuera del mapeo) no se modifican.

    .EXAMPLE
    Set-LifecycleUserTransfer -Identity jperez -NuevaArea Finanzas -NuevoPuesto 'Analista Contable' -Ticket 'RRHH-1010'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('usuario', 'SamAccountName')]
        [ValidateNotNullOrEmpty()] [string] $Identity,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('area')]
        [ValidateNotNullOrEmpty()] [string] $NuevaArea,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('puesto')]
        [ValidateNotNullOrEmpty()] [string] $NuevoPuesto,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()] [string] $Ticket,

        [pscustomobject] $Config
    )

    begin {
        $Config = Resolve-LifecycleConfig -Config $Config
        Assert-LifecycleADModule
        $ad = Get-LifecycleADConnectionParam -Config $Config
    }

    process {
        $user = Get-ADUser -Identity $Identity -Properties Department, Title @ad -ErrorAction Stop
        $sam = [string]$user.SamAccountName
        if (-not (Get-LifecycleObjectProperty -InputObject $user -Name 'Enabled')) {
            throw "La cuenta '$sam' está deshabilitada; un cambio de área no aplica a una baja."
        }

        $oldArea = [string](Get-LifecycleObjectProperty -InputObject $user -Name 'Department')
        $oldPuesto = [string](Get-LifecycleObjectProperty -InputObject $user -Name 'Title')
        $targetOU = Get-LifecycleTargetOU -Area $NuevaArea -Config $Config
        $currentOU = Get-LifecycleParentDN -DistinguishedName $user.DistinguishedName

        $oldManaged = @(Get-LifecycleRoleGroup -Area $oldArea -Puesto $oldPuesto -Config $Config)
        $newManaged = @(Get-LifecycleRoleGroup -Area $NuevaArea -Puesto $NuevoPuesto -Config $Config)
        $current = @(Get-ADPrincipalGroupMembership -Identity $sam @ad | ForEach-Object { [string]$_.Name })

        $toRemove = @($oldManaged | Where-Object { ($newManaged -notcontains $_) -and ($current -contains $_) })
        $toAdd = @($newManaged | Where-Object { $current -notcontains $_ })
        $moveOU = ($currentOU -ne $targetOU)

        $result = [pscustomobject]@{
            Action         = 'cambio'
            SamAccountName = $sam
            PreviousArea   = $oldArea
            NewArea        = $NuevaArea
            NewPuesto      = $NuevoPuesto
            GroupsAdded    = $toAdd
            GroupsRemoved  = $toRemove
            OU             = $targetOU
            Moved          = $moveOU
            Ticket         = $Ticket
            Status         = 'Simulado'
            Warnings       = New-Object System.Collections.Generic.List[string]
        }

        $plan = "Cambio $oldArea/$oldPuesto -> $NuevaArea/$NuevoPuesto. Quitar [$($toRemove -join ', ')], agregar [$($toAdd -join ', ')]"
        if ($moveOU) { $plan += ", mover a '$targetOU'" }
        if (-not $PSCmdlet.ShouldProcess($sam, $plan)) {
            Write-LifecycleAuditLog -Action 'cambio' -Target $sam -Ticket $Ticket -Result 'simulado' -Config $Config -Details @{
                from = "$oldArea/$oldPuesto"; to = "$NuevaArea/$NuevoPuesto"; add = $toAdd; remove = $toRemove
            }
            return $result
        }

        Set-ADUser -Identity $sam -Department $NuevaArea -Title $NuevoPuesto @ad -ErrorAction Stop

        foreach ($group in $toRemove) {
            try { Remove-ADGroupMember -Identity $group -Members $sam -Confirm:$false @ad -ErrorAction Stop }
            catch { $result.Warnings.Add("No se pudo quitar de '$group': $($_.Exception.Message)") }
        }
        foreach ($group in $toAdd) {
            try { Add-ADGroupMember -Identity $group -Members $sam @ad -ErrorAction Stop }
            catch { $result.Warnings.Add("No se pudo agregar a '$group': $($_.Exception.Message)") }
        }
        if ($moveOU) {
            Move-ADObject -Identity $user.DistinguishedName -TargetPath $targetOU @ad -ErrorAction Stop
        }

        $result.Status = if ($result.Warnings.Count -gt 0) { 'Advertencia' } else { 'OK' }
        $auditResult = if ($result.Warnings.Count -gt 0) { 'advertencia' } else { 'ok' }
        Write-LifecycleAuditLog -Action 'cambio' -Target $sam -Ticket $Ticket -Result $auditResult -Config $Config -Details @{
            from     = "$oldArea/$oldPuesto"
            to       = "$NuevaArea/$NuevoPuesto"
            add      = $toAdd
            remove   = $toRemove
            ou       = $targetOU
            warnings = $result.Warnings.ToArray()
        }
        return $result
    }
}
