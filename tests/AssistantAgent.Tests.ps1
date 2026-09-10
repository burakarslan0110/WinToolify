#Requires -Modules Pester

<#
.SYNOPSIS
    The agent loop with a scripted fake client: tool rounds, message-array
    discipline (assistant+tool_calls followed by paired tool replies), the
    round cap, trimming order and half-turn cleanup. No network, no tools.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath

    function New-WtOkResult { param([string]$Content = '', [array]$Calls = @())
        return @{ Ok = $true; Content = $Content; ToolCalls = @($Calls); FinishReason = $(if (@($Calls).Count -gt 0) { 'tool_calls' } else { 'stop' }); ErrorKind = ''; ErrorText = ''; Cancelled = $false }
    }
    function New-WtCall { param([string]$Id, [string]$Name, [string]$Arguments = '{}')
        return [PSCustomObject]@{ Id = $Id; Name = $Name; Arguments = $Arguments }
    }
}

Describe 'Invoke-WtAssistantTurn' {
    It 'fires -OnToolStart once per call, before Dispatch' {
        $script:Seq = @()
        $conversation = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $client = { param($Messages, $R)
            $script:round++
            if ($script:round -eq 1) { return @{ Ok = $true; Content = ''; ToolCalls = @(@{ Id = 'c1'; Name = 'read_system'; Arguments = '{"topic":"overview"}' }); FinishReason = 'tool_calls'; ErrorKind = ''; ErrorText = ''; Cancelled = $false } }
            return @{ Ok = $true; Content = 'done'; ToolCalls = @(); FinishReason = 'stop'; ErrorKind = ''; ErrorText = ''; Cancelled = $false }
        }
        $script:round = 0
        $r = Invoke-WtAssistantTurn -Conversation $conversation -UserText 'q' -Client $client `
            -Dispatch { param($n, $a) $script:Seq += @('dispatch'); '{}' } `
            -OnToolStart { param($n, $a) $script:Seq += @('start:' + $n + ':' + $a) }
        $r.Ok | Should -BeTrue
        $script:Seq | Should -Be @('start:read_system:{"topic":"overview"}', 'dispatch')
    }

    It 'runs a tool round, appends the paired messages and finishes' {
        $conversation = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $script:Round = 0
        $client = { param($Messages, $Round)
            $script:Round++
            if ($script:Round -eq 1) { return (New-WtOkResult -Calls @((New-WtCall -Id 'c1' -Name 'get_system_overview'))) }
            return (New-WtOkResult -Content 'iste cevap')
        }
        $script:Dispatched = @()
        $dispatch = { param($Name, $ArgsJson) $script:Dispatched += $Name; '{"ok":true}' }
        $script:Traces = @()
        $r = Invoke-WtAssistantTurn -Conversation $conversation -UserText 'soru' -Client $client -Dispatch $dispatch -OnTrace { param($Name, $ArgsJson) $script:Traces += $Name }
        $r.Ok | Should -BeTrue
        $r.FinalText | Should -Be 'iste cevap'
        $r.Rounds | Should -Be 2
        $script:Dispatched | Should -Be @('get_system_overview')
        $script:Traces | Should -Be @('get_system_overview')
        $roles = @($conversation.Messages | ForEach-Object { [string]$_.role })
        $roles | Should -Be @('user', 'assistant', 'tool', 'assistant')
        $conversation.Messages[1].tool_calls[0].id | Should -Be 'c1'
        $conversation.Messages[2].tool_call_id | Should -Be 'c1'
        $conversation.Messages[2].name | Should -Be 'get_system_overview'
    }

    It 'sends the system prompt first on every round but never stores it' {
        $conversation = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $script:FirstRoles = $null
        $client = { param($Messages, $Round)
            if ($null -eq $script:FirstRoles) { $script:FirstRoles = @($Messages | ForEach-Object { [string]$_.role }) }
            New-WtOkResult -Content 'x'
        }
        $null = Invoke-WtAssistantTurn -Conversation $conversation -UserText 'q' -Client $client -Dispatch { param($n, $a) '{}' } -SystemPrompt 'SYS'
        $script:FirstRoles[0] | Should -Be 'system'
        @($conversation.Messages | Where-Object { $_.role -eq 'system' }).Count | Should -Be 0
    }

    It 'hits the round cap and forces a final answer with Round greater than MaxRounds' {
        $conversation = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $script:Rounds = @()
        $client = { param($Messages, $Round)
            $script:Rounds += $Round
            if ($Round -le 2) { return (New-WtOkResult -Calls @((New-WtCall -Id "c$Round" -Name 'get_recent_errors'))) }
            New-WtOkResult -Content 'zorunlu final'
        }
        $r = Invoke-WtAssistantTurn -Conversation $conversation -UserText 'q' -Client $client -Dispatch { param($n, $a) '{}' } -MaxRounds 2
        $r.Ok | Should -BeTrue
        $r.FinalText | Should -Be 'zorunlu final'
        $script:Rounds | Should -Be @(1, 2, 3)
    }

    It 'strips the half-open tool turn when the client dies mid-loop, and takes this turn''s user message back with it' {
        $conversation = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $script:Round = 0
        $client = { param($Messages, $Round)
            $script:Round++
            if ($script:Round -eq 1) { return (New-WtOkResult -Calls @((New-WtCall -Id 'c1' -Name 'web_search'))) }
            @{ Ok = $false; Content = ''; ToolCalls = @(); FinishReason = ''; ErrorKind = 'Server'; ErrorText = 'patladi'; Cancelled = $false }
        }
        $r = Invoke-WtAssistantTurn -Conversation $conversation -UserText 'q' -Client $client -Dispatch { param($n, $a) '{}' }
        $r.Ok | Should -BeFalse
        $r.ErrorText | Should -Be 'patladi'
        @($conversation.Messages | ForEach-Object { [string]$_.role }) | Should -Be @()
        $conversation.Messages[-1].role | Should -Not -Be 'user'
        $conversation.Messages.Count | Should -Be 0
    }

    It 'an exception inside a dispatch entry becomes an error result for the model, not a crash' {
        $conversation = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $script:Round = 0
        $client = { param($Messages, $Round)
            $script:Round++
            if ($script:Round -eq 1) { return (New-WtOkResult -Calls @((New-WtCall -Id 'c1' -Name 'get_storage_health'))) }
            New-WtOkResult -Content 'done'
        }
        $r = Invoke-WtAssistantTurn -Conversation $conversation -UserText 'q' -Client $client -Dispatch { param($n, $a) throw ('C:\Users\Burak\secret on BURAK-PC') }
        $r.Ok | Should -BeTrue
        $error1 = [string]$conversation.Messages[2].content
        $error1 | Should -Match 'get_storage_health'
        $error1 | Should -Not -Match 'BURAK-PC'
        $error1 | Should -Not -Match ([regex]::Escape('C:\Users\Burak'))
    }

    It 'reports the dropped history out of the loop so the screen can say history was trimmed' {
        $conversation = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        for ($i = 1; $i -le 6; $i++) {
            $conversation.Messages.Add(@{ role = 'user'; content = ('eski soru ' + $i + ' ' + ('x' * 20000)) })
            $conversation.Messages.Add(@{ role = 'assistant'; content = ('eski cevap ' + $i) })
        }
        $r = Invoke-WtAssistantTurn -Conversation $conversation -UserText 'yeni soru' `
            -Client { param($Messages, $Round) New-WtOkResult -Content 'cevap' } -Dispatch { param($n, $a) '{}' }
        $r.Ok | Should -BeTrue
        $r.Dropped | Should -BeGreaterThan 0
    }

    It 'reports zero dropped blocks for a conversation that fits' {
        $conversation = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $r = Invoke-WtAssistantTurn -Conversation $conversation -UserText 'kisa soru' `
            -Client { param($Messages, $Round) New-WtOkResult -Content 'cevap' } -Dispatch { param($n, $a) '{}' }
        $r.Dropped | Should -Be 0
    }

    It 'keeps the message array well-formed even when -OnTrace itself throws' {
        $conversation = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $script:Round = 0
        $client = { param($Messages, $Round)
            $script:Round++
            if ($script:Round -eq 1) { return (New-WtOkResult -Calls @((New-WtCall -Id 'c1' -Name 'get_system_overview'), (New-WtCall -Id 'c2' -Name 'get_recent_errors'))) }
            New-WtOkResult -Content 'tamamlandi'
        }
        $r = Invoke-WtAssistantTurn -Conversation $conversation -UserText 'q' -Client $client -Dispatch { param($n, $a) '{"ok":true}' } -OnTrace { param($n, $a) throw 'trace patladi' }
        $r.Ok | Should -BeTrue
        $r.FinalText | Should -Be 'tamamlandi'
        $roles = @($conversation.Messages | ForEach-Object { [string]$_.role })
        $roles | Should -Be @('user', 'assistant', 'tool', 'tool', 'assistant')
        $conversation.Messages[2].tool_call_id | Should -Be 'c1'
        $conversation.Messages[3].tool_call_id | Should -Be 'c2'
    }

    It 'reports every dispatched call through -OnToolDone with seconds, chars and the error flag' {
        $conversation = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $script:Round = 0
        $client = { param($Messages, $Round)
            $script:Round++
            if ($script:Round -eq 1) { return (New-WtOkResult -Calls @((New-WtCall -Id 'c1' -Name 'get_system_overview'), (New-WtCall -Id 'c2' -Name 'apply_wintoolify'))) }
            New-WtOkResult -Content 'ok'
        }
        $script:Done = @()
        $null = Invoke-WtAssistantTurn -Conversation $conversation -UserText 'q' -Client $client `
            -Dispatch { param($n, $a) if ($n -eq 'get_system_overview') { 'os: Windows 10' } else { "error: tool failed: apply_wintoolify`ndetail: user declined" } } `
            -OnToolDone { param($Name, $Seconds, $Chars, $Ok) $script:Done += @(@{ Name = $Name; Seconds = $Seconds; Chars = $Chars; Ok = $Ok }) }
        @($script:Done).Count | Should -Be 2
        $script:Done[0].Name | Should -Be 'get_system_overview'
        $script:Done[0].Ok | Should -BeTrue
        $script:Done[0].Chars | Should -Be 14
        $script:Done[1].Ok | Should -BeFalse
        ($script:Done[0].Seconds -is [double]) | Should -BeTrue
    }

    It 'defaults to five rounds and passes HistoryMaxChars / KeepToolTurns through to the trimmer' {
        $script:round = 0
        $client = { param($Messages, $R) $script:round++; @{ Ok = $true; Content = ''; ToolCalls = @(@{ Id = 'c' + $script:round; Name = 'read_system'; Arguments = '{"topic":"overview","filter":"' + $script:round + '"}' }); FinishReason = 'tool_calls'; ErrorKind = ''; ErrorText = ''; Cancelled = $false } }
        $conversation = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $r = Invoke-WtAssistantTurn -Conversation $conversation -UserText 'q' -Client $client -Dispatch { param($n, $a) 'x' }
        $r.Rounds | Should -Be 6
        $conversation.Messages.Add(@{ role = 'user'; content = ('z' * 500) })
        $conversation.Messages.Add(@{ role = 'assistant'; content = 'ok' })
        $r2 = Invoke-WtAssistantTurn -Conversation $conversation -UserText 'q2' -Client { param($M, $R) @{ Ok = $true; Content = 'done'; ToolCalls = @(); FinishReason = 'stop'; ErrorKind = ''; ErrorText = ''; Cancelled = $false } } -Dispatch { param($n, $a) 'x' } -HistoryMaxChars 300
        $r2.Dropped | Should -BeGreaterThan 0
    }
}

Describe 'Get-WtAssistantTrimmedMessages' {
    It 'stubs every tool body outside the CURRENT turn with a digest, shrinks the call arguments, then drops the oldest pair over the cap' {
        $searchBody = "rows:`n  id | label | state | risk`n  Services:DiagTrack | DiagTrack | on | S`n  Telemetry:SetDiagnosticDataMinimal | Tanilama | off | S`nmore: 40 (X 3) - narrow with section="
        $messages = @(
            @{ role = 'user'; content = 'q1' }
            @{ role = 'assistant'; content = $null; tool_calls = @(@{ id = 'c1'; type = 'function'; 'function' = @{ name = 'search_wintoolify'; arguments = '{"query":"telemetri","section":"HardeningPrivacy","detail":false}' } }) }
            @{ role = 'tool'; tool_call_id = 'c1'; name = 'search_wintoolify'; content = $searchBody }
            @{ role = 'assistant'; content = 'a1' }
            @{ role = 'user'; content = 'q2' }
            @{ role = 'assistant'; content = $null; tool_calls = @(@{ id = 'c2'; type = 'function'; 'function' = @{ name = 'read_system'; arguments = '{"topic":"overview"}' } }) }
            @{ role = 'tool'; tool_call_id = 'c2'; name = 'read_system'; content = "os: Windows 10`ncpu: x" }
        )
        $r = Get-WtAssistantTrimmedMessages -Messages $messages
        $r.StubbedTools | Should -Be 1
        $r.Messages[2].content | Should -Match '^\[tool result cleared: search_wintoolify\(\{"query":"telemetri","section":"[A-Za-z]*~\) -> Services:DiagTrack; Telemetry:SetDiagnosticDataMinimal\]$'
        ([string]$r.Messages[2].content).Length | Should -BeLessOrEqual 200
        ([string]$r.Messages[1].tool_calls[0].'function'.arguments).Length | Should -BeLessOrEqual 60
        $messages[1].tool_calls[0].'function'.arguments | Should -Match 'detail'   # the original is untouched
        $r.Messages[6].content | Should -Be "os: Windows 10`ncpu: x"   # current turn stays whole
        (Get-WtAssistantToolResultDigest -Name 'read_system' -Content "os: Windows 10`ncpu: x") | Should -Be 'os: Windows 10'
        (Get-WtAssistantToolResultDigest -Name 'x' -Content ('a' * 200)).Length | Should -Be 120
        (Get-WtAssistantToolResultDigest -Name 'suggest_wintoolify' -Content "1: Services:DiagTrack`n2: Telemetry:X`ninvalid: Nope") | Should -Be '1: Services:DiagTrack; 2: Telemetry:X'
        $nine = (@(1..9 | ForEach-Object { [string]$_ + ': Winget:Vendor.Package' + $_ }) -join "`n")
        $nineDigest = Get-WtAssistantToolResultDigest -Name 'suggest_wintoolify' -Content $nine
        $nineDigest | Should -Match '; 9: Winget:Vendor\.Package9$'
        $nineDigest | Should -Not -Match '~'
        $tiny = Get-WtAssistantTrimmedMessages -Messages $messages -MaxChars 60
        $tiny.DroppedPairs | Should -BeGreaterThan 0
    }

    It 'keeps every tool body of the current user turn whole, however many tool rounds it took' {
        $messages = @(
            @{ role = 'user'; content = 'bilgisayarim yavasladi' }
            @{ role = 'assistant'; content = $null; tool_calls = @(@{ id = 'a'; type = 'function'; 'function' = @{ name = 'get_system_overview'; arguments = '{}' } }) }
            @{ role = 'tool'; tool_call_id = 'a'; name = 'get_system_overview'; content = ('{"disk_free_gb":322}' + ('x' * 2000)) }
            @{ role = 'assistant'; content = $null; tool_calls = @(@{ id = 'b'; type = 'function'; 'function' = @{ name = 'search_wintoolify_tools'; arguments = '{}' } }) }
            @{ role = 'tool'; tool_call_id = 'b'; name = 'search_wintoolify_tools'; content = '{"tools":[]}' }
            @{ role = 'assistant'; content = $null; tool_calls = @(@{ id = 'c'; type = 'function'; 'function' = @{ name = 'suggest_wintoolify_tools'; arguments = '{}' } }) }
            @{ role = 'tool'; tool_call_id = 'c'; name = 'suggest_wintoolify_tools'; content = '{"registered":1}' }
        )
        $r = Get-WtAssistantTrimmedMessages -Messages $messages -MaxChars 60000
        $r.StubbedTools | Should -Be 0
        $r.Messages[2].content | Should -Match 'disk_free_gb'
    }

    It 'counts kept turns in user messages, so an older turn with two tool rounds is stubbed as one unit' {
        $messages = @(
            @{ role = 'user'; content = 'ilk soru' }
            @{ role = 'assistant'; content = $null; tool_calls = @(@{ id = 'a'; type = 'function'; 'function' = @{ name = 'get_system_overview'; arguments = '{}' } }) }
            @{ role = 'tool'; tool_call_id = 'a'; name = 'get_system_overview'; content = ('x' * 3000) }
            @{ role = 'assistant'; content = $null; tool_calls = @(@{ id = 'b'; type = 'function'; 'function' = @{ name = 'get_storage_health'; arguments = '{}' } }) }
            @{ role = 'tool'; tool_call_id = 'b'; name = 'get_storage_health'; content = ('y' * 3000) }
            @{ role = 'assistant'; content = 'ilk cevap' }
            @{ role = 'user'; content = 'ikinci soru' }
            @{ role = 'assistant'; content = $null; tool_calls = @(@{ id = 'c'; type = 'function'; 'function' = @{ name = 'web_search'; arguments = '{}' } }) }
            @{ role = 'tool'; tool_call_id = 'c'; name = 'web_search'; content = ('z' * 3000) }
            @{ role = 'assistant'; content = 'ikinci cevap' }
        )
        $r = Get-WtAssistantTrimmedMessages -Messages $messages -MaxChars 60000 -KeepToolTurns 1
        $r.StubbedTools | Should -Be 2
        $r.Messages[2].content | Should -Match 'get_system_overview'
        $r.Messages[4].content | Should -Match 'get_storage_health'
        $r.Messages[8].content.Length | Should -Be 3000
    }
}

Describe 'Get-WtAssistantCallKey' {
    It 'is canonical: whitespace inside the JSON and key order do not matter, but values do' {
        $base = Get-WtAssistantCallKey -Name 'search_wintoolify' -Arguments '{"query":"x"}'
        (Get-WtAssistantCallKey -Name 'search_wintoolify' -Arguments '{"query": "x"}') | Should -Be $base
        (Get-WtAssistantCallKey -Name 'search_wintoolify' -Arguments '{ "query" :"x" }') | Should -Be $base
        $orderA = Get-WtAssistantCallKey -Name 'search_wintoolify' -Arguments '{"b":1,"a":2}'
        $orderB = Get-WtAssistantCallKey -Name 'search_wintoolify' -Arguments '{"a":2,"b":1}'
        $orderA | Should -Be $orderB
        (Get-WtAssistantCallKey -Name 'search_wintoolify' -Arguments '{"query":"y"}') | Should -Not -Be $base
    }
}

Describe 'Invoke-WtAssistantTurn trimming inside one turn' {
    It 'the model still sees the round-1 tool output when it writes the answer in round 4' {
        $conversation = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $script:Round = 0
        $script:SeenToolBodies = $null
        $client = { param($Messages, $Round)
            $script:Round++
            if ($script:Round -le 3) { return (New-WtOkResult -Calls @((New-WtCall -Id ('c' + $script:Round) -Name ('tool' + $script:Round)))) }
            $script:SeenToolBodies = @($Messages | Where-Object { [string]$_.role -eq 'tool' } | ForEach-Object { [string]$_.content })
            return (New-WtOkResult -Content 'cevap')
        }
        $dispatch = { param($Name, $ArgsJson) ('{"from":"' + $Name + '","disk_free_gb":322}') }
        $r = Invoke-WtAssistantTurn -Conversation $conversation -UserText 'soru' -Client $client -Dispatch $dispatch
        $r.Ok | Should -BeTrue
        $r.Rounds | Should -Be 4
        @($script:SeenToolBodies).Count | Should -Be 3
        $script:SeenToolBodies[0] | Should -Match 'tool1'
        $script:SeenToolBodies[0] | Should -Match 'disk_free_gb'
    }
}

Describe 'Remove-WtAssistantOpenToolTurn' {
    It 'peels trailing tool replies and the unanswered assistant call' {
        $list = New-Object System.Collections.Generic.List[object]
        $list.Add(@{ role = 'user'; content = 'q' })
        $list.Add(@{ role = 'assistant'; content = 'tamamlanmis cevap' })
        $list.Add(@{ role = 'assistant'; content = $null; tool_calls = @(@{ id = 'z' }) })
        $list.Add(@{ role = 'tool'; tool_call_id = 'z'; name = 'x'; content = '{}' })
        Remove-WtAssistantOpenToolTurn -Messages $list
        @($list | ForEach-Object { [string]$_.role }) | Should -Be @('user', 'assistant')
        $list[1].content | Should -Be 'tamamlanmis cevap'
    }
}

Describe 'Invoke-WtAssistantTurn: the per-turn tool budget' {
    It 'stops dispatching once the budget is spent and tells the model why' {
        $conversation = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $script:Dispatched = @()
        $client = { param($Messages, $Round)
            if ($Round -eq 1) {
                return (New-WtOkResult -Calls @(
                    (New-WtCall -Id 'c1' -Name 'analyze_minidump'),
                    (New-WtCall -Id 'c2' -Name 'web_search'),
                    (New-WtCall -Id 'c3' -Name 'fetch_page')))
            }
            return (New-WtOkResult -Content 'elimdekiyle cevap')
        }
        $script:Ticks = 0
        $elapsed = { $script:Ticks++; if ($script:Ticks -le 1) { 0 } else { 999 } }
        $r = Invoke-WtAssistantTurn -Conversation $conversation -UserText 'soru' -Client $client `
            -Dispatch { param($Name, $ArgsJson) $script:Dispatched += $Name; '{"ok":true}' } `
            -ToolBudgetSeconds 180 -ElapsedSeconds $elapsed
        $r.Ok | Should -BeTrue
        $script:Dispatched | Should -Be @('analyze_minidump')
        $replies = @($conversation.Messages | Where-Object { [string]$_.role -eq 'tool' })
        @($replies).Count | Should -Be 3
        [string]$replies[0].content | Should -Be '{"ok":true}'
        foreach ($i in 1, 2) {
            ([string]$replies[$i].content).IndexOf('time budget exhausted', [System.StringComparison]::Ordinal) | Should -BeGreaterThan -1
        }
        @($replies | ForEach-Object { [string]$_.tool_call_id }) | Should -Be @('c1', 'c2', 'c3')
    }

    It 'the budget spans rounds, not just one round' {
        $conversation = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $script:Dispatched = @()
        $client = { param($Messages, $Round)
            if ($Round -le 2) { return (New-WtOkResult -Calls @((New-WtCall -Id "c$Round" -Name 'web_search'))) }
            return (New-WtOkResult -Content 'son')
        }
        $script:Ticks = 0
        $elapsed = { $script:Ticks++; if ($script:Ticks -le 1) { 0 } else { 999 } }
        $null = Invoke-WtAssistantTurn -Conversation $conversation -UserText 'q' -Client $client `
            -Dispatch { param($Name, $ArgsJson) $script:Dispatched += $Name; '{}' } `
            -MaxRounds 4 -ToolBudgetSeconds 60 -ElapsedSeconds $elapsed
        @($script:Dispatched).Count | Should -Be 1
    }

    It 'a budget-refused call is not traced as if it had run' {
        $conversation = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $script:Traces = @()
        $client = { param($Messages, $Round)
            if ($Round -eq 1) { return (New-WtOkResult -Calls @((New-WtCall -Id 'c1' -Name 'web_search'))) }
            return (New-WtOkResult -Content 'x')
        }
        $null = Invoke-WtAssistantTurn -Conversation $conversation -UserText 'q' -Client $client `
            -Dispatch { param($Name, $ArgsJson) '{}' } -OnTrace { param($Name, $ArgsJson) $script:Traces += $Name } `
            -ToolBudgetSeconds 1 -ElapsedSeconds { 5000 }
        @($script:Traces).Count | Should -Be 0
    }

    It 'a zero or negative budget disables the check entirely' {
        $conversation = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $script:Dispatched = @()
        $client = { param($Messages, $Round)
            if ($Round -eq 1) { return (New-WtOkResult -Calls @((New-WtCall -Id 'c1' -Name 'web_search'))) }
            return (New-WtOkResult -Content 'x')
        }
        $null = Invoke-WtAssistantTurn -Conversation $conversation -UserText 'q' -Client $client `
            -Dispatch { param($Name, $ArgsJson) $script:Dispatched += $Name; '{}' } `
            -ToolBudgetSeconds 0 -ElapsedSeconds { 999999 }
        $script:Dispatched | Should -Be @('web_search')
    }

    It 'an ordinary turn is untouched: the default budget refuses nothing' {
        $conversation = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $script:Dispatched = @()
        $client = { param($Messages, $Round)
            if ($Round -eq 1) { return (New-WtOkResult -Calls @((New-WtCall -Id 'c1' -Name 'get_system_overview'), (New-WtCall -Id 'c2' -Name 'web_search'))) }
            return (New-WtOkResult -Content 'cevap')
        }
        $r = Invoke-WtAssistantTurn -Conversation $conversation -UserText 'q' -Client $client `
            -Dispatch { param($Name, $ArgsJson) $script:Dispatched += $Name; '{}' }
        $r.Ok | Should -BeTrue
        $script:Dispatched | Should -Be @('get_system_overview', 'web_search')
    }
}

Describe 'Invoke-WtAssistantTurn: per-turn call caps and exact repeats, so one question cannot fire five web searches' {
    It 'the third web_search of a turn is refused with a call-limit reply and never dispatched, across rounds' {
        $conversation = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $script:Dispatched = @()
        $script:Started = @()
        $client = { param($Messages, $Round)
            if ($Round -le 3) { return (New-WtOkResult -Calls @((New-WtCall -Id "c$Round" -Name 'web_search' -Arguments ('{"query":"q' + $Round + '"}')))) }
            return (New-WtOkResult -Content 'cevap')
        }
        $r = Invoke-WtAssistantTurn -Conversation $conversation -UserText 'soru' -Client $client `
            -Dispatch { param($Name, $ArgsJson) $script:Dispatched += $Name; '{"results":[]}' } `
            -OnToolStart { param($Name, $ArgsJson) $script:Started += $Name }
        $r.Ok | Should -BeTrue
        $script:Dispatched | Should -Be @('web_search', 'web_search')
        $script:Started | Should -Be @('web_search', 'web_search')
        $replies = @($conversation.Messages | Where-Object { [string]$_.role -eq 'tool' })
        @($replies).Count | Should -Be 3
        ([string]$replies[2].content) | Should -BeLike '*call limit reached: web_search may run at most 2 times per question*'
        @($replies | ForEach-Object { [string]$_.tool_call_id }) | Should -Be @('c1', 'c2', 'c3')
    }

    It 'an exact repeat (same tool, same argument text) is refused as a repeat even under the cap; different words are not a repeat' {
        $conversation = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $script:Dispatched = @()
        $client = { param($Messages, $Round)
            if ($Round -eq 1) { return (New-WtOkResult -Calls @((New-WtCall -Id 'c1' -Name 'get_service_status' -Arguments '{"name":"DiagTrack"}'))) }
            if ($Round -eq 2) { return (New-WtOkResult -Calls @((New-WtCall -Id 'c2' -Name 'get_service_status' -Arguments ' {"name":"DiagTrack"} '), (New-WtCall -Id 'c3' -Name 'get_service_status' -Arguments '{"name":"wuauserv"}'))) }
            return (New-WtOkResult -Content 'x')
        }
        $null = Invoke-WtAssistantTurn -Conversation $conversation -UserText 'q' -Client $client `
            -Dispatch { param($Name, $ArgsJson) $script:Dispatched += $ArgsJson; '{}' }
        @($script:Dispatched) | Should -Be @('{"name":"DiagTrack"}', '{"name":"wuauserv"}')
        $replies = @($conversation.Messages | Where-Object { [string]$_.role -eq 'tool' })
        ([string]$replies[1].content) | Should -BeLike '*repeated call: get_service_status already ran with these exact arguments*'
        ([string]$replies[2].content) | Should -Be '{}'
    }

    It 'the loop uses the CANONICAL key: different whitespace and key order refuse a repeat, a different value does not' {
        $conversation = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $script:Dispatched = @()
        $client = { param($Messages, $Round)
            if ($Round -eq 1) { return (New-WtOkResult -Calls @((New-WtCall -Id 'c1' -Name 'read_system' -Arguments '{"topic":"overview","filter":"x"}'))) }
            if ($Round -eq 2) { return (New-WtOkResult -Calls @((New-WtCall -Id 'c2' -Name 'read_system' -Arguments '{"filter": "x", "topic":"overview"}'))) }
            if ($Round -eq 3) { return (New-WtOkResult -Calls @((New-WtCall -Id 'c3' -Name 'read_system' -Arguments '{"topic":"overview","filter":"y"}'))) }
            return (New-WtOkResult -Content 'x')
        }
        $null = Invoke-WtAssistantTurn -Conversation $conversation -UserText 'q' -Client $client `
            -Dispatch { param($Name, $ArgsJson) $script:Dispatched += $ArgsJson; '{}' }
        @($script:Dispatched) | Should -Be @('{"topic":"overview","filter":"x"}', '{"topic":"overview","filter":"y"}')
        $replies = @($conversation.Messages | Where-Object { [string]$_.role -eq 'tool' })
        $replies.Count | Should -Be 3
        ([string]$replies[1].content) | Should -BeLike '*repeated call: read_system already ran with these exact arguments*'
        ([string]$replies[2].content) | Should -Be '{}'
    }

    It 'the total cap (*) stops a turn that keeps calling different read tools; a $null caps table disables all of it' {
        $conversation = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $script:Dispatched = @()
        $client = { param($Messages, $Round)
            if ($Round -le 4) { return (New-WtOkResult -Calls @((New-WtCall -Id "c$Round" -Name ('tool' + $Round)))) }
            return (New-WtOkResult -Content 'x')
        }
        $null = Invoke-WtAssistantTurn -Conversation $conversation -UserText 'q' -Client $client `
            -Dispatch { param($Name, $ArgsJson) $script:Dispatched += $Name; '{}' } -ToolCallCaps @{ '*' = 3 }
        @($script:Dispatched) | Should -Be @('tool1', 'tool2', 'tool3')
        $replies = @($conversation.Messages | Where-Object { [string]$_.role -eq 'tool' })
        ([string]$replies[3].content) | Should -BeLike '*call limit reached: at most 3 tool calls per question*'
        $conversation = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $script:Dispatched = @()
        $null = Invoke-WtAssistantTurn -Conversation $conversation -UserText 'q' -Client $client `
            -Dispatch { param($Name, $ArgsJson) $script:Dispatched += $Name; '{}' } -ToolCallCaps $null
        @($script:Dispatched).Count | Should -Be 4
    }

}

Describe 'in-text JSON tool-call recovery' {
    It 'turns fenced json blocks naming a tool from -Names into calls and strips them from the text' {
        $content = "I will check.`n" + '```json' + "`n" + '{"name":"search_wintoolify","arguments":{}}' + "`n" + '```' + "`nand`n" + '```json' + "`n" + '{"name":"read_system","arguments":{"topic":"overview"}}' + "`n" + '```' + "`ndone"
        $r = Get-WtAssistantRecoveredToolCalls -Content $content -Names @('search_wintoolify', 'read_system')
        @($r.Calls).Count | Should -Be 2
        $r.Calls[0].Name | Should -Be 'search_wintoolify'
        $r.Calls[0].Id | Should -Be 'rec_1'
        ($r.Calls[1].Arguments | ConvertFrom-Json).topic | Should -Be 'overview'
        $r.Text | Should -Not -Match 'search_wintoolify'
        $r.Text | Should -Match 'I will check'
        $r.Text | Should -Match 'done'
    }

    It 'leaves unknown names, broken json and non-object arguments as plain text, and caps at four' {
        $bad = '```json' + "`n" + '{"name":"nope","arguments":{}}' + "`n" + '```' + "`n" + '```json' + "`n" + '{"name":"search_wintoolify","arguments":"x"}' + "`n" + '```' + "`n" + '```json' + "`n" + '{broken' + "`n" + '```'
        $r = Get-WtAssistantRecoveredToolCalls -Content $bad -Names @('search_wintoolify', 'read_system')
        @($r.Calls).Count | Should -Be 0
        $r.Text | Should -Match 'nope'
        $many = (1..6 | ForEach-Object { '```json' + "`n" + '{"name":"search_wintoolify","arguments":{}}' + "`n" + '```' }) -join "`n"
        @((Get-WtAssistantRecoveredToolCalls -Content $many -Names @('search_wintoolify', 'read_system')).Calls).Count | Should -Be 4
    }

    It 'a name that is registered but was not in -Names this round is left as text' {
        $content = '```json' + "`n" + '{"name":"save_note","arguments":{}}' + "`n" + '```'
        $r = Get-WtAssistantRecoveredToolCalls -Content $content -Names @('search_wintoolify', 'read_system')
        @($r.Calls).Count | Should -Be 0
        $r.Text | Should -Match 'save_note'
    }

    It 'the loop recovers when tools were sent and no tool_calls came back, writes a synthetic tool_calls message and dispatches it' {
        $conversation = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $script:Round = 0
        $client = { param($Messages, $Round)
            $script:Round++
            if ($script:Round -eq 1) { return (New-WtOkResult -Content ('```json' + "`n" + '{"name":"search_wintoolify","arguments":{}}' + "`n" + '```')) }
            New-WtOkResult -Content 'final'
        }
        $script:Dispatched = @(); $script:Recovered = 0
        $r = Invoke-WtAssistantTurn -Conversation $conversation -UserText 'q' -Client $client -Schemas @(@{ type = 'function'; 'function' = @{ name = 'search_wintoolify' } }) `
            -Dispatch { param($n, $a) $script:Dispatched += $n; '{"ok":true}' } -OnRecovered { param($Count) $script:Recovered += $Count }
        $r.Ok | Should -BeTrue
        $script:Dispatched | Should -Be @('search_wintoolify')
        $script:Recovered | Should -Be 1
        @($conversation.Messages | ForEach-Object { [string]$_.role }) | Should -Be @('user', 'assistant', 'tool', 'assistant')
        $conversation.Messages[1].tool_calls[0].id | Should -Be 'rec1_1'
        $conversation.Messages[2].tool_call_id | Should -Be 'rec1_1'
    }

    It 'recovered ids stay unique across two recovering rounds instead of both restarting at rec_1' {
        $conversation = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $script:Round = 0
        $client = { param($Messages, $Round)
            $script:Round++
            if ($script:Round -le 2) { return (New-WtOkResult -Content ('```json' + "`n" + '{"name":"search_wintoolify","arguments":{}}' + "`n" + '```')) }
            New-WtOkResult -Content 'final'
        }
        $r = Invoke-WtAssistantTurn -Conversation $conversation -UserText 'q' -Client $client -Schemas @(@{ type = 'function'; 'function' = @{ name = 'search_wintoolify' } }) `
            -Dispatch { param($n, $a) '{"ok":true}' }
        $r.Ok | Should -BeTrue
        $ids = @($conversation.Messages | Where-Object { [string]$_.role -eq 'assistant' -and $_.tool_calls } | ForEach-Object { [string]$_.tool_calls[0].id })
        $ids | Should -Be @('rec1_1', 'rec2_1')
        (@($ids) | Select-Object -Unique).Count | Should -Be 2
    }

    It 'does not recover when no tools were sent or when -RecoverToolCalls is off' {
        $conversation = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $text = '```json' + "`n" + '{"name":"search_wintoolify","arguments":{}}' + "`n" + '```'
        $r = Invoke-WtAssistantTurn -Conversation $conversation -UserText 'q' -Client { param($M, $R) New-WtOkResult -Content $text } -Dispatch { param($n, $a) throw 'no' }
        $r.FinalText | Should -Be $text
        $conversation2 = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $r2 = Invoke-WtAssistantTurn -Conversation $conversation2 -UserText 'q' -Client { param($M, $R) New-WtOkResult -Content $text } -Schemas @(@{ type = 'function'; 'function' = @{ name = 'search_wintoolify' } }) -RecoverToolCalls $false -Dispatch { param($n, $a) throw 'no' }
        $r2.FinalText | Should -Be $text
    }
}

Describe 'system extra' {
    It 'sends a second system message only when SystemExtra is given, before the history' {
        $script:Seen = $null
        $client = { param($Messages, $Round) $script:Seen = @($Messages); New-WtOkResult -Content 'ok' }
        $conv = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $null = Invoke-WtAssistantTurn -Conversation $conv -UserText 'q' -Client $client -Dispatch { param($n, $a) '{}' } -SystemPrompt 'S0' -SystemExtra 'PROFILE'
        @($script:Seen | ForEach-Object { [string]$_.role }) | Should -Be @('system', 'system', 'user')
        $script:Seen[1].content | Should -Be 'PROFILE'
        $conv2 = @{ Messages = (New-Object System.Collections.Generic.List[object]) }
        $null = Invoke-WtAssistantTurn -Conversation $conv2 -UserText 'q' -Client $client -Dispatch { param($n, $a) '{}' } -SystemPrompt 'S0'
        @($script:Seen | ForEach-Object { [string]$_.role }) | Should -Be @('system', 'user')
        @($conv.Messages | ForEach-Object { [string]$_.role }) | Should -Not -Contain 'system'
    }
}
