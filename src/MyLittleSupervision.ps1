#Requires -Version 5.1
<#
.SYNOPSIS
Starts the Windows monitoring dashboard without changing machine settings.

.DESCRIPTION
Requires Windows PowerShell 5.1 or later with WPF and an STA thread. Loads
application components and validates configuration. If loading fails, opens an
empty dashboard with a localized error so the user can select another file.

.PARAMETER ConfigurationPath
Path to a declarative PSD1 configuration file. Defaults to config/example.psd1
relative to the application source directory.

.OUTPUTS
None.
#>
[CmdletBinding()]
param([string] $ConfigurationPath = (Join-Path $PSScriptRoot '../config/example.psd1'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'My Little Supervision requires Windows and WPF.' }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Start with powershell.exe -NoProfile -STA -File src\MyLittleSupervision.ps1.' }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Net.Http
foreach ($component in @('Configuration/Configuration.ps1', 'Localization/Localization.ps1', 'Logging/Logging.ps1', 'Checks/Checks.ps1', 'Core/Monitor.ps1', 'UI/Controller.ps1')) {
    . (Join-Path $PSScriptRoot $component)
}
$ConfigurationPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigurationPath)
$configurationFailed = $false
try { $configuration = Import-MonitorConfiguration $ConfigurationPath }
catch {
    $configurationFailed = $true
    $language = 'en-US'
    if ([Globalization.CultureInfo]::CurrentUICulture.Name -like 'fr-*') { $language = 'fr-FR' }
    $configuration = @{ Language = $language; RefreshSeconds = 30; MaxConcurrency = 4; Checks = @() }
}
Show-MonitorWindow -Configuration $configuration -Path $ConfigurationPath -SourceDirectory $PSScriptRoot -ConfigurationFailed $configurationFailed
