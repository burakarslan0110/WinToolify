#Requires -Modules Pester

<#
.SYNOPSIS
    The assistant tool registry: one data record per tool, the OpenAI
    schemas and the dispatch derived from it, and the generic argument
    binder. Nothing here is listed twice.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
    $script:Registry = @(Get-WtAssistantToolRegistry)
    $script:Context = @{ Mask = @{ ComputerName = 'BURAK-PC'; UserName = 'Burak'; Serial = ''; Macs = @() }; OnSuggest = { param($Valid) } }
}

Describe 'registry integrity' {
    It 'has unique names, a resolvable handler, a two-language description and a known tier on every record' {
        $names = @($Registry | ForEach-Object Name)
        @($names | Select-Object -Unique).Count | Should -Be $names.Count
        foreach ($record in $Registry) {
            (Get-Command -Name $record.Handler -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty -Because $record.Name
            $script:Translations['EN'][$record.DescriptionKey] | Should -Not -BeNullOrEmpty -Because $record.Name
            $script:Translations['TR'][$record.DescriptionKey] | Should -Not -BeNullOrEmpty -Because $record.Name
            @('read', 'net', 'act') | Should -Contain $record.Tier -Because $record.Name
            foreach ($p in @($record.Parameters)) {
                @('string', 'integer', 'boolean', 'array', 'object') | Should -Contain $p.Type -Because ($record.Name + '/' + $p.Name)
                $p.Param | Should -Not -BeNullOrEmpty -Because ($record.Name + '/' + $p.Name)
                (Get-Command -Name $record.Handler).Parameters.ContainsKey($p.Param) | Should -BeTrue -Because ($record.Name + '/' + $p.Name)
            }
            foreach ($r in @($record.Required)) { @($record.Parameters | ForEach-Object Name) | Should -Contain $r -Because $record.Name }
        }
    }

    It 'carries no act tool and no act tier at all - the model never executes' {
        $names = @(Get-WtAssistantToolRegistry | ForEach-Object Name)
        foreach ($gone in @('run_wintoolify_tool', 'apply_wintoolify', 'undo_wintoolify_change')) { $names | Should -Not -Contain $gone }
        foreach ($record in @(Get-WtAssistantToolRegistry)) { @('read', 'net') | Should -Contain ([string]$record.Tier) }
        { New-WtAssistantToolRecord -Name 'x' -DescriptionKey 'AsDescSearchWintoolify' -Handler 'Get-Date' -Tier 'act' } | Should -Throw
    }

    It 'derives one valid schema per record with the active-language description and the required list' {
        $schemas = @(Get-WtAssistantFunctionSchemas)
        $schemas.Count | Should -Be $Registry.Count
        foreach ($schema in $schemas) {
            $back = ($schema | ConvertTo-Json -Depth 10 -Compress) | ConvertFrom-Json
            $back.type | Should -Be 'function'
            $back.'function'.description | Should -Not -BeNullOrEmpty
            $back.'function'.parameters.type | Should -Be 'object'
            $schema.'function'.parameters.additionalProperties | Should -BeFalse
        }
        $search = @($schemas | Where-Object { $_.'function'.name -eq 'search_wintoolify' })[0]
        @($search.'function'.parameters.required) | Should -Be @('query')
        $suggest = @($schemas | Where-Object { $_.'function'.name -eq 'suggest_wintoolify' })[0]
        $suggest.'function'.parameters.properties.ids.items.type | Should -Be 'string'
    }

    It '-Disabled (the /araclar off-list) drops exactly those tools from the schemas, matched ordinal' {
        $all = @(Get-WtAssistantFunctionSchemas)
        $less = @(Get-WtAssistantFunctionSchemas -Disabled @('web_search', 'fetch_page'))
        $less.Count | Should -Be ($all.Count - 2)
        @($less | ForEach-Object { $_.'function'.name }) | Should -Not -Contain 'web_search'
        @($less | ForEach-Object { $_.'function'.name }) | Should -Not -Contain 'fetch_page'
        @(Get-WtAssistantFunctionSchemas -Disabled @()).Count | Should -Be $all.Count
        (Test-WtAssistantToolDisabled -Name 'web_search' -Disabled @('web_search')) | Should -BeTrue
        (Test-WtAssistantToolDisabled -Name 'WEB_SEARCH' -Disabled @('web_search')) | Should -BeFalse
        (Test-WtAssistantToolDisabled -Name 'x' -Disabled @()) | Should -BeFalse
    }

    It 'the off-list is the only thing that hides a tool: unknown names are ignored, an enabled key is ignored' {
        @(Get-WtAssistantDisabledTools) | Should -BeNullOrEmpty
        $off = @(Get-WtAssistantDisabledTools -Permissions @{ disabled = @('web_search', 'nope'); enabled = @('web_search') })
        $off | Should -Be @('web_search')
    }

    It 'is exactly the seven tools, in order' {
        @(Get-WtAssistantToolRegistry | ForEach-Object Name) | Should -Be @('search_wintoolify', 'suggest_wintoolify', 'read_system', 'web_search', 'fetch_page', 'read_raw', 'save_note')
    }

    It 'search_wintoolify: query required, section is the enum of catalog sections plus Tools/Screens/Winget, detail is a boolean default false, no state' {
        $rec = Get-WtAssistantToolRecord -Name 'search_wintoolify'
        $rec.Required | Should -Be @('query')
        $names = @($rec.Parameters | ForEach-Object Name)
        $names | Should -Be @('query', 'section', 'detail')
        $section = @($rec.Parameters | Where-Object Name -eq 'section')[0]
        $expected = @(@(Get-WtApplySectionCatalog | Where-Object Key -ne 'PerAppPermissions' | ForEach-Object Key) + @('Tools', 'Screens', 'Winget'))
        @($section.Enum) | Should -Be $expected
        @($section.Enum).Count | Should -Be 26
        @($rec.Parameters | Where-Object Name -eq 'detail')[0].Default | Should -BeFalse
    }

    It 'read_system: topic is the twelve-value enum, filter a free string; read_raw: kind enum registry|file, path required, lines default 100' {
        $rs = Get-WtAssistantToolRecord -Name 'read_system'
        $rs.Required | Should -Be @('topic')
        @(@($rs.Parameters | Where-Object Name -eq 'topic')[0].Enum) | Should -Be @(Get-WtAssistantReadTopics)
        $rs.Handler | Should -Be 'Get-WtAssistantSystemRead'
        $rr = Get-WtAssistantToolRecord -Name 'read_raw'
        $rr.Required | Should -Be @('kind', 'path')
        @(@($rr.Parameters | Where-Object Name -eq 'kind')[0].Enum) | Should -Be @('registry', 'file')
        @($rr.Parameters | Where-Object Name -eq 'lines')[0].Default | Should -Be 100
        (Get-WtAssistantToolRecord -Name 'web_search').Parameters.Count | Should -Be 1
        (Get-WtAssistantToolRecord -Name 'web_search').Tier | Should -Be 'net'
        (Get-WtAssistantToolRecord -Name 'fetch_page').Tier | Should -Be 'net'
        (Get-WtAssistantToolRecord -Name 'fetch_page').Parameters.Count | Should -Be 2
        (Get-WtAssistantToolRecord -Name 'fetch_page').MaxChars | Should -Be 3900
        $fetchSchema = @(Get-WtAssistantFunctionSchemas) | Where-Object { $_.function.name -eq 'fetch_page' }
        $fetchSchema.function.parameters.properties.offset.type | Should -Be 'integer'
        $fetchSchema.function.parameters.properties.offset.default | Should -Be 0
        @($fetchSchema.function.parameters.required) | Should -Be @('url')
    }

    It 'schemas: additionalProperties false, defaults carried, and the whole array stays under 4000 chars in BOTH languages with every description under 320' {
        foreach ($lang in @('TR', 'EN')) {
            $saved = $script:Language
            $script:Language = $lang
            try {
                $schemas = @(Get-WtAssistantFunctionSchemas)
                $schemas.Count | Should -Be 7
                foreach ($s in $schemas) {
                    $s.function.parameters.additionalProperties | Should -BeFalse
                    ([string]$s.function.description).Length | Should -BeLessOrEqual 320 -Because $s.function.name
                    ([string]$s.function.description) | Should -Not -Match 'apply_wintoolify|run_wintoolify_tool|undo_wintoolify_change|get_machine_profile'
                }
                $json = ($schemas | ConvertTo-Json -Depth 10 -Compress)
                $json.Length | Should -BeLessOrEqual 4000 -Because $lang
                $lines = @($schemas | Where-Object { $_.function.name -eq 'read_raw' })[0].function.parameters.properties.lines
                $lines.default | Should -Be 100
            }
            finally { $script:Language = $saved }
        }
    }

    It 'sibling tools say what they are NOT for, by naming the sibling' {
        foreach ($lang in @('TR', 'EN')) {
            $t = $script:Translations[$lang]
            [string]$t['AsDescSearchWintoolify'] | Should -Match 'read_system'
            [string]$t['AsDescReadSystem'] | Should -Match 'search_wintoolify'
            [string]$t['AsDescWebSearch'] | Should -Match 'WinToolify'
            [string]$t['AsDescFetchPage'] | Should -Match 'web_search'
            [string]$t['AsDescSuggestWintoolify'] | Should -Match 'search_wintoolify'
        }
    }

}

Describe 'ConvertTo-WtAssistantHandlerArgs' {
    BeforeAll {
        function Test-WtBinderProbe { param([int]$Hours, [bool]$RunTests, [string[]]$Ids, [hashtable]$Targets, [string]$Query, $Context) }
        $script:Record = New-WtAssistantToolRecord -Name 'probe' -DescriptionKey 'AsDescGetSystemOverview' -Handler 'Test-WtBinderProbe' -PassContext -MaskArgs @('query') -Parameters @(
            @{ Name = 'hours'; Type = 'integer'; Description = 'h'; Param = 'Hours' }
            @{ Name = 'run_tests'; Type = 'boolean'; Description = 'b'; Param = 'RunTests' }
            @{ Name = 'ids'; Type = 'array'; Description = 'a'; Param = 'Ids' }
            @{ Name = 'targets'; Type = 'object'; Description = 'o'; Param = 'Targets' }
            @{ Name = 'query'; Type = 'string'; Description = 's'; Param = 'Query' }
        )
    }

    It 'binds by schema type: stringified booleans through ConvertTo-WtAssistantBool, arrays to string[], objects to hashtable' {
        $toolArgs = '{"hours":"24","run_tests":"false","ids":["a","b"],"targets":{"Services:X":"Manual"},"query":"my pc BURAK-PC"}' | ConvertFrom-Json
        $bound = ConvertTo-WtAssistantHandlerArgs -Record $Record -ToolArgs $toolArgs -Context $Context
        $bound.Hours | Should -Be 24
        $bound.RunTests | Should -BeFalse
        $bound.Ids | Should -Be @('a', 'b')
        $bound.Targets['Services:X'] | Should -Be 'Manual'
        $bound.Query | Should -Match '<pc>'
        $bound.Context | Should -Be $Context
    }

    It 'leaves absent and unknown properties out so handler defaults apply' {
        $bound = ConvertTo-WtAssistantHandlerArgs -Record $Record -ToolArgs ('{"nope":1}' | ConvertFrom-Json) -Context $Context
        $bound.ContainsKey('Hours') | Should -BeFalse
        $bound.ContainsKey('nope') | Should -BeFalse
        (ConvertTo-WtAssistantHandlerArgs -Record $Record -ToolArgs $null -Context $Context).Keys | Should -Be @('Context')
    }
}

Describe 'Invoke-WtAssistantToolCall (registry-driven)' {
    BeforeAll {
        function Get-WtProbeRecordResult { param([string]$Word = 'x', [int]$Top = 1, [string]$Mode = 'a') return [ordered]@{ word = $Word; top = $Top; mode = $Mode; machine = $env:COMPUTERNAME } }
        function Get-WtProbeThrows { throw 'kaboom' }
        function Get-WtProbeBig { return @{ rows = @(1..400 | ForEach-Object { [PSCustomObject]@{ n = $_; text = ('row ' + $_ + ' padding padding padding') } }) } }
        $script:ProbeRegistry = @(
            (New-WtAssistantToolRecord -Name 'probe' -DescriptionKey 'AsDescSearchWintoolify' -Handler 'Get-WtProbeRecordResult' -Required @('word') -Parameters @(
                @{ Name = 'word'; Type = 'string'; Description = 'w'; Param = 'Word' }
                @{ Name = 'top'; Type = 'integer'; Description = 't'; Param = 'Top' }
                @{ Name = 'mode'; Type = 'string'; Description = 'm'; Param = 'Mode'; Enum = @('a', 'b') }))
            (New-WtAssistantToolRecord -Name 'boom' -DescriptionKey 'AsDescSearchWintoolify' -Handler 'Get-WtProbeThrows')
            (New-WtAssistantToolRecord -Name 'big' -DescriptionKey 'AsDescSearchWintoolify' -Handler 'Get-WtProbeBig' -MaxChars 700 -Hint 'narrow it')
        )
        $script:Ctx = @{ Mask = @{ ComputerName = $env:COMPUTERNAME; UserName = 'zz-nobody'; Serial = ''; Macs = @() } }
    }

    It 'refuses a tool the user switched off with /araclar even when the model still names it' {
        $ctx = @{ Mask = $Ctx.Mask; Disabled = @('probe') }
        $r = Invoke-WtAssistantToolCall -Name 'probe' -ArgumentsJson '{"word":"x"}' -Context $ctx -Registry $ProbeRegistry
        @($r -split "`n")[0] | Should -Be 'error: tool disabled by the user: probe'
        @($r -split "`n")[1] | Should -Be 'hint: do not call it again in this conversation'
    }

    It 'answers an unknown name as a one-line error' {
        Invoke-WtAssistantToolCall -Name 'nope' -ArgumentsJson '{}' -Context $Ctx -Registry $ProbeRegistry | Should -Be 'error: unknown tool: nope'
    }

    It 'runs a record handler, serializes its OBJECT result as text and masks it' {
        $r = Invoke-WtAssistantToolCall -Name 'probe' -ArgumentsJson '{"word":"hello","top":"7","mode":"b"}' -Context $Ctx -Registry $ProbeRegistry
        $lines = @($r -split "`n")
        $lines | Should -Contain 'word: hello'
        $lines | Should -Contain 'top: 7'
        $lines | Should -Contain 'mode: b'
        $lines | Should -Contain 'machine: <pc>'
        $r | Should -Not -Match '[{}"]'
    }

    It 'broken argument JSON is an error, never "no arguments"' {
        $r = Invoke-WtAssistantToolCall -Name 'probe' -ArgumentsJson '{"word":' -Context $Ctx -Registry $ProbeRegistry
        @($r -split "`n")[0] | Should -Be 'error: arguments are not valid JSON'
    }

    It 'a missing required argument is named; the handler never runs' {
        $r = Invoke-WtAssistantToolCall -Name 'probe' -ArgumentsJson '{"top":3}' -Context $Ctx -Registry $ProbeRegistry
        $r | Should -Be 'error: missing required argument: word'
    }

    It 'a required argument sent as JSON null, or as a whitespace-only string, counts as missing - never a mandatory-parameter prompt' {
        function Test-WtProbeMustNotRun { param([string]$Word) throw 'the handler must never run for a null/blank required argument' }
        $reg = @((New-WtAssistantToolRecord -Name 'nullprobe' -DescriptionKey 'AsDescSearchWintoolify' -Handler 'Test-WtProbeMustNotRun' -Required @('word') -Parameters @(
            @{ Name = 'word'; Type = 'string'; Description = 'w'; Param = 'Word' })))
        (Invoke-WtAssistantToolCall -Name 'nullprobe' -ArgumentsJson '{"word":null}' -Context $Ctx -Registry $reg) | Should -Be 'error: missing required argument: word'
        (Invoke-WtAssistantToolCall -Name 'nullprobe' -ArgumentsJson '{"word":"   "}' -Context $Ctx -Registry $reg) | Should -Be 'error: missing required argument: word'
    }

    It 'a bad type and an out-of-enum value name the argument and what was expected' {
        (Invoke-WtAssistantToolCall -Name 'probe' -ArgumentsJson '{"word":"x","top":"abc"}' -Context $Ctx -Registry $ProbeRegistry) | Should -Be 'error: argument top must be an integer (got "abc")'
        (Invoke-WtAssistantToolCall -Name 'probe' -ArgumentsJson '{"word":"x","mode":"zzz"}' -Context $Ctx -Registry $ProbeRegistry) | Should -Be 'error: argument mode must be one of: a, b'
    }

    It 'a throwing handler becomes a masked error with its detail, never an exception' {
        $r = Invoke-WtAssistantToolCall -Name 'boom' -ArgumentsJson '{}' -Context $Ctx -Registry $ProbeRegistry
        @($r -split "`n")[0] | Should -Be 'error: tool failed: boom'
        @($r -split "`n")[1] | Should -Match '^detail: kaboom'
    }

    It 'trims to the record MaxChars at a row boundary and appends omitted and the record hint' {
        $r = Invoke-WtAssistantToolCall -Name 'big' -ArgumentsJson '{}' -Context $Ctx -Registry $ProbeRegistry
        $r.Length | Should -BeLessOrEqual 700
        $lines = @($r -split "`n")
        $lines[-1] | Should -Be 'hint: narrow it'
        $lines[-2] | Should -Match '^omitted: \d+ lines$'
        $lines[1] | Should -Be '  n | text'
    }

    It 'a handler-stamped _max_chars overrides the record MaxChars for that call, and never reaches the model as text' {
        function Get-WtProbeTopicCeiling {
            $rows = @(1..60 | ForEach-Object { [PSCustomObject]@{ n = $_; text = ('row ' + $_ + ' padding padding') } })
            return [ordered]@{ _max_chars = 200; rows = $rows }
        }
        $reg = @((New-WtAssistantToolRecord -Name 'ceiling' -DescriptionKey 'AsDescSearchWintoolify' -Handler 'Get-WtProbeTopicCeiling' -MaxChars 5000 -Hint 'narrow it'))
        $r = Invoke-WtAssistantToolCall -Name 'ceiling' -ArgumentsJson '{}' -Context $Ctx -Registry $reg
        $r.Length | Should -BeLessOrEqual 200
        $lines = @($r -split "`n")
        $lines[-2] | Should -Match '^omitted: \d+ lines$'
        $r | Should -Not -Match '_max_chars'
    }

    It 'skips the IP mask for records that say so' {
        function Get-WtProbeIp { return @{ ip = '93.184.216.34' } }
        $reg = @((New-WtAssistantToolRecord -Name 'ipy' -DescriptionKey 'AsDescSearchWintoolify' -Handler 'Get-WtProbeIp' -SkipIpMask), (New-WtAssistantToolRecord -Name 'ipn' -DescriptionKey 'AsDescSearchWintoolify' -Handler 'Get-WtProbeIp'))
        (Invoke-WtAssistantToolCall -Name 'ipy' -ArgumentsJson '{}' -Context $Ctx -Registry $reg) | Should -Be 'ip: 93.184.216.34'
        (Invoke-WtAssistantToolCall -Name 'ipn' -ArgumentsJson '{}' -Context $Ctx -Registry $reg) | Should -Be 'ip: <ip>'
    }

    It 'suggest_wintoolify hands the valid entries to the OnSuggest sink and reports invalid ids' {
        $script:Sunk = $null
        $ctx = @{ Mask = $Ctx.Mask; OnSuggest = { param($Valid) $script:Sunk = @($Valid) } }
        $r = Invoke-WtAssistantToolCall -Name 'suggest_wintoolify' -ArgumentsJson '{"ids":["Services:DiagTrack","Nope:X"]}' -Context $ctx
        @($Sunk).Count | Should -Be 1
        @($r -split "`n")[0] | Should -Be '1: Services:DiagTrack'
        $r | Should -Match '(?m)^invalid: Nope:X$'
    }

    It 'web_search masks the OUTBOUND query (identity, not IPs) before the handler sees it' {
        $script:Seen = ''
        function Get-WtAssistantWebSearch { param([string]$Query) $script:Seen = $Query; return @{ results = @() } }
        $ctx = @{ Mask = @{ ComputerName = 'MYBOX'; UserName = 'zz-nobody'; Serial = ''; Macs = @() } }
        $null = Invoke-WtAssistantToolCall -Name 'web_search' -ArgumentsJson '{"query":"MYBOX cannot reach 93.184.216.34"}' -Context $ctx
        $Seen | Should -Be '<pc> cannot reach 93.184.216.34'
    }
}
