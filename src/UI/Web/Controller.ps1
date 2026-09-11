<#
.SYNOPSIS
Serves the local browser dashboard using bounded, nonblocking TCP connections.

.DESCRIPTION
Dot-source after shared components. No WPF, external server or web framework is
loaded. The owner loop advances monitoring and services at most 32 connections.
#>
Set-StrictMode -Version Latest

function Set-WebConfiguration {
  <#
  .SYNOPSIS
  Replaces idle monitoring state after configuration validation.

  .PARAMETER Web
  Controller state owned by Show-WebMonitor.

  .PARAMETER Configuration
  Validated configuration.

  .PARAMETER Path
  Absolute configuration file path.

  .OUTPUTS
  None.
  #>
  param(
    [hashtable] $Web,
    [hashtable] $Configuration,
    [string] $Path
  )

  $newState = New-MonitorState `
    -Configuration $Configuration `
    -ChecksPath (Join-Path $Web.Source 'Checks/Checks.ps1')

  if ($null -ne $Web.State) {
    Close-MonitorState -State $Web.State
  }

  $Web.State = $newState
  foreach ($check in $Configuration.Checks) {
    $status = if ($check.Enabled) {
      'Unknown'
    }
    else {
      'Disabled'
    }

    $Web.State.Results[$check.Name] = New-CheckResult `
      -Check $check `
      -Status $status `
      -Message $status
  }

  $Web.Path = $Path
  $Web.Strings = Import-Translations `
    -Directory (Join-Path $Web.Source 'Localization') `
    -Language $Configuration.Language

  $Web.Journal.Clear()
  $Web.ConfigurationFailed = $false
  $Web.Revision++
}

function Invoke-WebTick {
  <#
  .SYNOPSIS
  Collects results, logs safe diagnostics and schedules work without waiting.

  .PARAMETER Web
  Mutable controller state.

  .OUTPUTS
  None.
  #>
  param([hashtable] $Web)

  foreach ($result in @(Receive-MonitorResults -State $Web.State)) {
    $level = if ($result.Success) {
      'Info'
    }
    else {
      'Warning'
    }

    $logged = Write-ApplicationLog `
      -Directory $Web.LogDirectory `
      -Level $level `
      -Component 'Checks' `
      -Message (
      'Type={0}; Status={1}; DurationMs={2}; Message={3}; Code={4}' -f
      $result.Type,
      $result.Status,
      $result.DurationMs,
      $result.Message,
      $result.Details.Code
    )

    if (-not $logged) {
      $Web.LoggingFailed = $true
    }

    $Web.Journal.Insert(0, $result)

    if ($Web.Journal.Count -gt 300) {
      $Web.Journal.RemoveAt(300)
    }
  }

  if ($null -ne $Web.Pending -and -not $Web.State.Running) {
    $pending = $Web.Pending
    $Web.Pending = $null

    Set-WebConfiguration `
      -Web $Web `
      -Configuration $pending.Configuration `
      -Path $pending.Path
  }

  if (
    -not $Web.State.Running -and
    -not $Web.State.Paused -and
    [DateTime]::UtcNow -ge $Web.State.NextRun
  ) {
    Start-MonitorCycle -State $Web.State
  }
}

function Get-WebRows {
  <#
  .SYNOPSIS
  Returns presentation data without exposing request headers or bodies.

  .PARAMETER Web
  Current controller state.

  .OUTPUTS
  PSCustomObject rows.
  #>
  param([hashtable] $Web)

  foreach ($check in $Web.State.Configuration.Checks) {
    $result = $Web.State.Results[$check.Name]

    [pscustomobject]@{
      Name       = $check.Name
      Group      = $check.Group
      Type       = $check.Type
      Target     = $check.Target
      Status     = $result.Status
      DurationMs = $result.DurationMs
      Timestamp  = $result.Timestamp
      Message    = $result.Message
      Details    = $result.Details
    }
  }
}

function New-WebResponse {
  <#
  .SYNOPSIS
  Creates a bounded-route HTTP response for asynchronous transmission.

  .PARAMETER Status
  HTTP status code.

  .PARAMETER Body
  Text body.

  .PARAMETER ContentType
  Explicit response media type.

  .OUTPUTS
  Hashtable containing UTF-8 response bytes.
  #>
  param(
    [int] $Status = 200,
    [string] $Body = '',
    [string] $ContentType = 'application/json; charset=utf-8'
  )

  $payload = [Text.Encoding]::UTF8.GetBytes($Body)

  $header = (
    "HTTP/1.1 $Status Response`r`n" +
    "Content-Type: $ContentType`r`n" +
    "Content-Length: $($payload.Length)`r`n" +
    "Connection: close`r`n" +
    "Cache-Control: no-store`r`n" +
    "X-Content-Type-Options: nosniff`r`n" +
    "Referrer-Policy: no-referrer`r`n" +
    "Content-Security-Policy" +
    ": default-src 'self'" +
    "; script-src 'self'" +
    "; style-src 'self'" +
    "; connect-src 'self'" +
    "; frame-ancestors 'none'" +
    "; base-uri 'none'" +
    "; form-action 'self'`r`n" +
    "`r`n"
  )

  return @{
    Bytes = [byte[]] ([Text.Encoding]::ASCII.GetBytes($header) + $payload)
  }
}

function Invoke-WebRequestRoute {
  <#
  .SYNOPSIS
  Validates browser boundaries and dispatches fixed local routes.
  .PARAMETER Web
  Mutable controller state, including the session CSRF token.
  .PARAMETER Method
  Parsed HTTP method.
  .PARAMETER Target
  Origin-form request target.
  .PARAMETER Headers
  Case-insensitive header dictionary with duplicates already rejected.
  .PARAMETER Body
  UTF-8 JSON body, limited to 16 KiB by the transport.
  .OUTPUTS
  HTTP response hashtable.
  #>
  param(
    [hashtable] $Web,
    [string] $Method,
    [string] $Target,
    [hashtable] $Headers,
    [string] $Body
  )

  if (
    $Headers.Host -cne $Web.Authority -or
    (
      $Headers.ContainsKey('Origin') -and
      $Headers.Origin -cne $Web.Origin
    ) -or
    (
      $Headers.ContainsKey('Sec-Fetch-Site') -and
      $Headers['Sec-Fetch-Site'] -notin @('same-origin', 'none')
    )
  ) {
    return New-WebResponse -Status 403 -Body '{"error":"Error.Action"}'
  }

  if ($Method -notin @('GET', 'POST')) {
    return New-WebResponse -Status 405
  }

  $applicationJson = '^application/json(?:;\s*charset=utf-8)?$' 
  if (
    $Method -eq 'POST' -and
    (
      $Headers['X-CSRF-Token'] -cne $Web.Token -or
      $Headers['Content-Type'] -notmatch $applicationJson
    )
  ) {
    return New-WebResponse -Status 403 -Body '{"error":"Error.Action"}'
  }

  $route = $Target.Split('?')[0]
  $query = @{}
  if ($Target.Contains('?')) {
    foreach ($part in $Target.Substring($Target.IndexOf('?') + 1).Split('&')) {
      $pair = $part.Split('=', 2)

      if ($pair.Count -ne 2) {
        return New-WebResponse -Status 400
      }

      $query[[Uri]::UnescapeDataString($pair[0].Replace('+', ' '))] = `
        [Uri]::UnescapeDataString($pair[1].Replace('+', ' '))
    }
  }
  if ($Method -eq 'GET') {
    $assets = @{
      '/'                = 'index.html'
      '/app.js'          = 'app.js'
      '/api.js'          = 'api.js'
      '/localization.js' = 'localization.js'
      '/view.js'         = 'view.js'
      '/style.css'       = 'style.css'
    }

    if ($assets.ContainsKey($route)) {
      $types = @{
        '/'                = 'text/html'
        '/app.js'          = 'text/javascript'
        '/api.js'          = 'text/javascript'
        '/localization.js' = 'text/javascript'
        '/view.js'         = 'text/javascript'
        '/style.css'       = 'text/css'
      }

      $body = [IO.File]::ReadAllText((Join-Path $Web.Assets $assets[$route]))
      return New-WebResponse `
        -Body $body `
        -ContentType ($types[$route] + '; charset=utf-8')
    }

    switch ($route) {
      '/api/configuration' {
        $data = @{
          path         = $Web.Path
          language     = $Web.State.Configuration.Language
          strings      = $Web.Strings
          token        = $Web.Token
          revision     = $Web.Revision
          logDirectory = $Web.LogDirectory 
        }
      }

      '/api/status' {
        $data = @{
          paused              = $Web.State.Paused
          running             = $Web.State.Running
          nextRun             = $Web.State.NextRun
          checks              = @(Get-WebRows -Web $Web)
          revision            = $Web.Revision
          pending             = ($null -ne $Web.Pending)
          configurationFailed = $Web.ConfigurationFailed
          loggingFailed       = $Web.LoggingFailed
          journal             = @($Web.Journal.ToArray()) 
        }
      }

      '/api/history' {
        if (-not $query['name']) {
          return New-WebResponse -Status 400
        }

        $history = $Web.State.History[$query['name']]
        $data = @{
          results = @()
        }

        if ($null -ne $history) {
          $data.results = @($history.ToArray())
        }
      }
      '/api/export' {
        $rows = @(Get-WebRows -Web $Web | Where-Object {
            (
              -not $query['group'] -or
              $_.Group -eq $query['group']
            ) -and
            (
              -not $query['search'] -or
              ($_.Name + ' ' + $_.Target).IndexOf(
                $query['search'],
                [StringComparison]::OrdinalIgnoreCase
              ) -ge 0
            ) -and
            (
              $query['incidents'] -ne 'true' -or
              $_.Status -in @('Degraded', 'Offline', 'Error')
            )
          } | Select-Object Name, Type, Target, Group, Status, Timestamp)

        foreach ($row in $rows) {
          foreach ($property in $row.PSObject.Properties) {
            if (
              $property.Value -is [string] -and
              $property.Value -match '^[\s]*[=+@-]|^[\t\r\n]'
            ) {
              $property.Value = "'" + $property.Value
            }
          }
        }
        $csv = ($rows | ConvertTo-Csv -NoTypeInformation) -join "`r`n"

        if ($rows.Count -eq 0) {
          $csv = '"Name","Type","Target","Group","Status","Timestamp"'
        }

        return New-WebResponse `
          -Body ([string][char]0xFEFF + $csv) `
          -ContentType 'text/csv; charset=utf-8'
      }

      default {
        return New-WebResponse -Status 404
      }
    }
    return New-WebResponse `
      -Body (ConvertTo-Json -InputObject $data -Depth 8 -Compress)
  }

  try {
    $inputData = ConvertFrom-Json -InputObject $Body -ErrorAction Stop

    if (
      $null -eq $inputData -or
      $inputData -isnot [pscustomobject]
    ) {
      throw 'Expected a JSON object.'
    }

    $keys = @($inputData.PSObject.Properties | ForEach-Object { $_.Name })
    switch ($route) {
      '/api/refresh' {
        if (
          $keys.Count -ne 0 -or
          $null -ne $Web.Pending
        ) {
          throw 'Refresh unavailable.'
        }

        Start-MonitorCycle -State $Web.State
      }

      '/api/pause' {
        if (
          $keys.Count -ne 1 -or
          $keys[0] -ne 'paused' -or
          $inputData.paused -isnot [bool]
        ) {
          throw 'Invalid pause state.'
        }

        $Web.State.Paused = $inputData.paused
      }

      '/api/configuration' {
        if (
          $keys.Count -ne 1 -or
          $keys[0] -ne 'path' -or
          $inputData.path -isnot [string] -or
          -not [IO.Path]::IsPathRooted($inputData.path) -or
          [IO.Path]::GetExtension($inputData.path) -ne '.psd1'
        ) {
          throw 'Expected an absolute PSD1 path.'
        }

        $configuration = Import-MonitorConfiguration -Path $inputData.path
        $Web.Pending = @{
          Configuration = $configuration
          Path          = $inputData.path
        }

        $Web.State.Pending.Clear()
      }

      default {
        return New-WebResponse -Status 404
      }
    }

    return New-WebResponse -Body '{"ok":true}'
  }
  catch {
    $key = if ($route -eq '/api/configuration') {
      'Error.Configuration'
    }
    else {
      'Error.Action'
    }

    return New-WebResponse `
      -Status 400 `
      -Body ('{"error":"' + $key + '"}')
  }
}

function Read-WebRequest {
  <#
  .SYNOPSIS
  Parses one strictly framed HTTP request without blocking on incomplete data.

  .PARAMETER Connection
  Connection state containing a byte buffer; mutated only by its owner loop.

  .OUTPUTS
  Hashtable request, or null while incomplete. Malformed input throws.
  #>
  param([hashtable] $Connection)

  $bytes = $Connection.Buffer.ToArray()
  $text = [Text.Encoding]::ASCII.GetString($bytes)
  $end = $text.IndexOf("`r`n`r`n", [StringComparison]::Ordinal)

  if ($end -lt 0) {
    if ($bytes.Length -gt 8192) {
      throw 'Headers too large.'
    }

    return $null
  }

  if ($end -gt 8192) {
    throw 'Headers too large.'
  }

  $lines = $text.Substring(0, $end).Split(
    @("`r`n"),
    [StringSplitOptions]::None
  )

  if ($lines[0] -cnotmatch '^(GET|POST) (/[^\s#]*) HTTP/1\.[01]$') {
    throw 'Invalid request line.'
  }

  $method = $Matches[1]
  $target = $Matches[2]
  $headers = @{}
  foreach ($line in $lines | Select-Object -Skip 1) {
    if ($line -notmatch '^([A-Za-z0-9-]+):[ \t]*([^\r\n]*)$') {
      throw 'Invalid header.'
    }

    $name = $Matches[1]; $value = $Matches[2].Trim()

    if ($headers.ContainsKey($name)) {
      throw 'Duplicate header.'
    }

    $headers[$name] = $value
  }

  if (
    -not $headers.ContainsKey('Host') -or
    $headers.ContainsKey('Transfer-Encoding') -or
    $headers.ContainsKey('Expect')
  ) {
    throw 'Unsupported framing.'
  }

  $length = 0
  if ($headers.ContainsKey('Content-Length')) {
    if ($headers['Content-Length'] -notmatch '^\d{1,5}$') {
      throw 'Invalid length.'
    }

    $length = [int] $headers['Content-Length']
  }

  if (
    $length -gt 16384 -or
    ($method -eq 'GET' -and $length -ne 0)
  ) {
    throw 'Invalid body length.'
  }

  $total = $end + 4 + $length

  if ($bytes.Length -lt $total) {
    return $null
  }

  if ($bytes.Length -ne $total) {
    throw 'Pipelining is unsupported.'
  }

  $encoding = New-Object Text.UTF8Encoding($false, $true)
  return @{
    Method  = $method
    Target  = $target
    Headers = $headers
    Body    = $encoding.GetString($bytes, $end + 4, $length)
  }
}

function Start-WebBrowser {
  <#
  .SYNOPSIS
  Opens the dashboard in Chromium application mode or the default browser.

  .PARAMETER Url
  Local dashboard URL generated by the Web controller.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string] $Url)

  # Attempt to launch Chromium in application mode first.
  foreach ($browserName in @('chromium', 'chromium-browser')) {
    $browser = Get-Command `
      -Name $browserName `
      -CommandType Application `
      -ErrorAction SilentlyContinue `
    | Select-Object -First 1

    if ($null -eq $browser) {
      continue
    }

    try {
      Start-Process `
        -FilePath $browser.Path `
        -ArgumentList ('--app=' + $Url) `
        -ErrorAction Stop `
      | Out-Null

      return
    }
    catch {
      Write-Verbose (
        "Chromium launch failed ({0}): {1}" -f
        $browserName,
        $_.Exception.Message
      )
    }
  }

  # Launch the default browser if Chromium was not used.
  Start-Process -FilePath $Url -ErrorAction Stop | Out-Null
}

function Show-WebMonitor {
  <#
  .SYNOPSIS
  Runs the loopback dashboard until interrupted with Ctrl+C.

  .PARAMETER Configuration
  Validated initial configuration.

  .PARAMETER Path
  Absolute PSD1 path for reload.

  .PARAMETER SourceDirectory
  Trusted application source directory.

  .PARAMETER ConfigurationFailed
  Shows a recoverable startup configuration error.

  .PARAMETER Port
  Loopback port, between 1024 and 65535.

  .PARAMETER NoBrowser
  Suppresses the optional browser launch.

  .OUTPUTS
  None. Prints the local URL and shutdown instructions.
  #>
  param(
    [hashtable] $Configuration,
    [string] $Path,
    [string] $SourceDirectory,
    [bool] $ConfigurationFailed,
    [ValidateRange(1024, 65535)][int] $Port = 8123,
    [switch] $NoBrowser
  )

  $stateRoot = [Environment]::GetFolderPath('LocalApplicationData')
  if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    $stateRoot = $env:XDG_STATE_HOME

    if (
      -not $stateRoot -or
      -not [IO.Path]::IsPathRooted($stateRoot)
    ) {
      $stateRoot = Join-Path `
      ([Environment]::GetFolderPath('UserProfile')) '.local/state'
    }
  }

  $token = [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')
  $web = @{
    State               = $null
    Path                = $Path
    Source              = $SourceDirectory
    Assets              = $PSScriptRoot
    Pending             = $null
    Revision            = 0
    Strings             = @{}
    LoggingFailed       = $false
    ConfigurationFailed = $false
    Journal             = New-Object System.Collections.ArrayList
    LogDirectory        = Join-Path $stateRoot 'my-little-supervision/Logs'
    Token               = $token
    Authority           = "127.0.0.1:$Port"
    Origin              = "http://127.0.0.1:$Port" 
  }

  $listener = New-Object `
    Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)

  $connections = New-Object System.Collections.ArrayList
  try {
    $listener.Start(32)
    Set-WebConfiguration -Web $web -Configuration $Configuration -Path $Path
    $web.ConfigurationFailed = $ConfigurationFailed

    Write-Host `
    ((Get-Translation $web.Strings 'Web.Started') -f ($web.Origin + '/'))

    if (-not $NoBrowser) {
      try {
        Start-WebBrowser -Url ($web.Origin + '/')
      }
      catch {
        Write-Warning (Get-Translation $web.Strings 'Web.BrowserUnavailable')
      }
    }

    while ($true) {
      Invoke-WebTick -Web $web

      # Each connection gets a fixed deadline and one read per tick. A slow
      # browser cannot hold the scheduler or other API requests hostage.
      if ($listener.Pending()) {
        $client = $listener.AcceptTcpClient()

        if ($connections.Count -ge 32) {
          $client.Dispose()
        }
        else {
          $null = $connections.Add(@{
              Client   = $client
              Stream   = $client.GetStream()
              Buffer   = New-Object 'System.Collections.Generic.List[byte]'
              Deadline = [DateTime]::UtcNow.AddSeconds(5)
              Write    = $null
              Response = $null 
            }
          )
        }
      }

      foreach ($connection in @($connections.ToArray())) {
        $close = $false

        try {
          if ([DateTime]::UtcNow -ge $connection.Deadline) {
            $close = $true
          }
          elseif ($null -ne $connection.Write) {
            if ($connection.Write.IsCompleted) {
              $null = $connection.Write.GetAwaiter().GetResult()
              $close = $true
            }
          }
          elseif ($connection.Stream.DataAvailable) {
            $chunk = New-Object byte[] 4096
            $count = $connection.Stream.Read(
              $chunk,
              0,
              [Math]::Min($chunk.Length, $connection.Client.Available)
            )

            if ($count -eq 0) {
              $close = $true
            }
            else {
              $connection.Buffer.AddRange([byte[]] $chunk[0..($count - 1)])
              $request = Read-WebRequest -Connection $connection

              if ($null -ne $request) {
                try {
                  $connection.Response = `
                    Invoke-WebRequestRoute -Web $web @request
                }
                catch {
                  $logged = Write-ApplicationLog `
                    -Directory $web.LogDirectory `
                    -Level Error `
                    -Component 'Web' `
                    -Message (
                    'API dispatch failed: ' + $_.Exception.GetType().Name
                  )

                  if (-not $logged) {
                    $web.LoggingFailed = $true
                  }

                  $connection.Response = New-WebResponse `
                    -Status 500 `
                    -Body '{"error":"Error.Action"}'
                }

                $responseBytes = $connection.Response.Bytes
                $connection.Write = $connection.Stream.WriteAsync(
                  $responseBytes,
                  0,
                  $responseBytes.Length
                )
              }
            }
          }
          elseif (
            $connection.Client.Client.Poll(
              0,
              [Net.Sockets.SelectMode]::SelectRead
            )
          ) {
            $close = $true
          }
        }
        catch {
          # Malformed requests and disconnected clients affect only their own
          # connection. Do not log request data, which may contain secrets.
          $close = $true
        }

        if ($close) {
          $connection.Client.Dispose()
          $connections.Remove($connection)
        }
      }

      Start-Sleep -Milliseconds 20
    }
  }
  finally {
    $listener.Stop()
    foreach ($connection in $connections) {
      $connection.Client.Dispose()
    }

    if ($null -ne $web.State) {
      Close-MonitorState -State $web.State
    }
  }
}
