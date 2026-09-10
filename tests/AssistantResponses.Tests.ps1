#Requires -Modules Pester

<#
.SYNOPSIS
    The Responses adapter: chat/completions messages and tools converted
    to the Responses shape, the SSE event reader, and the transport
    wrapper. All pure or seam-injected - no network anywhere in this file.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'message conversion' {
    It 'hoists every system message into instructions and drops them from input' {
        $messages = @(
            @{ role = 'system'; content = 'first' }
            @{ role = 'user'; content = 'hi' }
            @{ role = 'system'; content = 'second' }
        )
        ConvertTo-WtResponsesInstructions -Messages $messages | Should -Be "first`n`nsecond"
        $items = @(ConvertTo-WtResponsesInput -Messages $messages)
        $items.Count | Should -Be 1
        $items[0].role | Should -Be 'user'
        $items[0].content[0].type | Should -Be 'input_text'
        $items[0].content[0].text | Should -Be 'hi'
    }

    It 'uses output_text for assistant messages and input_text for user messages' {
        $items = @(ConvertTo-WtResponsesInput -Messages @(
                @{ role = 'user'; content = 'q' }
                @{ role = 'assistant'; content = 'a' }
            ))
        $items[0].content[0].type | Should -Be 'input_text'
        $items[1].role | Should -Be 'assistant'
        $items[1].content[0].type | Should -Be 'output_text'
        $items[1].content[0].text | Should -Be 'a'
    }

    It 'turns assistant tool_calls into function_call items keyed by call id' {
        $items = @(ConvertTo-WtResponsesInput -Messages @(
                @{ role = 'assistant'; content = ''; tool_calls = @(
                        @{ id = 'call_1'; type = 'function'; 'function' = @{ name = 'read_system'; arguments = '{"a":1}' } }
                        @{ id = 'call_2'; type = 'function'; 'function' = @{ name = 'web_search'; arguments = '{}' } }
                    )
                }
            ))
        $items.Count | Should -Be 2
        $items[0].type | Should -Be 'function_call'
        $items[0].call_id | Should -Be 'call_1'
        $items[0].name | Should -Be 'read_system'
        $items[0].arguments | Should -Be '{"a":1}'
        $items[1].call_id | Should -Be 'call_2'
    }

    It 'turns a tool reply into a function_call_output on the same call id' {
        $items = @(ConvertTo-WtResponsesInput -Messages @(
                @{ role = 'tool'; tool_call_id = 'call_1'; content = 'the result' }
            ))
        $items[0].type | Should -Be 'function_call_output'
        $items[0].call_id | Should -Be 'call_1'
        $items[0].output | Should -Be 'the result'
    }

    It 'keeps an assistant message that has both text and tool calls, text first' {
        $items = @(ConvertTo-WtResponsesInput -Messages @(
                @{ role = 'assistant'; content = 'thinking out loud'; tool_calls = @(
                        @{ id = 'call_9'; 'function' = @{ name = 'n'; arguments = '{}' } }) }
            ))
        $items.Count | Should -Be 2
        $items[0].content[0].text | Should -Be 'thinking out loud'
        $items[1].type | Should -Be 'function_call'
    }

    It 'survives an empty message list' {
        @(ConvertTo-WtResponsesInput -Messages @()).Count | Should -Be 0
        ConvertTo-WtResponsesInstructions -Messages @() | Should -Be ''
    }
}

Describe 'tool conversion' {
    It 'flattens the chat/completions function wrapper' {
        $tools = @(ConvertTo-WtResponsesTools -Tools @(
                @{ type = 'function'; 'function' = @{ name = 'read_system'; description = 'd'
                        parameters = @{ type = 'object'; properties = @{ scope = @{ type = 'string' } } }
                    }
                }
            ))
        $tools.Count | Should -Be 1
        $tools[0].type | Should -Be 'function'
        $tools[0].name | Should -Be 'read_system'
        $tools[0].description | Should -Be 'd'
        $tools[0].parameters.type | Should -Be 'object'
        @($tools[0].Keys) | Should -Not -Contain 'function'
    }

    It 'returns nothing for an empty tool list' {
        @(ConvertTo-WtResponsesTools -Tools @()).Count | Should -Be 0
    }
}

Describe 'the request body' {
    It 'always sends store false and stream true' {
        $body = ConvertTo-WtResponsesRequestBody -Model 'gpt-5-codex' -Messages @(@{ role = 'user'; content = 'hi' }) | ConvertFrom-Json
        $body.model | Should -Be 'gpt-5-codex'
        $body.store | Should -BeFalse
        $body.stream | Should -BeTrue
        $body.reasoning.summary | Should -Be 'auto'
    }

    It 'omits tools and tool_choice entirely when no tools are passed' {
        $json = ConvertTo-WtResponsesRequestBody -Model 'm' -Messages @(@{ role = 'user'; content = 'hi' })
        $json | Should -Not -Match '"tools"'
        $json | Should -Not -Match '"tool_choice"'
    }

    It 'carries tools with auto by default and an explicit override' {
        $tool = @{ type = 'function'; 'function' = @{ name = 'p'; description = 'd'; parameters = @{ type = 'object'; properties = @{} } } }
        (ConvertTo-WtResponsesRequestBody -Model 'm' -Messages @(@{ role = 'user'; content = 'x' }) -Tools @($tool) | ConvertFrom-Json).tool_choice | Should -Be 'auto'
        (ConvertTo-WtResponsesRequestBody -Model 'm' -Messages @(@{ role = 'user'; content = 'x' }) -Tools @($tool) -ToolChoice 'none' | ConvertFrom-Json).tool_choice | Should -Be 'none'
    }

    It 'writes instructions separately from input' {
        $body = ConvertTo-WtResponsesRequestBody -Model 'm' -Messages @(
            @{ role = 'system'; content = 'be brief' }
            @{ role = 'user'; content = 'hi' }
        ) | ConvertFrom-Json
        $body.instructions | Should -Be 'be brief'
        @($body.input).Count | Should -Be 1
    }

    It 'builds the responses uri from the configured api base' {
        Get-WtChatGptResponsesUri | Should -Be ((Get-WtChatGptOAuthConfig).ApiBase + '/responses')
    }
}

Describe 'the Responses SSE reader' {
    It 'accumulates text deltas and reports each piece' {
        $s = New-WtResponsesStreamState
        $p1 = Add-WtResponsesStreamLine -State $s -Line 'data: {"type":"response.output_text.delta","delta":"Mer"}'
        $p2 = Add-WtResponsesStreamLine -State $s -Line 'data: {"type":"response.output_text.delta","delta":"haba"}'
        $p1 | Should -Be 'Mer'
        $p2 | Should -Be 'haba'
        (Get-WtResponsesStreamResult -State $s).Content | Should -Be 'Merhaba'
    }

    It 'ignores everything that is not a data line, including the event line' {
        $s = New-WtResponsesStreamState
        Add-WtResponsesStreamLine -State $s -Line 'event: response.output_text.delta' | Should -Be ''
        Add-WtResponsesStreamLine -State $s -Line '' | Should -Be ''
        Add-WtResponsesStreamLine -State $s -Line ': keep-alive' | Should -Be ''
        Add-WtResponsesStreamLine -State $s -Line 'data: not json' | Should -Be ''
        Add-WtResponsesStreamLine -State $s -Line 'data: {"type":"response.some.future.event"}' | Should -Be ''
        (Get-WtResponsesStreamResult -State $s).Content | Should -Be ''
    }

    It 'collects the reasoning summary separately from the answer' {
        $s = New-WtResponsesStreamState
        Add-WtResponsesStreamLine -State $s -Line 'data: {"type":"response.reasoning_summary_text.delta","delta":"dus"}' | Should -Be ''
        $s.LastReasoningPiece | Should -Be 'dus'
        $null = Add-WtResponsesStreamLine -State $s -Line 'data: {"type":"response.output_text.delta","delta":"cevap"}'
        $s.LastReasoningPiece | Should -Be ''
        $done = Get-WtResponsesStreamResult -State $s
        $done.Reasoning | Should -Be 'dus'
        $done.Content | Should -Be 'cevap'
    }

    It 'merges a tool call announced once and streamed in pieces' {
        $s = New-WtResponsesStreamState
        $null = Add-WtResponsesStreamLine -State $s -Line 'data: {"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"call_a","name":"read_system"}}'
        $null = Add-WtResponsesStreamLine -State $s -Line 'data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":0,"delta":"{\"sc"}'
        $null = Add-WtResponsesStreamLine -State $s -Line 'data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":0,"delta":"ope\":1}"}'
        $done = Get-WtResponsesStreamResult -State $s
        @($done.ToolCalls).Count | Should -Be 1
        $done.ToolCalls[0].Id | Should -Be 'call_a'
        $done.ToolCalls[0].Name | Should -Be 'read_system'
        $done.ToolCalls[0].Arguments | Should -Be '{"scope":1}'
        $done.FinishReason | Should -Be 'tool_calls'
    }

    It 'keeps two parallel tool calls apart by item id' {
        $s = New-WtResponsesStreamState
        $null = Add-WtResponsesStreamLine -State $s -Line 'data: {"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"call_a","name":"one"}}'
        $null = Add-WtResponsesStreamLine -State $s -Line 'data: {"type":"response.output_item.added","output_index":1,"item":{"id":"fc_2","type":"function_call","call_id":"call_b","name":"two"}}'
        $null = Add-WtResponsesStreamLine -State $s -Line 'data: {"type":"response.function_call_arguments.delta","item_id":"fc_2","delta":"{\"b\":2}"}'
        $null = Add-WtResponsesStreamLine -State $s -Line 'data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\"a\":1}"}'
        $done = Get-WtResponsesStreamResult -State $s
        @($done.ToolCalls).Count | Should -Be 2
        $done.ToolCalls[0].Name | Should -Be 'one'
        $done.ToolCalls[0].Arguments | Should -Be '{"a":1}'
        $done.ToolCalls[1].Name | Should -Be 'two'
        $done.ToolCalls[1].Arguments | Should -Be '{"b":2}'
    }

    It 'takes the final arguments from the done event when one arrives' {
        $s = New-WtResponsesStreamState
        $null = Add-WtResponsesStreamLine -State $s -Line 'data: {"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"call_a","name":"n"}}'
        $null = Add-WtResponsesStreamLine -State $s -Line 'data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\"par"}'
        $null = Add-WtResponsesStreamLine -State $s -Line 'data: {"type":"response.function_call_arguments.done","item_id":"fc_1","arguments":"{\"partial\":false}"}'
        (Get-WtResponsesStreamResult -State $s).ToolCalls[0].Arguments | Should -Be '{"partial":false}'
    }

    It 'ignores an output item that is not a function call' {
        $s = New-WtResponsesStreamState
        $null = Add-WtResponsesStreamLine -State $s -Line 'data: {"type":"response.output_item.added","output_index":0,"item":{"id":"msg_1","type":"message"}}'
        @((Get-WtResponsesStreamResult -State $s).ToolCalls).Count | Should -Be 0
    }

    It 'reads usage off the completed event in the shared shape' {
        $s = New-WtResponsesStreamState
        $null = Add-WtResponsesStreamLine -State $s -Line 'data: {"type":"response.completed","response":{"usage":{"input_tokens":120,"output_tokens":34,"input_tokens_details":{"cached_tokens":100}}}}'
        $s.Done | Should -BeTrue
        $usage = (Get-WtResponsesStreamResult -State $s).Usage
        $usage.PromptTokens | Should -Be 120
        $usage.CompletionTokens | Should -Be 34
        $usage.CachedTokens | Should -Be 100
    }

    It 'reads zero for usage fields it cannot parse, and null for no usage at all' {
        (ConvertTo-WtResponsesUsage -Usage $null) | Should -BeNullOrEmpty
        $partial = ConvertTo-WtResponsesUsage -Usage ([PSCustomObject]@{ input_tokens = 'x' })
        $partial.PromptTokens | Should -Be 0
        $partial.CompletionTokens | Should -Be 0
        $partial.CachedTokens | Should -Be 0
    }

    It 'carries a failure event as error text' {
        $s = New-WtResponsesStreamState
        $null = Add-WtResponsesStreamLine -State $s -Line 'data: {"type":"response.failed","response":{"error":{"message":"model is overloaded"}}}'
        $s.ErrorText | Should -Be 'model is overloaded'
        $s.Done | Should -BeTrue
    }

    It 'reports stop when there were no tool calls' {
        $s = New-WtResponsesStreamState
        $null = Add-WtResponsesStreamLine -State $s -Line 'data: {"type":"response.output_text.delta","delta":"x"}'
        (Get-WtResponsesStreamResult -State $s).FinishReason | Should -Be 'stop'
    }
}

Describe 'the Responses transport wrapper' {
    BeforeAll {
        $script:GoodToken = { param($Root) return @{ Ok = $true; AccessToken = 'at-1'; AccountId = 'acct-1'; ErrorKind = ''; ErrorText = '' } }
        $script:StreamOk = {
            param($Request)
            & $Request.OnLine 'data: {"type":"response.output_text.delta","delta":"selam"}'
            & $Request.OnLine 'data: {"type":"response.completed","response":{"usage":{"input_tokens":10,"output_tokens":2}}}'
            return @{ Ok = $true; StatusCode = 200; Body = ''; Cancelled = $false; Failure = '' }
        }
    }

    It 'returns exactly the key set Invoke-WtLlmChat returns' {
        $mine = @((Invoke-WtChatGptResponses -Model 'm' -Messages @(@{ role = 'user'; content = 'hi' }) `
                    -GetToken $script:GoodToken -Transport $script:StreamOk).Keys) | Sort-Object
        $theirs = @((Invoke-WtLlmChat -Endpoint 'http://x/v1' -Model 'm' -Messages @(@{ role = 'user'; content = 'hi' }) -Stream $false `
                    -Transport { param($Request) return @{ Ok = $true; StatusCode = 200; Body = '{"choices":[{"message":{"content":"x"}}]}'; Cancelled = $false; Failure = '' } }).Keys) | Sort-Object
        ($mine -join ',') | Should -Be ($theirs -join ',')
    }

    It 'streams the answer, the usage and the deltas' {
        $pieces = New-Object System.Collections.Generic.List[string]
        $onDelta = { param($Piece) $pieces.Add([string]$Piece) }.GetNewClosure()
        $r = Invoke-WtChatGptResponses -Model 'm' -Messages @(@{ role = 'user'; content = 'hi' }) `
            -OnDelta $onDelta -GetToken $script:GoodToken -Transport $script:StreamOk
        $r.Ok | Should -BeTrue
        $r.Content | Should -Be 'selam'
        $r.Usage.PromptTokens | Should -Be 10
        ($pieces -join '') | Should -Be 'selam'
    }

    It 'carries the account, beta, originator and session headers plus the bearer token' {
        $seen = New-Object System.Collections.Generic.List[object]
        $transport = {
            param($Request)
            $seen.Add($Request)
            return @{ Ok = $true; StatusCode = 200; Body = ''; Cancelled = $false; Failure = '' }
        }.GetNewClosure()
        $null = Invoke-WtChatGptResponses -Model 'm' -Messages @(@{ role = 'user'; content = 'hi' }) -SessionId 'sess-9' `
            -GetToken $script:GoodToken -Transport $transport
        $seen[0].Uri | Should -Be (Get-WtChatGptResponsesUri)
        $seen[0].ApiKey | Should -Be 'at-1'
        $seen[0].Headers['ChatGPT-Account-Id'] | Should -Be 'acct-1'
        $seen[0].Headers['OpenAI-Beta'] | Should -Be 'responses=experimental'
        $seen[0].Headers['originator'] | Should -Be 'wintoolify'
        $seen[0].Headers['session_id'] | Should -Be 'sess-9'
        $seen[0].Body | Should -Match '"store":false'
    }

    It 'omits the session header when no session id was given' {
        $seen = New-Object System.Collections.Generic.List[object]
        $transport = {
            param($Request)
            $seen.Add($Request)
            return @{ Ok = $true; StatusCode = 200; Body = ''; Cancelled = $false; Failure = '' }
        }.GetNewClosure()
        $null = Invoke-WtChatGptResponses -Model 'm' -Messages @(@{ role = 'user'; content = 'hi' }) `
            -GetToken $script:GoodToken -Transport $transport
        $seen[0].Headers.ContainsKey('session_id') | Should -BeFalse
    }

    It 'fails as Auth without touching the network when there is no usable token' {
        $calls = New-Object System.Collections.Generic.List[object]
        $transport = {
            param($Request)
            $calls.Add($Request)
            return @{ Ok = $true; StatusCode = 200; Body = ''; Cancelled = $false; Failure = '' }
        }.GetNewClosure()
        $r = Invoke-WtChatGptResponses -Model 'm' -Messages @(@{ role = 'user'; content = 'hi' }) `
            -GetToken { param($Root) return @{ Ok = $false; AccessToken = ''; AccountId = ''; ErrorKind = 'Auth'; ErrorText = 'sign in again' } } `
            -Transport $transport
        $r.Ok | Should -BeFalse
        $r.ErrorKind | Should -Be 'Auth'
        $r.ErrorText | Should -Be 'sign in again'
        $calls.Count | Should -Be 0
    }

    It 'keeps the partial answer when the user cancels' {
        $r = Invoke-WtChatGptResponses -Model 'm' -Messages @(@{ role = 'user'; content = 'hi' }) -GetToken $script:GoodToken `
            -Transport {
            param($Request)
            & $Request.OnLine 'data: {"type":"response.output_text.delta","delta":"yarim"}'
            return @{ Ok = $false; StatusCode = 0; Body = ''; Cancelled = $true; Failure = '' }
        }
        $r.Ok | Should -BeFalse
        $r.Cancelled | Should -BeTrue
        $r.Content | Should -Be 'yarim'
        $r.ErrorKind | Should -Be ''
    }

    It 'maps a transport failure through the shared error kinds' {
        $tool = @{ type = 'function'; 'function' = @{ name = 'p'; description = 'd'; parameters = @{ type = 'object'; properties = @{} } } }
        $r = Invoke-WtChatGptResponses -Model 'm' -Messages @(@{ role = 'user'; content = 'hi' }) -Tools @($tool) -GetToken $script:GoodToken `
            -Transport { param($Request) return @{ Ok = $false; StatusCode = 429; Body = 'slow down'; Cancelled = $false; Failure = '' } }
        $r.Ok | Should -BeFalse
        $r.ErrorKind | Should -Be 'RateLimit'
        $r.ErrorText | Should -Match 'slow down'
    }

    It 'turns a failure event inside a 200 stream into a server error' {
        $r = Invoke-WtChatGptResponses -Model 'm' -Messages @(@{ role = 'user'; content = 'hi' }) -GetToken $script:GoodToken `
            -Transport {
            param($Request)
            & $Request.OnLine 'data: {"type":"response.failed","response":{"error":{"message":"overloaded"}}}'
            return @{ Ok = $true; StatusCode = 200; Body = ''; Cancelled = $false; Failure = '' }
        }
        $r.Ok | Should -BeFalse
        $r.ErrorKind | Should -Be 'Server'
        $r.ErrorText | Should -Match 'overloaded'
    }
}
