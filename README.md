# My Little Supervision

A Windows monitoring dashboard built with Windows PowerShell 5.1, WPF/XAML,
and declarative PSD1 configuration. It needs no administrator privileges,
third-party modules, installation service, or machine-wide configuration.

## Start

Copy the project to a user-writable folder. From its root, run:

```powershell
powershell.exe -NoProfile -STA -File .\src\MyLittleSupervision.ps1
```

To use your own configuration:

```powershell
Copy-Item .\config\example.psd1 .\config\office.local.psd1
powershell.exe -NoProfile -STA -File .\src\MyLittleSupervision.ps1 -ConfigurationPath .\config\office.local.psd1
```

The application respects the existing execution policy and does not change it.
If organizational policy prevents scripts from running, use your organization's
approved script signing/distribution process. WPF requires a Windows desktop
session. PowerShell 7 is not required.

The default example uses French and only pings `127.0.0.1`. HTTP and TCP examples
are disabled until you customize and enable them. Select `en-US` in configuration
for English.

## Dashboard

The layout follows [the interface proposal](docs/project-interface.png):

- Groups in the sidebar, a synchronized group selector, literal text search over
  names and targets, and an incidents filter (slow, offline, or error).
- A resource table with status indicators and text, Ping duration, TCP state,
  HTTP response code, and last check time. Each row represents **one check**;
  irrelevant protocol columns display a dash. Add separate named checks to
  monitor multiple protocols on the same host.
- Details and history for the selected resource. History keeps the last 200
  results per check in memory. The success rate uses those session samples,
  includes slow successful checks, and is not a 24-hour availability measurement.
- A session journal limited to 300 entries, CSV export of the filtered table,
  and shortcuts to the configuration and log folders.
- Manual refresh, automatic polling, and pause. Pause stops new automatic cycles;
  checks already in progress finish. A manual refresh also works while paused.

Automatic cycles begin at startup and then wait `RefreshSeconds` after the
previous cycle finishes. Checks run in bounded background runspaces. No cycles
overlap. Opening/reloading a valid configuration waits for active checks to
finish, discards queued old checks, and resets history. Invalid configuration
leaves the current monitor running; invalid startup configuration opens an empty
dashboard so another file can be selected.

## Configuration

PSD1 files are loaded with `Import-PowerShellDataFile`, never executed as scripts.
See [config/example.psd1](config/example.psd1) for Ping, GET, POST, and TCP examples.
Validation rejects unexpected keys, duplicate names (case insensitive), invalid
types, and out-of-range values before any checks run.

| Root key | Default / allowed values |
| --- | --- |
| `ConfigurationVersion` | Required integer `1` |
| `Checks` | Required array, up to 1000 entries; empty is supported |
| `Language` | `en-US`; also `fr-FR` |
| `RefreshSeconds` | `30`; integer 5–86400 |
| `MaxConcurrency` | `4`; integer 1–16 |

| Common check key | Default / allowed values |
| --- | --- |
| `Name` | Required unique non-empty string |
| `Type` | Required `Ping`, `Http`, or `Tcp` |
| `Group` | `Default`; non-empty string |
| `Enabled` | `$true`; boolean |
| `TimeoutSeconds` | `5`; integer 1–120 |
| `SlowThresholdMs` | `1000`; integer 1–120000 |

Ping and TCP require `HostName` (DNS name or IP address). TCP also requires
`Port` (integer 1–65535). The first resolved address is used. Ping failure only
means that the ICMP check failed; it does not establish service downtime.
The Ping column shows total probe duration, including DNS, rather than only
ICMP round-trip time.

HTTP requires an absolute `Uri` using `http` or `https`, without embedded
credentials or a fragment. Optional fields:

| HTTP key | Default / allowed values |
| --- | --- |
| `Method` | `GET`; also `POST` |
| `ExpectedStatusCodes` | All 200–299 codes; non-empty array such as `@(200, 204)` |
| `Headers` | Hashtable of string names and values; no line breaks |
| `Body` | Empty string; only supported for POST |

POST uses UTF-8 and defaults to `text/plain`. Set `Headers = @{ 'Content-Type' =
'application/json' }` for JSON. HTTP checks inspect response headers/status without
downloading the response body. Redirects are not followed; explicitly include an
expected redirect status if appropriate. TLS certificate validation remains on,
and TLS support follows the installed Windows/.NET environment.

Authentication is not implemented. Authorization, cookie, token, API-key, and
secret headers are rejected, as are transport-managed headers. Do not put secrets
in URLs, bodies, or other configuration values. The dashboard and CSV display
targets. CSV escapes formula prefixes in user-provided values.

## Results and diagnostics

Successful checks become `Online`, or `Degraded` when total duration reaches the
slow threshold. Unexpected HTTP statuses, DNS failures, refused connections, and
timeouts become `Offline`. Unexpected execution failures become `Error`.
Disabled checks never perform network work.

Logs are stored under `%LOCALAPPDATA%\my-little-supervision\Logs`. They rotate at
approximately 2 MiB, keeping the active file and one previous file. Records contain
UTC timestamps, severity, component, protocol, result, duration, and safe failure
codes/exception types. Request data, raw exception messages, resource names, and
URLs are omitted to avoid leaking secrets. A logging failure is shown in the
status bar and does not stop monitoring. Full historical availability is not
persisted across restarts.

## Validation

Run the dependency-free suite on Windows:

```powershell
powershell.exe -NoProfile -STA -File .\tests\Run-Tests.ps1
```

Tests use loopback fixtures and need no public internet or administrator rights.
See [tests/README.md](tests/README.md) for manual WPF checks and environment limits.
See [docs/architecture.md](docs/architecture.md) for component responsibilities.
