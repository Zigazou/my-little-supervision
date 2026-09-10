# Requires -Version 5.1
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
param(
  [string] $ConfigurationPath = `
  (Join-Path $PSScriptRoot '../config/example.psd1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
  throw 'My Little Supervision requires Windows and WPF.'
}

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
  throw (
    'Start with ' +
    'powershell.exe -NoProfile -STA -File src\MyLittleSupervision.ps1.'
  )
}

# Load required .NET assemblies for WPF and HTTP client functionality.
Add-Type -AssemblyName @(
  'PresentationFramework'
  'PresentationCore'
  'WindowsBase'
  'System.Net.Http'
)

# Load application components such as configuration, localization, logging,
# checks, core monitor, and UI controller.
$components = @(
  'Configuration/Configuration.ps1',
  'Localization/Localization.ps1',
  'Logging/Logging.ps1',
  'Checks/Checks.ps1',
  'Core/Monitor.ps1',
  'UI/Controller.ps1'
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

# Show the main monitoring window with the resolved configuration and state.
Show-MonitorWindow `
  -Configuration $configuration `
  -Path $ConfigurationPath `
  -SourceDirectory $PSScriptRoot `
  -ConfigurationFailed $configurationFailed
