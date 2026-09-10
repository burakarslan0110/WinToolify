BeforeAll {
    . (Join-Path (Join-Path $PSScriptRoot '..') 'dist/WinToolify.ps1')
}

Describe 'Settings persistence' {
    It 'round-trips the language' {
        $root = Join-Path $TestDrive 'settings-root'
        Save-WtSettings -Settings ([PSCustomObject]@{ Language = 'TR' }) -TestRootOverride $root
        (Read-WtSettings -TestRootOverride $root).Language | Should -Be 'TR'
    }
    It 'missing file yields null language' {
        $root = Join-Path $TestDrive 'settings-empty'
        (Read-WtSettings -TestRootOverride $root).Language | Should -BeNullOrEmpty
    }
    It 'corrupt file yields null language instead of throwing' {
        $root = Join-Path $TestDrive 'settings-bad'
        $dir = Split-Path -Parent (Get-WtSettingsFilePath -TestRootOverride $root)
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -Path (Get-WtSettingsFilePath -TestRootOverride $root) -Value 'not-json{{{' -Encoding UTF8
        (Read-WtSettings -TestRootOverride $root).Language | Should -BeNullOrEmpty
    }
    It 'rejects an unknown language value on read' {
        $root = Join-Path $TestDrive 'settings-odd'
        Save-WtSettings -Settings ([PSCustomObject]@{ Language = 'XX' }) -TestRootOverride $root
        (Read-WtSettings -TestRootOverride $root).Language | Should -BeNullOrEmpty
    }
    It 'preserves keys written by other builds when saving the language' {
        $root = Join-Path $TestDrive 'settings-merge'
        $file = Get-WtSettingsFilePath -TestRootOverride $root
        Set-Content -Path $file -Value '{ "Borders": "Auto", "Version": "2.0", "Language": "TR" }' -Encoding UTF8
        Save-WtSettings -Settings ([PSCustomObject]@{ Language = 'EN' }) -TestRootOverride $root
        $raw = Get-Content -Raw $file | ConvertFrom-Json
        $raw.Language | Should -Be 'EN'
        $raw.Borders | Should -Be 'Auto'
        $raw.Version | Should -Be '2.0'
    }
    It 'stores settings.json under the User data root' {
        $root = Join-Path $TestDrive 'settings-path'
        (Get-WtSettingsFilePath -TestRootOverride $root) | Should -Be (Join-Path (Join-Path $root 'User') 'settings.json')
    }
}

Describe 'Embedded UI strings moved to the translation table' {
    BeforeAll { $script:src = Get-Content -Raw (Join-Path (Join-Path $PSScriptRoot '..') 'dist/WinToolify.ps1') }

    It 'defines every moved key in both languages' {
        $keys = @(
            'SelectorAdvancedHeader', 'SelectorAdvancedPrompt',
            'RpCreating', 'RpCreated', 'RpProtectionDisabled',
            'RpThrottled', 'RpCreateFailed', 'RpManualDescription',
            'UndoMenuEmpty', 'UndoFooter', 'UndoConfirmFooter', 'UndoMenuResultsHeader',
            'UndoResultRestored', 'UndoResultFailed', 'UndoResultNotRestorable',
            'StateInstalled', 'StateRemoved', 'StateUnknown'
        )
        foreach ($key in $keys) {
            $script:Translations['EN'].ContainsKey($key) | Should -BeTrue -Because "EN needs '$key'"
            $script:Translations['TR'].ContainsKey($key) | Should -BeTrue -Because "TR needs '$key'"
        }
    }
    It 'drops the keys the per-action restore-point prompts used to need' {
        foreach ($key in 'RpDeclinedRestate', 'RpProtectionContinue', 'RpThrottledContinue', 'RpFailedContinue',
                         'RpCreateIntro', 'RpCreateOnce', 'RpCreatePrompt', 'RpSessionDescription') {
            $script:Translations['EN'].ContainsKey($key) | Should -BeFalse -Because "'$key' belonged to a prompt that no longer exists"
            $script:Translations['TR'].ContainsKey($key) | Should -BeFalse -Because "'$key' belonged to a prompt that no longer exists"
        }
    }
    It 'leaves the typed token and the risk tag to placeholders in both languages' {
        foreach ($lang in 'EN', 'TR') {
            $script:Translations[$lang]['SelectorAdvancedPrompt'] | Should -Match '\{0\}'
            $script:Translations[$lang]['SelectorAdvancedPrompt'] | Should -Match '\{1\}'
        }
    }
    It 'drops the main-menu restore-point footnote - the description band says it now' {
        foreach ($lang in 'EN', 'TR') {
            $script:Translations[$lang].ContainsKey('MainRestoreHint') | Should -BeFalse
            $script:Translations[$lang]['MainDescCreateRestorePoint'] | Should -Not -BeNullOrEmpty
            $script:Translations[$lang]['MainDescCreateRestorePoint'] | Should -Not -Match '\{0\}'
            $script:Translations[$lang]['MainDescCreateRestorePoint'] | Should -Not -Match '\d'
        }
    }
    It 'EN values keep the original literals verbatim' {
        $script:Translations['EN']['SelectorAdvancedHeader'] | Should -Be 'The following {0} items are selected:'
        $script:Translations['EN']['UndoMenuEmpty'] | Should -Be 'No recorded changes yet - nothing to undo.'
        $script:Translations['EN']['StateInstalled'] | Should -Be 'Installed'
    }
    It 'no longer embeds the moved literals at their call sites' {
        $src | Should -Not -Match 'Read-Host "Create a System Restore Point before'
        $src | Should -Not -Match 'Write-Host "`nThe following ADVANCED items are selected:"'
        $src | Should -Not -Match "Write-Host 'No recorded changes yet"
        $src | Should -Not -Match 'Read-Host "`nSelect an entry to restore"'
        $src | Should -Not -Match "StateLabel = if \(\`$state\.Installed\) \{ 'Installed' \}"
    }
}

Describe 'Assistant settings storage' {
    It 'round-trips endpoint and model through settings.json' {
        $root = Join-Path $TestDrive 'as-roundtrip'
        Save-WtSettings -Settings ([PSCustomObject]@{ AssistantEndpoint = 'http://localhost:1234/v1'; AssistantModel = 'qwen' }) -TestRootOverride $root
        $s = Read-WtSettings -TestRootOverride $root
        $s.AssistantEndpoint | Should -Be 'http://localhost:1234/v1'
        $s.AssistantModel | Should -Be 'qwen'
        $s.AssistantApiKey | Should -Be ''
    }

    It 'reads empty strings when nothing was ever saved' {
        $s = Read-WtSettings -TestRootOverride (Join-Path $TestDrive 'as-fresh')
        $s.AssistantEndpoint | Should -Be ''
        $s.AssistantModel | Should -Be ''
        $s.AssistantApiKey | Should -Be ''
    }

    It 'round-trips the optional sampling fields and leaves them empty when absent' {
        $root = Join-Path $TestDrive 'sampling'
        (Read-WtSettings -TestRootOverride $root).AssistantTemperature | Should -Be ''
        Save-WtSettings -Settings ([PSCustomObject]@{ AssistantTemperature = '0.2'; AssistantMaxTokens = '4096' }) -TestRootOverride $root
        $s = Read-WtSettings -TestRootOverride $root
        $s.AssistantTemperature | Should -Be '0.2'
        $s.AssistantMaxTokens | Should -Be '4096'
        Save-WtSettings -Settings ([PSCustomObject]@{ AssistantModel = 'x' }) -TestRootOverride $root
        (Read-WtSettings -TestRootOverride $root).AssistantTemperature | Should -Be '0.2'
    }

    It 'keeps Language and foreign keys when only assistant fields are saved' {
        $root = Join-Path $TestDrive 'as-merge'
        Save-WtSettings -Settings ([PSCustomObject]@{ Language = 'TR' }) -TestRootOverride $root
        $file = Get-WtSettingsFilePath -TestRootOverride $root
        $raw = Read-WtJson -Path $file
        $raw | Add-Member -NotePropertyName 'Borders' -NotePropertyValue 'double' -Force
        Write-WtJson -Path $file -InputObject $raw
        Save-WtSettings -Settings ([PSCustomObject]@{ AssistantEndpoint = 'https://api.openai.com/v1' }) -TestRootOverride $root
        $after = Read-WtJson -Path $file
        $after.Language | Should -Be 'TR'
        $after.Borders | Should -Be 'double'
        $after.AssistantEndpoint | Should -Be 'https://api.openai.com/v1'
    }

    It 'protects and unprotects a secret; empty stays empty' {
        $blob = Protect-WtAssistantSecret -PlainText 'sk-test-123'
        $blob | Should -Not -Be 'sk-test-123'
        $blob.Length | Should -BeGreaterThan 20
        Unprotect-WtAssistantSecret -Blob $blob | Should -Be 'sk-test-123'
        Protect-WtAssistantSecret -PlainText '' | Should -Be ''
        Unprotect-WtAssistantSecret -Blob '' | Should -Be ''
    }

    It 'returns empty for a corrupt blob instead of throwing' {
        Unprotect-WtAssistantSecret -Blob 'not-a-dpapi-blob' | Should -Be ''
    }

    It 'round-trips AssistantNumCtx and leaves it empty when absent' {
        $root = Join-Path $TestDrive 'numctx'
        (Read-WtSettings -TestRootOverride $root).AssistantNumCtx | Should -Be ''
        Save-WtSettings -Settings ([PSCustomObject]@{ AssistantNumCtx = '8192' }) -TestRootOverride $root
        (Read-WtSettings -TestRootOverride $root).AssistantNumCtx | Should -Be '8192'
        Save-WtSettings -Settings ([PSCustomObject]@{ AssistantModel = 'x' }) -TestRootOverride $root
        (Read-WtSettings -TestRootOverride $root).AssistantNumCtx | Should -Be '8192'
        Save-WtSettings -Settings ([PSCustomObject]@{ AssistantNumCtx = '' }) -TestRootOverride $root
        (Read-WtSettings -TestRootOverride $root).AssistantNumCtx | Should -Be ''
    }
}
