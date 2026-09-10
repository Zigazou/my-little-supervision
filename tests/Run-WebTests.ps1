#Requires -Version 5.1
<#
.SYNOPSIS
Runs dependency-free loopback tests for the browser controller.
.DESCRIPTION
Starts the actual launcher in a background runspace. Temporary files, sockets
and runspaces are released in finally. Requires permission to bind loopback.
.OUTPUTS
Assertion progress. Throws on failure.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('monitor-web-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temporaryDirectory
$server = $null
$client = $null
$fixture = $null
$slowClient = $null
$passed = 0
$previousStateHome = $env:XDG_STATE_HOME
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
  $env:XDG_STATE_HOME = $temporaryDirectory
}

function Assert-Web {
  param([bool] $Condition, [string] $Name)
  if (-not $Condition) { throw "FAIL: $Name" }
  $script:passed++
  Write-Output "PASS: $Name"
}

function Send-TestRequest {
  param([string] $Route, [string] $Method = 'GET', [string] $Body = '', [hashtable] $Headers = @{})
  $request = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::new($Method), ($script:origin + $Route))
  try {
    if ($Method -eq 'POST') { $request.Content = New-Object Net.Http.StringContent($Body, [Text.Encoding]::UTF8, 'application/json') }
    foreach ($key in $Headers.Keys) { $null = $request.Headers.TryAddWithoutValidation($key, $Headers[$key]) }
    $response = $script:client.SendAsync($request).GetAwaiter().GetResult()
    try {
      return @{ Status = [int] $response.StatusCode; Body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        Csp = [string] ($response.Headers.GetValues('Content-Security-Policy') -join '') }
    }
    finally { $response.Dispose() }
  }
  finally { $request.Dispose() }
}

try {
  . (Join-Path $root 'src/UI/Web/Controller.ps1')
  foreach ($invalidRequest in @(
    "GET / HTTP/1.1`r`nHost: a`r`nHost: b`r`n`r`n",
    "POST /api/refresh HTTP/1.1`r`nHost: a`r`nTransfer-Encoding: chunked`r`n`r`n",
    "POST /api/refresh HTTP/1.1`r`nHost: a`r`nContent-Length: -1`r`n`r`n",
    "POST /api/refresh HTTP/1.1`r`nHost: a`r`nContent-Length: 16385`r`n`r`n",
    "GET / HTTP/1.1`r`nHost: a`r`n`r`nGET / HTTP/1.1`r`nHost: a`r`n`r`n",
    ("GET / HTTP/1.1`r`nHost: " + ('a' * 8192))
  )) {
    $connection = @{ Buffer = New-Object 'System.Collections.Generic.List[byte]' }
    $connection.Buffer.AddRange([Text.Encoding]::ASCII.GetBytes($invalidRequest))
    $rejected = $false
    try { $null = Read-WebRequest -Connection $connection } catch { $rejected = $true }
    Assert-Web $rejected 'Reject malformed or oversized HTTP framing'
  }
  $connection = @{ Buffer = New-Object 'System.Collections.Generic.List[byte]' }
  $connection.Buffer.AddRange([Text.Encoding]::ASCII.GetBytes("POST /api/refresh HTTP/1.1`r`nHost: a`r`nContent-Length: 2`r`n`r`n{"))
  Assert-Web ($null -eq (Read-WebRequest -Connection $connection)) 'Incomplete request body waits without blocking'
  $connection.Buffer.Add([byte][char]'}')
  Assert-Web ((Read-WebRequest -Connection $connection).Body -eq '{}') 'Fragmented body parsed only after completion'
  Add-Type -AssemblyName System.Net.Http
  $fixture = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
  $fixture.Start()
  $fixturePort = $fixture.LocalEndpoint.Port
  $portReservation = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
  $portReservation.Start()
  $port = $portReservation.LocalEndpoint.Port
  $portReservation.Stop()
  $script:origin = "http://127.0.0.1:$port"
  $path = Join-Path $temporaryDirectory 'checks.psd1'
  $emptyPath = Join-Path $temporaryDirectory 'empty.psd1'
  $invalidPath = Join-Path $temporaryDirectory 'invalid.psd1'
  $configText = @"
@{ ConfigurationVersion = 1; Language = 'fr-FR'; MaxConcurrency = 2; RefreshSeconds = 60; Checks = @(
  @{ Name = 'Slow HTTP'; Type = 'Http'; Uri = 'http://127.0.0.1:$fixturePort/'; TimeoutSeconds = 2 }
  @{ Name = '=Été <script>&'; Type = 'Tcp'; HostName = '127.0.0.1'; Port = $fixturePort; Group = 'A&B' }
  @{ Name = 'Disabled'; Type = 'Ping'; HostName = 'localhost'; Enabled = `$false }
) }
"@
  [IO.File]::WriteAllText($path, $configText, [Text.Encoding]::UTF8)
  [IO.File]::WriteAllText($emptyPath, "@{ ConfigurationVersion = 1; Checks = @() }")
  [IO.File]::WriteAllText($invalidPath, "@{ ConfigurationVersion = 99; Checks = @() }")
  $server = [PowerShell]::Create()
  $null = $server.AddScript('param($launcher, $path, $port) & $launcher -ConfigurationPath $path -UI Web -NoBrowser -Port $port')
  $null = $server.AddArgument((Join-Path $root 'src/MyLittleSupervision.ps1')).AddArgument($path).AddArgument($port)
  $handle = $server.BeginInvoke()
  $handler = New-Object Net.Http.HttpClientHandler
  $handler.UseProxy = $false
  $script:client = New-Object Net.Http.HttpClient($handler)
  $client.Timeout = [TimeSpan]::FromSeconds(4)
  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  $bootstrap = $null
  while ([DateTime]::UtcNow -lt $deadline) {
    if ($handle.IsCompleted) { throw ('Server exited: ' + ($server.Streams.Error -join '; ')) }
    try { $bootstrap = Send-TestRequest '/api/configuration'; break }
    catch { Start-Sleep -Milliseconds 100 }
  }
  Assert-Web ($null -ne $bootstrap -and $bootstrap.Status -eq 200) 'Web launcher starts without WPF'
  $metadata = $bootstrap.Body | ConvertFrom-Json
  $auth = @{ 'X-CSRF-Token' = $metadata.token; Origin = $origin }
  Assert-Web ($metadata.language -eq 'fr-FR' -and $metadata.strings.'Status.Online' -eq 'Disponible') 'Browser receives French resources'
  $asset = Send-TestRequest '/'
  Assert-Web ($asset.Status -eq 200 -and $asset.Csp.Contains("frame-ancestors 'none'")) 'Local HTML has restrictive CSP'
  foreach ($route in @('/app.js', '/api.js', '/localization.js', '/view.js', '/style.css')) { Assert-Web ((Send-TestRequest $route).Status -eq 200) "Local asset $route" }
  Assert-Web ((Send-TestRequest '/api/status' -Headers @{ Host = 'attacker.invalid' }).Status -eq 403) 'Reject DNS rebinding Host'
  Assert-Web ((Send-TestRequest '/api/status' -Headers @{ Origin = 'http://attacker.invalid' }).Status -eq 403) 'Reject foreign origin'
  Assert-Web ((Send-TestRequest '/api/status' -Headers @{ 'Sec-Fetch-Site' = 'cross-site' }).Status -eq 403) 'Reject cross-site browser requests'
  Assert-Web ((Send-TestRequest '/api/refresh' -Method POST -Body '{}').Status -eq 403) 'Reject mutation without CSRF token'
  Assert-Web ((Send-TestRequest '/api/pause' -Method POST -Body '{"paused":"yes"}' -Headers $auth).Status -eq 400) 'Reject invalid API value'
  Assert-Web ((Send-TestRequest '/api/pause' -Method POST -Body '{"paused":true}' -Headers $auth).Status -eq 200) 'Pause automatic checks'
  $slowClient = New-Object Net.Sockets.TcpClient
  $slowClient.Connect('127.0.0.1', $port)
  $partial = [Text.Encoding]::ASCII.GetBytes('GET /api/status HTTP/1.1')
  $slowClient.GetStream().Write($partial, 0, $partial.Length)
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $snapshot = (Send-TestRequest '/api/status').Body | ConvertFrom-Json
  Assert-Web ($watch.ElapsedMilliseconds -lt 1500 -and $snapshot.paused) 'Partial HTTP client does not block API requests'
  Assert-Web ($snapshot.checks.Count -eq 3 -and $snapshot.checks[1].Name -eq '=Été <script>&') 'Special labels survive JSON'
  Assert-Web (@($snapshot.checks | Where-Object Status -eq 'Disabled').Count -eq 1) 'Disabled check is displayed'
  $deadline = [DateTime]::UtcNow.AddSeconds(8)
  do {
    $snapshot = (Send-TestRequest '/api/status').Body | ConvertFrom-Json
    if (-not $snapshot.running) { break }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  Assert-Web (-not $snapshot.running -and $snapshot.checks[0].Message -eq 'Timeout' -and $snapshot.checks[1].Status -eq 'Online') 'Slow HTTP timeout is isolated from TCP success'
  $historyResponse = Send-TestRequest ('/api/history?name=' + [Uri]::EscapeDataString('=Été <script>&'))
  Assert-Web (($historyResponse.Body | ConvertFrom-Json).results.Count -eq 1) 'Selected resource history is available'
  Assert-Web ((Send-TestRequest '/api/history').Status -eq 400) 'Missing history name rejected'
  $export = Send-TestRequest '/api/export?group=A%26B&search=%3D&incidents=false'
  Assert-Web ($export.Body.Contains("'=Été <script>&") -and -not $export.Body.Contains('Slow HTTP')) 'CSV filters and formula escaping'
  $exportWithSpaces = Send-TestRequest '/api/export?search=Slow+HTTP'
  Assert-Web ($exportWithSpaces.Body.Contains('Slow HTTP') -and -not $exportWithSpaces.Body.Contains('Disabled')) 'URL-encoded spaces round-trip in export filters'
  $invalidBody = @{ path = $invalidPath } | ConvertTo-Json
  Assert-Web ((Send-TestRequest '/api/configuration' -Method POST -Body $invalidBody -Headers $auth).Status -eq 400) 'Invalid configuration rejected'
  Assert-Web (((Send-TestRequest '/api/status').Body | ConvertFrom-Json).checks.Count -eq 3) 'Invalid configuration retains live state'
  Assert-Web ((Send-TestRequest '/api/refresh' -Method POST -Body '{}' -Headers $auth).Status -eq 200) 'Manual refresh works while paused'
  $null = Send-TestRequest '/api/status'
  $body = @{ path = $emptyPath } | ConvertTo-Json
  Assert-Web ((Send-TestRequest '/api/configuration' -Method POST -Body $body -Headers $auth).Status -eq 200) 'Valid configuration queued during active checks'
  $snapshot = (Send-TestRequest '/api/status').Body | ConvertFrom-Json
  Assert-Web ($snapshot.pending -and $snapshot.checks.Count -eq 3) 'Replacement waits for active workers'
  $deadline = [DateTime]::UtcNow.AddSeconds(8)
  do {
    $snapshot = (Send-TestRequest '/api/status').Body | ConvertFrom-Json
    if (-not $snapshot.pending) { break }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  Assert-Web ($snapshot.checks.Count -eq 0 -and $snapshot.revision -eq 2 -and $snapshot.journal.Count -eq 0) 'Configuration replacement resets session history'
  Assert-Web ((Send-TestRequest '/api/export').Body.Contains('"Name","Type","Target"')) 'Empty export retains CSV headers'
  Assert-Web (-not $server.HadErrors) 'Server has no unexpected PowerShell errors'
  $server.Stop()
  $server.Dispose()
  $server = [PowerShell]::Create()
  $startupUI = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'Web' } else { 'Auto' }
  $null = $server.AddScript('param($launcher, $path, $port, $ui) & $launcher -ConfigurationPath $path -UI $ui -NoBrowser -Port $port')
  $null = $server.AddArgument((Join-Path $root 'src/MyLittleSupervision.ps1')).AddArgument($invalidPath).AddArgument($port).AddArgument($startupUI)
  $handle = $server.BeginInvoke()
  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  $bootstrap = $null
  while ([DateTime]::UtcNow -lt $deadline) {
    if ($handle.IsCompleted) { throw ('Server restart failed: ' + ($server.Streams.Error -join '; ')) }
    try { $bootstrap = Send-TestRequest '/api/configuration'; break }
    catch { Start-Sleep -Milliseconds 100 }
  }
  Assert-Web ($null -ne $bootstrap -and $bootstrap.Status -eq 200) 'Shutdown releases port for next launcher'
  $metadata = $bootstrap.Body | ConvertFrom-Json
  $auth = @{ 'X-CSRF-Token' = $metadata.token; Origin = $origin }
  $snapshot = (Send-TestRequest '/api/status').Body | ConvertFrom-Json
  Assert-Web ($snapshot.configurationFailed -and $snapshot.checks.Count -eq 0) 'Invalid startup configuration opens recoverable empty dashboard'
  Assert-Web ((Send-TestRequest '/api/configuration' -Method POST -Body $body -Headers $auth).Status -eq 200) 'Load valid configuration after startup failure'
  $snapshot = (Send-TestRequest '/api/status').Body | ConvertFrom-Json
  Assert-Web (-not $snapshot.configurationFailed -and $snapshot.revision -eq 2) 'Startup error clears after successful load'
  Write-Output "Passed $passed web assertions."
}
finally {
  if ($null -ne $slowClient) { $slowClient.Dispose() }
  if ($null -ne $client) { $client.Dispose() }
  if ($null -ne $server) { $server.Stop(); $server.Dispose() }
  if ($null -ne $fixture) { $fixture.Stop() }
  $env:XDG_STATE_HOME = $previousStateHome
  Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
}
