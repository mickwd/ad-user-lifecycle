BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelper.ps1')
}

Describe 'Set-LifecycleUserTransfer' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -Path $root -ItemType Directory | Out-Null
        $cfg = New-TestLifecycleConfig -Root $root

        Mock Get-ADUser -ModuleName ADUserLifecycle {
            [pscustomobject]@{
                SamAccountName    = 'lgomez'
                DistinguishedName = 'CN=Lucía Gómez,OU=Sistemas,OU=Usuarios,DC=contoso,DC=local'
                Enabled           = $true
                Department        = 'Sistemas'
                Title             = 'Analista de Soporte'
            }
        }
        Mock Get-ADPrincipalGroupMembership -ModuleName ADUserLifecycle {
            @('Domain Users', 'GG_Todos_Empleados', 'GG_Sistemas', 'GG_Helpdesk', 'GG_VPN', 'GG_Proyecto_X') |
                ForEach-Object { [pscustomobject]@{ Name = $_ } }
        }
        foreach ($mutator in $global:ADMutators) {
            Mock $mutator -ModuleName ADUserLifecycle { }
        }
    }

    It 'pasa a otra área: quita grupos viejos, agrega nuevos y mueve de OU' {
        $result = Set-LifecycleUserTransfer -Identity 'lgomez' -NuevaArea 'Finanzas' -NuevoPuesto 'Analista Contable' -Ticket 'RRHH-1004' -Config $cfg

        $result.Status | Should -Be 'OK'
        @($result.GroupsRemoved) | Should -Be @('GG_Sistemas', 'GG_Helpdesk', 'GG_VPN')
        @($result.GroupsAdded) | Should -Be @('GG_Finanzas', 'GG_ERP_Contabilidad')
        Should -Invoke Remove-ADGroupMember -ModuleName ADUserLifecycle -Times 3 -Exactly
        Should -Invoke Add-ADGroupMember -ModuleName ADUserLifecycle -Times 2 -Exactly
        Should -Invoke Move-ADObject -ModuleName ADUserLifecycle -Times 1 -Exactly -ParameterFilter {
            $TargetPath -eq 'OU=Finanzas,OU=Usuarios,DC=contoso,DC=local'
        }
        Should -Invoke Set-ADUser -ModuleName ADUserLifecycle -Times 1 -Exactly -ParameterFilter {
            $Department -eq 'Finanzas' -and $Title -eq 'Analista Contable'
        }
    }

    It 'no toca grupos asignados fuera del mapeo ni los comunes' {
        Set-LifecycleUserTransfer -Identity 'lgomez' -NuevaArea 'Finanzas' -NuevoPuesto 'Analista Contable' -Ticket 'RRHH-1004' -Config $cfg | Out-Null
        Should -Invoke Remove-ADGroupMember -ModuleName ADUserLifecycle -Times 0 -Exactly -ParameterFilter {
            $Identity -in @('GG_Proyecto_X', 'GG_Todos_Empleados', 'Domain Users')
        }
    }

    It 'cambio de puesto dentro de la misma área: no mueve de OU y conserva grupos compartidos' {
        $result = Set-LifecycleUserTransfer -Identity 'lgomez' -NuevaArea 'Sistemas' -NuevoPuesto 'Administrador de Sistemas' -Ticket 'RRHH-1005' -Config $cfg

        $result.Moved | Should -BeFalse
        @($result.GroupsRemoved) | Should -Be @('GG_Helpdesk')
        @($result.GroupsAdded) | Should -Be @('GG_Admins_Lectura')
        Should -Invoke Move-ADObject -ModuleName ADUserLifecycle -Times 0 -Exactly
    }

    It 'rechaza el cambio sobre una cuenta deshabilitada' {
        Mock Get-ADUser -ModuleName ADUserLifecycle {
            [pscustomobject]@{ SamAccountName = 'lgomez'; DistinguishedName = 'CN=x,OU=Bajas,DC=contoso,DC=local'; Enabled = $false; Department = 'Sistemas'; Title = 'x' }
        }
        { Set-LifecycleUserTransfer -Identity 'lgomez' -NuevaArea 'Finanzas' -NuevoPuesto 'Analista Contable' -Ticket 'T-1' -Config $cfg } |
            Should -Throw '*deshabilitada*'
    }

    It 'con -WhatIf no llama a ningún mutador' {
        $result = Set-LifecycleUserTransfer -Identity 'lgomez' -NuevaArea 'Finanzas' -NuevoPuesto 'Analista Contable' -Ticket 'RRHH-1004' -Config $cfg -WhatIf
        $result.Status | Should -Be 'Simulado'
        foreach ($mutator in $global:ADMutators) {
            Should -Invoke $mutator -ModuleName ADUserLifecycle -Times 0 -Exactly
        }
    }
}
