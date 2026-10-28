BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelper.ps1')
}

Describe 'New-LifecycleUser' {
    BeforeAll {
        $alta = @{
            Nombre       = 'Juan'
            Apellido     = 'Pérez'
            Legajo       = '10234'
            Area         = 'Sistemas'
            Puesto       = 'Analista de Soporte'
            Manager      = 'mgarcia'
            FechaIngreso = '2026-11-02'
            Ticket       = 'RRHH-1001'
        }
    }

    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -Path $root -ItemType Directory | Out-Null
        $cfg = New-TestLifecycleConfig -Root $root
        New-Item -Path $cfg.HomeFolders.Root -ItemType Directory | Out-Null

        Mock Get-ADUser -ModuleName ADUserLifecycle { $null }
        Mock Get-ADUser -ModuleName ADUserLifecycle -ParameterFilter { $Identity -eq 'mgarcia' } {
            [pscustomobject]@{ SamAccountName = 'mgarcia'; DistinguishedName = 'CN=Marta Garcia,OU=Sistemas,OU=Usuarios,DC=contoso,DC=local' }
        }
        Mock New-ADUser -ModuleName ADUserLifecycle {
            [pscustomobject]@{ SamAccountName = $SamAccountName; SID = 'S-1-5-21-1111111111-2222222222-3333333333-1105' }
        }
        Mock Add-ADGroupMember -ModuleName ADUserLifecycle { }
        Mock Set-LifecycleHomeFolderAcl -ModuleName ADUserLifecycle { }
    }

    It 'crea la cuenta con los atributos esperados' {
        $result = New-LifecycleUser @alta -Config $cfg

        $result.Status | Should -Be 'OK'
        $result.SamAccountName | Should -Be 'jperez'
        Should -Invoke New-ADUser -ModuleName ADUserLifecycle -Times 1 -Exactly -ParameterFilter {
            $SamAccountName -eq 'jperez' -and
            $UserPrincipalName -eq 'jperez@contoso.local' -and
            $Path -eq 'OU=Sistemas,OU=Usuarios,DC=contoso,DC=local' -and
            $ChangePasswordAtLogon -eq $true -and
            $Enabled -eq $true -and
            $EmployeeID -eq '10234' -and
            $Department -eq 'Sistemas' -and
            $Title -eq 'Analista de Soporte' -and
            $Manager -like 'CN=Marta Garcia*' -and
            $Description -eq 'Alta 2026-11-02 | Ticket RRHH-1001' -and
            $AccountPassword -is [securestring] -and
            $HomeDrive -eq 'H:'
        }
    }

    It 'devuelve la contraseña temporal como SecureString y nunca en texto plano' {
        $result = New-LifecycleUser @alta -Config $cfg
        $result.TemporaryPassword | Should -BeOfType [securestring]
        Get-Content -LiteralPath $cfg.Audit.LogPath -Raw | Should -Not -Match 'Password'
    }

    It 'agrega la cuenta a todos los grupos del rol' {
        New-LifecycleUser @alta -Config $cfg | Out-Null
        foreach ($group in @('GG_Todos_Empleados', 'GG_Sistemas', 'GG_Helpdesk', 'GG_VPN')) {
            Should -Invoke Add-ADGroupMember -ModuleName ADUserLifecycle -Times 1 -Exactly -ParameterFilter {
                $Identity -eq $group -and $Members -eq 'jperez'
            }
        }
        Should -Invoke Add-ADGroupMember -ModuleName ADUserLifecycle -Times 4 -Exactly
    }

    It 'crea la carpeta personal y aplica la ACL con el SID de la cuenta nueva' {
        $result = New-LifecycleUser @alta -Config $cfg
        Test-Path -LiteralPath $result.HomeDirectory | Should -BeTrue
        Should -Invoke Set-LifecycleHomeFolderAcl -ModuleName ADUserLifecycle -Times 1 -Exactly -ParameterFilter {
            $Sid -eq 'S-1-5-21-1111111111-2222222222-3333333333-1105' -and $Path -like '*jperez'
        }
    }

    It 'usa jperez2 y un CN distinto cuando jperez ya existe' {
        Mock Get-ADUser -ModuleName ADUserLifecycle -ParameterFilter { $Filter -match "sAMAccountName -eq 'jperez'" } {
            [pscustomobject]@{ SamAccountName = 'jperez' }
        }
        $result = New-LifecycleUser @alta -Config $cfg
        $result.SamAccountName | Should -Be 'jperez2'
        Should -Invoke New-ADUser -ModuleName ADUserLifecycle -ParameterFilter { $Name -eq 'Juan Pérez (jperez2)' }
    }

    It 'no crea un duplicado si el legajo ya existe' {
        Mock Get-ADUser -ModuleName ADUserLifecycle -ParameterFilter { $Filter -eq "EmployeeID -eq '10234'" } {
            [pscustomobject]@{ SamAccountName = 'jperez' }
        }
        { New-LifecycleUser @alta -Config $cfg } | Should -Throw '*legajo 10234*'
        Should -Invoke New-ADUser -ModuleName ADUserLifecycle -Times 0 -Exactly
    }

    It 'falla antes de crear nada si el área no existe' {
        $otra = $alta.Clone(); $otra.Area = 'Marketing'
        { New-LifecycleUser @otra -Config $cfg } | Should -Throw '*Marketing*'
        Should -Invoke New-ADUser -ModuleName ADUserLifecycle -Times 0 -Exactly
    }

    It 'si falla un grupo, sigue con el resto y marca Advertencia' {
        Mock Add-ADGroupMember -ModuleName ADUserLifecycle -ParameterFilter { $Identity -eq 'GG_VPN' } {
            throw 'Acceso denegado'
        }
        $result = New-LifecycleUser @alta -Config $cfg
        $result.Status | Should -Be 'Advertencia'
        ($result.Warnings -join ' ') | Should -Match 'GG_VPN'
        Should -Invoke Add-ADGroupMember -ModuleName ADUserLifecycle -Times 4 -Exactly
    }

    It 'si el manager no existe crea la cuenta igual y lo informa' {
        Mock Get-ADUser -ModuleName ADUserLifecycle -ParameterFilter { $Identity -eq 'mgarcia' } { throw 'No encontrado' }
        $result = New-LifecycleUser @alta -Config $cfg
        $result.Status | Should -Be 'Advertencia'
        Should -Invoke New-ADUser -ModuleName ADUserLifecycle -Times 1 -Exactly -ParameterFilter { -not $Manager }
    }

    It 'escribe una línea de auditoría con acción, usuario y ticket' {
        New-LifecycleUser @alta -Config $cfg | Out-Null
        $entries = @(Get-TestAuditEntry -Config $cfg)
        $entries.Count | Should -Be 1
        $entries[0].action | Should -Be 'alta'
        $entries[0].target | Should -Be 'jperez'
        $entries[0].ticket | Should -Be 'RRHH-1001'
        $entries[0].result | Should -Be 'ok'
        $entries[0].operator | Should -Not -BeNullOrEmpty
        $entries[0].details.groups | Should -Contain 'GG_Helpdesk'
    }

    Context 'con -WhatIf' {
        It 'no llama a ningún cmdlet que modifique AD ni crea la carpeta' {
            $result = New-LifecycleUser @alta -Config $cfg -WhatIf

            $result.Status | Should -Be 'Simulado'
            $result.SamAccountName | Should -Be 'jperez'
            foreach ($mutator in @('New-ADUser', 'Add-ADGroupMember')) {
                Should -Invoke $mutator -ModuleName ADUserLifecycle -Times 0 -Exactly
            }
            Should -Invoke Set-LifecycleHomeFolderAcl -ModuleName ADUserLifecycle -Times 0 -Exactly
            Test-Path -LiteralPath $result.HomeDirectory | Should -BeFalse
            (Get-TestAuditEntry -Config $cfg)[0].result | Should -Be 'simulado'
        }
    }
}
