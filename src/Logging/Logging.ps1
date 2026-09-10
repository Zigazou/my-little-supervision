Set-StrictMode -Version Latest

function Write-ApplicationLog {
    param([string] $Directory, [string] $Level, [string] $Component, [string] $Message)
    try {
        if (-not (Test-Path -LiteralPath $Directory)) { $null = New-Item -ItemType Directory -Path $Directory -Force }
        $path = Join-Path $Directory 'application.log'
        if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 2MB) {
            Move-Item -LiteralPath $path -Destination (Join-Path $Directory 'application.previous.log') -Force
        }
        $line = '{0:o} [{1}] [{2}] {3}' -f [DateTime]::UtcNow, $Level, $Component, ($Message -replace '[\r\n]', ' ')
        Add-Content -LiteralPath $path -Value $line -Encoding UTF8
        return $true
    }
    catch {
        # Logging failure must not interrupt monitoring, but remains visible to the caller.
        return $false
    }
}
