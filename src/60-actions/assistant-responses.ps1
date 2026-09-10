# The Responses API adapter: chat/completions messages and tools into the
# Responses shape, the SSE event reader, and the one request that spends a
# ChatGPT subscription.
# Covered by: tests/AssistantResponses.Tests.ps1

function Get-WtChatGptResponsesUri {
    <#
    .SYNOPSIS
        The subscription-billed completions endpoint. Not api.openai.com:
        a ChatGPT OAuth token is only accepted by this backend, and only
        in the Responses shape - chat/completions was retired here.
    #>
    return ([string](Get-WtChatGptOAuthConfig).ApiBase + '/responses')
}

function ConvertTo-WtResponsesInstructions {
    <#
    .SYNOPSIS
        PURE: every system message joined into the single instructions
        field. Responses has no system role in the input array, so a
        system message left there would be silently ignored.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Messages)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($message in @($Messages)) {
        if ($null -eq $message) { continue }
        if (-not [string]::Equals([string]$message.role, 'system', [System.StringComparison]::Ordinal)) { continue }
        $text = [string]$message.content
        if ($text) { $parts.Add($text) }
    }
    return (($parts.ToArray()) -join "`n`n")
}

function ConvertTo-WtResponsesInput {
    <#
    .SYNOPSIS
        PURE: the message array in the Responses input shape. A user turn
        carries input_text and an assistant turn output_text - the two are
        NOT interchangeable. An assistant turn that both spoke and called
        tools becomes several items, text first, so the transcript reads
        in the order it happened. System messages are dropped here; they
        belong to ConvertTo-WtResponsesInstructions.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Messages)
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($message in @($Messages)) {
        if ($null -eq $message) { continue }
        $role = [string]$message.role
        if ([string]::Equals($role, 'system', [System.StringComparison]::Ordinal)) { continue }
        if ([string]::Equals($role, 'tool', [System.StringComparison]::Ordinal)) {
            $items.Add([ordered]@{ type = 'function_call_output'; call_id = [string]$message.tool_call_id; output = [string]$message.content })
            continue
        }
        $text = [string]$message.content
        if ($text) {
            $partType = $(if ([string]::Equals($role, 'assistant', [System.StringComparison]::Ordinal)) { 'output_text' } else { 'input_text' })
            $items.Add([ordered]@{ type = 'message'; role = $role; content = @([ordered]@{ type = $partType; text = $text }) })
        }
        $calls = $null
        if ($message -is [System.Collections.IDictionary]) {
            if ($message.Contains('tool_calls')) { $calls = $message['tool_calls'] }
        }
        elseif (@($message.PSObject.Properties.Name) -contains 'tool_calls') { $calls = $message.tool_calls }
        foreach ($call in @($calls)) {
            if ($null -eq $call) { continue }
            $items.Add([ordered]@{
                    type      = 'function_call'
                    call_id   = [string]$call.id
                    name      = [string]$call.function.name
                    arguments = [string]$call.function.arguments
                })
        }
    }
    return @($items.ToArray())
}

function ConvertTo-WtResponsesTools {
    <#
    .SYNOPSIS
        PURE: our chat/completions tool wrapper flattened - Responses puts
        name, description and parameters on the tool itself rather than
        inside a nested function object.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Tools)
    $converted = New-Object System.Collections.Generic.List[object]
    foreach ($tool in @($Tools)) {
        if ($null -eq $tool) { continue }
        $fn = $tool.'function'
        if ($null -eq $fn) { continue }
        $converted.Add([ordered]@{
                type        = 'function'
                name        = [string]$fn.name
                description = [string]$fn.description
                parameters  = $fn.parameters
            })
    }
    return @($converted.ToArray())
}

function ConvertTo-WtResponsesRequestBody {
    <#
    .SYNOPSIS
        The Responses request body. store is always false - nothing this
        app sends should be retained server-side - and reasoning.summary
        is asked for so the existing reasoning stream keeps flowing. tools
        and tool_choice are omitted entirely when there are no tools, the
        same rule the chat/completions body follows.
    #>
    param(
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Messages,
        [AllowEmptyCollection()][array]$Tools = @(),
        [string]$ToolChoice = ''
    )
    $body = [ordered]@{
        model        = $Model
        instructions = (ConvertTo-WtResponsesInstructions -Messages $Messages)
        input        = @(ConvertTo-WtResponsesInput -Messages $Messages)
        stream       = $true
        store        = $false
        reasoning    = [ordered]@{ summary = 'auto' }
    }
    $converted = @(ConvertTo-WtResponsesTools -Tools $Tools)
    if ($converted.Count -gt 0) {
        $body['tools'] = $converted
        $body['tool_choice'] = $(if ($ToolChoice) { $ToolChoice } else { 'auto' })
    }
    return ($body | ConvertTo-Json -Depth 16 -Compress)
}

function New-WtResponsesStreamState {
    <#
    .SYNOPSIS
        The accumulator Add-WtResponsesStreamLine fills. Tool calls are
        kept in a list plus an id->slot map: Responses identifies a call
        by item_id, which rides on every argument delta, rather than by
        the positional index chat/completions uses.
    #>
    return @{
        Content            = (New-Object System.Text.StringBuilder)
        Reasoning          = (New-Object System.Text.StringBuilder)
        LastReasoningPiece = ''
        ToolCalls          = (New-Object System.Collections.Generic.List[object])
        SlotByItemId       = @{}
        Usage              = $null
        Done               = $false
        ErrorText          = ''
    }
}

function ConvertTo-WtResponsesUsage {
    <#
    .SYNOPSIS
        PURE: a Responses usage object in the same shape the rest of the
        app already counts - the field names differ (input_tokens rather
        than prompt_tokens), the meaning does not. Unreadable numbers
        become 0; a missing object stays $null.
    #>
    param([AllowNull()]$Usage)
    if ($null -eq $Usage) { return $null }
    $read = { param($Source, [string]$Name)
        if ($null -eq $Source -or -not (@($Source.PSObject.Properties.Name) -contains $Name)) { return 0 }
        $parsed = 0
        if ([int]::TryParse([string]$Source.$Name, [System.Globalization.NumberStyles]::Integer,
                [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and $parsed -ge 0) {
            return $parsed
        }
        return 0
    }
    $details = $null
    if (@($Usage.PSObject.Properties.Name) -contains 'input_tokens_details') { $details = $Usage.input_tokens_details }
    return @{
        PromptTokens     = [int](& $read $Usage 'input_tokens')
        CompletionTokens = [int](& $read $Usage 'output_tokens')
        CachedTokens     = [int](& $read $details 'cached_tokens')
    }
}

function Add-WtResponsesStreamLine {
    <#
    .SYNOPSIS
        Applies one SSE line to the stream state and returns the answer
        text it contributed. Only 'data:' lines are read, and the event is
        identified by the payload's own type field rather than by the
        'event:' line - the two always agree, and reading one of them
        keeps this a pure function of the JSON. Unknown types are ignored
        so a new server-side event cannot break a turn.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [AllowNull()][AllowEmptyString()][string]$Line
    )
    $State.LastReasoningPiece = ''
    $text = [string]$Line
    if (-not $text.StartsWith('data:', [System.StringComparison]::Ordinal)) { return '' }
    $payload = $text.Substring(5).Trim()
    if (-not $payload) { return '' }
    if ($payload -eq '[DONE]') { $State.Done = $true; return '' }
    $chunk = $null
    try { $chunk = $payload | ConvertFrom-Json } catch { return '' }
    if ($null -eq $chunk -or -not (@($chunk.PSObject.Properties.Name) -contains 'type')) { return '' }
    $type = [string]$chunk.type
    $slotFor = { param([string]$ItemId)
        if (-not $ItemId -or -not $State.SlotByItemId.ContainsKey($ItemId)) { return $null }
        return $State.ToolCalls[[int]$State.SlotByItemId[$ItemId]]
    }
    if ([string]::Equals($type, 'response.output_text.delta', [System.StringComparison]::Ordinal)) {
        $piece = [string]$chunk.delta
        [void]$State.Content.Append($piece)
        return $piece
    }
    if ([string]::Equals($type, 'response.reasoning_summary_text.delta', [System.StringComparison]::Ordinal) -or
        [string]::Equals($type, 'response.reasoning_text.delta', [System.StringComparison]::Ordinal)) {
        $piece = [string]$chunk.delta
        [void]$State.Reasoning.Append($piece)
        $State.LastReasoningPiece = $piece
        return ''
    }
    if ([string]::Equals($type, 'response.output_item.added', [System.StringComparison]::Ordinal)) {
        $item = $chunk.item
        if ($null -eq $item) { return '' }
        if (-not [string]::Equals([string]$item.type, 'function_call', [System.StringComparison]::Ordinal)) { return '' }
        $itemId = [string]$item.id
        if (-not $itemId) { $itemId = 'item_' + [string]$State.ToolCalls.Count }
        if ($State.SlotByItemId.ContainsKey($itemId)) { return '' }
        $State.ToolCalls.Add(@{ Id = [string]$item.call_id; Name = [string]$item.name; Arguments = (New-Object System.Text.StringBuilder) })
        $State.SlotByItemId[$itemId] = $State.ToolCalls.Count - 1
        return ''
    }
    if ([string]::Equals($type, 'response.function_call_arguments.delta', [System.StringComparison]::Ordinal)) {
        $slot = & $slotFor ([string]$chunk.item_id)
        if ($null -ne $slot) { [void]$slot.Arguments.Append([string]$chunk.delta) }
        return ''
    }
    if ([string]::Equals($type, 'response.function_call_arguments.done', [System.StringComparison]::Ordinal)) {
        $slot = & $slotFor ([string]$chunk.item_id)
        if ($null -ne $slot) {
            [void]$slot.Arguments.Clear()
            [void]$slot.Arguments.Append([string]$chunk.arguments)
        }
        return ''
    }
    if ([string]::Equals($type, 'response.completed', [System.StringComparison]::Ordinal)) {
        $State.Done = $true
        if ($null -ne $chunk.response -and (@($chunk.response.PSObject.Properties.Name) -contains 'usage')) {
            $State.Usage = ConvertTo-WtResponsesUsage -Usage $chunk.response.usage
        }
        return ''
    }
    if ([string]::Equals($type, 'response.failed', [System.StringComparison]::Ordinal) -or
        [string]::Equals($type, 'error', [System.StringComparison]::Ordinal)) {
        $State.Done = $true
        $message = ''
        if ($null -ne $chunk.response -and $null -ne $chunk.response.error) { $message = [string]$chunk.response.error.message }
        elseif (@($chunk.PSObject.Properties.Name) -contains 'error' -and $null -ne $chunk.error) { $message = [string]$chunk.error.message }
        elseif (@($chunk.PSObject.Properties.Name) -contains 'message') { $message = [string]$chunk.message }
        $State.ErrorText = $message
        return ''
    }
    return ''
}

function Get-WtResponsesStreamResult {
    <#
    .SYNOPSIS
        Freezes the stream state into the same result triple the
        chat/completions client produces. FinishReason is derived, not
        received: Responses does not send one, and the rest of the app
        expects the chat/completions vocabulary.
    #>
    param([Parameter(Mandatory)][hashtable]$State)
    $calls = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $State.ToolCalls.Count; $i++) {
        $slot = $State.ToolCalls[$i]
        $id = [string]$slot.Id
        if (-not $id) { $id = 'call_' + $i }
        $calls.Add([PSCustomObject]@{ Id = $id; Name = [string]$slot.Name; Arguments = $slot.Arguments.ToString() })
    }
    $finish = $(if ($calls.Count -gt 0) { 'tool_calls' } else { 'stop' })
    return @{
        Content   = $State.Content.ToString(); Reasoning = $State.Reasoning.ToString()
        ToolCalls = @($calls.ToArray()); FinishReason = $finish; Usage = $State.Usage
    }
}

function Invoke-WtChatGptResponses {
    <#
    .SYNOPSIS
        One model turn billed to the user's ChatGPT subscription. Returns
        the SAME result table Invoke-WtLlmChat returns - that shared shape
        is the contract the facade rests on, so nothing above it needs to
        know which protocol answered. The token is fetched first and a
        failure there short-circuits before any request goes out, because
        a dead session must read as "sign in again", not as a server
        error. There is no non-stream fallback: this endpoint streams.
        -Compat is accepted and unused so the facade can hand both
        transports the same argument table.
    #>
    param(
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Messages,
        [AllowEmptyCollection()][array]$Tools = @(),
        [string]$ToolChoice = '',
        [scriptblock]$OnDelta = $null,
        [scriptblock]$OnReasoningDelta = $null,
        [scriptblock]$ShouldCancel = { $false },
        [int]$TimeoutSec = 180,
        [AllowEmptyString()][string]$SessionId = '',
        [string]$TestRootOverride,
        [AllowNull()][hashtable]$Compat = $null,
        [scriptblock]$GetToken = { param($Root) Get-WtChatGptAccessToken -TestRootOverride $Root },
        [scriptblock]$Transport = { param($Request) Invoke-WtLlmHttpTransport -Request $Request }
    )
    $answer = { param($Ok, $Content, $Calls, $Finish, $Kind, $Text, $Cancelled, $Reasoning, $Usage)
        return @{
            Ok        = [bool]$Ok; Content = [string]$Content; ToolCalls = @($Calls); FinishReason = [string]$Finish
            ErrorKind = [string]$Kind; ErrorText = [string]$Text; Cancelled = [bool]$Cancelled
            Reasoning = [string]$Reasoning; Usage = $Usage
        }
    }
    $token = & $GetToken $TestRootOverride
    if (-not $token.Ok) { return (& $answer $false '' @() '' 'Auth' ([string]$token.ErrorText) $false '' $null) }
    $config = Get-WtChatGptOAuthConfig
    $headers = @{
        'ChatGPT-Account-Id' = [string]$token.AccountId
        'OpenAI-Beta'        = 'responses=experimental'
        'originator'         = [string]$config.Originator
    }
    if ($SessionId) { $headers['session_id'] = [string]$SessionId }
    $state = New-WtResponsesStreamState
    $onLine = { param($Line)
        $piece = Add-WtResponsesStreamLine -State $state -Line $Line
        if ($piece -and $OnDelta) { & $OnDelta $piece }
        if ($state.LastReasoningPiece -and $OnReasoningDelta) { & $OnReasoningDelta $state.LastReasoningPiece }
    }
    $response = & $Transport @{
        Uri = (Get-WtChatGptResponsesUri); Method = 'POST'; ApiKey = [string]$token.AccessToken; Headers = $headers
        Body = (ConvertTo-WtResponsesRequestBody -Model $Model -Messages $Messages -Tools $Tools -ToolChoice $ToolChoice)
        Stream = $true; TimeoutSec = $TimeoutSec; OnLine = $onLine; ShouldCancel = $ShouldCancel
    }
    if ($response.Cancelled) {
        $partial = Get-WtResponsesStreamResult -State $state
        return (& $answer $false $partial.Content @() '' '' '' $true $partial.Reasoning $null)
    }
    if (-not $response.Ok) {
        $kind = Get-WtLlmErrorKind -StatusCode ([int]$response.StatusCode) -Body ([string]$response.Body) `
            -FailureKind ([string]$response.Failure) -SentTools (@($Tools).Count -gt 0)
        return (& $answer $false '' @() '' $kind (Get-WtLlmErrorText -Kind $kind -Detail ([string]$response.Body)) $false '' $null)
    }
    if ([string]$state.ErrorText) {
        return (& $answer $false '' @() '' 'Server' (Get-WtLlmErrorText -Kind 'Server' -Detail ([string]$state.ErrorText)) $false '' $null)
    }
    $done = Get-WtResponsesStreamResult -State $state
    return (& $answer $true $done.Content $done.ToolCalls $done.FinishReason '' '' $false $done.Reasoning $done.Usage)
}
