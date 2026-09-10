# The OpenAI tool-schema builder and the search-text folding helper used
# by the DERIVED WinToolify tool index the model searches and suggests
# from. The tool registry itself lives in 40-catalogs/assistant-registry.ps1.
# Covered by: tests/AssistantRegistry.Tests.ps1, tests/AssistantIndex.Tests.ps1

function New-WtAssistantFunctionSchema {
    <#
    .SYNOPSIS
        One OpenAI tool declaration. 'function' is quoted everywhere - it
        is a keyword-shaped key.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Description,
        [hashtable]$Properties = @{},
        [AllowEmptyCollection()][string[]]$Required = @()
    )
    $parameters = @{ type = 'object'; properties = $Properties; additionalProperties = $false }
    if (@($Required).Count -gt 0) { $parameters['required'] = @($Required) }
    return @{ type = 'function'; 'function' = @{ name = $Name; description = $Description; parameters = $parameters } }
}

function ConvertTo-WtAssistantSearchText {
    <#
    .SYNOPSIS
        Folds the six Turkish letters (both cases) to their ASCII base and
        lowercases invariantly. The index rows are pure ASCII (src rule),
        but the model searches with the user's own spelling - s-cedilla,
        dotless i, c-cedilla - and no ordinal comparison bridges dotted
        and dotless i by itself. Folding BOTH sides before comparing
        makes either spelling meet the other.
    #>
    param([AllowEmptyString()][string]$Text)
    $folded = [string]$Text
    foreach ($pair in @(
            @(0x00E7, 'c'), @(0x00C7, 'C'),
            @(0x011F, 'g'), @(0x011E, 'G'),
            @(0x0131, 'i'), @(0x0130, 'I'),
            @(0x00F6, 'o'), @(0x00D6, 'O'),
            @(0x015F, 's'), @(0x015E, 'S'),
            @(0x00FC, 'u'), @(0x00DC, 'U'))) {
        $folded = $folded.Replace([char][int]$pair[0], [char][string]$pair[1])
    }
    return $folded.ToLowerInvariant()
}
