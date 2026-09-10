#Requires -Modules Pester

<#
.SYNOPSIS
    Coverage for the four System Summary information rows: Windows
    install/upgrade history, the pending-restart check, the time
    source and sync status, and the uptime/shutdown history. Every
    Windows source (registry, Get-Service, w32tm, Get-CimInstance,
    Get-WinEvent) is reached through an injectable scriptblock, so the
    tests here feed fixture objects shaped like the real output and
    never touch the live machine. Each function is proven twice: with
    data, and with the data missing or throwing. A fixture handed to
    an injected scriptblock through & needs its own $script: variable,
    never a same-named plain one: the callee's own local variable of
    that name would shadow it at the invocation site and the
    scriptblock would see an empty value.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath

    function script:New-FakeCurrentVersion {
        param(
            $InstallDate = 1628200267,
            $DisplayVersion = '21H2',
            $CurrentBuild = '19044',
            $UBR = 4291,
            $ProductName = 'Windows 10 IoT Enterprise LTSC'
        )
        [PSCustomObject]@{
            InstallDate    = $InstallDate
            DisplayVersion = $DisplayVersion
            CurrentBuild   = $CurrentBuild
            UBR            = $UBR
            ProductName    = $ProductName
        }
    }

    function script:New-FakeSourceOs {
        param(
            $ChildName = 'Source OS (Updated on 8/5/2021 22:31:07)',
            $InstallDate = 1590000000,
            $ProductName = 'Windows 10 Pro',
            $CurrentBuild = '18363',
            $ReleaseId = '1909'
        )
        [PSCustomObject]@{
            PSChildName  = $ChildName
            InstallDate  = $InstallDate
            ProductName  = $ProductName
            CurrentBuild = $CurrentBuild
            ReleaseId    = $ReleaseId
        }
    }

    function script:Get-ExpectedStamp {
        param([long]$Unix)
        ([datetimeoffset]::FromUnixTimeSeconds($Unix)).LocalDateTime.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
    }
}

Describe 'Get-WtWindowsUpgradeHistoryLines' {
    It 'reports the install date and the running build' {
        $lines = @(Get-WtWindowsUpgradeHistoryLines -GetCurrentVersion { New-FakeCurrentVersion } -GetSourceOsEntries { @() })
        $joined = $lines -join "`n"
        $joined | Should -Match ([regex]::Escape((Get-ExpectedStamp -Unix 1628200267)))
        $joined | Should -Match ([regex]::Escape('21H2'))
        $joined | Should -Match ([regex]::Escape('19044.4291'))
    }

    It 'says so plainly when no Source OS key exists (the common case)' {
        $lines = @(Get-WtWindowsUpgradeHistoryLines -GetCurrentVersion { New-FakeCurrentVersion } -GetSourceOsEntries { @() })
        $lines[-1] | Should -Be (Get-Translation 'UpgradeHistoryNone')
    }

    It 'lists Source OS keys oldest first' {
        $script:entries = @(
            (New-FakeSourceOs -ChildName 'Source OS (Updated on 8/5/2021 22:31:07)' -InstallDate 1628200267 -CurrentBuild '19042' -ReleaseId '20H2')
            (New-FakeSourceOs -ChildName 'Source OS (Updated on 5/20/2020 09:00:00)' -InstallDate 1590000000 -CurrentBuild '18363' -ReleaseId '1909')
        )
        $lines = @(Get-WtWindowsUpgradeHistoryLines -GetCurrentVersion { New-FakeCurrentVersion } -GetSourceOsEntries { $script:entries })
        $rows = @($lines | Where-Object { $_ -cmatch 'Windows 10 Pro' })
        $rows.Count | Should -Be 2
        $rows[0] | Should -Match ([regex]::Escape('18363'))
        $rows[1] | Should -Match ([regex]::Escape('19042'))
    }

    It 'falls back to the localized unknown-date text for a missing InstallDate' {
        $lines = @(Get-WtWindowsUpgradeHistoryLines -GetCurrentVersion { New-FakeCurrentVersion -InstallDate $null } -GetSourceOsEntries { @() })
        ($lines -join "`n") | Should -Match ([regex]::Escape((Get-Translation 'UpgradeHistoryDateUnknown')))
    }

    It 'returns a single not-available line when the registry read throws' {
        $lines = @(Get-WtWindowsUpgradeHistoryLines -GetCurrentVersion { throw 'registry unavailable' } -GetSourceOsEntries { @() })
        $lines.Count | Should -Be 1
        $lines[0] | Should -Be (Get-Translation 'UpgradeHistoryNotAvailable')
    }
}

Describe 'Get-WtPendingRebootLines' {
    It 'answers no while four file-rename entries are queued (the measured reference case)' {
        $lines = @(Get-WtPendingRebootLines `
            -GetCbsRebootPending { $false } `
            -GetWindowsUpdateRebootRequired { $false } `
            -GetActiveComputerName { 'WT-DESK' } `
            -GetPendingComputerName { 'WT-DESK' } `
            -GetPendingFileRenames { @('\??\C:\a.tmp', '!\??\C:\a.dll', '\??\C:\b.tmp', '!\??\C:\b.dll', '') })
        $lines[0] | Should -Be ('{0}: {1}' -f (Get-Translation 'PendingRebootHeader'), (Get-Translation 'AnswerNo'))
        $joined = $lines -join "`n"
        $joined | Should -Match ([regex]::Escape((Get-Translation 'PendingRebootNoFlags')))
        $joined | Should -Match ([regex]::Escape(((Get-Translation 'PendingRebootFileRenameLine') -f 4)))
    }

    It 'names the CBS flag when that is the one that is set' {
        $lines = @(Get-WtPendingRebootLines `
            -GetCbsRebootPending { $true } `
            -GetWindowsUpdateRebootRequired { $false } `
            -GetActiveComputerName { 'WT-DESK' } `
            -GetPendingComputerName { 'WT-DESK' } `
            -GetPendingFileRenames { @() })
        $lines[0] | Should -Be ('{0}: {1}' -f (Get-Translation 'PendingRebootHeader'), (Get-Translation 'AnswerYes'))
        $joined = $lines -join "`n"
        $joined | Should -Match ([regex]::Escape((Get-Translation 'PendingRebootReasonCbs')))
        $joined | Should -Not -Match ([regex]::Escape((Get-Translation 'PendingRebootReasonWindowsUpdate')))
    }

    It 'names the Windows Update flag when that is the one that is set' {
        $lines = @(Get-WtPendingRebootLines `
            -GetCbsRebootPending { $false } `
            -GetWindowsUpdateRebootRequired { $true } `
            -GetActiveComputerName { 'WT-DESK' } `
            -GetPendingComputerName { 'WT-DESK' } `
            -GetPendingFileRenames { @() })
        $lines[0] | Should -Be ('{0}: {1}' -f (Get-Translation 'PendingRebootHeader'), (Get-Translation 'AnswerYes'))
        $joined = $lines -join "`n"
        $joined | Should -Match ([regex]::Escape((Get-Translation 'PendingRebootReasonWindowsUpdate')))
        $joined | Should -Not -Match ([regex]::Escape((Get-Translation 'PendingRebootReasonCbs')))
    }

    It 'names both the old and the new computer name when they differ' {
        $lines = @(Get-WtPendingRebootLines `
            -GetCbsRebootPending { $false } `
            -GetWindowsUpdateRebootRequired { $false } `
            -GetActiveComputerName { 'OLD-PC' } `
            -GetPendingComputerName { 'NEW-PC' } `
            -GetPendingFileRenames { @() })
        $lines[0] | Should -Be ('{0}: {1}' -f (Get-Translation 'PendingRebootHeader'), (Get-Translation 'AnswerYes'))
        $joined = $lines -join "`n"
        $joined | Should -Match 'OLD-PC'
        $joined | Should -Match 'NEW-PC'
    }

    It 'does not call a case-only difference a rename, even under tr-TR' {
        $old = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            $lines = @(Get-WtPendingRebootLines `
                -GetCbsRebootPending { $false } `
                -GetWindowsUpdateRebootRequired { $false } `
                -GetActiveComputerName { 'ISIK-PC' } `
                -GetPendingComputerName { 'isik-pc' } `
                -GetPendingFileRenames { @() })
            $lines[0] | Should -Be ('{0}: {1}' -f (Get-Translation 'PendingRebootHeader'), (Get-Translation 'AnswerNo'))
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $old }
    }

    It 'still answers, and says what it could not read, when every registry read throws' {
        $lines = @(Get-WtPendingRebootLines `
            -GetCbsRebootPending { throw 'access denied' } `
            -GetWindowsUpdateRebootRequired { throw 'access denied' } `
            -GetActiveComputerName { throw 'access denied' } `
            -GetPendingComputerName { throw 'access denied' } `
            -GetPendingFileRenames { throw 'access denied' })
        $lines[0] | Should -Be ('{0}: {1}' -f (Get-Translation 'PendingRebootHeader'), (Get-Translation 'AnswerNo'))
        $lines[-1] | Should -Be (Get-Translation 'PendingRebootFileRenameUnavailable')
    }
}

Describe 'Get-WtTimeSyncLines' {
    It 'prints local time, UTC and the time zone before anything else' {
        $now = [datetime]'2026-08-23T14:05:00'
        $lines = @(Get-WtTimeSyncLines `
            -GetNow { $now } `
            -GetTimeZoneName { '(UTC+03:00) Istanbul' } `
            -GetTimeService { [PSCustomObject]@{ Status = 'Running' } } `
            -GetTimeSource { 'time.windows.com' } `
            -GetTimeStatus { @('Leap Indicator: 0(no warning)', 'Last Successful Sync Time: 8/23/2026 1:00:00 PM') })
        $lines[0] | Should -Be ('{0}: {1}' -f (Get-Translation 'TimeSyncLocalTime'), '2026-08-23 14:05:00')
        $lines[1] | Should -Match ([regex]::Escape((Get-Translation 'TimeSyncUtcTime')))
        $lines[2] | Should -Be ('{0}: {1}' -f (Get-Translation 'TimeSyncTimeZone'), '(UTC+03:00) Istanbul')
        $joined = $lines -join "`n"
        $joined | Should -Match ([regex]::Escape('time.windows.com'))
        $joined | Should -Match ([regex]::Escape('Last Successful Sync Time'))
    }

    It 'never calls w32tm while the W32Time service is stopped' {
        $lines = @(Get-WtTimeSyncLines `
            -GetNow { [datetime]'2026-08-23T14:05:00' } `
            -GetTimeZoneName { '(UTC+03:00) Istanbul' } `
            -GetTimeService { [PSCustomObject]@{ Status = 'Stopped' } } `
            -GetTimeSource { throw 'w32tm must not run with the service stopped' } `
            -GetTimeStatus { throw 'w32tm must not run with the service stopped' })
        $lines[-1] | Should -Be (Get-Translation 'TimeSyncServiceStopped')
    }

    It 'says the service is missing when Get-Service finds nothing' {
        $lines = @(Get-WtTimeSyncLines `
            -GetNow { [datetime]'2026-08-23T14:05:00' } `
            -GetTimeZoneName { '(UTC+03:00) Istanbul' } `
            -GetTimeService { $null } `
            -GetTimeSource { throw 'w32tm must not run without the service' } `
            -GetTimeStatus { throw 'w32tm must not run without the service' })
        $lines[-1] | Should -Be (Get-Translation 'TimeSyncServiceMissing')
    }

    It 'reports w32tm silence instead of printing a blank block' {
        $lines = @(Get-WtTimeSyncLines `
            -GetNow { [datetime]'2026-08-23T14:05:00' } `
            -GetTimeZoneName { '(UTC+03:00) Istanbul' } `
            -GetTimeService { [PSCustomObject]@{ Status = 'Running' } } `
            -GetTimeSource { '' } `
            -GetTimeStatus { @() })
        $joined = $lines -join "`n"
        $joined | Should -Match ([regex]::Escape((Get-Translation 'TimeSyncNotAvailable')))
    }

    It 'falls back to a readable line when the time zone cannot be read' {
        $lines = @(Get-WtTimeSyncLines `
            -GetNow { [datetime]'2026-08-23T14:05:00' } `
            -GetTimeZoneName { throw 'no zone' } `
            -GetTimeService { $null } `
            -GetTimeSource { throw 'unused' } `
            -GetTimeStatus { throw 'unused' })
        $lines[2] | Should -Be ('{0}: {1}' -f (Get-Translation 'TimeSyncTimeZone'), (Get-Translation 'TimeSyncZoneUnknown'))
    }

    It 'formats the clock the same way under tr-TR' {
        $old = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            $lines = @(Get-WtTimeSyncLines `
                -GetNow { [datetime]'2026-08-23T14:05:00' } `
                -GetTimeZoneName { '(UTC+03:00) Istanbul' } `
                -GetTimeService { $null } `
                -GetTimeSource { throw 'unused' } `
                -GetTimeStatus { throw 'unused' })
            $lines[0] | Should -Match '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $old }
    }
}

Describe 'Get-WtShutdownHistoryLines' {
    BeforeAll {
        function script:New-FakeShutdownEvent {
            param([int]$Id, [datetime]$TimeCreated, [string]$Message = '')
            [PSCustomObject]@{ Id = $Id; TimeCreated = $TimeCreated; Message = $Message }
        }
        $script:Boot = [datetime]'2026-08-23T09:00:00'
        $script:Now = [datetime]'2026-08-23T12:34:00'
    }

    It 'leads with the last boot time, the uptime and the Fast Startup footnote' {
        $lines = @(Get-WtShutdownHistoryLines -GetOs { [PSCustomObject]@{ LastBootUpTime = $script:Boot } } -GetNow { $script:Now } -GetEvents { @() })
        $lines[0] | Should -Be ('{0}: {1}' -f (Get-Translation 'ShutdownLastBoot'), '2026-08-23 09:00:00')
        $lines[1] | Should -Be ('{0}: {1}' -f (Get-Translation 'ShutdownUptime'), ((Get-Translation 'ShutdownUptimeValue') -f 0, 3, 34))
        $lines[2] | Should -Be (Get-Translation 'ShutdownFastStartupNote')
    }

    It 'reads the 1074 story from the first line of Message, newest row first' {
        $message = "The process C:\Windows\System32\shutdown.exe (WT-DESK) has initiated the restart of computer WT-DESK on behalf of user WT-DESK\burak for the following reason: Other (Planned)`r`nReason Code: 0x85000000`r`nShutdown Type: restart"
        $script:events = @(
            (New-FakeShutdownEvent -Id 6005 -TimeCreated ([datetime]'2026-08-23T09:00:05'))
            (New-FakeShutdownEvent -Id 6006 -TimeCreated ([datetime]'2026-08-23T08:58:00'))
            (New-FakeShutdownEvent -Id 1074 -TimeCreated ([datetime]'2026-08-23T08:57:30') -Message $message)
        )
        $lines = @(Get-WtShutdownHistoryLines -GetOs { [PSCustomObject]@{ LastBootUpTime = $script:Boot } } -GetNow { $script:Now } -GetEvents { $script:events })
        $rows = @($lines | Where-Object { $_ -cmatch '^  \d{4}-\d{2}-\d{2} ' })
        $rows.Count | Should -Be 3
        $rows[0] | Should -Match ([regex]::Escape((Get-Translation 'ShutdownEventLogStarted')))
        $rows[1] | Should -Match ([regex]::Escape((Get-Translation 'ShutdownEventLogStopped')))
        $rows[2] | Should -Match ([regex]::Escape((Get-Translation 'ShutdownEventRequested')))
        $rows[2] | Should -Match ([regex]::Escape('Other (Planned)'))
        $rows[2] | Should -Not -Match ([regex]::Escape('Reason Code'))
    }

    It 'says the log was trimmed when Get-WinEvent finds nothing to return' {
        $lines = @(Get-WtShutdownHistoryLines -GetOs { [PSCustomObject]@{ LastBootUpTime = $script:Boot } } -GetNow { $script:Now } -GetEvents { throw 'No events were found that match the specified selection criteria.' })
        ($lines -join "`n") | Should -Match ([regex]::Escape((Get-Translation 'ShutdownHistoryNone')))
        $lines[0] | Should -Match ([regex]::Escape((Get-Translation 'ShutdownLastBoot')))
    }

    It 'keeps the history section when the boot time cannot be read' {
        $lines = @(Get-WtShutdownHistoryLines -GetOs { throw 'cim unavailable' } -GetNow { $script:Now } -GetEvents { @((New-FakeShutdownEvent -Id 6006 -TimeCreated ([datetime]'2026-08-23T08:58:00'))) })
        $lines[0] | Should -Be (Get-Translation 'ShutdownBootTimeUnavailable')
        ($lines -join "`n") | Should -Match ([regex]::Escape((Get-Translation 'ShutdownEventLogStopped')))
    }

    It 'says so when a 1074 record carries no message text' {
        $lines = @(Get-WtShutdownHistoryLines -GetOs { [PSCustomObject]@{ LastBootUpTime = $script:Boot } } -GetNow { $script:Now } -GetEvents { @((New-FakeShutdownEvent -Id 1074 -TimeCreated ([datetime]'2026-08-23T08:57:30') -Message '')) })
        ($lines -join "`n") | Should -Match ([regex]::Escape((Get-Translation 'ShutdownMessageUnavailable')))
    }

    It 'points 6008 and 41 at the blue screen row instead of listing them here' {
        $lines = @(Get-WtShutdownHistoryLines -GetOs { [PSCustomObject]@{ LastBootUpTime = $script:Boot } } -GetNow { $script:Now } -GetEvents { @() })
        $lines[-1] | Should -Be (Get-Translation 'ShutdownBugcheckElsewhere')
    }

    It 'caps the list at -MaxRows rows' {
        $script:events = @(1..12 | ForEach-Object { New-FakeShutdownEvent -Id 6005 -TimeCreated ([datetime]'2026-08-23T09:00:00').AddMinutes(-$_) })
        $lines = @(Get-WtShutdownHistoryLines -GetOs { [PSCustomObject]@{ LastBootUpTime = $script:Boot } } -GetNow { $script:Now } -GetEvents { $script:events } -MaxRows 3)
        @($lines | Where-Object { $_ -cmatch '^  \d{4}-\d{2}-\d{2} ' }).Count | Should -Be 3
    }
}

Describe 'System Summary rows are wired into the Information screen' {
    BeforeAll {
        $script:NewNames = @('WindowsUpgradeHistory', 'PendingRebootCheck', 'ShowTimeSyncStatus', 'ShutdownHistory')
        $script:AllItems = @(Get-WtInfoToolsItems)
        $script:AllNames = @($script:AllItems | ForEach-Object { [string]$_.Name })
    }

    It 'adds all four rows, each exactly once' {
        foreach ($name in $script:NewNames) {
            @($script:AllNames | Where-Object { $_ -ceq $name }).Count | Should -Be 1 -Because "$name must appear once"
        }
    }

    It 'keeps them in catalogue order inside the System Summary group' {
        $version = [array]::IndexOf($script:AllNames, 'ShowWindowsVersion')
        $upgrade = [array]::IndexOf($script:AllNames, 'WindowsUpgradeHistory')
        $reboot = [array]::IndexOf($script:AllNames, 'PendingRebootCheck')
        $time = [array]::IndexOf($script:AllNames, 'ShowTimeSyncStatus')
        $shutdown = [array]::IndexOf($script:AllNames, 'ShutdownHistory')
        $version | Should -BeLessThan $upgrade
        $upgrade | Should -BeLessThan $reboot
        $reboot | Should -BeLessThan $time
        $time | Should -BeLessThan $shutdown
    }

    It 'renders every one of them inside the box' {
        foreach ($name in $script:NewNames) {
            $row = @($script:AllItems | Where-Object { $_.Name -ceq $name })[0]
            $row.Kind | Should -Be 'Action'
            $row.Data.Captured | Should -BeTrue -Because "$name must stream into the panel"
            $row.Data.Action -is [scriptblock] | Should -BeTrue
        }
    }

    It 'never asks with Read-Host behind the capture and never writes state' {
        foreach ($name in $script:NewNames) {
            $row = @($script:AllItems | Where-Object { $_.Name -ceq $name })[0]
            $text = $row.Data.Action.ToString()
            $text | Should -Not -Match 'Read-Host' -Because "$name is captured and would deadlock"
            $text | Should -Not -MatchExactly '\b(Set|Remove|Stop|Start|Restart|New|Clear|Disable|Enable)-' -Because "$name is an information row"
        }
    }

    It 'labels every row in both languages, inside the 45-character panel budget' {
        $old = $script:Language
        try {
            foreach ($lang in 'EN', 'TR') {
                $script:Language = $lang
                foreach ($name in $script:NewNames) {
                    $label = Get-Translation $name
                    $label | Should -Not -BeNullOrEmpty -Because "$lang needs a label for $name"
                    $label.Length | Should -BeLessOrEqual 45 -Because "$lang label for $name must fit the panel"
                }
            }
        }
        finally { $script:Language = $old }
    }
}
