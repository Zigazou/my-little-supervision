Set-StrictMode -Version Latest

function Import-Translations {
    param([string] $Directory, [string] $Language)
    $strings = Import-PowerShellDataFile -LiteralPath (Join-Path $Directory 'en-US.psd1')
    if ($Language -ne 'en-US') {
        $path = Join-Path $Directory "$Language.psd1"
        if (Test-Path -LiteralPath $path) {
            $localized = Import-PowerShellDataFile -LiteralPath $path
            foreach ($key in $localized.Keys) { $strings[$key] = $localized[$key] }
        }
    }
    return $strings
}

function Get-Translation {
    param([hashtable] $Strings, [string] $Key)
    if ($Strings.ContainsKey($Key)) { return [string] $Strings[$Key] }
    return $Key
}
