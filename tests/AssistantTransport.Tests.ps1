#Requires -Modules Pester

<#
.SYNOPSIS
    The facade that picks a transport from the auth mode, and the one
    call site in the chat screen that goes through it.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'the auth mode test' {
    It 'is true only for the exact ChatGPT mode string' {
        Test-WtAssistantChatGptMode -AuthMode 'ChatGPT' | Should -BeTrue
        Test-WtAssistantChatGptMode -AuthMode 'chatgpt' | Should -BeFalse
        Test-WtAssistantChatGptMode -AuthMode '' | Should -BeFalse
        Test-WtAssistantChatGptMode -AuthMode $null | Should -BeFalse
    }
}

Describe 'the facade' {
    It 'sends everything to the OpenAI-compatible client when no mode is set' {
        $seen = New-Object System.Collections.Generic.List[object]
        $llm = { param($A) $seen.Add($A); return @{ Ok = $true; Content = 'from-llm' } }.GetNewClosure()
        $r = Invoke-WtAssistantChat -AuthMode '' -Arguments @{ Endpoint = 'http://x/v1'; Model = 'm'; Messages = @() } `
            -LlmChat $llm -ChatGptChat { param($A) return @{ Ok = $true; Content = 'from-chatgpt' } }
        $seen.Count | Should -Be 1
        $seen[0].Endpoint | Should -Be 'http://x/v1'
        $r.Content | Should -Be 'from-llm'
    }

    It 'drops the arguments the OpenAI-compatible client has no parameter for' {
        $seen = New-Object System.Collections.Generic.List[object]
        $llm = { param($A) $seen.Add($A); return @{ Ok = $true } }.GetNewClosure()
        $null = Invoke-WtAssistantChat -AuthMode '' -LlmChat $llm -ChatGptChat { param($A) return @{ Ok = $true } } `
            -Arguments @{ Endpoint = 'http://x/v1'; Model = 'm'; Messages = @(); NumCtx = 8192; SessionId = 'sess-1' }
        @($seen[0].Keys) | Should -Not -Contain 'SessionId'
        $seen[0].NumCtx | Should -Be 8192
    }

    It 'accepts every name it forwards as a real parameter of the OpenAI-compatible client' {
        $parameters = @((Get-Command Invoke-WtLlmChat).Parameters.Keys)
        foreach ($name in @(Get-WtLlmChatArgumentNames)) {
            $parameters | Should -Contain $name
        }
    }

    It 'sends the turn to the Responses transport in ChatGPT mode' {
        $r = Invoke-WtAssistantChat -AuthMode 'ChatGPT' -Arguments @{ Model = 'm'; Messages = @() } `
            -LlmChat { param($A) return @{ Ok = $true; Content = 'from-llm' } } `
            -ChatGptChat { param($A) return @{ Ok = $true; Content = 'from-chatgpt' } }
        $r.Content | Should -Be 'from-chatgpt'
    }

    It 'drops the arguments the Responses transport has no parameter for' {
        $seen = New-Object System.Collections.Generic.List[object]
        $chatGpt = { param($A) $seen.Add($A); return @{ Ok = $true } }.GetNewClosure()
        $null = Invoke-WtAssistantChat -AuthMode 'ChatGPT' -ChatGptChat $chatGpt `
            -LlmChat { param($A) return @{ Ok = $true } } `
            -Arguments @{
            Model    = 'm'; Messages = @(); Tools = @(); ToolChoice = 'auto'; TimeoutSec = 60; Compat = @{}
            Endpoint = 'http://x/v1'; ApiKey = 'sk-1'; Temperature = 0.2; MaxTokens = 100; NumCtx = 8192; Stream = $true
        }
        @($seen[0].Keys) | Should -Not -Contain 'Endpoint'
        @($seen[0].Keys) | Should -Not -Contain 'ApiKey'
        @($seen[0].Keys) | Should -Not -Contain 'NumCtx'
        @($seen[0].Keys) | Should -Not -Contain 'Stream'
        $seen[0].Model | Should -Be 'm'
        $seen[0].ToolChoice | Should -Be 'auto'
        $seen[0].TimeoutSec | Should -Be 60
    }

    It 'accepts every name it forwards as a real parameter of the Responses transport' {
        $parameters = @((Get-Command Invoke-WtChatGptResponses).Parameters.Keys)
        foreach ($name in @(Get-WtChatGptChatArgumentNames)) {
            $parameters | Should -Contain $name
        }
    }

    It 'never forwards the AuthMode key itself to either transport' {
        $plain = New-Object System.Collections.Generic.List[object]
        $llm = { param($A) $plain.Add($A); return @{ Ok = $true } }.GetNewClosure()
        $null = Invoke-WtAssistantChat -AuthMode '' -Arguments @{ AuthMode = ''; Model = 'm'; Messages = @() } `
            -LlmChat $llm -ChatGptChat { param($A) return @{ Ok = $true } }
        @($plain[0].Keys) | Should -Not -Contain 'AuthMode'

        $routed = New-Object System.Collections.Generic.List[object]
        $chatGpt = { param($A) $routed.Add($A); return @{ Ok = $true } }.GetNewClosure()
        $null = Invoke-WtAssistantChat -AuthMode 'ChatGPT' -Arguments @{ AuthMode = 'ChatGPT'; Model = 'm'; Messages = @() } `
            -LlmChat { param($A) return @{ Ok = $true } } -ChatGptChat $chatGpt
        @($routed[0].Keys) | Should -Not -Contain 'AuthMode'
    }

    It 'passes the transport result back untouched' {
        $r = Invoke-WtAssistantChat -AuthMode 'ChatGPT' -Arguments @{ Model = 'm'; Messages = @() } `
            -LlmChat { param($A) return @{ Ok = $true } } `
            -ChatGptChat { param($A) return @{ Ok = $false; ErrorKind = 'Auth'; ErrorText = 'x'; Cancelled = $false } }
        $r.Ok | Should -BeFalse
        $r.ErrorKind | Should -Be 'Auth'
    }
}

Describe 'the chat screen call site' {
    It 'goes through the facade rather than calling a transport directly' {
        $source = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/80-screens/assistant.ps1') -Raw
        $source | Should -Match 'Invoke-WtAssistantChat'
        $source | Should -Not -Match 'Invoke-WtLlmChat'
        $source | Should -Not -Match 'Invoke-WtChatGptResponses'
    }

    It 'gives every chat session its own session id' {
        $state = New-WtReplSession
        $state.SessionId | Should -Not -BeNullOrEmpty
        (New-WtReplSession).SessionId | Should -Not -Be $state.SessionId
    }
}

Describe 'the effective endpoint' {
    It 'reports the Codex backend in ChatGPT mode, whatever endpoint is saved' {
        $s = [PSCustomObject]@{ AssistantEndpoint = 'http://localhost:1234/v1'; AssistantAuthMode = 'ChatGPT' }
        Get-WtAssistantEffectiveEndpoint -Settings $s | Should -Be ((Get-WtChatGptOAuthConfig).ApiBase)
    }

    It 'reports the saved endpoint when no mode is set' {
        $s = [PSCustomObject]@{ AssistantEndpoint = 'http://localhost:1234/v1'; AssistantAuthMode = '' }
        Get-WtAssistantEffectiveEndpoint -Settings $s | Should -Be 'http://localhost:1234/v1'
    }

    It 'is remote in ChatGPT mode even when the saved endpoint is loopback' {
        $s = [PSCustomObject]@{ AssistantEndpoint = 'http://127.0.0.1:11434/v1'; AssistantAuthMode = 'ChatGPT' }
        Test-WtAssistantRemoteEndpoint -Endpoint (Get-WtAssistantEffectiveEndpoint -Settings $s) | Should -BeTrue
    }
}

Describe 'being configured' {
    It 'needs only a model in ChatGPT mode' {
        Test-WtAssistantConfigured -Settings ([PSCustomObject]@{ AssistantEndpoint = ''; AssistantModel = 'gpt-5.6-terra'; AssistantAuthMode = 'ChatGPT' }) | Should -BeTrue
        Test-WtAssistantConfigured -Settings ([PSCustomObject]@{ AssistantEndpoint = ''; AssistantModel = ''; AssistantAuthMode = 'ChatGPT' }) | Should -BeFalse
    }

    It 'needs both an endpoint and a model otherwise' {
        Test-WtAssistantConfigured -Settings ([PSCustomObject]@{ AssistantEndpoint = 'http://x/v1'; AssistantModel = 'm'; AssistantAuthMode = '' }) | Should -BeTrue
        Test-WtAssistantConfigured -Settings ([PSCustomObject]@{ AssistantEndpoint = ''; AssistantModel = 'm'; AssistantAuthMode = '' }) | Should -BeFalse
        Test-WtAssistantConfigured -Settings ([PSCustomObject]@{ AssistantEndpoint = 'http://x/v1'; AssistantModel = ''; AssistantAuthMode = '' }) | Should -BeFalse
    }
}
