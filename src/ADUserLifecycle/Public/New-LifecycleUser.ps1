function New-LifecycleUser {
    <#
    .SYNOPSIS
    Alta de usuario en Active Directory a partir de un registro de RRHH.

    .DESCRIPTION
    - Verifica que no exista otra cuenta con el mismo legajo (EmployeeID), lo que hace
      idempotente el reproceso de un lote.
    - Genera un sAMAccountName único (jperez, jperez2, ...).
    - Genera una contraseña temporal que cumple la política y obliga a cambiarla al iniciar sesión.
    - Ubica la cuenta en la OU del área y la agrega a los grupos del rol según la configuración.
    - Crea la carpeta personal en el file server con ACL explícita y setea HomeDirectory.
    - Registra todo en el log de auditoría.

    Los errores al agregar grupos o crear la carpeta no cortan el alta: se informan como
    advertencias (Status = Advertencia) para que mesa de ayuda los complete a mano.

    .EXAMPLE
    New-LifecycleUser -Nombre 'Juan' -Apellido 'Pérez' -Legajo 10234 -Area 'Sistemas' `
        -Puesto 'Analista de Soporte' -Manager 'mgarcia' -FechaIngreso '2026-11-02' -Ticket 'RRHH-1001'

    .EXAMPLE
    Import-Csv .\altas.csv | New-LifecycleUser -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()] [string] $Nombre,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()] [string] $Apellido,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidatePattern('^\d{1,10}$')] [string] $Legajo,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()] [string] $Area,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()] [string] $Puesto,

        [Parameter(ValueFromPipelineByPropertyName)]
        [AllowEmptyString()] [string] $Manager,

        [Parameter(ValueFromPipelineByPropertyName)]
        [Alias('fecha_ingreso')]
        [AllowEmptyString()] [string] $FechaIngreso,

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
        $Nombre = $Nombre.Trim()
        $Apellido = $Apellido.Trim()

        $existing = Get-ADUser -Filter "EmployeeID -eq '$Legajo'" @ad
        if ($existing) {
            $existingSam = Get-LifecycleObjectProperty -InputObject @($existing)[0] -Name 'SamAccountName'
            throw "Ya existe una cuenta con el legajo $Legajo ($existingSam). No se crea un duplicado."
        }

        $ou = Get-LifecycleTargetOU -Area $Area -Config $Config
        $groups = @(Get-LifecycleRoleGroup -Area $Area -Puesto $Puesto -Config $Config)
        $fecha = ConvertTo-LifecycleDate -Value $FechaIngreso
        $sam = New-LifecycleSamAccountName -Nombre $Nombre -Apellido $Apellido -Config $Config

        $displayName = '{0} {1}' -f $Nombre, $Apellido
        # El CN tiene que ser único dentro de la OU: si hubo colisión de nombre se agrega el usuario.
        $cn = if ($sam -match '\d+$') { '{0} ({1})' -f $displayName, $sam } else { $displayName }
        $upn = '{0}@{1}' -f $sam, $Config.Domain.UpnSuffix
        $homeDirectory = Join-Path -Path $Config.HomeFolders.Root -ChildPath $sam
        $fechaTexto = if ($fecha) { $fecha.ToString('yyyy-MM-dd') } else { (Get-Date).ToString('yyyy-MM-dd') }
        $description = 'Alta {0} | Ticket {1}' -f $fechaTexto, $Ticket

        $warnings = New-Object System.Collections.Generic.List[string]
        $managerDn = $null
        if ($Manager) {
            try {
                $managerDn = (Get-ADUser -Identity $Manager @ad -ErrorAction Stop).DistinguishedName
            }
            catch {
                $warnings.Add("No se encontró el manager '$Manager'; la cuenta se crea sin manager.")
            }
        }

        $result = [pscustomobject]@{
            Action            = 'alta'
            SamAccountName    = $sam
            UserPrincipalName = $upn
            DisplayName       = $displayName
            Legajo            = $Legajo
            OU                = $ou
            Groups            = $groups
            HomeDirectory     = $homeDirectory
            Ticket            = $Ticket
            Status            = 'Simulado'
            Warnings          = $warnings
            TemporaryPassword = $null
        }

        $plan = "Crear usuario en '$ou' con grupos [$($groups -join ', ')] y carpeta '$homeDirectory'"
        if (-not $PSCmdlet.ShouldProcess($sam, $plan)) {
            Write-LifecycleAuditLog -Action 'alta' -Target $sam -Ticket $Ticket -Result 'simulado' -Config $Config -Details @{
                legajo = $Legajo; ou = $ou; groups = $groups
            }
            return $result
        }

        $password = New-LifecyclePassword -Length ([int]$Config.Password.Length) -SamAccountName $sam -DisplayName $displayName
        $newUserParams = @{
            Name                  = $cn
            GivenName             = $Nombre
            Surname               = $Apellido
            DisplayName           = $displayName
            SamAccountName        = $sam
            UserPrincipalName     = $upn
            Path                  = $ou
            AccountPassword       = $password
            ChangePasswordAtLogon = $true
            Enabled               = $true
            EmployeeID            = $Legajo
            Department            = $Area
            Title                 = $Puesto
            Description           = $description
            HomeDirectory         = $homeDirectory
            HomeDrive             = [string]$Config.HomeFolders.Drive
            PassThru              = $true
            ErrorAction           = 'Stop'
        }
        if ($managerDn) { $newUserParams['Manager'] = $managerDn }

        try {
            $user = New-ADUser @newUserParams @ad
        }
        catch {
            Write-LifecycleAuditLog -Action 'alta' -Target $sam -Ticket $Ticket -Result 'error' -Config $Config -Details @{
                legajo = $Legajo; error = $_.Exception.Message
            }
            throw
        }

        $addedGroups = New-Object System.Collections.Generic.List[string]
        foreach ($group in $groups) {
            try {
                Add-ADGroupMember -Identity $group -Members $sam @ad -ErrorAction Stop
                $addedGroups.Add($group)
            }
            catch {
                $warnings.Add("No se pudo agregar a '$group': $($_.Exception.Message)")
            }
        }

        try {
            if (-not (Test-Path -LiteralPath $homeDirectory)) {
                New-Item -Path $homeDirectory -ItemType Directory -ErrorAction Stop | Out-Null
            }
            $sid = [string](Get-LifecycleObjectProperty -InputObject $user -Name 'SID')
            if (-not $sid) { throw 'New-ADUser no devolvió el SID de la cuenta.' }
            Set-LifecycleHomeFolderAcl -Path $homeDirectory -Sid $sid -Rights ([string]$Config.HomeFolders.Rights) -Confirm:$false
        }
        catch {
            $warnings.Add("No se pudo preparar la carpeta personal '$homeDirectory': $($_.Exception.Message)")
        }

        $result.Status = if ($warnings.Count -gt 0) { 'Advertencia' } else { 'OK' }
        $result.TemporaryPassword = $password
        $auditResult = if ($warnings.Count -gt 0) { 'advertencia' } else { 'ok' }
        Write-LifecycleAuditLog -Action 'alta' -Target $sam -Ticket $Ticket -Result $auditResult -Config $Config -Details @{
            legajo        = $Legajo
            ou            = $ou
            groups        = $addedGroups.ToArray()
            homeDirectory = $homeDirectory
            warnings      = $warnings.ToArray()
        }
        return $result
    }
}
