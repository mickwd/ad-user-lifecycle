BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelper.ps1')
}

Describe 'Disable-LifecycleUser' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -Path $root -ItemType Directory | Out-Null
        $cfg = New-TestLifecycleConfig -Root $root

        $homeDir = Join-Path $cfg.HomeFolders.Root 'jperez'
        New-Item -Path $homeDir -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $homeDir 'informe.txt') -Value 'datos del usuario'

        $user = [pscustomobject]@{
            SamAccountName    = 'jperez'
            DistinguishedName = 'CN=Juan Pérez,OU=Sistemas,OU=Usuarios,DC=contoso,DC=local'
            Enabled           = $true
            HomeDirectory     = $homeDir
            mailNickname      = 'jperez'
        }
        Mock Get-ADUser -ModuleName ADUserLifecycle { $user }.GetNewClosure()
        Mock Get-ADPrincipalGroupMembership -ModuleName ADUserLifecycle {
            @(
                [pscustomobject]@{ Name = 'Domain Users'; DistinguishedName = 'CN=Domain Users,CN=Users,DC=contoso,DC=local'; SID = 'S-1-5-21-1-2-3-513' }
                [pscustomobject]@{ Name = 'GG_Sistemas'; DistinguishedName = 'CN=GG_Sistemas,OU=Grupos,DC=contoso,DC=local'; SID = 'S-1-5-21-1-2-3-2001' }
                [pscustomobject]@{ Name = 'GG_VPN'; DistinguishedName = 'CN=GG_VPN,OU=Grupos,DC=contoso,DC=local'; SID = 'S-1-5-21-1-2-3-2002' }
            )
        }
        foreach ($mutator in $global:ADMutators) {
            Mock $mutator -ModuleName ADUserLifecycle { }
        }
    }

    It 'guarda un snapshot JSON con las membresías previas' {
        $result = Disable-LifecycleUser -Identity 'jperez' -Ticket 'INC-2045' -Config $cfg

        Test-Path -LiteralPath $result.SnapshotPath | Should -BeTrue
        $snapshot = Get-Content -LiteralPath $result.SnapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $snapshot.samAccountName | Should -Be 'jperez'
        $snapshot.ticket | Should -Be 'INC-2045'
        @($snapshot.grupos.name) | Should -Be @('Domain Users', 'GG_Sistemas', 'GG_VPN')
        $snapshot.distinguishedName | Should -Match 'OU=Sistemas'
    }

    It 'quita todos los grupos excepto Domain Users' {
        $result = Disable-LifecycleUser -Identity 'jperez' -Ticket 'INC-2045' -Config $cfg

        $result.GroupsRemoved | Should -Be @('GG_Sistemas', 'GG_VPN')
        Should -Invoke Remove-ADGroupMember -ModuleName ADUserLifecycle -Times 2 -Exactly
        Should -Invoke Remove-ADGroupMember -ModuleName ADUserLifecycle -Times 0 -Exactly -ParameterFilter { $Identity -like '*Domain Users*' }
    }

    It 'deshabilita, resetea la contraseña, documenta y mueve a Bajas' {
        Disable-LifecycleUser -Identity 'jperez' -Ticket 'INC-2045' -Config $cfg | Out-Null

        Should -Invoke Disable-ADAccount -ModuleName ADUserLifecycle -Times 1 -Exactly -ParameterFilter { $Identity -eq 'jperez' }
        Should -Invoke Set-ADAccountPassword -ModuleName ADUserLifecycle -Times 1 -Exactly -ParameterFilter {
            $Reset -and $NewPassword -is [securestring]
        }
        $today = (Get-Date).ToString('yyyy-MM-dd')
        Should -Invoke Set-ADUser -ModuleName ADUserLifecycle -Times 1 -Exactly -ParameterFilter {
            $Description -like "Baja $today | Ticket INC-2045 | *"
        }
        Should -Invoke Move-ADObject -ModuleName ADUserLifecycle -Times 1 -Exactly -ParameterFilter {
            $TargetPath -eq 'OU=Bajas,DC=contoso,DC=local' -and $Identity -like 'CN=Juan Pérez,*'
        }
    }

    It 'oculta de la GAL cuando la cuenta tiene buzón' {
        Disable-LifecycleUser -Identity 'jperez' -Ticket 'INC-2045' -Config $cfg | Out-Null
        Should -Invoke Set-ADUser -ModuleName ADUserLifecycle -Times 1 -Exactly -ParameterFilter {
            $Replace -and $Replace['msExchHideFromAddressLists'] -eq $true
        }
    }

    It 'no toca atributos de Exchange si la cuenta no tiene buzón' {
        $user.PSObject.Properties.Remove('mailNickname')
        Disable-LifecycleUser -Identity 'jperez' -Ticket 'INC-2045' -Config $cfg | Out-Null
        Should -Invoke Set-ADUser -ModuleName ADUserLifecycle -Times 0 -Exactly -ParameterFilter { $Replace }
    }

    It 'archiva la carpeta personal en un zip' {
        $result = Disable-LifecycleUser -Identity 'jperez' -Ticket 'INC-2045' -Config $cfg
        $result.ArchivePath | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $result.ArchivePath | Should -BeTrue
        $result.ArchivePath | Should -BeLike (Join-Path $cfg.HomeFolders.ArchiveRoot 'jperez_*.zip')
        $result.Status | Should -Be 'OK'
    }

    It 'si falla quitar un grupo, sigue y marca Advertencia' {
        Mock Remove-ADGroupMember -ModuleName ADUserLifecycle -ParameterFilter { $Identity -like '*GG_VPN*' } { throw 'Acceso denegado' }
        $result = Disable-LifecycleUser -Identity 'jperez' -Ticket 'INC-2045' -Config $cfg
        $result.Status | Should -Be 'Advertencia'
        Should -Invoke Move-ADObject -ModuleName ADUserLifecycle -Times 1 -Exactly
    }

    It 'rechaza una cuenta que ya está dada de baja' {
        $user.Enabled = $false
        $user.DistinguishedName = 'CN=Juan Pérez,OU=Bajas,DC=contoso,DC=local'
        { Disable-LifecycleUser -Identity 'jperez' -Ticket 'INC-2045' -Config $cfg } | Should -Throw '*ya está deshabilitada*'
        Should -Invoke Disable-ADAccount -ModuleName ADUserLifecycle -Times 0 -Exactly
    }

    It 'registra la baja en el log de auditoría' {
        Disable-LifecycleUser -Identity 'jperez' -Ticket 'INC-2045' -Config $cfg | Out-Null
        $entry = (Get-TestAuditEntry -Config $cfg)[-1]
        $entry.action | Should -Be 'baja'
        $entry.ticket | Should -Be 'INC-2045'
        @($entry.details.groupsRemoved) | Should -Be @('GG_Sistemas', 'GG_VPN')
    }

    Context 'con -WhatIf' {
        It 'no llama a ningún mutador, no guarda snapshot ni archiva' {
            $result = Disable-LifecycleUser -Identity 'jperez' -Ticket 'INC-2045' -Config $cfg -WhatIf

            $result.Status | Should -Be 'Simulado'
            foreach ($mutator in $global:ADMutators) {
                Should -Invoke $mutator -ModuleName ADUserLifecycle -Times 0 -Exactly
            }
            Test-Path -LiteralPath $cfg.Offboarding.SnapshotFolder | Should -BeFalse
            Test-Path -LiteralPath $cfg.HomeFolders.ArchiveRoot | Should -BeFalse
        }
    }
}
