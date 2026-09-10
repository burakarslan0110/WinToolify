#Requires -Modules Pester

<#
.SYNOPSIS
    The assistant screen's testable edges: main-menu registration, the
    remote-endpoint predicate, the status text, the system prompt, the
    dispatch table, the privacy gate, runnable suggestions and the agent
    send path with an injected turn. The interactive loop is UI.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'registration' {
    It 'sits on the main menu in its own titled block, just above Exit' {
        $names = @(Get-WtMainMenuItems | Where-Object { Test-WtItemFocusable -Item $_ } | ForEach-Object Name)
        $names[-2] | Should -Be 'Assistant'
        $names[-1] | Should -Be 'Exit'
        $all = @(Get-WtMainMenuItems | ForEach-Object Name)
        @(Get-WtMainMenuItems | Where-Object Kind -eq 'Rule' | ForEach-Object Name) | Should -Be @('MainToolsRule', 'MainAssistantRule')
        [array]::IndexOf($all, 'Assistant') | Should -Be ([array]::IndexOf($all, 'MainAssistantRule') + 1)
        $item = @(Get-WtMainMenuItems) | Where-Object Name -eq 'Assistant'
        $item.Data.Screen | Should -Be 'Assistant'
    }

    It 'the main menu has no settings row any more - settings open from /ayarlar inside the assistant' {
        @(Get-WtMainMenuItems | ForEach-Object Name) | Should -Not -Contain 'AssistantSettings'
        $script:Translations['EN'].ContainsKey('AsSettingsMenuLabel') | Should -BeFalse
        (Get-Command Invoke-WtScreenByKey).Definition | Should -Not -Match "'AssistantSettings'"
    }

    It 'has a case in the screen registry for the chat' {
        $src = (Get-Command Invoke-WtScreenByKey).Definition
        $src | Should -Match "'Assistant' \{ return Invoke-WtAssistantScreen \}"
    }

    It 'labels the row and the part-1 strings in both languages' {
        foreach ($lang in 'EN', 'TR') {
            foreach ($key in 'Assistant',
                'AsSuggestionsHeading', 'AsScanning', 'AsAutoSelected', 'AsLocalTag', 'AsRemoteTag',
                'AsProbingTools') {
                $script:Translations[$lang][$key] | Should -Not -BeNullOrEmpty -Because "$lang/$key"
            }
        }
    }
}

Describe 'Test-WtAssistantRemoteEndpoint' {
    It 'treats loopback as local and anything else as remote' {
        Test-WtAssistantRemoteEndpoint -Endpoint 'http://localhost:1234/v1' | Should -BeFalse
        Test-WtAssistantRemoteEndpoint -Endpoint 'http://127.0.0.1:11434/v1' | Should -BeFalse
        Test-WtAssistantRemoteEndpoint -Endpoint 'http://[::1]:8080/v1' | Should -BeFalse
        Test-WtAssistantRemoteEndpoint -Endpoint 'https://api.openai.com/v1' | Should -BeTrue
        Test-WtAssistantRemoteEndpoint -Endpoint 'http://192.168.1.20:1234/v1' | Should -BeTrue
        Test-WtAssistantRemoteEndpoint -Endpoint '' | Should -BeFalse
    }
}

Describe 'Get-WtAssistantSystemPrompt (v3: static, suggest-only, under 2700 chars)' {
    BeforeAll { $script:Prompt = Get-WtAssistantSystemPrompt }

    It 'is static: no date, no reply language, no slash help table, and the same bytes twice' {
        $Prompt.Length | Should -BeLessOrEqual 2700
        $Prompt | Should -Not -Match 'Today is'
        $Prompt | Should -Not -Match '\d{4}-\d{2}-\d{2}'
        $Prompt | Should -Not -Match 'Answer in (Turkish|English)'
        $Prompt | Should -Not -Match '/kopyala|/kaydet|/durum'
        $Prompt | Should -Not -Match 'Burak Arslan|github\.com'
        (Get-WtAssistantSystemPrompt) | Should -Be $Prompt
    }

    It 'suggest-only: never runs anything, searches then suggests, points to the numbers, explains manual fixes when nothing fits' {
        $Prompt | Should -Match 'never run, apply, remove or undo anything'
        $Prompt | Should -Match 'search_wintoolify'
        $Prompt | Should -Match 'suggest_wintoolify'
        $Prompt | Should -Match 'types a number'
        $Prompt | Should -Match 'CONFIRM or YES'
        $Prompt | Should -Match 'manual fix'
        $Prompt | Should -Not -Match 'I can apply this for you'
        $Prompt | Should -Not -Match 'verify after acting'
        $Prompt | Should -Not -Match 'apply_wintoolify|run_wintoolify_tool|undo_wintoolify_change|suggest_wintoolify_tools'
    }

    It 'keeps the scope guardrail, the identity rule, the terminal format rule and the five slash names' {
        $Prompt | Should -Match 'WinToolify Asistan'
        $Prompt | Should -Match 'Decline anything else in one short sentence'
        $Prompt | Should -Match 'never name a model vendor'
        $Prompt | Should -Match 'terminal'
        $Prompt | Should -Match 'no headings or tables'
        foreach ($cmd in @('/ayarlar', '/yeni', '/profil', '/notlar', '/unut', '/yardim')) { $Prompt | Should -Match ([regex]::Escape($cmd)) }
    }

    It 'says the tool rules once and leaves the per-tool routing to the descriptions' {
        $Prompt | Should -Match 'follow each tool description'
        $Prompt | Should -Match 'never call a tool whose result you will not use'
        $Prompt | Should -Not -Match 'get_wintoolify_status|get_machine_profile|at most two searches'
    }

    It 'report-turn rules: interpret every result, the (note: / (result of message, numbers only through suggest, research when unsure' {
        $Prompt | Should -Match 'never paste raw lines'
        $Prompt | Should -Match '"\(note:" or "\(result of"'
        $Prompt | Should -Match "If the user's own words follow, answer those"
        $Prompt | Should -Match 'Never claim you did it'
        $Prompt | Should -Match 'the numbers on screen stay valid'
        $Prompt | Should -Match 'or a number that matched nothing'
        $Prompt | Should -Match 'numbered lists exist only through suggest_wintoolify'
        $Prompt | Should -Match 'research with web_search and fetch_page'
        $Prompt | Should -Not -Match 'use web_search only for facts you do not have'
        $Prompt | Should -Not -Match 'at most one level'
    }
}

Describe 'Get-WtAssistantSystemExtra / Get-WtAssistantSessionExtra (system[1], frozen per session)' {
    It 'renders date, reply language, the profile line and the notes, in that order' {
        $extra = Get-WtAssistantSystemExtra -Date ([datetime]'2026-09-05') -Language 'TR' -ProfileJson '{"a":1}' -Notes @(@{ text = 'likes dark mode' })
        $lines = @($extra -split "`n")
        $lines[0] | Should -Be 'date: 2026-09-05'
        $lines[1] | Should -Be 'reply language: Turkish'
        $lines[2] | Should -Be 'machine profile (anonymized): {"a":1}'
        $lines[3] | Should -Be 'notes the user asked you to remember:'
        $lines[4] | Should -Be '- likes dark mode'
        $en = Get-WtAssistantSystemExtra -Date ([datetime]'2026-09-05') -Language 'EN'
        @($en -split "`n") | Should -Be @('date: 2026-09-05', 'reply language: English')
    }

    It 'builds once per session, serves the same bytes afterwards even when the profile seam changes, and rebuilds after a reset' {
        $chat = New-WtReplSession
        $script:Profile = '{"v":1}'
        $a = Get-WtAssistantSessionExtra -Chat $chat -GetProfile { $script:Profile } -GetNotes { @() } -Mask @{ ComputerName = 'X'; UserName = 'zz'; Serial = ''; Macs = @() } -Date ([datetime]'2026-09-05') -Language 'EN'
        $script:Profile = '{"v":2}'
        $b = Get-WtAssistantSessionExtra -Chat $chat -GetProfile { $script:Profile } -GetNotes { @() } -Mask @{ ComputerName = 'X'; UserName = 'zz'; Serial = ''; Macs = @() } -Date ([datetime]'2026-09-06') -Language 'TR'
        $b | Should -Be $a
        $a | Should -Match '"v":1'
        Reset-WtAssistantSessionExtra -Chat $chat
        $c = Get-WtAssistantSessionExtra -Chat $chat -GetProfile { $script:Profile } -GetNotes { @() } -Mask @{ ComputerName = 'X'; UserName = 'zz'; Serial = ''; Macs = @() } -Date ([datetime]'2026-09-06') -Language 'TR'
        $c | Should -Match '"v":2'
        $c | Should -Match 'reply language: Turkish'
    }
}

Describe 'Invoke-WtAssistantSend (agent wiring)' {
    It 'appends user and the final answer around the turn seam - and nothing after the answer (no per-turn summary footer)' {
        $chat = New-WtReplSession
        $settings = [PSCustomObject]@{ AssistantEndpoint = 'http://localhost:1234/v1'; AssistantModel = 'm'; AssistantApiKey = '' }
        Invoke-WtAssistantSend -Chat $chat -Settings $settings -Text 'soru' -Breadcrumb 'x' -GetProfile { param($S) '' } -GetNotes { @() } `
            -Turn { param($ArgTable) @{ Ok = $true; FinalText = 'cevap'; ErrorText = ''; Cancelled = $false; Rounds = 1 } }
        @($chat.Entries | ForEach-Object Kind) | Should -Be @('User', 'Assistant')
    }

    It 'sends the registry tools minus the /araclar off-list and never an act tool, whatever permissions say' {
        $script:SentSchemas = $null
        $chat = New-WtReplSession
        Invoke-WtAssistantSend -Chat $chat -Settings ([PSCustomObject]@{ AssistantEndpoint = 'http://localhost:1234/v1'; AssistantModel = 'm'; AssistantApiKey = '' }) -Text 'q' -Breadcrumb '' `
            -Turn { param($ArgTable) $script:SentSchemas = @($ArgTable.Schemas); @{ Ok = $true; FinalText = 'x'; ErrorText = ''; Cancelled = $false; Rounds = 1; Dropped = 0 } } `
            -ReadPermissions { @{ v = 1; endpoints = @(); disabled = @('web_search'); enabled = @('apply_wintoolify') } } -Write { param($S) }
        $names = @($SentSchemas | ForEach-Object { [string]$_.function.name })
        $names | Should -Not -Contain 'web_search'
        $names | Should -Not -Contain 'apply_wintoolify'
        $names | Should -Contain 'search_wintoolify'
    }

    It 'reports a failed turn as an error entry' {
        $chat = New-WtReplSession
        $settings = [PSCustomObject]@{ AssistantEndpoint = 'http://localhost:1234/v1'; AssistantModel = 'm'; AssistantApiKey = '' }
        Invoke-WtAssistantSend -Chat $chat -Settings $settings -Text 'soru' -Breadcrumb 'x' -GetProfile { param($S) '' } -GetNotes { @() } `
            -Turn { param($ArgTable) @{ Ok = $false; FinalText = ''; ErrorText = 'kotu'; Cancelled = $false; Rounds = 1 } }
        ($chat.Entries.ToArray() | Select-Object -Last 1).Kind | Should -Be 'Error'
    }

    It 'the default -GetProfile passes -OnCold, so a mid-turn cold rebuild announces itself before the turn runs' {
        $chat = New-WtReplSession
        $settings = [PSCustomObject]@{ AssistantEndpoint = 'http://localhost:1234/v1'; AssistantModel = 'm'; AssistantApiKey = '' }
        $script:Order = New-Object System.Collections.Generic.List[string]
        Mock Get-WtAssistantMachineProfile { if ($null -ne $OnCold) { & $OnCold }; @{ Json = '{}'; Cold = $true; BuiltAt = '' } }
        Mock Write-WtReplLine { $script:Order.Add('write:' + [string]$Text) }
        Invoke-WtAssistantSend -Chat $chat -Settings $settings -Text 'soru' -Breadcrumb 'x' -GetNotes { @() } `
            -Turn { param($ArgTable) $script:Order.Add('turn'); @{ Ok = $true; FinalText = 'cevap'; ErrorText = ''; Cancelled = $false; Rounds = 1 } }
        Should -Invoke Get-WtAssistantMachineProfile -Times 1
        $buildIdx = [array]::IndexOf(@($script:Order), 'write:  ' + (Get-Translation 'AsProfileBuilding'))
        $turnIdx = [array]::IndexOf(@($script:Order), 'turn')
        $buildIdx | Should -BeGreaterOrEqual 0
        $turnIdx | Should -BeGreaterThan $buildIdx
    }

    It 'a declined privacy gate adds a visible Info entry and never reaches the turn seam' {
        $chat = New-WtReplSession
        $settings = [PSCustomObject]@{ AssistantEndpoint = 'https://api.openai.com/v1'; AssistantModel = 'm'; AssistantApiKey = '' }
        Mock Invoke-WtAssistantPrivacyGate { $false }
        Invoke-WtAssistantSend -Chat $chat -Settings $settings -Text 'soru' -Breadcrumb 'x' -GetProfile { param($S) '' } -GetNotes { @() } `
            -Turn { param($ArgTable) throw 'must not reach the agent turn' }
        @($chat.Entries | ForEach-Object Kind) | Should -Be @('Info')
        $chat.Entries.ToArray()[0].Text | Should -Be (Get-Translation 'AsPrivacyDeclined')
        $chat.Messages.ToArray().Count | Should -Be 0
    }
}

Describe 'assistant settings' {
    It 'offers the six preset endpoints' {
        $presets = @(Get-WtLlmPresets)
        @($presets | ForEach-Object Name) | Should -Be @('OpenAI', 'OpenRouter', 'Groq', 'LM Studio', 'Ollama', 'llama.cpp')
        $presets[0].Endpoint | Should -Be 'https://api.openai.com/v1'
        $presets[4].Endpoint | Should -Be 'http://127.0.0.1:11434/v1'
    }

    It 'shows current values and masks the key' {
        $s = [PSCustomObject]@{ AssistantEndpoint = 'http://x/v1'; AssistantModel = 'qwen'; AssistantApiKey = 'BLOB' }
        $rows = @(Get-WtAssistantSettingsRows -Settings $s)
        @($rows | ForEach-Object Name) | Should -Be @('AsSetAuthMode', 'AsSetPreset', 'AsSetEndpoint', 'AsSetApiKey', 'AsSetModel', 'AsScanLocal', 'AsTestConnection', 'AsSetNumCtx')
        ($rows | Where-Object Name -eq 'AsSetEndpoint').StateLabel | Should -Be 'http://x/v1'
        ($rows | Where-Object Name -eq 'AsSetApiKey').StateLabel | Should -Be '****'
        $empty = [PSCustomObject]@{ AssistantEndpoint = ''; AssistantModel = ''; AssistantApiKey = '' }
        (@(Get-WtAssistantSettingsRows -Settings $empty) | Where-Object Name -eq 'AsSetModel').StateLabel | Should -Be (Get-Translation 'AsNotSet')
        (@(Get-WtAssistantSettingsRows -Settings $empty) | Where-Object Name -eq 'AsSetNumCtx').StateLabel | Should -Be (Get-Translation 'AsNotSet')
        $ctx = [PSCustomObject]@{ AssistantEndpoint = 'http://x/v1'; AssistantModel = 'qwen'; AssistantApiKey = ''; AssistantNumCtx = '8192' }
        (@(Get-WtAssistantSettingsRows -Settings $ctx) | Where-Object Name -eq 'AsSetNumCtx').StateLabel | Should -Be '8192'
    }

    It 'numbered picker returns the chosen option and empty on nonsense' {
        Invoke-WtAssistantPickFromList -Breadcrumb 'x' -Title 't' -Options @('a', 'b', 'c') -ReadAnswer { param($Lines, $Prompt) '2' } | Should -Be 'b'
        Invoke-WtAssistantPickFromList -Breadcrumb 'x' -Title 't' -Options @('a', 'b') -ReadAnswer { param($Lines, $Prompt) '9' } | Should -Be ''
        Invoke-WtAssistantPickFromList -Breadcrumb 'x' -Title 't' -Options @('a', 'b') -ReadAnswer { param($Lines, $Prompt) '' } | Should -Be ''
    }

    It 'connection test verdicts: reachable + tools answered / tools missing / plain failure' {
        $s = [PSCustomObject]@{ AssistantEndpoint = 'http://x/v1'; AssistantModel = 'm'; AssistantApiKey = '' }
        $okChat = { param($ArgTable) @{ Ok = $true; Content = ''; ToolCalls = @([PSCustomObject]@{ Id = 'c'; Name = 'probe_ping'; Arguments = '{}' }); FinishReason = 'tool_calls'; ErrorKind = ''; ErrorText = ''; Cancelled = $false } }
        $lines = @(Invoke-WtAssistantConnectionTest -Settings $s -Chat $okChat)
        $lines[0] | Should -Be (Get-Translation 'AsTestReachable')
        $lines[1] | Should -Be (Get-Translation 'AsTestToolsOk')
        $noTools = { param($ArgTable) @{ Ok = $true; Content = 'merhaba'; ToolCalls = @(); FinishReason = 'stop'; ErrorKind = ''; ErrorText = ''; Cancelled = $false } }
        (@(Invoke-WtAssistantConnectionTest -Settings $s -Chat $noTools))[1] | Should -Be (Get-Translation 'AsTestToolsMissing')
        $fail = { param($ArgTable) @{ Ok = $false; Content = ''; ToolCalls = @(); FinishReason = ''; ErrorKind = 'Auth'; ErrorText = 'anahtar yok'; Cancelled = $false } }
        (@(Invoke-WtAssistantConnectionTest -Settings $s -Chat $fail))[0] | Should -Be 'anahtar yok'
    }
}

Describe 'Invoke-WtAssistantChooseServer (one picker, two callers)' {
    BeforeAll {
        $script:ChooseServers = @(
            [PSCustomObject]@{ Provider = 'LM Studio'; Endpoint = 'http://localhost:1234/v1'; Models = @('a', 'b') }
            [PSCustomObject]@{ Provider = 'Ollama'; Endpoint = 'http://localhost:11434/v1'; Models = @('qwen', 'llama') }
        )
    }

    It 'saves the picked endpoint and model together' {
        Mock Save-WtSettings { $script:chosen = $Settings }
        Mock Invoke-WtAssistantPickFromList {
            if ($Title -eq (Get-Translation 'AsScanPickServer')) { return @($Options)[0] }
            return @($Options)[1]
        }
        Invoke-WtAssistantChooseServer -Breadcrumb 'x' -Servers $ChooseServers | Should -BeTrue
        $script:chosen.AssistantEndpoint | Should -Be 'http://localhost:1234/v1'
        $script:chosen.AssistantModel | Should -Be 'b'
    }

    It 'saves nothing when the server picker is left empty' {
        Mock Save-WtSettings { throw 'must not save' }
        Mock Invoke-WtAssistantPickFromList { '' }
        Invoke-WtAssistantChooseServer -Breadcrumb 'x' -Servers $ChooseServers | Should -BeFalse
    }

    It 'never falls back to the LAST server when the pick does not resolve' {
        Mock Save-WtSettings { throw 'must not save' }
        Mock Invoke-WtAssistantPickFromList { 'a server nobody offered' }
        Invoke-WtAssistantChooseServer -Breadcrumb 'x' -Servers $ChooseServers | Should -BeFalse
    }

    It 'saves nothing when a model is offered but not picked' {
        Mock Save-WtSettings { throw 'must not save' }
        Mock Invoke-WtAssistantPickFromList {
            if ($Title -eq (Get-Translation 'AsScanPickServer')) { return @($Options)[0] }
            return ''
        }
        Invoke-WtAssistantChooseServer -Breadcrumb 'x' -Servers $ChooseServers | Should -BeFalse
    }

    It 'says what it is doing before the slow Ollama tool-capability probe' {
        Mock Show-WtPanelMessage { $script:probePanel = @($Lines); @{ Width = 100; Height = 40; FooterRow = 38; FooterCol = 2 } }
        Mock Get-WtOllamaToolCapableModels { [string[]]@('qwen') }
        Mock Save-WtSettings { $script:chosen = $Settings }
        Mock Invoke-WtAssistantPickFromList { @($Options)[1] }
        Invoke-WtAssistantChooseServer -Breadcrumb 'x' -Servers $ChooseServers | Should -BeTrue
        @($script:probePanel) | Should -Contain (Get-Translation 'AsProbingTools')
        Should -Invoke Get-WtOllamaToolCapableModels -Times 1 -Exactly
        $script:chosen.AssistantModel | Should -Be 'qwen'
    }

    It 'asks nothing for an empty scan' {
        Mock Invoke-WtAssistantPickFromList { throw 'must not ask' }
        Invoke-WtAssistantChooseServer -Breadcrumb 'x' -Servers @() | Should -BeFalse
    }

    It 'is the one implementation both the Scan row and the startup path run' {
        (Get-Command Invoke-WtAssistantSettingsScreen).Definition | Should -Match 'Invoke-WtAssistantChooseServer'
    }
}

Describe 'settings screen: the API key row' {
    BeforeEach {
        $script:apiRow = @{
            Emit = 'Activate'; Char = ''; Selection = $null; CursorIndex = 0
            Item = (New-WtListItem -Kind 'Action' -Name 'AsSetApiKey' -Label 'k' -Data @{ Setting = 'ApiKey' })
        }
        $script:listCalls = 0
        Mock Read-WtSettings { [PSCustomObject]@{ Language = 'EN'; AssistantEndpoint = 'http://x/v1'; AssistantModel = 'm'; AssistantApiKey = 'BLOB' } }
        Mock Invoke-WtListScreen {
            $script:listCalls++
            if ($script:listCalls -eq 1) { return $script:apiRow }
            return @{ Emit = 'Back'; Char = ''; Item = $null; Selection = $null; CursorIndex = 0 }
        }
    }

    It 'treats a cancelled / exhausted prompt as "change nothing"' {
        Mock Read-WtPanelAnswer { $null }
        Mock Save-WtSettings { }
        (Invoke-WtAssistantSettingsScreen).Nav | Should -Be 'Back'
        Should -Invoke Save-WtSettings -Times 0 -Exactly
    }

    It 'still clears the key on an empty answer - the documented way to do it' {
        Mock Read-WtPanelAnswer { '' }
        Mock Save-WtSettings { $script:keySaved = $Settings }
        Invoke-WtAssistantSettingsScreen | Out-Null
        Should -Invoke Save-WtSettings -Times 1 -Exactly
        [string]$script:keySaved.AssistantApiKey | Should -Be ''
    }

    It 'stores what was typed, protected, never in the clear' {
        Mock Read-WtPanelAnswer { '  sk-secret  ' }
        Mock Save-WtSettings { $script:keySaved = $Settings }
        Invoke-WtAssistantSettingsScreen | Out-Null
        [string]$script:keySaved.AssistantApiKey | Should -Not -Be 'sk-secret'
        (Unprotect-WtAssistantSecret -Blob ([string]$script:keySaved.AssistantApiKey)) | Should -Be 'sk-secret'
    }

    It 'asks for the key through the masked -Secret path, never a clear-text echo' {
        Mock Read-WtPanelAnswer { $script:keyAskedSecret = [bool]$Secret; $null }
        Mock Save-WtSettings { }
        Invoke-WtAssistantSettingsScreen | Out-Null
        $script:keyAskedSecret | Should -BeTrue
    }
}

Describe 'dispatch (registry-driven, wired by the screen)' {
    BeforeAll { $script:Ctx = @{ Mask = @{ ComputerName = 'BURAK-PC'; UserName = 'Burak'; Serial = ''; Macs = @() }; OnSuggest = { param($Valid) }; Breadcrumb = ''; ReadAnswer = { param($Lines, $Prompt, $Risk) '' } } }

    It 'reads run_tests through ConvertTo-WtAssistantBool, so a stringified "false" does NOT probe the network' {
        function Get-WtNetProbe { param([bool]$RunTests = $false) [PSCustomObject]@{ ran = $RunTests } }
        $registry = @((New-WtAssistantToolRecord -Name 'get_network_status' -DescriptionKey 'AsDescGetNetworkStatus' -Handler 'Get-WtNetProbe' -Parameters @(@{ Name = 'run_tests'; Type = 'boolean'; Description = 'x'; Param = 'RunTests' })))
        $r = Invoke-WtAssistantToolCall -Name 'get_network_status' -ArgumentsJson '{"run_tests":"false"}' -Context $Ctx -Registry $registry
        $r | Should -Not -Match '(?m)^tests'
        (Invoke-WtAssistantToolCall -Name 'get_network_status' -ArgumentsJson '{"run_tests":true}' -Context $Ctx -Registry $registry) | Should -Match 'ran: yes'
    }

    It 'search_wintoolify returns real rows with state fields and masks the result' {
        $r = Invoke-WtAssistantToolCall -Name 'search_wintoolify' -ArgumentsJson '{"query":"diagtrack"}' -Context $Ctx
        $r | Should -Match '(?m)^rows:'
        $r | Should -Match 'id \| label \| state \| risk'
        $r | Should -Match 'Services:DiagTrack \| '
        $r | Should -Not -Match '[{}"]'
    }

    It 'the real web_search and fetch_page records carry SkipIpMask, net tier and the query mask' {
        $web = Get-WtAssistantToolRecord -Name 'web_search'
        $web.Tier | Should -Be 'net'
        $web.SkipIpMask | Should -BeTrue
        @($web.MaskArgs) | Should -Contain 'query'
        (Get-WtAssistantToolRecord -Name 'fetch_page').SkipIpMask | Should -BeTrue
    }

    It 'a tool answer that carries the machine name reaches the model masked, end to end' {
        function Get-WtLeakProbe { [PSCustomObject]@{ host = $env:COMPUTERNAME; path = 'C:\Users\Burak\x' } }
        $registry = @((New-WtAssistantToolRecord -Name 'leak' -DescriptionKey 'AsDescGetSystemOverview' -Handler 'Get-WtLeakProbe'))
        $ctx = @{ Mask = @{ ComputerName = $env:COMPUTERNAME; UserName = 'Burak'; Serial = ''; Macs = @() }; OnSuggest = { } }
        $a = Invoke-WtAssistantToolCall -Name 'leak' -ArgumentsJson '{}' -Context $ctx -Registry $registry
        $a | Should -Not -Match ([regex]::Escape($env:COMPUTERNAME))
        $a | Should -Match '<kullanici>'
        $a | Should -Match '<pc>'
    }
}

Describe 'privacy gate' {
    BeforeEach { $script:WtAssistantPrivacyEndpoint = '' }
    AfterAll { $script:WtAssistantPrivacyEndpoint = '' }

    It 'the default REPL answer seam asks with yes/no choices' {
        (Get-Command Invoke-WtAssistantPrivacyGate).Parameters['ReadAnswer'].Attributes | Out-Null
        $def = (Get-Command Invoke-WtAssistantPrivacyGate).Definition
        $def | Should -Match '-Choices'
        $def | Should -Match 'AnswerYes'
        $def | Should -Match 'AnswerNo'
    }

    It 'never asks for a local endpoint' {
        $script:Asked = $false
        $s = [PSCustomObject]@{ AssistantEndpoint = 'http://localhost:1234/v1'; AssistantModel = 'm'; AssistantApiKey = '' }
        Invoke-WtAssistantPrivacyGate -Settings $s -Breadcrumb 'x' -ReadAnswer { param($Lines, $Prompt) $script:Asked = $true; 'e' } -ReadPermissions { @{ v = 1; always = @(); endpoints = @() } } -SavePermissions { param($P) } | Should -BeTrue
        $script:Asked | Should -BeFalse
    }

    It 'asks once per session for a remote endpoint and remembers the yes' {
        $script:AskCount = 0
        $s = [PSCustomObject]@{ AssistantEndpoint = 'https://api.openai.com/v1'; AssistantModel = 'm'; AssistantApiKey = '' }
        $yes = { param($Lines, $Prompt) $script:AskCount++; [string](Get-WtAnswerLetter -Kind 'Yes') }
        Invoke-WtAssistantPrivacyGate -Settings $s -Breadcrumb 'x' -ReadAnswer $yes -ReadPermissions { @{ v = 1; always = @(); endpoints = @() } } -SavePermissions { param($P) } | Should -BeTrue
        Invoke-WtAssistantPrivacyGate -Settings $s -Breadcrumb 'x' -ReadAnswer $yes -ReadPermissions { @{ v = 1; always = @(); endpoints = @() } } -SavePermissions { param($P) } | Should -BeTrue
        $script:AskCount | Should -Be 1
    }

    It 'a no blocks the send and does not stick' {
        $s = [PSCustomObject]@{ AssistantEndpoint = 'https://api.openai.com/v1'; AssistantModel = 'm'; AssistantApiKey = '' }
        Invoke-WtAssistantPrivacyGate -Settings $s -Breadcrumb 'x' -ReadAnswer { param($Lines, $Prompt) 'h' } -ReadPermissions { @{ v = 1; always = @(); endpoints = @() } } -SavePermissions { param($P) } | Should -BeFalse
        $script:WtAssistantPrivacyEndpoint | Should -BeNullOrEmpty
    }

    It 'a remembered endpoint skips the question; a yes is persisted; a no persists nothing' {
        $script:WtAssistantPrivacyEndpoint = ''
        $remote = [PSCustomObject]@{ AssistantEndpoint = 'https://api.x.com/v1'; AssistantModel = 'm'; AssistantApiKey = '' }
        $script:Asked = 0; $script:SavedPerms = $null
        $allowed = @{ v = 1; always = @(); endpoints = @(@{ endpoint = 'https://api.x.com/v1'; at = 'x' }) }
        (Invoke-WtAssistantPrivacyGate -Settings $remote -Breadcrumb 'b' -ReadAnswer { param($L, $P) $script:Asked++; 'n' } -ReadPermissions { $allowed } -SavePermissions { param($P) $script:SavedPerms = $P }) | Should -BeTrue
        $script:Asked | Should -Be 0
        $script:WtAssistantPrivacyEndpoint = ''
        (Invoke-WtAssistantPrivacyGate -Settings $remote -Breadcrumb 'b' -ReadAnswer { param($L, $P) $script:Asked++; 'y' } -ReadPermissions { @{ v = 1; always = @(); endpoints = @() } } -SavePermissions { param($P) $script:SavedPerms = $P }) | Should -BeTrue
        $script:Asked | Should -Be 1
        @($script:SavedPerms.endpoints)[0].endpoint | Should -Be 'https://api.x.com/v1'
        $script:WtAssistantPrivacyEndpoint = ''; $script:SavedPerms = $null
        (Invoke-WtAssistantPrivacyGate -Settings $remote -Breadcrumb 'b' -ReadAnswer { param($L, $P) 'n' } -ReadPermissions { @{ v = 1; always = @(); endpoints = @() } } -SavePermissions { param($P) $script:SavedPerms = $P }) | Should -BeFalse
        $script:SavedPerms | Should -BeNullOrEmpty
        $script:WtAssistantPrivacyEndpoint = ''
    }

    It 'enumerates what the wired tools actually emit, and does not claim nothing has been sent' {
        $categories = @{
            EN = @('event log', 'crash', 'disk health', 'volume labels', 'network adapters', 'IP and DNS',
                'security posture', 'installed program names', 'startup command lines', 'scheduled task names',
                'service names and states', 'change history')
            TR = @('olay gunlugu', 'cokme', 'disk sagligi', 'birim etiketleri', 'ag baglantilari', 'IP ve DNS',
                'guvenlik durumu', 'kurulu program adlari', 'baslangic komut satirlari', 'zamanlanmis gorev adlari',
                'servis adlari ve durumlari', 'degisiklik gecmisi')
        }
        foreach ($lang in 'EN', 'TR') {
            $line2 = (@('AsPrivacyItem1', 'AsPrivacyItem2', 'AsPrivacyItem3', 'AsPrivacyItem4', 'AsPrivacyMasked', 'AsPrivacyWeb') | ForEach-Object { [string]$script:Translations[$lang][$_] }) -join ' '
            foreach ($category in $categories[$lang]) {
                $line2.IndexOf($category, [System.StringComparison]::Ordinal) | Should -BeGreaterThan -1 -Because "$lang / $category"
            }
        }
        ([string]$script:Translations['EN']['AsPrivacyLine3']).IndexOf('Nothing is sent', [System.StringComparison]::Ordinal) | Should -Be -1
        ([string]$script:Translations['TR']['AsPrivacyLine3']).IndexOf('hicbir sey gonderilmez', [System.StringComparison]::Ordinal) | Should -Be -1
        ([string]$script:Translations['EN']['AsPrivacyLine3']).IndexOf('No system data is sent', [System.StringComparison]::Ordinal) | Should -Be 0
        ([string]$script:Translations['TR']['AsPrivacyLine3']).IndexOf('hicbir sistem verisi gonderilmez', [System.StringComparison]::Ordinal) | Should -BeGreaterThan -1
    }

    It 'names the three tools that reach the internet whatever the endpoint is' {
        $clauses = @{
            EN = @('Web search', 'Microsoft Learn', 'DuckDuckGo', 'page fetching', 'symbol download', 'from any endpoint')
            TR = @('Web aramasi', 'Microsoft Learn', 'DuckDuckGo', 'sayfa getirme', 'sembol indirme', 'uc noktadan bagimsiz')
        }
        foreach ($lang in 'EN', 'TR') {
            $line2 = (@('AsPrivacyItem1', 'AsPrivacyItem2', 'AsPrivacyItem3', 'AsPrivacyItem4', 'AsPrivacyMasked', 'AsPrivacyWeb') | ForEach-Object { [string]$script:Translations[$lang][$_] }) -join ' '
            foreach ($clause in $clauses[$lang]) {
                $line2.IndexOf($clause, [System.StringComparison]::Ordinal) | Should -BeGreaterThan -1 -Because "$lang / $clause"
            }
        }
        ([string]$script:Translations['EN']['AsPrivacyLine3']).IndexOf('three internet tools above still go online', [System.StringComparison]::Ordinal) | Should -BeGreaterThan -1
        ([string]$script:Translations['TR']['AsPrivacyLine3']).IndexOf('yukaridaki uc internet araci ise yine internete cikar', [System.StringComparison]::Ordinal) | Should -BeGreaterThan -1
    }

    It 'the consent panel still fits on a small console - every line of it (regression guard)' {
        foreach ($lang in 'EN', 'TR') {
            $old = $script:Language
            $script:Language = $lang
            try {
                foreach ($case in @(@{ W = 80; Cap = 28 }, @{ W = 100; Cap = 23 }, @{ W = 120; Cap = 21 })) {
                    $lines = @(Get-WtAssistantPrivacyLines -Endpoint 'https://api.openai.com/v1')
                    $rows = @(ConvertTo-WtPanelLines -Lines $lines -Width (Get-WtPanelInnerWidth -Width ([int]$case.W)) -Risk 'CAUTION')
                    @($rows).Count | Should -BeLessOrEqual ([int]$case.Cap) -Because ("$lang at " + [string]$case.W + ' columns')
                }
            }
            finally { $script:Language = $old }
        }
    }

    It 'asks again when the endpoint changed - the consent named ONE host' {
        $script:AskedFor = New-Object System.Collections.Generic.List[string]
        $yes = { param($Lines, $Prompt) $script:AskedFor.Add([string]$Lines[0]); [string](Get-WtAnswerLetter -Kind 'Yes') }
        $a = [PSCustomObject]@{ AssistantEndpoint = 'https://api.openai.com/v1'; AssistantModel = 'm'; AssistantApiKey = '' }
        $b = [PSCustomObject]@{ AssistantEndpoint = 'https://api.baskabir.com/v1'; AssistantModel = 'm'; AssistantApiKey = '' }
        Invoke-WtAssistantPrivacyGate -Settings $a -Breadcrumb 'x' -ReadAnswer $yes -ReadPermissions { @{ v = 1; always = @(); endpoints = @() } } -SavePermissions { param($P) } | Should -BeTrue
        Invoke-WtAssistantPrivacyGate -Settings $b -Breadcrumb 'x' -ReadAnswer $yes -ReadPermissions { @{ v = 1; always = @(); endpoints = @() } } -SavePermissions { param($P) } | Should -BeTrue
        Invoke-WtAssistantPrivacyGate -Settings $a -Breadcrumb 'x' -ReadAnswer $yes -ReadPermissions { @{ v = 1; always = @(); endpoints = @() } } -SavePermissions { param($P) } | Should -BeTrue
        $script:AskedFor.Count | Should -Be 3
        $script:AskedFor[1] | Should -Match 'api\.baskabir\.com'
    }
}

Describe 'suggestions on screen' {
    BeforeAll {
        $script:SugIndex = @(
            (New-WtAssistantIndexEntry -Id 'CapRow' -Kind 'Action' -LabelEn 'Captured row' -LabelTr 'Yakalanan satir' -Risk 'CAUTION' -Runnable $true -DescriptionEn 'Runs the row and captures its console output.' -DescriptionTr 'Satiri calistirir ve konsol ciktisini yakalar.' -Item @{ Name = 'CapRow'; Data = @{ Captured = $true; Title = 'Captured row'; Action = { }; Encoding = $null } })
            (New-WtAssistantIndexEntry -Id 'InlineRow' -Kind 'Action' -LabelEn 'Inline row' -LabelTr 'Satir ici' -Runnable $false -Item @{ Name = 'InlineRow'; Data = @{ Action = { 'painted' } } })
            (New-WtAssistantIndexEntry -Id 'Screen:Services' -Kind 'Screen' -LabelEn 'Services' -LabelTr 'Hizmetler' -Screen 'Services')
            (New-WtAssistantIndexEntry -Id 'Winget:X.Y' -Kind 'Winget' -LabelEn 'XY' -LabelTr 'XY' -Screen 'WingetStore' -Runnable $false)
            (New-WtAssistantIndexEntry -Id 'Telemetry:T' -Kind 'Toggle' -SectionKey 'Telemetry' -Section 'Telemetry' -LabelEn 'Toggle T' -LabelTr 'Anahtar T' -Risk 'SAFE' -Runnable $true -Entry ([PSCustomObject]@{ Name = 'T' }))
            (New-WtAssistantIndexEntry -Id 'DnsPreset:Cloudflare' -Kind 'Toggle' -SectionKey 'DnsPreset' -Section 'DnsPreset' -LabelEn 'Cloudflare' -LabelTr 'Cloudflare' -Runnable $false -Screen 'SystemSettings' -Entry ([PSCustomObject]@{ Name = 'Cloudflare' }))
        )
    }

    It 'fills labels and paths in the active language and carries the risk' {
        $chat = New-WtReplSession
        Set-WtAssistantSuggestions -Chat $chat -Entries @($SugIndex[0])
        $chat.Suggestions[0].Label | Should -Be 'Captured row'
        $chat.Suggestions[0].Risk | Should -Be 'CAUTION'
        $chat.Suggestions[0].What | Should -Not -BeNullOrEmpty
        $chat.Suggestions[0].What.Length | Should -BeLessOrEqual 120
    }

    It 'a screen suggestion returns a Push verdict and clears any stale store filter' {
        $chat = New-WtReplSession
        Set-WtAssistantSuggestions -Chat $chat -Entries @($SugIndex[2])
        $script:WtWingetStoreInitialQuery = 'stale'
        (Invoke-WtAssistantSuggestion -Chat $chat -Index 1 -Breadcrumb 'b').Target | Should -Be 'Services'
        [string]$script:WtWingetStoreInitialQuery | Should -Be ''
    }

    It 'a winget suggestion installs in place - no Push - and records the run for the model' {
        $chat = New-WtReplSession
        $chat.Messages.Add(@{ role = 'user'; content = 'kur' })
        Set-WtAssistantSuggestions -Chat $chat -Entries @($SugIndex[3])
        $script:WtWingetStoreInitialQuery = 'stale'
        $script:SeenEntry = $null
        $before = $chat.Messages.Count
        $r = Invoke-WtAssistantSuggestion -Chat $chat -Index 1 -Breadcrumb 'b' -InstallWinget { param($Entry, $Crumb) $script:SeenEntry = $Entry; $true }
        $r | Should -BeNullOrEmpty
        $script:SeenEntry.Id | Should -Be 'Winget:X.Y'
        [string]$script:WtWingetStoreInitialQuery | Should -Be 'stale'
        $script:WtWingetStoreInitialQuery = ''
        $tool = @($chat.Entries | Where-Object { $_.Kind -eq 'Tool' } | ForEach-Object Text)
        $tool | Should -Contain ('  ' + [string]$script:WtGlyphs.Bullet + ' XY')
        $tool | Should -Contain ('    ' + [string]$script:WtGlyphs.Branch + ' ' + (Get-Translation 'AsToolRunOwnScreen'))
        @($chat.Entries | Where-Object { $_.Kind -eq 'Info' }).Count | Should -Be 0
        $chat.Messages.Count | Should -Be $before
        $chat.PendingNotes[-1] | Should -Match '^\(note: user ran 1 Winget:.* -> winget install ran on its own screen\)$'
    }

    It 'a declined winget install applies nothing, leaves an Info line and tells the model nothing ran' {
        $chat = New-WtReplSession
        $chat.Messages.Add(@{ role = 'user'; content = 'kur' })
        Set-WtAssistantSuggestions -Chat $chat -Entries @($SugIndex[3])
        $before = $chat.Messages.Count
        $r = Invoke-WtAssistantSuggestion -Chat $chat -Index 1 -Breadcrumb 'b' -InstallWinget { param($Entry, $Crumb) $false }
        $r | Should -BeNullOrEmpty
        @($chat.Entries | Where-Object { $_.Kind -eq 'Tool' }).Count | Should -Be 0
        @($chat.Entries | Where-Object { $_.Kind -eq 'Info' }).Count | Should -Be 1
        $chat.Messages.Count | Should -Be $before
        $chat.PendingNotes[-1] | Should -Match '-> declined\)$'
    }

    It 'the default winget installer confirms yes/no, strips the Winget: id prefix and hops to run one install' {
        $chat = New-WtReplSession
        Set-WtAssistantSuggestions -Chat $chat -Entries @($SugIndex[3])
        Mock Read-WtReplAnswer { Get-WtAnswerLetter -Kind 'Yes' }
        Mock Invoke-WtReplHop { & $Action }
        Mock Reset-WtFrameCache { }
        $script:RunOp = $null; $script:RunMarks = $null
        Mock Invoke-WtWingetStoreRun { param($State, $Operation) $script:RunOp = $Operation; $script:RunMarks = @($State.Marks) }
        $null = Invoke-WtAssistantSuggestion -Chat $chat -Index 1 -Breadcrumb 'b'
        Should -Invoke Read-WtReplAnswer -Times 1 -Exactly
        Should -Invoke Invoke-WtReplHop -Times 1 -Exactly
        $script:RunOp | Should -Be 'Install'
        $script:RunMarks | Should -Be @('X.Y')
    }

    It 'the default winget installer runs nothing when the user declines' {
        $chat = New-WtReplSession
        Set-WtAssistantSuggestions -Chat $chat -Entries @($SugIndex[3])
        Mock Read-WtReplAnswer { Get-WtAnswerLetter -Kind 'No' }
        Mock Invoke-WtReplHop { throw 'must not run winget on a no' }
        Mock Reset-WtFrameCache { }
        $null = Invoke-WtAssistantSuggestion -Chat $chat -Index 1 -Breadcrumb 'b'
        Should -Invoke Invoke-WtReplHop -Times 0 -Exactly
        @($chat.Entries | Where-Object { $_.Kind -eq 'Info' }).Count | Should -Be 1
    }

    It 'a stage-only toggle (DNS preset, blocklist) pushes its screen instead of asking approval for an apply that cannot run from the chat' {
        $chat = New-WtReplSession
        Set-WtAssistantSuggestions -Chat $chat -Entries @($SugIndex[5])
        $script:Approvals = 0
        $r = Invoke-WtAssistantSuggestion -Chat $chat -Index 1 -Breadcrumb 'b' -Confirm { param($E) $script:Approvals++; $true } -Apply { param($Ids, $Ctx) throw 'must not apply' }
        $r.Nav | Should -Be 'Push'
        $r.Target | Should -Be 'SystemSettings'
        $script:Approvals | Should -Be 0
    }

    It 'a runnable row runs through the shared runner, leaves a transcript line and a pending note, never a tool pair' {
        $chat = New-WtReplSession
        $chat.Messages.Add(@{ role = 'user'; content = 'q' })
        Set-WtAssistantSuggestions -Chat $chat -Entries @($SugIndex[0])
        $before = $chat.Messages.Count
        $r = Invoke-WtAssistantSuggestion -Chat $chat -Index 1 -Breadcrumb 'b' -RunRow { param($Entry, $Crumb) @{ Ran = $true; Lines = @('out 1', 'out 2') } }
        $r | Should -BeNullOrEmpty
        $tool = @($chat.Entries | Where-Object { $_.Kind -eq 'Tool' } | ForEach-Object Text)
        $tool.Count | Should -BeGreaterThan 0
        $tool | Should -Contain ('  ' + [string]$script:WtGlyphs.Bullet + ' Captured row')
        $tool | Should -Contain ('    ' + [string]$script:WtGlyphs.Branch + ' ' + (Get-Translation 'AsToolRunDone'))
        $tool | Should -Contain '      out 2'
        @($chat.Entries | Where-Object { $_.Kind -eq 'Info' }).Count | Should -Be 0
        $chat.Messages.Count | Should -Be $before
        $chat.PendingNotes[-1] | Should -Match '-> ran \(\d+ output lines shown to the user\)\)$'
    }

    It 'a non-runnable row still runs for the USER through its own delegate and the model hears that it ran uncaptured' {
        $chat = New-WtReplSession
        Set-WtAssistantSuggestions -Chat $chat -Entries @($SugIndex[1])
        $script:Inline = 0
        $before = $chat.Messages.Count
        $null = Invoke-WtAssistantSuggestion -Chat $chat -Index 1 -Breadcrumb 'b' -RunInline { param($Entry, $Crumb) $script:Inline++ }
        $script:Inline | Should -Be 1
        $chat.Messages.Count | Should -Be $before
        $chat.PendingNotes[-1] | Should -Match '-> opened its own screen\)$'
        @($chat.Entries | Where-Object { $_.Kind -eq 'Info' }).Count | Should -Be 0
        $tool = @($chat.Entries | Where-Object { $_.Kind -eq 'Tool' } | ForEach-Object Text)
        $tool | Should -Be @(('  ' + [string]$script:WtGlyphs.Bullet + ' Inline row'), ('    ' + [string]$script:WtGlyphs.Branch + ' ' + (Get-Translation 'AsToolRunOwnScreen')))
    }

    It 'a toggle suggestion asks for approval and applies through the apply handler; a refusal applies nothing' {
        $chat = New-WtReplSession
        Set-WtAssistantSuggestions -Chat $chat -Entries @($SugIndex[4])
        $script:Applied = 0
        $null = Invoke-WtAssistantSuggestion -Chat $chat -Index 1 -Breadcrumb 'b' -Confirm { param($E) $false } -Apply { param($Ids, $Ctx) $script:Applied++; [PSCustomObject]@{ applied = @() } }
        $script:Applied | Should -Be 0
        @($chat.Entries | Where-Object { $_.Kind -eq 'Info' }).Count | Should -Be 1
        $chat.PendingNotes[-1] | Should -Match '-> declined\)$'
        $script:SeenIds = $null
        $script:SeenCtx = $null
        $chat.SystemExtra = 'stale'
        $null = Invoke-WtAssistantSuggestion -Chat $chat -Index 1 -Breadcrumb 'b' -Confirm { param($E) $true } -Apply { param($Ids, $Ctx) $script:SeenIds = @($Ids); $script:SeenCtx = $Ctx; [PSCustomObject]@{ applied = @(@{ id = 'Telemetry:T'; label = 'Toggle T' }) } }
        $script:SeenIds | Should -Be @('Telemetry:T')
        $script:SeenCtx.ContainsKey('Approved') | Should -BeFalse
        $chat.PendingNotes[-1] | Should -Match '-> applied\)$'
        $chat.SystemExtra | Should -BeNullOrEmpty
    }

    It 'an out-of-range index does nothing' {
        $chat = New-WtReplSession
        (Invoke-WtAssistantSuggestion -Chat $chat -Index 3 -Breadcrumb 'b') | Should -BeNullOrEmpty
    }

    It 'the report turn: a row that ran in place fills FollowUp with its header, the live numbers and its lines; a refused row fills nothing' {
        $chat = New-WtReplSession
        Set-WtAssistantSuggestions -Chat $chat -Entries @($SugIndex[0], $SugIndex[2])
        $null = Invoke-WtAssistantSuggestion -Chat $chat -Index 1 -Breadcrumb 'b' -RunRow { param($Entry, $Crumb) @{ Ran = $true; Lines = @('out 1', 'out 2') } }
        $chat.FollowUp | Should -Be "(result of 1 Captured row, 2 lines; explain it, do not repeat it)`nnumbers on screen: 1 Captured row; 2 Services`nout 1`nout 2"
        $refused = New-WtReplSession
        Set-WtAssistantSuggestions -Chat $refused -Entries @($SugIndex[0])
        $null = Invoke-WtAssistantSuggestion -Chat $refused -Index 1 -Breadcrumb 'b' -RunRow { param($Entry, $Crumb) @{ Ran = $false; Lines = @() } }
        $refused.FollowUp | Should -Be ''
        $refused.PendingNotes[-1] | Should -Match '-> refused \(not runnable from the chat\)\)$'
        $toolRows = @($refused.Entries | Where-Object { $_.Kind -eq 'Tool' } | ForEach-Object Text)
        $toolRows | Should -Contain ('    ' + [string]$script:WtGlyphs.Branch + ' ' + (Get-Translation 'AsToolRunRefused'))
        $toolRows | Should -Not -Contain ('    ' + [string]$script:WtGlyphs.Branch + ' ' + (Get-Translation 'AsToolRunDone'))
    }

    It 'the report turn: an applied or failed toggle reports the engine lines; a declined one, a pushed screen and an own-screen row report nothing' {
        $applied = New-WtReplSession
        Set-WtAssistantSuggestions -Chat $applied -Entries @($SugIndex[4])
        $null = Invoke-WtAssistantSuggestion -Chat $applied -Index 1 -Breadcrumb 'b' -Confirm { param($E) $true } -Apply { param($Ids, $Ctx) [PSCustomObject]@{ applied = @(@{ id = 'Telemetry:T'; label = 'Toggle T' }); failed = @(); skipped = @(); reboot_needed = $true; explorer_restart = $false } }
        $applied.FollowUp | Should -Match '^\(result of 1 Toggle T, 2 lines; explain it, do not repeat it\)\n'
        $applied.FollowUp | Should -Match ([regex]::Escape((Get-Translation 'AsApplied') -f 'Toggle T'))
        $applied.FollowUp | Should -Match 'reboot needed: yes$'
        $failed = New-WtReplSession
        Set-WtAssistantSuggestions -Chat $failed -Entries @($SugIndex[4])
        $null = Invoke-WtAssistantSuggestion -Chat $failed -Index 1 -Breadcrumb 'b' -Confirm { param($E) $true } -Apply { param($Ids, $Ctx) [PSCustomObject]@{ applied = @(); failed = @(@{ id = 'Telemetry:T'; label = 'Toggle T'; error = 'boom' }) } }
        $failed.FollowUp | Should -Match ([regex]::Escape(((Get-Translation 'AsApplyFailed') -f 'Toggle T', 'boom')))
        $declined = New-WtReplSession
        Set-WtAssistantSuggestions -Chat $declined -Entries @($SugIndex[4])
        $null = Invoke-WtAssistantSuggestion -Chat $declined -Index 1 -Breadcrumb 'b' -Confirm { param($E) $false } -Apply { param($Ids, $Ctx) throw 'must not apply' }
        $declined.FollowUp | Should -Be ''
        $gated = New-WtReplSession
        Set-WtAssistantSuggestions -Chat $gated -Entries @($SugIndex[4])
        $null = Invoke-WtAssistantSuggestion -Chat $gated -Index 1 -Breadcrumb 'b' -Confirm { param($E) $true } -Apply { param($Ids, $Ctx) [PSCustomObject]@{ applied = @(); failed = @(); skipped = @('T') } }
        $gated.FollowUp | Should -Be ''
        $gated.PendingNotes[-1] | Should -Match '-> skipped \(gate declined\)\)$'
        $pushed = New-WtReplSession
        Set-WtAssistantSuggestions -Chat $pushed -Entries @($SugIndex[2])
        $null = Invoke-WtAssistantSuggestion -Chat $pushed -Index 1 -Breadcrumb 'b'
        $pushed.FollowUp | Should -Be ''
        $inline = New-WtReplSession
        Set-WtAssistantSuggestions -Chat $inline -Entries @($SugIndex[1])
        $null = Invoke-WtAssistantSuggestion -Chat $inline -Index 1 -Breadcrumb 'b' -RunInline { param($Entry, $Crumb) }
        $inline.FollowUp | Should -Be ''
    }

    It 'the report turn: a winget install reports the runner summary it came back with; the older bare-boolean seam contract still works' {
        $chat = New-WtReplSession
        Set-WtAssistantSuggestions -Chat $chat -Entries @($SugIndex[3])
        $null = Invoke-WtAssistantSuggestion -Chat $chat -Index 1 -Breadcrumb 'b' -InstallWinget { param($Entry, $Crumb) @{ Ran = $true; Lines = @('1 installed, 0 already installed, 0 failed.') } }
        $chat.FollowUp | Should -Be "(result of 1 XY, 1 lines; explain it, do not repeat it)`nnumbers on screen: 1 XY`n1 installed, 0 already installed, 0 failed."
        $chat.PendingNotes[-1] | Should -Match '-> winget install ran on its own screen\)$'
        $declined = New-WtReplSession
        Set-WtAssistantSuggestions -Chat $declined -Entries @($SugIndex[3])
        $null = Invoke-WtAssistantSuggestion -Chat $declined -Index 1 -Breadcrumb 'b' -InstallWinget { param($Entry, $Crumb) @{ Ran = $false; Lines = @() } }
        $declined.FollowUp | Should -Be ''
        $declined.PendingNotes[-1] | Should -Match '-> declined\)$'
        $bare = New-WtReplSession
        Set-WtAssistantSuggestions -Chat $bare -Entries @($SugIndex[3])
        $null = Invoke-WtAssistantSuggestion -Chat $bare -Index 1 -Breadcrumb 'b' -InstallWinget { param($Entry, $Crumb) $true }
        $bare.FollowUp | Should -Be ''
        $bare.PendingNotes[-1] | Should -Match '-> winget install ran on its own screen\)$'
    }

    It 'the default winget installer hands the runner state back with its closing summary (State.LastSummary)' {
        $chat = New-WtReplSession
        Set-WtAssistantSuggestions -Chat $chat -Entries @($SugIndex[3])
        Mock Read-WtReplAnswer { Get-WtAnswerLetter -Kind 'Yes' }
        Mock Invoke-WtReplHop { & $Action }
        Mock Reset-WtFrameCache { }
        Mock Invoke-WtWingetStoreRun { param($State, $Operation) $State.LastSummary = [string[]]@('summary line'); @{ Ran = $false; Lines = @('leak') } }
        $null = Invoke-WtAssistantSuggestion -Chat $chat -Index 1 -Breadcrumb 'b'
        $chat.FollowUp | Should -Match "`nsummary line$"
        $chat.FollowUp | Should -Not -Match 'leak'
        $chat.PendingNotes[-1] | Should -Match '-> winget install ran on its own screen\)$'
    }

    It 'the default inline runner hops and runs a Power row through Invoke-WtPowerAction' {
        $chat = New-WtReplSession
        $entry = New-WtAssistantIndexEntry -Id 'PowerRow' -Kind 'Action' -LabelEn 'Power' -LabelTr 'Guc' -Runnable $false -Item @{ Name = 'PowerRow'; Data = @{ Power = $true; ConsequenceKey = 'ConsequenceRestart'; Action = { } } }
        Set-WtAssistantSuggestions -Chat $chat -Entries @($entry)
        Mock Invoke-WtReplHop { & $Action }
        Mock Invoke-WtPowerAction { }
        Mock Reset-WtFrameCache { }
        $null = Invoke-WtAssistantSuggestion -Chat $chat -Index 1 -Breadcrumb 'b'
        Should -Invoke Invoke-WtReplHop -Times 1 -Exactly
        Should -Invoke Invoke-WtPowerAction -Times 1 -Exactly
        $chat.Messages.Count | Should -Be 0
        $chat.PendingNotes[-1] | Should -Match '-> opened its own screen\)$'
    }

    It 'a toggle digit asks through Read-WtReplAnswer, never a panel' {
        $chat = New-WtReplSession
        Set-WtAssistantSuggestions -Chat $chat -Entries @($SugIndex[4])
        $script:SeenLines = $null; $script:SeenPrompt = $null; $script:SeenRisk = $null
        Mock Read-WtReplAnswer { param($Lines, $Prompt, $Risk) $script:SeenLines = @($Lines); $script:SeenPrompt = $Prompt; $script:SeenRisk = $Risk; 'n' }
        Mock Read-WtPanelAnswer { throw 'panel must not be used' }
        $null = Invoke-WtAssistantSuggestion -Chat $chat -Index 1 -Breadcrumb 'b'
        Should -Invoke Read-WtReplAnswer -Times 1 -Exactly
        $script:SeenLines[0] | Should -Be (Get-WtAssistantIndexLabel -Entry $SugIndex[4])
        $script:SeenPrompt | Should -Match ([regex]::Escape((Get-Translation 'AsDigitApplyPrompt')))
        $script:SeenRisk | Should -Be 'SAFE'
        @($chat.Entries | Where-Object { $_.Kind -eq 'Info' }).Count | Should -Be 1
    }

    It 'the DEFAULT Confirm gate applies on the yes letter and declines on a blank Enter or on Esc ($null) - never a panel' {
        Mock Read-WtPanelAnswer { throw 'panel must not be used' }

        $chatYes = New-WtReplSession
        Set-WtAssistantSuggestions -Chat $chatYes -Entries @($SugIndex[4])
        Mock Read-WtReplAnswer { Get-WtAnswerLetter -Kind 'Yes' }
        $script:ApplyCallsYes = 0
        $null = Invoke-WtAssistantSuggestion -Chat $chatYes -Index 1 -Breadcrumb 'b' -Apply { param($Ids, $Ctx) $script:ApplyCallsYes++; [PSCustomObject]@{ applied = @(@{ id = 'Telemetry:T'; label = 'Toggle T' }) } }
        $script:ApplyCallsYes | Should -Be 1
        $chatYes.PendingNotes[-1] | Should -Match '-> applied\)$'

        $chatBlank = New-WtReplSession
        Set-WtAssistantSuggestions -Chat $chatBlank -Entries @($SugIndex[4])
        Mock Read-WtReplAnswer { '' }
        $script:ApplyCallsBlank = 0
        $null = Invoke-WtAssistantSuggestion -Chat $chatBlank -Index 1 -Breadcrumb 'b' -Apply { param($Ids, $Ctx) $script:ApplyCallsBlank++; [PSCustomObject]@{ applied = @() } }
        $script:ApplyCallsBlank | Should -Be 0
        $chatBlank.PendingNotes[-1] | Should -Match '-> declined\)$'

        $chatEsc = New-WtReplSession
        Set-WtAssistantSuggestions -Chat $chatEsc -Entries @($SugIndex[4])
        Mock Read-WtReplAnswer { $null }
        $script:ApplyCallsEsc = 0
        $null = Invoke-WtAssistantSuggestion -Chat $chatEsc -Index 1 -Breadcrumb 'b' -Apply { param($Ids, $Ctx) $script:ApplyCallsEsc++; [PSCustomObject]@{ applied = @() } }
        $script:ApplyCallsEsc | Should -Be 0
        $chatEsc.PendingNotes[-1] | Should -Match '-> declined\)$'
    }
}

Describe 'Invoke-WtAssistantSend' {
    It 'pending notes ride in front of the next user text for the model, and the transcript shows only what the user typed' {
        $chat = New-WtReplSession
        Add-WtAssistantPendingNote -Chat $chat -Text '(note: user ran 1 Services:DiagTrack -> applied)'
        $script:Sent = ''
        Invoke-WtAssistantSend -Chat $chat -Settings ([PSCustomObject]@{ AssistantEndpoint = 'http://localhost:1234/v1'; AssistantModel = 'm'; AssistantApiKey = '' }) -Text 'oldu mu?' -Breadcrumb '' `
            -Turn { param($ArgTable) $script:Sent = [string]$ArgTable.UserText; @{ Ok = $true; FinalText = 'x'; ErrorText = ''; Cancelled = $false; Rounds = 1; Dropped = 0 } } -Write { param($S) }
        $Sent | Should -Be "(note: user ran 1 Services:DiagTrack -> applied)`noldu mu?"
        @($chat.Entries | Where-Object Kind -eq 'User')[-1].Text | Should -Be 'oldu mu?'
        $chat.PendingNotes.Count | Should -Be 0
    }

    It 'a harness turn (-Harness): no user entry, the notes still in front, the card on screen kept as it is' {
        $chat = New-WtReplSession
        $kept = @(@{ Label = 'Old'; Path = ''; Risk = ''; Entry = $null })
        $chat.Suggestions = $kept
        Add-WtAssistantPendingNote -Chat $chat -Text '(note: user ran 1 X -> ran (2 output lines shown to the user))'
        $script:Sent = ''
        $settings = [PSCustomObject]@{ AssistantEndpoint = 'http://localhost:1234/v1'; AssistantModel = 'm'; AssistantApiKey = '' }
        Invoke-WtAssistantSend -Chat $chat -Settings $settings -Text "(result of 1 X, 2 lines; explain it, do not repeat it)`na`nb" -Breadcrumb '' -Harness `
            -Turn { param($ArgTable) $script:Sent = [string]$ArgTable.UserText; @{ Ok = $true; FinalText = 'aciklama'; ErrorText = ''; Cancelled = $false; Rounds = 1; Dropped = 0 } } -Write { param($S) } -GetProfile { param($S) '' } -GetNotes { @() }
        $Sent | Should -Be "(note: user ran 1 X -> ran (2 output lines shown to the user))`n(result of 1 X, 2 lines; explain it, do not repeat it)`na`nb"
        @($chat.Entries | Where-Object Kind -eq 'User').Count | Should -Be 0
        @($chat.Entries | Where-Object Kind -eq 'Assistant')[-1].Text | Should -Be 'aciklama'
        [object]::ReferenceEquals($chat.Suggestions, $kept) | Should -BeTrue
        $chat.PendingNotes.Count | Should -Be 0
        Invoke-WtAssistantSend -Chat $chat -Settings $settings -Text 'soru' -Breadcrumb '' -Turn { param($ArgTable) @{ Ok = $true; FinalText = 'x'; ErrorText = ''; Cancelled = $false; Rounds = 1; Dropped = 0 } } -Write { param($S) } -GetProfile { param($S) '' } -GetNotes { @() }
        @($chat.Suggestions).Count | Should -Be 0
    }

    It '-KeepSuggestions: a normal turn that must not drop the card (an out-of-range digit) keeps it by reference; the line is still the user''s own' {
        $chat = New-WtReplSession
        $kept = @(@{ Label = 'Old'; Path = ''; Risk = ''; Entry = $null })
        $chat.Suggestions = $kept
        $settings = [PSCustomObject]@{ AssistantEndpoint = 'http://localhost:1234/v1'; AssistantModel = 'm'; AssistantApiKey = '' }
        Invoke-WtAssistantSend -Chat $chat -Settings $settings -Text '4' -Breadcrumb '' -KeepSuggestions -Turn { param($ArgTable) @{ Ok = $true; FinalText = 'hangisi?'; ErrorText = ''; Cancelled = $false; Rounds = 1; Dropped = 0 } } -Write { param($S) } -GetProfile { param($S) '' } -GetNotes { @() }
        [object]::ReferenceEquals($chat.Suggestions, $kept) | Should -BeTrue
        @($chat.Entries | Where-Object Kind -eq 'User')[-1].Text | Should -Be '4'
    }

    It 'a harness turn the privacy gate refuses keeps its report: queued behind the notes, no user entry, the card kept' {
        Mock Invoke-WtAssistantPrivacyGate { $false }
        $chat = New-WtReplSession
        $kept = @(@{ Label = 'Old'; Path = ''; Risk = ''; Entry = $null })
        $chat.Suggestions = $kept
        Add-WtAssistantPendingNote -Chat $chat -Text '(note: user ran 1 X -> applied)'
        Invoke-WtAssistantSend -Chat $chat -Settings ([PSCustomObject]@{ AssistantEndpoint = 'https://remote.example/v1'; AssistantModel = 'm'; AssistantApiKey = '' }) -Text '(result of 1 X, 1 lines; explain it, do not repeat it)' -Breadcrumb '' -Harness -Turn { param($ArgTable) throw 'must not send' } -Write { param($S) }
        @($chat.Entries | Where-Object Kind -eq 'User').Count | Should -Be 0
        $chat.Entries[$chat.Entries.Count - 1].Text | Should -Be (Get-Translation 'AsPrivacyDeclined')
        @($chat.PendingNotes.ToArray()) | Should -Be @('(note: user ran 1 X -> applied)', '(result of 1 X, 1 lines; explain it, do not repeat it)')
        [object]::ReferenceEquals($chat.Suggestions, $kept) | Should -BeTrue
    }

    It 'the card is printed only when the model suggested THIS turn: kept list -> no card, all-invalid suggest -> list untouched and no card, a real suggest -> card' {
        Mock Write-WtReplSuggestions { $script:CardPrints++ }
        Mock Show-WtReplSpinner { }
        Mock Hide-WtReplSpinner { }
        Mock Update-WtReplSpinner { }
        $script:CardPrints = 0
        $settings = [PSCustomObject]@{ AssistantEndpoint = 'http://localhost:1234/v1'; AssistantModel = 'm'; AssistantApiKey = '' }
        $ok = { @{ Ok = $true; FinalText = 'x'; ErrorText = ''; Cancelled = $false; Rounds = 1; Dropped = 0 } }
        $script:WtReplMode = $true
        try {
            $chat = New-WtReplSession
            $kept = @(@{ Label = 'Old'; Path = ''; Risk = ''; Entry = $null })
            $chat.Suggestions = $kept
            Invoke-WtAssistantSend -Chat $chat -Settings $settings -Text 'r' -Breadcrumb '' -Harness -Turn { param($ArgTable) & $ok } -Write { param($S) } -GetProfile { param($S) '' } -GetNotes { @() }
            $script:CardPrints | Should -Be 0
            Invoke-WtAssistantSend -Chat $chat -Settings $settings -Text 'r' -Breadcrumb '' -Harness -Turn { param($ArgTable) $null = & $ArgTable.Dispatch 'suggest_wintoolify' '{"ids":["Nope:Nope"]}'; & $ok } -Write { param($S) } -GetProfile { param($S) '' } -GetNotes { @() }
            [object]::ReferenceEquals($chat.Suggestions, $kept) | Should -BeTrue
            $script:CardPrints | Should -Be 0
            Invoke-WtAssistantSend -Chat $chat -Settings $settings -Text 'r' -Breadcrumb '' -Harness -Turn { param($ArgTable) $null = & $ArgTable.Dispatch 'suggest_wintoolify' '{"ids":["Services:DiagTrack"]}'; & $ok } -Write { param($S) } -GetProfile { param($S) '' } -GetNotes { @() }
            $chat.Suggestions[0].Id | Should -Be 'Services:DiagTrack'
            $script:CardPrints | Should -Be 1
            Invoke-WtAssistantSend -Chat $chat -Settings $settings -Text 'soru' -Breadcrumb '' -Turn { param($ArgTable) $null = & $ArgTable.Dispatch 'suggest_wintoolify' '{"ids":["Services:DiagTrack"]}'; & $ok } -Write { param($S) } -GetProfile { param($S) '' } -GetNotes { @() }
            $script:CardPrints | Should -Be 2
        }
        finally { $script:WtReplMode = $false }
    }

    It 'a turn that never landed puts the notes back on the queue, in both modes' {
        $settings = [PSCustomObject]@{ AssistantEndpoint = 'http://localhost:1234/v1'; AssistantModel = 'm'; AssistantApiKey = '' }
        $chat = New-WtReplSession
        Add-WtAssistantPendingNote -Chat $chat -Text '(note: user ran 1 X -> applied)'
        Invoke-WtAssistantSend -Chat $chat -Settings $settings -Text 'oldu mu?' -Breadcrumb '' -Turn { param($ArgTable) @{ Ok = $false; FinalText = ''; ErrorText = 'boom'; Cancelled = $false; Rounds = 1; Dropped = 0 } } -Write { param($S) } -GetProfile { param($S) '' } -GetNotes { @() }
        @($chat.PendingNotes.ToArray()) | Should -Be @('(note: user ran 1 X -> applied)')
        $cancelled = New-WtReplSession
        Add-WtAssistantPendingNote -Chat $cancelled -Text '(note: user ran 2 Y -> ran (3 output lines shown to the user))'
        Invoke-WtAssistantSend -Chat $cancelled -Settings $settings -Text '(result of 2 Y, 3 lines; explain it, do not repeat it)' -Breadcrumb '' -Harness -Turn { param($ArgTable) @{ Ok = $false; FinalText = ''; ErrorText = ''; Cancelled = $true; Rounds = 1; Dropped = 0 } } -Write { param($S) } -GetProfile { param($S) '' } -GetNotes { @() }
        @($cancelled.PendingNotes.ToArray()) | Should -Be @('(note: user ran 2 Y -> ran (3 output lines shown to the user))', '(result of 2 Y, 3 lines; explain it, do not repeat it)')
    }

    It 'routes through the agent turn, filters schemas to the dispatch table and traces tools' {
        $chat = New-WtReplSession
        $settings = [PSCustomObject]@{ AssistantEndpoint = 'http://localhost:1234/v1'; AssistantModel = 'm'; AssistantApiKey = '' }
        $script:TurnArgs = $null
        $turn = { param($ArgTable) $script:TurnArgs = $ArgTable; @{ Ok = $true; FinalText = 'ajan cevabi'; ErrorText = ''; Cancelled = $false; Rounds = 2 } }
        Invoke-WtAssistantSend -Chat $chat -Settings $settings -Text 'soru' -Breadcrumb 'x' -Turn $turn -GetProfile { param($S) '' } -GetNotes { @() }
        (@($chat.Entries.ToArray() | Where-Object { $_.Kind -eq 'Assistant' })).Text | Should -Be 'ajan cevabi'
        @($script:TurnArgs.Schemas | ForEach-Object { [string]$_.'function'.name }) | Should -Contain 'search_wintoolify'
        @($script:TurnArgs.Schemas | ForEach-Object { [string]$_.'function'.name }) | Should -Contain 'web_search'
        @($script:TurnArgs.Schemas | ForEach-Object { [string]$_.'function'.name }) | Should -Contain 'fetch_page'
        @($script:TurnArgs.Schemas | ForEach-Object { [string]$_.'function'.name }) | Should -Contain 'read_system'
        $script:TurnArgs.MaxRounds | Should -Be 5
        $script:TurnArgs.HistoryMaxChars | Should -Be 40000
        $script:Schemas1 = $script:TurnArgs.Schemas
        Invoke-WtAssistantSend -Chat $chat -Settings $settings -Text 'soru2' -Breadcrumb 'x' -Turn $turn -GetProfile { param($S) '' } -GetNotes { @() }
        $script:Schemas2 = $script:TurnArgs.Schemas
        [object]::ReferenceEquals($script:Schemas1, $script:Schemas2) | Should -BeTrue
    }

    It 'posts the spec trimming notice above the answer when history fell off the back' {
        $chat = New-WtReplSession
        $settings = [PSCustomObject]@{ AssistantEndpoint = 'http://localhost:1234/v1'; AssistantModel = 'm'; AssistantApiKey = '' }
        $turn = { param($ArgTable) @{ Ok = $true; FinalText = 'cevap'; ErrorText = ''; Cancelled = $false; Rounds = 1; Dropped = 2 } }
        Invoke-WtAssistantSend -Chat $chat -Settings $settings -Text 'soru' -Breadcrumb 'x' -Turn $turn -GetProfile { param($S) '' } -GetNotes { @() }
        $entries = @($chat.Entries.ToArray())
        $entries[1].Kind | Should -Be 'Info'
        $entries[1].Text | Should -Be (Get-Translation 'AsTrimmed')
        $entries[2].Kind | Should -Be 'Assistant'
        $entries[2].Text | Should -Be 'cevap'

        $quiet = New-WtReplSession
        $noDrop = { param($ArgTable) @{ Ok = $true; FinalText = 'cevap'; ErrorText = ''; Cancelled = $false; Rounds = 1; Dropped = 0 } }
        Invoke-WtAssistantSend -Chat $quiet -Settings $settings -Text 'soru' -Breadcrumb 'x' -Turn $noDrop -GetProfile { param($S) '' } -GetNotes { @() }
        @($quiet.Entries.ToArray() | Where-Object { [string]$_.Kind -eq 'Info' -and [string]$_.Text -eq (Get-Translation 'AsTrimmed') }).Count | Should -Be 0
    }

    It 'passes the sampling settings to the client; a reasoning delta ticks the spinner and is never written' {
        $chat = New-WtReplSession
        $settings = [PSCustomObject]@{ AssistantEndpoint = 'http://127.0.0.1:11434/v1'; AssistantModel = 'm'; AssistantApiKey = ''; AssistantTemperature = '0.3'; AssistantMaxTokens = '512' }
        $script:ClientArgs = $null
        Mock Invoke-WtLlmChat {
            param($Endpoint, $ApiKey, $Model, $Messages, $Tools, $ToolChoice, $OnDelta, $OnReasoningDelta, $ShouldCancel, $TimeoutSec, $Stream, $Temperature, $MaxTokens, $Transport, $NumCtx, $Compat)
            $script:ClientArgs = $PSBoundParameters
            @{ Ok = $true; Content = 'x'; ToolCalls = @(); FinishReason = 'stop'; ErrorKind = ''; ErrorText = ''; Cancelled = $false; Reasoning = '' }
        }
        Mock Update-WtReplSpinner { param($AddChars) $script:Ticked += [int]$AddChars }
        Mock Show-WtReplSpinner { }
        Mock Hide-WtReplSpinner { }
        $script:Ticked = 0
        $script:Written = @()
        Reset-WtReplStream
        Invoke-WtAssistantSend -Chat $chat -Settings $settings -Text 'q' -Breadcrumb 'b' -Turn { param($ArgTable) & $ArgTable.Client @() 1 | Out-Null; @{ Ok = $true; FinalText = 'x'; ErrorText = ''; Cancelled = $false; Rounds = 1; Dropped = 0 } } -Write { param($T, $F, $N) $script:Written += @($T) } -GetProfile { param($S) '' } -GetNotes { @() }
        $script:ClientArgs.Temperature | Should -Be 0.3
        $script:ClientArgs.MaxTokens | Should -Be 512
        & $script:ClientArgs.OnReasoningDelta 'secret thoughts'
        $script:Ticked | Should -Be 15
        ($script:Written -join '') | Should -Not -Match 'secret'
        (Get-WtReplStreamText -Kind 'Content') | Should -Be ''
    }

    It 'passes num_ctx to the client only for an Ollama endpoint, hands the session Compat table over, and derives the history window from num_ctx' {
        Mock Invoke-WtLlmChat {
            param($Endpoint, $ApiKey, $Model, $Messages, $Tools, $ToolChoice, $OnDelta, $OnReasoningDelta, $ShouldCancel, $TimeoutSec, $Stream, $Temperature, $MaxTokens, $Transport, $NumCtx, $Compat)
            $script:ClientArgs = $PSBoundParameters
            @{ Ok = $true; Content = 'x'; ToolCalls = @(); FinishReason = 'stop'; ErrorKind = ''; ErrorText = ''; Cancelled = $false; Reasoning = ''; Usage = $null }
        }
        Mock Show-WtReplSpinner { }
        Mock Hide-WtReplSpinner { }
        $turn = { param($ArgTable) $script:TurnArgs = $ArgTable; & $ArgTable.Client @() 1 | Out-Null; @{ Ok = $true; FinalText = 'x'; ErrorText = ''; Cancelled = $false; Rounds = 1; Dropped = 0 } }
        $chat = New-WtReplSession
        $ollama = [PSCustomObject]@{ AssistantEndpoint = 'http://127.0.0.1:11434/v1'; AssistantModel = 'm'; AssistantApiKey = ''; AssistantNumCtx = '8192' }
        Reset-WtReplStream
        Invoke-WtAssistantSend -Chat $chat -Settings $ollama -Text 'q' -Breadcrumb 'b' -Turn $turn -Write { param($T, $F, $N) } -GetProfile { param($S) '' } -GetNotes { @() }
        $script:ClientArgs.NumCtx | Should -Be 8192
        [object]::ReferenceEquals($script:ClientArgs.Compat, $chat.ClientCompat) | Should -BeTrue
        $script:TurnArgs.HistoryMaxChars | Should -BeGreaterOrEqual 12000
        $script:TurnArgs.HistoryMaxChars | Should -BeLessThan 40000
        $chat.HistoryMaxChars | Should -Be $script:TurnArgs.HistoryMaxChars
        $lmStudio = [PSCustomObject]@{ AssistantEndpoint = 'http://127.0.0.1:1234/v1'; AssistantModel = 'm'; AssistantApiKey = ''; AssistantNumCtx = '8192' }
        $chat2 = New-WtReplSession
        Reset-WtReplStream
        Invoke-WtAssistantSend -Chat $chat2 -Settings $lmStudio -Text 'q' -Breadcrumb 'b' -Turn $turn -Write { param($T, $F, $N) } -GetProfile { param($S) '' } -GetNotes { @() }
        $script:ClientArgs.NumCtx | Should -Be 0
        $script:TurnArgs.HistoryMaxChars | Should -Be 40000
        $chat2.HistoryMaxChars | Should -Be 40000
    }

    It 'sums the usage of every round into Chat.LastUsage and warns once when the last prompt nears num_ctx' {
        Mock Invoke-WtLlmChat {
            param($Endpoint, $ApiKey, $Model, $Messages, $Tools, $ToolChoice, $OnDelta, $OnReasoningDelta, $ShouldCancel, $TimeoutSec, $Stream, $Temperature, $MaxTokens, $Transport, $NumCtx, $Compat)
            @{ Ok = $true; Content = 'x'; ToolCalls = @(); FinishReason = 'stop'; ErrorKind = ''; ErrorText = ''; Cancelled = $false; Reasoning = ''; Usage = @{ PromptTokens = 7000; CompletionTokens = 10; CachedTokens = 500 } }
        }
        Mock Show-WtReplSpinner { }
        Mock Hide-WtReplSpinner { }
        $twoRounds = { param($ArgTable) & $ArgTable.Client @() 1 | Out-Null; & $ArgTable.Client @() 2 | Out-Null; @{ Ok = $true; FinalText = 'x'; ErrorText = ''; Cancelled = $false; Rounds = 2; Dropped = 0 } }
        $chat = New-WtReplSession
        $ollama = [PSCustomObject]@{ AssistantEndpoint = 'http://127.0.0.1:11434/v1'; AssistantModel = 'm'; AssistantApiKey = ''; AssistantNumCtx = '8192' }
        Reset-WtReplStream
        Invoke-WtAssistantSend -Chat $chat -Settings $ollama -Text 'q' -Breadcrumb 'b' -Turn $twoRounds -Write { param($T, $F, $N) } -GetProfile { param($S) '' } -GetNotes { @() }
        $chat.LastUsage.PromptTokens | Should -Be 14000
        $chat.LastUsage.CompletionTokens | Should -Be 20
        $chat.LastUsage.CachedTokens | Should -Be 1000
        $chat.LastUsage.LastPromptTokens | Should -Be 7000
        $chat.LastUsage.Rounds | Should -Be 2
        @($chat.Entries | ForEach-Object Kind) | Should -Be @('User', 'Assistant', 'Info')
        $chat.Entries[2].Text | Should -Be ((Get-Translation 'AsCtxWarning') -f 7000, 8192)
        $plain = [PSCustomObject]@{ AssistantEndpoint = 'http://127.0.0.1:11434/v1'; AssistantModel = 'm'; AssistantApiKey = ''; AssistantNumCtx = '' }
        $chat2 = New-WtReplSession
        Reset-WtReplStream
        Invoke-WtAssistantSend -Chat $chat2 -Settings $plain -Text 'q' -Breadcrumb 'b' -Turn $twoRounds -Write { param($T, $F, $N) } -GetProfile { param($S) '' } -GetNotes { @() }
        @($chat2.Entries | ForEach-Object Kind) | Should -Be @('User', 'Assistant')
        $chat2.LastUsage.PromptTokens | Should -Be 14000
        Mock Invoke-WtLlmChat {
            param($Endpoint, $ApiKey, $Model, $Messages, $Tools, $ToolChoice, $OnDelta, $OnReasoningDelta, $ShouldCancel, $TimeoutSec, $Stream, $Temperature, $MaxTokens, $Transport, $NumCtx, $Compat)
            @{ Ok = $true; Content = 'x'; ToolCalls = @(); FinishReason = 'stop'; ErrorKind = ''; ErrorText = ''; Cancelled = $false; Reasoning = '' }
        }
        Reset-WtReplStream
        Invoke-WtAssistantSend -Chat $chat2 -Settings $plain -Text 'q2' -Breadcrumb 'b' -Turn $twoRounds -Write { param($T, $F, $N) } -GetProfile { param($S) '' } -GetNotes { @() }
        $chat2.LastUsage | Should -BeNullOrEmpty
    }

    It 'the num_ctx parse and the history window formula are pure' {
        ConvertTo-WtAssistantNumCtx -Text '8192' | Should -Be 8192
        ConvertTo-WtAssistantNumCtx -Text ' 4096 ' | Should -Be 4096
        foreach ($bad in '', 'abc', '-5', '0', '1.5', $null) { ConvertTo-WtAssistantNumCtx -Text $bad | Should -Be 0 -Because ('[' + [string]$bad + ']') }
        ConvertTo-WtAssistantNumCtx -Text '2000000000' | Should -Be 4000000
        { Get-WtAssistantHistoryMaxChars -NumCtx 4000000 -PrefixChars 0 -Ollama $true } | Should -Not -Throw
        Get-WtAssistantHistoryMaxChars | Should -Be 40000
        Get-WtAssistantHistoryMaxChars -NumCtx 8192 -PrefixChars 6000 -Ollama $false | Should -Be 40000
        Get-WtAssistantHistoryMaxChars -NumCtx 8192 -PrefixChars 6000 -Ollama $true | Should -Be 16576
        Get-WtAssistantHistoryMaxChars -NumCtx 4096 -PrefixChars 6000 -Ollama $true | Should -Be 12000
        Get-WtAssistantHistoryMaxChars -NumCtx 0 -PrefixChars 6000 -Ollama $true | Should -Be 40000
        $total = @{ PromptTokens = 0; CompletionTokens = 0; CachedTokens = 0; LastPromptTokens = 0; Rounds = 0 }
        Add-WtAssistantUsage -Total $total -Usage $null
        $total.Rounds | Should -Be 0
        Add-WtAssistantUsage -Total $total -Usage @{ PromptTokens = 10; CompletionTokens = 1; CachedTokens = 0 }
        Add-WtAssistantUsage -Total $total -Usage @{ PromptTokens = 20; CompletionTokens = 2; CachedTokens = 5 }
        $total.PromptTokens | Should -Be 30
        $total.LastPromptTokens | Should -Be 20
        $total.CachedTokens | Should -Be 5
        $total.Rounds | Should -Be 2
    }

    It 'a declined privacy gate leaves one Info entry and never reaches the turn seam' {
        $chat = New-WtReplSession
        $settings = [PSCustomObject]@{ AssistantEndpoint = 'https://api.example.com/v1'; AssistantModel = 'm'; AssistantApiKey = '' }
        $script:WtAssistantPrivacyEndpoint = ''
        Mock Invoke-WtAssistantPrivacyGate { $false }
        Invoke-WtAssistantSend -Chat $chat -Settings $settings -Text 'q' -Breadcrumb 'b' -Turn { param($ArgTable) throw 'must not run' } -GetProfile { param($S) '' } -GetNotes { @() }
        @($chat.Entries | Where-Object { $_.Kind -eq 'Info' }).Count | Should -Be 1
        $chat.Messages.Count | Should -Be 0
    }

    It 'a throwing turn leaves Busy false' {
        $chat = New-WtReplSession
        $settings = [PSCustomObject]@{ AssistantEndpoint = 'http://127.0.0.1:11434/v1'; AssistantModel = 'm'; AssistantApiKey = '' }
        { Invoke-WtAssistantSend -Chat $chat -Settings $settings -Text 'q' -Breadcrumb 'b' -Turn { param($ArgTable) throw 'boom' } -GetProfile { param($S) '' } -GetNotes { @() } } | Should -Throw
        $chat.Busy | Should -BeFalse
    }

    It 'OnToolStart writes the bullet line and switches the spinner label; OnToolDone writes the branch result and goes back to thinking' {
        $chat = New-WtReplSession
        $settings = [PSCustomObject]@{ AssistantEndpoint = 'http://127.0.0.1:11434/v1'; AssistantModel = 'm'; AssistantApiKey = '' }
        $script:Labels = @()
        $script:LabelAtDispatch = ''
        Mock Show-WtReplSpinner { param($Label) $script:Labels += @($Label) }
        Mock Hide-WtReplSpinner { }
        Mock Invoke-WtAssistantToolCall { param($Name, $ArgumentsJson, $Context) $script:LabelAtDispatch = [string]$script:Labels[-1]; '{}' }
        Invoke-WtAssistantSend -Chat $chat -Settings $settings -Text 'q' -Breadcrumb 'b' -GetProfile { param($S) '' } -GetNotes { @() } -Write { param($T, $F, $N) } -Turn { param($ArgTable)
            & $ArgTable.OnToolStart 'get_system_overview' '{}'
            $null = & $ArgTable.Dispatch 'get_system_overview' '{}'
            & $ArgTable.OnToolDone 'get_system_overview' 0.42 1843 $true
            @{ Ok = $true; FinalText = 'ok'; ErrorText = ''; Cancelled = $false; Rounds = 1; Dropped = 0 }
        }
        $tool = @($chat.Entries | Where-Object { $_.Kind -eq 'Tool' })
        $tool.Count | Should -Be 2
        $tool[0].Text | Should -Be (Format-WtReplToolStart -Name 'get_system_overview' -ArgumentsJson '{}' -Width 100)
        $tool[1].Text | Should -Be (Format-WtReplToolResult -Seconds 0.42 -Chars 1843 -Ok $true)
        $running = (Get-Translation 'AsSpinTool') -f 'get_system_overview'
        $script:Labels | Should -Be @((Get-Translation 'AsSpinThinking'), $running, (Get-Translation 'AsSpinThinking'))
        $script:LabelAtDispatch | Should -Be $running
    }

    It 'streams through -OnDelta, records the streamed text as the silent assistant entry and traces tools with timing' {
        $chat = New-WtReplSession
        $settings = [PSCustomObject]@{ AssistantEndpoint = 'http://127.0.0.1:11434/v1'; AssistantModel = 'm'; AssistantApiKey = '' }
        $script:Streamed = ''
        Reset-WtReplStream
        Invoke-WtAssistantSend -Chat $chat -Settings $settings -Text 'q' -Breadcrumb 'b' -GetProfile { param($S) '' } -GetNotes { @() } -OnDelta { param($Piece) $script:Streamed += $Piece; Write-WtReplStream -Piece $Piece -Write { param($T, $F, $N) } } -Turn { param($ArgTable)
            & $ArgTable.OnToolDone 'get_system_overview' 0.42 1843 $true
            @{ Ok = $true; FinalText = 'cevap'; ErrorText = ''; Cancelled = $false; Rounds = 2; Dropped = 0 }
        } -Write { param($T, $F, $N) }
        $kinds = @($chat.Entries | ForEach-Object { [string]$_.Kind })
        $kinds | Should -Be @('User', 'Tool', 'Assistant')
        $chat.Entries[1].Text | Should -Be (Format-WtReplToolResult -Seconds 0.42 -Chars 1843 -Ok $true)
        $chat.Entries[2].Text | Should -Be 'cevap'
        $chat.Entries.Count | Should -Be 3
    }

    It 'a transcript writer fired mid-stream flushes the buffered half line as a complete row first' {
        $chat = New-WtReplSession
        $settings = [PSCustomObject]@{ AssistantEndpoint = 'http://127.0.0.1:11434/v1'; AssistantModel = 'm'; AssistantApiKey = '' }
        Reset-WtReplStream
        Reset-WtReplBlockState
        $script:W = @()
        Invoke-WtAssistantSend -Chat $chat -Settings $settings -Text 'q' -Breadcrumb 'b' -GetProfile { param($S) '' } -GetNotes { @() } -Write { param($T, $F, $N) $script:W += @("$T|$N") } -Turn { param($ArgTable)
            Write-WtReplStream -Piece 'half' -Write { param($T, $F, $N) $script:W += @("$T|$N") }
            & $ArgTable.OnToolDone 'x' 0.1 10 $true
            @{ Ok = $true; FinalText = 'ok'; ErrorText = ''; Cancelled = $false; Rounds = 1; Dropped = 0 }
        }
        @($script:W).Count | Should -Be 1
        $script:W[0].TrimStart().StartsWith('half', [System.StringComparison]::Ordinal) | Should -BeTrue
        $script:W[0].EndsWith('|False', [System.StringComparison]::Ordinal) | Should -BeTrue

        $src = (Get-Command Invoke-WtAssistantSend).Definition
        $src | Should -Match 'OnApplied\s*=\s*\{\s*param\(\$Lines\)\s*& \$breakStream'
        $src | Should -Match '\$onToolStart\s*=\s*\{\s*param\(\$Name, \$ArgsJson\)\s*\r?\n\s*& \$breakStream'
        $src | Should -Match '\$onToolDone\s*=\s*\{\s*param\(\$Name, \$Seconds, \$Chars, \$Ok\)\s*\r?\n\s*& \$breakStream'
    }

    It 'a cancelled turn keeps the partial streamed text as an Info line' {
        $chat = New-WtReplSession
        $settings = [PSCustomObject]@{ AssistantEndpoint = 'http://127.0.0.1:11434/v1'; AssistantModel = 'm'; AssistantApiKey = '' }
        Reset-WtReplStream
        Invoke-WtAssistantSend -Chat $chat -Settings $settings -Text 'q' -Breadcrumb 'b' -GetProfile { param($S) '' } -GetNotes { @() } -Turn { param($ArgTable)
            Write-WtReplStream -Piece 'yarim' -Write { param($T, $F, $N) }
            @{ Ok = $false; FinalText = ''; ErrorText = ''; Cancelled = $true; Rounds = 1; Dropped = 0 }
        } -Write { param($T, $F, $N) }
        $last = $chat.Entries[$chat.Entries.Count - 1]
        $last.Kind | Should -Be 'Info'
        $last.Text | Should -Match 'yarim'
    }

    It 'masks a note''s text with -Mask, given or not; no -Mask leaves it exactly as stored (already masked at save time)' {
        $mask = @{ ComputerName = 'TESTPC'; UserName = 'ali'; Serial = ''; Macs = @() }
        $masked = Get-WtAssistantSystemExtra -Date ([datetime]'2026-09-05') -Language 'EN' -Notes @(@{ text = 'ali here'; at = 'x' }) -Mask $mask
        $masked | Should -Match '<kullanici>'
        $masked | Should -Not -Match 'ali here'
        $unmasked = Get-WtAssistantSystemExtra -Date ([datetime]'2026-09-05') -Language 'EN' -Notes @(@{ text = 'ali here'; at = 'x' })
        $unmasked | Should -Match 'ali here'
    }

    It 'sends the session system[1] on every turn - identical bytes across two sends - and rebuilds it without the profile after /profil off' {
        $chat = New-WtReplSession
        $script:Extras = @()
        $turn = { param($ArgTable) $script:Extras += @([string]$ArgTable.SystemExtra); @{ Ok = $true; FinalText = 'x'; ErrorText = ''; Cancelled = $false; Rounds = 1; Dropped = 0 } }
        $profile = { param($S) if ($S.ProfileEnabled) { '{"cpu":"probe"}' } else { '' } }
        Invoke-WtAssistantSend -Chat $chat -Settings ([PSCustomObject]@{ AssistantEndpoint = 'http://localhost:1234/v1'; AssistantModel = 'm'; AssistantApiKey = '' }) -Text 'a' -Breadcrumb '' -Turn $turn -GetProfile $profile -GetNotes { @() } -Write { param($S) }
        Invoke-WtAssistantSend -Chat $chat -Settings ([PSCustomObject]@{ AssistantEndpoint = 'http://localhost:1234/v1'; AssistantModel = 'm'; AssistantApiKey = '' }) -Text 'b' -Breadcrumb '' -Turn $turn -GetProfile $profile -GetNotes { @() } -Write { param($S) }
        $Extras.Count | Should -Be 2
        $Extras[1] | Should -Be $Extras[0]
        $Extras[0] | Should -Match 'machine profile \(anonymized\): \{"cpu":"probe"\}'
        $Extras[0] | Should -Match '^date: \d{4}-\d{2}-\d{2}'
        $chat.ProfileEnabled = $false
        Reset-WtAssistantSessionExtra -Chat $chat
        Invoke-WtAssistantSend -Chat $chat -Settings ([PSCustomObject]@{ AssistantEndpoint = 'http://localhost:1234/v1'; AssistantModel = 'm'; AssistantApiKey = '' }) -Text 'c' -Breadcrumb '' -Turn $turn -GetProfile $profile -GetNotes { @() } -Write { param($S) }
        $Extras[2] | Should -Not -Match 'machine profile'
        $Extras[2] | Should -Match 'reply language'
    }

    It 'the default profile seam goes through the cache orchestrator' {
        Mock Get-WtAssistantMachineProfile { @{ Json = '{"mocked":true}'; Cold = $false; BuiltAt = '' } }
        $chat = New-WtReplSession
        $script:ExtraSeen = $null
        Invoke-WtAssistantSend -Chat $chat -Settings ([PSCustomObject]@{ AssistantEndpoint = 'http://127.0.0.1:11434/v1'; AssistantModel = 'm'; AssistantApiKey = '' }) -Text 'q' -Breadcrumb 'b' -Turn { param($ArgTable) $script:ExtraSeen = [string]$ArgTable.SystemExtra; @{ Ok = $true; FinalText = 'x'; ErrorText = ''; Cancelled = $false; Rounds = 1; Dropped = 0 } } -Write { param($T, $F, $N) } -GetNotes { @() }
        $script:ExtraSeen | Should -Match 'mocked'
        Should -Invoke Get-WtAssistantMachineProfile -Times 1 -ParameterFilter { $Kind -eq 'Short' }
    }

    It 'a saved note lands in the transcript as an info line and the notes reach system[1]' {
        $chat = New-WtReplSession
        $settings = [PSCustomObject]@{ AssistantEndpoint = 'http://127.0.0.1:11434/v1'; AssistantModel = 'm'; AssistantApiKey = '' }
        $script:Extras = @()
        $script:Saved = $false
        $turn = { param($ArgTable) $script:Extras += @([string]$ArgTable.SystemExtra); & $ArgTable.Dispatch 'save_note' '{"text":"likes dark mode"}' | Out-Null; @{ Ok = $true; FinalText = 'x'; ErrorText = ''; Cancelled = $false; Rounds = 1; Dropped = 0 } }
        Mock Add-WtAssistantNote { $script:Saved = $true; @{ Saved = $true; Text = 'likes dark mode'; Dropped = $false; Count = 1 } }
        $getNotes = { if ($script:Saved) { @(@{ text = 'old note'; at = 'x' }, @{ text = 'likes dark mode'; at = 'y' }) } else { @(@{ text = 'old note'; at = 'x' }) } }
        Invoke-WtAssistantSend -Chat $chat -Settings $settings -Text 'q' -Breadcrumb 'b' -Turn $turn -Write { param($T, $F, $N) } -GetProfile { param($S) '' } -GetNotes $getNotes
        $script:ExtraSeen = $Extras[0]
        $script:ExtraSeen | Should -Match '- old note'
        @($chat.Entries | Where-Object { $_.Kind -eq 'Info' -and $_.Text -match 'likes dark mode' }).Count | Should -Be 1
        Invoke-WtAssistantSend -Chat $chat -Settings $settings -Text 'q2' -Breadcrumb 'b' -Turn $turn -Write { param($T, $F, $N) } -GetProfile { param($S) '' } -GetNotes $getNotes
        $Extras[-1] | Should -Match 'notes the user asked you to remember'
    }
}


Describe 'Get-WtAssistantPrivacyLines (the consent text)' {
    It 'is a headed list: where, a blank, the heading and four bullets, a blank, masking and the internet tools, a blank, the guarantee' {
        foreach ($lang in 'EN', 'TR') {
            $old = $script:Language
            $script:Language = $lang
            try {
                $lines = @(Get-WtAssistantPrivacyLines -Endpoint 'https://api.example.com/v1')
                $lines.Count | Should -Be 12 -Because $lang
                $lines[0] | Should -Match 'https://api\.example\.com/v1'
                $lines[1] | Should -Be ''
                $lines[2] | Should -Be (Get-Translation 'AsPrivacyWhat')
                foreach ($i in 3..6) { $lines[$i] | Should -Match '^- \S' -Because "$lang item $i" }
                $lines[7] | Should -Be ''
                $lines[8] | Should -Be (Get-Translation 'AsPrivacyMasked')
                $lines[9] | Should -Be (Get-Translation 'AsPrivacyWeb')
                $lines[10] | Should -Be ''
                $lines[11] | Should -Be (Get-Translation 'AsPrivacyLine3')
                foreach ($l in $lines) { $l.Length | Should -BeLessThan 450 -Because $lang }
            }
            finally { $script:Language = $old }
        }
        $script:Translations['EN'].ContainsKey('AsPrivacyLine2') | Should -BeFalse
        $script:Translations['TR'].ContainsKey('AsPrivacyLine2') | Should -BeFalse
    }
    It 'the gate hands exactly these lines to the answer seam' {
        $s = [PSCustomObject]@{ AssistantEndpoint = 'https://api.example.com/v1'; AssistantModel = 'm'; AssistantApiKey = '' }
        $script:WtAssistantPrivacyEndpoint = ''
        $script:GateLines = $null
        $null = Invoke-WtAssistantPrivacyGate -Settings $s -Breadcrumb 'x' -ReadAnswer { param($Lines, $Prompt) $script:GateLines = @($Lines); 'h' } -ReadPermissions { @{ v = 1; always = @(); endpoints = @() } } -SavePermissions { param($P) }
        @($script:GateLines) | Should -Be @(Get-WtAssistantPrivacyLines -Endpoint 'https://api.example.com/v1')
    }
}

Describe 'the settings rows with a ChatGPT identity' {
    It 'puts the account row first and still returns eight rows' {
        $rows = @(Get-WtAssistantSettingsRows -Settings ([PSCustomObject]@{
                    AssistantEndpoint = ''; AssistantModel = ''; AssistantApiKey = ''; AssistantNumCtx = ''; AssistantAuthMode = ''
                }))
        $rows.Count | Should -Be 8
        $rows[0].Data.Setting | Should -Be 'AuthMode'
        @($rows | ForEach-Object { [string]$_.Data.Setting }) | Should -Be @('AuthMode', 'Preset', 'Endpoint', 'ApiKey', 'Model', 'Scan', 'Test', 'NumCtx')
    }

    It 'enables every row when no mode is set' {
        $rows = @(Get-WtAssistantSettingsRows -Settings ([PSCustomObject]@{
                    AssistantEndpoint = 'http://x/v1'; AssistantModel = 'm'; AssistantApiKey = ''; AssistantNumCtx = ''; AssistantAuthMode = ''
                }))
        foreach ($row in $rows) { [bool]$row.Data.Disabled | Should -BeFalse }
    }

    It 'disables preset, endpoint, api key, scan and numctx in ChatGPT mode' {
        $rows = @(Get-WtAssistantSettingsRows -Settings ([PSCustomObject]@{
                    AssistantEndpoint = 'http://x/v1'; AssistantModel = 'm'; AssistantApiKey = ''; AssistantNumCtx = ''; AssistantAuthMode = 'ChatGPT'
                }) -Auth @{ Email = 'a@b.c'; PlanType = 'plus' })
        $byName = @{}
        foreach ($row in $rows) { $byName[[string]$row.Data.Setting] = $row }
        foreach ($disabled in @('Preset', 'Endpoint', 'ApiKey', 'Scan', 'NumCtx')) {
            [bool]$byName[$disabled].Data.Disabled | Should -BeTrue
            $byName[$disabled].StateLabel | Should -Be (Get-Translation 'AsChatGptNotUsedInMode')
        }
        foreach ($enabled in @('AuthMode', 'Model', 'Test')) {
            [bool]$byName[$enabled].Data.Disabled | Should -BeFalse
        }
    }

    It 'shows the account and plan in the state column when signed in' {
        $rows = @(Get-WtAssistantSettingsRows -Settings ([PSCustomObject]@{
                    AssistantEndpoint = ''; AssistantModel = ''; AssistantApiKey = ''; AssistantNumCtx = ''; AssistantAuthMode = 'ChatGPT'
                }) -Auth @{ Email = 'burak@example.com'; PlanType = 'plus' })
        $rows[0].StateLabel | Should -Be ((Get-Translation 'AsChatGptStateFormat') -f 'burak@example.com', 'plus')
        $rows[0].Label | Should -Be (Get-Translation 'AsChatGptSignOut')
    }

    It 'offers sign-in and shows nothing about an account when signed out' {
        $rows = @(Get-WtAssistantSettingsRows -Settings ([PSCustomObject]@{
                    AssistantEndpoint = ''; AssistantModel = ''; AssistantApiKey = ''; AssistantNumCtx = ''; AssistantAuthMode = ''
                }) -Auth @{ Email = ''; PlanType = '' })
        $rows[0].Label | Should -Be (Get-Translation 'AsChatGptSignIn')
        $rows[0].StateLabel | Should -Be ''
    }

    It 'falls back to the email alone when the plan is unknown' {
        Get-WtChatGptAccountStateLabel -Auth @{ Email = 'a@b.c'; PlanType = '' } | Should -Be 'a@b.c'
        Get-WtChatGptAccountStateLabel -Auth @{ Email = ''; PlanType = 'plus' } | Should -Be ''
        Get-WtChatGptAccountStateLabel -Auth $null | Should -Be ''
    }

    It 'still masks the api key and never shows it' {
        $rows = @(Get-WtAssistantSettingsRows -Settings ([PSCustomObject]@{
                    AssistantEndpoint = ''; AssistantModel = ''; AssistantApiKey = 'blob'; AssistantNumCtx = ''; AssistantAuthMode = ''
                }))
        ($rows | Where-Object { [string]$_.Data.Setting -eq 'ApiKey' }).StateLabel | Should -Be '****'
    }
}

Describe 'the ChatGPT model catalog' {
    It 'offers a non-empty curated list, since the backend has no models endpoint' {
        $models = @(Get-WtChatGptModelCatalog)
        $models.Count | Should -BeGreaterThan 0
        foreach ($model in $models) { [string]$model | Should -Not -BeNullOrEmpty }
    }

    It 'has no duplicates' {
        $models = @(Get-WtChatGptModelCatalog)
        (@($models | Sort-Object -Unique)).Count | Should -Be $models.Count
    }
}

Describe 'the sign-in cancel key' {
    It 'reports Esc and drains the other keys that were waiting' {
        $queue = New-Object System.Collections.Generic.Queue[object]
        $queue.Enqueue([PSCustomObject]@{ Key = [ConsoleKey]::A })
        $queue.Enqueue([PSCustomObject]@{ Key = [ConsoleKey]::Escape })
        $available = { return ($queue.Count -gt 0) }.GetNewClosure()
        $read = { return $queue.Dequeue() }.GetNewClosure()
        Test-WtOAuthCancelKey -KeyAvailable $available -ReadKey $read | Should -BeTrue
        $queue.Count | Should -Be 0
    }

    It 'is false when nothing is waiting or nothing was Esc' {
        Test-WtOAuthCancelKey -KeyAvailable { $false } -ReadKey { throw 'must not read' } | Should -BeFalse
        $one = New-Object System.Collections.Generic.Queue[object]
        $one.Enqueue([PSCustomObject]@{ Key = [ConsoleKey]::Enter })
        $available = { return ($one.Count -gt 0) }.GetNewClosure()
        $read = { return $one.Dequeue() }.GetNewClosure()
        Test-WtOAuthCancelKey -KeyAvailable $available -ReadKey $read | Should -BeFalse
    }

    It 'never throws when the console cannot be read' {
        Test-WtOAuthCancelKey -KeyAvailable { throw 'no console' } -ReadKey { } | Should -BeFalse
    }
}

Describe 'the ChatGPT model catalog contents' {
    It 'offers the documented ChatGPT-account model ids' {
        $models = @(Get-WtChatGptModelCatalog)
        $models | Should -Contain 'gpt-5.6-terra'
        $models | Should -Contain 'gpt-5.6-luna'
        $models | Should -Contain 'gpt-5.3-codex-spark'
        $models | Should -Contain 'gpt-5.6-sol'
        $models | Should -Contain 'gpt-6-astra'
    }

    It 'offers none of the ids the Codex backend refuses for a ChatGPT account' {
        $models = @(Get-WtChatGptModelCatalog)
        foreach ($refused in @('gpt-5', 'gpt-5-codex', 'gpt-5.4', 'gpt-5.4-mini', 'gpt-5.1-codex-mini', 'gpt-5.2-codex')) {
            $models | Should -Not -Contain $refused
        }
    }
}

Describe 'the model choices for the active identity' {
    It 'returns the catalog in ChatGPT mode without asking any endpoint' {
        $calls = New-Object System.Collections.Generic.List[object]
        $get = { param($E, $K) $calls.Add($E); return @{ Ok = $true; Models = @('remote-1'); ErrorText = '' } }.GetNewClosure()
        $r = Get-WtAssistantModelChoices -GetModels $get -Settings ([PSCustomObject]@{
                AssistantEndpoint = 'http://x/v1'; AssistantApiKey = ''; AssistantAuthMode = 'ChatGPT'
            })
        $r.Ok | Should -BeTrue
        @($r.Models) | Should -Be @(Get-WtChatGptModelCatalog)
        $r.HintKey | Should -Be 'AsChatGptModelHint'
        $calls.Count | Should -Be 0
    }

    It 'asks the endpoint when no mode is set' {
        $calls = New-Object System.Collections.Generic.List[object]
        $get = { param($E, $K) $calls.Add($E); return @{ Ok = $true; Models = @('remote-1'); ErrorText = '' } }.GetNewClosure()
        $r = Get-WtAssistantModelChoices -GetModels $get -Settings ([PSCustomObject]@{
                AssistantEndpoint = 'http://x/v1'; AssistantApiKey = ''; AssistantAuthMode = ''
            })
        @($r.Models) | Should -Be @('remote-1')
        $r.HintKey | Should -Be ''
        $calls[0] | Should -Be 'http://x/v1'
    }

    It 'refuses without an endpoint when no mode is set, and never calls out' {
        $calls = New-Object System.Collections.Generic.List[object]
        $get = { param($E, $K) $calls.Add($E); return @{ Ok = $true; Models = @('remote-1'); ErrorText = '' } }.GetNewClosure()
        $r = Get-WtAssistantModelChoices -GetModels $get -Settings ([PSCustomObject]@{
                AssistantEndpoint = ''; AssistantApiKey = ''; AssistantAuthMode = ''
            })
        $r.Ok | Should -BeFalse
        $calls.Count | Should -Be 0
    }
}

Describe 'the privacy gate in ChatGPT mode' {
    BeforeEach { $script:WtAssistantPrivacyEndpoint = '' }
    AfterAll { $script:WtAssistantPrivacyEndpoint = '' }

    It 'still asks when the stale saved endpoint is local, because the data goes to ChatGPT' {
        $asked = New-Object System.Collections.Generic.List[object]
        $ask = { param($Lines, $Prompt) $asked.Add($Lines); [string](Get-WtAnswerLetter -Kind 'Yes') }
        $s = [PSCustomObject]@{ AssistantEndpoint = 'http://localhost:1234/v1'; AssistantModel = 'm'; AssistantApiKey = ''; AssistantAuthMode = 'ChatGPT' }
        Invoke-WtAssistantPrivacyGate -Settings $s -Breadcrumb 'x' -ReadAnswer $ask `
            -ReadPermissions { @{ v = 1; always = @(); endpoints = @() } } -SavePermissions { param($P) } | Should -BeTrue
        $asked.Count | Should -Be 1
    }

    It 'remembers the consent against the ChatGPT backend, not the stale endpoint' {
        $saved = New-Object System.Collections.Generic.List[object]
        $save = { param($P) $saved.Add($P) }
        $s = [PSCustomObject]@{ AssistantEndpoint = 'http://localhost:1234/v1'; AssistantModel = 'm'; AssistantApiKey = ''; AssistantAuthMode = 'ChatGPT' }
        $null = Invoke-WtAssistantPrivacyGate -Settings $s -Breadcrumb 'x' `
            -ReadAnswer { param($Lines, $Prompt) [string](Get-WtAnswerLetter -Kind 'Yes') } `
            -ReadPermissions { @{ v = 1; always = @(); endpoints = @() } } -SavePermissions $save
        $script:WtAssistantPrivacyEndpoint | Should -Be ((Get-WtChatGptOAuthConfig).ApiBase)
        (@($saved[0].endpoints) | ForEach-Object { [string]$_.endpoint }) -join ',' | Should -Match 'chatgpt\.com'
    }

    It 'still skips the question for a local endpoint when no mode is set' {
        $asked = New-Object System.Collections.Generic.List[object]
        $ask = { param($Lines, $Prompt) $asked.Add($Lines); 'e' }
        $s = [PSCustomObject]@{ AssistantEndpoint = 'http://localhost:1234/v1'; AssistantModel = 'm'; AssistantApiKey = ''; AssistantAuthMode = '' }
        Invoke-WtAssistantPrivacyGate -Settings $s -Breadcrumb 'x' -ReadAnswer $ask `
            -ReadPermissions { @{ v = 1; always = @(); endpoints = @() } } -SavePermissions { param($P) } | Should -BeTrue
        $asked.Count | Should -Be 0
    }
}

Describe 'the ChatGPT sign-in gate' {
    BeforeAll { $script:SavedLangGate = $script:Language }
    AfterAll { $script:Language = $script:SavedLangGate }

    It 'asks for a typed confirmation before any sign-in starts' {
        $def = (Get-Command Invoke-WtAssistantSettingsScreen).Definition
        $def.Contains('Confirm-WtDestructiveAction') | Should -BeTrue
        $def.Contains('Invoke-WtChatGptSignIn') | Should -BeTrue
        $def.IndexOf('Confirm-WtDestructiveAction') | Should -BeLessThan $def.IndexOf('Invoke-WtChatGptSignIn')
    }

    It 'names the account risk, the liability and the api key route in both languages' {
        foreach ($lang in @('EN', 'TR')) {
            $script:Language = $lang
            $consequence = [string](Get-Translation 'AsChatGptBanConsequence')
            $lines = @(Get-WtChatGptSignInWarningLines)
            $consequence | Should -Not -BeNullOrEmpty -Because "$lang states what OpenAI may do"
            $lines.Count | Should -BeGreaterThan 2
            ($lines -join ' ') | Should -Match 'WinToolify'
            ($lines -join ' ') | Should -Match 'API'
        }
    }
}
