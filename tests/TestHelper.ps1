# Helper común de los tests.
#
# Define stubs globales de los cmdlets de ActiveDirectory para que los tests corran en
# equipos sin RSAT (y para garantizar que nunca se toque un dominio real). Pester necesita
# que el comando exista para poder mockearlo; los parámetros declarados acá son los que
# usa el módulo. Si un test llama a un stub sin Mock, falla de forma explícita.

function global:Get-ADUser {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] $Identity,
        [string] $Filter,
        [string[]] $Properties,
        [string] $SearchBase,
        [string] $SearchScope,
        [string] $Server
    )
    throw 'Stub Get-ADUser invocado sin Mock.'
}

function global:New-ADUser {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $Name, [string] $GivenName, [string] $Surname, [string] $DisplayName,
        [string] $SamAccountName, [string] $UserPrincipalName, [string] $Path,
        [securestring] $AccountPassword, [bool] $ChangePasswordAtLogon, [bool] $Enabled,
        [string] $EmployeeID, [string] $Department, [string] $Title, [string] $Manager,
        [string] $Description, [string] $HomeDirectory, [string] $HomeDrive,
        [switch] $PassThru, [string] $Server
    )
    throw 'Stub New-ADUser invocado sin Mock.'
}

function global:Set-ADUser {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)] $Identity,
        [string] $Description, [string] $Department, [string] $Title,
        [hashtable] $Replace, [string[]] $Clear, [string] $Server
    )
    throw 'Stub Set-ADUser invocado sin Mock.'
}

function global:Add-ADGroupMember {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Position = 0)] $Identity, $Members, [string] $Server)
    throw 'Stub Add-ADGroupMember invocado sin Mock.'
}

function global:Remove-ADGroupMember {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Position = 0)] $Identity, $Members, [string] $Server)
    throw 'Stub Remove-ADGroupMember invocado sin Mock.'
}

function global:Get-ADPrincipalGroupMembership {
    [CmdletBinding()]
    param([Parameter(Position = 0)] $Identity, [string] $Server)
    throw 'Stub Get-ADPrincipalGroupMembership invocado sin Mock.'
}

function global:Move-ADObject {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Position = 0)] $Identity, [string] $TargetPath, [string] $Server)
    throw 'Stub Move-ADObject invocado sin Mock.'
}

function global:Disable-ADAccount {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Position = 0)] $Identity, [string] $Server)
    throw 'Stub Disable-ADAccount invocado sin Mock.'
}

function global:Set-ADAccountPassword {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Position = 0)] $Identity, [switch] $Reset, [securestring] $NewPassword, [string] $Server)
    throw 'Stub Set-ADAccountPassword invocado sin Mock.'
}

function global:Remove-ADObject {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Position = 0)] $Identity, [switch] $Recursive, [string] $Server)
    throw 'Stub Remove-ADObject invocado sin Mock.'
}

# Lista de cmdlets que modifican AD: se usa para verificar que -WhatIf no llama a ninguno.
$global:ADMutators = @(
    'New-ADUser', 'Set-ADUser', 'Add-ADGroupMember', 'Remove-ADGroupMember',
    'Move-ADObject', 'Disable-ADAccount', 'Set-ADAccountPassword', 'Remove-ADObject'
)

$modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\src\ADUserLifecycle\ADUserLifecycle.psd1'
Import-Module -Name $modulePath -Force

function global:New-TestLifecycleConfig {
    <#
    .SYNOPSIS
    Crea un JSON de configuración apuntando a carpetas dentro de TestDrive y lo carga.
    #>
    param([Parameter(Mandatory)] [string] $Root)

    $config = [ordered]@{
        Domain      = @{ NetBIOS = 'CONTOSO'; UpnSuffix = 'contoso.local' }
        OUs         = @{
            Areas = [ordered]@{
                Sistemas  = 'OU=Sistemas,OU=Usuarios,DC=contoso,DC=local'
                Finanzas  = 'OU=Finanzas,OU=Usuarios,DC=contoso,DC=local'
                Comercial = 'OU=Comercial,OU=Usuarios,DC=contoso,DC=local'
            }
            Bajas = 'OU=Bajas,DC=contoso,DC=local'
        }
        RoleGroups  = @{
            Common  = @('GG_Todos_Empleados')
            Areas   = @{
                Sistemas  = @('GG_Sistemas')
                Finanzas  = @('GG_Finanzas')
                Comercial = @('GG_Comercial')
            }
            Puestos = @{
                'Analista de Soporte'       = @('GG_Helpdesk', 'GG_VPN')
                'Administrador de Sistemas' = @('GG_VPN', 'GG_Admins_Lectura')
                'Analista Contable'         = @('GG_ERP_Contabilidad', 'gg_todos_empleados')
            }
        }
        HomeFolders = @{
            Root        = (Join-Path $Root 'home')
            ArchiveRoot = (Join-Path $Root 'archivo')
        }
        Offboarding = @{ SnapshotFolder = 'bajas'; RetentionDays = 90 }
        Audit       = @{ LogPath = 'logs/audit.jsonl' }
        Batch       = @{ ReportFolder = 'reportes' }
    }
    $path = Join-Path $Root 'lifecycle.config.json'
    $config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
    return (Import-LifecycleConfig -Path $path)
}

function global:Get-TestAuditEntry {
    param([Parameter(Mandatory)] $Config)
    if (-not (Test-Path -LiteralPath $Config.Audit.LogPath)) { return @() }
    return @(Get-Content -LiteralPath $Config.Audit.LogPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
}
