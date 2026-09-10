#Requires -Modules Pester

<#
.SYNOPSIS
    The assistant REPL screen logic: pickers, slash commands, the
    first-run wizard and the loop, all driven through scripted line
    readers and injected backends. No console, no network.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
    function New-WtLineQueue { param([string[]]$Lines) $script:LineQueue = New-Object System.Collections.Generic.Queue[string]; foreach ($l in $Lines) { $script:LineQueue.Enqueue($l) } }
    $script:ReadLineSeam = { param($Prompt) if ($script:LineQueue.Count -eq 0) { return @{ Kind = 'Eof'; Text = '' } }; @{ Kind = 'Submit'; Text = $script:LineQueue.Dequeue() } }
    $script:Local = [PSCustomObject]@{ Language = 'EN'; AssistantEndpoint = 'http://127.0.0.1:11434/v1'; AssistantModel = 'qwen3'; AssistantApiKey = '' }
    $script:Unset = [PSCustomObject]@{ Language = 'EN'; AssistantEndpoint = ''; AssistantModel = ''; AssistantApiKey = '' }
    Mock Write-WtReplLine { }
}

Describe 'Invoke-WtReplPick' {
    It 'returns the index for a number, the raw text when allowed, nothing otherwise' {
        New-WtLineQueue -Lines @('2')
        (Invoke-WtReplPick -Title 't' -Options @('a', 'b') -ReadLine $script:ReadLineSeam).Index | Should -Be 2
        New-WtLineQueue -Lines @('http://x/v1')
        $r = Invoke-WtReplPick -Title 't' -Options @('a') -AllowText -ReadLine $script:ReadLineSeam
        $r.Index | Should -Be 0; $r.Text | Should -Be 'http://x/v1'
        New-WtLineQueue -Lines @('9')
        (Invoke-WtReplPick -Title 't' -Options @('a') -ReadLine $script:ReadLineSeam).Index | Should -Be 0
        New-WtLineQueue -Lines @()
        (Invoke-WtReplPick -Title 't' -Options @('a') -ReadLine $script:ReadLineSeam).Index | Should -Be 0
    }

    It 'delegates to Read-WtReplPick with the type-option only when text is allowed' {
        $script:PickArgs = $null
        $r = Invoke-WtReplPick -Title 't' -Options @('a', 'b') -AllowText -ReadPick { param($T, $O, $X) $script:PickArgs = @{ T = $T; O = $O; X = $X }; @{ Index = 2; Text = 'b' } }
        $r.Index | Should -Be 2
        $script:PickArgs.X | Should -Be (Get-Translation 'AsPickTypeOption')
        $null = Invoke-WtReplPick -Title 't' -Options @('a') -ReadPick { param($T, $O, $X) $script:PickArgs = @{ X = $X }; @{ Index = 0; Text = '' } }
        $script:PickArgs.X | Should -Be ''
    }
}

Describe 'Invoke-WtReplChooseServer / ChooseModel' {
    It 'picks a server, filters Ollama models to the tool-capable ones and auto-picks a single model' {
        $servers = @(
            [PSCustomObject]@{ Provider = 'LM Studio'; Endpoint = 'http://127.0.0.1:1234/v1'; Models = @('a', 'b') }
            [PSCustomObject]@{ Provider = 'Ollama'; Endpoint = 'http://127.0.0.1:11434/v1'; Models = @('x', 'y') }
        )
        New-WtLineQueue -Lines @('2')
        $r = Invoke-WtReplChooseServer -Servers $servers -ReadLine $script:ReadLineSeam -FilterOllama { param($Models) [string[]]@('y') }
        $r.Endpoint | Should -Be 'http://127.0.0.1:11434/v1'
        $r.Model | Should -Be 'y'
        New-WtLineQueue -Lines @('1', '2')
        $r = Invoke-WtReplChooseServer -Servers $servers -ReadLine $script:ReadLineSeam
        $r.Model | Should -Be 'b'
        New-WtLineQueue -Lines @('')
        (Invoke-WtReplChooseServer -Servers $servers -ReadLine $script:ReadLineSeam) | Should -BeNullOrEmpty
    }

    It 'lists models from the endpoint or accepts a typed name when the list fails' {
        New-WtLineQueue -Lines @('2')
        $plain = [PSCustomObject]@{ AssistantEndpoint = 'http://x/v1'; AssistantApiKey = ''; AssistantAuthMode = '' }
        (Invoke-WtReplChooseModel -Settings $plain -GetModels { param($E, $K) @{ Ok = $true; Models = @('m1', 'm2'); ErrorText = '' } } -ReadLine $script:ReadLineSeam) | Should -Be 'm2'
        New-WtLineQueue -Lines @('typed-model')
        (Invoke-WtReplChooseModel -Settings $plain -GetModels { param($E, $K) @{ Ok = $false; Models = @(); ErrorText = 'down' } } -ReadLine $script:ReadLineSeam) | Should -Be 'typed-model'
    }
}

Describe 'Invoke-WtAssistantSlash' {
    BeforeEach {
        $script:Saved = @()
        $script:Session = New-WtReplSession
        $script:Reloaded = [PSCustomObject]@{ Language = 'EN'; AssistantEndpoint = 'http://reloaded/v1'; AssistantModel = 'reloaded-model'; AssistantApiKey = '' }
    }
    BeforeAll {
        $script:SaveSeam = { param($Settings) $script:Saved += @($Settings) }
        $script:ReadSeam = { $script:Reloaded }
    }

    It 'new resets, quit backs out, help and status print lines' {
        $newResult = Invoke-WtAssistantSlash -Command 'new' -Argument '' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam
        $newResult.NewSession | Should -BeTrue
        $newResult.Notice | Should -Be ''
        (Invoke-WtAssistantSlash -Command 'quit' -Argument '' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam).Nav | Should -Be 'Back'
        (Invoke-WtAssistantSlash -Command 'help' -Argument '' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam).Settings.AssistantModel | Should -Be 'qwen3'
        Mock Write-WtReplLine { $script:Printed += @($Text) }
        $script:Printed = @()
        $null = Invoke-WtAssistantSlash -Command 'help' -Argument '' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam
        @($script:Printed).Count | Should -BeGreaterOrEqual @(Get-WtReplSlashTable).Count
        $script:Printed = @()
        $null = Invoke-WtAssistantSlash -Command 'status' -Argument '' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam -Permissions @{ v = 1; always = @(); endpoints = @() }
        ($script:Printed -join "`n") | Should -Match 'qwen3'
        ($script:Printed -join "`n") | Should -Match '11434'
        $script:Printed = @()
        $null = Invoke-WtAssistantSlash -Command 'status' -Argument '' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam `
            -ReadPermissions { @{ v = 1; always = @(@{ tool = 'a'; id = 'b'; at = 'c' }); endpoints = @(@{ endpoint = 'https://x/v1'; at = 'c' }) } }
        $expectedPermsLine = (Get-Translation 'AsStatusPerms') -f 1
        $script:Printed | Should -Contain $expectedPermsLine
        $script:Printed | Should -Contain (Get-Translation 'AsStatusUsageNone')
        $script:Printed | Should -Contain ((Get-Translation 'AsStatusNumCtx') -f (Get-Translation 'AsNotSet'))
        $Session.LastUsage = @{ PromptTokens = 4312; CompletionTokens = 210; CachedTokens = 3900; LastPromptTokens = 4312; Rounds = 2 }
        $script:Printed = @()
        $null = Invoke-WtAssistantSlash -Command 'status' -Argument '' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam -Permissions @{ v = 1; endpoints = @() }
        ($script:Printed -join "`n") | Should -Match '4\.312'
        ($script:Printed -join "`n") | Should -Match '3\.900'
    }

    It 'model saves an argument directly or picks from the list; endpoint takes a preset number or a pasted URL and forgets the privacy consent' {
        $r = Invoke-WtAssistantSlash -Command 'model' -Argument 'llama3' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam
        $script:Saved[0].AssistantModel | Should -Be 'llama3'
        $r.Settings.AssistantModel | Should -Be 'reloaded-model'
        New-WtLineQueue -Lines @('1')
        $null = Invoke-WtAssistantSlash -Command 'model' -Argument '' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam -GetModels { param($E, $K) @{ Ok = $true; Models = @('only'); ErrorText = '' } }
        $script:Saved[1].AssistantModel | Should -Be 'only'
        $script:WtAssistantPrivacyEndpoint = 'https://old/v1'
        New-WtLineQueue -Lines @('2')
        $null = Invoke-WtAssistantSlash -Command 'endpoint' -Argument '' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam
        $script:Saved[2].AssistantEndpoint | Should -Be (@(Get-WtLlmPresets)[1].Endpoint)
        $script:WtAssistantPrivacyEndpoint | Should -Be ''
        $null = Invoke-WtAssistantSlash -Command 'endpoint' -Argument 'https://api.groq.com/openai/v1' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam
        $script:Saved[3].AssistantEndpoint | Should -Be 'https://api.groq.com/openai/v1'
        $null = Invoke-WtAssistantSlash -Command 'endpoint' -Argument 'ftp://nope' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam
        @($script:Saved).Count | Should -Be 4
    }

    It 'model accepts optional temperature and max_tokens after the name; garbage is ignored' {
        $r = Invoke-WtAssistantSlash -Command 'model' -Argument 'qwen3 0.2 4096' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam
        $script:Saved[0].AssistantModel | Should -Be 'qwen3'
        $script:Saved[0].AssistantTemperature | Should -Be '0.2'
        $script:Saved[0].AssistantMaxTokens | Should -Be '4096'
        $null = Invoke-WtAssistantSlash -Command 'model' -Argument 'qwen3 hot' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam
        $script:Saved[1].PSObject.Properties.Name | Should -Not -Contain 'AssistantTemperature'
    }

    It 'key reads masked and stores protected; an empty answer clears' {
        Mock Read-WtReplLine { @{ Kind = 'Submit'; Text = $script:LineQueue.Dequeue() } }
        New-WtLineQueue -Lines @('sk-secret')
        $null = Invoke-WtAssistantSlash -Command 'key' -Argument '' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam
        $script:Saved[0].AssistantApiKey | Should -Not -Be 'sk-secret'
        (Unprotect-WtAssistantSecret -Blob $script:Saved[0].AssistantApiKey) | Should -Be 'sk-secret'
        New-WtLineQueue -Lines @('')
        $null = Invoke-WtAssistantSlash -Command 'key' -Argument '' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam
        $script:Saved[1].AssistantApiKey | Should -Be ''
    }

    It 'scan offers the servers found or the installed-but-silent hints; test prints the connection verdict' {
        New-WtLineQueue -Lines @('1')
        $null = Invoke-WtAssistantSlash -Command 'scan' -Argument '' -Session $Session -Settings $Unset -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam `
            -Scan { @([PSCustomObject]@{ Provider = 'LM Studio'; Endpoint = 'http://127.0.0.1:1234/v1'; Models = @('solo') }) }
        $script:Saved[0].AssistantEndpoint | Should -Be 'http://127.0.0.1:1234/v1'
        $script:Saved[0].AssistantModel | Should -Be 'solo'
        Mock Write-WtReplLine { $script:Printed += @($Text) }
        $script:Printed = @()
        Mock Get-WtLlmLocalHints { [string[]]@('hint-line') }
        $null = Invoke-WtAssistantSlash -Command 'scan' -Argument '' -Session $Session -Settings $Unset -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam -Scan { @() }
        $script:Printed | Should -Contain 'hint-line'
        $script:Printed = @()
        $null = Invoke-WtAssistantSlash -Command 'test' -Argument '' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam -Test { param($S) [string[]]@('reachable', 'tools ok') }
        $script:Printed | Should -Contain 'tools ok'
    }

    It 'perms lists the remembered endpoints and revokes the picked one' {
        $perms = @{ v = 1; endpoints = @(@{ endpoint = 'https://api.x.com/v1'; at = 'y' }, @{ endpoint = 'https://api.z.com/v1'; at = 'z' }) }
        $script:SavedP = $null
        $script:LineQueue.Enqueue('1')
        $script:WtAssistantPrivacyEndpoint = 'https://api.x.com/v1'
        $null = Invoke-WtAssistantSlash -Command 'perms' -Argument '' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam -Permissions $perms -SavePermissions { param($P) $script:SavedP = $P }
        @($script:SavedP.endpoints).Count | Should -Be 1
        $script:SavedP.endpoints[0].endpoint | Should -Be 'https://api.z.com/v1'
        $script:WtAssistantPrivacyEndpoint | Should -Be ''
        $script:SavedP = $null
        New-WtLineQueue -Lines @('')
        $null = Invoke-WtAssistantSlash -Command 'perms' -Argument '' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam -Permissions $perms -SavePermissions { param($P) $script:SavedP = $P }
        $script:SavedP | Should -BeNullOrEmpty
    }

    It 'tools lists every registry tool with its state; a number flips one and saves it with the permissions, Enter keeps all' {
        $perms = @{ v = 1; always = @(); endpoints = @(); disabled = @() }
        $script:SavedPerms = $null
        New-WtLineQueue -Lines @('1')
        $null = Invoke-WtAssistantSlash -Command 'tools' -Argument '' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam -Permissions $perms -SavePermissions { param($P) $script:SavedPerms = $P }
        $first = [string]@(Get-WtAssistantToolRegistry)[0].Name
        @($script:SavedPerms.disabled) | Should -Be @($first)
        New-WtLineQueue -Lines @('1')
        $null = Invoke-WtAssistantSlash -Command 'tools' -Argument '' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam -Permissions $script:SavedPerms -SavePermissions { param($P) $script:SavedPerms = $P }
        @($script:SavedPerms.disabled).Count | Should -Be 0
        $script:SavedPerms = $null
        New-WtLineQueue -Lines @('')
        $null = Invoke-WtAssistantSlash -Command 'tools' -Argument '' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam -Permissions $perms -SavePermissions { param($P) $script:SavedPerms = $P }
        $script:SavedPerms | Should -BeNullOrEmpty
        Resolve-WtReplSlash -Word 'araclar' | Should -Be 'tools'
        Resolve-WtReplSlash -Word 'tools' | Should -Be 'tools'
    }

    It 'Write-WtReplWelcome prints the introduction, the five examples and the key hint, wrapped, in the app column' {
        $script:Out = New-Object System.Collections.Generic.List[string]
        Write-WtReplWelcome -Width 60 -Write { param($Text, $Fg, $NoNewline) $script:Out.Add([string]$Text) }
        $text = @($script:Out | ForEach-Object { $_.TrimEnd() })
        ($text -join ' ') | Should -BeLike ('*' + (Get-Translation 'AsWelcome2') + '*')
        foreach ($key in 'AsWelcomeEx1', 'AsWelcomeEx2', 'AsWelcomeEx3', 'AsWelcomeEx4', 'AsWelcomeEx5') {
            @($text | Where-Object { $_ -like ('*' + (Get-Translation $key)) }).Count | Should -Be 1 -Because $key
        }
        ($text -join ' ') | Should -BeLike '*Esc*'
        @($text | Where-Object { $_.Length -gt 0 -and -not $_.StartsWith('  ') }).Count | Should -Be 0
        foreach ($row in $text) { $row.Length | Should -BeLessOrEqual 59 }
    }

    It 'forget asks first, then wipes the files, the session consent and starts a new session' {
        $script:Cleared = 0
        $script:WtAssistantPrivacyEndpoint = 'https://api.x.com/v1'
        $script:LineQueue.Enqueue('n')
        $r = Invoke-WtAssistantSlash -Command 'forget' -Argument '' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam -ClearMemory { $script:Cleared++; 4 }
        $r.NewSession | Should -BeFalse
        $script:Cleared | Should -Be 0
        $script:LineQueue.Enqueue('y')
        $r = Invoke-WtAssistantSlash -Command 'forget' -Argument '' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam -ClearMemory { $script:Cleared++; 4 }
        $r.NewSession | Should -BeTrue
        $script:Cleared | Should -Be 1
        $script:WtAssistantPrivacyEndpoint | Should -Be ''
        $r.Notice | Should -Be ((Get-Translation 'AsForgotten') -f 4)
        $r.NoticeFg | Should -Be 'DarkYellow'
    }

    It 'save writes the transcript lines through the report seam' {
        $Session.Entries.Add(@{ Kind = 'User'; Text = 'soru' })
        $Session.Entries.Add(@{ Kind = 'Assistant'; Text = 'cevap' })
        $Session.Suggestions = @(@{ Label = 'S'; Path = 'P'; Risk = 'SAFE' }, @{ Label = 'T'; Path = ''; Risk = '' })
        $script:Report = $null
        $null = Invoke-WtAssistantSlash -Command 'save' -Argument '' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam -SaveReport { param($Lines) $script:Report = @($Lines); 'C:\r.txt' }
        $script:Report | Should -Contain '  > soru'
        $script:Report | Should -Contain '  cevap'
        ($script:Report -join "`n") | Should -Match '\[1\] S'
        $script:Report[-2] | Should -Be ''
        $script:Report[-1] | Should -Be '  [2] T'
    }

    It 'profile off/on flips the session flag, yenile forces a rebuild, bare prints the status and the json' {
        $script:ProfileSeam = { param($Force) $script:ProfileCalls += @($Force); @{ Json = '{"short":1}'; Cold = [bool]$Force; BuiltAt = '2026-09-01T09:00:00' } }
        Mock Write-WtReplLine { $script:Printed += @([string]$Text) }
        $script:ProfileCalls = @()
        $Session.SystemExtra = 'stale'
        $null = Invoke-WtAssistantSlash -Command 'profile' -Argument 'off' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam -Profile $script:ProfileSeam
        $Session.ProfileEnabled | Should -BeFalse
        $null = Invoke-WtAssistantSlash -Command 'profile' -Argument 'on' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam -Profile $script:ProfileSeam
        $Session.ProfileEnabled | Should -BeTrue
        $null = Invoke-WtAssistantSlash -Command 'profile' -Argument 'yenile' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam -Profile $script:ProfileSeam
        $script:ProfileCalls | Should -Be @($true)
        $script:Printed = @()
        $null = Invoke-WtAssistantSlash -Command 'profile' -Argument '' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam -Profile $script:ProfileSeam
        $script:ProfileCalls | Should -Be @($true, $false)
        ($script:Printed -join "`n") | Should -Match '\{"short":1\}'
        $Session.SystemExtra | Should -BeNullOrEmpty
    }

    It 'notes lists numbered notes and deletes the picked one; an empty list says so' {
        $script:Removed = @()
        $seams = @{ ReadNotes = { @(@{ text = 'a'; at = '2026-09-01T10:00:00' }, @{ text = 'b'; at = '2026-09-01T11:00:00' }) }; RemoveNote = { param($I) $script:Removed += @($I); $true } }
        $Session.SystemExtra = 'stale'
        $script:LineQueue.Enqueue('2')
        $null = Invoke-WtAssistantSlash -Command 'notes' -Argument '' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam @seams
        $script:Removed | Should -Be @(2)
        $script:LineQueue.Enqueue('')
        $null = Invoke-WtAssistantSlash -Command 'notes' -Argument '' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam @seams
        $script:Removed | Should -Be @(2)
        Mock Write-WtReplLine { $script:Printed += @([string]$Text) }
        $script:Printed = @()
        $null = Invoke-WtAssistantSlash -Command 'notes' -Argument '' -Session $Session -Settings $Local -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -ReadSettings $script:ReadSeam -ReadNotes { @() } -RemoveNote { param($I) $true }
        ($script:Printed -join "`n") | Should -Match ([regex]::Escape((Get-Translation 'AsNotesEmpty')))
        $Session.SystemExtra | Should -BeNullOrEmpty
    }

    It '/settings hops into the framed settings screen, re-reads the settings and drops the endpoint consent when the endpoint changed' {
        $script:WtAssistantPrivacyEndpoint = 'http://127.0.0.1:11434/v1'
        $script:Opened = 0
        $changed = [PSCustomObject]@{ Language = 'EN'; AssistantEndpoint = 'https://api.example.com/v1'; AssistantModel = 'gpt'; AssistantApiKey = '' }
        Mock Write-WtReplLine { $script:Printed += @($Text) }
        $script:Printed = @()
        $r = Invoke-WtAssistantSlash -Command 'settings' -Session (New-WtReplSession) -Settings $script:Local -Hop { param($A) & $A } -OpenSettings { $script:Opened++; @{ Nav = 'Back' } } -ReadSettings { $changed }
        $script:Opened | Should -Be 1
        $r.Settings.AssistantModel | Should -Be 'gpt'
        $script:WtAssistantPrivacyEndpoint | Should -Be ''
        ($script:Printed -join "`n") | Should -Match 'gpt'
        $script:WtAssistantPrivacyEndpoint = 'http://127.0.0.1:11434/v1'
        $null = Invoke-WtAssistantSlash -Command 'settings' -Session (New-WtReplSession) -Settings $script:Local -Hop { param($A) & $A } -OpenSettings { @{ Nav = 'Back' } } -ReadSettings { $script:Local }
        $script:WtAssistantPrivacyEndpoint | Should -Be 'http://127.0.0.1:11434/v1'
        $script:WtAssistantPrivacyEndpoint = ''
    }

    It '/settings passes the settings screen Quit verdict on, and a plain Back stays in the chat' {
        Mock Write-WtReplLine { $script:Printed += @($Text) }
        $script:Printed = @()
        $r = Invoke-WtAssistantSlash -Command 'settings' -Session (New-WtReplSession) -Settings $script:Local -Hop { param($A) & $A } -OpenSettings { @{ Nav = 'Exit' } } -ReadSettings { $script:Local }
        $r.Nav | Should -Be 'Exit'
        $r = Invoke-WtAssistantSlash -Command 'settings' -Session (New-WtReplSession) -Settings $script:Local -Hop { param($A) & $A } -OpenSettings { @{ Nav = 'Back' } } -ReadSettings { $script:Local }
        $r.Nav | Should -Be 'None'
        $script:WtAssistantPrivacyEndpoint = ''
    }

    It '/temizle and /clear ARE /yeni: the same command, a new session with the page repainted by the screen' {
        foreach ($word in @('temizle', 'clear', 'yeni', 'new')) { Resolve-WtReplSlash -Word $word | Should -Be 'new' -Because $word }
        (ConvertTo-WtReplCommand -Line '/clear' -SuggestionCount 0).Command | Should -Be 'new'
        $r = Invoke-WtAssistantSlash -Command 'new' -Session (New-WtReplSession) -Settings $script:Local
        $r.NewSession | Should -BeTrue
        $r.Notice | Should -Be ''
        (Get-Command Invoke-WtAssistantSlash).Parameters.Keys | Should -Not -Contain 'ClearScreen'
    }

    It '/copy puts the last answer (or the Nth last) on the clipboard and says so; nothing to copy is a hint' {
        $s = New-WtReplSession
        $s.Entries.Add(@{ Kind = 'Assistant'; Text = 'first' })
        $s.Entries.Add(@{ Kind = 'Info'; Text = 'meta' })
        $s.Entries.Add(@{ Kind = 'Assistant'; Text = 'second' })
        Mock Write-WtReplLine { $script:Printed += @($Text) }
        $script:Printed = @(); $script:Clip = $null
        $null = Invoke-WtAssistantSlash -Command 'copy' -Session $s -Settings $script:Local -SetClipboard { param($T) $script:Clip = $T }
        $script:Clip | Should -Be 'second'
        ($script:Printed -join "`n") | Should -Match ([regex]::Escape(((Get-Translation 'AsReplCopied') -f 6)))
        $null = Invoke-WtAssistantSlash -Command 'copy' -Argument '2' -Session $s -Settings $script:Local -SetClipboard { param($T) $script:Clip = $T }
        $script:Clip | Should -Be 'first'
        $script:Printed = @()
        $null = Invoke-WtAssistantSlash -Command 'copy' -Argument '9' -Session $s -Settings $script:Local -SetClipboard { param($T) throw 'must not' }
        ($script:Printed -join "`n") | Should -Match ([regex]::Escape((Get-Translation 'AsReplNothingToCopy')))
        $script:Printed = @()
        { Invoke-WtAssistantSlash -Command 'copy' -Session $s -Settings $script:Local -SetClipboard { param($T) throw 'no clipboard' } } | Should -Not -Throw
        ($script:Printed -join "`n") | Should -Match ([regex]::Escape((Get-Translation 'AsReplCopyFailed')))
        ($script:Printed -join "`n") | Should -Not -Match ([regex]::Escape((Get-Translation 'AsReplNothingToCopy')))
    }

    It '/help lists every command and the two key-hint lines' {
        Mock Write-WtReplLine { $script:Printed += @($Text) }
        $script:Printed = @()
        $null = Invoke-WtAssistantSlash -Command 'help' -Session (New-WtReplSession) -Settings $script:Local
        $script:Printed.Count | Should -Be (@(Get-WtReplSlashTable).Count + 3)
        $script:Printed | Should -Contain (Get-Translation 'AsReplHelpKeys1')
        $script:Printed | Should -Contain (Get-Translation 'AsReplHelpKeys2')
    }
}

Describe 'Write-WtReplPage' {
    It 'clears the screen and then prints the header' {
        $script:Order = @()
        Mock Clear-WtReplScreen { $script:Order += @('clear') }
        Mock Write-WtReplHeader { $script:Order += @('header') }
        Write-WtReplPage
        $script:Order | Should -Be @('clear', 'header')
    }
}

Describe 'Invoke-WtAssistantReplWizard' {
    BeforeEach { $script:Saved = @(); $script:WtAssistantPrivacyEndpoint = '' }
    BeforeAll { $script:SaveSeam = { param($Settings) $script:Saved += @($Settings) } }

    It 'scan -> pick server -> single model auto -> probe test -> saved' {
        New-WtLineQueue -Lines @('1')
        $r = Invoke-WtAssistantReplWizard -ReadLine $script:ReadLineSeam -Save $script:SaveSeam `
            -Scan { @([PSCustomObject]@{ Provider = 'LM Studio'; Endpoint = 'http://127.0.0.1:1234/v1'; Models = @('solo') }) } `
            -Test { param($S) [string[]]@('ok') }
        $r.AssistantEndpoint | Should -Be 'http://127.0.0.1:1234/v1'
        $r.AssistantModel | Should -Be 'solo'
        @($script:Saved).Count | Should -Be 1
    }

    It 'a pasted remote URL asks for the key (masked) and the model, then tests' {
        New-WtLineQueue -Lines @('https://api.groq.com/openai/v1', 'gsk-xyz', '2')
        $r = Invoke-WtAssistantReplWizard -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -Scan { @() } `
            -GetModels { param($E, $K) $script:KeySeen = $K; @{ Ok = $true; Models = @('m1', 'm2'); ErrorText = '' } } -Test { param($S) [string[]]@('ok') }
        $r.AssistantEndpoint | Should -Be 'https://api.groq.com/openai/v1'
        $r.AssistantModel | Should -Be 'm2'
        $script:KeySeen | Should -Be 'gsk-xyz'
        (Unprotect-WtAssistantSecret -Blob ([string]$script:Saved[0].AssistantApiKey)) | Should -Be 'gsk-xyz'
    }

    It 'refuses a single Ollama model that firmly lacks tools; passes Unknown' {
        New-WtLineQueue -Lines @('1')
        $r = Invoke-WtAssistantReplWizard -ReadLine $script:ReadLineSeam -Save $script:SaveSeam `
            -Scan { @([PSCustomObject]@{ Provider = 'Ollama'; Endpoint = 'http://127.0.0.1:11434/v1'; Models = @('lightonocr') }) } `
            -FilterOllama { param($Models) [string[]]@($Models) } -ProbeOllama { param($M) 'NoTools' } -Test { param($S) [string[]]@('ok') }
        $r | Should -BeNullOrEmpty
        @($script:Saved).Count | Should -Be 0
        New-WtLineQueue -Lines @('1')
        $r = Invoke-WtAssistantReplWizard -ReadLine $script:ReadLineSeam -Save $script:SaveSeam `
            -Scan { @([PSCustomObject]@{ Provider = 'Ollama'; Endpoint = 'http://127.0.0.1:11434/v1'; Models = @('qwen3') }) } `
            -FilterOllama { param($Models) [string[]]@($Models) } -ProbeOllama { param($M) 'Unknown' } -Test { param($S) [string[]]@('ok') }
        $r.AssistantModel | Should -Be 'qwen3'
    }

    It 'nothing found and nothing pasted: prints the hints and gives up without saving' {
        Mock Write-WtReplLine { $script:Printed += @($Text) }
        Mock Get-WtLlmLocalHints { [string[]]@('ollama-hint') }
        $script:Printed = @()
        New-WtLineQueue -Lines @('')
        (Invoke-WtAssistantReplWizard -ReadLine $script:ReadLineSeam -Save $script:SaveSeam -Scan { @() }) | Should -BeNullOrEmpty
        $script:Printed | Should -Contain 'ollama-hint'
        ($script:Printed -join "`n") | Should -Match 'api'
        @($script:Saved).Count | Should -Be 0
    }
}

Describe 'Invoke-WtAssistantScreen (the loop)' {
    BeforeEach {
        $script:WtAssistantChat = $null
        $script:WtReplMode = $false
        $script:Sent = @(); $script:Slashed = @(); $script:Entered = 0; $script:Exited = 0
        $script:Enter = { $script:Entered++ }; $script:Exit = { $script:Exited++ }
        $script:TitleSet = $null
        Mock Read-WtSettings { $script:Local }
        Mock Set-WtReplTitle { param($Text) $script:TitleSet = $Text }
        Mock Clear-Host { }
        Mock Write-WtReplHeader { }
    }

    It 'enters the mode, sends plain lines, routes slash and digits, and leaves on /quit with the mode restored' {
        New-WtLineQueue -Lines @('neden yavas', '/help', '/quit')
        $r = Invoke-WtAssistantScreen -ReadLine $script:ReadLineSeam -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } `
            -Send { param($S, $Settings, $Text) $script:Sent += @($Text) } `
            -Slash { param($C, $A, $S, $Settings) $script:Slashed += @($C); $script:LastSession = $S; @{ Nav = $(if ($C -eq 'quit') { 'Back' } else { 'None' }); Settings = $Settings; NewSession = $false } }
        $r.Nav | Should -Be 'Back'
        $script:Sent | Should -Be @('neden yavas')
        $script:Slashed | Should -Be @('help', 'quit')
        $script:Entered | Should -Be 1; $script:Exited | Should -Be 1
        $script:TitleSet | Should -Be (Get-WtWindowTitle)
        $script:LastSession.History.Count | Should -Be 3
        $script:WtAssistantChat | Should -Be $null
    }

    It 'a throwing ReadPermissions/ReadNotes still renders the status line with zero counts, not a crash' {
        $script:Captured = $null
        $reader = { param($Prompt, $History, $StatusRows) $script:Captured = $StatusRows; @{ Kind = 'Submit'; Text = '/quit' } }
        $r = Invoke-WtAssistantScreen -ReadLine $reader -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } -Send { param($S, $Settings, $Text) } `
            -Slash { param($C, $A, $S, $Settings) @{ Nav = 'Back'; Settings = $Settings; NewSession = $false } } `
            -ReadPermissions { throw 'boom' } -ReadNotes { throw 'boom' }
        $r.Nav | Should -Be 'Back'
        $script:Captured | Should -Not -Be $null
        $text = [string](@(@($script:Captured)[0])[0].T)
        $text | Should -BeLike '*qwen3*'
        $notesWord = (Get-Translation 'AsStatusNotesShort').Replace('{0}', '').Trim()
        $permsWord = (Get-Translation 'AsStatusPermsShort').Replace('{0}', '').Trim()
        $text | Should -Not -BeLike ('*' + $notesWord + '*')
        $text | Should -Not -BeLike ('*' + $permsWord + '*')
    }

    It 'refreshes the memory counts after /izinler revokes a permission' {
        $script:PermStore = @{ endpoints = @(@{ endpoint = 'https://a/v1' }, @{ endpoint = 'https://b/v1' }) }
        $script:StatusTexts = New-Object System.Collections.Generic.List[string]
        $script:Ticks = 0
        $reader = { param($Prompt, $History, $StatusRows)
            $script:Ticks++
            $script:StatusTexts.Add([string](@(@($StatusRows)[0])[0].T))
            $(if ($script:Ticks -eq 1) { @{ Kind = 'Submit'; Text = '/izinler' } } else { @{ Kind = 'Submit'; Text = '/quit' } })
        }
        $r = Invoke-WtAssistantScreen -ReadLine $reader -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } -Send { param($S, $Settings, $Text) } -ReadNotes { @() } `
            -ReadPermissions { $script:PermStore } `
            -Slash { param($C, $A, $S, $Settings)
                if ($C -eq 'perms') { $script:PermStore.endpoints = @($script:PermStore.endpoints | Select-Object -First 1) }
                @{ Nav = $(if ($C -eq 'quit') { 'Back' } else { 'None' }); Settings = $Settings; NewSession = $false }
            }
        $r.Nav | Should -Be 'Back'
        $script:StatusTexts.Count | Should -Be 2
        $script:StatusTexts[0] | Should -BeLike ('*' + ((Get-Translation 'AsStatusPermsShort') -f 2) + '*')
        $script:StatusTexts[1] | Should -BeLike ('*' + ((Get-Translation 'AsStatusPermsShort') -f 1) + '*')
    }

    It 'entering from the menu is always a fresh conversation: /quit drops the chat, so the next entry starts empty' {
        $script:WtAssistantChat = $null
        New-WtLineQueue -Lines @('soru', '/quit')
        $r = Invoke-WtAssistantScreen -ReadLine $script:ReadLineSeam -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } `
            -Send { param($S, $Settings, $Text) $S.Messages.Add(@{ role = 'user'; content = $Text }); $S.Entries.Add(@{ Kind = 'User'; Text = $Text }) } `
            -Slash { param($C, $A, $S, $Settings) @{ Nav = $(if ($C -eq 'quit') { 'Back' } else { 'None' }); Settings = $Settings; NewSession = $false } }
        $r.Nav | Should -Be 'Back'
        $script:WtAssistantChat | Should -Be $null
        Mock Write-WtReplTranscriptTail { $script:TailPrinted = $true }
        $script:TailPrinted = $false
        New-WtLineQueue -Lines @('/quit')
        $null = Invoke-WtAssistantScreen -ReadLine $script:ReadLineSeam -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } -Send { param($S, $Settings, $Text) } `
            -Slash { param($C, $A, $S, $Settings) @{ Nav = 'Back'; Settings = $Settings; NewSession = $false } }
        $script:TailPrinted | Should -BeFalse
        $script:WtAssistantChat = $null
        New-WtLineQueue -Lines @('/ayarlar')
        $null = Invoke-WtAssistantScreen -ReadLine $script:ReadLineSeam -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } -Send { param($S, $Settings, $Text) } `
            -Slash { param($C, $A, $S, $Settings) @{ Nav = 'Exit'; Settings = $Settings; NewSession = $false } }
        $script:WtAssistantChat | Should -Be $null
        $script:WtAssistantChat = $null
        $script:Presses = 0
        $esc = { param($P, $History, $StatusRows) $script:Presses++; @{ Kind = 'Cancel'; Text = '' } }
        $r = Invoke-WtAssistantScreen -ReadLine $esc -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } -Send { param($S, $Settings, $Text) } -Now { Get-Date '2026-09-03T10:00:00' }
        $r.Nav | Should -Be 'Back'
        $script:Presses | Should -Be 3
        $script:WtAssistantChat | Should -Be $null
    }

    It 'a digit opens the suggestion; a Push verdict leaves the REPL and comes back with the transcript tail' {
        New-WtLineQueue -Lines @('1')
        $script:WtAssistantChat = New-WtReplSession
        $script:WtAssistantChat.Suggestions = @(@{ Label = 'S'; Path = ''; Risk = ''; Entry = $null })
        $r = Invoke-WtAssistantScreen -ReadLine $script:ReadLineSeam -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } -Send { param($S, $Settings, $Text) } `
            -Suggest { param($S, $Index) @{ Nav = 'Push'; Target = 'Services'; Char = ''; HasMarks = $false } }
        $r.Nav | Should -Be 'Push'; $r.Target | Should -Be 'Services'
        $script:Exited | Should -Be 1
        $script:WtAssistantChat.Entries.Add(@{ Kind = 'Info'; Text = 'old-line' })
        Mock Write-WtReplTranscriptTail { $script:TailPrinted = $true }
        $script:TailPrinted = $false
        New-WtLineQueue -Lines @('/quit')
        $null = Invoke-WtAssistantScreen -ReadLine $script:ReadLineSeam -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } -Send { param($S, $Settings, $Text) } `
            -Slash { param($C, $A, $S, $Settings) @{ Nav = 'Back'; Settings = $Settings; NewSession = $false } }
        $script:TailPrinted | Should -BeTrue
    }

    It 'an unknown digit (endpoint unset) or slash prints a hint and stays; Esc three times in a row backs out' {
        Mock Read-WtSettings { $script:Unset }
        Mock Write-WtReplLine { $script:Printed += @($Text) }
        $script:Printed = @()
        $script:Clock = [datetime]'2026-09-02T10:00:00'
        $script:Ticks = 0
        $reader = { param($Prompt)
            $script:Ticks++
            switch ($script:Ticks) {
                1 { @{ Kind = 'Submit'; Text = '7' } }
                2 { @{ Kind = 'Submit'; Text = '/nope' } }
                3 { @{ Kind = 'Cancel'; Text = '' } }
                4 { @{ Kind = 'Cancel'; Text = '' } }
                5 { @{ Kind = 'Cancel'; Text = '' } }
                default { @{ Kind = 'Eof'; Text = '' } }
            }
        }
        $r = Invoke-WtAssistantScreen -ReadLine $reader -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } -Send { param($S, $Settings, $Text) throw 'no send' } -Wizard { $null } -Now { $script:Clock = $script:Clock.AddSeconds(0.5); $script:Clock }
        $r.Nav | Should -Be 'Back'
        $script:Ticks | Should -Be 5
        ($script:Printed -join "`n") | Should -Match ([regex]::Escape((Get-Translation 'AsReplNoSuggestion') -f 7))
        ($script:Printed -join "`n") | Should -Match 'nope'
    }

    It 'a lone digit the card cannot answer goes to the model with a note naming what is on screen' {
        $script:SentTexts = @(); $script:NotesSeen = @(); $script:KeepSeen = @(); $script:AtSend = @()
        $send = { param($S, $Settings, $Text, $Keep) $script:SentTexts += @($Text); $script:KeepSeen += @([bool]$Keep); $script:AtSend += @($S.PendingNotes.Count); $script:NotesSeen += @($S.PendingNotes.ToArray()); $S.PendingNotes.Clear() }
        $quit = { param($C, $A, $S, $Settings) @{ Nav = 'Back'; Settings = $Settings; NewSession = $false } }
        New-WtLineQueue -Lines @('7', '0', '/quit')
        $null = Invoke-WtAssistantScreen -ReadLine $script:ReadLineSeam -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } -Send $send -Slash $quit
        $script:SentTexts | Should -Be @('7', '0')
        $script:AtSend | Should -Be @(1, 1)
        $script:KeepSeen | Should -Be @($false, $false)
        $script:NotesSeen[0] | Should -Match '^\(note: the user typed 7 but no numbered suggestion list is active'
        $script:NotesSeen[1] | Should -Match '^\(note: the user typed 0 but no numbered suggestion list is active'
        $script:SentTexts = @(); $script:NotesSeen = @(); $script:KeepSeen = @()
        $script:WtAssistantChat = New-WtReplSession
        $script:WtAssistantChat.Suggestions = @(@{ Label = 'A'; Path = ''; Risk = ''; Entry = $null }, @{ Label = 'B'; Path = ''; Risk = ''; Entry = $null })
        New-WtLineQueue -Lines @('7', '/quit')
        $null = Invoke-WtAssistantScreen -ReadLine $script:ReadLineSeam -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } -Send $send -Slash $quit
        $script:SentTexts | Should -Be @('7')
        $script:KeepSeen | Should -Be @($true)
        $script:NotesSeen[0] | Should -Match '^\(note: the user typed 7 but the numbers on screen are 1-2: 1 A; 2 B - '
        $script:WtAssistantChat = $null
        $script:AtSend = @()
        New-WtLineQueue -Lines @('3', '/quit')
        $null = Invoke-WtAssistantScreen -ReadLine $script:ReadLineSeam -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } -Send { param($S, $Settings, $Text) $script:AtSend += @($S.PendingNotes.Count); $script:LastSession = $S } -Slash $quit
        $script:AtSend | Should -Be @(1)
        $script:LastSession.PendingNotes.Count | Should -Be 0
        $script:WtAssistantChat = New-WtReplSession
        Add-WtAssistantPendingNote -Chat $script:WtAssistantChat -Text '(note: user ran 1 X -> applied)'
        New-WtLineQueue -Lines @('5', '/quit')
        $null = Invoke-WtAssistantScreen -ReadLine $script:ReadLineSeam -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } -Send { param($S, $Settings, $Text) $n = @($S.PendingNotes.ToArray()); $S.PendingNotes.Clear(); foreach ($x in $n) { $S.PendingNotes.Add($x) }; $script:LastSession = $S } -Slash $quit
        @($script:LastSession.PendingNotes.ToArray()) | Should -Be @('(note: user ran 1 X -> applied)')
    }

    It 'a digit run with the endpoint unset drops the report (nothing to send it to) but keeps the run note queued and the slot clean' {
        Mock Read-WtSettings { $script:Unset }
        $script:WtAssistantChat = New-WtReplSession
        $script:WtAssistantChat.Suggestions = @(@{ Label = 'S'; Path = ''; Risk = ''; Entry = $null })
        New-WtLineQueue -Lines @('1', '/quit')
        $null = Invoke-WtAssistantScreen -ReadLine $script:ReadLineSeam -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } -Wizard { $null } `
            -Suggest { param($S, $Index) Add-WtAssistantPendingNote -Chat $S -Text '(note: user ran 1 S -> ran (1 output lines shown to the user))'; $S.FollowUp = '(result of 1 S, 1 lines; explain it, do not repeat it)'; $null } `
            -FollowUp { param($S, $Settings, $Report) throw 'must not send without an endpoint' } `
            -Slash { param($C, $A, $S, $Settings) $script:LastSession = $S; @{ Nav = 'Back'; Settings = $Settings; NewSession = $false } }
        $script:LastSession.FollowUp | Should -Be ''
        $script:LastSession.PendingNotes.Count | Should -Be 1
    }

    It 'a digit run that left a report sends it at once through the FollowUp seam and clears the slot; an empty slot sends nothing' {
        $script:Reports = @(); $script:Runs = 0; $script:SeenSlot = 'unset'
        $script:WtAssistantChat = New-WtReplSession
        $script:WtAssistantChat.Suggestions = @(@{ Label = 'S'; Path = ''; Risk = ''; Entry = $null })
        New-WtLineQueue -Lines @('1', '1', '/quit')
        $null = Invoke-WtAssistantScreen -ReadLine $script:ReadLineSeam -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } `
            -Send { param($S, $Settings, $Text) throw 'no send' } `
            -Suggest { param($S, $Index) $script:Runs++; if ($script:Runs -eq 1) { $S.FollowUp = '(result of 1 S, 2 lines; explain it, do not repeat it)' }; $null } `
            -FollowUp { param($S, $Settings, $Report) $script:Reports += @($Report); $script:SeenSlot = [string]$S.FollowUp } `
            -Slash { param($C, $A, $S, $Settings) @{ Nav = 'Back'; Settings = $Settings; NewSession = $false } }
        $script:Runs | Should -Be 2
        $script:Reports | Should -Be @('(result of 1 S, 2 lines; explain it, do not repeat it)')
        $script:SeenSlot | Should -Be ''
    }

    It 'the default FollowUp seam sends the report as a harness message through Invoke-WtAssistantSend' {
        $script:HarnessArgs = $null
        Mock Invoke-WtAssistantSend { param($Chat, $Settings, $Text, $Breadcrumb, $Harness) $script:HarnessArgs = $PSBoundParameters }
        $script:WtAssistantChat = New-WtReplSession
        $script:WtAssistantChat.Suggestions = @(@{ Label = 'S'; Path = ''; Risk = ''; Entry = $null })
        New-WtLineQueue -Lines @('1', '/quit')
        $null = Invoke-WtAssistantScreen -ReadLine $script:ReadLineSeam -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } `
            -Suggest { param($S, $Index) $S.FollowUp = '(result of 1 S, 0 lines; explain it, do not repeat it)'; $null } `
            -Slash { param($C, $A, $S, $Settings) @{ Nav = 'Back'; Settings = $Settings; NewSession = $false } }
        $script:HarnessArgs.Text | Should -Be '(result of 1 S, 0 lines; explain it, do not repeat it)'
        [bool]$script:HarnessArgs.Harness | Should -BeTrue
        $script:HarnessArgs.Breadcrumb | Should -Be (Get-Translation 'Assistant')
    }

    It 'a bare q / exit prints how to leave and stays - never a message for the model, never a quit' {
        Mock Write-WtReplLine { $script:Printed += @($Text) }
        $script:Printed = @()
        New-WtLineQueue -Lines @('q', 'exit', '/quit')
        $r = Invoke-WtAssistantScreen -ReadLine $script:ReadLineSeam -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } `
            -Send { param($S, $Settings, $Text) throw 'no send' } `
            -Slash { param($C, $A, $S, $Settings) $script:LastSession = $S; @{ Nav = 'Back'; Settings = $Settings; NewSession = $false } }
        $r.Nav | Should -Be 'Back'
        @($script:Printed | Where-Object { $_ -eq (Get-Translation 'AsReplQuitHint') }).Count | Should -Be 2
        $script:LastSession.History.Count | Should -Be 3
    }

    It 'Esc presses more than two seconds apart never add up to an exit' {
        $script:Clock = [datetime]'2026-09-02T10:00:00'
        $script:Ticks = 0
        $reader = { param($Prompt) $script:Ticks++; if ($script:Ticks -le 3) { @{ Kind = 'Cancel'; Text = '' } } else { @{ Kind = 'Eof'; Text = '' } } }
        $r = Invoke-WtAssistantScreen -ReadLine $reader -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } -Send { param($S, $Settings, $Text) } -Now { $script:Clock = $script:Clock.AddSeconds(5); $script:Clock }
        $r.Nav | Should -Be 'Back'
        $script:Ticks | Should -Be 4
    }
    It 'anything typed between two Esc presses restarts the count, and Ctrl+C never leaves any more' {
        $script:Clock = [datetime]'2026-09-02T10:00:00'
        $script:Ticks = 0
        $reader = { param($Prompt)
            $script:Ticks++
            switch ($script:Ticks) {
                1 { @{ Kind = 'Cancel'; Text = '' } }
                2 { @{ Kind = 'Cancel'; Text = '' } }
                3 { @{ Kind = 'Submit'; Text = '/nope' } }
                4 { @{ Kind = 'Cancel'; Text = '' } }
                5 { @{ Kind = 'CtrlC'; Text = '' } }
                6 { @{ Kind = 'CtrlC'; Text = '' } }
                7 { @{ Kind = 'CtrlC'; Text = '' } }
                default { @{ Kind = 'Eof'; Text = '' } }
            }
        }
        $r = Invoke-WtAssistantScreen -ReadLine $reader -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } -Send { param($S, $Settings, $Text) throw 'no send' } -Now { $script:Clock = $script:Clock.AddSeconds(0.2); $script:Clock }
        $r.Nav | Should -Be 'Back'
        $script:Ticks | Should -Be 8
    }

    It 'runs the wizard when unconfigured and keeps the prompt open when it gives up' {
        Mock Read-WtSettings { $script:Unset }
        $script:WizardRuns = 0
        New-WtLineQueue -Lines @('/quit')
        $r = Invoke-WtAssistantScreen -ReadLine $script:ReadLineSeam -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } -Send { param($S, $Settings, $Text) } `
            -Wizard { $script:WizardRuns++; $null } -Slash { param($C, $A, $S, $Settings) @{ Nav = 'Back'; Settings = $Settings; NewSession = $false } }
        $script:WizardRuns | Should -Be 1
        $r.Nav | Should -Be 'Back'
    }

    It 'a plain line while unconfigured explains instead of sending' {
        Mock Read-WtSettings { $script:Unset }
        Mock Write-WtReplLine { $script:Printed += @($Text) }
        $script:Printed = @()
        New-WtLineQueue -Lines @('merhaba', '/quit')
        $null = Invoke-WtAssistantScreen -ReadLine $script:ReadLineSeam -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } -Send { param($S, $Settings, $Text) throw 'no send' } `
            -Wizard { $null } -Slash { param($C, $A, $S, $Settings) @{ Nav = 'Back'; Settings = $Settings; NewSession = $false } }
        $script:Printed | Should -Contain (Get-Translation 'AsReplNeedEndpoint')
    }

    It 'calls -Profile once with $false at entry and prints the built line only when the cache came back cold' {
        Mock Write-WtReplLine { $script:Printed += @([string]$Text) }
        $script:Printed = @()
        $script:ProfileForceSeen = @()
        New-WtLineQueue -Lines @('/quit')
        $null = Invoke-WtAssistantScreen -ReadLine $script:ReadLineSeam -Enter $script:Enter -Exit $script:Exit `
            -Profile { param($Force) $script:ProfileForceSeen += @($Force); @{ Json = '{"p":1}'; Cold = $true; BuiltAt = 'x' } } `
            -Send { param($S, $Settings, $Text) } -Slash { param($C, $A, $S, $Settings) @{ Nav = 'Back'; Settings = $Settings; NewSession = $false } }
        $script:ProfileForceSeen | Should -Be @($false)
        $built = @($script:Printed | Where-Object { $_.IndexOf(([string](Get-Translation 'AsProfileBuilt')).Split([char]' ')[0], [System.StringComparison]::Ordinal) -ge 0 })
        $built.Count | Should -BeGreaterThan 0
        ([string]$built[0]).StartsWith(' ', [System.StringComparison]::Ordinal) | Should -BeFalse
        ($script:Printed -join "`n") | Should -Match ([regex]::Escape((Get-Translation 'AsProfileBuilt') -f 7))

        $script:Printed = @()
        New-WtLineQueue -Lines @('/quit')
        $null = Invoke-WtAssistantScreen -ReadLine $script:ReadLineSeam -Enter $script:Enter -Exit $script:Exit `
            -Profile { param($Force) @{ Json = '{"p":1}'; Cold = $false; BuiltAt = 'x' } } `
            -Send { param($S, $Settings, $Text) } -Slash { param($C, $A, $S, $Settings) @{ Nav = 'Back'; Settings = $Settings; NewSession = $false } }
        ($script:Printed -join "`n") | Should -Not -Match ([regex]::Escape((Get-Translation 'AsProfileBuilt') -f 7))
    }

    It 'C1: /profil yenile through the REAL -Slash/-Profile defaults forces the rebuild (regression: the loop default used to drop -Force)' {
        Mock Get-WtAssistantMachineProfile { @{ Json = '{}'; Cold = $false; BuiltAt = '' } }
        New-WtLineQueue -Lines @('/profil yenile', '/cik')
        $null = Invoke-WtAssistantScreen -ReadLine $script:ReadLineSeam -Enter { } -Exit { } -Wizard { $null }
        Should -Invoke Get-WtAssistantMachineProfile -Times 1 -ParameterFilter { $Force }
        Should -Invoke Get-WtAssistantMachineProfile -Times 1 -ParameterFilter { -not $Force }
    }

    It 'prints the header on entry (clear + banner + welcome), and again on /new with the fresh session' {
        $script:Headers = @()
        New-WtLineQueue -Lines @('/new', '/quit')
        $null = Invoke-WtAssistantScreen -ReadLine $script:ReadLineSeam -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } -Send { param($S, $Settings, $Text) } `
            -Header { param($S, $Settings, $ResumedAt) $script:Headers += @(@{ Session = $S; ResumedAt = $ResumedAt }) } `
            -Slash { param($C, $A, $S, $Settings) $script:LastSession = $S; @{ Nav = $(if ($C -eq 'quit') { 'Back' } else { 'None' }); Settings = $Settings; NewSession = ($C -eq 'new') } }
        $script:Headers.Count | Should -Be 2
        $script:Headers[0].ResumedAt | Should -Be ''
        [object]::ReferenceEquals($script:Headers[1].Session, $script:LastSession) | Should -BeTrue
        [object]::ReferenceEquals($script:Headers[0].Session, $script:LastSession) | Should -BeFalse
    }

    It 'a slash handler that answers Exit leaves the whole app, not just the chat' {
        New-WtLineQueue -Lines @('/ayarlar')
        $r = Invoke-WtAssistantScreen -ReadLine $script:ReadLineSeam -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } -Send { param($S, $Settings, $Text) } `
            -Header { param($S, $Settings, $ResumedAt) } `
            -Slash { param($C, $A, $S, $Settings) @{ Nav = 'Exit'; Settings = $Settings; NewSession = $false } }
        $r.Nav | Should -Be 'Exit'
        $r.Target | Should -Be ''
        $r.HasMarks | Should -BeFalse
    }

    It 'a slash Notice is printed AFTER the header repaint, so a new session cannot erase it' {
        $script:Order = @()
        Mock Write-WtReplLine { $script:Order += @('line:' + [string]$Text) }
        New-WtLineQueue -Lines @('/unut', '/quit')
        $null = Invoke-WtAssistantScreen -ReadLine $script:ReadLineSeam -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } -Send { param($S, $Settings, $Text) } `
            -Header { param($S, $Settings, $ResumedAt) $script:Order += @('header') } `
            -Slash { param($C, $A, $S, $Settings) @{ Nav = $(if ($C -eq 'quit') { 'Back' } else { 'None' }); Settings = $Settings; NewSession = ($C -eq 'forget'); Notice = 'wiped 4'; NoticeFg = 'DarkYellow' } }
        $script:Order | Should -Contain 'line:wiped 4'
        $script:Order.IndexOf('line:wiped 4') | Should -BeGreaterThan ([array]::LastIndexOf([array]$script:Order, 'header'))
    }

    It 'hands status rows to the line reader: model, where, context; unconfigured says so' {
        $script:StatusSeen = @()
        $reader = { param($P, $History, $StatusRows) $script:StatusSeen += @(, $StatusRows); @{ Kind = 'Submit'; Text = '/quit' } }
        $null = Invoke-WtAssistantScreen -ReadLine $reader -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } -Send { param($S, $Settings, $Text) } -Header { param($S, $Settings, $R) } `
            -Slash { param($C, $A, $S, $Settings) @{ Nav = 'Back'; Settings = $Settings; NewSession = $false } }
        $text = (@($script:StatusSeen[0]) | ForEach-Object { (@($_) | ForEach-Object T) -join '' }) -join "`n"
        $text | Should -Match 'qwen3'
        $text | Should -Match ([regex]::Escape((Get-Translation 'AsLocalTag')))
        Mock Read-WtSettings { $script:Unset }
        $script:StatusSeen = @()
        $null = Invoke-WtAssistantScreen -ReadLine $reader -Enter $script:Enter -Exit $script:Exit -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } -Send { param($S, $Settings, $Text) } -Header { param($S, $Settings, $R) } -Wizard { $null } `
            -Slash { param($C, $A, $S, $Settings) @{ Nav = 'Back'; Settings = $Settings; NewSession = $false } }
        $text = (@($script:StatusSeen[0]) | ForEach-Object { (@($_) | ForEach-Object T) -join '' }) -join "`n"
        $text | Should -Match ([regex]::Escape((Get-Translation 'AsReplNeedEndpoint')))
    }

    It 'the default ReadLine seam commits a submitted line through -EchoAsUser (source-shape guard)' {
        $src = (Get-Command Invoke-WtAssistantScreen).Definition
        $src | Should -Match ([regex]::Escape("Read-WtReplLine -Prompt `$P -History `$History -StatusRows `$StatusRows -Placeholder (Get-Translation 'AsReplPlaceholder') -EchoAsUser -AllowResize -InitialText `$Draft"))
    }

    It 'a Resize from the reader repaints the page and reprints the transcript at the new width' {
        $script:Order = New-Object System.Collections.Generic.List[string]
        Mock Write-WtReplTranscriptTail { param($Session, $Count, $Width, $Write) $script:Order.Add('tail:' + $Count + ':' + $Width) }
        Mock Get-WtConsoleSize { @{ Width = 132; Height = 40 } }
        $script:Turn = 0
        $script:Drafts = @()
        $reader = { param($P, $History, $StatusRows, $Draft)
            $script:Turn++
            $script:Drafts += @([string]$Draft)
            if ($script:Turn -eq 1) { return @{ Kind = 'Resize'; Text = 'yarim satir' } }
            return @{ Kind = 'Submit'; Text = '/quit' }
        }
        $r = Invoke-WtAssistantScreen -ReadLine $reader -Enter $script:Enter -Exit $script:Exit `
            -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } -Send { param($S, $Settings, $Text) } `
            -Header { param($S, $Settings, $ResumedAt) $script:Order.Add('page') } `
            -Slash { param($C, $A, $S, $Settings) $script:LastSession = $S; @{ Nav = 'Back'; Settings = $Settings; NewSession = $false } }
        $r.Nav | Should -Be 'Back'
        @($script:Order) | Should -Be @('page', 'page', 'tail:400:132')
        $script:LastSession.History.Count | Should -Be 1
        $script:Drafts | Should -Be @('', 'yarim satir')
    }

    It 'the welcome stays at the top of the page: every repaint prints it above the transcript, empty or not' {
        $script:Order = New-Object System.Collections.Generic.List[string]
        Mock Write-WtReplPage { $script:Order.Add('page') }
        Mock Write-WtReplWelcome { $script:Order.Add('welcome') }
        Mock Write-WtReplTranscriptTail { param($Session, $Count, $Width, $Write) $script:Order.Add('tail') }
        Mock Get-WtConsoleSize { @{ Width = 100; Height = 40 } }
        $script:WtAssistantChat = New-WtReplSession
        $script:WtAssistantChat.Entries.Add(@{ Kind = 'User'; Text = 'soru' })
        $script:Turn = 0
        $reader = { param($P, $History, $StatusRows, $Draft)
            $script:Turn++
            if ($script:Turn -eq 1) { return @{ Kind = 'Resize'; Text = '' } }
            return @{ Kind = 'Submit'; Text = '/quit' }
        }
        $r = Invoke-WtAssistantScreen -ReadLine $reader -Enter $script:Enter -Exit $script:Exit `
            -Profile { param($Force) @{ Json = ''; Cold = $false; BuiltAt = '' } } -Send { param($S, $Settings, $Text) } `
            -Slash { param($C, $A, $S, $Settings) @{ Nav = 'Back'; Settings = $Settings; NewSession = $false } }
        $r.Nav | Should -Be 'Back'
        @($script:Order) | Should -Be @('page', 'welcome', 'tail', 'page', 'welcome', 'tail')
    }
}


Describe 'the REPL status in ChatGPT mode' {
    It 'shows the account and hides the endpoint and key rows' {
        $session = New-WtReplSession
        $s = [PSCustomObject]@{
            AssistantEndpoint = 'http://127.0.0.1:11434/v1'; AssistantModel = 'gpt-5.6-terra'; AssistantApiKey = 'BLOB'
            AssistantTemperature = ''; AssistantMaxTokens = ''; AssistantNumCtx = ''; AssistantAuthMode = 'ChatGPT'
        }
        $lines = @(Get-WtReplStatusLines -Settings $s -Session $session -Auth @{ Email = 'a@b.c'; PlanType = 'plus' })
        ($lines -join "`n") | Should -Match 'a@b\.c'
        ($lines -join "`n") | Should -Not -Match '11434'
        ($lines -join "`n") | Should -Not -Match '\*\*\*\*'
    }

    It 'still shows the endpoint and key when no mode is set' {
        $session = New-WtReplSession
        $s = [PSCustomObject]@{
            AssistantEndpoint = 'http://127.0.0.1:11434/v1'; AssistantModel = 'm'; AssistantApiKey = 'BLOB'
            AssistantTemperature = ''; AssistantMaxTokens = ''; AssistantNumCtx = ''; AssistantAuthMode = ''
        }
        $lines = @(Get-WtReplStatusLines -Settings $s -Session $session)
        ($lines -join "`n") | Should -Match '11434'
        ($lines -join "`n") | Should -Match '\*\*\*\*'
    }
}

Describe 'the REPL where-tag' {
    It 'says ChatGPT in ChatGPT mode and keeps local/remote otherwise' {
        Get-WtAssistantWhereTag -Settings ([PSCustomObject]@{ AssistantEndpoint = 'http://127.0.0.1:11434/v1'; AssistantAuthMode = 'ChatGPT' }) |
            Should -Be (Get-Translation 'AsChatGptTag')
        Get-WtAssistantWhereTag -Settings ([PSCustomObject]@{ AssistantEndpoint = 'http://127.0.0.1:11434/v1'; AssistantAuthMode = '' }) |
            Should -Be (Get-Translation 'AsLocalTag')
        Get-WtAssistantWhereTag -Settings ([PSCustomObject]@{ AssistantEndpoint = 'https://api.openai.com/v1'; AssistantAuthMode = '' }) |
            Should -Be (Get-Translation 'AsRemoteTag')
    }
}
