# The assistant's tool registry: one data record per tool, from which the
# OpenAI schemas and the dispatch table are both derived.
# Covered by: tests/AssistantRegistry.Tests.ps1

function New-WtAssistantToolRecord {
    <#
    .SYNOPSIS
        One registry record. Parameters are hashtables @{ Name; Type;
        Description; Param; Enum?; Default? }. MaskArgs masks string
        arguments before the handler sees them; PassContext adds
        -Context; Hint is appended when the result must be cut.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$DescriptionKey,
        [Parameter(Mandatory)][string]$Handler,
        [ValidateSet('read', 'net')][string]$Tier = 'read',
        [AllowEmptyCollection()][array]$Parameters = @(),
        [AllowEmptyCollection()][string[]]$Required = @(),
        [switch]$SkipIpMask,
        [AllowEmptyCollection()][string[]]$MaskArgs = @(),
        [switch]$PassContext,
        [int]$MaxChars = 2500,
        [AllowEmptyString()][string]$Hint = ''
    )
    return @{
        Name = $Name; DescriptionKey = $DescriptionKey; Handler = $Handler; Tier = $Tier
        Parameters = @($Parameters); Required = [string[]]@($Required)
        SkipIpMask = [bool]$SkipIpMask; MaskArgs = [string[]]@($MaskArgs); PassContext = [bool]$PassContext; MaxChars = $MaxChars
        Hint = [string]$Hint
    }
}

function Get-WtAssistantReadTopics {
    <#
    .SYNOPSIS
        The twelve read_system topic names, in the fixed order the
        router and the unknown-topic hint both rely on.
    #>
    return [string[]]@('overview', 'errors', 'crashes', 'storage', 'network', 'network_tests', 'security', 'startup', 'services', 'processes', 'wintoolify_changes', 'wintoolify_status')
}

function Get-WtAssistantToolRegistry {
    <#
    .SYNOPSIS
        Every tool the model can call, as data. Read and net tiers only:
        the model never runs, applies or undoes anything.
    #>
    return @(
        (New-WtAssistantToolRecord -Name 'search_wintoolify' -DescriptionKey 'AsDescSearchWintoolify' -Handler 'Get-WtAssistantSearchResult' -Required @('query') -Hint 'narrow with section= or fewer, more specific words' -Parameters @(
            @{ Name = 'query'; Type = 'string'; Description = 'Keywords, Turkish or English.'; Param = 'Query' }
            @{ Name = 'section'; Type = 'string'; Description = 'Section key, or a kind: Tools, Screens, Winget.'; Param = 'Section'; Enum = @(Get-WtAssistantSearchSections) }
            @{ Name = 'detail'; Type = 'boolean'; Description = 'Add the what column to at most 5 rows.'; Param = 'Detail'; Default = $false }))
        (New-WtAssistantToolRecord -Name 'suggest_wintoolify' -DescriptionKey 'AsDescSuggestWintoolify' -Handler 'Invoke-WtAssistantSuggest' -PassContext -Required @('ids') -Parameters @(
            @{ Name = 'ids'; Type = 'array'; Description = 'Ids from search_wintoolify, best first, at most 9.'; Param = 'Ids' }))
        (New-WtAssistantToolRecord -Name 'read_system' -DescriptionKey 'AsDescReadSystem' -Handler 'Get-WtAssistantSystemRead' -Required @('topic') -Hint 'use filter= to narrow (name, hours or count)' -Parameters @(
            @{ Name = 'topic'; Type = 'string'; Description = 'What to read.'; Param = 'Topic'; Enum = @(Get-WtAssistantReadTopics) }
            @{ Name = 'filter'; Type = 'string'; Description = 'errors=hours, startup/services=name, processes/wintoolify_changes=count, crashes=dump file.'; Param = 'Filter' }))
        (New-WtAssistantToolRecord -Name 'web_search' -DescriptionKey 'AsDescWebSearch' -Handler 'Get-WtAssistantWebSearch' -Tier 'net' -SkipIpMask -MaskArgs @('query') -Required @('query') -Parameters @(
            @{ Name = 'query'; Type = 'string'; Description = 'Search words.'; Param = 'Query' }))
        (New-WtAssistantToolRecord -Name 'fetch_page' -DescriptionKey 'AsDescFetchPage' -Handler 'Get-WtAssistantFetchPage' -Tier 'net' -SkipIpMask -MaxChars 3900 -Required @('url') -Parameters @(
            @{ Name = 'url'; Type = 'string'; Description = 'A web_search result url.'; Param = 'Url' }
            @{ Name = 'offset'; Type = 'integer'; Description = 'Continue from this character (see omitted).'; Param = 'Offset'; Default = 0 }))
        (New-WtAssistantToolRecord -Name 'read_raw' -DescriptionKey 'AsDescReadRaw' -Handler 'Get-WtAssistantRawRead' -Required @('kind', 'path') -Parameters @(
            @{ Name = 'kind'; Type = 'string'; Description = 'registry or file.'; Param = 'Kind'; Enum = @('registry', 'file') }
            @{ Name = 'path'; Type = 'string'; Description = 'Registry path or absolute file path.'; Param = 'Path' }
            @{ Name = 'name'; Type = 'string'; Description = 'Value name; omit to list the key.'; Param = 'Name' }
            @{ Name = 'lines'; Type = 'integer'; Description = 'File lines to read (1-500).'; Param = 'Lines'; Default = 100 }))
        (New-WtAssistantToolRecord -Name 'save_note' -DescriptionKey 'AsDescSaveNote' -Handler 'Invoke-WtAssistantSaveNote' -PassContext -Required @('text') -Parameters @(
            @{ Name = 'text'; Type = 'string'; Description = 'One fact, max 200 characters.'; Param = 'Text' }))
    )
}

function Get-WtAssistantToolRecord {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [AllowNull()][array]$Registry = $null
    )
    $records = if ($null -ne $Registry) { @($Registry) } else { @(Get-WtAssistantToolRegistry) }
    foreach ($record in $records) {
        if ([string]::Equals([string]$record.Name, $Name, [System.StringComparison]::Ordinal)) { return $record }
    }
    return $null
}

function Test-WtAssistantToolDisabled {
    <#
    .SYNOPSIS
        PURE: whether a tool name is on the user's /araclar off-list.
        Ordinal - never -contains on names under tr-TR.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name, [AllowNull()][AllowEmptyCollection()][string[]]$Disabled = @())
    foreach ($d in @($Disabled)) {
        if ([string]::Equals([string]$d, $Name, [System.StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Get-WtAssistantDisabledTools {
    <#
    .SYNOPSIS
        PURE: the tools the model must NOT see - the user's /araclar
        off-list, filtered to names the registry knows.
    #>
    param([AllowNull()][hashtable]$Permissions = $null, [AllowNull()][array]$Registry = $null)
    $records = if ($null -ne $Registry) { @($Registry) } else { @(Get-WtAssistantToolRegistry) }
    $disabled = [string[]]@()
    if ($null -ne $Permissions -and $Permissions.ContainsKey('disabled')) { $disabled = [string[]]@($Permissions.disabled | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
    $off = New-Object System.Collections.Generic.List[string]
    foreach ($record in $records) {
        $name = [string]$record.Name
        if (Test-WtAssistantToolDisabled -Name $name -Disabled $disabled) { $off.Add($name) }
    }
    return [string[]]$off.ToArray()
}

function Get-WtAssistantFunctionSchemas {
    <#
    .SYNOPSIS
        The OpenAI tool declarations, derived from the registry. The
        description comes from the active language's table. -Disabled
        names leave the list entirely: a tool the user switched off with
        /araclar is one the model never hears of.
    #>
    param([AllowNull()][array]$Registry = $null, [AllowNull()][AllowEmptyCollection()][string[]]$Disabled = @())
    $records = if ($null -ne $Registry) { @($Registry) } else { @(Get-WtAssistantToolRegistry) }
    return @(foreach ($record in $records) {
        if (Test-WtAssistantToolDisabled -Name ([string]$record.Name) -Disabled $Disabled) { continue }
        $properties = @{}
        foreach ($p in @($record.Parameters)) {
            $property = @{ type = [string]$p.Type; description = [string]$p.Description }
            if ([string]$p.Type -eq 'array') { $property['items'] = @{ type = 'string' } }
            if ($p.ContainsKey('Enum')) { $property['enum'] = @($p.Enum) }
            if ($p.ContainsKey('Default')) { $property['default'] = $p.Default }
            $properties[[string]$p.Name] = $property
        }
        New-WtAssistantFunctionSchema -Name ([string]$record.Name) -Description ([string](Get-Translation ([string]$record.DescriptionKey))) -Properties $properties -Required ([string[]]@($record.Required))
    })
}
