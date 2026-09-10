# Default language, the empty translation table, Get-Translation, Resolve-WtCatalogText. en.ps1 and tr.ps1 fill the table.
# Covered by: tests/Translations.Tests.ps1, tests/CatalogI18n.Tests.ps1

$script:Language = "EN"
$script:Translations = @{}

function Get-Translation($Key) {
    return $script:Translations[$script:Language][$Key]
}

function Resolve-WtCatalogText {
    <#
    .SYNOPSIS
        Localizes catalog prose at build time: LabelKey -> DisplayLabel,
        ConsequenceKey -> Consequence, via the active language. A missing
        key leaves the shipped English literal in place, so a
        half-translated table degrades gracefully instead of blanking
        labels. With KeyPrefix, an entry with no explicit key gets one
        synthesized from its sanitized Name; the sanitizer uses
        -creplace, not -replace, because a culture-aware replace drops
        the capital I on Turkish systems.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Catalog,
        [string]$KeyPrefix
    )

    foreach ($entry in $Catalog) {
        $props = $entry.PSObject.Properties.Name
        if ($KeyPrefix) {
            $sanitized = ([string]$entry.Name) -creplace '[^A-Za-z0-9]', ''
            if ($props -contains 'DisplayLabel' -and $entry.DisplayLabel -and -not ($props -contains 'LabelKey' -and $entry.LabelKey)) {
                $entry | Add-Member -NotePropertyName 'LabelKey' -NotePropertyValue ('Cat{0}{1}Label' -f $KeyPrefix, $sanitized) -Force
            }
            if ($props -contains 'Consequence' -and $entry.Consequence -and -not ($props -contains 'ConsequenceKey' -and $entry.ConsequenceKey)) {
                $entry | Add-Member -NotePropertyName 'ConsequenceKey' -NotePropertyValue ('Cat{0}{1}Consequence' -f $KeyPrefix, $sanitized) -Force
            }
            $props = $entry.PSObject.Properties.Name
        }
        if ($props -contains 'LabelKey' -and $entry.LabelKey) {
            $text = Get-Translation $entry.LabelKey
            if ($text) {
                if ($props -contains 'LabelArgs' -and $null -ne $entry.LabelArgs) { $text = $text -f @($entry.LabelArgs) }
                $entry | Add-Member -NotePropertyName 'DisplayLabel' -NotePropertyValue $text -Force
            }
        }
        if ($props -contains 'ConsequenceKey' -and $entry.ConsequenceKey) {
            $text = Get-Translation $entry.ConsequenceKey
            if ($text) {
                if ($props -contains 'ConsequenceArgs' -and $null -ne $entry.ConsequenceArgs) { $text = $text -f @($entry.ConsequenceArgs) }
                $entry | Add-Member -NotePropertyName 'Consequence' -NotePropertyValue $text -Force
            }
        }
    }
    return $Catalog
}
