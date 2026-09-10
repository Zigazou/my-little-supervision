<#
.SYNOPSIS
Defines the bounded runspace monitoring scheduler.

.DESCRIPTION
Dot-source after Checks.ps1. The caller owns mutable scheduler state, polls for
results and releases the pool during shutdown.

.OUTPUTS
None.
#>

Set-StrictMode -Version Latest

function New-MonitorState {
  <#
  .SYNOPSIS
  Creates scheduler state and opens its runspace pool.

  .DESCRIPTION
  Initializes queues, result and history maps, and the next-run timestamp. The
  caller owns the returned state and must release it with Close-MonitorState.

  .PARAMETER Configuration
  Validated configuration containing Checks, MaxConcurrency and
  RefreshSeconds.

  .PARAMETER ChecksPath
  Path to the trusted check implementation script dot-sourced by each worker;
  use an absolute path.

  .OUTPUTS
  System.Collections.Hashtable. Mutable scheduler state including the open
  Pool.
  #>
  param(
    [hashtable] $Configuration,
    [string] $ChecksPath
  )

  $pool = [RunspaceFactory]::CreateRunspacePool(
    1,
    $Configuration.MaxConcurrency
  )

  $pool.Open()

  return @{
    Configuration = $Configuration
    ChecksPath    = $ChecksPath
    Pool          = $pool
    Pending       = New-Object System.Collections.Queue
    Active        = New-Object System.Collections.ArrayList
    Results       = @{}
    History       = @{}
    Paused        = $false
    NextRun       = [DateTime]::UtcNow
    Running       = $false
  }
}

function Start-MonitorCycle {
  <#
  .SYNOPSIS
  Queues enabled checks for a monitoring cycle.

  .DESCRIPTION
  Mutates the state without launching workers. Does nothing during an existing
  cycle. The caller handles pause policy; Receive-MonitorResults starts queued
  work.

  .PARAMETER State
  Live scheduler state returned by New-MonitorState.

  .OUTPUTS
  None.
  #>
  param([hashtable] $State)

  if ($State.Running) {
    return
  }

  foreach ($check in $State.Configuration.Checks) {
    if ($check.Enabled) {
      $State.Pending.Enqueue($check)
    }
  }

  $State.Running = $State.Pending.Count -gt 0
  $State.NextRun = [DateTime]::UtcNow.AddSeconds(
    $State.Configuration.RefreshSeconds
  )
}

function Receive-MonitorResults {
  <#
  .SYNOPSIS
  Collects completed results and launches queued checks.

  .DESCRIPTION
  Polls completed workers without waiting for active network checks. Updates
  Results and newest-first History (at most 200 results per check), disposes
  completed workers, and fills available concurrency slots. Worker failures
  become Error results; worker startup failures propagate. Call repeatedly
  from the scheduler owner.

  .PARAMETER State
  Live scheduler state whose queues, results, history and cycle timing are
  updated in place.

  .OUTPUTS
  System.Management.Automation.PSCustomObject. Zero or more newly completed
  check results.
  #>
  param([hashtable] $State)

  foreach ($job in @($State.Active.ToArray())) {
    if (-not $job.Handle.IsCompleted) {
      continue
    }

    try {
      $output = @($job.PowerShell.EndInvoke($job.Handle))

      if ($output.Count -ne 1 -or $job.PowerShell.HadErrors) {
        throw 'Worker returned an invalid result.'
      }

      $result = $output[0]
    }
    catch {
      $result = New-CheckResult $job.Check 'Error' 'WorkerFailure'
    }
    finally {
      $job.PowerShell.Dispose()
      $State.Active.Remove($job)
    }

    $State.Results[$result.Name] = $result
    if (-not $State.History.ContainsKey($result.Name)) {
      $State.History[$result.Name] = `
        New-Object System.Collections.ArrayList
    }

    $history = $State.History[$result.Name]
    $null = $history.Insert(0, $result)

    if ($history.Count -gt 200) {
      $history.RemoveAt($history.Count - 1)
    }

    $result
  }

  while (
    $State.Pending.Count -gt 0 -and
    $State.Active.Count -lt $State.Configuration.MaxConcurrency
  ) {
    $check = $State.Pending.Dequeue()
    $worker = [PowerShell]::Create()
    $worker.RunspacePool = $State.Pool

    $script = (
      'param($path, $check) ' +
      'Set-StrictMode -Version Latest; ' +
      '$ErrorActionPreference = "Stop"; ' +
      '. $path; ' +
      'Invoke-MonitorCheck -Check $check'
    )

    $null = $worker.AddScript($script)
    $null = $worker.AddArgument($State.ChecksPath)
    $null = $worker.AddArgument($check)

    try {
      $handle = $worker.BeginInvoke()

      $null = $State.Active.Add(@{
          Check      = $check
          PowerShell = $worker
          Handle     = $handle
        })
    }
    catch {
      $worker.Dispose()
      throw
    }
  }

  if (
    $State.Running -and
    $State.Active.Count -eq 0 -and
    $State.Pending.Count -eq 0
  ) {
    $State.Running = $false
    $State.NextRun = [DateTime]::UtcNow.AddSeconds(
      $State.Configuration.RefreshSeconds
    )
  }
}

function Close-MonitorState {
  <#
  .SYNOPSIS
  Stops workers and releases scheduler resources.

  .DESCRIPTION
  Clears pending work, stops and disposes active workers, and closes the pool.
  Stopping may wait for worker shutdown. Call once when replacing the state or
  closing the application.

  .PARAMETER State
  Live scheduler state to dispose; it must not be reused afterward.

  .OUTPUTS
  None.
  #>
  param([hashtable] $State)

  $State.Pending.Clear()
  foreach ($job in $State.Active) {
    try {
      $job.PowerShell.Stop()
    }
    finally {
      $job.PowerShell.Dispose()
    }
  }

  $State.Active.Clear()
  $State.Pool.Close()
  $State.Pool.Dispose()
}
