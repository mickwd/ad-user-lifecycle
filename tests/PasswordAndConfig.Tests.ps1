BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelper.ps1')
}

Describe 'Política de contraseñas temporales' {
    It 'genera 200 contraseñas que cumplen la política y son distintas entre sí' {
        $passwords = InModuleScope ADUserLifecycle {
            1..200 | ForEach-Object { New-LifecyclePasswordText -Length 16 -SamAccountName 'jperez' -DisplayName 'Juan Pérez' }
        }
        $passwords.Count | Should -Be 200
        @($passwords | Select-Object -Unique).Count | Should -Be 200
        foreach ($candidate in $passwords) {
            $candidate.Length | Should -Be 16
            $candidate | Should -MatchExactly '[A-Z]'
            $candidate | Should -MatchExactly '[a-z]'
            $candidate | Should -Match '[0-9]'
            $candidate | Should -Match '[^A-Za-z0-9]'
            $candidate | Should -Not -Match 'jperez'
            $candidate | Should -Not -MatchExactly '[0O1lI]'
        }
    }

    It 'rechaza contraseñas que no cumplen: <Caso>' -TestCases @(
        @{ Caso = 'corta'; Candidate = 'Ab1!xyzw' }
        @{ Caso = 'sin símbolo'; Candidate = 'Abcdefgh12345678' }
        @{ Caso = 'sin mayúscula'; Candidate = 'abcdefgh1234567!' }
        @{ Caso = 'sin número'; Candidate = 'Abcdefghijklmno!' }
        @{ Caso = 'contiene el usuario'; Candidate = 'Xx9!JPEREZabcdef' }
        @{ Caso = 'contiene parte del nombre'; Candidate = 'Xx9!JuanABCdefgh' }
    ) {
        $ok = InModuleScope ADUserLifecycle -Parameters @{ P = $Candidate } {
            Test-LifecyclePasswordComplexity -Candidate $P -MinLength 14 -SamAccountName 'jperez' -DisplayName 'Juan Pérez'
        }
        $ok | Should -BeFalse
    }

    It 'acepta una contraseña válida' {
        InModuleScope ADUserLifecycle {
            Test-LifecyclePasswordComplexity -Candidate 'Kq7#mZ2!pW9@xR4a' -MinLength 14 -SamAccountName 'jperez'
        } | Should -BeTrue
    }

    It 'devuelve un SecureString del largo pedido' {
        $secure = InModuleScope ADUserLifecycle { New-LifecyclePassword -Length 20 }
        $secure | Should -BeOfType [securestring]
        $secure.Length | Should -Be 20
    }
}

Describe 'Mapeo de grupos por rol y OU por área' {
    BeforeAll {
        $cfg = New-TestLifecycleConfig -Root $TestDrive
    }

    It 'combina grupos comunes, de área y de puesto' {
        $groups = InModuleScope ADUserLifecycle -Parameters @{ C = $cfg } {
            @(Get-LifecycleRoleGroup -Area 'Sistemas' -Puesto 'Analista de Soporte' -Config $C)
        }
        $groups | Should -Be @('GG_Todos_Empleados', 'GG_Sistemas', 'GG_Helpdesk', 'GG_VPN')
    }

    It 'elimina duplicados sin distinguir mayúsculas' {
        $groups = InModuleScope ADUserLifecycle -Parameters @{ C = $cfg } {
            @(Get-LifecycleRoleGroup -Area 'Finanzas' -Puesto 'Analista Contable' -Config $C)
        }
        $groups | Should -Be @('GG_Todos_Empleados', 'GG_Finanzas', 'GG_ERP_Contabilidad')
    }

    It 'con un puesto sin mapeo asigna solo comunes + área' {
        $groups = InModuleScope ADUserLifecycle -Parameters @{ C = $cfg } {
            @(Get-LifecycleRoleGroup -Area 'Comercial' -Puesto 'Puesto Inexistente' -Config $C)
        }
        $groups | Should -Be @('GG_Todos_Empleados', 'GG_Comercial')
    }

    It 'devuelve la OU del área' {
        InModuleScope ADUserLifecycle -Parameters @{ C = $cfg } {
            Get-LifecycleTargetOU -Area 'sistemas' -Config $C
        } | Should -Be 'OU=Sistemas,OU=Usuarios,DC=contoso,DC=local'
    }

    It 'falla con un área desconocida' {
        { InModuleScope ADUserLifecycle -Parameters @{ C = $cfg } { Get-LifecycleTargetOU -Area 'Marketing' -Config $C } } |
            Should -Throw "*'Marketing' no está definida*"
    }
}

Describe 'Import-LifecycleConfig' {
    It 'resuelve rutas relativas contra la carpeta del archivo y completa defaults' {
        $cfg = New-TestLifecycleConfig -Root $TestDrive
        $cfg.Audit.LogPath | Should -Be (Join-Path $TestDrive 'logs\audit.jsonl')
        $cfg.Offboarding.SnapshotFolder | Should -Be (Join-Path $TestDrive 'bajas')
        $cfg.Password.Length | Should -Be 16
        $cfg.HomeFolders.Drive | Should -Be 'H:'
        $cfg.Offboarding.KeepGroups | Should -Contain 'Domain Users'
    }

    It 'falla si faltan claves obligatorias' {
        $path = Join-Path $TestDrive 'incompleta.json'
        '{ "Domain": { "NetBIOS": "CONTOSO" } }' | Set-Content -LiteralPath $path -Encoding UTF8
        { Import-LifecycleConfig -Path $path } | Should -Throw '*Domain.UpnSuffix*'
    }

    It 'falla si el JSON es inválido' {
        $path = Join-Path $TestDrive 'rota.json'
        '{ esto no es json' | Set-Content -LiteralPath $path -Encoding UTF8
        { Import-LifecycleConfig -Path $path } | Should -Throw '*no es un JSON válido*'
    }

    It 'la configuración de ejemplo del repositorio es válida' {
        $sample = Join-Path $PSScriptRoot '..\config\lifecycle.config.json'
        $cfg = Import-LifecycleConfig -Path $sample
        @($cfg.OUs.Areas.PSObject.Properties).Count | Should -BeGreaterThan 0
    }
}
