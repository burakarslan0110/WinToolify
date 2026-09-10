#Requires -Modules Pester

<#
.SYNOPSIS
    The "Power and session" group of Basic Tools > Actions: a
    ShutdownTimer row that arms and cancels a timer, plus two Power rows
    that restart into advanced startup (WinRE) and UEFI firmware
    settings. Every Windows edge is an injected scriptblock.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Power and session translations' {
    BeforeAll {
        $script:PowerKeys = @(
            'ShutdownTimer', 'RestartToAdvancedStartup', 'RestartToFirmwareSettings',
            'ConsequenceRestartToAdvancedStartup', 'ConsequenceRestartToFirmwareSettings',
            'ShutdownTimerPrompt', 'ShutdownTimerHint', 'ShutdownTimerInvalid',
            'ShutdownTimerCancelled', 'ShutdownTimerNonePending', 'ShutdownTimerCancelFailed',
            'ShutdownTimerCapped', 'ShutdownTimerScheduled', 'ShutdownTimerScheduleFailed',
            'ShutdownTimerCancelHint',
            'WinReChecking', 'WinReUnavailable', 'WinReUnavailableHint', 'RestartingToAdvancedStartup',
            'FirmwareNotUefi', 'FirmwareNotUefiHint', 'RestartingToFirmwareSettings',
            'PowerCommandFailed'
        )
    }

    It 'defines every new key in both dictionaries' {
        foreach ($key in $PowerKeys) {
            $script:Translations['EN'][$key] | Should -Not -BeNullOrEmpty -Because "EN needs '$key'"
            $script:Translations['TR'][$key] | Should -Not -BeNullOrEmpty -Because "TR needs '$key'"
        }
    }

    It 'keeps every new value ASCII, so the file parses the same under any codepage' {
        foreach ($lang in 'EN', 'TR') {
            foreach ($key in $PowerKeys) {
                foreach ($ch in ([string]$script:Translations[$lang][$key]).ToCharArray()) {
                    [int]$ch | Should -BeLessOrEqual 127 -Because "$lang '$key' must be ASCII-folded"
                }
            }
        }
    }

    It 'keeps the three row labels under 46 characters so the panel never cuts them' {
        foreach ($lang in 'EN', 'TR') {
            foreach ($key in 'ShutdownTimer', 'RestartToAdvancedStartup', 'RestartToFirmwareSettings') {
                ([string]$script:Translations[$lang][$key]).Length | Should -BeLessOrEqual 45 -Because "$lang '$key'"
            }
        }
    }

    It 'actually translates the labels instead of copying English into TR' {
        foreach ($key in 'ShutdownTimer', 'RestartToAdvancedStartup', 'RestartToFirmwareSettings') {
            $script:Translations['EN'][$key] | Should -Not -Be $script:Translations['TR'][$key] -Because "'$key'"
        }
    }

    It 'keeps the placeholders the formatted lines rely on' {
        foreach ($lang in 'EN', 'TR') {
            $script:Translations[$lang]['ShutdownTimerScheduled'] | Should -Match '\{0\}'
            $script:Translations[$lang]['ShutdownTimerScheduled'] | Should -Match '\{1\}'
            $script:Translations[$lang]['ShutdownTimerCancelFailed'] | Should -Match '\{0\}'
            $script:Translations[$lang]['ShutdownTimerScheduleFailed'] | Should -Match '\{0\}'
            $script:Translations[$lang]['PowerCommandFailed'] | Should -Match '\{0\}'
        }
    }
}

Describe 'Get-WtShutdownTimerPlan (PURE: what the panel answer means)' {
    BeforeAll { $script:PlanNow = [datetime]'2026-08-23T10:00:00' }

    It 'treats empty, whitespace, null and zero as "cancel the pending timer"' {
        foreach ($answer in '', '   ', $null, '0', '00', ' 0 ') {
            (Get-WtShutdownTimerPlan -Answer $answer -Now $PlanNow).Mode | Should -Be 'Cancel' -Because "'$answer'"
        }
    }

    It 'turns a whole number of minutes into seconds and a wall-clock time' {
        $plan = Get-WtShutdownTimerPlan -Answer '10' -Now $PlanNow
        $plan.Mode | Should -Be 'Schedule'
        $plan.Minutes | Should -Be 10
        $plan.Seconds | Should -Be 600
        $plan.Capped | Should -BeFalse
        $plan.At | Should -Be ([datetime]'2026-08-23T10:10:00')
    }

    It 'accepts exactly the two-day ceiling without capping it' {
        $plan = Get-WtShutdownTimerPlan -Answer '2880' -Now $PlanNow
        $plan.Minutes | Should -Be 2880
        $plan.Seconds | Should -Be 172800
        $plan.Capped | Should -BeFalse
    }

    It 'clamps anything above two days and flags the clamp instead of applying it silently' {
        foreach ($answer in '2881', '100000', '99999999999999999999999') {
            $plan = Get-WtShutdownTimerPlan -Answer $answer -Now $PlanNow
            $plan.Mode | Should -Be 'Schedule' -Because "'$answer'"
            $plan.Minutes | Should -Be 2880 -Because "'$answer'"
            $plan.Capped | Should -BeTrue -Because "'$answer'"
        }
    }

    It 'refuses everything that is not digits - this is what keeps user text off a command line' {
        foreach ($answer in 'abc', '10 dakika', '-5', '5.5', '1e3', '12a', '/a', '10;shutdown /s', '+5') {
            (Get-WtShutdownTimerPlan -Answer $answer -Now $PlanNow).Mode | Should -Be 'Invalid' -Because "'$answer'"
        }
    }

    It 'reads the same digits under tr-TR, where a culture-sensitive match is a known foot-gun' {
        $old = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            (Get-WtShutdownTimerPlan -Answer '15' -Now $PlanNow).Minutes | Should -Be 15
            (Get-WtShutdownTimerPlan -Answer 'I' -Now $PlanNow).Mode | Should -Be 'Invalid'
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $old }
    }
}

Describe 'Get-WtShutdownCancelLines (PURE: what "shutdown /a" answered)' {
    BeforeAll { $script:SavedLangCancel = $script:Language }
    AfterAll { $script:Language = $script:SavedLangCancel }

    It 'says the timer was cancelled on exit code 0' {
        $script:Language = 'EN'
        @(Get-WtShutdownCancelLines -ExitCode 0) | Should -Be @($script:Translations['EN']['ShutdownTimerCancelled'])
    }

    It 'translates exit code 1116 into "there was nothing pending" instead of printing the raw error' {
        foreach ($lang in 'EN', 'TR') {
            $script:Language = $lang
            $rows = @(Get-WtShutdownCancelLines -ExitCode 1116)
            $rows | Should -Be @($script:Translations[$lang]['ShutdownTimerNonePending'])
            ($rows -join ' ') | Should -Not -Match '1116'
            ($rows -join ' ') | Should -Not -Match 'shutdown was in progress'
        }
    }

    It 'reports any other exit code with the number, so a real failure is not hidden' {
        $script:Language = 'EN'
        @(Get-WtShutdownCancelLines -ExitCode 5) | Should -Be @(($script:Translations['EN']['ShutdownTimerCancelFailed'] -f 5))
    }
}

Describe 'Get-WtShutdownScheduleLines (PURE: what "shutdown /s /t" answered)' {
    BeforeAll {
        $script:SavedLangSchedule = $script:Language
        $script:ArmedPlan = Get-WtShutdownTimerPlan -Answer '30' -Now ([datetime]'2026-08-23T10:00:00')
        $script:CappedPlan = Get-WtShutdownTimerPlan -Answer '5000' -Now ([datetime]'2026-08-23T10:00:00')
    }
    AfterAll { $script:Language = $script:SavedLangSchedule }

    It 'echoes the minutes and the resulting wall-clock time in a culture-independent format' {
        $script:Language = 'EN'
        $rows = @(Get-WtShutdownScheduleLines -Plan $ArmedPlan -ExitCode 0)
        $rows[0] | Should -Be ($script:Translations['EN']['ShutdownTimerScheduled'] -f 30, '2026-08-23 10:30')
        $rows[1] | Should -Be $script:Translations['EN']['ShutdownTimerCancelHint']
    }

    It 'keeps the same wall-clock text under tr-TR' {
        $old = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            @(Get-WtShutdownScheduleLines -Plan $ArmedPlan -ExitCode 0)[0] | Should -Match '2026-08-23 10:30'
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $old }
    }

    It 'announces the two-day clamp before the confirmation line' {
        $script:Language = 'EN'
        $rows = @(Get-WtShutdownScheduleLines -Plan $CappedPlan -ExitCode 0)
        $rows[0] | Should -Be $script:Translations['EN']['ShutdownTimerCapped']
        $rows[1] | Should -Be ($script:Translations['EN']['ShutdownTimerScheduled'] -f 2880, '2026-08-25 10:00')
    }

    It 'never claims a timer was armed when shutdown.exe returned a failure' {
        $script:Language = 'EN'
        $rows = @(Get-WtShutdownScheduleLines -Plan $ArmedPlan -ExitCode 1)
        $rows | Should -Be @(($script:Translations['EN']['ShutdownTimerScheduleFailed'] -f 1))
    }
}

Describe 'Invoke-WtShutdownCommand' {
    It 'builds the command line from the argument array and merges stderr inside cmd.exe' {
        $calls = New-Object System.Collections.Generic.List[string]
        $answer = Invoke-WtShutdownCommand -Arguments @('/s', '/t', '600') -RunLine {
            param($CommandLine)
            $calls.Add($CommandLine)
            [PSCustomObject]@{ ExitCode = 0; Output = [string[]]@() }
        }
        @($calls) | Should -Be @('shutdown.exe /s /t 600 2>&1')
        $answer.ExitCode | Should -Be 0
    }

    It 'passes the cancel switch through unchanged and returns the exit code the caller must branch on' {
        $calls = New-Object System.Collections.Generic.List[string]
        $answer = Invoke-WtShutdownCommand -Arguments @('/a') -RunLine {
            param($CommandLine)
            $calls.Add($CommandLine)
            [PSCustomObject]@{ ExitCode = 1116; Output = [string[]]@('Unable to abort the system shutdown...') }
        }
        @($calls) | Should -Be @('shutdown.exe /a 2>&1')
        $answer.ExitCode | Should -Be 1116
        @($answer.Output).Count | Should -Be 1
    }
}

Describe 'Show-WtShutdownTimerResult' {
    It 'streams the result rows into the capture without binding to the capture own $lines collector' {
        Mock Invoke-WtCapturedAction {
            $lines = New-Object System.Collections.Generic.List[string]
            $lines.Add('collector-poison')
            $script:WtShownRows = @(& $Action *>&1 | ForEach-Object { ConvertTo-WtOutputLines -InputObject $_ })
        }
        Show-WtShutdownTimerResult -Title 'Shutdown timer' -ResultLines @('alpha', 'beta') -Breadcrumb 'B'
        @($script:WtShownRows) | Should -Be @('alpha', 'beta')
    }

    It 'passes the title and the breadcrumb through to the capture' {
        Mock Invoke-WtCapturedAction {
            $script:WtShownTitle = $Title
            $script:WtShownCrumb = $Breadcrumb
        }
        Show-WtShutdownTimerResult -Title 'Kapatma zamanlayicisi' -ResultLines @('x') -Breadcrumb 'Ana Menu > Temel Araclar > Eylemler'
        $script:WtShownTitle | Should -Be 'Kapatma zamanlayicisi'
        $script:WtShownCrumb | Should -Be 'Ana Menu > Temel Araclar > Eylemler'
    }
}

Describe 'Invoke-WtShutdownTimerAction (one row, both jobs)' {
    It 'cancels a pending timer when the answer is empty, and reports honestly when none was pending' {
        $calls = New-Object System.Collections.Generic.List[string]
        $shown = New-Object System.Collections.Generic.List[string]
        Invoke-WtShutdownTimerAction `
            -AskMinutes { '' } `
            -ShowInvalid { $calls.Add('invalid-panel') } `
            -RunCancel { $calls.Add('cancel'); [PSCustomObject]@{ ExitCode = 1116; Output = [string[]]@() } } `
            -RunSchedule { param($Seconds) $calls.Add('schedule:' + $Seconds); [PSCustomObject]@{ ExitCode = 0; Output = [string[]]@() } } `
            -ShowResult { param($Rows) foreach ($r in $Rows) { $shown.Add($r) } }
        @($calls) | Should -Be @('cancel')
        @($shown) | Should -Be @((Get-Translation 'ShutdownTimerNonePending'))
    }

    It 'treats 0 exactly like empty' {
        $calls = New-Object System.Collections.Generic.List[string]
        Invoke-WtShutdownTimerAction `
            -AskMinutes { '0' } `
            -ShowInvalid { $calls.Add('invalid-panel') } `
            -RunCancel { $calls.Add('cancel'); [PSCustomObject]@{ ExitCode = 0; Output = [string[]]@() } } `
            -RunSchedule { param($Seconds) $calls.Add('schedule:' + $Seconds); [PSCustomObject]@{ ExitCode = 0; Output = [string[]]@() } } `
            -ShowResult { param($Rows) $null = $Rows }
        @($calls) | Should -Be @('cancel')
    }

    It 'arms the timer in seconds and echoes the wall-clock time' {
        $calls = New-Object System.Collections.Generic.List[string]
        $shown = New-Object System.Collections.Generic.List[string]
        Invoke-WtShutdownTimerAction `
            -AskMinutes { '45' } `
            -ShowInvalid { $calls.Add('invalid-panel') } `
            -RunCancel { $calls.Add('cancel'); [PSCustomObject]@{ ExitCode = 0; Output = [string[]]@() } } `
            -RunSchedule { param($Seconds) $calls.Add('schedule:' + $Seconds); [PSCustomObject]@{ ExitCode = 0; Output = [string[]]@() } } `
            -ShowResult { param($Rows) foreach ($r in $Rows) { $shown.Add($r) } }
        @($calls) | Should -Be @('schedule:2700')
        @($shown).Count | Should -Be 2
        @($shown)[0] | Should -Match '\d{4}-\d{2}-\d{2} \d{2}:\d{2}'
    }

    It 'refuses non-numeric input in the panel and never starts shutdown.exe' {
        foreach ($badAnswer in 'abc', '10 dk', '/a', '-3') {
            $calls = New-Object System.Collections.Generic.List[string]
            Invoke-WtShutdownTimerAction `
                -AskMinutes { $badAnswer }.GetNewClosure() `
                -ShowInvalid { $calls.Add('invalid-panel') } `
                -RunCancel { $calls.Add('cancel'); [PSCustomObject]@{ ExitCode = 0; Output = [string[]]@() } } `
                -RunSchedule { param($Seconds) $calls.Add('schedule:' + $Seconds); [PSCustomObject]@{ ExitCode = 0; Output = [string[]]@() } } `
                -ShowResult { param($Rows) $calls.Add('shown') }
            @($calls) | Should -Be @('invalid-panel') -Because "'$badAnswer'"
        }
    }

    It 'clamps a huge answer to the two-day ceiling and says so' {
        $calls = New-Object System.Collections.Generic.List[string]
        $shown = New-Object System.Collections.Generic.List[string]
        Invoke-WtShutdownTimerAction `
            -AskMinutes { '999999' } `
            -ShowInvalid { $calls.Add('invalid-panel') } `
            -RunCancel { $calls.Add('cancel'); [PSCustomObject]@{ ExitCode = 0; Output = [string[]]@() } } `
            -RunSchedule { param($Seconds) $calls.Add('schedule:' + $Seconds); [PSCustomObject]@{ ExitCode = 0; Output = [string[]]@() } } `
            -ShowResult { param($Rows) foreach ($r in $Rows) { $shown.Add($r) } }
        @($calls) | Should -Be @('schedule:172800')
        @($shown)[0] | Should -Be (Get-Translation 'ShutdownTimerCapped')
    }
}

Describe 'Test-WtWinReAvailable' {
    It 'finds the recovery image path in an English reagentc /info dump' {
        $dump = @(
            'Windows Recovery Environment (Windows RE) and system reset configuration',
            'Information:',
            '',
            '    Windows RE status:         Enabled',
            '    Windows RE location:       \\?\GLOBALROOT\device\harddisk0\partition4\Recovery\WindowsRE',
            '    Boot Configuration Data (BCD) identifier: 9cb1b1e4-0000-0000-0000-000000000000',
            'REAGENTC.EXE: Operation Successful.'
        )
        Test-WtWinReAvailable -GetInfo { $dump } | Should -BeTrue
    }

    It 'finds the same path when the labels come back in Turkish - the path is never localized' {
        $dump = @(
            'Windows Kurtarma Ortami (Windows RE) ve sistem sifirlama yapilandirmasi',
            '    Windows RE durumu:         Etkin',
            '    Windows RE konumu:         \\?\GLOBALROOT\device\harddisk0\partition4\Recovery\WindowsRE',
            'REAGENTC.EXE: Islem Basarili.'
        )
        Test-WtWinReAvailable -GetInfo { $dump } | Should -BeTrue
    }

    It 'reports "not available" when reagentc lists an empty location (WinRE disabled)' {
        $dump = @(
            '    Windows RE status:         Disabled',
            '    Windows RE location:       ',
            'REAGENTC.EXE: Operation Successful.'
        )
        Test-WtWinReAvailable -GetInfo { $dump } | Should -BeFalse
    }

    It 'reports "not available" when reagentc produces nothing or throws' {
        Test-WtWinReAvailable -GetInfo { @() } | Should -BeFalse
        Test-WtWinReAvailable -GetInfo { throw 'reagentc is missing' } | Should -BeFalse
    }

    It 'matches the path Ordinal, so the Turkish dotless I cannot decide whether WinRE exists' {
        $old = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            Test-WtWinReAvailable -GetInfo { @('    Konum: \\?\GLOBALROOT\device\harddisk0\partition4\Recovery\WindowsRE') } | Should -BeTrue
            Test-WtWinReAvailable -GetInfo { @('    Konum: \\?\globalroot\device\harddisk0') } | Should -BeFalse
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $old }
    }
}

Describe 'Invoke-WtRestartToAdvancedStartup' {
    BeforeAll {
        $script:WinReDump = @('    Windows RE location:       \\?\GLOBALROOT\device\harddisk0\partition4\Recovery\WindowsRE')
    }

    It 'asks shutdown for the recovery menu when WinRE is present' {
        $calls = New-Object System.Collections.Generic.List[string]
        $rows = @(Invoke-WtRestartToAdvancedStartup -GetWinReInfo { $WinReDump } -Restart {
                $calls.Add('restart')
                [PSCustomObject]@{ ExitCode = 0; Output = [string[]]@() }
            } *>&1 | ForEach-Object { ConvertTo-WtOutputLines -InputObject $_ })
        @($calls) | Should -Be @('restart')
        $rows | Should -Contain (Get-Translation 'RestartingToAdvancedStartup')
    }

    It 'prints an early line before the reagentc check, so the panel never looks frozen' {
        $rows = @(Invoke-WtRestartToAdvancedStartup -GetWinReInfo { $WinReDump } -Restart {
                [PSCustomObject]@{ ExitCode = 0; Output = [string[]]@() }
            } *>&1 | ForEach-Object { ConvertTo-WtOutputLines -InputObject $_ })
        @($rows)[0] | Should -Be (Get-Translation 'WinReChecking')
    }

    It 'refuses honestly and restarts NOTHING when reagentc lists no recovery image' {
        $calls = New-Object System.Collections.Generic.List[string]
        $rows = @(Invoke-WtRestartToAdvancedStartup -GetWinReInfo { @('    Windows RE status: Disabled') } -Restart {
                $calls.Add('restart')
                [PSCustomObject]@{ ExitCode = 0; Output = [string[]]@() }
            } *>&1 | ForEach-Object { ConvertTo-WtOutputLines -InputObject $_ })
        @($calls).Count | Should -Be 0
        $rows | Should -Contain (Get-Translation 'WinReUnavailable')
        $rows | Should -Contain (Get-Translation 'WinReUnavailableHint')
    }

    It 'reports a non-zero shutdown exit code instead of pretending the restart was queued' {
        $rows = @(Invoke-WtRestartToAdvancedStartup -GetWinReInfo { $WinReDump } -Restart {
                [PSCustomObject]@{ ExitCode = 1190; Output = [string[]]@() }
            } *>&1 | ForEach-Object { ConvertTo-WtOutputLines -InputObject $_ })
        $rows | Should -Contain ((Get-Translation 'PowerCommandFailed') -f 1190)
    }
}

Describe 'Test-WtUefiFirmware' {
    It 'believes $env:firmware_type when Windows sets it' {
        Test-WtUefiFirmware -GetFirmwareType { 'UEFI' } -GetSecureBootState { throw 'must not be asked' } | Should -BeTrue
        Test-WtUefiFirmware -GetFirmwareType { 'uefi' } -GetSecureBootState { throw 'must not be asked' } | Should -BeTrue
        Test-WtUefiFirmware -GetFirmwareType { 'Legacy' } -GetSecureBootState { throw 'must not be asked' } | Should -BeFalse
    }

    It 'falls back to Confirm-SecureBootUEFI when the variable is empty' {
        Test-WtUefiFirmware -GetFirmwareType { '' } -GetSecureBootState { $true } | Should -BeTrue
        Test-WtUefiFirmware -GetFirmwareType { $null } -GetSecureBootState { $false } | Should -BeTrue
    }

    It 'reads PlatformNotSupportedException as "legacy BIOS"' {
        $legacy = { throw [System.PlatformNotSupportedException]::new('Cmdlet not supported on this platform') }
        Test-WtUefiFirmware -GetFirmwareType { '' } -GetSecureBootState $legacy | Should -BeFalse
    }

    It 'refuses rather than guesses when the fallback cannot answer at all' {
        Test-WtUefiFirmware -GetFirmwareType { '' } -GetSecureBootState { throw 'Confirm-SecureBootUEFI is not available' } | Should -BeFalse
    }

    It 'compares the firmware word Ordinal, so tr-TR cannot turn UEFI into something else' {
        $old = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            Test-WtUefiFirmware -GetFirmwareType { 'UEFI' } -GetSecureBootState { throw 'must not be asked' } | Should -BeTrue
            Test-WtUefiFirmware -GetFirmwareType { 'Legacy' } -GetSecureBootState { throw 'must not be asked' } | Should -BeFalse
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $old }
    }
}

Describe 'Invoke-WtRestartToFirmwareSettings' {
    It 'asks shutdown for the firmware setup on a UEFI machine' {
        $calls = New-Object System.Collections.Generic.List[string]
        $rows = @(Invoke-WtRestartToFirmwareSettings -IsUefi { $true } -Restart {
                $calls.Add('restart')
                [PSCustomObject]@{ ExitCode = 0; Output = [string[]]@() }
            } *>&1 | ForEach-Object { ConvertTo-WtOutputLines -InputObject $_ })
        @($calls) | Should -Be @('restart')
        $rows | Should -Contain (Get-Translation 'RestartingToFirmwareSettings')
    }

    It 'refuses on a legacy BIOS and restarts NOTHING' {
        $calls = New-Object System.Collections.Generic.List[string]
        $rows = @(Invoke-WtRestartToFirmwareSettings -IsUefi { $false } -Restart {
                $calls.Add('restart')
                [PSCustomObject]@{ ExitCode = 0; Output = [string[]]@() }
            } *>&1 | ForEach-Object { ConvertTo-WtOutputLines -InputObject $_ })
        @($calls).Count | Should -Be 0
        $rows | Should -Contain (Get-Translation 'FirmwareNotUefi')
        $rows | Should -Contain (Get-Translation 'FirmwareNotUefiHint')
    }

    It 'reports a non-zero shutdown exit code instead of claiming the firmware will open' {
        $rows = @(Invoke-WtRestartToFirmwareSettings -IsUefi { $true } -Restart {
                [PSCustomObject]@{ ExitCode = 50; Output = [string[]]@() }
            } *>&1 | ForEach-Object { ConvertTo-WtOutputLines -InputObject $_ })
        $rows | Should -Contain ((Get-Translation 'PowerCommandFailed') -f 50)
    }
}

Describe 'The Power and session group (ActionGroupPowerSession)' {
    BeforeAll {
        $script:PowerGroup = @(Get-WtActionToolGroups) | Where-Object { $_.HeaderKey -eq 'ActionGroupPowerSession' } | Select-Object -First 1
        $script:PowerRows = @(& $PowerGroup.GetRows)
    }

    It 'holds the seven catalogue rows in catalogue order' {
        @($PowerRows | ForEach-Object Name) | Should -Be @(
            'ShutdownTimer', 'RestartComputer', 'ShutdownComputer',
            'RestartToAdvancedStartup', 'RestartToFirmwareSettings',
            'RestartInSafeMode', 'ExitSafeMode'
        )
    }

    It 'makes ShutdownTimer an inline CAUTION row - it asks in the panel, so it can never be Captured' {
        $row = $PowerRows | Where-Object Name -eq 'ShutdownTimer'
        $row.Kind | Should -Be 'Action'
        $row.Risk | Should -Be 'CAUTION'
        $row.Data.Captured | Should -Not -BeTrue
        $row.Data.Power | Should -Not -BeTrue
        $row.Data.Action.ToString() | Should -Match 'Invoke-WtShutdownTimerAction'
    }

    It 'gives the two new restart rows the ADVANCED badge and their own consequence key' {
        $expected = @{
            RestartToAdvancedStartup  = 'ConsequenceRestartToAdvancedStartup'
            RestartToFirmwareSettings = 'ConsequenceRestartToFirmwareSettings'
        }
        foreach ($name in $expected.Keys) {
            $row = $PowerRows | Where-Object Name -eq $name
            $row.Data.Power | Should -BeTrue -Because $name
            $row.Risk | Should -Be 'ADVANCED' -Because $name
            $row.Data.ConsequenceKey | Should -Be $expected[$name] -Because $name
            (Get-Translation $row.Data.ConsequenceKey) | Should -Not -BeNullOrEmpty -Because $name
        }
    }

    It 'wires each new Power row to its own guarded function' {
        ($PowerRows | Where-Object Name -eq 'RestartToAdvancedStartup').Data.Action.ToString() | Should -Match 'Invoke-WtRestartToAdvancedStartup'
        ($PowerRows | Where-Object Name -eq 'RestartToFirmwareSettings').Data.Action.ToString() | Should -Match 'Invoke-WtRestartToFirmwareSettings'
    }

    It 'keeps the safe-boot identifier quoted - a bare {default} is turned into -encodedCommand' {
        ($PowerRows | Where-Object Name -eq 'RestartInSafeMode').Data.Action.ToString() | Should -Match "'\{default\}'"
        ($PowerRows | Where-Object Name -eq 'ExitSafeMode').Data.Action.ToString() | Should -Match "'\{default\}'"
    }

    It 'labels every row through the active language' {
        $old = $script:Language
        try {
            foreach ($lang in 'EN', 'TR') {
                $script:Language = $lang
                foreach ($row in @(& $PowerGroup.GetRows)) {
                    $row.Label | Should -Be $script:Translations[$lang][$row.Name] -Because "$lang '$($row.Name)'"
                }
            }
        }
        finally { $script:Language = $old }
    }

    It 'never lets a captured row in this group call Read-Host' {
        foreach ($row in $PowerRows) {
            if ($row.Data.Captured) {
                $row.Data.Action.ToString() | Should -Not -Match 'Read-Host' -Because $row.Name
            }
        }
    }
}
