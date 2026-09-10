#Requires -Modules Pester

<#
.SYNOPSIS
    Local LLM discovery: the provider probe table, models-list parsing,
    the Ollama tool-capability filter, installed-but-stopped hints and
    the startup decision. All probes injected - no network.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Get-WtLlmModelList' {
    It 'parses the models list from a successful GET and asks the right URI' {
        $script:SeenModelListRequest = $null
        $transport = { param($Request)
            $script:SeenModelListRequest = $Request
            return @{ Ok = $true; StatusCode = 200; Body = '{"data":[{"id":"a"},{"id":"b"}]}'; Cancelled = $false; Failure = '' }
        }
        $r = Get-WtLlmModelList -Endpoint 'http://127.0.0.1:1234/v1' -Transport $transport
        $r.Ok | Should -BeTrue
        @($r.Models) | Should -Be @('a', 'b')
        $r.ErrorText | Should -Be ''
        $script:SeenModelListRequest.Uri | Should -Be 'http://127.0.0.1:1234/v1/models'
    }

    It 'maps a failed GET to Ok=false with an error text and no models' {
        $transport = { param($Request) @{ Ok = $false; StatusCode = 401; Body = 'nope'; Cancelled = $false; Failure = '' } }
        $r = Get-WtLlmModelList -Endpoint 'http://127.0.0.1:1234/v1' -Transport $transport
        $r.Ok | Should -BeFalse
        @($r.Models).Count | Should -Be 0
        $r.ErrorText | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-WtLocalLlmProviderTable' {
    It 'probes and talks to 127.0.0.1, never localhost, so the scan cannot die on the ::1 detour' {
        foreach ($provider in (Get-WtLocalLlmProviderTable)) {
            ([uri]$provider.ProbeUri).Host | Should -Be '127.0.0.1'
            ([uri]$provider.Endpoint).Host | Should -Be '127.0.0.1'
        }
    }
}

Describe 'Find-WtLocalLlmServers' {
    It 'probes all four known local ports and reports the ones that answered' {
        $script:Probed = @()
        $probe = { param($Uri)
            $script:Probed += $Uri
            if ($Uri -eq 'http://127.0.0.1:1234/v1/models') { return '{"data":[{"id":"qwen2.5-7b"},{"id":"llama-3.1-8b"}]}' }
            if ($Uri -eq 'http://127.0.0.1:11434/api/tags') { return '{"models":[{"name":"qwen2.5:7b"}]}' }
            return $null
        }
        $servers = @(Find-WtLocalLlmServers -Probe $probe)
        @($script:Probed).Count | Should -Be 4
        @($servers).Count | Should -Be 2
        $servers[0].Provider | Should -Be 'LM Studio'
        $servers[0].Endpoint | Should -Be 'http://127.0.0.1:1234/v1'
        @($servers[0].Models) | Should -Be @('qwen2.5-7b', 'llama-3.1-8b')
        $servers[1].Provider | Should -Be 'Ollama'
        $servers[1].Endpoint | Should -Be 'http://127.0.0.1:11434/v1'
        @($servers[1].Models) | Should -Be @('qwen2.5:7b')
    }

    It 'skips a server whose answer is not the expected JSON' {
        @(Find-WtLocalLlmServers -Probe { param($Uri) '<html>proxy login</html>' }).Count | Should -Be 0
    }
}

Describe 'Test-WtOllamaModelToolCapable' {
    It 'gives the three-way verdict the AutoSelect gate needs' {
        $tools = { param($Uri, $BodyJson) '{"capabilities":["completion","tools"]}' }
        $noTools = { param($Uri, $BodyJson) '{"capabilities":["completion"]}' }
        $dead = { param($Uri, $BodyJson) $null }
        $old = { param($Uri, $BodyJson) '{"license":"..."}' }
        $garbage = { param($Uri, $BodyJson) '<html>' }
        Test-WtOllamaModelToolCapable -Model 'm' -Probe $tools | Should -Be 'Tools'
        Test-WtOllamaModelToolCapable -Model 'm' -Probe $noTools | Should -Be 'NoTools'
        Test-WtOllamaModelToolCapable -Model 'm' -Probe $dead | Should -Be 'Unknown'
        Test-WtOllamaModelToolCapable -Model 'm' -Probe $old | Should -Be 'Unknown'
        Test-WtOllamaModelToolCapable -Model 'm' -Probe $garbage | Should -Be 'Unknown'
    }
}

Describe 'Get-WtOllamaToolCapableModels' {
    It 'keeps only models whose show response lists the tools capability' {
        $probe = { param($Uri, $BodyJson)
            $m = ($BodyJson | ConvertFrom-Json).model
            if ($m -eq 'toolish') { return '{"capabilities":["completion","tools"]}' }
            return '{"capabilities":["completion"]}'
        }
        @(Get-WtOllamaToolCapableModels -Models @('plain', 'toolish') -Probe $probe) | Should -Be @('toolish')
    }

    It 'returns the input unchanged when the probe fails or nothing claims tools' {
        @(Get-WtOllamaToolCapableModels -Models @('a', 'b') -Probe { param($Uri, $BodyJson) $null }) | Should -Be @('a', 'b')
        @(Get-WtOllamaToolCapableModels -Models @('a', 'b') -Probe { param($Uri, $BodyJson) '{"capabilities":["completion"]}' }) | Should -Be @('a', 'b')
    }

    It 'returns the input unchanged when the probe answers with unparsable JSON' {
        @(Get-WtOllamaToolCapableModels -Models @('a', 'b') -Probe { param($Uri, $BodyJson) '<html>not json</html>' }) | Should -Be @('a', 'b')
    }
}

Describe 'Get-WtLlmLocalHints' {
    It 'names an installed-but-silent ollama and LM Studio' {
        $hints = @(Get-WtLlmLocalHints -GetCommand { param($Name) $true } -TestPath { param($Path) $true })
        @($hints).Count | Should -Be 2
        $hints[0] | Should -Be (Get-Translation 'AsHintOllamaInstalled')
    }

    It 'stays silent when neither is installed' {
        @(Get-WtLlmLocalHints -GetCommand { param($Name) $null } -TestPath { param($Path) $false }).Count | Should -Be 0
    }
}

Describe 'Test-WtLlmOllamaEndpoint' {
    It 'recognizes port 11434 on any host and nothing else' {
        foreach ($e in 'http://127.0.0.1:11434/v1', 'http://localhost:11434/v1', 'http://192.168.1.20:11434/v1', 'http://[::1]:11434/v1/') { Test-WtLlmOllamaEndpoint -Endpoint $e | Should -BeTrue -Because $e }
        foreach ($e in 'http://127.0.0.1:1234/v1', 'https://api.openai.com/v1', 'http://127.0.0.1/v1', '', 'not a url', '/v1') { Test-WtLlmOllamaEndpoint -Endpoint $e | Should -BeFalse -Because $e }
    }
}
