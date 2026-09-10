# Architecture

| Component | Responsibility |
| --- | --- |
| `src/MyLittleSupervision.ps1` | Platform/UI selection, Windows STA guard, shared loading, safe startup |
| `src/Configuration/Configuration.ps1` | PSD1 data import, strict schema validation, normalized defaults |
| `src/Checks/Checks.ps1` | Ping, HTTP, TCP, explicit deadlines and normalized results |
| `src/Core/Monitor.ps1` | Runspace pool, bounded queue, independent completion, session history |
| `src/UI/Wpf/MainWindow.xaml` | Native WPF dashboard based on the interface proposal |
| `src/UI/Wpf/Controller.ps1` | Events, filters, selection, exports, configuration replacement |
| `src/UI/Web/Controller.ps1` | Loopback TCP/HTTP transport, API, browser scheduler and configuration lifecycle |
| `src/UI/Web/index.html`, `app.js`, `style.css` | Local, framework-free browser presentation |
| `start.sh` | Linux runtime discovery and PowerShell launcher |
| `src/Localization/` | English fallback and French resources |
| `src/Logging/Logging.ps1` | Bounded per-user disk diagnostics |

The controller owns a monitor state with a queue, a pool of at most 16
runspaces, and at most `MaxConcurrency` submitted workers. Each worker receives
a validated check hashtable and executes the same check dispatcher. It returns
exactly one normalized result: `Name`, `Type`, `Target`, `Status`, `Success`,
`Message`, `DurationMs`, UTC `Timestamp`, and `Details`.

A WPF dispatcher timer polls completed workers every 250 ms. Only the UI thread
updates controls; workers never access WPF. The timer submits more queued
checks, records completed results, and starts subsequent cycles after the
configured interval. A failing worker becomes an error result without aborting
other checks. Closing the window stops the timer and disposes workers and their
runspace pool.

DNS is resolved asynchronously with a bounded wait for Ping/TCP. The remaining
check budget is used for the network operation. Native DNS tasks cannot be
cancelled on the supported .NET baseline, but the monitoring worker stops
waiting at its deadline. TCP/Ping resources are disposed on all paths. HTTP uses
an instance-local HttpClient with a timeout, response-header completion, no
cookies, no redirects, and normal platform certificate validation. Only status
and safe exception type information leave the check implementation.

Configuration changes are fully validated before replacing state. Active checks
finish before replacement, so reloading does not block the dispatcher on network
operations. History is intentionally bounded and session-only. English resource
keys are stable identifiers; translations are applied when configuration loads.

The implementation does not persist secrets, change execution policy, request
elevation, install services, or alter firewall/registry settings.

## Source documentation

PowerShell files include file-level help, and each function documents its
purpose, parameters, outputs and relevant side effects using comment-based help.
XAML and PSD1 headers describe their role. UI helpers that depend on the active
window identify their script-scoped state and UI-thread requirement.

To read function help, dot-source the defining file in Windows PowerShell 5.1,
then use `Get-Help`:

```powershell
. .\src\Configuration\Configuration.ps1
Get-Help Import-MonitorConfiguration -Full
Get-Help Import-MonitorConfiguration -Parameter Path
Get-Help .\src\MyLittleSupervision.ps1 -Full
```

Dot-sourcing component files defines their functions; running the application
entry script opens the dashboard. Keep help blocks synchronized with signatures,
return values and lifecycle changes when modifying the code.

## Browser controller

The browser controller owns the same monitor state as WPF and advances it in a
20 ms owner loop. Probe work stays in the existing bounded runspace pool. The
loop polls TCP clients without waiting for incomplete requests and writes
responses asynchronously. It accepts at most 32 clients, each with a five-second
connection deadline, 8 KiB of headers and 16 KiB of UTF-8 body. Connections close
after one response; duplicate headers, chunked transfer, pipelining and Expect
are unsupported. No filesystem paths are derived from asset request URLs.

The API uses these routes:

| Method | Route | Purpose |
| --- | --- | --- |
| GET | `/api/configuration` | Current path, language resources, revision, CSRF token and log path; excludes probe headers/bodies |
| GET | `/api/status` | Results, scheduling flags, revision and bounded journal |
| GET | `/api/history?name=...` | Up to 200 results for the selected check |
| GET | `/api/export?group=...&search=...&incidents=true` | Filtered CSV with formula escaping |
| POST | `/api/refresh` | Empty JSON object; request a manual cycle |
| POST | `/api/pause` | JSON object with boolean `paused` |
| POST | `/api/configuration` | JSON object with absolute PSD1 `path`; validate and queue replacement |

All requests must use the exact loopback Host and, when present, the same Origin.
Browser fetch-site metadata must be same-origin or none. POST additionally
requires application/json and the session X-CSRF-Token. Tokens stay in memory.
The UI polls after each previous request completes; history is fetched only for
the selected resource. Neither controller is loaded by the other. Shared code
keeps Windows PowerShell 5.1 syntax and APIs; the Linux launcher requires 7+.

### Browser JavaScript

Native ES modules separate the browser responsibilities without a build step:

- `app.js` owns dashboard state, polling, actions and event handlers.
- `api.js` handles JSON requests, CSRF headers and export URLs.
- `localization.js` formats resource text, result messages and dates.
- `view.js` renders the table, filters, details, history, journal and activity.

The view receives monitor state and selection explicitly; it performs no network
requests. Table selection uses a delegated event handler so polling can replace
rows without registering new listeners. The server explicitly allows each module
path and serves it as JavaScript under the existing content security policy.
