# Version 1 sample configuration loaded by default by MyLittleSupervision.ps1.
# Only local Ping is enabled; replace service targets before enabling other checks.
# Configuration fields and defaults are documented in README.md.
@{
    ConfigurationVersion = 1
    Language = 'fr-FR'
    RefreshSeconds = 30
    MaxConcurrency = 4
    Checks = @(
        @{
            Name = 'Local computer'
            Group = 'Local'
            Type = 'Ping'
            HostName = '127.0.0.1'
            TimeoutSeconds = 3
            SlowThresholdMs = 100
        }
        # Enable these examples after replacing their targets with your own services.
        @{
            Name = 'Web health'
            Group = 'Web'
            Type = 'Http'
            Uri = 'https://example.com/health'
            Method = 'GET'
            ExpectedStatusCodes = @(200)
            TimeoutSeconds = 5
            Enabled = $false
        }
        @{
            Name = 'API health'
            Group = 'Web'
            Type = 'Http'
            Uri = 'http://localhost:8080/health'
            Method = 'POST'
            Headers = @{ 'Content-Type' = 'application/json' }
            Body = '{"probe":"health"}'
            ExpectedStatusCodes = @(200, 204)
            Enabled = $false
        }
        @{
            Name = 'Local TCP service'
            Group = 'Services'
            Type = 'Tcp'
            HostName = 'localhost'
            Port = 8080
            Enabled = $false
        }
    )
}
