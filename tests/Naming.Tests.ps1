BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelper.ps1')
}

Describe 'Generación de sAMAccountName' {
    BeforeAll {
        $cfg = New-TestLifecycleConfig -Root $TestDrive
    }

    BeforeEach {
        # Por defecto no existe ningún usuario en el "dominio".
        Mock Get-ADUser -ModuleName ADUserLifecycle { $null }
    }

    It 'genera inicial + apellido sin tildes: <Nombre> <Apellido> -> <Esperado>' -TestCases @(
        @{ Nombre = 'Juan'; Apellido = 'Pérez'; Esperado = 'jperez' }
        @{ Nombre = 'Ñaño'; Apellido = 'Muñoz'; Esperado = 'nmunoz' }
        @{ Nombre = 'Ángela'; Apellido = 'Pérez García'; Esperado = 'aperez' }
        @{ Nombre = 'María José'; Apellido = 'de la Fuente'; Esperado = 'mdelafuente' }
        @{ Nombre = 'Luis'; Apellido = "D'Angelo"; Esperado = 'ldangelo' }
        @{ Nombre = 'Ana'; Apellido = 'Gómez-Paz'; Esperado = 'agomez' }
    ) {
        $result = InModuleScope ADUserLifecycle -Parameters @{ N = $Nombre; A = $Apellido; C = $cfg } {
            New-LifecycleSamAccountName -Nombre $N -Apellido $A -Config $C
        }
        $result | Should -BeExactly $Esperado
    }

    It 'agrega sufijo 2 cuando el usuario base ya existe' {
        Mock Get-ADUser -ModuleName ADUserLifecycle -ParameterFilter { $Filter -match "sAMAccountName -eq 'jperez'" } {
            [pscustomobject]@{ SamAccountName = 'jperez' }
        }
        $result = InModuleScope ADUserLifecycle -Parameters @{ C = $cfg } {
            New-LifecycleSamAccountName -Nombre 'Juan' -Apellido 'Pérez' -Config $C
        }
        $result | Should -BeExactly 'jperez2'
    }

    It 'sigue incrementando hasta encontrar uno libre' {
        Mock Get-ADUser -ModuleName ADUserLifecycle -ParameterFilter {
            $Filter -match "sAMAccountName -eq '(jperez|jperez2|jperez3)'"
        } { [pscustomobject]@{ SamAccountName = 'ocupado' } }

        $result = InModuleScope ADUserLifecycle -Parameters @{ C = $cfg } {
            New-LifecycleSamAccountName -Nombre 'Juan' -Apellido 'Pérez' -Config $C
        }
        $result | Should -BeExactly 'jperez4'
        Should -Invoke Get-ADUser -ModuleName ADUserLifecycle -Times 4 -Exactly
    }

    It 'considera colisión también al UPN' {
        Mock Get-ADUser -ModuleName ADUserLifecycle -ParameterFilter { $Filter -match "UserPrincipalName -eq 'jperez@contoso.local'" } {
            [pscustomobject]@{ SamAccountName = 'otro' }
        }
        $result = InModuleScope ADUserLifecycle -Parameters @{ C = $cfg } {
            New-LifecycleSamAccountName -Nombre 'Juan' -Apellido 'Pérez' -Config $C
        }
        $result | Should -BeExactly 'jperez2'
    }

    It 'nunca supera los 20 caracteres, incluso con sufijo' {
        Mock Get-ADUser -ModuleName ADUserLifecycle -ParameterFilter { $Filter -match "sAMAccountName -eq 'mwolfeschlegelsteinh'" } {
            [pscustomobject]@{ SamAccountName = 'ocupado' }
        }
        $result = InModuleScope ADUserLifecycle -Parameters @{ C = $cfg } {
            New-LifecycleSamAccountName -Nombre 'Max' -Apellido 'Wolfeschlegelsteinhausenberger' -Config $C
        }
        $result.Length | Should -BeLessOrEqual 20
        $result | Should -BeExactly 'mwolfeschlegelstein2'
    }

    It 'falla si se agotan los intentos' {
        Mock Get-ADUser -ModuleName ADUserLifecycle { [pscustomobject]@{ SamAccountName = 'ocupado' } }
        {
            InModuleScope ADUserLifecycle -Parameters @{ C = $cfg } {
                New-LifecycleSamAccountName -Nombre 'Juan' -Apellido 'Pérez' -Config $C -MaxAttempts 3
            }
        } | Should -Throw '*luego de 3 intentos*'
    }

    It 'falla si el nombre queda vacío luego de normalizar' {
        {
            InModuleScope ADUserLifecycle -Parameters @{ C = $cfg } {
                New-LifecycleSamAccountName -Nombre '***' -Apellido 'Pérez' -Config $C
            }
        } | Should -Throw '*quedan vacíos*'
    }
}
