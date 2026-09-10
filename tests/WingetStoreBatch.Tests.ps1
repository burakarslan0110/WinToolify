#Requires -Modules Pester

<#
.SYNOPSIS
    The streamed-process core shared by the sfc/DISM panel and the winget
    batch runner, and the batch runner itself. Drives real short-lived
    child processes - never winget.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Invoke-WtStreamedProcess' {
    It 'collects the child stdout into the shared output state' {
        $state = New-WtNativeOutputState
        $code = Invoke-WtStreamedProcess -FilePath 'cmd.exe' -Arguments '/c echo hello-from-child' `
            -State $state -OnTick { } -RefreshMs 10
        $code | Should -Be 0
        (@($state.Lines.ToArray()) -join "`n") | Should -BeLike '*hello-from-child*'
    }

    It 'returns the child exit code so the caller can classify the result' {
        $state = New-WtNativeOutputState
        $code = Invoke-WtStreamedProcess -FilePath 'cmd.exe' -Arguments '/c exit 3' `
            -State $state -OnTick { } -RefreshMs 10
        $code | Should -Be 3
    }

    It 'ticks while the child runs, so an idle tool still repaints' {
        $script:Ticks = 0
        $state = New-WtNativeOutputState
        $null = Invoke-WtStreamedProcess -FilePath 'cmd.exe' -Arguments '/c ping -n 2 127.0.0.1' `
            -State $state -OnTick { $script:Ticks++ } -RefreshMs 20
        $script:Ticks | Should -BeGreaterThan 1
    }

    It 'reports a missing executable instead of throwing' {
        $state = New-WtNativeOutputState
        $code = Invoke-WtStreamedProcess -FilePath 'no-such-binary-wt.exe' -Arguments '' `
            -State $state -OnTick { } -RefreshMs 10
        $code | Should -Not -Be 0
        @($state.Lines.ToArray()).Count | Should -BeGreaterThan 0
    }
}

Describe 'Get-WtWingetBatchArguments' {
    It 'routes each operation to its own builder' {
        (Get-WtWingetBatchArguments -Operation 'Install'   -Id 'A.B')[0] | Should -Be 'install'
        (Get-WtWingetBatchArguments -Operation 'Uninstall' -Id 'A.B')[0] | Should -Be 'uninstall'
        (Get-WtWingetBatchArguments -Operation 'Upgrade'   -Id 'A.B')[0] | Should -Be 'upgrade'
    }

    It 'returns the same String[] shape for every operation - Upgrade must not degrade to Object[] or a bare scalar' {
        (Get-WtWingetBatchArguments -Operation 'Install'   -Id 'A.B').GetType().Name | Should -Be 'String[]'
        (Get-WtWingetBatchArguments -Operation 'Uninstall' -Id 'A.B').GetType().Name | Should -Be 'String[]'
        (Get-WtWingetBatchArguments -Operation 'Upgrade'   -Id 'A.B').GetType().Name | Should -Be 'String[]'
    }
}

Describe 'Invoke-WtWingetBatch' {
    It 'runs every id in order - winget takes one package per command' {
        $script:Ran = @()
        $fake = { param($Id, $Arguments, $Index, $Total) $script:Ran += $Id; 0 }
        $null = Invoke-WtWingetBatch -Ids @('A.One', 'B.Two', 'C.Three') -Operation 'Install' -RunOne $fake
        $script:Ran | Should -Be @('A.One', 'B.Two', 'C.Three')
    }

    It 'classifies each result rather than stopping at the first failure' {
        $noApp = [System.BitConverter]::ToInt32([System.BitConverter]::GetBytes([Convert]::ToUInt32('8A150014', 16)), 0)
        $fake = { param($Id, $Arguments, $Index, $Total) if ($Id -eq 'B.Two') { $noApp } else { 0 } }
        $r = @(Invoke-WtWingetBatch -Ids @('A.One', 'B.Two', 'C.Three') -Operation 'Install' -RunOne $fake)
        $r.Count | Should -Be 3
        ($r | Where-Object { $_.Id -eq 'A.One' }).Kind | Should -Be 'Ok'
        ($r | Where-Object { $_.Id -eq 'B.Two' }).Kind | Should -Be 'NotFound'
        ($r | Where-Object { $_.Id -eq 'C.Three' }).Kind | Should -Be 'Ok'
    }

    It 'hands the runner its position so the panel can show [3/8]' {
        $script:Seen = @()
        $fake = { param($Id, $Arguments, $Index, $Total) $script:Seen += "$Index/$Total"; 0 }
        $null = Invoke-WtWingetBatch -Ids @('A.One', 'B.Two') -Operation 'Install' -RunOne $fake
        $script:Seen | Should -Be @('1/2', '2/2')
    }

    It 'invalidates the installed cache - the list is stale the moment this runs' {
        Clear-WtWingetCache
        $script:Calls = 0
        $listFake = { param($Arguments) $script:Calls++; @('Ad  Kimlik  Surum', '-------------------', 'X   X.Y     1.0') }
        $null = Get-WtWingetInstalledPackages -RunWinget $listFake
        $null = Invoke-WtWingetBatch -Ids @('A.One') -Operation 'Install' -RunOne { param($Id, $Arguments, $Index, $Total) 0 }
        $null = Get-WtWingetInstalledPackages -RunWinget $listFake
        $script:Calls | Should -Be 2
    }

    It 'does nothing, and does not throw, on an empty selection' {
        @(Invoke-WtWingetBatch -Ids @() -Operation 'Install' -RunOne { throw 'must not run' }).Count | Should -Be 0
    }
}

Describe 'Get-WtWingetSummaryLines' {
    It 'counts each verdict so the tail of a long log is still readable' {
        $results = @(
            @{ Id = 'A'; Kind = 'Ok'; ExitCode = 0 }
            @{ Id = 'B'; Kind = 'Ok'; ExitCode = 0 }
            @{ Id = 'C'; Kind = 'AlreadyInstalled'; ExitCode = 1 }
            @{ Id = 'D'; Kind = 'Failed'; ExitCode = 5 }
        )
        $lines = @(Get-WtWingetSummaryLines -Results $results)
        $expectedCounts = (Get-Translation 'WsSummaryCounts') -f 2, 1, 0, 1
        $lines | Should -Contain $expectedCounts
        $lines | Should -Contain ('  ' + ((Get-Translation 'WsResultAlready') -f 'C'))
        $lines | Should -Contain ('  ' + ((Get-Translation 'WsResultFailed') -f 'D', '00000005'))
        $lines | Should -Not -Contain ('  ' + ((Get-Translation 'WsResultOk') -f 'A'))
        $lines | Should -Not -Contain ('  ' + ((Get-Translation 'WsResultOk') -f 'B'))
    }

    It 'folds NotFound into the failed count - the four counts must always sum to the result total' {
        $results = @(
            @{ Id = 'A'; Kind = 'Ok'; ExitCode = 0 }
            @{ Id = 'B'; Kind = 'AlreadyInstalled'; ExitCode = 1 }
            @{ Id = 'C'; Kind = 'NoUpgrade'; ExitCode = 2 }
            @{ Id = 'D'; Kind = 'Failed'; ExitCode = 5 }
            @{ Id = 'E'; Kind = 'NotFound'; ExitCode = 6 }
        )
        $lines = @(Get-WtWingetSummaryLines -Results $results)
        $expectedCounts = (Get-Translation 'WsSummaryCounts') -f 1, 1, 1, 2
        $lines | Should -Contain $expectedCounts
        $countsLine = $lines[2]
        $countedTotal = (([regex]::Matches($countsLine, '\d+') | ForEach-Object { [int]$_.Value }) | Measure-Object -Sum).Sum
        $countedTotal | Should -Be $results.Count
        $lines | Should -Contain ('  ' + ((Get-Translation 'WsResultNotFound') -f 'E'))
    }
}

Describe 'Invoke-WtWingetCapture pipe draining' {
    BeforeAll {
        $script:ChattyPath = Join-Path ([System.IO.Path]::GetTempPath()) ('wt-chatty-' + [guid]::NewGuid().ToString('N') + '.cmd')
        $pad = 'X' * 60
        $body = @(
            '@echo off'
            "for /L %%i in (1,1,400) do @echo ERR-%%i-$pad 1>&2"
            'echo Name  Id       Version  Source'
            'echo ---------------------------------'
            'echo App   A.B      1.0      winget'
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($script:ChattyPath, $body, (New-Object System.Text.ASCIIEncoding))
    }
    AfterAll {
        if (Test-Path -LiteralPath $script:ChattyPath) { Remove-Item -LiteralPath $script:ChattyPath -Force }
    }

    It 'returns the child stdout even when the child floods stderr first' {
        $lines = Invoke-WtWingetCapture -Arguments @('/c', $script:ChattyPath) -FilePath 'cmd.exe'
        ($lines -join "`n") | Should -BeLike '*A.B*'
    }

    It 'still parses that output into packages, so the drain order changed nothing else' {
        $lines = Invoke-WtWingetCapture -Arguments @('/c', $script:ChattyPath) -FilePath 'cmd.exe'
        $rows = @(ConvertFrom-WtWingetTable -Lines $lines)
        $rows.Count | Should -Be 1
        $rows[0].Id | Should -Be 'A.B'
    }

    It 'returns an empty result, and does not throw, when the executable does not exist' {
        $lines = Invoke-WtWingetCapture -Arguments @('list') -FilePath 'no-such-binary-wt.exe'
        @($lines).Count | Should -Be 0
    }
}

Describe 'Get-WtWingetResultKind reboot codes' {
    BeforeAll {
        function ConvertTo-Signed($Hex) {
            [System.BitConverter]::ToInt32([System.BitConverter]::GetBytes([Convert]::ToUInt32($Hex, 16)), 0)
        }
    }

    It '0x8A150109 is INSTALL_REBOOT_REQUIRED_TO_FINISH - a success that wants a restart' {
        Get-WtWingetResultKind -ExitCode (ConvertTo-Signed '8A150109') | Should -Be 'RebootRequired'
    }

    It '0x8A15010B is INSTALL_REBOOT_INITIATED - also a success, the restart is already coming' {
        Get-WtWingetResultKind -ExitCode (ConvertTo-Signed '8A15010B') | Should -Be 'RebootRequired'
    }

    It '0x8A15010A says the install FAILED and needs a restart before a retry - never a success' {
        Get-WtWingetResultKind -ExitCode (ConvertTo-Signed '8A15010A') | Should -Be 'RebootToRetry'
    }

    It 'counts a reboot-required install as done and a reboot-to-retry as failed' {
        $results = @(
            @{ Id = 'A'; Kind = 'Ok'; ExitCode = 0 }
            @{ Id = 'B'; Kind = 'RebootRequired'; ExitCode = (ConvertTo-Signed '8A150109') }
            @{ Id = 'C'; Kind = 'RebootToRetry';  ExitCode = (ConvertTo-Signed '8A15010A') }
        )
        $lines = @(Get-WtWingetSummaryLines -Results $results -Operation 'Install')
        $lines | Should -Contain ((Get-Translation 'WsSummaryCounts') -f 2, 0, 0, 1)
        $lines | Should -Contain ('  ' + ((Get-Translation 'WsResultReboot') -f 'B'))
        $lines | Should -Contain ('  ' + ((Get-Translation 'WsResultRebootRetry') -f 'C'))
        $counted = (([regex]::Matches($lines[2], '\d+') | ForEach-Object { [int]$_.Value }) | Measure-Object -Sum).Sum
        $counted | Should -Be $results.Count
    }

    It 'never prints a raw hex code for a reboot verdict' {
        foreach ($hex in '8A150109', '8A15010A', '8A15010B') {
            $kind = Get-WtWingetResultKind -ExitCode (ConvertTo-Signed $hex)
            $line = Get-WtWingetResultLine -Id 'A.B' -Kind $kind -ExitCode (ConvertTo-Signed $hex)
            $line | Should -Not -BeLike "*0x$hex*" -Because "$hex must have a verdict of its own"
            $line | Should -BeLike '*A.B*'
        }
    }
}

Describe 'Get-WtWingetSummaryLines per operation' {
    BeforeAll {
        $script:TwoOfThree = @(
            @{ Id = 'A'; Kind = 'Ok'; ExitCode = 0 }
            @{ Id = 'B'; Kind = 'Ok'; ExitCode = 0 }
            @{ Id = 'C'; Kind = 'Failed'; ExitCode = 5 }
        )
    }

    It 'says removed, not installed, after an uninstall batch' {
        $lines = @(Get-WtWingetSummaryLines -Results $TwoOfThree -Operation 'Uninstall')
        $lines | Should -Contain ((Get-Translation 'WsSummaryCountsUninstall') -f 2, 0, 1)
        $lines | Should -Not -Contain ((Get-Translation 'WsSummaryCounts') -f 2, 0, 0, 1)
        $lines | Should -Contain ('  ' + ((Get-Translation 'WsResultFailed') -f 'C', '00000005'))
    }

    It 'says updated, not installed, after an upgrade batch' {
        $lines = @(Get-WtWingetSummaryLines -Results $TwoOfThree -Operation 'Upgrade')
        $lines | Should -Contain ((Get-Translation 'WsSummaryCountsUpgrade') -f 2, 0, 0, 1)
        $lines | Should -Not -Contain ((Get-Translation 'WsSummaryCounts') -f 2, 0, 0, 1)
    }

    It 'still says installed for an install batch, and for a caller that names no operation' {
        $named = @(Get-WtWingetSummaryLines -Results $TwoOfThree -Operation 'Install')
        $default = @(Get-WtWingetSummaryLines -Results $TwoOfThree)
        $named | Should -Contain ((Get-Translation 'WsSummaryCounts') -f 2, 0, 0, 1)
        ($default -join "`n") | Should -Be ($named -join "`n")
    }

    It 'keeps the uninstall counts summing to the result total' {
        $mixed = @(
            @{ Id = 'A'; Kind = 'Ok'; ExitCode = 0 }
            @{ Id = 'B'; Kind = 'AlreadyInstalled'; ExitCode = 1 }
            @{ Id = 'C'; Kind = 'NoUpgrade'; ExitCode = 2 }
            @{ Id = 'D'; Kind = 'NotFound'; ExitCode = 3 }
        )
        $lines = @(Get-WtWingetSummaryLines -Results $mixed -Operation 'Uninstall')
        $counted = (([regex]::Matches($lines[2], '\d+') | ForEach-Object { [int]$_.Value }) | Measure-Object -Sum).Sum
        $counted | Should -Be $mixed.Count
    }

    It 'gives each operation its own per-package success wording' {
        (Get-WtWingetResultLine -Id 'A.B' -Kind 'Ok' -ExitCode 0 -Operation 'Install') |
            Should -Be ((Get-Translation 'WsResultOk') -f 'A.B')
        (Get-WtWingetResultLine -Id 'A.B' -Kind 'Ok' -ExitCode 0 -Operation 'Upgrade') |
            Should -Be ((Get-Translation 'WsResultOkUpgrade') -f 'A.B')
        (Get-WtWingetResultLine -Id 'A.B' -Kind 'Ok' -ExitCode 0 -Operation 'Uninstall') |
            Should -Be ((Get-Translation 'WsResultOkUninstall') -f 'A.B')
    }

    It 'does not claim a package is already installed or already current after an uninstall' {
        foreach ($kind in 'AlreadyInstalled', 'NoUpgrade') {
            $line = Get-WtWingetResultLine -Id 'A.B' -Kind $kind -ExitCode 1 -Operation 'Uninstall'
            $line | Should -Be ((Get-Translation 'WsResultUnchanged') -f 'A.B')
            $line | Should -Not -Be ((Get-Translation 'WsResultAlready') -f 'A.B')
            $line | Should -Not -Be ((Get-Translation 'WsResultNoUpgrade') -f 'A.B')
        }
    }

    It 'has every new result and summary key in both languages, with matching placeholders' {
        $keys = @(
            'WsResultOkUpgrade', 'WsResultOkUninstall', 'WsResultUnchanged',
            'WsResultReboot', 'WsResultRebootRetry',
            'WsSummaryCountsUpgrade', 'WsSummaryCountsUninstall'
        )
        foreach ($key in $keys) {
            foreach ($lang in 'EN', 'TR') {
                $script:Translations[$lang].ContainsKey($key) | Should -BeTrue -Because "$lang needs '$key'"
            }
            $enSlots = @([regex]::Matches($script:Translations['EN'][$key], '\{\d\}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
            $trSlots = @([regex]::Matches($script:Translations['TR'][$key], '\{\d\}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
            $trSlots | Should -Be $enSlots -Because "'$key' must take the same placeholders in both languages"
        }
        (@([regex]::Matches($script:Translations['TR']['WsSummaryCountsUninstall'], '\{\d\}')).Count) | Should -Be 3
    }
}

Describe 'The admin-context (user scope) verdict' {
    BeforeAll {
        $script:AdminCtx = [System.BitConverter]::ToInt32(
            [System.BitConverter]::GetBytes([Convert]::ToUInt32('8A15007D', 16)), 0)
    }

    It 'recognises 0x8A15007D and nothing else' {
        Test-WtWingetAdminContextProhibited -ExitCode $script:AdminCtx | Should -BeTrue
        Test-WtWingetAdminContextProhibited -ExitCode 0 | Should -BeFalse
        Test-WtWingetAdminContextProhibited -ExitCode $null | Should -BeFalse
        $noApp = [System.BitConverter]::ToInt32([System.BitConverter]::GetBytes([Convert]::ToUInt32('8A150014', 16)), 0)
        Test-WtWingetAdminContextProhibited -ExitCode $noApp | Should -BeFalse
    }

    It 'gets its own verdict rather than the anonymous Failed bucket' {
        Get-WtWingetResultKind -ExitCode $script:AdminCtx | Should -Be 'AdminContext'
    }

    It 'explains itself instead of printing a hex code' {
        Get-WtWingetResultKey -Kind 'AdminContext' -Operation 'Uninstall' | Should -Be 'WsResultAdminContext'
        $line = Get-WtWingetResultLine -Id 'Google.Antigravity' -Kind 'AdminContext' `
            -ExitCode $script:AdminCtx -Operation 'Uninstall'
        $line | Should -BeLike '*Google.Antigravity*'
        $line | Should -Not -BeLike '*8A15007D*'
    }

    It 'still adds up: the counts line covers it as a failure' {
        $results = @(
            @{ Id = 'A.One'; Kind = 'Ok'; ExitCode = 0 },
            @{ Id = 'B.Two'; Kind = 'AdminContext'; ExitCode = $script:AdminCtx }
        )
        $lines = @(Get-WtWingetSummaryLines -Results $results -Operation 'Uninstall')
        ($lines -join "`n") | Should -BeLike '*1*1*'
        ($lines | Where-Object { $_ -like '*B.Two*' }).Count | Should -Be 1
    }
}

Describe 'Invoke-WtWingetBatch -RunOneAsUser' {
    BeforeAll {
        $script:AdminCtx = [System.BitConverter]::ToInt32(
            [System.BitConverter]::GetBytes([Convert]::ToUInt32('8A15007D', 16)), 0)
    }

    It 'retries as the signed-in user and takes that verdict when it succeeds' {
        $asUserCalls = New-Object System.Collections.Generic.List[string]
        $r = @(Invoke-WtWingetBatch -Ids @('Google.Antigravity') -Operation 'Uninstall' `
            -RunOne { param($Id, $Arguments, $Index, $Total) $script:AdminCtx } `
            -RunOneAsUser { param($Id, $Arguments, $Index, $Total) $asUserCalls.Add([string]$Id); 0 })
        @($asUserCalls).Count | Should -Be 1
        $asUserCalls[0] | Should -Be 'Google.Antigravity'
        $r[0].Kind | Should -Be 'Ok'
    }

    It 'hands the retry the SAME arguments the elevated run used' {
        $seen = $null
        $null = Invoke-WtWingetBatch -Ids @('Google.Antigravity') -Operation 'Uninstall' `
            -RunOne { param($Id, $Arguments, $Index, $Total) $script:AdminCtx } `
            -RunOneAsUser { param($Id, $Arguments, $Index, $Total) $script:seen = @($Arguments); 0 }
        ($script:seen -join ' ') | Should -BeLike '*uninstall*Google.Antigravity*'
    }

    It 'keeps the original verdict when the retry could not run at all' {
        $r = @(Invoke-WtWingetBatch -Ids @('Google.Antigravity') -Operation 'Uninstall' `
            -RunOne { param($Id, $Arguments, $Index, $Total) $script:AdminCtx } `
            -RunOneAsUser { param($Id, $Arguments, $Index, $Total) $null })
        $r[0].Kind | Should -Be 'AdminContext'
    }

    It 'says the same thing when no retry runner was supplied' {
        $r = @(Invoke-WtWingetBatch -Ids @('Google.Antigravity') -Operation 'Uninstall' `
            -RunOne { param($Id, $Arguments, $Index, $Total) $script:AdminCtx })
        $r[0].Kind | Should -Be 'AdminContext'
    }

    It 'never retries a failure that de-elevation cannot fix' {
        $tried = $false
        $noApp = [System.BitConverter]::ToInt32([System.BitConverter]::GetBytes([Convert]::ToUInt32('8A150014', 16)), 0)
        $null = Invoke-WtWingetBatch -Ids @('A.One') -Operation 'Uninstall' `
            -RunOne { param($Id, $Arguments, $Index, $Total) $noApp } `
            -RunOneAsUser { param($Id, $Arguments, $Index, $Total) $script:tried = $true; 0 }
        $script:tried | Should -BeFalse
    }

    It 'retries an install and an upgrade too - user scope blocks all three' {
        foreach ($operation in @('Install', 'Upgrade', 'Uninstall')) {
            $tried = $false
            $null = Invoke-WtWingetBatch -Ids @('A.One') -Operation $operation `
                -RunOne { param($Id, $Arguments, $Index, $Total) $script:AdminCtx } `
                -RunOneAsUser { param($Id, $Arguments, $Index, $Total) $script:tried = $true; 0 }
            $script:tried | Should -BeTrue -Because "$operation must retry as the user"
        }
    }
}
