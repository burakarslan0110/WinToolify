# The assistant settings screen: preset, endpoint, api key, model picker,
# local scan and the connection test.
# Covered by: tests/AssistantScreen.Tests.ps1

function Get-WtLlmPresets {
    <#
    .SYNOPSIS
        Known OpenAI-compatible endpoints. A preset only fills the
        endpoint field - key and model stay whatever they were.
    #>
    return @(
        [PSCustomObject]@{ Name = 'OpenAI'; Endpoint = 'https://api.openai.com/v1' }
        [PSCustomObject]@{ Name = 'OpenRouter'; Endpoint = 'https://openrouter.ai/api/v1' }
        [PSCustomObject]@{ Name = 'Groq'; Endpoint = 'https://api.groq.com/openai/v1' }
        [PSCustomObject]@{ Name = 'LM Studio'; Endpoint = 'http://127.0.0.1:1234/v1' }
        [PSCustomObject]@{ Name = 'Ollama'; Endpoint = 'http://127.0.0.1:11434/v1' }
        [PSCustomObject]@{ Name = 'llama.cpp'; Endpoint = 'http://127.0.0.1:8080/v1' }
    )
}

function Get-WtChatGptModelCatalog {
    <#
    .SYNOPSIS
        The models offered in ChatGPT mode. A hand-maintained list rather
        than a call: the subscription backend has no /models route. The
        ids are the ones documented for signing in with a ChatGPT
        account; gpt-5 and gpt-5-codex are NOT among them and the backend
        refuses them outright. Which of these a given plan actually
        allows is not documented, so all of them are offered, lighter
        first, and the type-it-yourself fallback and the connection test
        stay the real judges.
    #>
    return [string[]]@('gpt-5.6-terra', 'gpt-5.6-luna', 'gpt-5.3-codex-spark', 'gpt-5.6-sol', 'gpt-6-astra', 'gpt-5.5')
}

function Get-WtAssistantModelChoices {
    <#
    .SYNOPSIS
        The models to offer for the ACTIVE identity: the curated ChatGPT
        catalogue in ChatGPT mode - that backend has no /models route -
        and the endpoint's own list otherwise. One function so the
        settings screen and the REPL's /model can never disagree about
        which list belongs to which identity.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Settings,
        [AllowNull()][AllowEmptyString()][string]$PlainApiKey = $null,
        [scriptblock]$GetModels = { param($E, $K) Get-WtLlmModelList -Endpoint $E -ApiKey $K }
    )
    if (Test-WtAssistantChatGptMode -AuthMode ([string]$Settings.AssistantAuthMode)) {
        return @{ Ok = $true; Models = [string[]]@(Get-WtChatGptModelCatalog); ErrorText = ''; HintKey = 'AsChatGptModelHint' }
    }
    $endpoint = [string]$Settings.AssistantEndpoint
    if (-not $endpoint) {
        return @{ Ok = $false; Models = [string[]]@(); ErrorText = [string](Get-Translation 'AsReplNeedEndpoint'); HintKey = '' }
    }
    $key = $(if ($null -ne $PlainApiKey) { [string]$PlainApiKey } else { [string](Unprotect-WtAssistantSecret -Blob ([string]$Settings.AssistantApiKey)) })
    $list = & $GetModels $endpoint $key
    return @{ Ok = [bool]$list.Ok; Models = [string[]]@($list.Models); ErrorText = [string]$list.ErrorText; HintKey = '' }
}

function Get-WtChatGptAccountStateLabel {
    <#
    .SYNOPSIS
        PURE: the account row's state column - "email - plan", the email
        alone when the plan is unknown, and nothing at all without an
        email, so a half-read session never renders a bare dash.
    #>
    param([AllowNull()][hashtable]$Auth)
    if ($null -eq $Auth) { return '' }
    $email = [string]$Auth.Email
    if (-not $email) { return '' }
    $plan = [string]$Auth.PlanType
    if (-not $plan) { return $email }
    return ([string](Get-Translation 'AsChatGptStateFormat') -f $email, $plan)
}

function Get-WtChatGptSignInWarningLines {
    <#
    .SYNOPSIS
        PURE: what stands behind the typed gate on the ChatGPT sign-in -
        that the risk of a restricted or closed account is the user's own
        and WinToolify carries none of it, that the API key row is the
        supported route, and the Codex disclosure. Pure so the wording
        can be tested without driving the screen; the consequence line
        itself is AsChatGptBanConsequence and the gate renders it in red.
    #>
    return [string[]]@(
        [string](Get-Translation 'AsChatGptBanLiability'),
        '',
        [string](Get-Translation 'AsChatGptBanAlternative'),
        '',
        [string](Get-Translation 'AsChatGptDisclosure')
    )
}

function Get-WtAssistantSettingsRows {
    <#
    .SYNOPSIS
        PURE: the eight settings rows with the live values in the state
        column. The key never shows itself - only '****' or "not set".
        In ChatGPT mode the rows that describe the other identity are
        marked Disabled and say why rather than disappearing: a row that
        vanishes reads as a missing feature, one that explains itself
        does not.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Settings,
        [AllowNull()][hashtable]$Auth = $null
    )
    $notSet = [string](Get-Translation 'AsNotSet')
    $chatGpt = Test-WtAssistantChatGptMode -AuthMode ([string]$Settings.AssistantAuthMode)
    $unusedLabel = [string](Get-Translation 'AsChatGptNotUsedInMode')
    $endpoint = [string]$Settings.AssistantEndpoint
    if (-not $endpoint) { $endpoint = $notSet }
    $model = [string]$Settings.AssistantModel
    if (-not $model) { $model = $notSet }
    $keyState = $(if ([string]$Settings.AssistantApiKey) { '****' } else { $notSet })
    $numCtx = [string]$Settings.AssistantNumCtx
    if (-not $numCtx) { $numCtx = $notSet }
    $row = { param([string]$Name, [string]$Setting, [string]$Label, [string]$State, [bool]$Disabled)
        $shownState = $(if ($Disabled) { $unusedLabel } else { $State })
        return (New-WtListItem -Kind 'Action' -Name $Name -Label $Label -StateLabel $shownState -Data @{ Setting = $Setting; Disabled = $Disabled })
    }
    $accountLabel = [string](Get-Translation $(if ($chatGpt) { 'AsChatGptSignOut' } else { 'AsChatGptSignIn' }))
    $accountState = $(if ($chatGpt) { Get-WtChatGptAccountStateLabel -Auth $Auth } else { '' })
    return @(
        (& $row 'AsSetAuthMode' 'AuthMode' $accountLabel $accountState $false)
        (& $row 'AsSetPreset' 'Preset' ([string](Get-Translation 'AsSetPreset')) '' $chatGpt)
        (& $row 'AsSetEndpoint' 'Endpoint' ([string](Get-Translation 'AsSetEndpoint')) $endpoint $chatGpt)
        (& $row 'AsSetApiKey' 'ApiKey' ([string](Get-Translation 'AsSetApiKey')) $keyState $chatGpt)
        (& $row 'AsSetModel' 'Model' ([string](Get-Translation 'AsSetModel')) $model $false)
        (& $row 'AsScanLocal' 'Scan' ([string](Get-Translation 'AsScanLocal')) '' $chatGpt)
        (& $row 'AsTestConnection' 'Test' ([string](Get-Translation 'AsTestConnection')) '' $false)
        (& $row 'AsSetNumCtx' 'NumCtx' ([string](Get-Translation 'AsSetNumCtx')) $numCtx $chatGpt)
    )
}

function Invoke-WtAssistantPickFromList {
    <#
    .SYNOPSIS
        A numbered picker in the panel: options listed 1..N, the answer
        is a number; anything else (blank, out of range, letters) means
        "leave it". Used for presets, scanned servers and model lists.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Breadcrumb,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Options,
        [scriptblock]$ReadAnswer = { param($Lines, $Prompt) Read-WtPanelAnswer -Breadcrumb $Breadcrumb -Lines $Lines -Prompt $Prompt -Layout 'Compact' }
    )
    $options = @($Options)
    if ($options.Count -eq 0) { return '' }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($Title)
    for ($i = 0; $i -lt $options.Count; $i++) { $lines.Add(('  {0}) {1}' -f ($i + 1), [string]$options[$i])) }
    $answer = ([string](& $ReadAnswer ([string[]]$lines.ToArray()) (Get-Translation 'AsPickPrompt'))).Trim()
    $index = 0
    if (-not [int]::TryParse($answer, [ref]$index)) { return '' }
    if ($index -lt 1 -or $index -gt $options.Count) { return '' }
    return [string]$options[$index - 1]
}

function Invoke-WtAssistantChooseServer {
    <#
    .SYNOPSIS
        Turns a local scan into a saved endpoint+model: pick a server,
        then a model, then store both. Shared by the settings screen's
        Scan row and the chat startup 'Choose' branch, so a scan (up to
        8s) is offered rather than re-run. IndexOf returns -1 on a miss,
        and PS negative indices wrap from the end, so the miss is
        checked before indexing. The Ollama model list is force-wrapped
        in @() - unwrapped, a one-element result becomes a bare String
        and $models[0] returns its first CHARACTER, not the model name.
        Returns $true only when both were saved.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Breadcrumb,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Servers
    )
    $servers = @($Servers)
    if ($servers.Count -eq 0) { return $false }
    $serverNames = @($servers | ForEach-Object { [string]$_.Provider + '  (' + [string]$_.Endpoint + ')' })
    $pickedServer = Invoke-WtAssistantPickFromList -Breadcrumb $Breadcrumb -Title (Get-Translation 'AsScanPickServer') -Options $serverNames
    $serverIndex = [array]::IndexOf($serverNames, $pickedServer)
    if ($serverIndex -lt 0) { return $false }
    $server = $servers[$serverIndex]
    $models = [string[]]@($server.Models)
    if ([string]$server.Provider -eq 'Ollama') {
        Show-WtPanelMessage -Breadcrumb $Breadcrumb -Lines @((Get-Translation 'AsProbingTools')) -FooterText '' | Out-Null
        $models = [string[]]@(Get-WtOllamaToolCapableModels -Models $models)
        Reset-WtFrameCache
    }
    $pickedModel = ''
    if (@($models).Count -eq 1) { $pickedModel = [string]$models[0] }
    else { $pickedModel = Invoke-WtAssistantPickFromList -Breadcrumb $Breadcrumb -Title (Get-Translation 'AsSetModel') -Options $models }
    if (-not $pickedModel) { return $false }
    Save-WtSettings -Settings ([PSCustomObject]@{ AssistantEndpoint = [string]$server.Endpoint; AssistantModel = $pickedModel })
    return $true
}

function Invoke-WtAssistantConnectionTest {
    <#
    .SYNOPSIS
        The full-agent gatekeeper: one small request WITH a probe tool.
        Reports reachability and - separately - whether the model
        actually answered with a tool call, because "the endpoint took
        tools" and "the model uses them" are different failures.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Settings,
        [scriptblock]$Chat = { param($ArgTable) Invoke-WtAssistantChat -AuthMode ([string]$ArgTable.AuthMode) -Arguments $ArgTable }
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $probeTool = @{ type = 'function'; 'function' = @{ name = 'probe_ping'; description = 'Connectivity probe. Call this tool once, with no arguments.'; parameters = @{ type = 'object'; properties = @{} } } }
    $result = & $Chat @{
        AuthMode = [string]$Settings.AssistantAuthMode
        Endpoint = [string]$Settings.AssistantEndpoint
        ApiKey = (Unprotect-WtAssistantSecret -Blob ([string]$Settings.AssistantApiKey))
        Model = [string]$Settings.AssistantModel
        Messages = @(@{ role = 'user'; content = 'Call the probe_ping tool now.' })
        Tools = @($probeTool); Stream = $false; TimeoutSec = 60
    }
    if (-not $result.Ok) {
        $lines.Add([string]$result.ErrorText)
        return [string[]]$lines.ToArray()
    }
    $lines.Add([string](Get-Translation 'AsTestReachable'))
    $called = @($result.ToolCalls) | Where-Object { [string]$_.Name -eq 'probe_ping' }
    if (@($called).Count -gt 0) { $lines.Add([string](Get-Translation 'AsTestToolsOk')) }
    else { $lines.Add([string](Get-Translation 'AsTestToolsMissing')) }
    return [string[]]$lines.ToArray()
}

function Invoke-WtAssistantSettingsScreen {
    <#
    .SYNOPSIS
        The settings list screen: each row opens its panel flow, saves
        and redraws with the new value. Left/Esc returns to the caller.
        A prompt answer of $null means cancelled (change nothing); '' is
        the documented way to clear a value - the two must be told apart
        before casting to [string], which collapses both to ''. IndexOf
        on a picked list returns -1 on a miss, and a negative PS array
        index wraps from the end, so the miss is checked before indexing.
    #>
    $breadcrumb = Get-WtBreadcrumb -Keys 'MainMenu', 'Assistant', 'AsSettingsTitle'
    while ($true) {
        $settings = Read-WtSettings
        $auth = Read-WtChatGptAuth
        $r = Invoke-WtListScreen -Breadcrumb $breadcrumb -Items @(Get-WtAssistantSettingsRows -Settings $settings -Auth $auth) `
            -MultiSelect $false -FooterText (Get-Translation 'NavFooter') -Layout 'Compact'
        if ($r.Emit -eq 'Back') { return @{ Nav = 'Back'; Target = ''; Char = ''; HasMarks = $false } }
        if ($r.Emit -eq 'Quit') { return @{ Nav = 'Exit'; Target = ''; Char = ''; HasMarks = $false } }
        if ($r.Emit -ne 'Activate' -or $null -eq $r.Item) { continue }
        if ([bool]$r.Item.Data.Disabled) { continue }
        switch ([string]$r.Item.Data.Setting) {
            'AuthMode' {
                if (Test-WtAssistantChatGptMode -AuthMode ([string]$settings.AssistantAuthMode)) {
                    Clear-WtChatGptAuth
                    $null = Read-WtPanelAnswer -Breadcrumb $breadcrumb -Lines @((Get-Translation 'AsChatGptSignedOut')) -Prompt (Get-Translation 'PressEnterContinue') -Layout 'Compact'
                    Reset-WtFrameCache
                    continue
                }
                $accepted = Confirm-WtDestructiveAction -Consequence (Get-Translation 'AsChatGptBanConsequence') `
                    -Lines (Get-WtChatGptSignInWarningLines) -Breadcrumb $breadcrumb
                Reset-WtFrameCache
                if (-not $accepted) { continue }
                Show-WtPanelMessage -Breadcrumb $breadcrumb -Lines @((Get-Translation 'AsChatGptDisclosure'), '', (Get-Translation 'AsChatGptWaiting')) -FooterText '' | Out-Null
                $signIn = Invoke-WtChatGptSignIn -ShouldCancel { Test-WtOAuthCancelKey }
                Reset-WtFrameCache
                $lines = New-Object System.Collections.Generic.List[string]
                if ($signIn.Ok) { $lines.Add(([string](Get-Translation 'AsChatGptSignedIn') -f [string]$signIn.Email)) }
                else {
                    if ([string]$signIn.ReasonKey) { $lines.Add([string](Get-Translation ([string]$signIn.ReasonKey))) }
                    if ([string]$signIn.ErrorText) { $lines.Add([string]$signIn.ErrorText) }
                    if ([bool]$signIn.BrowserFailed) {
                        $lines.Add([string](Get-Translation 'AsChatGptBrowserFailed'))
                        $lines.Add([string]$signIn.AuthorizeUri)
                    }
                }
                $null = Read-WtPanelAnswer -Breadcrumb $breadcrumb -Lines ([string[]]$lines.ToArray()) -Prompt (Get-Translation 'PressEnterContinue') -Layout 'Compact'
                Reset-WtFrameCache
            }
            'Preset' {
                $names = @((Get-WtLlmPresets) | ForEach-Object { [string]$_.Name + '  (' + [string]$_.Endpoint + ')' })
                $picked = Invoke-WtAssistantPickFromList -Breadcrumb $breadcrumb -Title (Get-Translation 'AsSetPreset') -Options $names
                $presetIndex = [array]::IndexOf($names, $picked)
                if ($presetIndex -ge 0) {
                    $preset = @(Get-WtLlmPresets)[$presetIndex]
                    Save-WtSettings -Settings ([PSCustomObject]@{ AssistantEndpoint = [string]$preset.Endpoint })
                }
            }
            'Endpoint' {
                $answer = ([string](Read-WtPanelAnswer -Breadcrumb $breadcrumb -Lines @((Get-Translation 'AsEndpointHint')) -Prompt (Get-Translation 'AsSetEndpoint') -Layout 'Compact')).Trim()
                if ($answer -and ($answer.StartsWith('http://', [System.StringComparison]::OrdinalIgnoreCase) -or $answer.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase))) {
                    Save-WtSettings -Settings ([PSCustomObject]@{ AssistantEndpoint = $answer })
                }
            }
            'ApiKey' {
                $raw = Read-WtPanelAnswer -Breadcrumb $breadcrumb -Lines @((Get-Translation 'AsApiKeyHint')) -Prompt (Get-Translation 'AsSetApiKey') -Layout 'Compact' -Secret
                if ($null -ne $raw) {
                    Save-WtSettings -Settings ([PSCustomObject]@{ AssistantApiKey = (Protect-WtAssistantSecret -PlainText (([string]$raw).Trim())) })
                }
            }
            'NumCtx' {
                $raw = Read-WtPanelAnswer -Breadcrumb $breadcrumb -Lines @((Get-Translation 'AsNumCtxHint')) -Prompt (Get-Translation 'AsSetNumCtx') -Layout 'Compact'
                if ($null -ne $raw) {
                    $answer = ([string]$raw).Trim()
                    if ($answer -eq '') { Save-WtSettings -Settings ([PSCustomObject]@{ AssistantNumCtx = '' }) }
                    else {
                        $parsedCtx = ConvertTo-WtAssistantNumCtx -Text $answer
                        if ($parsedCtx -gt 0) { Save-WtSettings -Settings ([PSCustomObject]@{ AssistantNumCtx = [string]$parsedCtx }) }
                    }
                }
            }
            'Model' {
                $chatGptMode = Test-WtAssistantChatGptMode -AuthMode ([string]$settings.AssistantAuthMode)
                if (-not ($chatGptMode -or [string]$settings.AssistantEndpoint)) { continue }
                if (-not $chatGptMode) { Show-WtPanelMessage -Breadcrumb $breadcrumb -Lines @((Get-Translation 'AsLoadingModels')) -FooterText '' | Out-Null }
                $list = Get-WtAssistantModelChoices -Settings $settings
                Reset-WtFrameCache
                $picked = ''
                if ($list.Ok -and @($list.Models).Count -gt 0) {
                    $title = [string](Get-Translation 'AsSetModel')
                    if ([string]$list.HintKey) { $title = $title + ' - ' + [string](Get-Translation ([string]$list.HintKey)) }
                    $picked = Invoke-WtAssistantPickFromList -Breadcrumb $breadcrumb -Title $title -Options ([string[]]@($list.Models))
                }
                if (-not $picked) {
                    $picked = ([string](Read-WtPanelAnswer -Breadcrumb $breadcrumb -Lines @($(if ($list.Ok) { Get-Translation 'AsModelTypeHint' } else { [string]$list.ErrorText })) -Prompt (Get-Translation 'AsSetModel') -Layout 'Compact')).Trim()
                }
                if ($picked) { Save-WtSettings -Settings ([PSCustomObject]@{ AssistantModel = $picked }) }
            }
            'Scan' {
                Show-WtPanelMessage -Breadcrumb $breadcrumb -Lines @((Get-Translation 'AsScanning')) -FooterText '' | Out-Null
                $servers = @(Find-WtLocalLlmServers)
                Reset-WtFrameCache
                if (@($servers).Count -eq 0) {
                    $lines = @((Get-Translation 'AsScanNothing')) + @(Get-WtLlmLocalHints)
                    $null = Read-WtPanelAnswer -Breadcrumb $breadcrumb -Lines $lines -Prompt (Get-Translation 'PressEnterContinue') -Layout 'Compact'
                    Reset-WtFrameCache
                    continue
                }
                $null = Invoke-WtAssistantChooseServer -Breadcrumb $breadcrumb -Servers $servers
            }
            'Test' {
                if (-not ([string]$settings.AssistantEndpoint -and [string]$settings.AssistantModel)) { continue }
                Show-WtPanelMessage -Breadcrumb $breadcrumb -Lines @((Get-Translation 'AsTesting')) -FooterText '' | Out-Null
                $lines = @(Invoke-WtAssistantConnectionTest -Settings $settings)
                Reset-WtFrameCache
                $null = Read-WtPanelAnswer -Breadcrumb $breadcrumb -Lines $lines -Prompt (Get-Translation 'PressEnterContinue') -Layout 'Compact'
                Reset-WtFrameCache
            }
        }
        Reset-WtFrameCache
    }
}
