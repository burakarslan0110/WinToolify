#Requires -Modules Pester

<#
.SYNOPSIS
    The OpenAI-compatible client: request body, SSE stream accumulation,
    tool-call delta merging, plain-response parsing and error mapping.
    All pure - no network anywhere in this file.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'request building' {
    It 'joins the endpoint and route without double slashes' {
        Get-WtLlmChatUri -Endpoint 'http://localhost:1234/v1' | Should -Be 'http://localhost:1234/v1/chat/completions'
        Get-WtLlmChatUri -Endpoint 'http://localhost:1234/v1/' | Should -Be 'http://localhost:1234/v1/chat/completions'
        Get-WtLlmModelsUri -Endpoint 'https://api.openai.com/v1' | Should -Be 'https://api.openai.com/v1/models'
    }

    It 'omits tools and tool_choice entirely when no tools are passed' {
        $body = ConvertTo-WtLlmRequestBody -Model 'm' -Messages @(@{ role = 'user'; content = 'hi' }) -Stream $false
        $body | Should -Not -Match '"tools"'
        $body | Should -Not -Match '"tool_choice"'
        ($body | ConvertFrom-Json).model | Should -Be 'm'
        ($body | ConvertFrom-Json).stream | Should -BeFalse
    }

    It 'carries tools with tool_choice auto by default, and an explicit override' {
        $tool = @{ type = 'function'; 'function' = @{ name = 'probe'; description = 'd'; parameters = @{ type = 'object'; properties = @{} } } }
        $auto = ConvertTo-WtLlmRequestBody -Model 'm' -Messages @(@{ role = 'user'; content = 'x' }) -Tools @($tool)
        ($auto | ConvertFrom-Json).tool_choice | Should -Be 'auto'
        $none = ConvertTo-WtLlmRequestBody -Model 'm' -Messages @(@{ role = 'user'; content = 'x' }) -Tools @($tool) -ToolChoice 'none'
        ($none | ConvertFrom-Json).tool_choice | Should -Be 'none'
        @(($auto | ConvertFrom-Json).messages).Count | Should -Be 1
    }
}

Describe 'SSE stream accumulation' {
    It 'accumulates content deltas and reports each piece' {
        $s = New-WtLlmStreamState
        $p1 = Add-WtLlmStreamLine -State $s -Line 'data: {"choices":[{"delta":{"content":"Mer"}}]}'
        $p2 = Add-WtLlmStreamLine -State $s -Line 'data: {"choices":[{"delta":{"content":"haba"}}]}'
        $null = Add-WtLlmStreamLine -State $s -Line 'data: [DONE]'
        $p1 | Should -Be 'Mer'
        $p2 | Should -Be 'haba'
        $s.Done | Should -BeTrue
        (Get-WtLlmStreamResult -State $s).Content | Should -Be 'Merhaba'
    }

    It 'merges fragmented tool_call deltas by index' {
        $s = New-WtLlmStreamState
        $null = Add-WtLlmStreamLine -State $s -Line 'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"get_sys","arguments":""}}]}}]}'
        $null = Add-WtLlmStreamLine -State $s -Line 'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"ho"}}]}}]}'
        $null = Add-WtLlmStreamLine -State $s -Line 'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"urs\":48}"}}]}}]}'
        $null = Add-WtLlmStreamLine -State $s -Line 'data: {"choices":[{"finish_reason":"tool_calls","delta":{}}]}'
        $r = Get-WtLlmStreamResult -State $s
        @($r.ToolCalls).Count | Should -Be 1
        $r.ToolCalls[0].Id | Should -Be 'call_a'
        $r.ToolCalls[0].Name | Should -Be 'get_sys'
        $r.ToolCalls[0].Arguments | Should -Be '{"hours":48}'
        $r.FinishReason | Should -Be 'tool_calls'
    }

    It 'ignores blank lines, comments and unparsable payloads without dying' {
        $s = New-WtLlmStreamState
        foreach ($line in @('', ': keep-alive', 'event: x', 'data: not-json', 'data: {"choices":[{"delta":{"content":"ok"}}]}')) {
            $null = Add-WtLlmStreamLine -State $s -Line $line
        }
        (Get-WtLlmStreamResult -State $s).Content | Should -Be 'ok'
    }

    It 'invents a stable id when a local server omits tool_call ids' {
        $s = New-WtLlmStreamState
        $null = Add-WtLlmStreamLine -State $s -Line 'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"probe","arguments":"{}"}}]}}]}'
        (Get-WtLlmStreamResult -State $s).ToolCalls[0].Id | Should -Be 'call_0'
    }
}

Describe 'plain (non-stream) response parsing' {
    It 'reads content, tool calls and finish_reason from one JSON body' {
        $json = '{"choices":[{"finish_reason":"tool_calls","message":{"content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"web_search","arguments":"{\"query\":\"x\"}"}}]}}]}'
        $r = ConvertFrom-WtLlmResponseJson -Json $json
        $r.Content | Should -Be ''
        $r.ToolCalls[0].Name | Should -Be 'web_search'
        $r.FinishReason | Should -Be 'tool_calls'
    }

    It 'returns the empty shape for garbage' {
        $r = ConvertFrom-WtLlmResponseJson -Json '<html>oops</html>'
        $r.Content | Should -Be ''
        @($r.ToolCalls).Count | Should -Be 0
    }
}

Describe 'Invoke-WtLlmChat orchestration (fake transports only)' {
    It 'streams: feeds lines through the accumulator and reports deltas' {
        $script:Deltas = @()
        $transport = { param($Request)
            & $Request.OnLine 'data: {"choices":[{"delta":{"content":"Sel"}}]}'
            & $Request.OnLine 'data: {"choices":[{"delta":{"content":"am"}}]}'
            & $Request.OnLine 'data: [DONE]'
            @{ Ok = $true; StatusCode = 200; Body = ''; Cancelled = $false; Failure = '' }
        }
        $r = Invoke-WtLlmChat -Endpoint 'http://x/v1' -Model 'm' -Messages @(@{ role = 'user'; content = 'q' }) `
            -OnDelta { param($P) $script:Deltas += $P } -Transport $transport
        $r.Ok | Should -BeTrue
        $r.Content | Should -Be 'Selam'
        ($script:Deltas -join '|') | Should -Be 'Sel|am'
    }

    It 'falls back to a plain request when the server rejects streaming' {
        $script:Bodies = @()
        $transport = { param($Request)
            $script:Bodies += [string]$Request.Body
            if ($Request.Stream) { return @{ Ok = $false; StatusCode = 400; Body = '{"error":"stream not supported"}'; Cancelled = $false; Failure = '' } }
            @{ Ok = $true; StatusCode = 200; Body = '{"choices":[{"finish_reason":"stop","message":{"content":"duz"}}]}'; Cancelled = $false; Failure = '' }
        }
        $r = Invoke-WtLlmChat -Endpoint 'http://x/v1' -Model 'm' -Messages @(@{ role = 'user'; content = 'q' }) -Transport $transport
        $r.Ok | Should -BeTrue
        $r.Content | Should -Be 'duz'
        @($script:Bodies).Count | Should -Be 2
        ($script:Bodies[0] | ConvertFrom-Json).stream | Should -BeTrue
        ($script:Bodies[1] | ConvertFrom-Json).stream | Should -BeFalse
    }

    It 'maps auth, tools-unsupported and connection failures to their kinds' {
        $t401 = { param($Request) @{ Ok = $false; StatusCode = 401; Body = 'unauthorized'; Cancelled = $false; Failure = '' } }
        $tTools = { param($Request) @{ Ok = $false; StatusCode = 400; Body = '{"error":{"message":"llama does not support tools"}}'; Cancelled = $false; Failure = '' } }
        $tConn = { param($Request) @{ Ok = $false; StatusCode = 0; Body = 'refused'; Cancelled = $false; Failure = 'Connect' } }
        $tool = @{ type = 'function'; 'function' = @{ name = 'p'; description = 'd'; parameters = @{ type = 'object'; properties = @{} } } }
        (Invoke-WtLlmChat -Endpoint 'http://x/v1' -Model 'm' -Messages @(@{ role='user'; content='q' }) -Stream $false -Transport $t401).ErrorKind | Should -Be 'Auth'
        (Invoke-WtLlmChat -Endpoint 'http://x/v1' -Model 'm' -Messages @(@{ role='user'; content='q' }) -Tools @($tool) -Stream $false -Transport $tTools).ErrorKind | Should -Be 'ToolsUnsupported'
        (Invoke-WtLlmChat -Endpoint 'http://x/v1' -Model 'm' -Messages @(@{ role='user'; content='q' }) -Stream $false -Transport $tConn).ErrorKind | Should -Be 'Connect'
    }

    It 'a 400 mentioning tools is NOT ToolsUnsupported when no tools were sent' {
        $t = { param($Request) @{ Ok = $false; StatusCode = 400; Body = 'bad function argument'; Cancelled = $false; Failure = '' } }
        (Invoke-WtLlmChat -Endpoint 'http://x/v1' -Model 'm' -Messages @(@{ role='user'; content='q' }) -Stream $false -Transport $t).ErrorKind | Should -Be 'BadRequest'
    }

    It 'surfaces a cancelled stream with the partial text' {
        $transport = { param($Request)
            & $Request.OnLine 'data: {"choices":[{"delta":{"content":"yarim"}}]}'
            @{ Ok = $false; StatusCode = 200; Body = ''; Cancelled = $true; Failure = '' }
        }
        $r = Invoke-WtLlmChat -Endpoint 'http://x/v1' -Model 'm' -Messages @(@{ role='user'; content='q' }) -Transport $transport
        $r.Cancelled | Should -BeTrue
        $r.Ok | Should -BeFalse
        $r.Content | Should -Be 'yarim'
    }

    It 'error text resolves through translations in both languages' {
        $old = $script:Language
        try {
            foreach ($lang in 'EN', 'TR') {
                $script:Language = $lang
                foreach ($kind in 'Connect', 'Timeout', 'Auth', 'NotFound', 'RateLimit', 'ToolsUnsupported', 'BadRequest', 'Server', 'Unknown') {
                    Get-WtLlmErrorText -Kind $kind | Should -Not -BeNullOrEmpty -Because "$lang/$kind"
                }
            }
        }
        finally { $script:Language = $old }
    }
}

Describe 'SSE tool_calls without an index' {
    It 'two parallel calls in ONE delta with no index stay two calls, matching the non-stream path' {
        $payload = '{"tool_calls":[{"id":"c1","function":{"name":"web_search","arguments":"{\"query\":\"a\"}"}},{"id":"c2","function":{"name":"fetch_page","arguments":"{\"url\":\"http://x/\"}"}}]}'
        $s = New-WtLlmStreamState
        $null = Add-WtLlmStreamLine -State $s -Line ('data: {"choices":[{"delta":' + $payload + '}]}')
        $streamed = Get-WtLlmStreamResult -State $s
        $plain = ConvertFrom-WtLlmResponseJson -Json ('{"choices":[{"message":' + $payload + '}]}')
        @($streamed.ToolCalls).Count | Should -Be 2
        @($streamed.ToolCalls).Count | Should -Be @($plain.ToolCalls).Count
        for ($i = 0; $i -lt @($plain.ToolCalls).Count; $i++) {
            $streamed.ToolCalls[$i].Id | Should -Be $plain.ToolCalls[$i].Id
            $streamed.ToolCalls[$i].Name | Should -Be $plain.ToolCalls[$i].Name
            $streamed.ToolCalls[$i].Arguments | Should -Be $plain.ToolCalls[$i].Arguments
        }
    }

    It 'an unindexed server that FRAGMENTS one call across deltas still yields one call' {
        $s = New-WtLlmStreamState
        $null = Add-WtLlmStreamLine -State $s -Line 'data: {"choices":[{"delta":{"tool_calls":[{"id":"c9","function":{"name":"get_sys","arguments":""}}]}}]}'
        $null = Add-WtLlmStreamLine -State $s -Line 'data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"{\"ho"}}]}}]}'
        $null = Add-WtLlmStreamLine -State $s -Line 'data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"urs\":48}"}}]}}]}'
        $r = Get-WtLlmStreamResult -State $s
        @($r.ToolCalls).Count | Should -Be 1
        $r.ToolCalls[0].Id | Should -Be 'c9'
        $r.ToolCalls[0].Name | Should -Be 'get_sys'
        $r.ToolCalls[0].Arguments | Should -Be '{"hours":48}'
    }

    It 'two complete unindexed calls arriving in SEPARATE deltas are two calls' {
        $s = New-WtLlmStreamState
        $null = Add-WtLlmStreamLine -State $s -Line 'data: {"choices":[{"delta":{"tool_calls":[{"id":"c1","function":{"name":"web_search","arguments":"{}"}}]}}]}'
        $null = Add-WtLlmStreamLine -State $s -Line 'data: {"choices":[{"delta":{"tool_calls":[{"id":"c2","function":{"name":"fetch_page","arguments":"{}"}}]}}]}'
        $r = Get-WtLlmStreamResult -State $s
        @($r.ToolCalls).Count | Should -Be 2
        @($r.ToolCalls | ForEach-Object { $_.Name }) | Should -Be @('web_search', 'fetch_page')
        @($r.ToolCalls | ForEach-Object { $_.Id }) | Should -Be @('c1', 'c2')
    }

    It 'indexed deltas are unaffected, and index and no-index can be mixed' {
        $s = New-WtLlmStreamState
        $null = Add-WtLlmStreamLine -State $s -Line 'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"a","arguments":"{}"}},{"index":1,"id":"c2","function":{"name":"b","arguments":"{}"}}]}}]}'
        $null = Add-WtLlmStreamLine -State $s -Line 'data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":""}}]}}]}'
        $r = Get-WtLlmStreamResult -State $s
        @($r.ToolCalls).Count | Should -Be 2
        @($r.ToolCalls | ForEach-Object { $_.Name }) | Should -Be @('a', 'b')
    }

    It 'a junk or absurd index neither throws nor allocates a slot per unit' {
        $s = New-WtLlmStreamState
        { $null = Add-WtLlmStreamLine -State $s -Line 'data: {"choices":[{"delta":{"tool_calls":[{"index":"abc","id":"c1","function":{"name":"a","arguments":"{}"}}]}}]}' } | Should -Not -Throw
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        { $null = Add-WtLlmStreamLine -State $s -Line 'data: {"choices":[{"delta":{"tool_calls":[{"index":99999999,"id":"c2","function":{"name":"b","arguments":"{}"}}]}}]}' } | Should -Not -Throw
        $watch.Stop()
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 5
        @((Get-WtLlmStreamResult -State $s).ToolCalls).Count | Should -BeLessOrEqual 3
    }
}

Describe 'reasoning and sampling' {
    It 'puts temperature and max_tokens in the body only when given' {
        $plain = ConvertTo-WtLlmRequestBody -Model 'm' -Messages @() | ConvertFrom-Json
        $plain.PSObject.Properties.Name | Should -Not -Contain 'temperature'
        $plain.PSObject.Properties.Name | Should -Not -Contain 'max_tokens'
        $tuned = ConvertTo-WtLlmRequestBody -Model 'm' -Messages @() -Temperature 0.2 -MaxTokens 4096 | ConvertFrom-Json
        $tuned.temperature | Should -Be 0.2
        $tuned.max_tokens | Should -Be 4096
        (ConvertTo-WtLlmRequestBody -Model 'm' -Messages @() -Temperature 0.2) | Should -Match '"temperature":0\.2'
    }

    It 'collects reasoning_content separately from content and streams it through -OnReasoningDelta' {
        $state = New-WtLlmStreamState
        (Add-WtLlmStreamLine -State $state -Line 'data: {"choices":[{"delta":{"reasoning_content":"think "}}]}') | Should -Be ''
        $state.LastReasoningPiece | Should -Be 'think '
        (Add-WtLlmStreamLine -State $state -Line 'data: {"choices":[{"delta":{"reasoning":"more"}}]}') | Should -Be ''
        (Add-WtLlmStreamLine -State $state -Line 'data: {"choices":[{"delta":{"content":"answer"}}]}') | Should -Be 'answer'
        $state.LastReasoningPiece | Should -Be ''
        $r = Get-WtLlmStreamResult -State $state
        $r.Content | Should -Be 'answer'
        $r.Reasoning | Should -Be 'think more'
        $script:Reason = ''; $script:Text = ''
        $transport = { param($Request)
            & $Request.OnLine 'data: {"choices":[{"delta":{"reasoning_content":"hmm"}}]}'
            & $Request.OnLine 'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}'
            & $Request.OnLine 'data: [DONE]'
            @{ Ok = $true; StatusCode = 200; Body = ''; Cancelled = $false; Failure = '' }
        }
        $result = Invoke-WtLlmChat -Endpoint 'http://x/v1' -Model 'm' -Messages @() -Transport $transport -OnDelta { param($P) $script:Text += $P } -OnReasoningDelta { param($P) $script:Reason += $P }
        $script:Reason | Should -Be 'hmm'
        $script:Text | Should -Be 'ok'
        $result.Reasoning | Should -Be 'hmm'
        $body = ConvertFrom-WtLlmResponseJson -Json '{"choices":[{"message":{"role":"assistant","content":"c","reasoning_content":"r"},"finish_reason":"stop"}]}'
        $body.Reasoning | Should -Be 'r'
    }
}

Describe 'usage and optional request fields' {
    It 'puts stream_options and options.num_ctx in the body only when asked; a plain body never carries stream_options' {
        $s = ConvertTo-WtLlmRequestBody -Model 'm' -Messages @() -Stream $true -IncludeUsage $true -NumCtx 8192 | ConvertFrom-Json
        $s.stream_options.include_usage | Should -BeTrue
        $s.options.num_ctx | Should -Be 8192
        $plain = ConvertTo-WtLlmRequestBody -Model 'm' -Messages @() -Stream $false -IncludeUsage $true -NumCtx 8192 | ConvertFrom-Json
        $plain.PSObject.Properties.Name | Should -Not -Contain 'stream_options'
        $plain.options.num_ctx | Should -Be 8192
        $bare = ConvertTo-WtLlmRequestBody -Model 'm' -Messages @() | ConvertFrom-Json
        $bare.PSObject.Properties.Name | Should -Not -Contain 'stream_options'
        $bare.PSObject.Properties.Name | Should -Not -Contain 'options'
    }

    It 'reads usage from the stream tail - the OpenAI usage-only chunk and the Ollama last chunk - and from a plain body' {
        $state = New-WtLlmStreamState
        $state.Usage | Should -BeNullOrEmpty
        (Add-WtLlmStreamLine -State $state -Line 'data: {"choices":[{"delta":{"content":"a"}}]}') | Should -Be 'a'
        (Add-WtLlmStreamLine -State $state -Line 'data: {"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":7,"prompt_tokens_details":{"cached_tokens":100}}}') | Should -Be ''
        (Add-WtLlmStreamLine -State $state -Line 'data: [DONE]') | Should -Be ''
        $r = Get-WtLlmStreamResult -State $state
        $r.Content | Should -Be 'a'
        $r.Usage.PromptTokens | Should -Be 120
        $r.Usage.CompletionTokens | Should -Be 7
        $r.Usage.CachedTokens | Should -Be 100
        $ollama = New-WtLlmStreamState
        (Add-WtLlmStreamLine -State $ollama -Line 'data: {"choices":[{"delta":{"content":"b"},"finish_reason":"stop"}],"usage":{"prompt_tokens":50,"completion_tokens":3}}') | Should -Be 'b'
        $o = Get-WtLlmStreamResult -State $ollama
        $o.FinishReason | Should -Be 'stop'
        $o.Usage.PromptTokens | Should -Be 50
        $o.Usage.CachedTokens | Should -Be 0
        (Add-WtLlmStreamLine -State $ollama -Line 'data: {"usage":{"prompt_tokens":"abc"}}') | Should -Be ''
        (Get-WtLlmStreamResult -State $ollama).Usage.PromptTokens | Should -Be 0
        $body = ConvertFrom-WtLlmResponseJson -Json '{"choices":[{"message":{"content":"c"},"finish_reason":"stop"}],"usage":{"prompt_tokens":9,"completion_tokens":2}}'
        $body.Usage.PromptTokens | Should -Be 9
        $body.Usage.CompletionTokens | Should -Be 2
        (ConvertFrom-WtLlmResponseJson -Json '<html>oops</html>').Usage | Should -BeNullOrEmpty
        (ConvertFrom-WtLlmResponseJson -Json '{"choices":[{"message":{"content":"c"}}]}').Usage | Should -BeNullOrEmpty
        (ConvertTo-WtLlmUsage -Usage $null) | Should -BeNullOrEmpty
    }

    It 'the chat result carries Usage from a streamed and from a plain answer, and none on a failure' {
        $transport = { param($Request)
            & $Request.OnLine 'data: {"choices":[{"delta":{"content":"ok"}}]}'
            & $Request.OnLine 'data: {"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":1}}'
            & $Request.OnLine 'data: [DONE]'
            @{ Ok = $true; StatusCode = 200; Body = ''; Cancelled = $false; Failure = '' }
        }
        (Invoke-WtLlmChat -Endpoint 'http://x/v1' -Model 'm' -Messages @() -Transport $transport).Usage.PromptTokens | Should -Be 11
        $plainTransport = { param($Request) @{ Ok = $true; StatusCode = 200; Body = '{"choices":[{"message":{"content":"c"},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":1}}'; Cancelled = $false; Failure = '' } }
        (Invoke-WtLlmChat -Endpoint 'http://x/v1' -Model 'm' -Messages @() -Stream $false -Transport $plainTransport).Usage.PromptTokens | Should -Be 5
        $dead = { param($Request) @{ Ok = $false; StatusCode = 500; Body = 'boom'; Cancelled = $false; Failure = '' } }
        (Invoke-WtLlmChat -Endpoint 'http://x/v1' -Model 'm' -Messages @() -Transport $dead).Usage | Should -BeNullOrEmpty
    }

    It 'drops stream_options once when the server rejects it by name, remembers the drop in Compat, and never sends it again in that session' {
        $script:Bodies = @()
        $transport = { param($Request)
            $script:Bodies += [string]$Request.Body
            if (([string]$Request.Body).IndexOf('stream_options', [System.StringComparison]::Ordinal) -ge 0) {
                return @{ Ok = $false; StatusCode = 400; Body = '{"error":{"message":"Unrecognized request argument supplied: stream_options"}}'; Cancelled = $false; Failure = '' }
            }
            & $Request.OnLine 'data: {"choices":[{"delta":{"content":"fine"}}]}'
            & $Request.OnLine 'data: [DONE]'
            @{ Ok = $true; StatusCode = 200; Body = ''; Cancelled = $false; Failure = '' }
        }
        $compat = @{}
        $r = Invoke-WtLlmChat -Endpoint 'http://x/v1' -Model 'm' -Messages @() -Transport $transport -Compat $compat
        $r.Ok | Should -BeTrue
        $r.Content | Should -Be 'fine'
        @($script:Bodies).Count | Should -Be 2
        ($script:Bodies[0] | ConvertFrom-Json).stream_options.include_usage | Should -BeTrue
        ($script:Bodies[1] | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'stream_options'
        ($script:Bodies[1] | ConvertFrom-Json).stream | Should -BeTrue
        $compat.DropStreamOptions | Should -BeTrue
        $script:Bodies = @()
        $null = Invoke-WtLlmChat -Endpoint 'http://x/v1' -Model 'm' -Messages @() -Transport $transport -Compat $compat
        @($script:Bodies).Count | Should -Be 1
        ($script:Bodies[0] | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'stream_options'
    }

    It 'drops options.num_ctx once when the server rejects it, on the stream and on the plain path, and a generic 400 is still reported after at most one extra request' {
        $script:Bodies = @()
        $transport = { param($Request)
            $script:Bodies += [string]$Request.Body
            if (([string]$Request.Body).IndexOf('num_ctx', [System.StringComparison]::Ordinal) -ge 0) {
                return @{ Ok = $false; StatusCode = 400; Body = '{"error":"unknown field: options"}'; Cancelled = $false; Failure = '' }
            }
            & $Request.OnLine 'data: {"choices":[{"delta":{"content":"fine"}}]}'
            & $Request.OnLine 'data: [DONE]'
            @{ Ok = $true; StatusCode = 200; Body = ''; Cancelled = $false; Failure = '' }
        }
        $compat = @{}
        $r = Invoke-WtLlmChat -Endpoint 'http://x/v1' -Model 'm' -Messages @() -Transport $transport -Compat $compat -NumCtx 8192
        $r.Ok | Should -BeTrue
        @($script:Bodies).Count | Should -Be 2
        ($script:Bodies[0] | ConvertFrom-Json).options.num_ctx | Should -Be 8192
        ($script:Bodies[1] | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'options'
        $compat.DropOptions | Should -BeTrue
        $script:Bodies = @()
        $plainTransport = { param($Request)
            $script:Bodies += [string]$Request.Body
            if (([string]$Request.Body).IndexOf('num_ctx', [System.StringComparison]::Ordinal) -ge 0) { return @{ Ok = $false; StatusCode = 400; Body = 'num_ctx is not supported'; Cancelled = $false; Failure = '' } }
            @{ Ok = $true; StatusCode = 200; Body = '{"choices":[{"message":{"content":"duz"},"finish_reason":"stop"}]}'; Cancelled = $false; Failure = '' }
        }
        $p = Invoke-WtLlmChat -Endpoint 'http://x/v1' -Model 'm' -Messages @() -Stream $false -Transport $plainTransport -Compat @{} -NumCtx 4096
        $p.Content | Should -Be 'duz'
        @($script:Bodies).Count | Should -Be 2
        $script:Bodies = @()
        $generic = { param($Request) $script:Bodies += [string]$Request.Body; @{ Ok = $false; StatusCode = 400; Body = '{"error":"bad request"}'; Cancelled = $false; Failure = '' } }
        $g = Invoke-WtLlmChat -Endpoint 'http://x/v1' -Model 'm' -Messages @() -Transport $generic -Compat @{} -NumCtx 4096
        $g.Ok | Should -BeFalse
        $g.ErrorKind | Should -Be 'BadRequest'
        @($script:Bodies).Count | Should -Be 1
        (Get-WtLlmRejectedField -StatusCode 400 -Body 'x stream_options y' -IncludeUsage $true -NumCtx 0) | Should -Be 'stream_options'
        (Get-WtLlmRejectedField -StatusCode 400 -Body 'x stream_options y' -IncludeUsage $false -NumCtx 0) | Should -Be ''
        (Get-WtLlmRejectedField -StatusCode 400 -Body 'unknown options' -IncludeUsage $true -NumCtx 1) | Should -Be 'options'
        (Get-WtLlmRejectedField -StatusCode 500 -Body 'stream_options' -IncludeUsage $true -NumCtx 1) | Should -Be ''
        (Get-WtLlmRejectedField -StatusCode 400 -Body 'x stream_options y' -IncludeUsage $false -NumCtx 1) | Should -Be ''
        (Get-WtLlmRejectedField -StatusCode 400 -Body 'unknown options' -IncludeUsage $false -NumCtx 1) | Should -Be 'options'
    }
}

Describe 'transport headers' {
    It 'reads Headers and ContentType as optional request fields' {
        $source = (Get-Command Invoke-WtLlmHttpTransport).ScriptBlock.ToString()
        $source | Should -Match "ContainsKey\('Headers'\)"
        $source | Should -Match "ContainsKey\('ContentType'\)"
    }

    It 'refuses restricted header names so a caller cannot crash the request' {
        Test-WtLlmHeaderAllowed -Name 'ChatGPT-Account-Id' | Should -BeTrue
        Test-WtLlmHeaderAllowed -Name 'OpenAI-Beta' | Should -BeTrue
        Test-WtLlmHeaderAllowed -Name 'originator' | Should -BeTrue
        Test-WtLlmHeaderAllowed -Name 'session_id' | Should -BeTrue
        Test-WtLlmHeaderAllowed -Name 'Content-Type' | Should -BeFalse
        Test-WtLlmHeaderAllowed -Name 'accept' | Should -BeFalse
        Test-WtLlmHeaderAllowed -Name 'Content-Length' | Should -BeFalse
        Test-WtLlmHeaderAllowed -Name 'USER-AGENT' | Should -BeFalse
        Test-WtLlmHeaderAllowed -Name '' | Should -BeFalse
    }
}

Describe 'the Codex model refusal' {
    It 'gets its own kind so the user is told to pick another model' {
        $body = '{"detail":"The ''gpt-5'' model is not supported when using Codex with a ChatGPT account."}'
        Get-WtLlmErrorKind -StatusCode 400 -Body $body -SentTools $true | Should -Be 'ChatGptModel'
        Get-WtLlmErrorKind -StatusCode 404 -Body $body | Should -Be 'ChatGptModel'
    }

    It 'leaves every other 4xx alone' {
        Get-WtLlmErrorKind -StatusCode 400 -Body 'bad request' | Should -Be 'BadRequest'
        Get-WtLlmErrorKind -StatusCode 404 -Body 'nope' | Should -Be 'NotFound'
        Get-WtLlmErrorKind -StatusCode 400 -Body 'unknown tool' -SentTools $true | Should -Be 'ToolsUnsupported'
    }

    It 'has a localized line of its own' {
        (Get-WtLlmErrorText -Kind 'ChatGptModel') | Should -Not -Be (Get-WtLlmErrorText -Kind 'Unknown')
    }
}
