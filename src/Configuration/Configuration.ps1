<#
.SYNOPSIS
Defines declarative PSD1 validation and normalization.

.DESCRIPTION
Dot-source before loading configuration. Rejects unsupported input and produces
the common check model consumed by the scheduler and UI.

.OUTPUTS
None.
#>

Set-StrictMode -Version Latest

function Assert-ConfigurationKeys {
    <#
    .SYNOPSIS
    Rejects unsupported configuration keys.

    .DESCRIPTION
    Throws at the first key outside the allowed set; required keys are checked
    by the caller.

    .PARAMETER Data
    Hashtable whose keys are inspected.

    .PARAMETER Allowed
    Accepted key names, compared case insensitively.

    .PARAMETER Context
    Section label included in the validation error.

    .OUTPUTS
    None.
    #>
    param([hashtable] $Data, [string[]] $Allowed, [string] $Context)
    foreach ($key in $Data.Keys) {
        if ($key -notin $Allowed) { throw "${Context}: unsupported key '$key'." }
    }
}

function Get-IntegerSetting {
    <#
    .SYNOPSIS
    Reads a bounded integer setting or its default.

    .DESCRIPTION
    Accepts Int32 and Int64 values within inclusive bounds; throws for other
    supplied values. The caller must supply a valid default.

    .PARAMETER Data
    Configuration hashtable containing the optional setting.

    .PARAMETER Key
    Name of the setting to retrieve.

    .PARAMETER Default
    Value returned when the key is absent.

    .PARAMETER Minimum
    Smallest accepted supplied value.

    .PARAMETER Maximum
    Largest accepted supplied value.

    .OUTPUTS
    System.Int32. The supplied value or default.
    #>
    param([hashtable] $Data, [string] $Key, [int] $Default, [int] $Minimum, [int] $Maximum)
    if (-not $Data.ContainsKey($Key)) { return $Default }
    $value = $Data[$Key]
    if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt $Minimum -or $value -gt $Maximum) {
        throw "$Key must be an integer between $Minimum and $Maximum."
    }
    return [int] $value
}

function Import-MonitorConfiguration {
    <#
    .SYNOPSIS
    Loads and validates a declarative monitoring configuration.

    .DESCRIPTION
    Imports a PSD1 data file without executing arbitrary configuration code.
    Validates version 1, check-specific fields and limits, then adds defaults
    and normalized targets. Import or validation failures throw before a
    configuration is returned.

    .PARAMETER Path
    Literal path to the PSD1 file to load.

    .OUTPUTS
    System.Collections.Hashtable. Language, refresh interval, concurrency limit
    and validated Checks.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)
    $data = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
    Assert-ConfigurationKeys $data @('ConfigurationVersion', 'Language', 'RefreshSeconds', 'MaxConcurrency', 'Checks') 'Configuration'
    if (-not $data.ContainsKey('ConfigurationVersion') -or $data.ConfigurationVersion -isnot [int] -or $data.ConfigurationVersion -ne 1) { throw 'ConfigurationVersion must be 1.' }
    if (-not $data.ContainsKey('Checks') -or $data.Checks -isnot [array]) { throw 'Checks must be an array.' }
    if ($data.Checks.Count -gt 1000) { throw 'Checks may contain at most 1000 entries.' }
    $language = 'en-US'
    if ($data.ContainsKey('Language')) {
        if ($data.Language -notin @('en-US', 'fr-FR')) { throw 'Language must be en-US or fr-FR.' }
        $language = $data.Language
    }
    $names = @{}
    $checks = foreach ($entry in $data.Checks) {
        if ($entry -isnot [hashtable]) { throw 'Each check must be a hashtable.' }
        Assert-ConfigurationKeys $entry @('Name', 'Type', 'Group', 'HostName', 'Port', 'Uri', 'Method', 'Headers', 'Body', 'ExpectedStatusCodes', 'TimeoutSeconds', 'SlowThresholdMs', 'Enabled') 'Check'
        foreach ($key in @('Name', 'Type')) {
            if (-not $entry.ContainsKey($key) -or $entry[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($entry[$key])) { throw "Each check requires a non-empty $key string." }
        }
        if ($names.ContainsKey($entry.Name)) { throw 'Check names must be unique (case insensitive).' }
        $names[$entry.Name] = $true
        if ($entry.Type -notin @('Ping', 'Http', 'Tcp')) { throw 'Type must be Ping, Http or Tcp.' }
        $check = @{
            Name = $entry.Name; Type = $entry.Type; Group = 'Default'; Enabled = $true
            TimeoutSeconds = Get-IntegerSetting $entry 'TimeoutSeconds' 5 1 120
            SlowThresholdMs = Get-IntegerSetting $entry 'SlowThresholdMs' 1000 1 120000
        }
        if ($entry.ContainsKey('Group')) {
            if ($entry.Group -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.Group)) { throw 'Group must be a non-empty string.' }
            $check.Group = $entry.Group
        }
        if ($entry.ContainsKey('Enabled')) {
            if ($entry.Enabled -isnot [bool]) { throw 'Enabled must be a boolean.' }
            $check.Enabled = $entry.Enabled
        }
        if ($entry.Type -eq 'Http') {
            foreach ($key in @('HostName', 'Port')) { if ($entry.ContainsKey($key)) { throw "HTTP checks do not support $key." } }
            $uri = $null
            if (-not $entry.ContainsKey('Uri') -or $entry.Uri -isnot [string] -or -not [Uri]::TryCreate($entry.Uri, [UriKind]::Absolute, [ref] $uri) -or $uri.Scheme -notin @('http', 'https') -or $uri.UserInfo -or $uri.Fragment) { throw 'Uri must be an absolute HTTP(S) URL without credentials or a fragment.' }
            $check.Uri = $uri.AbsoluteUri
            $check.Target = $check.Uri
            $check.Method = 'GET'
            if ($entry.ContainsKey('Method')) {
                if ($entry.Method -notin @('GET', 'POST')) { throw 'Method must be GET or POST.' }
                $check.Method = $entry.Method.ToUpperInvariant()
            }
            $check.Body = ''
            if ($entry.ContainsKey('Body')) {
                if ($entry.Body -isnot [string] -or $check.Method -ne 'POST') { throw 'Body must be a string and is only supported for POST.' }
                $check.Body = $entry.Body
            }
            $check.Headers = @{}
            if ($entry.ContainsKey('Headers')) {
                if ($entry.Headers -isnot [hashtable]) { throw 'Headers must be a hashtable.' }
                foreach ($key in $entry.Headers.Keys) {
                    if ($key -isnot [string] -or $key -notmatch '^[A-Za-z0-9-]+$' -or $entry.Headers[$key] -isnot [string] -or $entry.Headers[$key] -match '[\r\n]') { throw 'Invalid HTTP header name or value.' }
                    if ($key -match '(?i)authorization|cookie|token|api.?key|secret' -or $key -in @('Host', 'Content-Length', 'Transfer-Encoding', 'Connection')) { throw 'Credentials and transport-controlled headers are not supported.' }
                    if ($key -like 'Content-*' -and ($key -ne 'Content-Type' -or $check.Method -ne 'POST')) { throw 'Only Content-Type on POST is supported as a content header.' }
                    $check.Headers[$key] = $entry.Headers[$key]
                }
            }
            $check.ExpectedStatusCodes = @(200..299)
            if ($entry.ContainsKey('ExpectedStatusCodes')) {
                if ($entry.ExpectedStatusCodes -isnot [array] -or $entry.ExpectedStatusCodes.Count -eq 0) { throw 'ExpectedStatusCodes must be a non-empty array.' }
                foreach ($code in $entry.ExpectedStatusCodes) {
                    if ($code -isnot [int] -or $code -lt 100 -or $code -gt 599) { throw 'ExpectedStatusCodes must contain integers from 100 to 599.' }
                }
                $check.ExpectedStatusCodes = $entry.ExpectedStatusCodes
            }
        }
        else {
            foreach ($key in @('Uri', 'Method', 'Headers', 'Body', 'ExpectedStatusCodes')) { if ($entry.ContainsKey($key)) { throw "Non-HTTP checks do not support $key." } }
            if (-not $entry.ContainsKey('HostName') -or $entry.HostName -isnot [string] -or [Uri]::CheckHostName($entry.HostName) -eq [UriHostNameType]::Unknown) { throw 'HostName must be a valid host name or IP address.' }
            $check.HostName = $entry.HostName
            $check.Target = $entry.HostName
            if ($entry.Type -eq 'Tcp') {
                if (-not $entry.ContainsKey('Port')) { throw 'TCP checks require Port.' }
                $check.Port = Get-IntegerSetting $entry 'Port' 80 1 65535
                $check.Target = '{0}:{1}' -f $entry.HostName, $check.Port
            }
            elseif ($entry.ContainsKey('Port')) { throw 'Ping checks do not support Port.' }
        }
        $check
    }
    return @{
        ConfigurationVersion = 1; Language = $language
        RefreshSeconds = Get-IntegerSetting $data 'RefreshSeconds' 30 5 86400
        MaxConcurrency = Get-IntegerSetting $data 'MaxConcurrency' 4 1 16
        Checks = @($checks)
    }
}
