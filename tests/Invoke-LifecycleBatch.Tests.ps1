BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelper.ps1')

    function global:New-TestBatchCsv {
        param([string] $Path, [string[]] $Lines)
        $encoding = New-Object System.Text.UTF8Encoding $true
        [System.IO.File]::WriteAllLines($Path, $Lines, $encoding)
    }
}

Describe 'Invoke-LifecycleBatch' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -Path $root -ItemType Directory | Out-Null
        $cfg = New-TestLifecycleConfig -Root $root
        $csv = Join-Path $root 'lote.csv'
    }

    Context 'manejo de errores por fila (funciones de alto nivel mockeadas)' {
        BeforeEach {
            Mock New-LifecycleUser -ModuleName ADUserLifecycle {
                if ($Legajo -eq '666') { throw 'Error simulado de AD' }
                [pscustomobject]@{ SamAccountName = 'nuevo' + $Legajo; Status = 'OK'; Warnings = @(); TemporaryPassword = $null }
            }
            Mock Disable-LifecycleUser -ModuleName ADUserLifecycle {
                [pscustomobject]@{ SamAccountName = $Identity; Status = 'Advertencia'; Warnings = @('Carpeta inexistente') }
            }
            Mock Set-LifecycleUserTransfer -ModuleName ADUserLifecycle {
                [pscustomobject]@{ SamAccountName = $Identity; Status = 'OK'; Warnings = @() }
            }
            New-TestBatchCsv -Path $csv -Lines @(
                'accion,nombre,apellido,legajo,area,puesto,manager,fecha_ingreso,usuario,ticket'
                'alta,Juan,Pérez,100,Sistemas,Analista de Soporte,,2026-11-02,,T-1'
                'alta,Falla,Siempre,666,Sistemas,Analista de Soporte,,2026-11-02,,T-2'
                'baja,,,,,,,,acastro,T-3'
                'cambio,,,,Finanzas,Analista Contable,,,lgomez,T-4'
                'suspension,,,,,,,,xx,T-5'
                'alta,SinApellido,,101,Sistemas,Analista de Soporte,,,,T-6'
            )
        }

        It 'un error en una fila no corta el lote' {
            $summary = Invoke-LifecycleBatch -Path $csv -Config $cfg -WarningAction SilentlyContinue

            $summary.Total | Should -Be 6
            $summary.OK | Should -Be 2
            $summary.Advertencias | Should -Be 1
            $summary.Errores | Should -Be 3
            Should -Invoke New-LifecycleUser -ModuleName ADUserLifecycle -Times 2 -Exactly
            Should -Invoke Disable-LifecycleUser -ModuleName ADUserLifecycle -Times 1 -Exactly
            Should -Invoke Set-LifecycleUserTransfer -ModuleName ADUserLifecycle -Times 1 -Exactly
        }

        It 'informa el motivo de cada error' {
            $summary = Invoke-LifecycleBatch -Path $csv -Config $cfg -WarningAction SilentlyContinue
            ($summary.Results | Where-Object Fila -eq 2).Detalle | Should -Be 'Error simulado de AD'
            ($summary.Results | Where-Object Fila -eq 5).Detalle | Should -Match "Acción desconocida 'suspension'"
            ($summary.Results | Where-Object Fila -eq 6).Detalle | Should -Match 'Faltan campos obligatorios.*apellido'
        }

        It 'genera el reporte CSV y HTML' {
            $summary = Invoke-LifecycleBatch -Path $csv -Config $cfg -WarningAction SilentlyContinue

            Test-Path -LiteralPath $summary.ReportCsv | Should -BeTrue
            Test-Path -LiteralPath $summary.ReportHtml | Should -BeTrue
            $report = @(Import-Csv -LiteralPath $summary.ReportCsv -Encoding UTF8)
            $report.Count | Should -Be 6
            $report[0].Estado | Should -Be 'OK'
            $html = Get-Content -LiteralPath $summary.ReportHtml -Raw -Encoding UTF8
            $html | Should -Match '<td class="estado-Error">Error</td>'
            $html | Should -Match 'Errores: 3'
        }

        It 'registra en auditoría las filas con error y el resumen del lote' {
            Invoke-LifecycleBatch -Path $csv -Config $cfg -WarningAction SilentlyContinue | Out-Null
            $entries = @(Get-TestAuditEntry -Config $cfg)
            @($entries | Where-Object result -eq 'error').Count | Should -Be 3
            ($entries | Where-Object action -eq 'lote').details.errores | Should -Be 3
        }

        It 'detecta separador punto y coma (Excel en español)' {
            New-TestBatchCsv -Path $csv -Lines @(
                'accion;nombre;apellido;legajo;area;puesto;manager;fecha_ingreso;usuario;ticket'
                'alta;Juan;Pérez;100;Sistemas;Analista de Soporte;;2026-11-02;;T-1'
            )
            $summary = Invoke-LifecycleBatch -Path $csv -Config $cfg
            $summary.OK | Should -Be 1
            Should -Invoke New-LifecycleUser -ModuleName ADUserLifecycle -Times 1 -Exactly -ParameterFilter {
                $Apellido -eq 'Pérez' -and $Puesto -eq 'Analista de Soporte'
            }
        }
    }

    Context 'con -WhatIf (funciones reales, AD mockeado)' {
        BeforeEach {
            Mock Get-ADUser -ModuleName ADUserLifecycle { $null }
            Mock Get-ADUser -ModuleName ADUserLifecycle -ParameterFilter { $Identity } {
                [pscustomobject]@{
                    SamAccountName    = [string]$Identity
                    DistinguishedName = "CN=$Identity,OU=Sistemas,OU=Usuarios,DC=contoso,DC=local"
                    Enabled           = $true
                    Department        = 'Sistemas'
                    Title             = 'Analista de Soporte'
                }
            }
            Mock Get-ADPrincipalGroupMembership -ModuleName ADUserLifecycle { [pscustomobject]@{ Name = 'GG_Sistemas' } }
            foreach ($mutator in $global:ADMutators) {
                Mock $mutator -ModuleName ADUserLifecycle { }
            }
            New-TestBatchCsv -Path $csv -Lines @(
                'accion,nombre,apellido,legajo,area,puesto,manager,fecha_ingreso,usuario,ticket'
                'alta,Juan,Pérez,100,Sistemas,Analista de Soporte,,2026-11-02,,T-1'
                'baja,,,,,,,,acastro,T-3'
                'cambio,,,,Finanzas,Analista Contable,,,lgomez,T-4'
            )
        }

        It 'no modifica AD pero genera el reporte con estado Simulado' {
            $summary = Invoke-LifecycleBatch -Path $csv -Config $cfg -WhatIf

            foreach ($mutator in $global:ADMutators) {
                Should -Invoke $mutator -ModuleName ADUserLifecycle -Times 0 -Exactly
            }
            $summary.Simuladas | Should -Be 3
            $summary.Errores | Should -Be 0
            Test-Path -LiteralPath $summary.ReportCsv | Should -BeTrue
        }
    }
}
