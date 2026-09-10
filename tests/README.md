# Tests

Run from the repository root on Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -STA -File .\tests\Run-Tests.ps1
```

No Pester or other external module is required. Temporary configuration, worker,
and log fixtures are removed in `finally`. HTTP fixtures bind an ephemeral port
on loopback only. Use `-SkipNetwork` to run parser, schema, localization,
logging, and scheduler tests without network operations.

Coverage includes valid defaults, invalid schema/values, executable input
rejection, group labels/counts/filter values, special characters, secret header
rejection, disabled checks, normalized results, log rotation, bounded
scheduling, worker failure isolation, loopback Ping, HTTP
success/error/POST/timeout, TCP success/refusal, and XAML loading on Windows.

Linux PowerShell can check syntax and non-WPF behavior but cannot establish
Windows PowerShell 5.1/.NET Framework or WPF compatibility. The initial
development validation uses PowerShell 7.4 on Linux; Windows validation remains
required.

## Manual Windows acceptance

1. Launch the example without elevation. Confirm the local Ping completes and
   disabled rows remain disabled. Resize the window and test keyboard
   navigation. Confirm all four toolbar buttons show their icons and localized
   labels at 100% and 150% display scaling, and Refresh dims while checks run.
2. Open a custom configuration with at least two groups. Search using literal
   punctuation, synchronize sidebar/dropdown selection, and filter incidents.
3. Select a result; verify details, translated messages, history, and journal.
4. Monitor a local HTTP fixture returning 200/503 and a slow response. Confirm
   other rows finish independently and the UI remains responsive during
   timeouts.
5. Pause automatic polling, refresh manually, and resume. Confirm no overlapping
   cycles and that subsequent cycles wait for the configured interval.
6. Load invalid PSD1 and verify current results remain. Load a valid new file
   during an active cycle and confirm replacement occurs after active work ends.
7. Export the filtered table, including a resource name starting with `=`;
   verify Unicode and spreadsheet formula escaping.
8. Switch Language between `en-US` and `fr-FR` and reload. Verify all labels and
   messages. Start with a missing file and recover through Open configuration.
9. Check log folder/rotation and a non-writable log location. Confirm errors
   remain visible without stopping checks and no request secrets appear in logs.
10. Close while checks run; verify the PowerShell process exits after cleanup.

## Browser tests

Run `pwsh -NoProfile -File ./tests/Run-WebTests.ps1` on Linux, or
`powershell.exe -NoProfile -File .\tests\Run-WebTests.ps1` on Windows. The suite
starts the real Web launcher in a runspace and checks local assets, localization,
Host/Origin/fetch-site/CSRF rejection, JSON validation, slow-client isolation,
HTTP timeout alongside successful TCP, history, CSV escaping/filtering, pause,
manual refresh and deferred configuration replacement. No browser automation
package is a project dependency.

Manual browser acceptance:

1. Start with `./start.sh`, verify the printed loopback address opens, then repeat
   with `-NoBrowser` and a different `-Port`. An occupied port must fail clearly.
2. Use keyboard navigation to select rows, search literal punctuation, filter
   groups/incidents, inspect history, and download filtered CSV with Unicode.
3. Pause and refresh. Change configuration during a slow check; ensure the page
   remains responsive and replacement waits for active checks. Invalid PSD1 must
   keep the existing monitor. Recover from an invalid startup file.
4. Reload in French and English; verify translated controls, messages and errors.
   Check narrow windows and zoom without hiding access to table columns.
5. Close the tab and reopen the address; monitoring should continue. Press Ctrl+C
   in the terminal and verify the port is released and browser reports disconnect.
6. Verify Linux logs under XDG_STATE_HOME and its documented fallback. Run Web
   on Windows PowerShell 5.1 as well as the existing WPF acceptance checklist.
