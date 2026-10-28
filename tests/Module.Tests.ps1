BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelper.ps1')
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $manifestPath = Join-Path $repoRoot 'src\ADUserLifecycle\ADUserLifecycle.psd1'
}

Describe 'Manifiesto y estructura del módulo' {
    It 'el manifiesto es válido' {
        { Test-ModuleManifest -Path $manifestPath -ErrorAction Stop } | Should -Not -Throw
    }

    It 'exporta exactamente las funciones públicas' {
        $exported = (Get-Module ADUserLifecycle).ExportedFunctions.Keys | Sort-Object
        $exported | Should -Be @(
            'Disable-LifecycleUser', 'Import-LifecycleConfig', 'Invoke-LifecycleBatch', 'New-LifecycleUser',
            'Remove-ExpiredDisabledUsers', 'Set-LifecycleAuditContext', 'Set-LifecycleUserTransfer'
        )
    }

    It '<Name> soporta -WhatIf y -Confirm' -TestCases @(
        @{ Name = 'New-LifecycleUser' }
        @{ Name = 'Set-LifecycleUserTransfer' }
        @{ Name = 'Disable-LifecycleUser' }
        @{ Name = 'Remove-ExpiredDisabledUsers' }
        @{ Name = 'Invoke-LifecycleBatch' }
    ) {
        $command = Get-Command -Name $Name -Module ADUserLifecycle
        $command.Parameters.Keys | Should -Contain 'WhatIf'
        $command.Parameters.Keys | Should -Contain 'Confirm'
    }

    It 'todos los archivos PowerShell están en UTF-8 con BOM y sin errores de sintaxis' {
        $files = Get-ChildItem -Path $repoRoot -Recurse -Include '*.ps1', '*.psm1', '*.psd1' |
            Where-Object { $_.FullName -notmatch '[\\/]\.venv[\\/]' }
        $files.Count | Should -BeGreaterThan 10
        foreach ($file in $files) {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) |
                Should -BeTrue -Because "$($file.Name) debe tener BOM para que Windows PowerShell 5.1 lea bien los acentos"

            $tokens = $null; $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
            $errors | Should -BeNullOrEmpty -Because $file.Name
        }
    }
}

Describe 'Set-LifecycleHomeFolderAcl (sobre una carpeta local de TestDrive)' {
    It 'corta la herencia y da Modify al SID indicado' -Skip:([System.Environment]::OSVersion.Platform -ne 'Win32NT') {
        $folder = Join-Path $TestDrive 'home_acl'
        New-Item -Path $folder -ItemType Directory | Out-Null
        $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value

        InModuleScope ADUserLifecycle -Parameters @{ F = $folder; S = $currentSid } {
            Set-LifecycleHomeFolderAcl -Path $F -Sid $S -Confirm:$false
        }

        $acl = Get-Acl -LiteralPath $folder
        $acl.AreAccessRulesProtected | Should -BeTrue
        $rules = @($acl.Access | Where-Object { -not $_.IsInherited })
        $userRule = $rules | Where-Object {
            $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -eq $currentSid -and
            ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Modify) -eq [System.Security.AccessControl.FileSystemRights]::Modify
        }
        $userRule | Should -Not -BeNullOrEmpty
        @($acl.Access | Where-Object IsInherited).Count | Should -Be 0
    }
}

Describe 'Auditoría' {
    It 'escribe JSON lines en UTF-8 sin BOM, una entrada por línea, con contexto' {
        $cfg = New-TestLifecycleConfig -Root $TestDrive
        InModuleScope ADUserLifecycle -Parameters @{ C = $cfg } {
            Set-LifecycleAuditContext -RequestId '42' -ApprovedBy 'mgarcia' -Source 'api'
            Write-LifecycleAuditLog -Action 'alta' -Target 'jperez' -Ticket 'T-1' -Config $C -Details @{ nota = 'acentuación' }
            Write-LifecycleAuditLog -Action 'baja' -Target 'jperez' -Ticket 'T-2' -Config $C
            Set-LifecycleAuditContext
        }
        $bytes = [System.IO.File]::ReadAllBytes($cfg.Audit.LogPath)
        $bytes[0] | Should -Be ([byte][char]'{')
        $lines = @(Get-Content -LiteralPath $cfg.Audit.LogPath -Encoding UTF8)
        $lines.Count | Should -Be 2
        $first = $lines[0] | ConvertFrom-Json
        $first.context.request_id | Should -Be '42'
        $first.context.approved_by | Should -Be 'mgarcia'
        $first.details.nota | Should -Be 'acentuación'
        $first.timestamp | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$'
    }
}
