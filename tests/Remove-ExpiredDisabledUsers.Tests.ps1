BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelper.ps1')
}

Describe 'Remove-ExpiredDisabledUsers' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -Path $root -ItemType Directory | Out-Null
        $cfg = New-TestLifecycleConfig -Root $root
        $reference = [datetime]'2026-10-28'

        Mock Get-ADUser -ModuleName ADUserLifecycle {
            @(
                [pscustomobject]@{ SamAccountName = 'vencido'; DistinguishedName = 'CN=vencido,OU=Bajas,DC=contoso,DC=local'; Description = 'Baja 2026-06-01 | Ticket INC-1 | CONTOSO\op' }
                [pscustomobject]@{ SamAccountName = 'reciente'; DistinguishedName = 'CN=reciente,OU=Bajas,DC=contoso,DC=local'; Description = 'Baja 2026-10-01 | Ticket INC-2 | CONTOSO\op' }
                [pscustomobject]@{ SamAccountName = 'sinfecha'; DistinguishedName = 'CN=sinfecha,OU=Bajas,DC=contoso,DC=local'; Description = 'Cuenta vieja' }
                [pscustomobject]@{ SamAccountName = 'admin.viejo'; DistinguishedName = 'CN=admin.viejo,OU=Bajas,DC=contoso,DC=local'; Description = 'Baja 2025-01-01 | Ticket INC-3 | x'; adminCount = 1 }
            )
        }
        Mock Remove-ADObject -ModuleName ADUserLifecycle { }
    }

    It 'elimina solo las cuentas con más días de baja que la retención' {
        $result = Remove-ExpiredDisabledUsers -Days 90 -ReferenceDate $reference -Config $cfg -Confirm:$false -WarningAction SilentlyContinue

        Should -Invoke Remove-ADObject -ModuleName ADUserLifecycle -Times 1 -Exactly -ParameterFilter {
            $Identity -eq 'CN=vencido,OU=Bajas,DC=contoso,DC=local' -and $Recursive
        }
        ($result | Where-Object SamAccountName -eq 'vencido').Estado | Should -Be 'Eliminado'
        ($result | Where-Object SamAccountName -eq 'reciente').Estado | Should -Be 'Vigente'
    }

    It 'omite cuentas privilegiadas y sin fecha de baja' {
        $result = Remove-ExpiredDisabledUsers -Days 90 -ReferenceDate $reference -Config $cfg -Confirm:$false -WarningAction SilentlyContinue
        ($result | Where-Object SamAccountName -eq 'sinfecha').Estado | Should -Be 'Omitido'
        ($result | Where-Object SamAccountName -eq 'admin.viejo').Estado | Should -Be 'Omitido'
        Should -Invoke Remove-ADObject -ModuleName ADUserLifecycle -Times 0 -Exactly -ParameterFilter { $Identity -like '*admin.viejo*' }
    }

    It 'usa RetentionDays de la configuración si no se pasa -Days' {
        $result = Remove-ExpiredDisabledUsers -ReferenceDate ([datetime]'2026-08-29') -Config $cfg -Confirm:$false -WarningAction SilentlyContinue
        # 2026-06-01 -> 2026-08-29 son 89 días: todavía vigente con retención 90.
        ($result | Where-Object SamAccountName -eq 'vencido').Estado | Should -Be 'Vigente'
        Should -Invoke Remove-ADObject -ModuleName ADUserLifecycle -Times 0 -Exactly
    }

    It 'busca solo cuentas deshabilitadas dentro de la OU de Bajas' {
        Remove-ExpiredDisabledUsers -Days 90 -ReferenceDate $reference -Config $cfg -WhatIf -WarningAction SilentlyContinue | Out-Null
        Should -Invoke Get-ADUser -ModuleName ADUserLifecycle -Times 1 -Exactly -ParameterFilter {
            $Filter -eq 'Enabled -eq $false' -and $SearchBase -eq 'OU=Bajas,DC=contoso,DC=local' -and $SearchScope -eq 'OneLevel'
        }
    }

    It 'con -WhatIf no elimina nada y lo informa como Simulado' {
        $result = Remove-ExpiredDisabledUsers -Days 90 -ReferenceDate $reference -Config $cfg -WhatIf -WarningAction SilentlyContinue
        Should -Invoke Remove-ADObject -ModuleName ADUserLifecycle -Times 0 -Exactly
        ($result | Where-Object SamAccountName -eq 'vencido').Estado | Should -Be 'Simulado'
    }

    It 'registra la eliminación en auditoría' {
        Remove-ExpiredDisabledUsers -Days 90 -ReferenceDate $reference -Config $cfg -Confirm:$false -WarningAction SilentlyContinue | Out-Null
        $entry = (Get-TestAuditEntry -Config $cfg) | Where-Object action -eq 'eliminacion'
        $entry.target | Should -Be 'vencido'
        $entry.details.dias | Should -Be 149
    }
}
