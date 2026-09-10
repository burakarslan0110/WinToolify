#Requires -Modules Pester

<#
.SYNOPSIS
    EN/TR translation dictionary parity: the automated check that every
    UI string resolves in both languages. The menu functions themselves
    are Write-Host/Read-Host driven and not unit-testable.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'EN/TR translation parity' {
    It 'has identical key sets in EN and TR' {
        $enKeys = @($script:Translations['EN'].Keys | Sort-Object)
        $trKeys = @($script:Translations['TR'].Keys | Sort-Object)
        $enKeys | Should -Be $trKeys
    }

    It 'has no empty or null value in EN' {
        foreach ($key in $script:Translations['EN'].Keys) {
            $script:Translations['EN'][$key] | Should -Not -BeNullOrEmpty -Because "EN key '$key' must not be blank"
        }
    }

    It 'has no empty or null value in TR' {
        foreach ($key in $script:Translations['TR'].Keys) {
            $script:Translations['TR'][$key] | Should -Not -BeNullOrEmpty -Because "TR key '$key' must not be blank"
        }
    }

    It 'resolves every Telemetry & Data Collection menu string in both languages' {
        foreach ($key in @('Telemetry', 'ActivityAndAdvertising', 'SearchAndSuggestions')) {
            $script:Translations['EN'].ContainsKey($key) | Should -BeTrue -Because "EN needs '$key'"
            $script:Translations['TR'].ContainsKey($key) | Should -BeTrue -Because "TR needs '$key'"
            $script:Translations['EN'][$key] | Should -Not -Be $script:Translations['TR'][$key] -Because "'$key' must actually be translated, not copied"
        }
    }

    It 'holds only ASCII, so the file parses the same under any codepage' {
        $offenders = New-Object 'System.Collections.Generic.List[string]'
        foreach ($lang in 'EN', 'TR') {
            foreach ($key in $script:Translations[$lang].Keys) {
                $value = [string]$script:Translations[$lang][$key]
                foreach ($ch in $value.ToCharArray()) {
                    if ([int]$ch -gt 127) { $offenders.Add("$lang '$key' -> U+$('{0:X4}' -f [int]$ch)"); break }
                }
            }
        }
        ($offenders -join '; ') | Should -BeNullOrEmpty -Because 'every translation must be ASCII-folded'
    }

    It 'has dropped the welcome box keys in both languages' {
        foreach ($lang in @('TR', 'EN')) {
            foreach ($key in @('AsWelcomeModel', 'AsWelcomeMemory', 'AsWelcomeModelUnset', 'AsWelcomeResumed', 'AsWelcomeProfile', 'AsWelcomeHints')) {
                $script:Translations[$lang].ContainsKey($key) | Should -BeFalse -Because "$key is gone with the welcome box"
            }
            foreach ($key in @('AsWelcomeMessages', 'AsWelcomeNotes', 'AsWelcomePerms')) {
                $script:Translations[$lang].ContainsKey($key) | Should -BeFalse -Because "$key went with the welcome box too"
            }
        }
    }
}

Describe 'Localized answers' {
    AfterEach { $script:Language = 'EN' }

    It 'gives each language its own yes/no letters' {
        $script:Translations['EN']['YesLetter'] | Should -Be 'Y'
        $script:Translations['EN']['NoLetter'] | Should -Be 'N'
        $script:Translations['TR']['YesLetter'] | Should -Be 'E'
        $script:Translations['TR']['NoLetter'] | Should -Be 'H'
    }

    It 'accepts the active language letter in either case and rejects the other language' {
        $script:Language = 'TR'
        foreach ($yes in 'E', 'e', 'evet') { Test-WtAffirmativeAnswer -Answer $yes | Should -BeTrue -Because "TR '$yes'" }
        foreach ($no in 'H', 'h', 'hayir') { Test-WtAffirmativeAnswer -Answer $no | Should -BeFalse -Because "TR '$no'" }
        Test-WtAffirmativeAnswer -Answer 'y' | Should -BeFalse
        $script:Language = 'EN'
        Test-WtAffirmativeAnswer -Answer 'y' | Should -BeTrue
        Test-WtAffirmativeAnswer -Answer 'N' | Should -BeFalse
        Test-WtAffirmativeAnswer -Answer 'e' | Should -BeFalse
    }

    It 'treats empty, whitespace and null as no (every prompt defaults to no)' {
        foreach ($blank in '', '   ', $null) {
            Test-WtAffirmativeAnswer -Answer $blank | Should -BeFalse
        }
    }

    It 'spells the answers out in navigation-guide style' {
        $script:Language = 'EN'
        Format-WtYesNoHint | Should -Be 'Y: Yes - N: No'
        $script:Language = 'TR'
        Format-WtYesNoHint | Should -Be 'E: Evet - H: Hayir'
    }

    It 'the hint names the same letters the code actually accepts' {
        foreach ($lang in 'EN', 'TR') {
            $script:Language = $lang
            $hint = Format-WtYesNoHint
            $yes = ($hint -split ':')[0]
            Test-WtAffirmativeAnswer -Answer $yes | Should -BeTrue -Because "$lang yes letter '$yes'"
            $no = (($hint -split ' - ')[1] -split ':')[0]
            Test-WtAffirmativeAnswer -Answer $no | Should -BeFalse -Because "$lang no letter '$no'"
        }
    }

    It 'a prompt carries the question and then the hint' {
        $script:Language = 'TR'
        Get-WtYesNoPrompt -Text 'Devam edilsin mi?' | Should -Be 'Devam edilsin mi? E: Evet - H: Hayir'
    }

    It 'no prompt string bakes in its own yes/no hint any more' {
        $offenders = New-Object 'System.Collections.Generic.List[string]'
        foreach ($lang in 'EN', 'TR') {
            foreach ($key in $script:Translations[$lang].Keys) {
                if ([string]$script:Translations[$lang][$key] -match '\([YyEe]/[NnHh]\)') { $offenders.Add("$lang '$key'") }
            }
        }
        ($offenders -join '; ') | Should -BeNullOrEmpty -Because 'the hint comes from Format-WtYesNoHint'
    }

    It 'prompts with the localized word' {
        $script:Language = 'TR'
        (Get-WtTypedWord -Kind 'Yes') | Should -Be 'EVET'
        (Get-WtTypedWord -Kind 'Confirm') | Should -Be 'ONAYLA'
        $script:Language = 'EN'
        (Get-WtTypedWord -Kind 'Yes') | Should -Be 'YES'
        (Get-WtTypedWord -Kind 'Confirm') | Should -Be 'CONFIRM'
    }

    It 'accepts the typed word in any case, in the active language or in English' {
        $script:Language = 'TR'
        foreach ($ok in 'EVET', 'evet', 'Evet', 'YES', 'yes') { Test-WtTypedConfirmation -Answer $ok -Kind 'Yes' | Should -BeTrue -Because "TR '$ok'" }
        foreach ($ok in 'ONAYLA', 'onayla', 'Onayla', 'CONFIRM', 'confirm') { Test-WtTypedConfirmation -Answer $ok -Kind 'Confirm' | Should -BeTrue -Because "TR '$ok'" }
        $script:Language = 'EN'
        foreach ($ok in 'YES', 'yes', 'Yes') { Test-WtTypedConfirmation -Answer $ok -Kind 'Yes' | Should -BeTrue -Because "EN '$ok'" }
        foreach ($ok in 'CONFIRM', 'confirm', 'Confirm') { Test-WtTypedConfirmation -Answer $ok -Kind 'Confirm' | Should -BeTrue -Because "EN '$ok'" }
    }

    It 'still refuses anything that is not the word' {
        foreach ($lang in 'EN', 'TR') {
            $script:Language = $lang
            foreach ($no in '', '   ', 'y', 'e', 'onay', 'confir', 'no', 'hayir', $null) {
                Test-WtTypedConfirmation -Answer $no -Kind 'Confirm' | Should -BeFalse -Because "$lang '$no'"
            }
        }
    }

    It 'matches Ordinal-IgnoreCase, so the Turkish dotted-I cannot break "confirm"' {
        $old = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            $script:Language = 'TR'
            Test-WtTypedConfirmation -Answer 'confirm' -Kind 'Confirm' | Should -BeTrue
            Test-WtTypedConfirmation -Answer 'CONFIRM' -Kind 'Confirm' | Should -BeTrue
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $old }
    }

    It 'names the typed word and the risk tag through placeholders, never in the sentence' {
        foreach ($lang in 'EN', 'TR') {
            foreach ($key in 'TypeYesToConfirm', 'ProfileTypeConfirm', 'SelectorAdvancedPrompt', 'SelectorAdvancedHeader', 'ProfileAdvancedWarning') {
                $text = [string]$script:Translations[$lang][$key]
                $text | Should -Not -CMatch 'YES|CONFIRM|ADVANCED' -Because "$lang '$key' must use {0}, not the English word"
                $text | Should -Match '\{0\}' -Because "$lang '$key'"
            }
        }
    }

    It 'the typed-YES gate takes the word in either language and any case' {
        $script:Language = 'TR'
        foreach ($ok in 'EVET', 'evet', 'YES') {
            Confirm-WtDestructiveAction -Consequence 'boom' -ReadAnswer { $ok }.GetNewClosure() | Should -BeTrue -Because "TR '$ok'"
        }
        Confirm-WtDestructiveAction -Consequence 'boom' -ReadAnswer { param($Lines, $Prompt) 'hayir' } | Should -BeFalse
        $script:Language = 'EN'
        Confirm-WtDestructiveAction -Consequence 'boom' -ReadAnswer { param($Lines, $Prompt) 'yes' } | Should -BeTrue
        Confirm-WtDestructiveAction -Consequence 'boom' -ReadAnswer { param($Lines, $Prompt) 'nope' } | Should -BeFalse
    }
}

Describe 'A gate accepts either language, whatever the screen is set to' {
    It 'lists every language word plus the English fallback, without duplicates' {
        foreach ($kind in 'Yes', 'Confirm') {
            $words = @(Get-WtAcceptedTypedWords -Kind $kind)
            $words | Should -Contain $(if ($kind -eq 'Yes') { 'YES' } else { 'CONFIRM' })
            $words | Should -Contain ([string]$script:Translations['TR']['Typed' + $kind + 'Word'])
            $words | Should -Contain ([string]$script:Translations['EN']['Typed' + $kind + 'Word'])
            @($words | Group-Object | Where-Object { $_.Count -gt 1 }).Count | Should -Be 0
        }
    }
    It 'the Turkish word passes on an English screen and vice versa, in any case' {
        foreach ($lang in 'EN', 'TR') {
            $script:Language = $lang
            try {
                foreach ($w in 'ONAYLA', 'onayla', 'oNaYlA', 'CONFIRM', 'confirm', ' confirm ') {
                    Test-WtTypedConfirmation -Answer $w -Kind 'Confirm' | Should -BeTrue -Because "$lang '$w'"
                }
                foreach ($w in 'EVET', 'evet', 'YES', 'yes', ' Evet ') {
                    Test-WtTypedConfirmation -Answer $w -Kind 'Yes' | Should -BeTrue -Because "$lang '$w'"
                }
                foreach ($w in '', ' ', 'onay', 'confir', 'ok', 'tamam', 'y', 'e') {
                    Test-WtTypedConfirmation -Answer $w -Kind 'Confirm' | Should -BeFalse -Because "$lang '$w'"
                }
            }
            finally { $script:Language = 'EN' }
        }
    }
    It 'a Yes word never opens a Confirm gate and vice versa' {
        Test-WtTypedConfirmation -Answer 'EVET' -Kind 'Confirm' | Should -BeFalse
        Test-WtTypedConfirmation -Answer 'YES' -Kind 'Confirm' | Should -BeFalse
        Test-WtTypedConfirmation -Answer 'ONAYLA' -Kind 'Yes' | Should -BeFalse
        Test-WtTypedConfirmation -Answer 'CONFIRM' -Kind 'Yes' | Should -BeFalse
    }
    It 'the hint names the English word as a second option only on a non-English screen' {
        $script:Language = 'TR'
        try {
            Get-WtGateWordHint -Kind 'Confirm' | Should -Be ((Get-Translation 'GateWordHint') -f 'ONAYLA', 'CONFIRM')
            Get-WtGateWordHint -Kind 'Yes' | Should -Be ((Get-Translation 'GateWordHint') -f 'EVET', 'YES')
        }
        finally { $script:Language = 'EN' }
        Get-WtGateWordHint -Kind 'Confirm' | Should -Be ((Get-Translation 'GateWordHintOne') -f 'CONFIRM')
    }
    It 'the new gate strings exist in both languages and keep their placeholders' {
        foreach ($lang in 'EN', 'TR') {
            foreach ($key in 'GateRefusedTyped', 'GateRefusedMechanism', 'GateWordHint', 'GateWordHintOne', 'ApplyNothingLeft') {
                $script:Translations[$lang][$key] | Should -Not -BeNullOrEmpty -Because "$lang needs $key"
            }
            $script:Translations[$lang]['GateRefusedTyped'] | Should -Match '\{0\}'
            $script:Translations[$lang]['GateWordHint'] | Should -Match '\{0\}'
            $script:Translations[$lang]['GateWordHint'] | Should -Match '\{1\}'
            $script:Translations[$lang]['GateWordHintOne'] | Should -Match '\{0\}'
            $script:Translations[$lang]['GateWordHintOne'] | Should -Not -Match '\{1\}'
        }
    }
}