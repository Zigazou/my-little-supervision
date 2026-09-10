#Requires -Version 5.1
[CmdletBinding()]
param([switch] $SkipNetwork)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
foreach ($path in @('Configuration/Configuration.ps1', 'Localization/Localization.ps1', 'Checks/Checks.ps1', 'Core/Monitor.ps1', 'Logging/Logging.ps1', 'UI/Controller.ps1')) { . (Join-Path $root "src/$path") }
$script:passed = 0
function Assert-True {
    param([bool] $Condition, [string] $Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
    Write-Output "PASS: $Name"
}
function Assert-Rejected {
    param([string] $Content, [string] $Name)
    Set-Content -LiteralPath $script:testPath -Value $Content -Encoding UTF8
    $rejected = $false
    try { $null = Import-MonitorConfiguration $script:testPath } catch { $rejected = $true }
    Assert-True $rejected $Name
}
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('supervision-tests-' + [Guid]::NewGuid())
$null = New-Item -ItemType Directory -Path $temporary
$script:testPath = Join-Path $temporary 'test.psd1'
try {
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psd1') }) {
        $tokens = $null; $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $tokens, [ref] $errors)
        Assert-True ($errors.Count -eq 0) "PowerShell syntax: $($file.Name) $errors"
    }
    $configuration = Import-MonitorConfiguration (Join-Path $root 'config/example.psd1')
    Assert-True ($configuration.Checks.Count -eq 4) 'Example configuration loads'
    $groups = @(Get-CheckGroupOptions -Configuration $configuration -AllLabel 'Tous')
    Assert-True (($groups.Label -join '|') -eq 'Tous (4)|Local (1)|Services (1)|Web (2)') 'Group labels and counts match the example configuration'
    Assert-True (($groups.Value -join '|') -eq '|Local|Services|Web') 'Group filter values preserve configured names'
    $emptyGroups = @(Get-CheckGroupOptions -Configuration @{ Checks = @() } -AllLabel 'All')
    Assert-True ($emptyGroups.Count -eq 1 -and $emptyGroups[0].Label -eq 'All (0)' -and $emptyGroups[0].Value -eq '') 'Empty configuration only offers the all-groups option'
    Assert-True ($configuration.Checks[1].ExpectedStatusCodes[0] -eq 200) 'Expected HTTP codes preserved'
    Set-Content -LiteralPath $script:testPath -Value '@{ConfigurationVersion=1;Checks=@()}' -Encoding UTF8
    Assert-True ((Import-MonitorConfiguration $script:testPath).Checks.Count -eq 0) 'Empty configuration supported'
    $valid = "@{ ConfigurationVersion = 1; Checks = @(@{ Name = 'Été & <server>'; Type = 'Ping'; HostName = 'localhost' }) }"
    Set-Content -LiteralPath $script:testPath -Value $valid -Encoding UTF8
    $loaded = Import-MonitorConfiguration $script:testPath
    Assert-True ($loaded.Checks[0].Name -eq 'Été & <server>') 'Special characters survive import'
    $defaultGroups = @(Get-CheckGroupOptions -Configuration $loaded -AllLabel 'All')
    Assert-True ($defaultGroups.Count -eq 2 -and $defaultGroups[1].Label -eq 'Default (1)') 'Checks without a group use the default group'
    Assert-True ($loaded.Checks[0].TimeoutSeconds -eq 5 -and $loaded.MaxConcurrency -eq 4) 'Safe defaults applied'
    foreach ($case in @(
        @("@{ConfigurationVersion=2;Checks=@()}", 'Unsupported version'),
        @("@{ConfigurationVersion=1;Checks=@();Extra=1}", 'Unexpected root key'),
        @("@{ConfigurationVersion=1;Checks=@();RefreshSeconds='5'}", 'Numeric string rejected'),
        @("@{ConfigurationVersion=1;Checks=@();MaxConcurrency=99}", 'Concurrency bound'),
        @("@{ConfigurationVersion=1;Checks=@(@{Name='a';Type='Script'})}", 'Unsupported check type'),
        @("@{ConfigurationVersion=1;Checks=@(@{Name='a';Type='Ping';HostName='a';Enabled='false'})}", 'Boolean required'),
        @("@{ConfigurationVersion=1;Checks=@(@{Name='a';Type='Ping';HostName='a';TimeoutSeconds=0})}", 'Timeout bound'),
        @("@{ConfigurationVersion=1;Checks=@(@{Name='a';Type='Tcp';HostName='a';Port=65536})}", 'Port bound'),
        @("@{ConfigurationVersion=1;Checks=@(@{Name='a';Type='Ping';HostName='not a host'})}", 'Host validation'),
        @("@{ConfigurationVersion=1;Checks=@(@{Name='a';Type='Http';Uri='file:///tmp/a'})}", 'URI scheme validation'),
        @("@{ConfigurationVersion=1;Checks=@(@{Name='a';Type='Http';Uri='https://user:pass@example.com'})}", 'URI credentials rejected'),
        @("@{ConfigurationVersion=1;Checks=@(@{Name='a';Type='Http';Uri='http://localhost';Method='DELETE'})}", 'HTTP method validation'),
        @("@{ConfigurationVersion=1;Checks=@(@{Name='a';Type='Http';Uri='http://localhost';ExpectedStatusCodes=@(999)})}", 'HTTP status validation'),
        @("@{ConfigurationVersion=1;Checks=@(@{Name='a';Type='Http';Uri='http://localhost';Headers=@{Authorization='secret'}})}", 'Secret headers rejected'),
        @("@{ConfigurationVersion=1;Checks=@(@{Name='a';Type='Ping';HostName='a';Body='bad'})}", 'Type-specific schema validation'),
        @("@{ConfigurationVersion=1;Checks=@(@{Name='a';Type='Ping';HostName='a'},@{Name='A';Type='Ping';HostName='a'})}", 'Duplicate names rejected'),
        @('@{ConfigurationVersion=1;Checks=@();Language=$(throw "must not execute")}', 'Executable configuration rejected')
    )) { Assert-Rejected $case[0] $case[1] }
    $strings = Import-Translations (Join-Path $root 'src/Localization') 'fr-FR'
    Assert-True ((Get-Translation $strings 'Status.Online') -eq 'Disponible') 'French translation loaded'
    $fallback = Import-Translations (Join-Path $root 'src/Localization') 'missing'
    Assert-True ((Get-Translation $fallback 'Status.Online') -eq 'Online') 'English fallback for missing language'
    Assert-True ((Get-Translation $fallback 'Absent.Key') -eq 'Absent.Key') 'Missing resource key is visible'
    $strings = Import-PowerShellDataFile (Join-Path $root 'src/Localization/fr-FR.psd1')
    $english = Import-PowerShellDataFile (Join-Path $root 'src/Localization/en-US.psd1')
    Assert-True (@($english.Keys | Where-Object { -not $strings.ContainsKey($_) }).Count -eq 0) 'Translation key parity'
    $xaml = Get-Content -LiteralPath (Join-Path $root 'src/UI/MainWindow.xaml') -Raw
    $null = [xml] $xaml
    $resourceKeys = [regex]::Matches($xaml, '\{DynamicResource ([^}]+)\}')
    Assert-True (@($resourceKeys | Where-Object { -not $english.ContainsKey($_.Groups[1].Value) }).Count -eq 0) 'All XAML translation keys exist'
    $partialDirectory = Join-Path $temporary 'translations'
    $null = New-Item -ItemType Directory -Path $partialDirectory
    Copy-Item -LiteralPath (Join-Path $root 'src/Localization/en-US.psd1') -Destination $partialDirectory
    Set-Content -LiteralPath (Join-Path $partialDirectory 'fr-FR.psd1') -Value "@{'Status.Online'='Disponible'}" -Encoding UTF8
    $partial = Import-Translations $partialDirectory 'fr-FR'
    Assert-True ($partial['Status.Offline'] -eq 'Offline' -and $partial['Status.Online'] -eq 'Disponible') 'Missing translated keys fall back individually'
    $check = $loaded.Checks[0]
    $check.Enabled = $false
    Assert-True ((Invoke-MonitorCheck $check).Status -eq 'Disabled') 'Disabled check does no network work'
    $check.Enabled = $true
    $result = New-CheckResult $check 'Degraded' 'PingReply' 123 'Success'
    Assert-True ($result.Success -and $result.DurationMs -eq 123 -and $result.Timestamp.Kind -eq 'Utc') 'Normalized slow result'
    $logDirectory = Join-Path $temporary 'logs'
    Assert-True (Write-ApplicationLog $logDirectory 'Info' 'Tests' 'Safe message') 'Per-user log writes'
    $logPath = Join-Path $logDirectory 'application.log'
    [IO.File]::WriteAllText($logPath, ('x' * (2MB + 1)))
    $null = Write-ApplicationLog $logDirectory 'Info' 'Tests' 'Rotation'
    Assert-True (Test-Path (Join-Path $logDirectory 'application.previous.log')) 'Log rotation'

    # A worker fixture tests scheduler bounds and failure isolation without network access.
    $fixture = Join-Path $temporary 'Worker.ps1'
    Set-Content -LiteralPath $fixture -Encoding UTF8 -Value @'
function Invoke-MonitorCheck {
    param($Check)
    Start-Sleep -Milliseconds 30
    if ($Check.Name -eq 'broken') { throw 'Fixture failure' }
    [pscustomobject]@{ Name=$Check.Name; Type=$Check.Type; Target=$Check.Target; Status='Online'; Success=$true; Message='TcpConnected'; DurationMs=30; Timestamp=[DateTime]::UtcNow; Details=@{Code=$null} }
}
'@
    $schedulerConfiguration = @{ MaxConcurrency = 2; RefreshSeconds = 5; Checks = @() }
    foreach ($name in @('first', 'broken', 'third', 'fourth')) { $schedulerConfiguration.Checks += @{ Name=$name; Type='Tcp'; Target='localhost'; Enabled=$true } }
    $state = New-MonitorState $schedulerConfiguration $fixture
    try {
        Start-MonitorCycle $state
        $allResults = @()
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while ($state.Running -and [DateTime]::UtcNow -lt $deadline) {
            $allResults += @(Receive-MonitorResults $state)
            if ($state.Active.Count -gt 2) { throw 'Concurrency exceeded' }
            Start-Sleep -Milliseconds 20
        }
        Assert-True ($allResults.Count -eq 4) 'All scheduled checks complete within deadline'
        Assert-True ($state.Results['broken'].Status -eq 'Error' -and $state.Results['third'].Success) 'Worker failures isolated'
        Assert-True ($state.Active.Count -eq 0 -and -not $state.Running) 'Workers cleaned up'
    }
    finally { Close-MonitorState $state }

    if (-not $SkipNetwork) {
        $check.HostName = '127.0.0.1'
        $check.Target = '127.0.0.1'
        $check.SlowThresholdMs = 120000
        $result = Invoke-MonitorCheck $check
        Assert-True ($result.Status -eq 'Online') 'Loopback Ping success'
        foreach ($scenario in @(@(200, 0, 'GET', 'Online'), @(503, 0, 'GET', 'Offline'), @(204, 0, 'POST', 'Online'), @(200, 1800, 'GET', 'Offline'))) {
            $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
            $listener.Start()
            $port = $listener.LocalEndpoint.Port
            $server = [PowerShell]::Create()
            $null = $server.AddScript({
                param($listener, $status, $delay)
                $client = $listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    $stream.ReadTimeout = 5000
                    $buffer = New-Object byte[] 8192
                    $count = $stream.Read($buffer, 0, $buffer.Length)
                    $requestText = [Text.Encoding]::UTF8.GetString($buffer, 0, $count)
                    Start-Sleep -Milliseconds $delay
                    $bytes = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status Test`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                    $stream.Write($bytes, 0, $bytes.Length)
                    $requestText
                }
                finally { $client.Dispose() }
            }).AddArgument($listener).AddArgument($scenario[0]).AddArgument($scenario[1])
            $handle = $server.BeginInvoke()
            try {
                $http = @{ Name='fixture'; Type='Http'; Target='loopback'; Uri="http://127.0.0.1:$port/"; Enabled=$true; TimeoutSeconds=1; SlowThresholdMs=120000; Method=$scenario[2]; Headers=@{}; Body='probe'; ExpectedStatusCodes=@(200,204) }
                $result = Invoke-MonitorCheck $http
                Assert-True ($result.Status -eq $scenario[3]) "HTTP $($scenario[0]) / $($scenario[2]) / delay $($scenario[1])"
                if ($scenario[1] -gt 0) { Assert-True ($result.Message -eq 'Timeout' -and $result.DurationMs -lt 1700) 'HTTP deadline normalization' }
                if (-not $handle.AsyncWaitHandle.WaitOne(6000)) { throw 'Fixture server exceeded deadline' }
                $requests = @($server.EndInvoke($handle))
                if ($scenario[2] -eq 'POST') { Assert-True ($requests[0] -like 'POST /*') 'POST method sent' }
            }
            finally { $listener.Stop(); $server.Stop(); $server.Dispose() }
        }
        $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $tcp = @{Name='tcp';Type='Tcp';Target='loopback';HostName='127.0.0.1';Port=$listener.LocalEndpoint.Port;Enabled=$true;TimeoutSeconds=1;SlowThresholdMs=120000}
        try { Assert-True ((Invoke-MonitorCheck $tcp).Success) 'TCP connection succeeds' }
        finally { $listener.Stop() }
        Assert-True ((Invoke-MonitorCheck $tcp).Status -eq 'Offline') 'TCP refusal normalized'
    }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Add-Type -AssemblyName PresentationFramework
        $reader = [Xml.XmlReader]::Create((Join-Path $root 'src/UI/MainWindow.xaml'))
        try { $window = [Windows.Markup.XamlReader]::Load($reader) }
        finally { $reader.Dispose() }
        Assert-True ($null -ne $window.FindName('ChecksDataGrid')) 'WPF XAML loads'
        $window.Close()
    }
    Write-Output "All $script:passed assertions passed."
}
finally { Remove-Item -LiteralPath $temporary -Recurse -Force }
