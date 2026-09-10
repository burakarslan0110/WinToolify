# The assistant's agent loop and conversation-trimming rules. Client and
# dispatch are injected - this file knows nothing about HTTP or tools.
# Covered by: tests/AssistantAgent.Tests.ps1

function Get-WtAssistantMessageChars {
    <#
    .SYNOPSIS
        Rough size of one message: content plus tool-call arguments.
    #>
    param([Parameter(Mandatory)]$Message)
    $chars = 0
    if ($Message.ContainsKey('content') -and $null -ne $Message.content) { $chars += ([string]$Message.content).Length }
    if ($Message.ContainsKey('tool_calls')) {
        foreach ($call in @($Message.tool_calls)) {
            try { $chars += ([string]$call.'function'.arguments).Length } catch { $null = $_ }
        }
    }
    return $chars
}

function Get-WtAssistantToolResultDigest {
    <#
    .SYNOPSIS
        PURE: what a cleared tool result leaves behind. A search keeps the
        ids of its rows; a suggest keeps every "n: id" line UNCUT, since
        the card stays valid on screen and the model must still know which
        number is which; anything else keeps its first line, cut at -Max.
    #>
    param([AllowEmptyString()][string]$Name, [AllowNull()][AllowEmptyString()][string]$Content, [int]$Max = 120)
    $lines = @(([string]$Content -split "`n") | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($lines.Count -eq 0) { return '' }
    $digest = $lines[0]
    $keepWhole = $false
    if ([string]::Equals([string]$Name, 'search_wintoolify', [System.StringComparison]::Ordinal)) {
        $ids = New-Object System.Collections.Generic.List[string]
        foreach ($line in $lines) {
            $sep = $line.IndexOf(' | ', [System.StringComparison]::Ordinal)
            if ($sep -lt 0) { continue }
            $first = $line.Substring(0, $sep).Trim()
            if ([string]::Equals($first, 'id', [System.StringComparison]::Ordinal)) { continue }
            $ids.Add($first)
        }
        if ($ids.Count -gt 0) { $digest = ($ids.ToArray() -join '; ') }
    }
    elseif ([string]::Equals([string]$Name, 'suggest_wintoolify', [System.StringComparison]::Ordinal)) {
        $numbered = @($lines | Where-Object { $_ -cmatch '^[0-9]+: ' })
        if ($numbered.Count -gt 0) { $digest = ($numbered -join '; '); $keepWhole = $true }
    }
    if (-not $keepWhole -and $Max -gt 1 -and $digest.Length -gt $Max) { $digest = $digest.Substring(0, $Max - 1) + '~' }
    return $digest
}

function Get-WtAssistantTrimmedMessages {
    <#
    .SYNOPSIS
        Trims history in two stages: first every tool body outside the
        current user turn (KeepToolTurns=1) becomes a one-line digest stub
        (Get-WtAssistantToolResultDigest); only if MaxChars is still
        exceeded do the oldest user..assistant blocks drop, oldest first.
        A "turn" means a user-message block, not a tool round, since the
        multi-round gather/search/suggest flow for the CURRENT question
        must survive whole. Pure - returns copies; DroppedPairs counts
        what it did.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Messages,
        [int]$MaxChars = 40000,
        [int]$KeepToolTurns = 1
    )
    $working = New-Object System.Collections.Generic.List[object]
    foreach ($message in @($Messages)) {
        $copy = @{}
        foreach ($key in $message.Keys) { $copy[$key] = $message[$key] }
        if ($message.ContainsKey('tool_calls')) {
            $copy['tool_calls'] = @(foreach ($call in @($message.tool_calls)) {
                @{ id = [string]$call.id; type = [string]$call.type; 'function' = @{ name = [string]$call.'function'.name; arguments = [string]$call.'function'.arguments } }
            })
        }
        $working.Add($copy)
    }
    $argsById = @{}
    foreach ($message in $working) {
        if (-not $message.ContainsKey('tool_calls')) { continue }
        foreach ($call in @($message.tool_calls)) { $argsById[[string]$call.id] = [string]$call.'function'.arguments }
    }
    $turnStarts = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $working.Count; $i++) {
        if ([string]$working[$i].role -eq 'user') { $turnStarts.Add($i) }
    }
    $keepFrom = [int]::MaxValue
    if ($turnStarts.Count -gt 0) {
        $keepIndex = [Math]::Max(0, $turnStarts.Count - [Math]::Max(0, $KeepToolTurns))
        if ($keepIndex -lt $turnStarts.Count) { $keepFrom = $turnStarts[$keepIndex] }
    }
    $stubbed = 0
    for ($i = 0; $i -lt $working.Count; $i++) {
        if ($i -ge $keepFrom) { continue }
        $role = [string]$working[$i].role
        if ($role -eq 'assistant' -and $working[$i].ContainsKey('tool_calls')) {
            foreach ($call in @($working[$i].tool_calls)) {
                $a = [string]$call.'function'.arguments
                if ($a.Length -gt 60) { $call.'function'.arguments = $a.Substring(0, 59) + '~' }
            }
            continue
        }
        if ($role -ne 'tool') { continue }
        $name = $(if ($working[$i].ContainsKey('name')) { [string]$working[$i].name } else { 'tool' })
        $callArgs = ''
        if ($working[$i].ContainsKey('tool_call_id') -and $argsById.ContainsKey([string]$working[$i].tool_call_id)) { $callArgs = [string]$argsById[[string]$working[$i].tool_call_id] }
        if ($callArgs.Length -gt 40) { $callArgs = $callArgs.Substring(0, 39) + '~' }
        $digest = Get-WtAssistantToolResultDigest -Name $name -Content ([string]$working[$i].content)
        $working[$i].content = ('[tool result cleared: ' + $name + '(' + $callArgs + ')' + $(if ($digest) { ' -> ' + $digest } else { '' }) + ']')
        $stubbed++
    }
    $dropped = 0
    $total = 0
    foreach ($message in $working) { $total += Get-WtAssistantMessageChars -Message $message }
    while ($total -gt $MaxChars -and $working.Count -gt 2) {
        if ([string]$working[0].role -ne 'user') { $null = $working[0]; $working.RemoveAt(0); continue }
        $end = 1
        while ($end -lt $working.Count -and [string]$working[$end].role -ne 'user') { $end++ }
        if ($end -ge $working.Count) { break }
        for ($i = 0; $i -lt $end; $i++) { $working.RemoveAt(0) }
        $dropped++
        $total = 0
        foreach ($message in $working) { $total += Get-WtAssistantMessageChars -Message $message }
    }
    return @{ Messages = @($working.ToArray()); StubbedTools = $stubbed; DroppedPairs = $dropped }
}

function Remove-WtAssistantOpenToolTurn {
    <#
    .SYNOPSIS
        Strips a trailing half-open tool round in place: tool replies at
        the tail, then the assistant+tool_calls message that owns them.
        An assistant message with unanswered tool_calls makes many servers
        reject the whole next request with a 400, so after a cancel or an
        error the conversation must end on user text or a completed answer.
    #>
    param([Parameter(Mandatory)]$Messages)
    while ($Messages.Count -gt 0) {
        $last = $Messages[$Messages.Count - 1]
        $role = [string]$last.role
        if ($role -eq 'tool') { $Messages.RemoveAt($Messages.Count - 1); continue }
        if ($role -eq 'assistant' -and $last.ContainsKey('tool_calls')) { $Messages.RemoveAt($Messages.Count - 1); continue }
        break
    }
}

function Get-WtAssistantCallKey {
    <#
    .SYNOPSIS
        PURE: the repeat-detection key - name plus the arguments in
        canonical form (keys sorted ordinally, compact), so whitespace
        or key order cannot disguise the same call. Non-JSON arguments
        are used as typed.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name, [AllowNull()][AllowEmptyString()][string]$Arguments)
    $text = ([string]$Arguments).Trim()
    $canonical = $text
    if ($text) {
        $parsed = $null
        try { $parsed = $text | ConvertFrom-Json } catch { $parsed = $null }
        if ($null -ne $parsed -and ($parsed -is [System.Management.Automation.PSCustomObject])) {
            $names = [string[]]@($parsed.PSObject.Properties.Name)
            [array]::Sort($names, [System.StringComparer]::Ordinal)
            $sorted = [ordered]@{}
            foreach ($propertyName in $names) { $sorted[[string]$propertyName] = $parsed.$propertyName }
            $canonical = [string](ConvertTo-Json -InputObject $sorted -Depth 8 -Compress)
        }
    }
    return ($Name + "`n" + $canonical)
}

function Get-WtAssistantRecoveredToolCalls {
    <#
    .SYNOPSIS
        Function-calling rescue for models that write the call as text:
        every fenced json block shaped {"name": <one of -Names>,
        "arguments": <object>} becomes a call (ids rec_1..) and leaves the
        visible text; -Names must be the schemas actually sent this round,
        not the whole registry, so an unoffered tool is never recovered.
        Anything else stays text; at most Max calls are recovered.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Content,
        [AllowEmptyCollection()][string[]]$Names = @(),
        [int]$Max = 4,
        [string]$IdPrefix = 'rec_'
    )
    $text = [string]$Content
    $calls = New-Object System.Collections.Generic.List[object]
    if (-not $text) { return @{ Calls = @(); Text = $text } }
    $pattern = [regex]::new('```json\s*\r?\n(?<body>[\s\S]*?)\r?\n\s*```', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    $fenceMatches = $pattern.Matches($text)
    $kept = New-Object System.Text.StringBuilder
    $cursor = 0
    foreach ($m in $fenceMatches) {
        $accepted = $false
        if ($calls.Count -lt $Max) {
            $obj = $null
            try { $obj = ([string]$m.Groups['body'].Value) | ConvertFrom-Json } catch { $obj = $null }
            if ($null -ne $obj -and ($obj.PSObject.Properties.Name -contains 'name') -and ($obj.PSObject.Properties.Name -contains 'arguments')) {
                $name = [string]$obj.name
                $known = $false
                foreach ($n in @($Names)) { if ([string]::Equals([string]$n, $name, [System.StringComparison]::Ordinal)) { $known = $true } }
                $argumentsValue = $obj.arguments
                if ($known -and $null -ne $argumentsValue -and ($argumentsValue -is [System.Management.Automation.PSCustomObject])) {
                    $calls.Add([PSCustomObject]@{ Id = ($IdPrefix + ($calls.Count + 1)); Name = $name; Arguments = [string](ConvertTo-Json -InputObject $argumentsValue -Depth 8 -Compress) })
                    $accepted = $true
                }
            }
        }
        if ($accepted) {
            [void]$kept.Append($text.Substring($cursor, $m.Index - $cursor))
            $cursor = $m.Index + $m.Length
        }
    }
    [void]$kept.Append($text.Substring($cursor))
    return @{ Calls = @($calls.ToArray()); Text = $kept.ToString().Trim() }
}

function Invoke-WtAssistantTurn {
    <#
    .SYNOPSIS
        One user message through the agent loop: client -> tool calls ->
        dispatch -> paired tool replies -> client again, until a text
        answer or MaxRounds. On failure the pending user message and any
        half-open tool round are removed so a retry does not resend a
        stale question or an unanswered tool_calls.

        ToolBudgetSeconds bounds only dispatch time, never generation; a
        spent budget gives remaining calls {error: 'time budget
        exhausted'} without cancelling one in flight, and a dispatch
        exception is masked to 'tool dispatch failed: <name>' since the
        raw .NET message could leak local paths or the machine name.
        ToolCallCaps also refuses an exact repeat (same name, same
        arguments); refused and budget-exhausted calls are never traced
        or announced. Returns @{ Ok; FinalText; ErrorText; Cancelled;
        Rounds; Dropped }, where Dropped is the largest DroppedPairs any
        round saw, not the sum.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Conversation,
        [Parameter(Mandatory)][string]$UserText,
        [Parameter(Mandatory)][scriptblock]$Client,
        [Parameter(Mandatory)][scriptblock]$Dispatch,
        [AllowEmptyCollection()][array]$Schemas = @(),
        [int]$MaxRounds = 5,
        [int]$HistoryMaxChars = 40000,
        [int]$KeepToolTurns = 1,
        [scriptblock]$OnTrace = $null,
        [scriptblock]$OnToolDone = $null,
        [scriptblock]$OnToolStart = $null,
        [string]$SystemPrompt = (Get-WtAssistantSystemPrompt),
        [AllowNull()][AllowEmptyString()][string]$SystemExtra = '',
        [int]$ToolBudgetSeconds = 180,
        [scriptblock]$ElapsedSeconds = $null,
        [bool]$RecoverToolCalls = $true,
        [scriptblock]$OnRecovered = $null,
        [AllowNull()][hashtable]$ToolCallCaps = @{ web_search = 2; fetch_page = 3; '*' = 12 }
    )
    $messages = $Conversation.Messages
    $messages.Add(@{ role = 'user'; content = $UserText })
    $dropped = 0
    $callCounts = @{}
    $callsTotal = 0
    $callsSeen = @{}
    $capFor = { param($Name)
        if ($null -eq $ToolCallCaps) { return -1 }
        if ($ToolCallCaps.ContainsKey($Name)) { return [int]$ToolCallCaps[$Name] }
        return -1
    }
    $toolTime = New-Object System.Diagnostics.Stopwatch
    $fail = { param($Result, $Round)
        Remove-WtAssistantOpenToolTurn -Messages $messages
        if ($messages.Count -gt 0 -and [string]$messages[$messages.Count - 1].role -eq 'user') { $messages.RemoveAt($messages.Count - 1) }
        return @{
            Ok = $false
            FinalText = $(if ($null -ne $Result) { [string]$Result.Content } else { '' })
            ErrorText = $(if ($null -ne $Result) { [string]$Result.ErrorText } else { '' })
            Cancelled = [bool]($null -ne $Result -and $Result.Cancelled)
            Rounds = [int]$Round
            Dropped = [int]$dropped
        }
    }
    for ($round = 1; $round -le ($MaxRounds + 1); $round++) {
        $trimmed = Get-WtAssistantTrimmedMessages -Messages $messages.ToArray() -MaxChars $HistoryMaxChars -KeepToolTurns $KeepToolTurns
        $dropped = [Math]::Max($dropped, [int]$trimmed.DroppedPairs)
        $systemList = @(@{ role = 'system'; content = $SystemPrompt })
        if ($SystemExtra) { $systemList += @{ role = 'system'; content = $SystemExtra } }
        $sendList = @($systemList) + @($trimmed.Messages)
        $result = & $Client $sendList $round
        if ($null -eq $result -or -not $result.Ok) { return (& $fail $result $round) }
        if ($RecoverToolCalls -and @($Schemas).Count -gt 0 -and @($result.ToolCalls).Count -eq 0 -and [string]$result.Content) {
            $recovered = Get-WtAssistantRecoveredToolCalls -Content ([string]$result.Content) -Names ([string[]]@(@($Schemas) | ForEach-Object { [string]$_.'function'.name })) -IdPrefix ('rec' + $round + '_')
            if (@($recovered.Calls).Count -gt 0) {
                $result.ToolCalls = @($recovered.Calls)
                $result.Content = [string]$recovered.Text
                if ($null -ne $OnRecovered) { try { & $OnRecovered (@($recovered.Calls).Count) } catch { $null = $_ } }
            }
        }
        if (@($result.ToolCalls).Count -eq 0 -or $round -gt $MaxRounds) {
            $messages.Add(@{ role = 'assistant'; content = [string]$result.Content })
            return @{ Ok = $true; FinalText = [string]$result.Content; ErrorText = ''; Cancelled = $false; Rounds = $round; Dropped = [int]$dropped }
        }
        $toolCallsOut = New-Object System.Collections.Generic.List[object]
        foreach ($call in @($result.ToolCalls)) {
            $toolCallsOut.Add(@{ id = [string]$call.Id; type = 'function'; 'function' = @{ name = [string]$call.Name; arguments = [string]$call.Arguments } })
        }
        $messages.Add(@{ role = 'assistant'; content = $(if ($result.Content) { [string]$result.Content } else { $null }); tool_calls = @($toolCallsOut.ToArray()) })
        foreach ($call in @($result.ToolCalls)) {
            $spent = $false
            if ($ToolBudgetSeconds -gt 0) {
                $elapsed = $(if ($null -eq $ElapsedSeconds) { [double]$toolTime.Elapsed.TotalSeconds } else { [double](& $ElapsedSeconds) })
                $spent = ($elapsed -ge $ToolBudgetSeconds)
            }
            if ($spent) {
                $messages.Add(@{ role = 'tool'; tool_call_id = [string]$call.Id; name = [string]$call.Name
                    content = [string](ConvertTo-WtAssistantToolText -Value @{ error = 'time budget exhausted' })
                })
                continue
            }
            $callName = [string]$call.Name
            $refusal = ''
            $nameCap = [int](& $capFor $callName)
            $totalCap = [int](& $capFor '*')
            $callKey = Get-WtAssistantCallKey -Name $callName -Arguments ([string]$call.Arguments)
            if ($callsSeen.ContainsKey($callKey)) {
                $refusal = 'repeated call: ' + $callName + ' already ran with these exact arguments in this turn - its result is above, use it'
            }
            elseif ($nameCap -ge 0 -and [int]$callCounts[$callName] -ge $nameCap) {
                $refusal = 'call limit reached: ' + $callName + ' may run at most ' + $nameCap + ' times per question - answer with what you have'
            }
            elseif ($totalCap -ge 0 -and $callsTotal -ge $totalCap) {
                $refusal = 'call limit reached: at most ' + $totalCap + ' tool calls per question - answer with what you have'
            }
            if ($refusal) {
                $messages.Add(@{ role = 'tool'; tool_call_id = [string]$call.Id; name = $callName
                    content = [string](ConvertTo-WtAssistantToolText -Value @{ error = $refusal })
                })
                continue
            }
            if ($null -ne $OnToolStart) { try { & $OnToolStart ([string]$call.Name) ([string]$call.Arguments) } catch { $null = $_ } }
            if ($OnTrace) { try { & $OnTrace ([string]$call.Name) ([string]$call.Arguments) } catch { $null = $_ } }
            $resultJson = ''
            $callWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $toolTime.Start()
            try { $resultJson = [string](& $Dispatch ([string]$call.Name) ([string]$call.Arguments)) }
            catch { $resultJson = [string](ConvertTo-WtAssistantToolText -Value @{ error = ('tool dispatch failed: ' + [string]$call.Name) }) }
            $toolTime.Stop()
            $callCounts[$callName] = [int]$callCounts[$callName] + 1
            $callsTotal++
            $callsSeen[$callKey] = $true
            if ($null -ne $OnToolDone) {
                $callOk = -not ([string]$resultJson).StartsWith('error:', [System.StringComparison]::Ordinal)
                try { & $OnToolDone ([string]$call.Name) ([double]$callWatch.Elapsed.TotalSeconds) ([int]$resultJson.Length) $callOk } catch { $null = $_ }
            }
            $messages.Add(@{ role = 'tool'; tool_call_id = [string]$call.Id; name = [string]$call.Name; content = $resultJson })
        }
    }
    return (& $fail $null ($MaxRounds + 1))
}
