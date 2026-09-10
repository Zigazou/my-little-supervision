Set-StrictMode -Version Latest

function New-MonitorState {
    param([hashtable] $Configuration, [string] $ChecksPath)
    $pool = [RunspaceFactory]::CreateRunspacePool(1, $Configuration.MaxConcurrency)
    $pool.Open()
    return @{
        Configuration = $Configuration; ChecksPath = $ChecksPath; Pool = $pool
        Pending = New-Object System.Collections.Queue
        Active = New-Object System.Collections.ArrayList
        Results = @{}; History = @{}; Paused = $false
        NextRun = [DateTime]::UtcNow; Running = $false
    }
}

function Start-MonitorCycle {
    param([hashtable] $State)
    if ($State.Running) { return }
    foreach ($check in $State.Configuration.Checks) { if ($check.Enabled) { $State.Pending.Enqueue($check) } }
    $State.Running = $State.Pending.Count -gt 0
    $State.NextRun = [DateTime]::UtcNow.AddSeconds($State.Configuration.RefreshSeconds)
}

function Receive-MonitorResults {
    param([hashtable] $State)
    foreach ($job in @($State.Active.ToArray())) {
        if (-not $job.Handle.IsCompleted) { continue }
        try {
            $output = @($job.PowerShell.EndInvoke($job.Handle))
            if ($output.Count -ne 1 -or $job.PowerShell.HadErrors) { throw 'Worker returned an invalid result.' }
            $result = $output[0]
        }
        catch { $result = New-CheckResult $job.Check 'Error' 'WorkerFailure' }
        finally {
            $job.PowerShell.Dispose()
            $State.Active.Remove($job)
        }
        $State.Results[$result.Name] = $result
        if (-not $State.History.ContainsKey($result.Name)) { $State.History[$result.Name] = New-Object System.Collections.ArrayList }
        $history = $State.History[$result.Name]
        $null = $history.Insert(0, $result)
        if ($history.Count -gt 200) { $history.RemoveAt($history.Count - 1) }
        $result
    }
    while ($State.Pending.Count -gt 0 -and $State.Active.Count -lt $State.Configuration.MaxConcurrency) {
        $check = $State.Pending.Dequeue()
        $worker = [PowerShell]::Create()
        $worker.RunspacePool = $State.Pool
        $null = $worker.AddScript('param($path, $check) Set-StrictMode -Version Latest; $ErrorActionPreference = "Stop"; . $path; Invoke-MonitorCheck -Check $check').AddArgument($State.ChecksPath).AddArgument($check)
        try {
            $handle = $worker.BeginInvoke()
            $null = $State.Active.Add(@{ Check = $check; PowerShell = $worker; Handle = $handle })
        }
        catch { $worker.Dispose(); throw }
    }
    if ($State.Running -and $State.Active.Count -eq 0 -and $State.Pending.Count -eq 0) {
        $State.Running = $false
        $State.NextRun = [DateTime]::UtcNow.AddSeconds($State.Configuration.RefreshSeconds)
    }
}

function Close-MonitorState {
    param([hashtable] $State)
    $State.Pending.Clear()
    foreach ($job in $State.Active) {
        try { $job.PowerShell.Stop() }
        finally { $job.PowerShell.Dispose() }
    }
    $State.Active.Clear()
    $State.Pool.Close()
    $State.Pool.Dispose()
}
