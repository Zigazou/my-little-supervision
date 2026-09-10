#Requires -Version 5.1
<#
.SYNOPSIS
Starts the native Windows or local browser monitoring dashboard.

.DESCRIPTION
Uses WPF/STA on Windows and PowerShell 7 with a browser on Linux. Loads
application components and validates configuration. If loading fails, opens an
empty dashboard with a localized error so the user can select another file.

.PARAMETER ConfigurationPath
Path to a declarative PSD1 configuration file. Defaults to config/example.psd1
relative to the application source directory.

.PARAMETER UI
Auto selects WPF on Windows and Web on Linux. Web is also available on Windows.

.PARAMETER Port
Unprivileged loopback port for the Web interface; defaults to 8123.

.PARAMETER NoBrowser
Prints the Web address without attempting to launch a browser.

.OUTPUTS
None.
#>
[CmdletBinding()]
param(
  [string] $ConfigurationPath = `
  (Join-Path $PSScriptRoot '../config/example.psd1'),
  [ValidateSet('Auto', 'Wpf', 'Web')][string] $UI = 'Auto',
  [ValidateRange(1024, 65535)][int] $Port = 8123,
  [switch] $NoBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Determine if the script is running on a Windows plateform
$windowsPlatform = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT

if (
  -not $windowsPlatform -and
  $PSVersionTable.PSVersion.Major -lt 7
) {
  throw 'Linux requires PowerShell 7 or later.'
}

if ($UI -eq 'Auto') {
  $UI = if ($windowsPlatform) { 'Wpf' } else { 'Web' }
}

if ($UI -eq 'Wpf') {
  if (-not $windowsPlatform) {
    throw 'WPF requires Windows. Use -UI Web on Linux.'
  }

  if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Start Windows PowerShell with -STA to use WPF.'
  }

  Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
}

# Load application components such as configuration, localization, logging,
# checks, core monitor, and UI controller.
$components = @(
  'Configuration/Configuration.ps1',
  'Localization/Localization.ps1',
  'Logging/Logging.ps1',
  'Checks/Checks.ps1',
  'Core/Monitor.ps1'
)

foreach ($component in $components) {
  . (Join-Path $PSScriptRoot $component)
}

# Resolve the full path of the configuration file and initialize the
# configuration state.
$pathProvider = $ExecutionContext.SessionState.Path
$ConfigurationPath = $pathProvider.GetUnresolvedProviderPathFromPSPath(
  $ConfigurationPath
)
$configurationFailed = $false

try {
  $configuration = Import-MonitorConfiguration $ConfigurationPath
}
catch {
  $configurationFailed = $true
  $language = 'en-US'

  if ([Globalization.CultureInfo]::CurrentUICulture.Name -like 'fr-*') {
    $language = 'fr-FR'
  }

  # If configuration loading fails, fall back to a default configuration with
  # the appropriate language.
  $configuration = @{
    Language       = $language
    RefreshSeconds = 30
    MaxConcurrency = 4
    Checks         = @()
  }
}

if ($UI -eq 'Wpf') {
  # Run with the Windows Presentation Foundations.
  . (Join-Path $PSScriptRoot 'UI/Wpf/Controller.ps1')

  Show-MonitorWindow `
    -Configuration $configuration `
    -Path $ConfigurationPath `
    -SourceDirectory $PSScriptRoot `
    -ConfigurationFailed $configurationFailed
}
else {
  # Run with the web view.
  . (Join-Path $PSScriptRoot 'UI/Web/Controller.ps1')

  Show-WebMonitor `
    -Configuration $configuration `
    -Path $ConfigurationPath `
    -SourceDirectory $PSScriptRoot `
    -ConfigurationFailed $configurationFailed `
    -Port $Port `
    -NoBrowser:$NoBrowser
}
