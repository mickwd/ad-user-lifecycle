<#
.SYNOPSIS
Ejecuta la suite de Pester 5 del módulo (local y en CI).

.EXAMPLE
.\tests\Invoke-Tests.ps1

.EXAMPLE
.\tests\Invoke-Tests.ps1 -CI   # sale con código distinto de cero si algo falla y genera testResults.xml
#>
[CmdletBinding()]
param([switch] $CI)

$ErrorActionPreference = 'Stop'
Import-Module -Name Pester -MinimumVersion 5.5.0 -MaximumVersion 5.99.99

$config = New-PesterConfiguration
$config.Run.Path = $PSScriptRoot
$config.Output.Verbosity = 'Detailed'
if ($CI) {
    $config.Run.Exit = $true
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputFormat = 'JUnitXml'
    $config.TestResult.OutputPath = Join-Path -Path $PSScriptRoot -ChildPath '..\testResults.xml'
}

Invoke-Pester -Configuration $config
