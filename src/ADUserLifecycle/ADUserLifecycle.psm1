Set-StrictMode -Version Latest

# Ruta por defecto del archivo de configuración (se puede pisar con $env:ADLC_CONFIG
# o pasando -Path a Import-LifecycleConfig).
$script:DefaultConfigPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\config\lifecycle.config.json'
$script:LifecycleConfig = $null
$script:AuditContext = @{}

# Generador criptográfico compartido para contraseñas temporales.
$script:Rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

foreach ($folder in @('Private', 'Public')) {
    $folderPath = Join-Path -Path $PSScriptRoot -ChildPath $folder
    foreach ($file in (Get-ChildItem -Path $folderPath -Filter '*.ps1' | Sort-Object -Property Name)) {
        . $file.FullName
    }
}

Export-ModuleMember -Function @(
    'Import-LifecycleConfig',
    'Set-LifecycleAuditContext',
    'New-LifecycleUser',
    'Set-LifecycleUserTransfer',
    'Disable-LifecycleUser',
    'Remove-ExpiredDisabledUsers',
    'Invoke-LifecycleBatch'
)
