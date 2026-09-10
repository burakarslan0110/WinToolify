# OpenAI-compatible LLM client: request building, SSE parsing, transport
# and error mapping - the wire protocol only.
# Covered by: tests/AssistantClient.Tests.ps1

function Get-WtLlmChatUri {
    param([Parameter(Mandatory)][string]$Endpoint)
    return ($Endpoint.TrimEnd('/') + '/chat/completions')
}

function Get-WtLlmModelsUri {
    param([Parameter(Mandatory)][string]$Endpoint)
    return ($Endpoint.TrimEnd('/') + '/models')
}

function ConvertTo-WtLlmRequestBody {
    <#
    .SYNOPSIS
        The chat/completions request body. tools/tool_choice are omitted
        when no tools are passed - several servers reject an empty tools
        array outright. IncludeUsage/NumCtx default to off so existing
        request bodies stay byte-identical when unused.
    #>
    param(
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Messages,
        [AllowEmptyCollection()][array]$Tools = @(),
        [bool]$Stream = $true,
        [string]$ToolChoice = '',
        [double]$Temperature = -1,
        [int]$MaxTokens = 0,
        [bool]$IncludeUsage = $false,
        [int]$NumCtx = 0
    )
    $body = @{ model = $Model; messages = @($Messages); stream = [bool]$Stream }
    if (@($Tools).Count -gt 0) {
        $body['tools'] = @($Tools)
        $body['tool_choice'] = $(if ($ToolChoice) { $ToolChoice } else { 'auto' })
    }
    if ($Temperature -ge 0) { $body['temperature'] = [double]$Temperature }
    if ($MaxTokens -gt 0) { $body['max_tokens'] = [int]$MaxTokens }
    if ($Stream -and $IncludeUsage) { $body['stream_options'] = @{ include_usage = $true } }
    if ($NumCtx -gt 0) { $body['options'] = @{ num_ctx = [int]$NumCtx } }
    return ($body | ConvertTo-Json -Depth 16 -Compress)
}

function ConvertTo-WtLlmUsage {
    <#
    .SYNOPSIS
        PURE: a chat completion's usage object (stream tail or plain body)
        as @{ PromptTokens; CompletionTokens; CachedTokens } - invariant
        integer parses, 0 for anything missing or unreadable; $null when
        the object itself is missing.
    #>
    param([AllowNull()]$Usage)
    if ($null -eq $Usage) { return $null }
    $read = { param($Source, [string]$Name)
        if ($null -eq $Source -or -not ($Source.PSObject.Properties.Name -contains $Name)) { return 0 }
        $parsed = 0
        if ([int]::TryParse([string]$Source.$Name, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and $parsed -ge 0) { return $parsed }
        return 0
    }
    $details = $null
    if ($Usage.PSObject.Properties.Name -contains 'prompt_tokens_details') { $details = $Usage.prompt_tokens_details }
    return @{
        PromptTokens     = [int](& $read $Usage 'prompt_tokens')
        CompletionTokens = [int](& $read $Usage 'completion_tokens')
        CachedTokens     = [int](& $read $details 'cached_tokens')
    }
}

function New-WtLlmStreamState {
    <#
    .SYNOPSIS
        The accumulator Add-WtLlmStreamLine fills: content pieces, the
        tool-call slots being merged by index, the finish reason.
    #>
    return @{
        Content            = (New-Object System.Text.StringBuilder)
        Reasoning          = (New-Object System.Text.StringBuilder)
        LastReasoningPiece = ''
        ToolCalls          = (New-Object System.Collections.Generic.List[object])
        FinishReason       = ''
        Done               = $false
        Usage              = $null
    }
}

function Add-WtLlmStreamLine {
    <#
    .SYNOPSIS
        Applies one SSE line to the stream state, returns the contributed
        text. An unindexed tool-call element is matched by position among
        the unindexed elements of its own delta, not slot 0, which used to
        merge parallel calls from servers that omit the index field.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [AllowNull()][AllowEmptyString()][string]$Line
    )
    $State.LastReasoningPiece = ''
    $text = [string]$Line
    if (-not $text.StartsWith('data:', [System.StringComparison]::Ordinal)) { return '' }
    $payload = $text.Substring(5).Trim()
    if ($payload -eq '[DONE]') { $State.Done = $true; return '' }
    if ($payload -eq '') { return '' }
    $chunk = $null
    try { $chunk = $payload | ConvertFrom-Json } catch { return '' }
    if ($null -eq $chunk) { return '' }
    if (($chunk.PSObject.Properties.Name -contains 'usage') -and $null -ne $chunk.usage) { $State.Usage = ConvertTo-WtLlmUsage -Usage $chunk.usage }
    if (-not ($chunk.PSObject.Properties.Name -contains 'choices')) { return '' }
    $choice = @($chunk.choices) | Select-Object -First 1
    if ($null -eq $choice) { return '' }
    if (($choice.PSObject.Properties.Name -contains 'finish_reason') -and $choice.finish_reason) {
        $State.FinishReason = [string]$choice.finish_reason
    }
    if (-not ($choice.PSObject.Properties.Name -contains 'delta') -or $null -eq $choice.delta) { return '' }
    $delta = $choice.delta
    $piece = ''
    if (($delta.PSObject.Properties.Name -contains 'content') -and $null -ne $delta.content) {
        $piece = [string]$delta.content
        [void]$State.Content.Append($piece)
    }
    foreach ($reasoningField in @('reasoning_content', 'reasoning')) {
        if (($delta.PSObject.Properties.Name -contains $reasoningField) -and $null -ne $delta.$reasoningField) {
            $rp = [string]$delta.$reasoningField
            [void]$State.Reasoning.Append($rp)
            $State.LastReasoningPiece = $State.LastReasoningPiece + $rp
        }
    }
    if (($delta.PSObject.Properties.Name -contains 'tool_calls') -and $null -ne $delta.tool_calls) {
        $unindexedPos = 0
        foreach ($tc in @($delta.tool_calls)) {
            $index = -1
            if (($tc.PSObject.Properties.Name -contains 'index') -and $null -ne $tc.index) {
                $parsed = 0
                if ([int]::TryParse([string]$tc.index, [System.Globalization.NumberStyles]::Integer,
                        [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and
                    $parsed -ge 0 -and $parsed -lt 64) {
                    $index = $parsed
                }
            }
            $callId = ''
            if (($tc.PSObject.Properties.Name -contains 'id') -and $tc.id) { $callId = [string]$tc.id }
            $callName = ''
            if (($tc.PSObject.Properties.Name -contains 'function') -and $null -ne $tc.function -and
                ($tc.function.PSObject.Properties.Name -contains 'name') -and $tc.function.name) { $callName = [string]$tc.function.name }
            if ($index -lt 0) {
                $index = $unindexedPos
                $unindexedPos++
                if ($index -lt $State.ToolCalls.Count) {
                    $existing = $State.ToolCalls[$index]
                    $sameCall = $true
                    if ($callId -and [string]$existing.Id -and -not [string]::Equals($callId, [string]$existing.Id, [System.StringComparison]::Ordinal)) { $sameCall = $false }
                    if ($callName -and [string]$existing.Name -and -not [string]::Equals($callName, [string]$existing.Name, [System.StringComparison]::Ordinal)) { $sameCall = $false }
                    if (-not $sameCall) { $index = $State.ToolCalls.Count }
                }
            }
            while ($State.ToolCalls.Count -le $index) {
                $State.ToolCalls.Add(@{ Id = ''; Name = ''; Arguments = (New-Object System.Text.StringBuilder) })
            }
            $slot = $State.ToolCalls[$index]
            if (($tc.PSObject.Properties.Name -contains 'id') -and $tc.id) { $slot.Id = [string]$tc.id }
            if (($tc.PSObject.Properties.Name -contains 'function') -and $null -ne $tc.function) {
                $fn = $tc.function
                if (($fn.PSObject.Properties.Name -contains 'name') -and $fn.name -and -not $slot.Name) { $slot.Name = [string]$fn.name }
                if (($fn.PSObject.Properties.Name -contains 'arguments') -and $null -ne $fn.arguments) { [void]$slot.Arguments.Append([string]$fn.arguments) }
            }
        }
    }
    return $piece
}

function Get-WtLlmStreamResult {
    <#
    .SYNOPSIS
        Freezes the stream state into the client's result triple. A slot
        without an id (some local servers omit them) gets call_<index>,
        because the tool reply must carry a matching tool_call_id.
    #>
    param([Parameter(Mandatory)][hashtable]$State)
    $calls = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $State.ToolCalls.Count; $i++) {
        $slot = $State.ToolCalls[$i]
        $id = [string]$slot.Id
        if (-not $id) { $id = 'call_' + $i }
        $calls.Add([PSCustomObject]@{ Id = $id; Name = [string]$slot.Name; Arguments = $slot.Arguments.ToString() })
    }
    return @{ Content = $State.Content.ToString(); Reasoning = $State.Reasoning.ToString(); ToolCalls = @($calls.ToArray()); FinishReason = [string]$State.FinishReason; Usage = $State.Usage }
}

function ConvertFrom-WtLlmResponseJson {
    <#
    .SYNOPSIS
        The non-stream body -> the same result triple the stream path
        produces. Garbage in (an HTML error page) -> the empty shape.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)
    $empty = @{ Content = ''; Reasoning = ''; ToolCalls = @(); FinishReason = ''; Usage = $null }
    $obj = $null
    try { $obj = $Json | ConvertFrom-Json } catch { return $empty }
    if ($null -eq $obj -or -not ($obj.PSObject.Properties.Name -contains 'choices')) { return $empty }
    $usage = $null
    if (($obj.PSObject.Properties.Name -contains 'usage') -and $null -ne $obj.usage) { $usage = ConvertTo-WtLlmUsage -Usage $obj.usage }
    $choice = @($obj.choices) | Select-Object -First 1
    if ($null -eq $choice) { return $empty }
    $content = ''
    $reasoning = ''
    $message = $null
    if ($choice.PSObject.Properties.Name -contains 'message') { $message = $choice.message }
    if ($null -ne $message -and ($message.PSObject.Properties.Name -contains 'content') -and $null -ne $message.content) {
        $content = [string]$message.content
    }
    if ($null -ne $message) {
        foreach ($reasoningField in @('reasoning_content', 'reasoning')) {
            if (($message.PSObject.Properties.Name -contains $reasoningField) -and $null -ne $message.$reasoningField) {
                $reasoning = [string]$message.$reasoningField
                break
            }
        }
    }
    $calls = New-Object System.Collections.Generic.List[object]
    if ($null -ne $message -and ($message.PSObject.Properties.Name -contains 'tool_calls') -and $null -ne $message.tool_calls) {
        $i = 0
        foreach ($tc in @($message.tool_calls)) {
            $id = ''
            if (($tc.PSObject.Properties.Name -contains 'id') -and $tc.id) { $id = [string]$tc.id }
            if (-not $id) { $id = 'call_' + $i }
            $calls.Add([PSCustomObject]@{ Id = $id; Name = [string]$tc.function.name; Arguments = [string]$tc.function.arguments })
            $i++
        }
    }
    $finish = ''
    if (($choice.PSObject.Properties.Name -contains 'finish_reason') -and $choice.finish_reason) { $finish = [string]$choice.finish_reason }
    return @{ Content = $content; Reasoning = $reasoning; ToolCalls = @($calls.ToArray()); FinishReason = $finish; Usage = $usage }
}

function Get-WtLlmRejectedField {
    <#
    .SYNOPSIS
        PURE: which OPTIONAL request field a 4xx body blames, if any -
        'stream_options' or 'options' (num_ctx) - so the client can drop
        it and retry once. Only a field that was actually sent can be
        blamed. A bare 'options' match strips 'stream_options' first, so
        it cannot match as a substring of it.
    #>
    param([int]$StatusCode, [AllowNull()][AllowEmptyString()][string]$Body, [bool]$IncludeUsage = $false, [int]$NumCtx = 0)
    if ($StatusCode -lt 400 -or $StatusCode -ge 500) { return '' }
    $text = [string]$Body
    $has = { param([string]$Needle) return ($text.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) }
    if ($NumCtx -gt 0 -and (& $has 'num_ctx')) { return 'options' }
    if ($IncludeUsage -and (& $has 'stream_options')) { return 'stream_options' }
    $bare = $text.Replace('stream_options', '')
    if ($NumCtx -gt 0 -and $bare.IndexOf('options', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return 'options' }
    return ''
}

function Get-WtLlmErrorKind {
    <#
    .SYNOPSIS
        One place that turns a transport failure into a user-facing kind.
        ToolsUnsupported requires that tools were actually sent - a plain
        400 whose body happens to say "function" must stay BadRequest.
    #>
    param(
        [int]$StatusCode = 0,
        [AllowNull()][AllowEmptyString()][string]$Body = '',
        [string]$FailureKind = '',
        [bool]$SentTools = $false
    )
    if ($FailureKind -eq 'Connect') { return 'Connect' }
    if ($FailureKind -eq 'Timeout') { return 'Timeout' }
    if ($StatusCode -ge 400 -and $StatusCode -lt 500 -and
        ([string]$Body).IndexOf('not supported when using Codex', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        return 'ChatGptModel'
    }
    if ($StatusCode -eq 401 -or $StatusCode -eq 403) { return 'Auth' }
    if ($StatusCode -eq 404) { return 'NotFound' }
    if ($StatusCode -eq 429) { return 'RateLimit' }
    if ($StatusCode -ge 400 -and $StatusCode -lt 500) {
        if ($SentTools) {
            $text = [string]$Body
            foreach ($needle in @('tool', 'function')) {
                if ($text.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return 'ToolsUnsupported' }
            }
        }
        return 'BadRequest'
    }
    if ($StatusCode -ge 500) { return 'Server' }
    return 'Unknown'
}

function Get-WtLlmErrorText {
    <#
    .SYNOPSIS
        Localized error line for a kind, with the server's own words as a
        clipped tail so the real reason is never hidden.
    #>
    param(
        [Parameter(Mandatory)][string]$Kind,
        [AllowNull()][AllowEmptyString()][string]$Detail = ''
    )
    $text = [string](Get-Translation ('AsErr' + $Kind))
    if (-not $text) { $text = [string](Get-Translation 'AsErrUnknown') }
    $tail = ([string]$Detail).Trim()
    if ($tail.Length -gt 200) { $tail = $tail.Substring(0, 200) + '~' }
    if ($tail) { return ($text + ' (' + $tail + ')') }
    return $text
}

function Test-WtLlmHeaderAllowed {
    <#
    .SYNOPSIS
        PURE: whether a header may go through HttpWebRequest's Headers
        collection. The restricted ones have their own properties and
        THROW when set this way, so a caller that names one is refused
        here rather than crashing the request. Ordinal-insensitive
        comparison, not -eq: tr-TR's dotless i would mis-match 'Accept'.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Name)
    if (-not $Name) { return $false }
    $restricted = @('Accept', 'Connection', 'Content-Length', 'Content-Type', 'Date', 'Expect',
        'Host', 'If-Modified-Since', 'Range', 'Referer', 'Transfer-Encoding', 'User-Agent', 'Proxy-Connection')
    foreach ($blocked in $restricted) {
        if ([string]::Equals($Name, $blocked, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Invoke-WtLlmHttpTransport {
    <#
    .SYNOPSIS
        The one real network call. Streaming reads the response line by
        line (Invoke-RestMethod buffers, so it cannot stream), calls
        OnLine per line and polls ShouldCancel between lines; a cancel
        aborts the request and the partial state stays with the caller.
    #>
    param([Parameter(Mandatory)][hashtable]$Request)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $req = $null
    try { $req = [System.Net.HttpWebRequest]::Create([string]$Request.Uri) }
    catch { return @{ Ok = $false; StatusCode = 0; Body = [string]$_.Exception.Message; Cancelled = $false; Failure = 'Connect' } }
    $req.Method = $(if ($Request.ContainsKey('Method') -and $Request.Method) { [string]$Request.Method } else { 'POST' })
    $timeoutSec = 180
    if ($Request.ContainsKey('TimeoutSec') -and [int]$Request.TimeoutSec -gt 0) { $timeoutSec = [int]$Request.TimeoutSec }
    $req.Timeout = 1000 * $timeoutSec
    $req.ReadWriteTimeout = $req.Timeout
    $req.ContentType = $(if ($Request.ContainsKey('ContentType') -and $Request.ContentType) { [string]$Request.ContentType } else { 'application/json; charset=utf-8' })
    $req.Accept = 'application/json'
    if ($Request.ContainsKey('ApiKey') -and $Request.ApiKey) { $req.Headers['Authorization'] = 'Bearer ' + [string]$Request.ApiKey }
    if ($Request.ContainsKey('Headers') -and $null -ne $Request.Headers) {
        foreach ($headerName in @($Request.Headers.Keys)) {
            if (-not (Test-WtLlmHeaderAllowed -Name ([string]$headerName))) { continue }
            $req.Headers[[string]$headerName] = [string]$Request.Headers[$headerName]
        }
    }
    $cancelled = $false
    try {
        if ($req.Method -ne 'GET' -and $Request.ContainsKey('Body') -and $null -ne $Request.Body) {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Request.Body)
            $req.ContentLength = $bytes.Length
            $stream = $req.GetRequestStream()
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        }
        $resp = $req.GetResponse()
        try {
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
            try {
                if ($Request.ContainsKey('Stream') -and $Request.Stream -and $Request.ContainsKey('OnLine') -and $Request.OnLine) {
                    while ($null -ne ($line = $reader.ReadLine())) {
                        & $Request.OnLine $line
                        if ($Request.ContainsKey('ShouldCancel') -and $Request.ShouldCancel -and (& $Request.ShouldCancel)) {
                            $cancelled = $true
                            $req.Abort()
                            break
                        }
                    }
                    return @{ Ok = (-not $cancelled); StatusCode = [int]$resp.StatusCode; Body = ''; Cancelled = $cancelled; Failure = '' }
                }
                return @{ Ok = $true; StatusCode = [int]$resp.StatusCode; Body = $reader.ReadToEnd(); Cancelled = $false; Failure = '' }
            }
            finally { $reader.Dispose() }
        }
        finally { $resp.Dispose() }
    }
    catch [System.Net.WebException] {
        $webEx = $_.Exception
        if ($cancelled) { return @{ Ok = $false; StatusCode = 0; Body = ''; Cancelled = $true; Failure = '' } }
        if ($webEx.Status -eq [System.Net.WebExceptionStatus]::Timeout) { return @{ Ok = $false; StatusCode = 0; Body = ''; Cancelled = $false; Failure = 'Timeout' } }
        $status = 0
        $body = ''
        if ($null -ne $webEx.Response) {
            try {
                $status = [int]$webEx.Response.StatusCode
                $errReader = New-Object System.IO.StreamReader($webEx.Response.GetResponseStream(), [System.Text.Encoding]::UTF8)
                try { $body = $errReader.ReadToEnd() } finally { $errReader.Dispose() }
            }
            catch { $null = $_ }
        }
        if ($status -eq 0) { return @{ Ok = $false; StatusCode = 0; Body = [string]$webEx.Message; Cancelled = $false; Failure = 'Connect' } }
        return @{ Ok = $false; StatusCode = $status; Body = $body; Cancelled = $false; Failure = '' }
    }
    catch {
        if ($cancelled) { return @{ Ok = $false; StatusCode = 0; Body = ''; Cancelled = $true; Failure = '' } }
        return @{ Ok = $false; StatusCode = 0; Body = [string]$_.Exception.Message; Cancelled = $false; Failure = 'Connect' }
    }
}

function Invoke-WtLlmChat {
    <#
    .SYNOPSIS
        One model turn against an OpenAI-compatible endpoint. Tries the
        stream first; a 4xx whose body mentions "stream" retries plain.
        -Compat remembers, across calls, which optional field a server
        rejected; the transport is injectable so every test runs without
        a network. Returns @{ Ok; Content; Reasoning; ToolCalls;
        FinishReason; ErrorKind; ErrorText; Cancelled; Usage }.
    #>
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [AllowNull()][AllowEmptyString()][string]$ApiKey = '',
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Messages,
        [AllowEmptyCollection()][array]$Tools = @(),
        [string]$ToolChoice = '',
        [scriptblock]$OnDelta = $null,
        [scriptblock]$OnReasoningDelta = $null,
        [scriptblock]$ShouldCancel = { $false },
        [int]$TimeoutSec = 180,
        [bool]$Stream = $true,
        [double]$Temperature = -1,
        [int]$MaxTokens = 0,
        [int]$NumCtx = 0,
        [AllowNull()][hashtable]$Compat = $null,
        [scriptblock]$Transport = { param($Request) Invoke-WtLlmHttpTransport -Request $Request }
    )
    $uri = Get-WtLlmChatUri -Endpoint $Endpoint
    $sentTools = (@($Tools).Count -gt 0)
    if ($null -eq $Compat) { $Compat = @{} }
    $includeUsage = -not ($Compat.ContainsKey('DropStreamOptions') -and $Compat.DropStreamOptions)
    $effectiveNumCtx = $(if ($Compat.ContainsKey('DropOptions') -and $Compat.DropOptions) { 0 } else { [int]$NumCtx })
    $answer = { param($Ok, $Content, $Calls, $Finish, $Kind, $Detail, $Cancelled, $Reasoning, $Usage)
        return @{
            Ok = [bool]$Ok; Content = [string]$Content; ToolCalls = @($Calls); FinishReason = [string]$Finish
            ErrorKind = [string]$Kind
            ErrorText = $(if ($Kind) { Get-WtLlmErrorText -Kind ([string]$Kind) -Detail ([string]$Detail) } else { '' })
            Cancelled = [bool]$Cancelled
            Reasoning = [string]$Reasoning
            Usage = $Usage
        }
    }
    $r = $null
    if ($Stream) {
        for ($attempt = 0; $attempt -lt 3; $attempt++) {
            $state = New-WtLlmStreamState
            $onLine = { param($Line)
                $piece = Add-WtLlmStreamLine -State $state -Line $Line
                if ($piece -and $OnDelta) { & $OnDelta $piece }
                if ($state.LastReasoningPiece -and $OnReasoningDelta) { & $OnReasoningDelta $state.LastReasoningPiece }
            }
            $body = ConvertTo-WtLlmRequestBody -Model $Model -Messages $Messages -Tools $Tools -Stream $true -ToolChoice $ToolChoice -Temperature $Temperature -MaxTokens $MaxTokens -IncludeUsage $includeUsage -NumCtx $effectiveNumCtx
            $r = & $Transport @{ Uri = $uri; Method = 'POST'; ApiKey = $ApiKey; Body = $body; Stream = $true; TimeoutSec = $TimeoutSec; OnLine = $onLine; ShouldCancel = $ShouldCancel }
            if ($r.Cancelled) {
                $partial = Get-WtLlmStreamResult -State $state
                return (& $answer $false $partial.Content @() '' '' '' $true $partial.Reasoning $null)
            }
            if ($r.Ok) {
                $done = Get-WtLlmStreamResult -State $state
                return (& $answer $true $done.Content $done.ToolCalls $done.FinishReason '' '' $false $done.Reasoning $done.Usage)
            }
            $rejected = Get-WtLlmRejectedField -StatusCode ([int]$r.StatusCode) -Body ([string]$r.Body) -IncludeUsage $includeUsage -NumCtx $effectiveNumCtx
            if ([string]::Equals($rejected, 'stream_options', [System.StringComparison]::Ordinal)) { $Compat['DropStreamOptions'] = $true; $includeUsage = $false; continue }
            if ([string]::Equals($rejected, 'options', [System.StringComparison]::Ordinal)) { $Compat['DropOptions'] = $true; $effectiveNumCtx = 0; continue }
            break
        }
        $retryPlain = ($r.StatusCode -ge 400 -and $r.StatusCode -lt 500 -and
            ([string]$r.Body).IndexOf('stream', [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
        if (-not $retryPlain) {
            $kind = Get-WtLlmErrorKind -StatusCode ([int]$r.StatusCode) -Body ([string]$r.Body) -FailureKind ([string]$r.Failure) -SentTools $sentTools
            return (& $answer $false '' @() '' $kind ([string]$r.Body) $false '' $null)
        }
    }
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $body = ConvertTo-WtLlmRequestBody -Model $Model -Messages $Messages -Tools $Tools -Stream $false -ToolChoice $ToolChoice -Temperature $Temperature -MaxTokens $MaxTokens -NumCtx $effectiveNumCtx
        $r = & $Transport @{ Uri = $uri; Method = 'POST'; ApiKey = $ApiKey; Body = $body; Stream = $false; TimeoutSec = $TimeoutSec; ShouldCancel = $ShouldCancel }
        if ($r.Ok) { break }
        $rejected = Get-WtLlmRejectedField -StatusCode ([int]$r.StatusCode) -Body ([string]$r.Body) -IncludeUsage $false -NumCtx $effectiveNumCtx
        if ([string]::Equals($rejected, 'options', [System.StringComparison]::Ordinal)) { $Compat['DropOptions'] = $true; $effectiveNumCtx = 0; continue }
        break
    }
    if (-not $r.Ok) {
        $kind = Get-WtLlmErrorKind -StatusCode ([int]$r.StatusCode) -Body ([string]$r.Body) -FailureKind ([string]$r.Failure) -SentTools $sentTools
        return (& $answer $false '' @() '' $kind ([string]$r.Body) $false '' $null)
    }
    $parsed = ConvertFrom-WtLlmResponseJson -Json ([string]$r.Body)
    if ($OnReasoningDelta -and $parsed.Reasoning) { & $OnReasoningDelta ([string]$parsed.Reasoning) }
    if ($OnDelta -and $parsed.Content) { & $OnDelta ([string]$parsed.Content) }
    return (& $answer $true $parsed.Content $parsed.ToolCalls $parsed.FinishReason '' '' $false $parsed.Reasoning $parsed.Usage)
}

