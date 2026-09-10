# Architecture

| Component | Responsibility |
| --- | --- |
| `src/MyLittleSupervision.ps1` | Windows/STA guards, component loading, safe startup |
| `src/Configuration/Configuration.ps1` | PSD1 data import, strict schema validation, normalized defaults |
| `src/Checks/Checks.ps1` | Ping, HTTP, TCP, explicit deadlines and normalized results |
| `src/Core/Monitor.ps1` | Runspace pool, bounded queue, independent completion, session history |
| `src/UI/MainWindow.xaml` | Native WPF dashboard based on the interface proposal |
| `src/UI/Controller.ps1` | Events, filters, selection, exports, configuration replacement |
| `src/Localization/` | English fallback and French resources |
| `src/Logging/Logging.ps1` | Bounded per-user disk diagnostics |

The controller owns a monitor state with a queue, a pool of at most 16 runspaces,
and at most `MaxConcurrency` submitted workers. Each worker receives a validated
check hashtable and executes the same check dispatcher. It returns exactly one
normalized result: `Name`, `Type`, `Target`, `Status`, `Success`, `Message`,
`DurationMs`, UTC `Timestamp`, and `Details`.

A WPF dispatcher timer polls completed workers every 250 ms. Only the UI thread
updates controls; workers never access WPF. The timer submits more queued checks,
records completed results, and starts subsequent cycles after the configured
interval. A failing worker becomes an error result without aborting other checks.
Closing the window stops the timer and disposes workers and their runspace pool.

DNS is resolved asynchronously with a bounded wait for Ping/TCP. The remaining
check budget is used for the network operation. Native DNS tasks cannot be
cancelled on the supported .NET baseline, but the monitoring worker stops waiting
at its deadline. TCP/Ping resources are disposed on all paths. HTTP uses an
instance-local HttpClient with a timeout, response-header completion, no cookies,
no redirects, and normal platform certificate validation. Only status and safe
exception type information leave the check implementation.

Configuration changes are fully validated before replacing state. Active checks
finish before replacement, so reloading does not block the dispatcher on network
operations. History is intentionally bounded and session-only. English resource
keys are stable identifiers; translations are applied when configuration loads.

The implementation does not persist secrets, change execution policy, request
elevation, install services, or alter firewall/registry settings.
