#Requires -Modules Pester

<#
.SYNOPSIS
    Coverage for the four rows of Information > Events and
    diagnostics. Every Get-Wt*Lines function is exercised at least
    twice - data present and data absent - and the absent case always
    includes the TERMINATING "No events were found that match the
    specified selection criteria" error Get-WinEvent raises when a
    filter matches nothing.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath

    function New-WtFakeEvent {
        <#
        .SYNOPSIS
            An object shaped like one Get-WinEvent record. Message is
            [object] on purpose so a test can pass $null through it - the
            real API returns $null whenever the provider's resource DLL is
            not registered.
        #>
        param(
            [datetime]$TimeCreated = ([datetime]::new(2026, 8, 20, 9, 15, 0)),
            [int]$Id = 1001,
            [object]$Level = 2,
            [string]$ProviderName = 'Test-Provider',
            [object]$Message = 'Something failed.'
        )
        return [PSCustomObject]@{
            TimeCreated  = $TimeCreated
            Id           = $Id
            Level        = $Level
            ProviderName = $ProviderName
            Message      = $Message
        }
    }

    function New-WtFakeDump {
        <#
        .SYNOPSIS
            An object shaped like one Get-ChildItem FileInfo for a .dmp.
        #>
        param(
            [string]$Name = '082026-11250-01.dmp',
            [long]$Length = 262144,
            [datetime]$LastWriteTime = ([datetime]::new(2026, 8, 20, 9, 16, 0))
        )
        return [PSCustomObject]@{ Name = $Name; Length = $Length; LastWriteTime = $LastWriteTime }
    }

    function Get-WtTestInfoGroupRows {
        <#
        .SYNOPSIS
            The rows one Information group emits, by header key. -ceq keeps
            the comparison ordinal (the tr-TR dotless-I rule).
        #>
        param([Parameter(Mandatory)][string]$HeaderKey)
        $group = @(Get-WtInfoToolGroups) | Where-Object { [string]$_.HeaderKey -ceq $HeaderKey }
        return @(& $group.GetRows)
    }
}

Describe 'Get-WtRecentSystemErrorsLines' {
    It 'renders a heading plus one row per event, with only the first message line' {
        $lines = @(Get-WtRecentSystemErrorsLines -Width 95 -GetEvents {
            @(
                (New-WtFakeEvent -TimeCreated ([datetime]::new(2026, 8, 20, 9, 15, 0)) -Id 7001 -Level 2 -ProviderName 'Service Control Manager' -Message "The Foo service failed to start.`r`nSee the vendor documentation.")
            )
        })

        $lines.Count | Should -Be 2
        $lines[0] | Should -Be (Get-Translation 'RecentSystemErrorsHeading')
        $lines[1] | Should -BeLike '2026-08-20 09:15*'
        $lines[1].Contains('7001') | Should -BeTrue
        $lines[1].Contains('Service Control Manag~') | Should -BeTrue -Because 'the provider column is 22 wide and a longer name is cut, not wrapped'
        $lines[1].Contains('The Foo service failed to start.') | Should -BeTrue
        $lines[1].Contains('See the vendor documentation') | Should -BeFalse -Because 'only the first CRLF-delimited line belongs in a table row'
        $lines[1] | Should -Be $lines[1].TrimEnd() -Because 'the -f padding must be trimmed or the panel cuts the row at ~'
    }

    It 'truncates the message column to the room the fixed columns leave' {
        $lines = @(Get-WtRecentSystemErrorsLines -Width 95 -GetEvents {
            @( (New-WtFakeEvent -Id 41 -Level 1 -ProviderName 'Microsoft-Windows-Kernel-Power' -Message ('x' * 400)) )
        })

        $lines.Count | Should -Be 2
        $lines[1].Length | Should -BeLessOrEqual 95
        $lines[1].EndsWith('~') | Should -BeTrue -Because 'a cut message must say it was cut'
        $lines[1].Contains((Get-Translation 'EventLevelCritical')) | Should -BeTrue
    }

    It 'says "no matching events" when the log has nothing for the filter' {
        $lines = @(Get-WtRecentSystemErrorsLines -Width 95 -GetEvents { @() })

        $lines.Count | Should -Be 1
        $lines[0] | Should -Be (Get-Translation 'EventsNoneFound')
    }

    It 'treats the terminating "No events were found" error as the empty case' {
        $call = { Get-WtRecentSystemErrorsLines -Width 95 -GetEvents { throw 'No events were found that match the specified selection criteria.' } }

        $call | Should -Not -Throw
        $lines = @(& $call)
        $lines.Count | Should -Be 1
        $lines[0] | Should -Be (Get-Translation 'EventsNoneFound')
    }

    It 'survives an event whose Message is null' {
        $lines = @(Get-WtRecentSystemErrorsLines -Width 95 -GetEvents {
            @( (New-WtFakeEvent -Id 6008 -Level 2 -ProviderName 'EventLog' -Message $null) )
        })

        $lines.Count | Should -Be 2
        $lines[1].Contains((Get-Translation 'EventNoMessage')) | Should -BeTrue
    }
}

Describe 'Get-WtBlueScreenHistoryLines' {
    It 'merges bugchecks and power-loss events newest first, then lists the dumps' {
        $lines = @(Get-WtBlueScreenHistoryLines -Width 95 `
            -GetBugchecks { @( (New-WtFakeEvent -TimeCreated ([datetime]::new(2026, 8, 18, 22, 30, 0)) -Id 1001 -Level 2 -ProviderName 'Microsoft-Windows-WER-SystemErrorReporting' -Message "The computer has rebooted from a bugcheck.`r`nThe bugcheck was: 0x0000009f.") ) } `
            -GetPowerLoss { @( (New-WtFakeEvent -TimeCreated ([datetime]::new(2026, 8, 20, 7, 5, 0)) -Id 41 -Level 1 -ProviderName 'Microsoft-Windows-Kernel-Power' -Message 'The system has rebooted without cleanly shutting down first.') ) } `
            -GetUnexpectedShutdowns { @() } `
            -GetDumps { @( (New-WtFakeDump -Name '081826-11250-01.dmp' -Length 262144 -LastWriteTime ([datetime]::new(2026, 8, 18, 22, 31, 0))) ) })

        $lines.Count | Should -Be 7
        $lines[0] | Should -Be (Get-Translation 'BlueScreenHistoryHeading')
        $lines[1] | Should -BeLike '2026-08-20 07:05*' -Because 'the newest event comes first'
        $lines[1].Contains((Get-Translation 'BlueScreenTagPowerLoss')) | Should -BeTrue
        $lines[2] | Should -BeLike '2026-08-18 22:30*'
        $lines[2].Contains((Get-Translation 'BlueScreenTagBugCheck')) | Should -BeTrue
        $lines[2].Contains('The computer has rebooted from a bugcheck.') | Should -BeTrue
        $lines[2].Contains('0x0000009f') | Should -BeFalse -Because 'only the first message line goes in the row'
        $lines[3] | Should -Be ''
        $lines[4] | Should -Be (Get-Translation 'CrashDumpsHeading')
        $lines[5].Contains((Format-WtByteSize -Bytes 262144)) | Should -BeTrue
        $lines[6].Contains('081826-11250-01.dmp') | Should -BeTrue
    }

    It 'labels an unexpected shutdown (6008) distinctly from a stop error (1001)' {
        $lines = @(Get-WtBlueScreenHistoryLines -Width 95 `
            -GetBugchecks { @( (New-WtFakeEvent -TimeCreated ([datetime]::new(2026, 8, 18, 22, 30, 0)) -Id 1001 -Level 2 -ProviderName 'Microsoft-Windows-WER-SystemErrorReporting' -Message 'The computer has rebooted from a bugcheck.') ) } `
            -GetPowerLoss { @() } `
            -GetUnexpectedShutdowns { @( (New-WtFakeEvent -TimeCreated ([datetime]::new(2026, 8, 20, 7, 5, 0)) -Id 6008 -Level 2 -ProviderName 'EventLog' -Message 'The previous system shutdown was unexpected.') ) } `
            -GetDumps { @() })

        $lines.Count | Should -Be 6
        $lines[1] | Should -BeLike '2026-08-20 07:05*' -Because 'the newest event comes first'
        $lines[1].Contains((Get-Translation 'BlueScreenTagUnexpectedShutdown')) | Should -BeTrue
        $lines[1].Contains((Get-Translation 'BlueScreenTagBugCheck')) | Should -BeFalse -Because '6008 is not proof of a stop error'
        $lines[2] | Should -BeLike '2026-08-18 22:30*'
        $lines[2].Contains((Get-Translation 'BlueScreenTagBugCheck')) | Should -BeTrue
        (Get-Translation 'BlueScreenTagUnexpectedShutdown') | Should -Not -Be (Get-Translation 'BlueScreenTagBugCheck') -Because '6008 must not read like a confirmed crash'
    }

    It 'still renders the bugcheck row when the unexpected-shutdown source throws' {
        $call = {
            Get-WtBlueScreenHistoryLines -Width 95 `
                -GetBugchecks { @( (New-WtFakeEvent -Id 1001 -Level 2 -ProviderName 'Microsoft-Windows-WER-SystemErrorReporting' -Message 'The computer has rebooted from a bugcheck.') ) } `
                -GetPowerLoss { @() } `
                -GetUnexpectedShutdowns { throw 'No events were found that match the specified selection criteria.' } `
                -GetDumps { @() }
        }

        $call | Should -Not -Throw
        $lines = @(& $call)
        $lines.Count | Should -Be 5
        $lines[1].Contains((Get-Translation 'BlueScreenTagBugCheck')) | Should -BeTrue
    }

    It 'truncates the message column to the room the fixed columns leave' {
        $lines = @(Get-WtBlueScreenHistoryLines -Width 95 `
            -GetBugchecks { @( (New-WtFakeEvent -Id 1001 -Level 2 -ProviderName 'Microsoft-Windows-WER-SystemErrorReporting' -Message ('x' * 400)) ) } `
            -GetPowerLoss { @() } `
            -GetUnexpectedShutdowns { @() } `
            -GetDumps { @() })

        $lines.Count | Should -Be 5
        $lines[1].Length | Should -BeLessOrEqual 95
        $lines[1].EndsWith('~') | Should -BeTrue -Because 'a cut message must say it was cut'
        $lines[1].Contains((Get-Translation 'BlueScreenTagBugCheck')) | Should -BeTrue
    }

    It 'says so explicitly when the machine has never crashed and holds no dump' {
        $lines = @(Get-WtBlueScreenHistoryLines -Width 95 -GetBugchecks { @() } -GetPowerLoss { @() } -GetUnexpectedShutdowns { @() } -GetDumps { @() })

        $lines.Count | Should -Be 5
        $lines[0] | Should -Be (Get-Translation 'BlueScreenHistoryHeading')
        $lines[1].Contains((Get-Translation 'BlueScreenNoneFound')) | Should -BeTrue
        $lines[2] | Should -Be ''
        $lines[3] | Should -Be (Get-Translation 'CrashDumpsHeading')
        $lines[4].Contains((Get-Translation 'CrashDumpsNone')) | Should -BeTrue
    }

    It 'treats the terminating "No events were found" error from all three providers as empty' {
        $call = {
            Get-WtBlueScreenHistoryLines -Width 95 `
                -GetBugchecks { throw 'No events were found that match the specified selection criteria.' } `
                -GetPowerLoss { throw 'No events were found that match the specified selection criteria.' } `
                -GetUnexpectedShutdowns { throw 'No events were found that match the specified selection criteria.' } `
                -GetDumps { throw 'Cannot find path because it does not exist.' }
        }

        $call | Should -Not -Throw
        $lines = @(& $call)
        $lines.Count | Should -Be 5
        $lines[1].Contains((Get-Translation 'BlueScreenNoneFound')) | Should -BeTrue
        $lines[4].Contains((Get-Translation 'CrashDumpsNone')) | Should -BeTrue
    }

    It 'resolves the dump folder from $env:SystemRoot and never hard-codes C:\Windows' {
        $ast = (Get-Command Get-WtBlueScreenHistoryLines).ScriptBlock.Ast
        $param = @($ast.Body.ParamBlock.Parameters | Where-Object { [string]$_.Name.VariablePath.UserPath -ceq 'GetDumps' })[0]
        $default = [string]$param.DefaultValue.Extent.Text

        $default.Contains('$env:SystemRoot') | Should -BeTrue
        $default.Contains('Minidump') | Should -BeTrue
        $default.Contains('C:\Windows') | Should -BeFalse -Because 'Windows does not always live on C:'
    }

    It 'reads events 1001, 41 and 6008 - a stop error, a hard power loss, and an unexpected shutdown' {
        $text = (Get-Command Get-WtBlueScreenHistoryLines).ScriptBlock.Ast.Extent.Text
        $filterText = ($text -csplit "`r`n|`r|`n" | Where-Object { $_.Contains('FilterHashtable') }) -join ' '

        $filterText.Contains('1001') | Should -BeTrue
        $filterText.Contains('41') | Should -BeTrue
        $filterText.Contains('6008') | Should -BeTrue -Because 'on a machine with minidumps disabled, 6008 is the only trace a crash happened'
    }
}

Describe 'Get-WtDiskErrorEventsLines' {
    It 'renders disk and file system faults newest first, with the level word' {
        $lines = @(Get-WtDiskErrorEventsLines -Width 95 -GetEvents {
            @(
                (New-WtFakeEvent -TimeCreated ([datetime]::new(2026, 8, 19, 3, 0, 0)) -Id 51 -Level 3 -ProviderName 'disk' -Message "An error was detected on device \Device\Harddisk0\DR0 during a paging operation.`r`nSecond line.")
                (New-WtFakeEvent -TimeCreated ([datetime]::new(2026, 8, 21, 14, 45, 0)) -Id 55 -Level 2 -ProviderName 'Ntfs' -Message 'The file system structure on volume C: cannot be corrected.')
            )
        })

        $lines.Count | Should -Be 3
        $lines[0] | Should -Be (Get-Translation 'DiskErrorEventsHeading')
        $lines[1] | Should -BeLike '2026-08-21 14:45*' -Because 'the newest fault comes first'
        $lines[1].Contains((Get-Translation 'EventLevelError')) | Should -BeTrue
        $lines[1].Contains('Ntfs') | Should -BeTrue
        $lines[2] | Should -BeLike '2026-08-19 03:00*'
        $lines[2].Contains((Get-Translation 'EventLevelWarning')) | Should -BeTrue
        $lines[2].Contains('Second line') | Should -BeFalse
        $lines[2] | Should -Be $lines[2].TrimEnd()
    }

    It 'says so when the System log holds no disk or file system fault' {
        $lines = @(Get-WtDiskErrorEventsLines -Width 95 -GetEvents { @() })

        $lines.Count | Should -Be 2
        $lines[0] | Should -Be (Get-Translation 'DiskErrorEventsHeading')
        $lines[1].Contains((Get-Translation 'DiskErrorEventsNone')) | Should -BeTrue
    }

    It 'treats the terminating "No events were found" error as the empty case' {
        $call = { Get-WtDiskErrorEventsLines -Width 95 -GetEvents { throw 'No events were found that match the specified selection criteria.' } }

        $call | Should -Not -Throw
        $lines = @(& $call)
        $lines.Count | Should -Be 2
        $lines[1].Contains((Get-Translation 'DiskErrorEventsNone')) | Should -BeTrue
    }

    It 'keeps Level inside the FilterHashtable, never in a later Where-Object' {
        $text = (Get-Command Get-WtDiskErrorEventsLines).ScriptBlock.Ast.Extent.Text

        $text -cmatch 'FilterHashtable\s*@\{[^}]*Level' | Should -BeTrue -Because '-MaxEvents is spent before any later filter runs'
        $text -cmatch 'Where-Object[^\r\n]*Level' | Should -BeFalse -Because 'filtering after -MaxEvents 40 throws the real faults away'
    }

    It 'asks all six storage providers for events' {
        $text = (Get-Command Get-WtDiskErrorEventsLines).ScriptBlock.Ast.Extent.Text

        foreach ($provider in @('disk', 'Ntfs', 'Microsoft-Windows-Ntfs', 'volmgr', 'storahci', 'stornvme')) {
            $text.Contains(("'" + $provider + "'")) | Should -BeTrue -Because "provider $provider is part of the measured filter"
        }
        $text.Contains('-ErrorAction SilentlyContinue') | Should -BeTrue -Because 'a provider missing on this machine must not be fatal'
    }
}

Describe 'Get-WtTopProcessesByMemoryLines' {
    It 'adds every instance of one program into a single row, biggest first' {
        $lines = @(Get-WtTopProcessesByMemoryLines -GetProcesses {
            @(
                [PSCustomObject]@{ ProcessName = 'chrome'; WorkingSet64 = [long]104857600 }
                [PSCustomObject]@{ ProcessName = 'chrome'; WorkingSet64 = [long]209715200 }
                [PSCustomObject]@{ ProcessName = 'chrome'; WorkingSet64 = [long]52428800 }
                [PSCustomObject]@{ ProcessName = 'explorer'; WorkingSet64 = [long]314572800 }
            )
        })

        $lines.Count | Should -Be 6
        $lines[0] | Should -Be (Get-Translation 'TopProcessesHeading')
        $lines[1].Contains((Get-Translation 'ColumnProcess')) | Should -BeTrue
        $lines[1].Contains((Get-Translation 'ColumnMemory')) | Should -BeTrue
        $lines[2].Contains('chrome') | Should -BeTrue -Because '350 MB of chrome outweighs 300 MB of explorer'
        $lines[2].Contains((Format-WtByteSize -Bytes 367001600)) | Should -BeTrue
        $lines[2] -cmatch '\s3\s' | Should -BeTrue -Because 'the instance count belongs in the row'
        $lines[3].Contains('explorer') | Should -BeTrue
        $lines[4] | Should -Be ''
        $lines[5].Contains((Format-WtByteSize -Bytes 681574400)) | Should -BeTrue
    }

    It 'honours -Top' {
        $lines = @(Get-WtTopProcessesByMemoryLines -Top 1 -GetProcesses {
            @(
                [PSCustomObject]@{ ProcessName = 'chrome'; WorkingSet64 = [long]209715200 }
                [PSCustomObject]@{ ProcessName = 'explorer'; WorkingSet64 = [long]104857600 }
            )
        })

        $lines.Count | Should -Be 5
        $lines[2].Contains('chrome') | Should -BeTrue
        $lines[2].Contains('explorer') | Should -BeFalse
    }

    It 'says process data is not available when nothing comes back' {
        $lines = @(Get-WtTopProcessesByMemoryLines -GetProcesses { @() })

        $lines.Count | Should -Be 1
        $lines[0] | Should -Be (Get-Translation 'TopProcessesNoneFound')
    }

    It 'says process data is not available when Get-Process throws' {
        $call = { Get-WtTopProcessesByMemoryLines -GetProcesses { throw 'Access is denied.' } }

        $call | Should -Not -Throw
        $lines = @(& $call)
        $lines.Count | Should -Be 1
        $lines[0] | Should -Be (Get-Translation 'TopProcessesNoneFound')
    }

    It 'groups names ordinally, so the Turkish dotless I cannot merge two programs' {
        $lines = @(Get-WtTopProcessesByMemoryLines -GetProcesses {
            @(
                [PSCustomObject]@{ ProcessName = 'ISLEM'; WorkingSet64 = [long]209715200 }
                [PSCustomObject]@{ ProcessName = 'islem'; WorkingSet64 = [long]104857600 }
            )
        })

        $lines.Count | Should -Be 6 -Because 'two different names must stay two rows'
        $lines[2].Contains('ISLEM') | Should -BeTrue
        $lines[3].Contains('islem') | Should -BeTrue
    }

    It 'has no CPU column and never reads the CPU property' {
        $lines = @(Get-WtTopProcessesByMemoryLines -GetProcesses {
            @( [PSCustomObject]@{ ProcessName = 'chrome'; WorkingSet64 = [long]104857600 } )
        })
        $text = (Get-Command Get-WtTopProcessesByMemoryLines).ScriptBlock.Ast.Extent.Text

        $lines[1].Contains('CPU') | Should -BeFalse
        $text -cmatch '\$\w+\.CPU' | Should -BeFalse -Because 'reading CPU throws Access Denied on a protected process'
    }
}

Describe 'Information > Events and diagnostics rows' {
    BeforeAll {
        $script:EventRowNames = @('RecentSystemErrors', 'BlueScreenHistory', 'DiskErrorEvents', 'TopProcessesByMemory')
        $script:EventRows = @(Get-WtTestInfoGroupRows -HeaderKey 'InfoGroupEventsDiagnostics')
    }

    It 'carries the four new rows, in catalogue order, each a captured action' {
        $names = @($EventRows | ForEach-Object { [string]$_.Name })

        foreach ($n in $EventRowNames) { $names | Should -Contain $n }
        [array]::IndexOf($names, 'RecentSystemErrors') | Should -BeLessThan ([array]::IndexOf($names, 'BlueScreenHistory'))
        [array]::IndexOf($names, 'BlueScreenHistory') | Should -BeLessThan ([array]::IndexOf($names, 'DiskErrorEvents'))
        [array]::IndexOf($names, 'DiskErrorEvents') | Should -BeLessThan ([array]::IndexOf($names, 'TopProcessesByMemory'))

        foreach ($n in $EventRowNames) {
            $row = @($EventRows | Where-Object { [string]$_.Name -ceq $n })[0]
            $row.Kind | Should -Be 'Action'
            $row.Data.Captured | Should -BeTrue -Because "$n streams its output into the panel"
            $row.Label | Should -Be (Get-Translation $n)
        }
    }

    It 'wires each row to its own pure lines function and calls nothing else' {
        $expected = @{
            'RecentSystemErrors'   = 'Get-WtRecentSystemErrorsLines'
            'BlueScreenHistory'    = 'Get-WtBlueScreenHistoryLines'
            'DiskErrorEvents'      = 'Get-WtDiskErrorEventsLines'
            'TopProcessesByMemory' = 'Get-WtTopProcessesByMemoryLines'
        }
        foreach ($n in $EventRowNames) {
            $row = @($EventRows | Where-Object { [string]$_.Name -ceq $n })[0]
            $text = $row.Data.Action.ToString()
            $text.Contains($expected[$n]) | Should -BeTrue -Because "$n must front its logic with a testable function"
            $text.Contains('Read-Host') | Should -BeFalse -Because "$n runs behind Invoke-WtCapturedAction and would deadlock"
        }
    }

    It 'changes no state: no write verb in any of the four scriptblocks' {
        foreach ($n in $EventRowNames) {
            $row = @($EventRows | Where-Object { [string]$_.Name -ceq $n })[0]
            $text = $row.Data.Action.ToString()
            foreach ($verb in @('Set-', 'Remove-', 'Stop-', 'Start-', 'Restart-', 'New-', 'Clear-', 'Disable-', 'Enable-')) {
                $text.Contains($verb) | Should -BeFalse -Because "$n is an information row"
            }
            $text.Contains('vssadmin') | Should -BeFalse
            $text.Contains('netsh') | Should -BeFalse
        }
    }

    It 'reads Windows through CIM only - no Get-WmiObject, no Win32_Product' {
        foreach ($fn in @('Get-WtRecentSystemErrorsLines', 'Get-WtBlueScreenHistoryLines', 'Get-WtDiskErrorEventsLines', 'Get-WtTopProcessesByMemoryLines')) {
            $text = (Get-Command $fn).ScriptBlock.Ast.Extent.Text
            $text.Contains('Get-WmiObject') | Should -BeFalse -Because 'Get-WmiObject does not exist in PowerShell 7'
            $text.Contains('Win32_Product') | Should -BeFalse -Because 'Win32_Product triggers MSI reconfiguration'
        }
    }
}

Describe 'Events and diagnostics translations' {
    AfterEach { $script:Language = 'EN' }

    It 'holds every new key in both dictionaries' {
        $keys = @(
            'RecentSystemErrors', 'BlueScreenHistory', 'DiskErrorEvents', 'TopProcessesByMemory'
            'RecentSystemErrorsHeading', 'EventsNoneFound', 'EventNoMessage'
            'EventLevelCritical', 'EventLevelError', 'EventLevelWarning'
            'BlueScreenHistoryHeading', 'BlueScreenNoneFound', 'BlueScreenTagBugCheck', 'BlueScreenTagPowerLoss'
            'BlueScreenTagUnexpectedShutdown'
            'CrashDumpsHeading', 'CrashDumpsNone', 'CrashDumpsSummary'
            'DiskErrorEventsHeading', 'DiskErrorEventsNone'
            'TopProcessesHeading', 'TopProcessesNoneFound', 'TopProcessesTotalLine'
            'ColumnProcess', 'ColumnInstances', 'ColumnMemory'
        )
        foreach ($key in $keys) {
            $script:Translations['EN'].ContainsKey($key) | Should -BeTrue -Because "EN needs '$key'"
            $script:Translations['TR'].ContainsKey($key) | Should -BeTrue -Because "TR needs '$key'"
        }
    }

    It 'keeps the four row labels translated, ASCII, and under 46 characters' {
        foreach ($key in @('RecentSystemErrors', 'BlueScreenHistory', 'DiskErrorEvents', 'TopProcessesByMemory')) {
            foreach ($lang in 'EN', 'TR') {
                $value = [string]$script:Translations[$lang][$key]
                $value.Length | Should -BeLessOrEqual 45 -Because "$lang '$key' must not be cut in the panel"
                foreach ($ch in $value.ToCharArray()) {
                    [int]$ch | Should -BeLessOrEqual 127 -Because "$lang '$key' must be ASCII-folded"
                }
            }
            $script:Translations['EN'][$key] | Should -Not -Be $script:Translations['TR'][$key] -Because "'$key' must actually be translated"
        }
    }

    It 'renders the Turkish panel without falling back to a blank line' {
        $script:Language = 'TR'

        $errors = @(Get-WtRecentSystemErrorsLines -Width 95 -GetEvents { @() })
        $errors[0] | Should -Be 'Gunlukte eslesen olay yok.'

        $bsod = @(Get-WtBlueScreenHistoryLines -Width 95 -GetBugchecks { @() } -GetPowerLoss { @() } -GetUnexpectedShutdowns { @() } -GetDumps { @() })
        $bsod[0] | Should -Be 'Durdurma hatalari ve beklenmedik guc kesintileri:'
        $bsod[4].Contains('Minidump dosyasi bulunamadi.') | Should -BeTrue

        $disk = @(Get-WtDiskErrorEventsLines -Width 95 -GetEvents { @() })
        $disk[0] | Should -Be 'Disk ve dosya sistemi olaylari, en yeni once:'

        $mem = @(Get-WtTopProcessesByMemoryLines -GetProcesses { @() })
        $mem[0] | Should -Be 'Islem verisi alinamadi.'
    }
}
