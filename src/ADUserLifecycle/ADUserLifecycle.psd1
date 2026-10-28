@{
    RootModule           = 'ADUserLifecycle.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = '20e1ead3-0437-4b99-92db-8bae07ef9579'
    Author               = 'mickwd'
    Description          = 'Automatización de altas, bajas y modificaciones (ABM) de usuarios en Active Directory con auditoría en JSON lines.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @(
        'Import-LifecycleConfig',
        'Set-LifecycleAuditContext',
        'New-LifecycleUser',
        'Set-LifecycleUserTransfer',
        'Disable-LifecycleUser',
        'Remove-ExpiredDisabledUsers',
        'Invoke-LifecycleBatch'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags = @('ActiveDirectory', 'Onboarding', 'Offboarding', 'Helpdesk', 'Automation')
        }
    }
}
