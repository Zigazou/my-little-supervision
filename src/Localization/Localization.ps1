<#
.SYNOPSIS
Defines resource loading and translation lookup.

.DESCRIPTION
Dot-source before initializing the UI. English resources supply fallback values
for optional translations.

.OUTPUTS
None.
#>

Set-StrictMode -Version Latest

function Import-Translations {
    <#
    .SYNOPSIS
    Loads English resources and overlays a selected language.

    .DESCRIPTION
    English is always loaded first. Missing language files or missing translated
    keys retain English text; data-file import errors propagate.

    .PARAMETER Directory
    Directory containing en-US.psd1 and optional language PSD1 files.

    .PARAMETER Language
    Language file stem, normally en-US or fr-FR, without the .psd1 extension.

    .OUTPUTS
    System.Collections.Hashtable. Merged resource keys and text.
    #>
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
    <#
    .SYNOPSIS
    Resolves a resource key to display text.

    .DESCRIPTION
    Returns the key itself when no translation is present, keeping missing
    resources visible.

    .PARAMETER Strings
    Resource table returned by Import-Translations.

    .PARAMETER Key
    Stable resource identifier, such as Status.Online.

    .OUTPUTS
    System.String. Translated text or the original key.
    #>
    param([hashtable] $Strings, [string] $Key)
    if ($Strings.ContainsKey($Key)) { return [string] $Strings[$Key] }
    return $Key
}
