# The assistant's plain-console REPL: pickers, slash commands, first-run
# wizard, and the loop. Every backend is an injectable seam.
# Covered by: tests/AssistantRepl.Tests.ps1

function Invoke-WtReplPick {
    <#
    .SYNOPSIS
        The REPL's numbered/arrow picker, kept under its old name and
        shape for the slash handlers and the wizard: delegates to
        Read-WtReplPick; -AllowText adds the "paste / type" row.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Title,
        [AllowEmptyCollection()][string[]]$Options = @(),
        [switch]$AllowText,
        [scriptblock]$ReadLine = { param($P) Read-WtReplLine -Prompt $P },
        [scriptblock]$ReadPick = { param($T, $O, $X) Read-WtReplPick -Title $T -Options $O -TextOption $X -ReadLine $ReadLine }
    )
    $textOption = $(if ($AllowText) { [string](Get-Translation 'AsPickTypeOption') } else { '' })
    $r = & $ReadPick $Title ([string[]]@($Options)) $textOption
    return @{ Index = [int]$r.Index; Text = [string]$r.Text }
}

function Invoke-WtReplChooseModel {
    <#
    .SYNOPSIS
        The /model picker. The list comes from the ACTIVE identity, not
        from AssistantEndpoint: in ChatGPT mode that is the curated
        catalogue, and the endpoint left in settings - which may be some
        other provider entirely - is never asked.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Settings,
        [AllowNull()][AllowEmptyString()][string]$PlainApiKey = $null,
        [scriptblock]$GetModels = { param($E, $K) Get-WtLlmModelList -Endpoint $E -ApiKey $K },
        [scriptblock]$ReadLine = { param($P) Read-WtReplLine -Prompt $P }
    )
    $chatGptMode = Test-WtAssistantChatGptMode -AuthMode ([string]$Settings.AssistantAuthMode)
    if (-not $chatGptMode) { Write-WtReplLine -Text (Get-Translation 'AsLoadingModels') -Fg 'DarkGray' }
    $list = Get-WtAssistantModelChoices -Settings $Settings -PlainApiKey $PlainApiKey -GetModels $GetModels
    $models = [string[]]@()
    if ($list.Ok) { $models = [string[]]@($list.Models) } else { Write-WtReplLine -Text ([string]$list.ErrorText) -Fg 'Red' }
    if ([string]$list.HintKey) { Write-WtReplLine -Text (Get-Translation ([string]$list.HintKey)) -Fg 'DarkGray' }
    $pick = Invoke-WtReplPick -Title (Get-Translation 'AsSetModel') -Options $models -AllowText -ReadLine $ReadLine
    if ($pick.Index -gt 0) { return [string]$models[$pick.Index - 1] }
    return [string]$pick.Text
}

function Invoke-WtReplChooseServer {
    <#
    .SYNOPSIS
        Scan result -> endpoint + model, inline: pick a server, Ollama's
        list narrowed to tool-capable models, a single model taken as is,
        otherwise picked or typed. $null when the user gave up.
    #>
    param(
        [AllowEmptyCollection()][array]$Servers = @(),
        [scriptblock]$ReadLine = { param($P) Read-WtReplLine -Prompt $P },
        [scriptblock]$FilterOllama = { param($Models) Get-WtOllamaToolCapableModels -Models $Models }
    )
    $rows = @($Servers)
    if ($rows.Count -eq 0) { return $null }
    $names = @($rows | ForEach-Object { [string]$_.Provider + '  (' + [string]$_.Endpoint + ')' })
    $pick = Invoke-WtReplPick -Title (Get-Translation 'AsScanPickServer') -Options $names -ReadLine $ReadLine
    if ($pick.Index -lt 1) { return $null }
    $server = $rows[$pick.Index - 1]
    $models = [string[]]@($server.Models)
    if ([string]$server.Provider -eq 'Ollama') {
        Write-WtReplLine -Text (Get-Translation 'AsProbingTools') -Fg 'DarkGray'
        $models = [string[]]@(& $FilterOllama $models)
    }
    $model = ''
    if ($models.Count -eq 1) { $model = [string]$models[0] }
    else {
        $mp = Invoke-WtReplPick -Title (Get-Translation 'AsSetModel') -Options $models -AllowText -ReadLine $ReadLine
        $model = $(if ($mp.Index -gt 0) { [string]$models[$mp.Index - 1] } else { [string]$mp.Text })
    }
    if (-not $model) { return $null }
    return @{ Endpoint = [string]$server.Endpoint; Model = $model }
}

function Get-WtReplStatusLines {
    <#
    .SYNOPSIS
        The /status block. In ChatGPT mode the endpoint and key rows are
        replaced by the signed-in account: printing a stale endpoint and
        a key that nothing reads would describe an identity that is not
        the one answering.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Settings,
        [Parameter(Mandatory)][hashtable]$Session,
        [AllowNull()][hashtable]$Permissions = $null,
        [AllowNull()][hashtable]$Auth = $null,
        [int]$NoteCount = 0
    )
    $where = Get-WtAssistantWhereTag -Settings $Settings
    $notSet = [string](Get-Translation 'AsNotSet')
    $endpoints = 0
    if ($null -ne $Permissions) { $endpoints = @($Permissions.endpoints).Count }
    $identity = [string[]]@(
        ((Get-Translation 'AsStatusEndpoint') -f $(if ([string]$Settings.AssistantEndpoint) { [string]$Settings.AssistantEndpoint } else { $notSet }), $where)
        ((Get-Translation 'AsStatusKey') -f $(if ([string]$Settings.AssistantApiKey) { '****' } else { $notSet }))
    )
    if (Test-WtAssistantChatGptMode -AuthMode ([string]$Settings.AssistantAuthMode)) {
        $account = Get-WtChatGptAccountStateLabel -Auth $Auth
        if (-not $account) { $account = $notSet }
        $identity = [string[]]@(((Get-Translation 'AsStatusChatGptAccount') -f $account))
    }
    return [string[]]@(
        $identity
        ((Get-Translation 'AsStatusModel') -f $(if ([string]$Settings.AssistantModel) { [string]$Settings.AssistantModel } else { $notSet }))
        ((Get-Translation 'AsStatusContext') -f (Get-WtReplContextPercent -Messages @($Session.Messages.ToArray()) -MaxChars $(if ([int]$Session.HistoryMaxChars -gt 0) { [int]$Session.HistoryMaxChars } else { 40000 })), $Session.Messages.Count)
        ((Get-Translation 'AsStatusPerms') -f $endpoints)
        ((Get-Translation 'AsStatusSampling') -f $(if ([string]$Settings.AssistantTemperature) { [string]$Settings.AssistantTemperature } else { $notSet }), $(if ([string]$Settings.AssistantMaxTokens) { [string]$Settings.AssistantMaxTokens } else { $notSet }))
        ((Get-Translation 'AsStatusNumCtx') -f $(if ([string]$Settings.AssistantNumCtx) { [string]$Settings.AssistantNumCtx } else { $notSet }))
        ((Get-Translation 'AsStatusProfile') -f $(if ($Session.ProfileEnabled) { Get-Translation 'AsOn' } else { Get-Translation 'AsOff' }))
        ((Get-Translation 'AsStatusNotes') -f $NoteCount)
        (Format-WtReplUsageLine -Usage $Session.LastUsage)
    )
}

function Get-WtReplTranscriptReportLines {
    param([Parameter(Mandatory)][hashtable]$Session)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($Session.Entries.ToArray())) {
        foreach ($row in (Get-WtReplEntryLines -Kind ([string]$entry.Kind) -Text ([string]$entry.Text))) { $lines.Add(((@($row) | ForEach-Object { [string]$_.T }) -join '')) }
    }
    foreach ($l in @(Get-WtReplSuggestionLines -Suggestions @($Session.Suggestions))) { $lines.Add($l) }
    return [string[]]$lines.ToArray()
}

function Write-WtReplPage {
    <#
    .SYNOPSIS
        A fresh assistant page: clear the console (viewport + scrollback)
        and print the banner + breadcrumb. Used on entry, after /yeni
        (= /temizle), /unut and when the REPL is re-entered from the menu.
    #>
    param()
    Clear-WtReplScreen
    Write-WtReplHeader
}

function Invoke-WtAssistantSlash {
    <#
    .SYNOPSIS
        One local command. Nothing here talks to the model. Returns what
        the loop must do next and the settings as saved. A confirmation
        rides back on the result's Notice field rather than being
        printed directly, since a command that starts a new session
        repaints the header and would erase a line printed here.
        Settings are re-read after every save rather than merged in
        memory, so the loop sees exactly what Save-WtSettings persisted.
        Disabled tools are both dropped from the model request and
        refused again at dispatch, in case a model still names one. The
        settings screen's Exit verdict is passed back through rather
        than swallowed, since its footer told the user to press the key
        that produced it.
    #>
    param(
        [Parameter(Mandatory)][string]$Command,
        [AllowNull()][AllowEmptyString()][string]$Argument = '',
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][PSCustomObject]$Settings,
        [scriptblock]$ReadLine = { param($P) Read-WtReplLine -Prompt $P },
        [scriptblock]$Scan = { Find-WtLocalLlmServers },
        [scriptblock]$GetModels = { param($E, $K) Get-WtLlmModelList -Endpoint $E -ApiKey $K },
        [scriptblock]$Test = { param($S) Invoke-WtAssistantConnectionTest -Settings $S },
        [scriptblock]$Save = { param($S) Save-WtSettings -Settings $S },
        [scriptblock]$ReadSettings = { Read-WtSettings },
        [scriptblock]$SaveReport = { param($Lines) Save-WtReport -Name 'assistant-chat' -Lines $Lines },
        [AllowNull()][hashtable]$Permissions = $null,
        [scriptblock]$SavePermissions = { param($P) Save-WtAssistantPermissions -Permissions $P },
        [scriptblock]$ReadPermissions = { Read-WtAssistantPermissions },
        [scriptblock]$Profile = { param($Force) if ($Force) { Get-WtAssistantMachineProfile -Kind 'Short' -Force } else { Get-WtAssistantMachineProfile -Kind 'Short' } },
        [scriptblock]$ReadNotes = { Read-WtAssistantNotes },
        [scriptblock]$RemoveNote = { param($I) Remove-WtAssistantNote -Index $I },
        [scriptblock]$ClearMemory = { Clear-WtAssistantMemory },
        [scriptblock]$Hop = { param($A) Invoke-WtReplHop -Action $A },
        [scriptblock]$OpenSettings = { Invoke-WtAssistantSettingsScreen },
        [scriptblock]$SetClipboard = { param($T) Set-Clipboard -Value $T }
    )
    $result = @{ Nav = 'None'; Settings = $Settings; NewSession = $false; Notice = ''; NoticeFg = 'DarkYellow' }
    $saveAndReload = { param($Patch)
        & $Save $Patch
        $result.Settings = & $ReadSettings
    }
    switch ($Command) {
        'new' { $result.NewSession = $true }
        'quit' { $result.Nav = 'Back' }
        'help' {
            foreach ($l in @(Get-WtReplHelpLines)) { Write-WtReplLine -Text $l }
            Write-WtReplLine -Text ''
            Write-WtReplLine -Text (Get-Translation 'AsReplHelpKeys1') -Fg 'DarkGray'
            Write-WtReplLine -Text (Get-Translation 'AsReplHelpKeys2') -Fg 'DarkGray'
        }
        'status' {
            $statusPerms = $Permissions
            if ($null -eq $statusPerms) { $statusPerms = & $ReadPermissions }
            foreach ($l in @(Get-WtReplStatusLines -Settings $Settings -Session $Session -Permissions $statusPerms -Auth (Read-WtChatGptAuth) -NoteCount @(& $ReadNotes).Count)) { Write-WtReplLine -Text $l }
        }
        'model' {
            $parts = @(([string]$Argument).Trim() -split '\s+' | Where-Object { $_ })
            $model = $(if ($parts.Count -ge 1) { [string]$parts[0] } else { '' })
            if (-not $model) {
                if (-not (Test-WtAssistantChatGptMode -AuthMode ([string]$Settings.AssistantAuthMode)) -and -not [string]$Settings.AssistantEndpoint) {
                    Write-WtReplLine -Text (Get-Translation 'AsReplNeedEndpoint') -Fg 'Red'; break
                }
                $model = Invoke-WtReplChooseModel -Settings $Settings -GetModels $GetModels -ReadLine $ReadLine
            }
            if ($model) {
                $patch = @{ AssistantModel = $model }
                if ($parts.Count -ge 2) {
                    $t = 0.0
                    if ([double]::TryParse([string]$parts[1], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$t) -and $t -ge 0 -and $t -le 2) {
                        $patch['AssistantTemperature'] = [string]$parts[1]
                    }
                }
                if ($parts.Count -ge 3) {
                    $m = 0
                    if ([int]::TryParse([string]$parts[2], [ref]$m) -and $m -gt 0) {
                        $patch['AssistantMaxTokens'] = [string]$parts[2]
                    }
                }
                & $saveAndReload ([PSCustomObject]$patch)
                Write-WtReplLine -Text ((Get-Translation 'AsReplSaved') -f $model) -Fg 'DarkYellow'
            }
        }
        'endpoint' {
            if (Test-WtAssistantChatGptMode -AuthMode ([string]$Settings.AssistantAuthMode)) {
                Write-WtReplLine -Text (Get-Translation 'AsChatGptNotUsedInMode') -Fg 'DarkYellow'; break
            }
            $endpoint = ([string]$Argument).Trim()
            if (-not $endpoint) {
                $presets = @(Get-WtLlmPresets)
                $pick = Invoke-WtReplPick -Title (Get-Translation 'AsEndpointHint') -Options @($presets | ForEach-Object { [string]$_.Name + '  (' + [string]$_.Endpoint + ')' }) -AllowText -ReadLine $ReadLine
                $endpoint = $(if ($pick.Index -gt 0) { [string]$presets[$pick.Index - 1].Endpoint } else { [string]$pick.Text })
            }
            if ($endpoint -and ($endpoint.StartsWith('http://', [System.StringComparison]::OrdinalIgnoreCase) -or $endpoint.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase))) {
                $script:WtAssistantPrivacyEndpoint = ''
                & $saveAndReload ([PSCustomObject]@{ AssistantEndpoint = $endpoint })
                Write-WtReplLine -Text ((Get-Translation 'AsReplSaved') -f $endpoint) -Fg 'DarkYellow'
            }
            elseif ($endpoint) { Write-WtReplLine -Text (Get-Translation 'AsEndpointHint') -Fg 'Red' }
        }
        'key' {
            if (Test-WtAssistantChatGptMode -AuthMode ([string]$Settings.AssistantAuthMode)) {
                Write-WtReplLine -Text (Get-Translation 'AsChatGptNotUsedInMode') -Fg 'DarkYellow'; break
            }
            Write-WtReplLine -Text (Get-Translation 'AsApiKeyHint')
            $r = Read-WtReplLine -Prompt ([string](Get-Translation 'AsSetApiKey') + ': ') -Secret
            if ([string]$r.Kind -eq 'Submit') {
                & $saveAndReload ([PSCustomObject]@{ AssistantApiKey = (Protect-WtAssistantSecret -PlainText (([string]$r.Text).Trim())) })
                Write-WtReplLine -Text (Get-Translation 'AsReplKeySaved') -Fg 'DarkYellow'
            }
        }
        'scan' {
            if (Test-WtAssistantChatGptMode -AuthMode ([string]$Settings.AssistantAuthMode)) {
                Write-WtReplLine -Text (Get-Translation 'AsChatGptNotUsedInMode') -Fg 'DarkYellow'; break
            }
            Write-WtReplLine -Text (Get-Translation 'AsScanning') -Fg 'DarkGray'
            $servers = @(& $Scan)
            if ($servers.Count -eq 0) {
                Write-WtReplLine -Text (Get-Translation 'AsScanNothing') -Fg 'Red'
                foreach ($h in @(Get-WtLlmLocalHints)) { Write-WtReplLine -Text $h -Fg 'DarkYellow' }
                break
            }
            $choice = Invoke-WtReplChooseServer -Servers $servers -ReadLine $ReadLine
            if ($null -ne $choice) {
                $script:WtAssistantPrivacyEndpoint = ''
                & $saveAndReload ([PSCustomObject]@{ AssistantEndpoint = [string]$choice.Endpoint; AssistantModel = [string]$choice.Model })
                Write-WtReplLine -Text ((Get-Translation 'AsAutoSelected') -f [string]$choice.Model, [string]$choice.Endpoint) -Fg 'DarkYellow'
            }
        }
        'test' {
            if (-not (Test-WtAssistantConfigured -Settings $Settings)) { Write-WtReplLine -Text (Get-Translation 'AsReplNeedEndpoint') -Fg 'Red'; break }
            Write-WtReplLine -Text (Get-Translation 'AsTesting') -Fg 'DarkGray'
            foreach ($l in @(& $Test $Settings)) { Write-WtReplLine -Text $l }
        }
        'perms' {
            $perms = $Permissions
            if ($null -eq $perms) { $perms = & $ReadPermissions }
            $endpointRows = @($perms.endpoints)
            if ($endpointRows.Count -eq 0) { Write-WtReplLine -Text (Get-Translation 'AsPermsEmpty') -Fg 'DarkYellow'; break }
            $options = @($endpointRows | ForEach-Object { (Get-Translation 'AsPermsEndpointRow') + '  ' + [string]$_.endpoint + '  (' + [string]$_.at + ')' })
            $pick = Invoke-WtReplPick -Title (Get-Translation 'AsPermsTitle') -Options $options -ReadLine $ReadLine
            if ($pick.Index -ge 1) {
                $e = $pick.Index - 1
                $keep = New-Object System.Collections.Generic.List[object]
                for ($i = 0; $i -lt $endpointRows.Count; $i++) { if ($i -ne $e) { $keep.Add($endpointRows[$i]) } }
                if ([string]::Equals([string]$script:WtAssistantPrivacyEndpoint, [string]$endpointRows[$e].endpoint, [System.StringComparison]::Ordinal)) { $script:WtAssistantPrivacyEndpoint = '' }
                $perms.endpoints = @($keep.ToArray())
                & $SavePermissions $perms
                Write-WtReplLine -Text (Get-Translation 'AsPermsRevoked') -Fg 'DarkYellow'
            }
        }
        'tools' {
            $perms = $Permissions
            if ($null -eq $perms) { $perms = & $ReadPermissions }
            $records = @(Get-WtAssistantToolRegistry)
            $off = [string[]]@(Get-WtAssistantDisabledTools -Permissions $perms -Registry $records)
            $options = @(foreach ($rec in $records) {
                $state = $(if (Test-WtAssistantToolDisabled -Name ([string]$rec.Name) -Disabled $off) { Get-Translation 'AsOff' } else { Get-Translation 'AsOn' })
                [string]$rec.Name + '  [' + [string]$rec.Tier + ']  ' + [string]$state
            })
            $pick = Invoke-WtReplPick -Title (Get-Translation 'AsToolsTitle') -Options $options -ReadLine $ReadLine
            if ($pick.Index -ge 1) {
                $rec = $records[$pick.Index - 1]
                $name = [string]$rec.Name
                $turningOn = (Test-WtAssistantToolDisabled -Name $name -Disabled $off)
                $without = { param($List) @(@($List) | ForEach-Object { [string]$_ } | Where-Object { $_ -and -not [string]::Equals($_, $name, [System.StringComparison]::Ordinal) }) }
                $disabled = & $without $(if ($perms.ContainsKey('disabled')) { $perms.disabled } else { @() })
                if (-not $turningOn) { $disabled += $name }
                $perms['disabled'] = @($disabled)
                & $SavePermissions $perms
                $state = [string](Get-Translation $(if ($turningOn) { 'AsOn' } else { 'AsOff' }))
                Write-WtReplLine -Text (((Get-Translation 'AsToolsToggled') -f $name, $state)) -Fg 'DarkYellow'
                Write-WtReplLine -Text ((Get-Translation 'AsToolsNextChat')) -Fg 'DarkGray'
            }
        }
        'forget' {
            Write-WtReplLine -Text (Get-Translation 'AsForgetWarning') -Fg 'DarkYellow'
            $r = & $ReadLine (Get-WtYesNoPrompt -Text (Get-Translation 'AsForgetPrompt'))
            if ([string]$r.Kind -eq 'Submit' -and (Test-WtAffirmativeAnswer -Answer ([string]$r.Text))) {
                $count = [int](& $ClearMemory)
                $script:WtAssistantPrivacyEndpoint = ''
                $result.NewSession = $true
                $result.Notice = [string]((Get-Translation 'AsForgotten') -f $count)
            }
        }
        'profile' {
            $word = ConvertTo-WtAssistantSearchText -Text (([string]$Argument).Trim())
            if ($word -eq 'off' -or $word -eq 'kapat') { $Session.ProfileEnabled = $false; Reset-WtAssistantSessionExtra -Chat $Session; Write-WtReplLine -Text ((Get-Translation 'AsProfileOff')) -Fg 'DarkYellow' }
            elseif ($word -eq 'on' -or $word -eq 'ac') { $Session.ProfileEnabled = $true; Reset-WtAssistantSessionExtra -Chat $Session; Write-WtReplLine -Text ((Get-Translation 'AsProfileOn')) -Fg 'DarkYellow' }
            elseif ($word -eq 'yenile' -or $word -eq 'refresh') {
                Write-WtReplLine -Text ((Get-Translation 'AsProfileBuilding')) -Fg 'DarkGray'
                $p = & $Profile $true
                Reset-WtAssistantSessionExtra -Chat $Session
                Write-WtReplLine -Text (((Get-Translation 'AsProfileRebuilt') -f ([string]$p.Json).Length)) -Fg 'DarkYellow'
            }
            else {
                $p = & $Profile $false
                $state = $(if ($Session.ProfileEnabled) { Get-Translation 'AsOn' } else { Get-Translation 'AsOff' })
                Write-WtReplLine -Text (((Get-Translation 'AsProfileStatus') -f $state, [string]$p.BuiltAt, ([string]$p.Json).Length))
                if ([string]$p.Json) { Write-WtReplLine -Text ([string]$p.Json) -Fg 'DarkGray' }
            }
        }
        'notes' {
            $notes = @(& $ReadNotes)
            if ($notes.Count -eq 0) { Write-WtReplLine -Text (Get-Translation 'AsNotesEmpty') -Fg 'DarkYellow'; break }
            $pick = Invoke-WtReplPick -Title (Get-Translation 'AsNotesTitle') -Options @($notes | ForEach-Object { [string]$_.text + '  (' + ([string]$_.at).Substring(0, [Math]::Min(10, ([string]$_.at).Length)) + ')' }) -ReadLine $ReadLine
            if ($pick.Index -ge 1 -and (& $RemoveNote ([int]$pick.Index))) { Reset-WtAssistantSessionExtra -Chat $Session; Write-WtReplLine -Text (Get-Translation 'AsNoteRemoved') -Fg 'DarkYellow' }
        }
        'save' {
            $path = [string](& $SaveReport ([string[]]@(Get-WtReplTranscriptReportLines -Session $Session)))
            Write-WtReplLine -Text ((Get-Translation 'ReportSaved') + ': ' + $path) -Fg 'DarkYellow'
        }
        'settings' {
            $before = [string]$Settings.AssistantEndpoint
            $hopOut = & $Hop $OpenSettings
            if ($null -ne $hopOut -and [string]$hopOut.Nav -eq 'Exit') { $result.Nav = 'Exit' }
            $result.Settings = & $ReadSettings
            $after = [string]$result.Settings.AssistantEndpoint
            if (-not [string]::Equals($before, $after, [System.StringComparison]::Ordinal)) { $script:WtAssistantPrivacyEndpoint = '' }
            $modelNow = [string]$result.Settings.AssistantModel
            if (-not $modelNow) { $modelNow = [string](Get-Translation 'AsNotSet') }
            if (-not $after) { $after = [string](Get-Translation 'AsNotSet') }
            Write-WtReplLine -Text ((Get-Translation 'AsReplSettingsBack') -f $modelNow, $after) -Fg 'DarkYellow'
        }
        'copy' {
            $n = 1
            $parsedN = 0
            if ([int]::TryParse(([string]$Argument).Trim(), [ref]$parsedN) -and $parsedN -ge 1) { $n = $parsedN }
            $answers = @($Session.Entries.ToArray() | Where-Object { [string]$_.Kind -eq 'Assistant' -and [string]$_.Text })
            if ($answers.Count -lt $n) { Write-WtReplLine -Text (Get-Translation 'AsReplNothingToCopy') -Fg 'DarkYellow'; break }
            $text = [string]$answers[$answers.Count - $n].Text
            $copied = $true
            try { & $SetClipboard $text } catch { $copied = $false }
            if ($copied) { Write-WtReplLine -Text ((Get-Translation 'AsReplCopied') -f $text.Length) -Fg 'DarkYellow' }
            else { Write-WtReplLine -Text (Get-Translation 'AsReplCopyFailed') -Fg 'Red' }
        }
        default { Write-WtReplLine -Text ((Get-Translation 'AsReplUnknownSlash') -f $Command) -Fg 'DarkYellow' }
    }
    return $result
}

function Invoke-WtAssistantReplWizard {
    <#
    .SYNOPSIS
        First run, inline: scan the local ports, list what answered,
        take a number or a pasted endpoint, ask for a key when the
        endpoint is remote (masked), pick the model, run the probe test,
        save. Nothing found and nothing pasted: say where keys and local
        servers come from and hand the prompt back.
    #>
    param(
        [scriptblock]$ReadLine = { param($P, $Secret) if ($Secret) { Read-WtReplLine -Prompt $P -Secret } else { Read-WtReplLine -Prompt $P } },
        [scriptblock]$Scan = { Find-WtLocalLlmServers },
        [scriptblock]$GetModels = { param($E, $K) Get-WtLlmModelList -Endpoint $E -ApiKey $K },
        [scriptblock]$Test = { param($S) Invoke-WtAssistantConnectionTest -Settings $S },
        [scriptblock]$Save = { param($S) Save-WtSettings -Settings $S },
        [scriptblock]$ProbeOllama = { param($M) Test-WtOllamaModelToolCapable -Model $M },
        [scriptblock]$FilterOllama = { param($Models) Get-WtOllamaToolCapableModels -Models $Models }
    )
    Write-WtReplLine -Text (Get-Translation 'AsWizardIntro') -Fg 'White'
    Write-WtReplLine -Text (Get-Translation 'AsScanning') -Fg 'DarkGray'
    $servers = @(& $Scan)
    $endpoint = ''
    $model = ''
    $apiKey = ''
    $isOllama = $false
    $names = @($servers | ForEach-Object { [string]$_.Provider + '  (' + [string]$_.Endpoint + ')' })
    if ($names.Count -eq 0) { Write-WtReplLine -Text (Get-Translation 'AsScanNothing') -Fg 'DarkYellow' }
    $pick = Invoke-WtReplPick -Title (Get-Translation 'AsWizardPickOrPaste') -Options $names -AllowText -ReadLine $ReadLine
    if ($pick.Index -ge 1) {
        $server = $servers[$pick.Index - 1]
        $endpoint = [string]$server.Endpoint
        $isOllama = ([string]$server.Provider -eq 'Ollama')
        $models = [string[]]@($server.Models)
        if ($isOllama) { Write-WtReplLine -Text (Get-Translation 'AsProbingTools') -Fg 'DarkGray'; $models = [string[]]@(& $FilterOllama $models) }
        if ($models.Count -eq 1) { $model = [string]$models[0] }
        else {
            $mp = Invoke-WtReplPick -Title (Get-Translation 'AsSetModel') -Options $models -AllowText -ReadLine $ReadLine
            $model = $(if ($mp.Index -gt 0) { [string]$models[$mp.Index - 1] } else { [string]$mp.Text })
        }
    }
    elseif ($pick.Text -and ($pick.Text.StartsWith('http://', [System.StringComparison]::OrdinalIgnoreCase) -or $pick.Text.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase))) {
        $endpoint = [string]$pick.Text
        if (Test-WtAssistantRemoteEndpoint -Endpoint $endpoint) {
            Write-WtReplLine -Text (Get-Translation 'AsApiKeyHint')
            $k = & $ReadLine ([string](Get-Translation 'AsSetApiKey') + ': ') $true
            if ([string]$k.Kind -eq 'Submit') { $apiKey = ([string]$k.Text).Trim() }
        }
        $model = Invoke-WtReplChooseModel -GetModels $GetModels -ReadLine $ReadLine -PlainApiKey $apiKey `
            -Settings ([PSCustomObject]@{ AssistantEndpoint = $endpoint; AssistantApiKey = ''; AssistantAuthMode = '' })
    }
    if (-not ($endpoint -and $model)) {
        Write-WtReplLine -Text (Get-Translation 'AsWizardKeySources') -Fg 'DarkYellow'
        foreach ($h in @(Get-WtLlmLocalHints)) { Write-WtReplLine -Text $h -Fg 'DarkYellow' }
        Write-WtReplLine -Text (Get-Translation 'AsWizardLater') -Fg 'DarkYellow'
        return $null
    }
    if ($isOllama) {
        $verdict = [string](& $ProbeOllama $model)
        if ($verdict -eq 'NoTools') { Write-WtReplLine -Text (Get-Translation 'AsTestToolsMissing') -Fg 'Red'; return $null }
    }
    $settings = [PSCustomObject]@{ AssistantEndpoint = $endpoint; AssistantModel = $model; AssistantApiKey = (Protect-WtAssistantSecret -PlainText $apiKey) }
    Write-WtReplLine -Text (Get-Translation 'AsTesting') -Fg 'DarkGray'
    foreach ($l in @(& $Test $settings)) { Write-WtReplLine -Text $l }
    & $Save $settings
    $script:WtAssistantPrivacyEndpoint = ''
    Write-WtReplLine -Text ((Get-Translation 'AsAutoSelected') -f $model, $endpoint) -Fg 'DarkYellow'
    return $settings
}

function Invoke-WtAssistantScreen {
    <#
    .SYNOPSIS
        The assistant as a plain-console REPL: run the wizard if nothing
        is configured, then loop a line to the model, a lone number
        opening that suggestion, a /command running locally, and Esc x3
        on an empty line returning to the menu - replacing a Ctrl+C
        double-press since a child process can turn Ctrl+C back into a
        break signal. Entering from the menu always opens a fresh
        conversation, except a numbered suggestion that pushed another
        screen, which returns to the same conversation with its
        transcript tail reprinted. A resize repaints a fresh page at the
        new width, trading away scrollback; the loop variable is
        $nowValue, not $now, since a local $now would collide with the
        -Now parameter (case-insensitive). Returns @{ Nav; Target; Char;
        HasMarks } for Invoke-WtMainLoop.
    #>
    param(
        [scriptblock]$ReadLine = { param($P, $History, $StatusRows, $Draft) Read-WtReplLine -Prompt $P -History $History -StatusRows $StatusRows -Placeholder (Get-Translation 'AsReplPlaceholder') -EchoAsUser -AllowResize -InitialText $Draft },
        [scriptblock]$Send = { param($S, $Settings, $Text, $Keep) Invoke-WtAssistantSend -Chat $S -Settings $Settings -Text $Text -Breadcrumb (Get-Translation 'Assistant') -KeepSuggestions:([bool]$Keep) },
        [scriptblock]$Suggest = { param($S, $Index) Invoke-WtAssistantSuggestion -Chat $S -Index $Index -Breadcrumb (Get-Translation 'Assistant') },
        [scriptblock]$FollowUp = { param($S, $Settings, $Report) Invoke-WtAssistantSend -Chat $S -Settings $Settings -Text $Report -Breadcrumb (Get-Translation 'Assistant') -Harness },
        [scriptblock]$Slash = { param($C, $A, $S, $Settings) Invoke-WtAssistantSlash -Command $C -Argument $A -Session $S -Settings $Settings -Profile $Profile },
        [scriptblock]$Wizard = { Invoke-WtAssistantReplWizard },
        [scriptblock]$Header = { param($S, $Settings, $ResumedAt) Write-WtReplPage; Write-WtReplWelcome },
        [scriptblock]$Enter = { Enter-WtReplMode },
        [scriptblock]$Exit = { Exit-WtReplMode },
        [scriptblock]$Now = { Get-Date },
        [scriptblock]$Profile = { param($Force) if ($Force) { Get-WtAssistantMachineProfile -Kind 'Short' -Force -OnCold { Write-WtReplLine -Text ((Get-Translation 'AsProfileBuilding')) -Fg 'DarkGray' } } else { Get-WtAssistantMachineProfile -Kind 'Short' -OnCold { Write-WtReplLine -Text ((Get-Translation 'AsProfileBuilding')) -Fg 'DarkGray' } } },
        [scriptblock]$ReadPermissions = { Read-WtAssistantPermissions },
        [scriptblock]$ReadNotes = { Read-WtAssistantNotes }
    )
    $back = @{ Nav = 'Back'; Target = ''; Char = ''; HasMarks = $false }
    $leave = { param($Verdict) if ([string]$Verdict.Nav -ne 'Push') { $script:WtAssistantChat = $null }; return $Verdict }
    & $Enter
    try {
        $settings = Read-WtSettings
        $resumed = ($null -ne $script:WtAssistantChat)
        if (-not $resumed) { $script:WtAssistantChat = New-WtReplSession }
        $session = $script:WtAssistantChat
        & $Header $session $settings ''
        $built = $null
        try { $built = & $Profile $false } catch { $built = $null }
        if ($null -ne $built -and $built.Cold -and [string]$built.Json) {
            Write-WtReplLine -Text (((Get-Translation 'AsProfileBuilt') -f ([string]$built.Json).Length)) -Fg 'DarkGray'
        }
        if (-not (Test-WtAssistantConfigured -Settings $settings)) {
            $configured = & $Wizard
            if ($null -ne $configured) {
                $settings = Read-WtSettings; if (-not [string]$settings.AssistantEndpoint) { $settings = $configured }
                Write-WtReplLine -Text ((Get-Translation 'AsReplSettingsBack') -f [string]$settings.AssistantModel, [string]$settings.AssistantEndpoint) -Fg 'DarkYellow'
            }
        }
        $tailWrite = { param($Text, $Fg, $NoNewline) Write-WtReplLine -Text $Text -Fg $Fg }
        $width = (Get-WtConsoleSize).Width
        if ($resumed) { Write-WtReplTranscriptTail -Session $session -Count 400 -Width $width -Write $tailWrite }
        $permCount = 0
        try { $p = & $ReadPermissions; if ($null -ne $p) { $permCount = @($p.endpoints).Count } } catch { $permCount = 0 }
        $noteCount = 0
        try { $noteCount = @(& $ReadNotes).Count } catch { $noteCount = 0 }
        $draft = ''
        while ($true) {
            $configuredNow = Test-WtAssistantConfigured -Settings $settings
            $where = Get-WtAssistantWhereTag -Settings $settings
            Set-WtReplTitle -Text (Get-WtWindowTitle)
            $width = (Get-WtConsoleSize).Width
            $right = $(if ([int]$session.EscCount -gt 0 -and ([datetime](& $Now) - [datetime]$session.LastEsc).TotalSeconds -le 2) { [string]((Get-Translation 'AsReplEscHint') -f (3 - [int]$session.EscCount)) } else { Get-WtReplStatusRight })
            $left = $(if ($configuredNow) {
                Get-WtReplStatusLeft -Model ([string]$settings.AssistantModel) -WhereTag $where `
                    -Percent (Get-WtReplContextPercent -Messages @($session.Messages.ToArray()) -MaxChars $(if ([int]$session.HistoryMaxChars -gt 0) { [int]$session.HistoryMaxChars } else { 40000 })) `
                    -MessageCount $session.Messages.Count -NoteCount $noteCount -PermCount $permCount `
                    -Width $width -Reserve ([string]$right).Length
            }
            else { [string](Get-Translation 'AsReplNeedEndpoint') })
            $statusRows = @(, @(, (New-WtSeg -Text (Format-WtReplStatusLine -Left $left -Right $right -Width $width) -Fg $(if ($configuredNow) { 'DarkGray' } else { 'Yellow' }))))
            Close-WtReplToolBox
            $r = & $ReadLine '> ' ([string[]]@($session.History.ToArray())) $statusRows $draft
            $draft = ''
            $kind = [string]$r.Kind
            if ($kind -eq 'Eof') { return (& $leave $back) }
            if ($kind -eq 'Cancel') {
                $nowValue = [datetime](& $Now)
                if (($nowValue - [datetime]$session.LastEsc).TotalSeconds -le 2) { $session.EscCount = [int]$session.EscCount + 1 }
                else { $session.EscCount = 1 }
                $session.LastEsc = $nowValue
                if ([int]$session.EscCount -ge 3) { return (& $leave $back) }
                if (-not $script:WtReplLiveEnabled) { Write-WtReplLine -Text ((Get-Translation 'AsReplEscHint') -f (3 - [int]$session.EscCount)) -Fg 'DarkGray' }
                continue
            }
            $session.EscCount = 0
            if ($kind -eq 'Resize') {
                $draft = [string]$r.Text
                $width = (Get-WtConsoleSize).Width
                & $Header $session $settings ''
                Write-WtReplTranscriptTail -Session $session -Count 400 -Width $width -Write $tailWrite
                continue
            }
            if ($kind -eq 'CtrlC') { continue }
            $line = [string]$r.Text
            if (([string]$line).Trim()) { $session.History.Add($line) }
            $command = ConvertTo-WtReplCommand -Line $line -SuggestionCount (@($session.Suggestions).Count)
            switch ([string]$command.Kind) {
                'None' { }
                'Send' {
                    if (-not $configuredNow) { Write-WtReplLine -Text (Get-Translation 'AsReplNeedEndpoint') -Fg 'Red'; break }
                    & $Send $session $settings $line
                }
                'Suggest' {
                    $verdict = & $Suggest $session ([int]$command.Index)
                    if ($null -ne $verdict) { return (& $leave $verdict) }
                    $report = [string]$session.FollowUp
                    $session.FollowUp = ''
                    if ($report -and $configuredNow) { & $FollowUp $session $settings $report }
                }
                'Hint' { Write-WtReplLine -Text (Get-Translation 'AsReplQuitHint') -Fg 'DarkGray' }
                'Slash' {
                    $out = & $Slash ([string]$command.Command) ([string]$command.Argument) $session $settings
                    if ($null -ne $out.Settings) { $settings = $out.Settings }
                    if (@('new', 'forget', 'notes', 'perms') -contains [string]$command.Command) {
                        $permCount = 0
                        try { $p = & $ReadPermissions; if ($null -ne $p) { $permCount = @($p.endpoints).Count } } catch { $permCount = 0 }
                        $noteCount = 0
                        try { $noteCount = @(& $ReadNotes).Count } catch { $noteCount = 0 }
                    }
                    if ($out.NewSession) {
                        $wasProfileEnabled = $session.ProfileEnabled
                        $script:WtAssistantChat = New-WtReplSession
                        $script:WtAssistantChat.ProfileEnabled = $wasProfileEnabled
                        $session = $script:WtAssistantChat
                        & $Header $session $settings ''
                    }
                    if ([string]$out.Notice) { Write-WtReplLine -Text ([string]$out.Notice) -Fg ([string]$out.NoticeFg) }
                    if ([string]$out.Nav -eq 'Back') { return (& $leave $back) }
                    if ([string]$out.Nav -eq 'Exit') { return (& $leave @{ Nav = 'Exit'; Target = ''; Char = ''; HasMarks = $false }) }
                }
                'Unknown' {
                    $isDigit = (([string]$command.Text) -cmatch '^[0-9]{1,2}\z')
                    if ($isDigit) {
                        $digit = [int]$command.Text
                        if ($configuredNow) {
                            $cardRows = [string[]]@(for ($i = 0; $i -lt @($session.Suggestions).Count; $i++) { [string]($i + 1) + ' ' + [string](@($session.Suggestions)[$i].Label) })
                            $loose = Format-WtAssistantLooseNumberNote -Number $digit -Numbers $cardRows
                            Add-WtAssistantPendingNote -Chat $session -Text $loose
                            & $Send $session $settings $line ($cardRows.Count -gt 0)
                            $lastNote = $session.PendingNotes.Count - 1
                            if ($lastNote -ge 0 -and [string]::Equals([string]$session.PendingNotes[$lastNote], $loose, [System.StringComparison]::Ordinal)) { $session.PendingNotes.RemoveAt($lastNote) }
                        }
                        else { Write-WtReplLine -Text ((Get-Translation 'AsReplNoSuggestion') -f $digit) -Fg 'DarkYellow' }
                    }
                    else { Write-WtReplLine -Text ((Get-Translation 'AsReplUnknownSlash') -f [string]$command.Command) -Fg 'DarkYellow' }
                }
            }
        }
    }
    finally { & $Exit }
}