# AGENTS.md

## Project Overview

**Project name:** `my-little-supervision`

`my-little-supervision` is a supervision/monitoring application targeting Windows
with a native WPF interface and Linux with a browser interface.

The application uses:

- **PowerShell** for application logic.
- **WPF/XAML** for the Windows graphical user interface.
- **HTML/CSS/JavaScript in a browser** for the Linux user interface, served by a
  local backend that executes monitoring checks.
- **PSD1** files for user-editable configuration.
- Native platform/.NET capabilities whenever possible.

**Avalonia must not be used.** Keep monitoring, configuration, result models,
logging, and localization independent of either presentation layer. These are
the target requirements; they do not imply that Linux support is already implemented.

The application is intended to let users define checks that verify the availability or health of one or more servers or services, for example:

- ICMP/ping checks.
- HTTP GET requests.
- HTTP POST requests.
- TCP/service availability checks where appropriate.
- Other safe, explicitly supported checks added in the future.

A primary project constraint is that the application must run on a **fresh Windows installation without requiring administrator privileges or special system configuration**.

---

## Core Engineering Principles

All contributors and coding agents must preserve the following principles.

1. **Windows and Linux presentation layers**
   - Windows uses WPF/XAML; Linux uses a browser connected to a local backend.
   - Do not introduce Avalonia or another desktop UI framework for Linux.
   - Share monitoring logic where practical and isolate platform-specific startup
     and UI operations. Do not load WPF assemblies on Linux.
   - Introduce cross-platform abstractions only when they serve these targets
     and clearly improve maintainability without unnecessary complexity.

2. **No administrator privileges**
   - Normal installation, configuration, startup, execution, monitoring, logging, and updates must not require elevation.
   - Do not write to protected system locations such as `C:\Program Files`, `C:\Windows`, HKLM registry keys, or other administrator-only resources at runtime.
   - Prefer per-user locations such as `%LOCALAPPDATA%`, `%APPDATA%`, or the application directory when writable and appropriate.
   - On Linux, use appropriate per-user XDG locations with documented fallbacks;
     do not require root, system services, or writes to system directories.

3. **Fresh-install compatibility**
   - Prefer functionality available on a standard supported Windows installation.
   - Avoid requiring third-party PowerShell modules, package managers, runtimes, services, drivers, or external executables unless explicitly approved.
   - Prefer built-in PowerShell and .NET APIs.
   - If a dependency becomes necessary, document it clearly and provide a graceful compatibility check.

4. **Least privilege**
   - Never solve a problem by requesting elevation when a non-privileged solution exists.
   - Network checks must operate using the current user's permissions.

5. **Simple deployment**
   - The project should remain easy to copy, unpack, and run.
   - Avoid installers or machine-wide configuration unless the project explicitly adopts them later.

6. **Readable and maintainable code**
   - Favor clear code over clever code.
   - Keep responsibilities separated between UI, configuration, monitoring logic, networking, logging, and localization.

---

## Language Policy

### Source code

All source code must be written in **English**, including:

- Function names.
- Variable names.
- Class names.
- Parameter names.
- Comments.
- XML/XAML identifiers.
- Log messages intended for developers.
- Error identifiers.
- Test names.
- Configuration schema/property names.

Use clear, descriptive English names.

Examples:

```powershell
function Test-ServerAvailability {
    param(
        [Parameter(Mandatory)]
        [string] $HostName
    )
}
```

Prefer:

```powershell
$serverStatus
$requestTimeout
$configurationPath
```

Avoid:

```powershell
$statutServeur
$delaiRequete
$cheminConfiguration
```

### User interface

The UI should support localization where practical.

At minimum:

- English should be the canonical/fallback UI language.
- French should be supported if a localization system is present.
- User-visible strings should not be scattered throughout PowerShell or XAML files.

Prefer storing localized strings in dedicated resource/configuration files and referencing stable resource keys.

Example conceptual keys:

```text
MainWindow.Title
Status.Online
Status.Offline
Action.Refresh
Error.ConfigurationInvalid
```

Do not use translated strings as programmatic identifiers.

---

## PowerShell Requirements

### Compatibility

Unless the project explicitly changes its baseline, write code compatible with **Windows PowerShell 5.1**.

This baseline applies to Windows and shared PowerShell components. Linux may use
PowerShell 7; document the required runtime and check its availability gracefully.
Do not require PowerShell 7 on Windows merely to support Linux.

Do not assume PowerShell 7 is installed on a fresh Windows machine.

Before using a cmdlet, parameter, .NET API, or language feature, ensure it is available in the supported baseline.

### Style

Follow standard PowerShell naming conventions.

- Functions should use approved `Verb-Noun` naming whenever practical.
- Use PascalCase for function names and parameters.
- Use descriptive camelCase variable names.
- Avoid aliases in source code.
- Avoid positional parameters when readability suffers.
- Prefer full cmdlet names.

Prefer:

```powershell
Get-ChildItem -Path $configurationDirectory
```

Avoid:

```powershell
gci $configurationDirectory
```

### Strictness

New scripts should enable strict behavior where practical:

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
```

If strict mode is incompatible with a specific component, document why rather than silently removing it globally.

### Functions

Functions should:

- Do one thing.
- Have clear inputs and outputs.
- Avoid hidden global state.
- Validate external input.
- Return objects rather than formatted text whenever possible.
- Avoid writing directly to the UI unless the function belongs to the UI layer.

Use `[CmdletBinding()]` for non-trivial functions when it improves consistency, validation, or diagnostics.

### Error handling

Do not swallow exceptions.

Prefer:

```powershell
try {
    $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec $timeoutSeconds
}
catch {
    Write-ApplicationLog -Level Error -Message "HTTP check failed." -Exception $_.Exception
    throw
}
```

User-facing errors should be translated into understandable messages at the UI boundary.

Internal diagnostics should preserve useful technical detail.

### Output

Avoid mixing:

- Data returned through the pipeline.
- User-visible console text.
- Debug diagnostics.

GUI-facing functions should return structured objects.

Example:

```powershell
[pscustomobject]@{
    Name       = $checkName
    Status     = 'Online'
    DurationMs = $durationMs
    Timestamp  = [DateTime]::UtcNow
}
```

---

## WPF/XAML Guidelines

### Separation of concerns

Keep XAML focused on presentation.

Do not place business logic in XAML event handlers when it can be delegated to PowerShell functions or controller/view-model-style code.

Separate, as much as practical:

- UI layout.
- UI event wiring.
- Monitoring logic.
- Network operations.
- Configuration loading.
- Logging.
- Localization.

### Naming

Use descriptive English control names.

Prefer:

```xml
<Button x:Name="RefreshButton" />
<DataGrid x:Name="ChecksDataGrid" />
<TextBlock x:Name="StatusTextBlock" />
```

Avoid generic names such as:

```xml
<Button x:Name="Button1" />
```

### Responsiveness

Network checks must not freeze the WPF UI.

Long-running work must not execute synchronously on the UI thread.

Use an approach compatible with Windows PowerShell 5.1, such as:

- Runspaces.
- Background workers.
- Suitable .NET asynchronous APIs where safely integrated with WPF.

Any background operation updating WPF controls must marshal changes back to the UI dispatcher.

### UI state

The UI must remain usable when:

- A server is unreachable.
- DNS resolution fails.
- A request times out.
- A configuration entry is invalid.
- A remote endpoint returns an HTTP error.
- One check fails while others succeed.

A single failed check must not crash the application.

### Accessibility

Where practical:

- Use meaningful labels.
- Ensure keyboard navigation works.
- Do not rely on color alone to communicate status.
- Keep text readable at standard Windows scaling levels.
- Prefer standard WPF controls unless customization is justified.

---

## Linux Browser Interface Guidelines

- Keep browser presentation separate from the local monitoring backend. Execute
  Ping, TCP, and HTTP probes in the backend, not in browser JavaScript.
- Bind the local server to loopback by default using an unprivileged port. Do not
  expose monitoring data or controls to the network by default.
- Validate API input, restrict accepted origins and hosts, and protect
  state-changing endpoints against cross-site requests.
- Render configuration labels and diagnostic values as text, never as trusted HTML.
- Keep requests and monitoring concurrency bounded. Slow checks must not block
  the interface or unrelated API requests.
- Reuse English and French localization resources and preserve accessible labels,
  keyboard navigation, and status text alongside colors.
- Serve assets locally without requiring CDNs or public internet access.
- Document Linux runtime requirements, startup, shutdown, and per-user data paths.

## PSD1 Configuration Guidelines

PSD1 configuration files are user-editable input and must be treated as **untrusted configuration**.

### General rules

Configuration should remain declarative.

Prefer data such as:

```powershell
@{
    Checks = @(
        @{
            Name = 'Example Web Server'
            Type = 'Http'
            Uri = 'https://example.com/health'
            Method = 'GET'
            TimeoutSeconds = 5
        }
    )
}
```

Do not design configuration that requires users to embed arbitrary PowerShell script blocks.

Avoid configuration values such as:

```powershell
Script = {
    Invoke-SomethingArbitrary
}
```

unless arbitrary code execution is an explicit, reviewed feature of the project.

### Validation

Every configuration file must be validated before use.

Validate at least:

- Required keys.
- Supported check types.
- Supported HTTP methods.
- URI format.
- Host names where applicable.
- Port ranges.
- Numeric ranges.
- Timeout values.
- Duplicate identifiers/names when uniqueness is required.
- Unsupported or unexpected values.

Invalid configuration should produce a clear, actionable error without crashing the whole application.

### Defaults

Provide safe defaults for optional values.

Example:

```powershell
$timeoutSeconds = if ($check.ContainsKey('TimeoutSeconds')) {
    [int] $check.TimeoutSeconds
}
else {
    5
}
```

### Schema evolution

If the configuration format evolves, introduce an explicit version field.

Example:

```powershell
@{
    ConfigurationVersion = 1
    Checks = @()
}
```

Changes to the configuration schema should preserve backward compatibility when reasonably possible.

---

## Check Model

Monitoring checks should use a common normalized result model.

A check result should contain enough information for the UI and logs without exposing implementation details.

Recommended fields:

```text
Name
Type
Target
Status
Success
Message
DurationMs
Timestamp
Details
```

Possible normalized statuses may include:

```text
Unknown
Running
Online
Degraded
Offline
Error
Disabled
```

Keep the set of statuses small and well defined.

### Ping checks

Ping checks should:

- Use APIs/cmdlets available without elevation.
- Support configurable timeout values.
- Distinguish timeout, DNS failure, and execution error when useful.
- Not assume that ICMP failure means the server itself is unavailable.

The UI should avoid presenting ping as definitive proof that a service is down.

### HTTP checks

HTTP checks should support, at minimum where implemented:

- GET.
- POST.
- Configurable timeout.
- Expected HTTP status code or status range.
- Optional headers.
- Optional request body for POST.
- TLS using capabilities provided by the installed Windows/.NET environment.

Do not disable TLS certificate validation globally.

If certificate-validation overrides are ever supported for testing, they must be explicit, scoped, opt-in, and clearly marked as insecure.

### Future check types

New check types should implement the same conceptual lifecycle:

1. Validate configuration.
2. Execute the check.
3. Capture duration.
4. Normalize the result.
5. Log useful diagnostics.
6. Return without directly manipulating UI elements.

---

## Security Requirements

Security-sensitive behavior must be explicit.

### Credentials and secrets

Do not store passwords, tokens, API keys, or credentials in plaintext PSD1 files by default.

If authenticated checks are introduced:

- Prefer Windows-native per-user secret protection where possible.
- Never log secrets.
- Never display secrets in error dialogs.
- Redact sensitive HTTP headers such as `Authorization`.

### Command execution

Because configuration is user-editable, do not convert arbitrary configuration strings into executable PowerShell.

Do not use:

```powershell
Invoke-Expression
```

for configuration-driven checks.

Avoid dynamically constructing and executing code from configuration values.

Prefer an explicit dispatcher:

```powershell
switch ($check.Type) {
    'Ping' {
        Invoke-PingCheck -Configuration $check
    }

    'Http' {
        Invoke-HttpCheck -Configuration $check
    }

    default {
        throw "Unsupported check type: $($check.Type)"
    }
}
```

### File access

Only access files required by the application.

Do not modify:

- System files.
- Machine-wide registry settings.
- Firewall settings.
- Windows services.
- Scheduled tasks.
- Execution policy.

unless a future requirement explicitly introduces such behavior and it is reviewed.

The application must not modify the user's PowerShell execution policy as part of normal use.

---

## Networking Guidelines

All network operations must use explicit timeouts.

Never allow an individual check to wait indefinitely.

Use conservative default timeouts so that a failed endpoint does not make the application appear frozen.

Where multiple checks are executed:

- One endpoint failure must not stop unrelated checks.
- Concurrency should be bounded.
- Avoid launching unbounded jobs/runspaces.
- Results should be associated with the correct configured check.

Network operations must not require administrator privileges.

---

## Logging

Provide application logging suitable for troubleshooting without elevated permissions.

Prefer a per-user writable directory, for example under:

```text
%LOCALAPPDATA%\my-little-supervision\
```

or another clearly documented per-user application directory.

Logs should contain:

- Timestamp.
- Severity.
- Component.
- Concise message.
- Technical exception details where appropriate.

Suggested levels:

```text
Debug
Info
Warning
Error
```

Do not log secrets, authorization headers, credentials, or sensitive request bodies.

Log rotation or retention limits should be considered to avoid unlimited disk usage.

---

## File and Directory Conventions

Keep project responsibilities separated.

A recommended structure is:

```text
my-little-supervision/
├── AGENTS.md
├── README.md
├── src/
│   ├── MyLittleSupervision.ps1
│   ├── UI/
│   │   └── MainWindow.xaml
│   ├── Core/
│   ├── Checks/
│   ├── Configuration/
│   ├── Localization/
│   └── Logging/
├── config/
│   └── example.psd1
├── tests/
└── docs/
```

This structure is a recommendation, not a requirement. Preserve an existing project structure unless there is a clear benefit to changing it.

Do not reorganize unrelated files as part of a focused change.

---

## Localization

If localization is implemented, use a central translation mechanism.

Recommended behavior:

1. Define stable English resource keys.
2. Provide English strings as the fallback.
3. Provide French translations.
4. Load the selected language at startup.
5. Fall back to English when a translation key is missing.

Example conceptual structure:

```text
Localization/
├── en-US.psd1
└── fr-FR.psd1
```

Example:

```powershell
@{
    'MainWindow.Title' = 'My Little Supervision'
    'Status.Online'    = 'Online'
    'Status.Offline'   = 'Offline'
}
```

French:

```powershell
@{
    'MainWindow.Title' = 'My Little Supervision'
    'Status.Online'    = 'Disponible'
    'Status.Offline'   = 'Indisponible'
}
```

Do not duplicate application logic between languages.

---

## Testing

Changes to monitoring logic, parsing, or configuration should include tests when practical.

Prefer tests that do not require:

- Administrator privileges.
- External modules unavailable on a fresh Windows installation.
- Public internet access.
- A specific corporate network.
- Machine-wide configuration.

Unit tests should favor dependency isolation for network behavior.

At minimum, validate:

- Valid configuration loads correctly.
- Invalid configuration is rejected cleanly.
- Ping result normalization.
- HTTP success/failure result normalization.
- Timeout handling.
- Unexpected network exceptions.
- Missing localization keys.
- Special characters in labels and server names.

If Pester is used, do not assume it is available in the required version on every fresh Windows installation unless the test environment installs it separately. Test-only dependencies must not become runtime dependencies.

---

## Code Quality

Before completing a change:

- Check PowerShell syntax.
- Keep formatting consistent.
- Remove debugging artifacts.
- Remove unused variables and dead code.
- Avoid duplicated logic.
- Check error paths, not only success paths.
- Check that no elevation requirement was introduced.
- Check compatibility with Windows PowerShell 5.1.
- Check that new user-visible strings are localizable.
- Check that configuration input is validated.

Do not introduce a new dependency for functionality that can be implemented clearly with built-in PowerShell or .NET.

---

## Comments and Documentation

Comments should explain **why**, not restate obvious code.

Prefer:

```powershell
# WPF controls must be updated from the UI dispatcher because checks run in a background runspace.
$window.Dispatcher.Invoke($updateAction)
```

Avoid:

```powershell
# Invoke dispatcher
$window.Dispatcher.Invoke($updateAction)
```

Public or reusable functions should have comment-based help when appropriate.

Example:

```powershell
<#
.SYNOPSIS
Tests an HTTP endpoint and returns a normalized supervision result.

.PARAMETER Configuration
Validated HTTP check configuration.

.OUTPUTS
PSCustomObject
#>
```

---

## Git and Change Discipline

Keep changes focused.

When modifying the project:

- Do not reformat unrelated files.
- Do not rename unrelated identifiers.
- Do not introduce broad architectural changes unless requested.
- Preserve backward compatibility where practical.
- Update sample configuration when the configuration schema changes.
- Update documentation when behavior visible to users changes.

Commit messages, branch names, comments, and technical documentation should preferably be in English.

---

## Definition of Done

A change is considered complete only when all applicable points below are satisfied:

- The feature works on supported Windows systems.
- Changes to shared components work on supported Linux runtimes, and Linux UI
  features work in the browser without loading WPF or using Avalonia.
- It does not require administrator privileges.
- It does not add an unnecessary runtime dependency.
- It remains compatible with the project's supported PowerShell baseline.
- UI operations remain responsive.
- Configuration input is validated.
- Network calls have explicit timeouts.
- Errors are handled gracefully.
- Source code and identifiers are in English.
- User-visible strings are localizable where practical.
- French translations are added for newly localized UI strings when the localization system exists.
- Sensitive data is not logged.
- Relevant documentation/examples are updated.
- Tests are added or updated when practical.

---

## Agent-Specific Instructions

When an AI coding agent works on this repository, it must:

1. Read this file before making changes.
2. Inspect existing patterns before introducing new architecture.
3. Prefer minimal, targeted modifications.
4. Preserve Windows PowerShell 5.1 compatibility unless the repository explicitly states a newer baseline.
5. Never assume administrator rights.
6. Never modify execution policy as a workaround.
7. Avoid external dependencies unless there is a documented requirement.
8. Treat PSD1 configuration as untrusted user input.
9. Never use `Invoke-Expression` for configuration-driven behavior.
10. Keep network operations timeout-bounded and failure-isolated.
11. Keep WPF responsive by moving blocking work off the UI thread.
12. Keep source code in English.
13. Keep UI text localizable and maintain French translations when localization exists.
14. Explain any unavoidable compatibility, security, or privilege trade-off in the change description.
15. Preserve Windows/WPF and Linux/browser as the target interfaces; never use Avalonia.

If a requested implementation conflicts with these constraints, do not silently violate them. Identify the conflict and choose the safest compatible design whenever possible.
