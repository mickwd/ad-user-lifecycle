# SIDs bien conocidos: no dependen del idioma del sistema operativo.
$script:SidBuiltinAdministrators = 'S-1-5-32-544'
$script:SidLocalSystem = 'S-1-5-18'

function Set-LifecycleHomeFolderAcl {
    <#
    .SYNOPSIS
    Deja la carpeta personal con permisos explícitos: corta la herencia, da control total
    a Administradores y SYSTEM y el permiso configurado (Modify por defecto) al usuario.

    .DESCRIPTION
    Se usa el SID devuelto por New-ADUser en lugar de DOMINIO\usuario: así no falla si
    el servidor de archivos consulta un DC al que todavía no replicó la cuenta nueva.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Sid,
        [System.Security.AccessControl.FileSystemRights] $Rights = 'Modify'
    )

    $acl = Get-Acl -LiteralPath $Path
    # true, false: protege contra herencia y descarta las reglas heredadas del share raíz.
    $acl.SetAccessRuleProtection($true, $false)

    $inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow

    $rules = @(
        @{ Sid = $script:SidBuiltinAdministrators; Rights = [System.Security.AccessControl.FileSystemRights]::FullControl },
        @{ Sid = $script:SidLocalSystem; Rights = [System.Security.AccessControl.FileSystemRights]::FullControl },
        @{ Sid = $Sid; Rights = $Rights }
    )
    foreach ($item in $rules) {
        $identity = New-Object System.Security.Principal.SecurityIdentifier($item.Sid)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, $item.Rights, $inheritance, $propagation, $allow)
        $acl.AddAccessRule($rule)
    }

    if ($PSCmdlet.ShouldProcess($Path, "Aplicar ACL de carpeta personal para $Sid")) {
        Set-Acl -LiteralPath $Path -AclObject $acl
    }
}
