<#
.SYNOPSIS
Defines network check execution and result normalization.

.DESCRIPTION
Dot-source from the launcher or a worker runspace. Loads System.Net.Http and
provides synchronous, timeout-bounded checks without UI access.

.OUTPUTS
None.
#>

Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Net.Http

function New-CheckResult {
  <#
  .SYNOPSIS
  Builds a normalized monitoring result.

  .DESCRIPTION
  Copies check identity, records a UTC timestamp and rounds duration to one
  decimal place. Online and Degraded statuses count as successful.

  .PARAMETER Check
  Validated check containing Name, Type and Target.

  .PARAMETER Status
  Normalized status, such as Online, Degraded, Offline, Error, Unknown or
  Disabled.

  .PARAMETER Message
  Untranslated message suffix resolved by the UI under the Message. resource
  prefix.

  .PARAMETER DurationMs
  Elapsed milliseconds; defaults to zero for synthetic results.

  .PARAMETER Code
  Optional HTTP status, Ping reply status or safe exception type stored in
  Details.Code. Defaults to null.

  .OUTPUTS
  System.Management.Automation.PSCustomObject. Name, Type, Target, Status,
  Success, Message, DurationMs, Timestamp and Details.
  #>
  param(
    [hashtable] $Check,
    [string] $Status,
    [string] $Message,
    [double] $DurationMs = 0,
    [object] $Code = $null
  )

  [pscustomobject]@{
    Name       = $Check.Name
    Type       = $Check.Type
    Target     = $Check.Target
    Status     = $Status
    Success    = ($Status -in @('Online', 'Degraded'))
    Message    = $Message
    DurationMs = [math]::Round($DurationMs, 1)
    Timestamp  = [DateTime]::UtcNow
    Details    = @{ Code = $Code }
  }
}

function Invoke-MonitorCheck {
  <#
    .SYNOPSIS
    Executes one validated Ping, HTTP or TCP check.

    .DESCRIPTION
    Runs synchronously with the configured timeout; callers should use a worker
    runspace. Disabled checks return immediately. Network failures become
    normalized results, slow successes become Degraded, and disposable network
    resources are released. HTTP redirects are not followed.

    .PARAMETER Check
    Normalized entry from Import-MonitorConfiguration, including Enabled,
    TimeoutSeconds, SlowThresholdMs and the fields required by its Type.

    .OUTPUTS
    System.Management.Automation.PSCustomObject. One normalized check result
    with an untranslated message key.
    #>
  [CmdletBinding()]

  param([Parameter(Mandatory)][hashtable] $Check)

  if (-not $Check.Enabled) {
    return New-CheckResult $Check 'Disabled' 'Disabled'
  }

  $watch = [Diagnostics.Stopwatch]::StartNew()
  $timeoutMs = $Check.TimeoutSeconds * 1000
  $resource = $null
  $handler = $null
  $request = $null
  $response = $null
  $code = $null

  try {
    $success = $false
    $message = 'NetworkFailure'

    switch ($Check.Type) {
      'Http' {
        Add-Type -AssemblyName System.Net.Http
        $handler = New-Object System.Net.Http.HttpClientHandler

        # Redirects are reported as their original status, avoiding
        # hidden target changes.
        $handler.AllowAutoRedirect = $false
        $handler.UseCookies = $false
        $resource = New-Object System.Net.Http.HttpClient($handler)
        $resource.Timeout = [TimeSpan]::FromMilliseconds($timeoutMs)
        $request = New-Object System.Net.Http.HttpRequestMessage
        $request.Method = New-Object System.Net.Http.HttpMethod(
          $Check.Method
        )
        $request.RequestUri = [Uri] $Check.Uri

        if ($Check.Method -eq 'POST') {
          $request.Content = `
            New-Object System.Net.Http.StringContent($Check.Body)
        }

        foreach ($key in $Check.Headers.Keys) {
          if ($key -eq 'Content-Type') {
            $request.Content.Headers.ContentType = (
              [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse(
                $Check.Headers[$key]
              )
            )
          }
          else {
            $request.Headers.Add($key, $Check.Headers[$key])
          }
        }

        $task = $resource.SendAsync(
          $request,
          [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        )

        if (-not $task.Wait($timeoutMs)) {
          $resource.CancelPendingRequests()

          throw (New-Object TimeoutException)
        }

        $response = $task.GetAwaiter().GetResult()
        $code = [int] $response.StatusCode
        $success = $code -in $Check.ExpectedStatusCodes

        $message = 'HttpStatus'
      }
      default {
        # Resolve separately so DNS lookup cannot exceed the check
        # deadline.
        $dnsTask = [Net.Dns]::GetHostAddressesAsync($Check.HostName)
        if (-not $dnsTask.Wait($timeoutMs)) {
          throw (New-Object TimeoutException)
        }

        $addresses = $dnsTask.GetAwaiter().GetResult()
        if ($addresses.Count -eq 0) {
          throw (New-Object Net.Sockets.SocketException)
        }

        $remaining = [math]::Max(
          1,
          $timeoutMs - [int] $watch.ElapsedMilliseconds
        )

        if ($Check.Type -eq 'Ping') {
          $resource = New-Object Net.NetworkInformation.Ping
          $task = $resource.SendPingAsync($addresses[0], $remaining)

          if (-not $task.Wait($remaining)) {
            throw (New-Object TimeoutException)
          }

          $reply = $task.GetAwaiter().GetResult()
          $code = $reply.Status.ToString()
          $success = (
            $reply.Status -eq [Net.NetworkInformation.IPStatus]::Success
          )

          $message = 'PingReply'

          if ($reply.Status -eq [Net.NetworkInformation.IPStatus]::TimedOut) {
            $message = 'Timeout'
          }
        }
        elseif ($Check.Type -eq 'Tcp') {
          $resource = New-Object Net.Sockets.TcpClient(
            $addresses[0].AddressFamily
          )

          $task = $resource.ConnectAsync($addresses[0], $Check.Port)

          if (-not $task.Wait($remaining)) {
            throw (New-Object TimeoutException)
          }

          $null = $task.GetAwaiter().GetResult()
          $success = $resource.Connected

          $message = 'TcpConnected'
        }
        else {
          throw 'Unsupported check type.'
        }
      }
    }

    $status = 'Offline'

    if ($success) {
      $status = 'Online'

      if ($watch.Elapsed.TotalMilliseconds -ge $Check.SlowThresholdMs) {
        $status = 'Degraded'
      }
    }

    New-CheckResult `
      $Check `
      $status `
      $message `
      $watch.Elapsed.TotalMilliseconds `
      $code
  }
  catch {
    $exception = $_.Exception.GetBaseException()
    $message = 'NetworkFailure'
    $status = 'Offline'

    if (
      $exception -is [TimeoutException] -or
      $exception -is [OperationCanceledException]
    ) {
      $message = 'Timeout'
    }
    elseif (
      $exception -is [Net.Sockets.SocketException] -and
      $exception.SocketErrorCode -in @('HostNotFound', 'NoData', 'TryAgain')
    ) {
      $message = 'DnsFailure'
    }
    elseif (
      $exception -isnot [Net.Sockets.SocketException] -and
      $exception -isnot [Net.Http.HttpRequestException] -and
      $exception -isnot [Net.NetworkInformation.PingException]
    ) {
      $status = 'Error'
    }

    # Exception text can contain URLs or headers. Retain only the exception
    # type.
    New-CheckResult `
      $Check `
      $status `
      $message `
      $watch.Elapsed.TotalMilliseconds `
      $exception.GetType().FullName
  }
  finally {
    if ($null -ne $response) {
      $response.Dispose()
    }

    if ($null -ne $request) {
      $request.Dispose()
    }
    if ($null -ne $resource) {
      $resource.Dispose()
    }
    if ($null -ne $handler) {
      $handler.Dispose()
    }

    $watch.Stop()
  }
}
