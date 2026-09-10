# The WinToolify Asistan chat screen: opening gate, the interactive loop,
# the send path and transcript saving.
# Covered by: tests/AssistantScreen.Tests.ps1

function Test-WtAssistantRemoteEndpoint {
    <#
    .SYNOPSIS
        Whether an endpoint leaves this machine. Loopback is decided by
        parsing the host as an IP address, not by string match, because
        Uri.DnsSafeHost expands IPv6 literals. Empty counts as local,
        unparsable as remote, so the privacy gate errs toward asking.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Endpoint)
    if (-not $Endpoint) { return $false }
    $uri = $null
    try { $uri = [uri]$Endpoint } catch { return $true }
    if (-not $uri.IsAbsoluteUri) { return $true }
    if ([string]::Equals([string]$uri.Host, 'localhost', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    $ip = $null
    if ([System.Net.IPAddress]::TryParse(([string]$uri.DnsSafeHost).Trim('[', ']'), [ref]$ip) -and [System.Net.IPAddress]::IsLoopback($ip)) { return $false }
    return $true
}

function ConvertTo-WtAssistantNumCtx {
    <#
    .SYNOPSIS
        PURE: the AssistantNumCtx setting (a string, '' = unset) as a
        positive integer, 0 for anything else, capped at 4,000,000 so the
        history-window arithmetic can never overflow Int32. Invariant
        parse - never a culture cast on user text.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)
    $parsed = 0
    if ([int]::TryParse(([string]$Text).Trim(), [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and $parsed -gt 0) { return [Math]::Min($parsed, 4000000) }
    return 0
}

function Get-WtAssistantHistoryMaxChars {
    <#
    .SYNOPSIS
        PURE: the history window in characters. Cloud endpoints and an
        unset num_ctx keep 40000; an Ollama endpoint with num_ctx gets
        max(12000, num_ctx*3 - prefixChars - 2000).
    #>
    param([int]$NumCtx = 0, [int]$PrefixChars = 0, [bool]$Ollama = $false)
    if (-not $Ollama -or $NumCtx -le 0) { return 40000 }
    return [int][Math]::Max(12000, ($NumCtx * 3) - $PrefixChars - 2000)
}

function Add-WtAssistantUsage {
    <#
    .SYNOPSIS
        Adds one round's usage to the turn total the screen keeps for
        /durum: the three counts are summed (every round re-sends the
        prefix, so the sum is what the provider bills), LastPromptTokens
        is the latest round's prompt (the context-warning measure).
    #>
    param([Parameter(Mandatory)][hashtable]$Total, [AllowNull()]$Usage)
    if ($null -eq $Usage) { return }
    $Total['PromptTokens'] = [int]$Total['PromptTokens'] + [int]$Usage.PromptTokens
    $Total['CompletionTokens'] = [int]$Total['CompletionTokens'] + [int]$Usage.CompletionTokens
    $Total['CachedTokens'] = [int]$Total['CachedTokens'] + [int]$Usage.CachedTokens
    $Total['LastPromptTokens'] = [int]$Usage.PromptTokens
    $Total['Rounds'] = [int]$Total['Rounds'] + 1
}

function Get-WtAssistantSystemPrompt {
    <#
    .SYNOPSIS
        system[0], STATIC: identity, scope, the suggest-only rule, the
        tool rules, the output format and the five slash names a user
        may ask about. No date, no language, no machine fact, no slash
        help table - those live in system[1] or on the screen, so this
        text is byte-identical across every request and a provider
        prefix cache can keep it. Under 2700 characters, pinned.
    #>
    return ('You are WinToolify Asistan, the assistant built into WinToolify, an open-source Windows optimization tool. ' +
        'If asked who you are or which model you are, say: WinToolify Asistan, running on the model configured under /ayarlar; never name a model vendor. ' +
        'Scope: Windows, this computer (hardware, drivers, software, services, startup, storage, network, security, performance, errors, updates), WinToolify itself and other technical questions. ' +
        'Decline anything else in one short sentence, without calling a tool. Greetings get one friendly sentence that offers help with this computer. ' +
        'You never run, apply, remove or undo anything and have no tool for it. For anything WinToolify can do, call search_wintoolify, then offer the fitting entries with suggest_wintoolify: ' +
        'the user types a number and WinToolify''s own confirmation takes over. Never say you started, applied or removed something, never ask the user to type CONFIRM or YES to you; point to the numbers instead ("type 1"). ' +
        'When no entry fits, explain the manual fix (steps or a command); when you are not sure of the facts, research with web_search and fetch_page and cite the sources by url. ' +
        'Tools: read the machine before diagnosing; follow each tool description; never repeat a call with the same or nearly the same words; never call a tool whose result you will not use; ' +
        'prefer the machine profile already in your context over a tool call for the same fact. ' +
        'Interpret every result in plain words for this computer - what it shows, what is normal and what is not, why it matters and what to do next; never paste raw lines. ' +
        'Lines starting with "(note:" or "(result of" at the top of a message come from WinToolify, not the user: what the user ran by number, or a number that matched nothing, and, after "(result of", its output, already on the user''s screen. ' +
        'If the user''s own words follow, answer those; if the message is only the report, explain it: what it found or changed, success or failure and the error if any, what it means, the next step. ' +
        'Never claim you did it; do not re-read that topic with read_system; the numbers on screen stay valid, call suggest_wintoolify only for a different next step. ' +
        'Format: you write for a terminal - short plain sentences, only "- " bullets (numbered lists exist only through suggest_wintoolify, never write your own), no headings or tables, **bold** only for one name or value, `backticks` for commands and file names. ' +
        'The user also has local commands starting with "/" (not tools, you cannot run them; /yardim lists them). If asked, name: /ayarlar (connection), /yeni (new chat), /profil, /notlar, /unut.')
}

function Get-WtAssistantSystemExtra {
    <#
    .SYNOPSIS
        system[1]: the per-session facts the static prompt must not
        carry - today's date, the reply language, the short anonymized
        profile, the saved notes. Built ONCE per session by
        Get-WtAssistantSessionExtra and re-sent byte for byte.
    #>
    param(
        [Parameter(Mandatory)][datetime]$Date,
        [Parameter(Mandatory)][string]$Language,
        [AllowNull()][AllowEmptyString()][string]$ProfileJson = '',
        [AllowNull()][AllowEmptyCollection()][array]$Notes = @(),
        [AllowNull()][hashtable]$Mask = $null
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('date: ' + $Date.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture))
    $lines.Add('reply language: ' + $(if ($Language -eq 'TR') { 'Turkish' } else { 'English' }))
    if ($ProfileJson) { $lines.Add('machine profile (anonymized): ' + $ProfileJson) }
    $noteRows = @($Notes | Where-Object { $null -ne $_ -and [string]$_.text })
    if ($noteRows.Count -gt 0) {
        $lines.Add('notes the user asked you to remember:')
        foreach ($note in $noteRows) {
            $t = [string]$note.text
            if ($null -ne $Mask) { $t = Protect-WtAssistantText -Text $t -Mask $Mask }
            $lines.Add('- ' + $t)
        }
    }
    return ($lines.ToArray() -join "`n")
}

function Get-WtAssistantSessionExtra {
    <#
    .SYNOPSIS
        The frozen system[1]: built on first use from the seams, stored on
        the session, returned unchanged afterwards - so every request of
        a session carries the identical prefix. Reset-WtAssistantSessionExtra
        drops it (profile on/off/refresh, a note saved or deleted, an apply
        the user ran, a new chat).
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Chat,
        [Parameter(Mandatory)][scriptblock]$GetProfile,
        [Parameter(Mandatory)][scriptblock]$GetNotes,
        [AllowNull()][hashtable]$Mask = $null,
        [datetime]$Date = (Get-Date),
        [string]$Language = $script:Language
    )
    if ($Chat.ContainsKey('SystemExtra') -and $null -ne $Chat.SystemExtra) { return [string]$Chat.SystemExtra }
    $profileJson = ''
    try { $profileJson = [string](& $GetProfile) } catch { $profileJson = '' }
    $notes = @()
    try { $notes = @(& $GetNotes) } catch { $notes = @() }
    $extra = Get-WtAssistantSystemExtra -Date $Date -Language $Language -ProfileJson $profileJson -Notes $notes -Mask $Mask
    $Chat.SystemExtra = $extra
    return $extra
}

function Reset-WtAssistantSessionExtra {
    <#
    .SYNOPSIS
        Drops the session's frozen system[1] so the next turn rebuilds it
        after the profile is toggled or refreshed, a note is saved or
        deleted, or a new chat.
    #>
    param([Parameter(Mandatory)][hashtable]$Chat)
    $Chat.SystemExtra = $null
}

function Get-WtAssistantPrivacyLines {
    <#
    .SYNOPSIS
        PURE: the consent text, one array of lines in the active
        language: where the data goes, a heading and four "- " items
        for WHAT goes there, what is masked first, the three tools that
        reach the internet on their own, and the closing guarantee.
        Blank lines separate the groups.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Endpoint)
    return [string[]]@(
        ((Get-Translation 'AsPrivacyLine1') -f $Endpoint)
        ''
        (Get-Translation 'AsPrivacyWhat')
        ('- ' + (Get-Translation 'AsPrivacyItem1'))
        ('- ' + (Get-Translation 'AsPrivacyItem2'))
        ('- ' + (Get-Translation 'AsPrivacyItem3'))
        ('- ' + (Get-Translation 'AsPrivacyItem4'))
        ''
        (Get-Translation 'AsPrivacyMasked')
        (Get-Translation 'AsPrivacyWeb')
        ''
        (Get-Translation 'AsPrivacyLine3')
    )
}

function Invoke-WtAssistantPrivacyGate {
    <#
    .SYNOPSIS
        Once per endpoint, persisted: where the data goes, what kind
        (anonymized), yes/no. A yes sticks for that endpoint, this
        session and every session after, once saved to permissions.json;
        a no asks again. Local endpoints never see this panel. Consent
        is stored keyed to the endpoint itself, not a bare flag, so
        switching endpoints through /ayarlar mid-chat cannot leak an
        earlier approval to a host the user never consented to.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Settings,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Breadcrumb,
        [scriptblock]$ReadAnswer = { param($Lines, $Prompt) Read-WtReplAnswer -Lines $Lines -Prompt $Prompt -Risk 'CAUTION' -Choices @(@{ Label = [string](Get-Translation 'AnswerYes'); Letter = (Get-WtAnswerLetter -Kind 'Yes') }, @{ Label = [string](Get-Translation 'AnswerNo'); Letter = (Get-WtAnswerLetter -Kind 'No') }) },
        [scriptblock]$ReadPermissions = { Read-WtAssistantPermissions },
        [scriptblock]$SavePermissions = { param($P) Save-WtAssistantPermissions -Permissions $P }
    )
    $endpoint = Get-WtAssistantEffectiveEndpoint -Settings $Settings
    if (-not (Test-WtAssistantRemoteEndpoint -Endpoint $endpoint)) { return $true }
    if ($endpoint -and [string]::Equals([string]$script:WtAssistantPrivacyEndpoint, $endpoint, [System.StringComparison]::Ordinal)) { return $true }
    $perms = $null
    try { $perms = & $ReadPermissions } catch { $perms = $null }
    if ($null -ne $perms -and (Test-WtAssistantEndpointAllowed -Endpoint $endpoint -Permissions $perms)) { $script:WtAssistantPrivacyEndpoint = $endpoint; return $true }
    $lines = @(Get-WtAssistantPrivacyLines -Endpoint $endpoint)
    Close-WtReplToolBox
    $answer = & $ReadAnswer $lines (Get-WtYesNoPrompt -Text (Get-Translation 'AsPrivacyPrompt'))
    if (Test-WtAffirmativeAnswer -Answer ([string]$answer)) {
        $script:WtAssistantPrivacyEndpoint = $endpoint
        if ($null -eq $perms) { $perms = @{ v = 1; endpoints = @(); disabled = @() } }
        try { & $SavePermissions (Add-WtAssistantEndpointAllowed -Endpoint $endpoint -Permissions $perms) } catch { $null = $_ }
        return $true
    }
    return $false
}

function Set-WtAssistantSuggestions {
    <#
    .SYNOPSIS
        Stores the resolved suggestion entries on the chat state with
        the active language's label, path and What text, plus the tool
        index's Risk so the row can wear the Actions screen's badge. A
        new answer replaces the whole list.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Chat,
        [AllowEmptyCollection()][array]$Entries = @()
    )
    $isTurkish = ($script:Language -eq 'TR')
    $Chat.Suggestions = @(foreach ($entry in @($Entries)) {
        @{
            Id    = [string]$entry.Id
            Label = [string]$(if ($isTurkish) { $entry.LabelTr } else { $entry.LabelEn })
            Path  = [string]$(if ($isTurkish) { $entry.PathTr } else { $entry.PathEn })
            Risk  = [string]$entry.Risk
            What  = (Get-WtAssistantEntryWhat -Entry $entry -Max 120)
            Entry = $entry
        }
    })
}

function Add-WtAssistantPendingNote {
    <#
    .SYNOPSIS
        Queues one digit-path run note on the chat; the next
        Invoke-WtAssistantSend prepends every queued note to the user's
        text and clears the queue.
    #>
    param([Parameter(Mandatory)][hashtable]$Chat, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if (-not $Text) { return }
    if (-not $Chat.ContainsKey('PendingNotes') -or $null -eq $Chat.PendingNotes) { $Chat.PendingNotes = New-Object System.Collections.Generic.List[string] }
    $Chat.PendingNotes.Add($Text)
}

function Invoke-WtAssistantSuggestion {
    <#
    .SYNOPSIS
        Digit 1-9. A Screen/Winget/stage-only-toggle entry pushes its
        screen or installs in place; a runnable Action/Info row runs
        through Invoke-WtAssistantToolRow; a non-runnable one runs
        through its own delegate and gates; a Toggle is confirmed with
        one Enter/Esc line and applied through WinToolify's own engine
        gates. Whatever ran leaves a transcript row and one pending note
        the next user message carries to the model. A run that finished
        in place with something to tell also fills $Chat.FollowUp with a
        report-turn body, sent immediately as a harness message so the
        model explains the outcome right away; a declined run or a
        pushed/painted screen leaves FollowUp alone since there is
        nothing honest to say yet.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Chat,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Breadcrumb,
        [scriptblock]$RunRow = { param($Entry, $Crumb) Invoke-WtAssistantToolRow -Entry $Entry -Breadcrumb $Crumb },
        [scriptblock]$RunInline = { param($Entry, $Crumb)
            Invoke-WtReplHop -Action {
                $data = $Entry.Item.Data
                $script:WtPanelBreadcrumb = $Crumb
                if ($data.Power) { Invoke-WtPowerAction -ConsequenceKey ([string]$data.ConsequenceKey) -Breadcrumb $Crumb -Action $data.Action }
                elseif ($data.Action) { & $data.Action | Out-Null }
            }
        },
        [scriptblock]$Confirm = { param($Entry)
            $answer = Read-WtReplAnswer -Lines (Get-WtAssistantDigitConfirmLines -Entry $Entry) -Prompt (Get-WtYesNoPrompt -Text (Get-Translation 'AsDigitApplyPrompt')) -Risk ([string]$Entry.Risk)
            return (Test-WtAffirmativeAnswer -Answer ([string]$answer))
        },
        [scriptblock]$Apply = { param($Ids, $Ctx) Invoke-WtAssistantApply -Ids $Ids -Context $Ctx },
        [scriptblock]$InstallWinget = { param($Entry, $Crumb)
            $id = [regex]::Replace([string]$Entry.Id, '^Winget:', '')
            $lines = @(((Get-Translation 'AsWingetInstallConfirm') -f [string]$Entry.LabelEn))
            $answer = Read-WtReplAnswer -Lines $lines -Prompt (Get-WtYesNoPrompt -Text (Get-Translation 'AsWingetInstallPrompt')) -Risk 'CAUTION'
            if (-not (Test-WtAffirmativeAnswer -Answer ([string]$answer))) { return @{ Ran = $false; Lines = [string[]]@() } }
            $state = @{ Marks = (New-Object 'System.Collections.Generic.List[string]'); Installed = @(); LastSummary = [string[]]@() }
            $null = Invoke-WtReplHop -Action {
                $script:WtPanelBreadcrumb = $Crumb
                $state.Marks.Add($id)
                Invoke-WtWingetStoreRun -State $state -Operation 'Install'
            }
            return @{ Ran = $true; Lines = [string[]]@($state.LastSummary | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) }
        }
    )
    $suggestions = @($Chat.Suggestions)
    if ($Index -lt 1 -or $Index -gt $suggestions.Count) { return $null }
    $pick = $suggestions[$Index - 1]
    $entry = $pick.Entry
    $kind = [string]$entry.Kind
    $mask = Get-WtAssistantMaskContext
    $note = { param($Outcome) Add-WtAssistantPendingNote -Chat $Chat -Text (Format-WtAssistantRunNote -Number $Index -Id ([string]$entry.Id) -Outcome $Outcome -Mask $mask) }
    $cardNumbers = [string[]]@(for ($i = 0; $i -lt $suggestions.Count; $i++) { [string]($i + 1) + ' ' + [string]$suggestions[$i].Label })
    $report = { param($Lines) $Chat.FollowUp = Format-WtAssistantRunReport -Number $Index -Label ([string]$pick.Label) -Lines ([string[]]@($Lines)) -Numbers $cardNumbers -Mask $mask }
    $stageOnlyToggle = ($kind -eq 'Toggle' -and -not $entry.Runnable -and [string]$entry.Screen)
    if ($kind -eq 'Screen' -or $stageOnlyToggle) {
        $script:WtWingetStoreInitialQuery = ''
        & $note 'opened its screen'
        return @{ Nav = 'Push'; Target = [string]$entry.Screen; Char = ''; HasMarks = $false }
    }
    if ($kind -eq 'Winget') {
        $install = & $InstallWinget $entry $Breadcrumb
        $installRan = $(if ($install -is [bool]) { [bool]$install } else { [bool]$install.Ran })
        if (-not $installRan) {
            Reset-WtFrameCache
            Add-WtChatEntry -State $Chat -Kind 'Info' -Text ((Get-Translation 'AsDeclinedTool') -f [string]$pick.Label)
            & $note 'declined'
            return $null
        }
        Reset-WtFrameCache
        foreach ($l in @(Format-WtReplToolRunLines -Label ([string]$pick.Label) -Status (Get-Translation 'AsToolRunOwnScreen'))) { Add-WtChatEntry -State $Chat -Kind 'Tool' -Text $l }
        & $note 'winget install ran on its own screen'
        $summary = [string[]]@()
        if (-not ($install -is [bool])) { $summary = [string[]]@($install.Lines | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) }
        if ($summary.Count -gt 0) { & $report $summary }
        return $null
    }
    if ($kind -eq 'Toggle') {
        if (-not (& $Confirm $entry)) {
            Reset-WtFrameCache
            Add-WtChatEntry -State $Chat -Kind 'Info' -Text ((Get-Translation 'AsDeclinedTool') -f [string]$pick.Label)
            & $note 'declined'
            return $null
        }
        $context = @{
            Mask = $mask; OnSuggest = { param($Valid) }; Breadcrumb = $Breadcrumb
            ReadAnswer = { param($Lines, $Prompt, $Risk) Read-WtReplAnswer -Lines $Lines -Prompt $Prompt -Risk $Risk }
            OnApplied = { param($Lines) foreach ($l in @($Lines)) { Add-WtChatEntry -State $Chat -Kind 'Tool' -Text ('    ' + [string]$script:WtGlyphs.Branch + ' ' + [string]$l) } }
        }
        $result = & $Apply ([string[]]@([string]$entry.Id)) $context
        Reset-WtFrameCache
        Reset-WtAssistantSessionExtra -Chat $Chat
        $outcome = 'applied'
        if (@($result.applied).Count -eq 0) {
            $firstError = ''
            if (@($result.failed).Count -gt 0) { $firstError = [string]$result.failed[0].error }
            if ($firstError) { $outcome = 'failed: ' + $firstError } else { $outcome = 'skipped (gate declined)' }
        }
        & $note $outcome
        if ($outcome -ne 'skipped (gate declined)') { & $report (Get-WtAssistantApplyReportLines -Result $result) }
        return $null
    }
    if ($entry.Runnable) {
        $run = & $RunRow $entry $Breadcrumb
        Reset-WtFrameCache
        $lines = [string[]]@($run.Lines | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        if (-not $run.Ran) {
            foreach ($l in @(Format-WtReplToolRunLines -Label ([string]$pick.Label) -Status (Get-Translation 'AsToolRunRefused'))) { Add-WtChatEntry -State $Chat -Kind 'Tool' -Text ([string]$l) }
            & $note 'refused (not runnable from the chat)'
            return $null
        }
        foreach ($l in @(Format-WtReplToolRunLines -Label ([string]$pick.Label) -Status (Get-Translation 'AsToolRunDone') -Lines $lines -Max 0)) { Add-WtChatEntry -State $Chat -Kind 'Tool' -Text ([string]$l) }
        & $note ('ran (' + $lines.Count + ' output lines shown to the user)')
        & $report $lines
        return $null
    }
    & $RunInline $entry $Breadcrumb
    Reset-WtFrameCache
    foreach ($l in @(Format-WtReplToolRunLines -Label ([string]$pick.Label) -Status (Get-Translation 'AsToolRunOwnScreen'))) { Add-WtChatEntry -State $Chat -Kind 'Tool' -Text ([string]$l) }
    & $note 'opened its own screen'
    return $null
}

function Invoke-WtAssistantSend {
    <#
    .SYNOPSIS
        One user turn through the agent loop, printed as it happens: a
        spinner runs while the model thinks, the answer streams behind one
        bullet, and each tool call opens with "* name(args)" and closes
        with a branch line for time and size. -Harness (report-turn path):
        Text is WinToolify's own report of what the user ran by number, not
        something typed - it reaches the model as a user-role message with
        no transcript entry. The profile getter is passed as $profileSeam,
        not $GetProfile: that name collides with
        Get-WtAssistantSessionExtra's own -GetProfile parameter and would
        shadow into infinite self-recursion.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Chat,
        [Parameter(Mandatory)][PSCustomObject]$Settings,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Breadcrumb,
        [switch]$Harness,
        [switch]$KeepSuggestions,
        [scriptblock]$Turn = { param($ArgTable) Invoke-WtAssistantTurn @ArgTable },
        [scriptblock]$ReadAnswer = { param($Lines, $Prompt, $Risk, $Choices) Read-WtReplAnswer -Lines $Lines -Prompt $Prompt -Risk $Risk -Choices $Choices },
        [scriptblock]$OnDelta = { param($Piece) Hide-WtReplSpinner; Write-WtReplStream -Piece $Piece },
        [scriptblock]$OnReasoningDelta = { param($Piece) Update-WtReplSpinner -AddChars ([string]$Piece).Length },
        [scriptblock]$ShouldCancel = { Sync-WtReplResize | Out-Null; Update-WtReplSpinner; Test-WtReplCancelRequested },
        [scriptblock]$Write = (Get-WtReplDefaultWriter),
        [scriptblock]$GetProfile = { param($S) if ($S.ProfileEnabled) { [string](Get-WtAssistantMachineProfile -Kind 'Short' -OnCold { & $breakStream; Write-WtReplLine -Text ('  ' + (Get-Translation 'AsProfileBuilding')) -Fg 'DarkGray' }).Json } else { '' } },
        [scriptblock]$GetNotes = { @(Read-WtAssistantNotes) },
        [scriptblock]$ReadPermissions = { Read-WtAssistantPermissions }
    )
    if (-not (Invoke-WtAssistantPrivacyGate -Settings $Settings -Breadcrumb $Breadcrumb)) {
        Add-WtChatEntry -State $Chat -Kind 'Info' -Text (Get-Translation 'AsPrivacyDeclined')
        if ($Harness) { Add-WtAssistantPendingNote -Chat $Chat -Text $Text }
        return
    }
    if (-not $Harness) { Add-WtChatEntry -State $Chat -Kind 'User' -Text $Text -Silent }
    $sendText = $Text
    $notesSent = [string[]]@()
    if ($Chat.ContainsKey('PendingNotes') -and $null -ne $Chat.PendingNotes -and $Chat.PendingNotes.Count -gt 0) {
        $notesSent = [string[]]@($Chat.PendingNotes.ToArray())
        $sendText = ($notesSent -join "`n") + "`n" + $Text
        $Chat.PendingNotes.Clear()
    }
    $Chat.Busy = $true
    if (-not ($Harness -or $KeepSuggestions)) { $Chat.Suggestions = @() }
    $listBefore = $Chat.Suggestions
    Reset-WtReplStream
    $width = (Get-WtConsoleSize).Width
    $script:WtReplStream.Width = $width
    $apiKey = Unprotect-WtAssistantSecret -Blob ([string]$Settings.AssistantApiKey)
    $temperature = -1.0
    $parsedT = 0.0
    if ([double]::TryParse([string]$Settings.AssistantTemperature, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedT) -and $parsedT -ge 0) {
        $temperature = $parsedT
    }
    $maxTokens = 0
    $parsedM = 0
    if ([int]::TryParse([string]$Settings.AssistantMaxTokens, [ref]$parsedM) -and $parsedM -gt 0) {
        $maxTokens = $parsedM
    }
    $isOllama = Test-WtLlmOllamaEndpoint -Endpoint (Get-WtAssistantEffectiveEndpoint -Settings $Settings)
    $numCtx = $(if ($isOllama) { ConvertTo-WtAssistantNumCtx -Text ([string]$Settings.AssistantNumCtx) } else { 0 })
    if ($null -eq $Chat.ClientCompat) { $Chat.ClientCompat = @{} }
    $turnUsage = @{ PromptTokens = 0; CompletionTokens = 0; CachedTokens = 0; LastPromptTokens = 0; Rounds = 0 }
    $mask = Get-WtAssistantMaskContext
    $context = @{
        Mask       = $mask
        OnSuggest  = { param($Valid) $validRows = @($Valid | Where-Object { $null -ne $_ }); if ($validRows.Count -gt 0) { Set-WtAssistantSuggestions -Chat $Chat -Entries $validRows } }
        Breadcrumb = $Breadcrumb
        ReadAnswer = $ReadAnswer
        OnApplied  = { param($Lines) & $breakStream; foreach ($l in @($Lines)) { Add-WtChatEntry -State $Chat -Kind 'Tool' -Text ('    ' + [string]$script:WtGlyphs.Branch + ' ' + [string]$l) } }
        OnNoteSaved = { param($T) Reset-WtAssistantSessionExtra -Chat $Chat; & $breakStream; Add-WtChatEntry -State $Chat -Kind 'Info' -Text ((Get-Translation 'AsNoteSaved') -f $T) }
    }
    if ($null -eq $Chat.Schemas) {
        $disabled = [string[]]@()
        try { $perms = & $ReadPermissions; $disabled = [string[]]@(Get-WtAssistantDisabledTools -Permissions $perms) } catch { $disabled = [string[]]@(Get-WtAssistantDisabledTools) }
        $Chat.Disabled = $disabled
        $Chat.Schemas = @(Get-WtAssistantFunctionSchemas -Disabled $disabled)
    }
    $context['Disabled'] = [string[]]@($Chat.Disabled)
    $schemas = $Chat.Schemas
    $systemPrompt = Get-WtAssistantSystemPrompt
    $maxRounds = 5
    $breakStream = { Complete-WtReplStream -Write $Write }
    $client = { param($Messages, $Round)
        $reply = Invoke-WtAssistantChat -AuthMode ([string]$Settings.AssistantAuthMode) -Arguments @{
            Endpoint    = [string]$Settings.AssistantEndpoint; ApiKey = $apiKey; Model = [string]$Settings.AssistantModel
            Messages    = $Messages; Tools = $schemas; ToolChoice = $(if ($Round -gt $maxRounds) { 'none' } else { '' })
            Stream      = $true; OnDelta = $OnDelta; OnReasoningDelta = $OnReasoningDelta; ShouldCancel = $ShouldCancel
            Temperature = $temperature; MaxTokens = $maxTokens; NumCtx = $numCtx; Compat = $Chat.ClientCompat
            SessionId   = [string]$Chat.SessionId; TimeoutSec = 180
        }
        if ($null -ne $reply) { Add-WtAssistantUsage -Total $turnUsage -Usage $reply.Usage }
        return $reply
    }
    $dispatch = { param($Name, $ArgsJson) Invoke-WtAssistantToolCall -Name $Name -ArgumentsJson $ArgsJson -Context $context }
    $onToolStart = { param($Name, $ArgsJson)
        & $breakStream
        Hide-WtReplSpinner
        Add-WtChatEntry -State $Chat -Kind 'Tool' -Text (Format-WtReplToolStart -Name $Name -ArgumentsJson $ArgsJson -Width ([int]$script:WtReplStream.Width))
        Show-WtReplSpinner -Label ((Get-Translation 'AsSpinTool') -f $Name)
    }
    $onToolDone = { param($Name, $Seconds, $Chars, $Ok)
        & $breakStream
        Hide-WtReplSpinner
        Add-WtChatEntry -State $Chat -Kind 'Tool' -Text (Format-WtReplToolResult -Seconds $Seconds -Chars $Chars -Ok $Ok)
        Show-WtReplSpinner -Label (Get-Translation 'AsSpinThinking')
    }
    $onRecovered = { param($Count) & $breakStream; Add-WtChatEntry -State $Chat -Kind 'Info' -Text ((Get-Translation 'AsReplRecovered') -f $Count) }
    try {
        Show-WtReplSpinner -Label (Get-Translation 'AsSpinThinking')
        $profileSeam = $GetProfile
        $systemExtra = Get-WtAssistantSessionExtra -Chat $Chat -GetProfile { & $profileSeam $Chat } -GetNotes $GetNotes -Mask $mask
        $prefixChars = 0
        if ($isOllama -and $numCtx -gt 0) {
            $prefixChars = ([string]$systemPrompt).Length + ([string]$systemExtra).Length + ([string](@($schemas) | ConvertTo-Json -Depth 10 -Compress)).Length
        }
        $historyMax = Get-WtAssistantHistoryMaxChars -NumCtx $numCtx -PrefixChars $prefixChars -Ollama $isOllama
        $Chat.HistoryMaxChars = $historyMax
        $result = & $Turn @{
            Conversation = @{ Messages = $Chat.Messages }; UserText = $sendText
            Client = $client; Dispatch = $dispatch; Schemas = $schemas; MaxRounds = $maxRounds
            HistoryMaxChars = $historyMax
            OnToolStart = $onToolStart; OnToolDone = $onToolDone; OnRecovered = $onRecovered
            SystemPrompt = $systemPrompt; SystemExtra = $systemExtra
        }
    }
    finally {
        Hide-WtReplSpinner
        $Chat.Busy = $false
        & $breakStream
        Close-WtReplToolBox -Write $Write
    }
    $Chat.LastUsage = $(if ([int]$turnUsage.Rounds -gt 0) { $turnUsage } else { $null })
    if ([int]$result.Dropped -gt 0) { Add-WtChatEntry -State $Chat -Kind 'Info' -Text (Get-Translation 'AsTrimmed') }
    $streamed = Get-WtReplStreamText -Kind 'Content'
    if (-not $result.Ok) {
        foreach ($n in $notesSent) { Add-WtAssistantPendingNote -Chat $Chat -Text $n }
        if ($Harness) { Add-WtAssistantPendingNote -Chat $Chat -Text $Text }
    }
    if ($result.Ok) {
        $answer = $(if ($streamed) { $streamed } else { [string]$result.FinalText })
        Add-WtChatEntry -State $Chat -Kind 'Assistant' -Text $answer -Silent
        $listChanged = -not [object]::ReferenceEquals($Chat.Suggestions, $listBefore)
        if ($listChanged -and @($Chat.Suggestions).Count -gt 0 -and $script:WtReplMode) { Write-WtReplSuggestions -Suggestions @($Chat.Suggestions) -Write $Write }
        if ($numCtx -gt 0 -and [int]$turnUsage.LastPromptTokens -gt (0.8 * $numCtx)) {
            Add-WtChatEntry -State $Chat -Kind 'Info' -Text ((Get-Translation 'AsCtxWarning') -f [int]$turnUsage.LastPromptTokens, $numCtx)
        }
    }
    elseif ($result.Cancelled) {
        $partial = [string]$result.FinalText
        if (-not $partial) { $partial = $streamed }
        Add-WtChatEntry -State $Chat -Kind 'Info' -Text ((Get-Translation 'AsCancelled') + $(if ($partial) { ' ' + $partial } else { '' }))
    }
    else { Add-WtChatEntry -State $Chat -Kind 'Error' -Text ([string]$result.ErrorText) }
}
