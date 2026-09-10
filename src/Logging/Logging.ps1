<#
.SYNOPSIS
Defines per-user diagnostic logging.

.DESCRIPTION
Dot-source to enable UTF-8 file logging with one rotated backup. Callers choose
a writable directory and supply diagnostic text free of secrets.

.OUTPUTS
None.
#>

Set-StrictMode -Version Latest

function Write-ApplicationLog {
    <#
    .SYNOPSIS
    Appends a UTC diagnostic line with bounded file rotation.

    .DESCRIPTION
    Creates the directory if needed. Rotates application.log to
    application.previous.log when the existing file exceeds 2 MB, replacing the
    previous backup. Message line breaks are flattened. Failures return false so
    callers can report them without stopping monitoring. Callers must exclude
    secrets from all fields.

    .PARAMETER Directory
    Writable log directory, normally below the current user LocalApplicationData
    folder.

    .PARAMETER Level
    Severity label, conventionally Debug, Info, Warning or Error.

    .PARAMETER Component
    Short diagnostic component name.

    .PARAMETER Message
    Safe diagnostic text to append; this function does not redact secrets.

    .OUTPUTS
    System.Boolean. True on success; false if directory creation, rotation or
    writing fails.
    #>
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
        # Logging failure must not interrupt monitoring, but remains visible to
        # the caller.
        return $false
    }
}
