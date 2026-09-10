# The facade in front of the two chat transports: the OpenAI-compatible
# client and the ChatGPT subscription one. Nothing above this file knows
# which protocol answered.
# Covered by: tests/AssistantTransport.Tests.ps1

function Test-WtAssistantChatGptMode {
    <#
    .SYNOPSIS
        PURE: whether settings say the ChatGPT session is the active
        identity. Ordinal comparison, not -eq: tr-TR's casing rules make
        a case-insensitive match on this word unsafe.
    #>
    param([AllowNull()][AllowEmptyString()][string]$AuthMode)
    return [string]::Equals([string]$AuthMode, 'ChatGPT', [System.StringComparison]::Ordinal)
}

function Get-WtAssistantEffectiveEndpoint {
    <#
    .SYNOPSIS
        PURE: where this assistant's requests ACTUALLY go. In ChatGPT
        mode that is the Codex backend, whatever endpoint happens to be
        left in settings - and every consumer must ask here rather than
        reading AssistantEndpoint, or a stale loopback value would make
        the privacy gate believe nothing leaves the machine.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Settings)
    if (Test-WtAssistantChatGptMode -AuthMode ([string]$Settings.AssistantAuthMode)) {
        return [string](Get-WtChatGptOAuthConfig).ApiBase
    }
    return [string]$Settings.AssistantEndpoint
}

function Test-WtAssistantConfigured {
    <#
    .SYNOPSIS
        PURE: whether the assistant can send at all. ChatGPT mode needs
        only a model - the endpoint is not its to choose - while every
        other identity needs both an endpoint and a model.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Settings)
    if (Test-WtAssistantChatGptMode -AuthMode ([string]$Settings.AssistantAuthMode)) {
        return [bool][string]$Settings.AssistantModel
    }
    return [bool]([string]$Settings.AssistantEndpoint -and [string]$Settings.AssistantModel)
}

function Get-WtAssistantWhereTag {
    <#
    .SYNOPSIS
        The one-word "where does this go" tag for the status line:
        ChatGPT, remote or local.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Settings)
    if (Test-WtAssistantChatGptMode -AuthMode ([string]$Settings.AssistantAuthMode)) {
        return [string](Get-Translation 'AsChatGptTag')
    }
    if (Test-WtAssistantRemoteEndpoint -Endpoint ([string]$Settings.AssistantEndpoint)) {
        return [string](Get-Translation 'AsRemoteTag')
    }
    return [string](Get-Translation 'AsLocalTag')
}

function Get-WtChatGptChatArgumentNames {
    <#
    .SYNOPSIS
        The arguments the Responses transport understands. An ALLOW list,
        not a deny list: splatting a name it has no parameter for is a
        hard error, so an argument added to the chat/completions path must
        be opted in here deliberately.
    #>
    return [string[]]@('Model', 'Messages', 'Tools', 'ToolChoice', 'OnDelta', 'OnReasoningDelta',
        'ShouldCancel', 'TimeoutSec', 'SessionId', 'Compat')
}

function Get-WtLlmChatArgumentNames {
    <#
    .SYNOPSIS
        The arguments the OpenAI-compatible client understands. Needed for
        the same reason as its ChatGPT twin: the caller builds ONE table
        for both transports, and splatting a name a transport has no
        parameter for is a hard binding error, not a warning.
    #>
    return [string[]]@('Endpoint', 'ApiKey', 'Model', 'Messages', 'Tools', 'ToolChoice', 'OnDelta',
        'OnReasoningDelta', 'ShouldCancel', 'TimeoutSec', 'Stream', 'Temperature', 'MaxTokens', 'NumCtx', 'Compat')
}

function Invoke-WtAssistantChat {
    <#
    .SYNOPSIS
        One model turn through whichever transport the auth mode selects.
        Both return the same result table, so the caller reads the answer
        the same way either way. The caller passes ONE argument table and
        each branch keeps only the names its own transport declares -
        AuthMode included, which selects a transport rather than being a
        parameter of one. Transports are seams so the routing can be
        tested without a network.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$AuthMode = '',
        [Parameter(Mandatory)][hashtable]$Arguments,
        [scriptblock]$LlmChat = { param($ArgTable) Invoke-WtLlmChat @ArgTable },
        [scriptblock]$ChatGptChat = { param($ArgTable) Invoke-WtChatGptResponses @ArgTable }
    )
    $chatGpt = Test-WtAssistantChatGptMode -AuthMode $AuthMode
    $allowed = @($(if ($chatGpt) { Get-WtChatGptChatArgumentNames } else { Get-WtLlmChatArgumentNames }))
    $forwarded = @{}
    foreach ($name in @($Arguments.Keys)) {
        if (-not ($allowed -contains [string]$name)) { continue }
        $forwarded[[string]$name] = $Arguments[$name]
    }
    if ($chatGpt) { return (& $ChatGptChat $forwarded) }
    return (& $LlmChat $forwarded)
}
