function Disable-LifecycleUser {
    <#
    .SYNOPSIS
    Baja (offboarding) de un usuario.

    .DESCRIPTION
    Pasos, en este orden:
    1. Guarda un snapshot JSON con los grupos actuales (permite revertir una baja errónea).
    2. Deshabilita la cuenta y le asigna una contraseña aleatoria.
    3. Quita todos los grupos salvo los de Offboarding.KeepGroups (Domain Users).
    4. Escribe la descripción "Baja yyyy-MM-dd | Ticket X | operador" (la usa
       Remove-ExpiredDisabledUsers para calcular la antigüedad de la baja).
    5. Si la cuenta tiene buzón, la oculta de la GAL (msExchHideFromAddressLists).
    6. Comprime la carpeta personal en el share de archivo.
    7. Mueve la cuenta a la OU de Bajas (último paso porque cambia el DN).

    .EXAMPLE
    Disable-LifecycleUser -Identity jperez -Ticket 'INC-2045'

    .EXAMPLE
    Disable-LifecycleUser -Identity jperez -Ticket 'INC-2045' -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('usuario', 'SamAccountName')]
        [ValidateNotNullOrEmpty()] [string] $Identity,

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
        $user = Get-ADUser -Identity $Identity -Properties * @ad -ErrorAction Stop
        $sam = [string]$user.SamAccountName
        $dn = [string]$user.DistinguishedName
        $bajasOU = [string]$Config.OUs.Bajas
        $enabled = [bool](Get-LifecycleObjectProperty -InputObject $user -Name 'Enabled')

        if (-not $enabled -and (Get-LifecycleParentDN -DistinguishedName $dn) -eq $bajasOU) {
            throw "La cuenta '$sam' ya está deshabilitada y en la OU de Bajas."
        }

        $keep = @($Config.Offboarding.KeepGroups)
        $groups = @(Get-ADPrincipalGroupMembership -Identity $sam @ad)
        $toRemove = @($groups | Where-Object { $keep -notcontains [string]$_.Name })

        $now = Get-Date
        $stamp = $now.ToString('yyyyMMdd-HHmmss')
        $operator = Get-LifecycleOperator
        $description = 'Baja {0} | Ticket {1} | {2}' -f $now.ToString('yyyy-MM-dd'), $Ticket, $operator
        $snapshotPath = Join-Path -Path $Config.Offboarding.SnapshotFolder -ChildPath ('{0}_{1}.json' -f $sam, $stamp)

        $homeDirectory = [string](Get-LifecycleObjectProperty -InputObject $user -Name 'HomeDirectory')
        $hasMailbox = $null -ne (Get-LifecycleObjectProperty -InputObject $user -Name 'mailNickname') -or
            $null -ne (Get-LifecycleObjectProperty -InputObject $user -Name 'msExchHideFromAddressLists')

        $result = [pscustomobject]@{
            Action         = 'baja'
            SamAccountName = $sam
            GroupsRemoved  = @($toRemove | ForEach-Object { [string]$_.Name })
            SnapshotPath   = $snapshotPath
            ArchivePath    = $null
            OU             = $bajasOU
            Ticket         = $Ticket
            Status         = 'Simulado'
            Warnings       = New-Object System.Collections.Generic.List[string]
        }

        $plan = "Deshabilitar, resetear contraseña, quitar $($toRemove.Count) grupo(s), archivar carpeta y mover a '$bajasOU'"
        if (-not $PSCmdlet.ShouldProcess($sam, $plan)) {
            Write-LifecycleAuditLog -Action 'baja' -Target $sam -Ticket $Ticket -Result 'simulado' -Config $Config -Details @{
                groups = $result.GroupsRemoved
            }
            return $result
        }

        # 1. Snapshot de membresías antes de tocar nada.
        $snapshot = [ordered]@{
            samAccountName    = $sam
            distinguishedName = $dn
            ticket            = $Ticket
            fechaBaja         = $now.ToString('o')
            operador          = $operator
            grupos            = @($groups | ForEach-Object {
                    [ordered]@{
                        name              = [string]$_.Name
                        distinguishedName = [string](Get-LifecycleObjectProperty -InputObject $_ -Name 'DistinguishedName')
                        sid               = [string](Get-LifecycleObjectProperty -InputObject $_ -Name 'SID')
                    }
                })
        }
        [void][System.IO.Directory]::CreateDirectory($Config.Offboarding.SnapshotFolder)
        $encoding = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($snapshotPath, (ConvertTo-Json -InputObject $snapshot -Depth 5), $encoding)

        # 2. Deshabilitar y resetear contraseña.
        Disable-ADAccount -Identity $sam @ad -ErrorAction Stop
        $randomPassword = New-LifecyclePassword -Length ([int]$Config.Password.Length) -SamAccountName $sam
        Set-ADAccountPassword -Identity $sam -Reset -NewPassword $randomPassword @ad -ErrorAction Stop

        # 3. Quitar grupos.
        foreach ($group in $toRemove) {
            $groupId = Get-LifecycleObjectProperty -InputObject $group -Name 'DistinguishedName'
            if (-not $groupId) { $groupId = [string]$group.Name }
            try { Remove-ADGroupMember -Identity $groupId -Members $sam -Confirm:$false @ad -ErrorAction Stop }
            catch { $result.Warnings.Add("No se pudo quitar de '$($group.Name)': $($_.Exception.Message)") }
        }

        # 4. Descripción con fecha y ticket.
        Set-ADUser -Identity $sam -Description $description @ad -ErrorAction Stop

        # 5. Ocultar de la libreta global si tiene buzón.
        if ($hasMailbox) {
            try { Set-ADUser -Identity $sam -Replace @{ msExchHideFromAddressLists = $true } @ad -ErrorAction Stop }
            catch { $result.Warnings.Add("No se pudo ocultar de la GAL: $($_.Exception.Message)") }
        }

        # 6. Archivar carpeta personal.
        if ($homeDirectory -and (Test-Path -LiteralPath $homeDirectory)) {
            try {
                [void][System.IO.Directory]::CreateDirectory($Config.HomeFolders.ArchiveRoot)
                $zipPath = Join-Path -Path $Config.HomeFolders.ArchiveRoot -ChildPath ('{0}_{1}.zip' -f $sam, $stamp)
                Compress-Archive -Path $homeDirectory -DestinationPath $zipPath -CompressionLevel Optimal -ErrorAction Stop
                $result.ArchivePath = $zipPath
                if ($Config.Offboarding.RemoveHomeAfterArchive) {
                    Remove-Item -LiteralPath $homeDirectory -Recurse -Force -ErrorAction Stop
                }
            }
            catch {
                $result.Warnings.Add("No se pudo archivar la carpeta '$homeDirectory': $($_.Exception.Message)")
            }
        }
        elseif ($homeDirectory) {
            $result.Warnings.Add("La carpeta personal '$homeDirectory' no existe; no se archivó nada.")
        }

        # 7. Mover a Bajas.
        Move-ADObject -Identity $dn -TargetPath $bajasOU @ad -ErrorAction Stop

        $result.Status = if ($result.Warnings.Count -gt 0) { 'Advertencia' } else { 'OK' }
        $auditResult = if ($result.Warnings.Count -gt 0) { 'advertencia' } else { 'ok' }
        Write-LifecycleAuditLog -Action 'baja' -Target $sam -Ticket $Ticket -Result $auditResult -Config $Config -Details @{
            groupsRemoved = $result.GroupsRemoved
            snapshot      = $snapshotPath
            archive       = $result.ArchivePath
            hiddenFromGal = $hasMailbox
            warnings      = $result.Warnings.ToArray()
        }
        return $result
    }
}
