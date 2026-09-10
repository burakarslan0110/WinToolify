#Requires -Modules Pester

<#
.SYNOPSIS
    Coverage for Information > Software and startup. The four pure
    line builders (installed programs, startup entries, non-Microsoft
    scheduled tasks, installed updates), the fixed-width cell formatter
    they share, and the StartupApproved enabled/disabled rule. Every
    Windows source (registry hives, Get-ScheduledTask, Get-HotFix) is
    behind an injectable scriptblock, so nothing here touches the real
    machine. Both halves of "honest degradation" are covered for each
    builder: data present, and data absent or throwing.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
    $script:Language = 'EN'
}

Describe 'Format-WtSoftwareCell' {
    It 'pads a short value out to the column width' {
        Format-WtSoftwareCell -Text 'abc' -Width 6 | Should -Be 'abc   '
    }

    It 'truncates a long value with the same tilde the panel uses' {
        Format-WtSoftwareCell -Text 'abcdefgh' -Width 5 | Should -Be 'abcd~'
    }

    It 'folds newlines and tabs, so a Run command line cannot tear the table apart' {
        Format-WtSoftwareCell -Text "a`r`nb" -Width 6 | Should -Be 'a b   '
        Format-WtSoftwareCell -Text "a`tb" -Width 6 | Should -Be 'a b   '
    }

    It 'turns a missing value into blanks instead of dying' {
        Format-WtSoftwareCell -Text $null -Width 3 | Should -Be '   '
        Format-WtSoftwareCell -Text '' -Width 3 | Should -Be '   '
    }

    It 'returns nothing for a non-positive width' {
        Format-WtSoftwareCell -Text 'abc' -Width 0 | Should -Be ''
    }
}

Describe 'Get-WtInstalledProgramsLines' {
    BeforeAll {
        function script:New-FakeUninstallEntry {
            param(
                $DisplayName,
                $DisplayVersion = '1.0',
                $Publisher = 'Acme',
                $SystemComponent = $null,
                $ParentKeyName = $null,
                $ReleaseType = $null
            )
            [PSCustomObject]@{
                DisplayName     = $DisplayName
                DisplayVersion  = $DisplayVersion
                Publisher       = $Publisher
                SystemComponent = $SystemComponent
                ParentKeyName   = $ParentKeyName
                ReleaseType     = $ReleaseType
            }
        }
    }

    BeforeEach {
        $script:ProgramSources = @{}
    }

    It 'lists machine, 32-bit and per-user programs in one alphabetical table' {
        $script:ProgramSources = @{
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' = @(
                (New-FakeUninstallEntry -DisplayName 'Zed Suite' -DisplayVersion '3.1' -Publisher 'Zed Ltd')
            )
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' = @(
                (New-FakeUninstallEntry -DisplayName 'Alpha Tool' -DisplayVersion '2.0' -Publisher 'Alpha Inc')
            )
            'Registry::HKEY_USERS\S-1-5-21-9\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' = @(
                (New-FakeUninstallEntry -DisplayName 'iTunes' -DisplayVersion '12.0' -Publisher 'Apple')
            )
        }
        $getEntries = { param($Path) if ($script:ProgramSources.ContainsKey($Path)) { , @($script:ProgramSources[$Path]) } else { , @() } }
        $lines = Get-WtInstalledProgramsLines -Width 95 -GetUserSid { 'S-1-5-21-9' } -GetUninstallEntries $getEntries

        $lines[0] | Should -Be 'Desktop programs found: 3'
        $text = $lines -join "`n"
        $text | Should -CMatch 'Alpha Tool'
        $text | Should -CMatch 'iTunes'
        $text | Should -CMatch 'Zed Suite'
        $text | Should -CMatch 'Apple'
        $alpha = ($lines | Select-String -SimpleMatch 'Alpha Tool' | Select-Object -First 1).LineNumber
        $itunes = ($lines | Select-String -SimpleMatch 'iTunes' | Select-Object -First 1).LineNumber
        $zed = ($lines | Select-String -SimpleMatch 'Zed Suite' | Select-Object -First 1).LineNumber
        $alpha | Should -BeLessThan $itunes
        $itunes | Should -BeLessThan $zed
    }

    It 'drops system components, update child keys, update release types and nameless entries' {
        $script:ProgramSources = @{
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' = @(
                (New-FakeUninstallEntry -DisplayName 'Real App')
                (New-FakeUninstallEntry -DisplayName 'Hidden Component' -SystemComponent 1)
                (New-FakeUninstallEntry -DisplayName 'KB5001234' -ParentKeyName 'Office16')
                (New-FakeUninstallEntry -DisplayName 'Security Patch' -ReleaseType 'Security Update')
                (New-FakeUninstallEntry -DisplayName '   ')
            )
        }
        $getEntries = { param($Path) if ($script:ProgramSources.ContainsKey($Path)) { , @($script:ProgramSources[$Path]) } else { , @() } }
        $lines = Get-WtInstalledProgramsLines -Width 95 -GetUserSid { 'S-1-5-21-9' } -GetUninstallEntries $getEntries

        $lines[0] | Should -Be 'Desktop programs found: 1'
        $text = $lines -join "`n"
        $text | Should -CMatch 'Real App'
        $text | Should -Not -CMatch 'Hidden Component'
        $text | Should -Not -CMatch 'KB5001234'
        $text | Should -Not -CMatch 'Security Patch'
    }

    It 'shows a program installed in both the 64-bit and the 32-bit key only once' {
        $script:ProgramSources = @{
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' = @(
                (New-FakeUninstallEntry -DisplayName 'Shared App' -DisplayVersion '5.5')
            )
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' = @(
                (New-FakeUninstallEntry -DisplayName 'Shared App' -DisplayVersion '5.5')
            )
        }
        $getEntries = { param($Path) if ($script:ProgramSources.ContainsKey($Path)) { , @($script:ProgramSources[$Path]) } else { , @() } }
        $lines = Get-WtInstalledProgramsLines -Width 95 -GetUserSid { $null } -GetUninstallEntries $getEntries

        $lines[0] | Should -Be 'Desktop programs found: 1'
    }

    It 'says the user hive is missing instead of silently hiding per-user installs' {
        $script:ProgramSources = @{
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' = @((New-FakeUninstallEntry -DisplayName 'Real App'))
        }
        $getEntries = { param($Path) if ($script:ProgramSources.ContainsKey($Path)) { , @($script:ProgramSources[$Path]) } else { , @() } }
        $lines = Get-WtInstalledProgramsLines -Width 95 -GetUserSid { $null } -GetUninstallEntries $getEntries

        $lines | Should -Contain 'The signed-in user''s hive could not be read: per-user installs are not listed.'
    }

    It 'says so when no uninstall key holds a program' {
        $lines = Get-WtInstalledProgramsLines -Width 95 -GetUserSid { 'S-1-5-21-9' } -GetUninstallEntries { param($Path) , @() }
        $lines | Should -Contain 'No installed program was found in the uninstall keys.'
    }

    It 'still prints what it did read when one hive throws' {
        $script:ProgramSources = @{
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' = @((New-FakeUninstallEntry -DisplayName 'Only One'))
        }
        $getEntries = { param($Path) if ($script:ProgramSources.ContainsKey($Path)) { , @($script:ProgramSources[$Path]) } else { throw 'Access is denied' } }
        $lines = Get-WtInstalledProgramsLines -Width 95 -GetUserSid { 'S-1-5-21-9' } -GetUninstallEntries $getEntries

        ($lines -join "`n") | Should -CMatch 'Only One'
    }

    It 'measures its columns against the panel width, not a hard-coded 100' {
        $script:ProgramSources = @{
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' = @(
                (New-FakeUninstallEntry -DisplayName ('X' * 200) -DisplayVersion ('9' * 40) -Publisher ('P' * 90))
            )
        }
        $getEntries = { param($Path) if ($script:ProgramSources.ContainsKey($Path)) { , @($script:ProgramSources[$Path]) } else { , @() } }
        $lines = Get-WtInstalledProgramsLines -Width 95 -GetUserSid { $null } -GetUninstallEntries $getEntries

        foreach ($line in $lines) { $line.Length | Should -BeLessOrEqual 95 }
    }

    It 'never reaches for the MSI product class or the retired WMI cmdlet' {
        $src = (Get-Command Get-WtInstalledProgramsLines).ScriptBlock.ToString()
        $src | Should -Not -CMatch 'Win32_Product'
        $src | Should -Not -CMatch 'Get-WmiObject'
    }

    It 'reads all three uninstall roots' {
        $src = (Get-Command Get-WtInstalledProgramsLines).ScriptBlock.ToString()
        $src | Should -CMatch 'WOW6432Node'
        $src | Should -CMatch 'HKEY_USERS'
    }
}

Describe 'Test-WtStartupEntryEnabled' {
    It 'reads 0x02 and 0x06 as enabled' {
        Test-WtStartupEntryEnabled -ApprovalValue ([byte[]]@(2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) | Should -BeTrue
        Test-WtStartupEntryEnabled -ApprovalValue ([byte[]]@(6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) | Should -BeTrue
    }

    It 'reads 0x03, 0x05 and 0x07 as disabled - the low bit means OFF, not ON' {
        foreach ($first in 3, 5, 7) {
            Test-WtStartupEntryEnabled -ApprovalValue ([byte[]]@($first, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) | Should -BeFalse -Because "first byte $first"
        }
    }

    It 'treats a missing or empty approval value as enabled' {
        Test-WtStartupEntryEnabled -ApprovalValue $null | Should -BeTrue
        Test-WtStartupEntryEnabled -ApprovalValue ([byte[]]@()) | Should -BeTrue
    }

    It 'treats a value it cannot read as enabled rather than lying' {
        Test-WtStartupEntryEnabled -ApprovalValue 'not bytes' | Should -BeTrue
    }
}

Describe 'Get-WtStartupProgramsLines' {
    BeforeEach {
        $script:RunValues = @{}
        $script:ApprovalValues = @{}
        $script:FolderItems = @{}
    }

    It 'lists Run entries from the machine hive and the interactive user hive' {
        $script:RunValues = @{
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' = @{ 'SecurityHealth' = 'C:\Windows\System32\SecurityHealthSystray.exe' }
            'Registry::HKEY_USERS\S-1-5-21-9\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' = @{ 'OneDrive' = 'C:\Users\ali\AppData\Local\Microsoft\OneDrive\OneDrive.exe /background' }
        }
        $getValues = { param($Path) if ($script:RunValues.ContainsKey($Path)) { $script:RunValues[$Path] } else { @{} } }
        $getApproval = { param($Path) if ($script:ApprovalValues.ContainsKey($Path)) { $script:ApprovalValues[$Path] } else { @{} } }
        $getFolder = { param($Path) , @() }
        $lines = Get-WtStartupProgramsLines -Width 95 -GetUserSid { 'S-1-5-21-9' } -GetValueMap $getValues -GetApprovalMap $getApproval -GetFolderEntries $getFolder -GetUserProfilePath { param($Sid) $null } -CommonStartup 'C:\ProgramData\Startup'

        $lines[0] | Should -Be 'Startup entries: 2 (2 enabled, 0 disabled)'
        $text = $lines -join "`n"
        $text | Should -CMatch 'SecurityHealth'
        $text | Should -CMatch 'OneDrive'
        $text | Should -CMatch 'HKLM Run'
        $text | Should -CMatch 'HKU Run'
    }

    It 'calls an entry disabled when StartupApproved in the user hive says so' {
        $script:RunValues = @{
            'Registry::HKEY_USERS\S-1-5-21-9\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' = @{ 'OneDrive' = 'C:\OneDrive.exe' }
        }
        $script:ApprovalValues = @{
            'Registry::HKEY_USERS\S-1-5-21-9\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' = @{ 'OneDrive' = [byte[]]@(3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) }
        }
        $getValues = { param($Path) if ($script:RunValues.ContainsKey($Path)) { $script:RunValues[$Path] } else { @{} } }
        $getApproval = { param($Path) if ($script:ApprovalValues.ContainsKey($Path)) { $script:ApprovalValues[$Path] } else { @{} } }
        $getFolder = { param($Path) , @() }
        $lines = Get-WtStartupProgramsLines -Width 95 -GetUserSid { 'S-1-5-21-9' } -GetValueMap $getValues -GetApprovalMap $getApproval -GetFolderEntries $getFolder -GetUserProfilePath { param($Sid) $null } -CommonStartup 'C:\ProgramData\Startup'

        $lines[0] | Should -Be 'Startup entries: 1 (0 enabled, 1 disabled)'
        ($lines -join "`n") | Should -CMatch 'Disabled'
    }

    It 'calls a 0x06 entry enabled - the byte is not a simple on/off flag' {
        $script:RunValues = @{
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' = @{ 'Vendor' = 'C:\vendor.exe' }
        }
        $script:ApprovalValues = @{
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' = @{ 'Vendor' = [byte[]]@(6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) }
        }
        $getValues = { param($Path) if ($script:RunValues.ContainsKey($Path)) { $script:RunValues[$Path] } else { @{} } }
        $getApproval = { param($Path) if ($script:ApprovalValues.ContainsKey($Path)) { $script:ApprovalValues[$Path] } else { @{} } }
        $getFolder = { param($Path) , @() }
        $lines = Get-WtStartupProgramsLines -Width 95 -GetUserSid { $null } -GetValueMap $getValues -GetApprovalMap $getApproval -GetFolderEntries $getFolder -GetUserProfilePath { param($Sid) $null } -CommonStartup 'C:\ProgramData\Startup'

        $lines[0] | Should -Be 'Startup entries: 1 (1 enabled, 0 disabled)'
    }

    It 'reads the 32-bit Run key through the Run32 approval key' {
        $script:RunValues = @{
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' = @{ 'Legacy' = 'C:\legacy.exe' }
        }
        $script:ApprovalValues = @{
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' = @{ 'Legacy' = [byte[]]@(3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) }
        }
        $getValues = { param($Path) if ($script:RunValues.ContainsKey($Path)) { $script:RunValues[$Path] } else { @{} } }
        $getApproval = { param($Path) if ($script:ApprovalValues.ContainsKey($Path)) { $script:ApprovalValues[$Path] } else { @{} } }
        $getFolder = { param($Path) , @() }
        $lines = Get-WtStartupProgramsLines -Width 95 -GetUserSid { $null } -GetValueMap $getValues -GetApprovalMap $getApproval -GetFolderEntries $getFolder -GetUserProfilePath { param($Sid) $null } -CommonStartup 'C:\ProgramData\Startup'

        $lines[0] | Should -Be 'Startup entries: 1 (0 enabled, 1 disabled)'
        ($lines -join "`n") | Should -CMatch 'HKLM32 Run'
    }

    It 'reads both Startup folders, the common one and the interactive user profile one' {
        $script:FolderItems = @{
            'C:\ProgramData\Startup' = @([PSCustomObject]@{ Name = 'Vendor.lnk'; Command = 'C:\ProgramData\Startup\Vendor.lnk' })
            'C:\Users\ali\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup' = @([PSCustomObject]@{ Name = 'Notes.lnk'; Command = 'C:\Users\ali\Notes.lnk' })
        }
        $script:ApprovalValues = @{
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' = @{ 'Vendor.lnk' = [byte[]]@(3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) }
        }
        $getValues = { param($Path) @{} }
        $getApproval = { param($Path) if ($script:ApprovalValues.ContainsKey($Path)) { $script:ApprovalValues[$Path] } else { @{} } }
        $getFolder = { param($Path) if ($script:FolderItems.ContainsKey($Path)) { , @($script:FolderItems[$Path]) } else { , @() } }
        $lines = Get-WtStartupProgramsLines -Width 95 -GetUserSid { 'S-1-5-21-9' } -GetValueMap $getValues -GetApprovalMap $getApproval -GetFolderEntries $getFolder -GetUserProfilePath { param($Sid) 'C:\Users\ali' } -CommonStartup 'C:\ProgramData\Startup'

        $lines[0] | Should -Be 'Startup entries: 2 (1 enabled, 1 disabled)'
        $text = $lines -join "`n"
        $text | Should -CMatch 'Startup \(all\)'
        $text | Should -CMatch 'Startup \(user\)'
        $text | Should -CMatch 'Notes.lnk'
    }

    It 'flattens two shortcuts from a SINGLE Startup-folder call instead of merging them into one row' {
        $script:FolderItems = @{
            'C:\ProgramData\Startup' = @(
                [PSCustomObject]@{ Name = 'Alpha.lnk'; Command = 'C:\ProgramData\Startup\Alpha.lnk' }
                [PSCustomObject]@{ Name = 'Beta.lnk'; Command = 'C:\ProgramData\Startup\Beta.lnk' }
            )
        }
        $getValues = { param($Path) @{} }
        $getApproval = { param($Path) @{} }
        $getFolder = { param($Path) if ($script:FolderItems.ContainsKey($Path)) { , @($script:FolderItems[$Path]) } else { , @() } }
        $lines = Get-WtStartupProgramsLines -Width 95 -GetUserSid { $null } -GetValueMap $getValues -GetApprovalMap $getApproval -GetFolderEntries $getFolder -GetUserProfilePath { param($Sid) $null } -CommonStartup 'C:\ProgramData\Startup'

        $lines[0] | Should -Be 'Startup entries: 2 (2 enabled, 0 disabled)'
        $text = $lines -join "`n"
        $text | Should -CMatch 'Alpha.lnk'
        $text | Should -CMatch 'Beta.lnk'
        $alpha = ($lines | Select-String -SimpleMatch 'Alpha.lnk' | Select-Object -First 1).LineNumber
        $beta = ($lines | Select-String -SimpleMatch 'Beta.lnk' | Select-Object -First 1).LineNumber
        $alpha | Should -Not -Be $beta -Because 'each shortcut must land on its own row, not merged into one'
        $text | Should -Not -CMatch 'Alpha.lnk Beta.lnk'
        $text | Should -Not -CMatch 'Beta.lnk Alpha.lnk'
    }

    It 'says the user hive is missing instead of pretending the machine keys are the whole story' {
        $script:RunValues = @{
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' = @{ 'Vendor' = 'C:\vendor.exe' }
        }
        $getValues = { param($Path) if ($script:RunValues.ContainsKey($Path)) { $script:RunValues[$Path] } else { @{} } }
        $getApproval = { param($Path) @{} }
        $getFolder = { param($Path) , @() }
        $lines = Get-WtStartupProgramsLines -Width 95 -GetUserSid { $null } -GetValueMap $getValues -GetApprovalMap $getApproval -GetFolderEntries $getFolder -GetUserProfilePath { param($Sid) $null } -CommonStartup 'C:\ProgramData\Startup'

        $lines | Should -Contain 'The signed-in user''s hive could not be read: only machine-wide entries are listed.'
    }

    It 'says so when nothing starts at sign-in' {
        $getValues = { param($Path) @{} }
        $getApproval = { param($Path) @{} }
        $getFolder = { param($Path) , @() }
        $lines = Get-WtStartupProgramsLines -Width 95 -GetUserSid { 'S-1-5-21-9' } -GetValueMap $getValues -GetApprovalMap $getApproval -GetFolderEntries $getFolder -GetUserProfilePath { param($Sid) 'C:\Users\ali' } -CommonStartup 'C:\ProgramData\Startup'

        $lines | Should -Contain 'No startup entry was found.'
    }

    It 'survives a key that throws and keeps the rest of the list' {
        $script:RunValues = @{
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' = @{ 'Vendor' = 'C:\vendor.exe' }
        }
        $getValues = { param($Path) if ($script:RunValues.ContainsKey($Path)) { $script:RunValues[$Path] } else { throw 'Access is denied' } }
        $getApproval = { param($Path) throw 'Access is denied' }
        $getFolder = { param($Path) throw 'Access is denied' }
        $lines = Get-WtStartupProgramsLines -Width 95 -GetUserSid { 'S-1-5-21-9' } -GetValueMap $getValues -GetApprovalMap $getApproval -GetFolderEntries $getFolder -GetUserProfilePath { param($Sid) 'C:\Users\ali' } -CommonStartup 'C:\ProgramData\Startup'

        ($lines -join "`n") | Should -CMatch 'Vendor'
    }

    It 'truncates the command column to the panel width' {
        $script:RunValues = @{
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' = @{ 'Vendor' = ('C:\' + ('x' * 300) + '.exe') }
        }
        $getValues = { param($Path) if ($script:RunValues.ContainsKey($Path)) { $script:RunValues[$Path] } else { @{} } }
        $getApproval = { param($Path) @{} }
        $getFolder = { param($Path) , @() }
        $lines = Get-WtStartupProgramsLines -Width 95 -GetUserSid { $null } -GetValueMap $getValues -GetApprovalMap $getApproval -GetFolderEntries $getFolder -GetUserProfilePath { param($Sid) $null } -CommonStartup 'C:\ProgramData\Startup'

        foreach ($line in $lines) { $line.Length | Should -BeLessOrEqual 95 }
    }
}

Describe 'Get-WtNonMicrosoftTaskLines' {
    BeforeAll {
        function script:New-FakeTask {
            param(
                $TaskName,
                $TaskPath = '\',
                $State = 'Ready',
                $Execute = 'C:\Program Files\Vendor\updater.exe'
            )
            [PSCustomObject]@{
                TaskName = $TaskName
                TaskPath = $TaskPath
                State    = $State
                Actions  = @([PSCustomObject]@{ Execute = $Execute })
            }
        }

        function script:New-FakeComTask {
            param($TaskName, $TaskPath = '\')
            [PSCustomObject]@{
                TaskName = $TaskName
                TaskPath = $TaskPath
                State    = 'Ready'
                Actions  = @([PSCustomObject]@{ ClassId = '{11111111-2222-3333-4444-555555555555}' })
            }
        }

        function script:New-FakeTaskInfo {
            param($LastRunTime = $null)
            [PSCustomObject]@{ LastRunTime = $LastRunTime; LastTaskResult = 0 }
        }
    }

    It 'keeps only the tasks that are not under \Microsoft\' {
        $tasks = @(
            (New-FakeTask -TaskName 'VendorUpdate' -TaskPath '\')
            (New-FakeTask -TaskName 'AdwareCheck' -TaskPath '\Vendor\')
            (New-FakeTask -TaskName 'Defrag' -TaskPath '\Microsoft\Windows\Defrag\')
            (New-FakeTask -TaskName 'Lowercase' -TaskPath '\microsoft\windows\foo\')
        )
        $script:TaskFixtures = $tasks
        $lines = Get-WtNonMicrosoftTaskLines -Width 95 -GetTasks { , @($script:TaskFixtures) } -GetTaskInfo { param($Task) New-FakeTaskInfo }

        $lines[0] | Should -Be 'Non-Microsoft tasks: 2 (2 enabled, 0 disabled)'
        $text = $lines -join "`n"
        $text | Should -CMatch 'VendorUpdate'
        $text | Should -CMatch 'AdwareCheck'
        $text | Should -Not -CMatch 'Defrag'
        $text | Should -Not -CMatch 'Lowercase'
    }

    It 'counts a disabled task separately instead of hiding it' {
        $script:TaskFixtures = @(
            (New-FakeTask -TaskName 'VendorUpdate' -TaskPath '\')
            (New-FakeTask -TaskName 'OldThing' -TaskPath '\' -State 'Disabled')
        )
        $lines = Get-WtNonMicrosoftTaskLines -Width 95 -GetTasks { , @($script:TaskFixtures) } -GetTaskInfo { param($Task) New-FakeTaskInfo }

        $lines[0] | Should -Be 'Non-Microsoft tasks: 2 (1 enabled, 1 disabled)'
        ($lines -join "`n") | Should -CMatch 'OldThing'
    }

    It 'survives an action with no Execute (ComHandler / SendEmail)' {
        $script:TaskFixtures = @((New-FakeComTask -TaskName 'ComThing'))
        $lines = Get-WtNonMicrosoftTaskLines -Width 95 -GetTasks { , @($script:TaskFixtures) } -GetTaskInfo { param($Task) New-FakeTaskInfo }

        $lines[0] | Should -Be 'Non-Microsoft tasks: 1 (1 enabled, 0 disabled)'
        ($lines -join "`n") | Should -CMatch 'ComThing'
    }

    It 'formats last run invariantly and shows a never-run task as a dash, even under tr-TR' {
        $old = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            $script:TaskFixtures = @(
                (New-FakeTask -TaskName 'RanTask' -TaskPath '\')
                (New-FakeTask -TaskName 'NeverTask' -TaskPath '\')
            )
            $getInfo = {
                param($Task)
                if ($Task.TaskName -ceq 'RanTask') { New-FakeTaskInfo -LastRunTime ([datetime]::new(2026, 8, 21, 14, 5, 0)) }
                else { New-FakeTaskInfo -LastRunTime ([datetime]::new(1899, 11, 30, 0, 0, 0)) }
            }
            $lines = Get-WtNonMicrosoftTaskLines -Width 95 -GetTasks { , @($script:TaskFixtures) } -GetTaskInfo $getInfo

            ($lines -join "`n") | Should -CMatch '2026-08-21 14:05'
            $neverLine = $lines | Select-String -SimpleMatch 'NeverTask' | Select-Object -First 1
            "$neverLine" | Should -CMatch '-'
            "$neverLine" | Should -Not -CMatch '1899'
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $old }
    }

    It 'says the list could not be read when the task source throws' {
        $lines = Get-WtNonMicrosoftTaskLines -Width 95 -GetTasks { throw 'The service is not running' } -GetTaskInfo { param($Task) New-FakeTaskInfo }
        $lines | Should -Contain 'The scheduled task list could not be read.'
    }

    It 'says so, and still explains the \Microsoft\ filter, when nothing survives it' {
        $script:TaskFixtures = @((New-FakeTask -TaskName 'Defrag' -TaskPath '\Microsoft\Windows\Defrag\'))
        $lines = Get-WtNonMicrosoftTaskLines -Width 95 -GetTasks { , @($script:TaskFixtures) } -GetTaskInfo { param($Task) New-FakeTaskInfo }

        $lines | Should -Contain 'No non-Microsoft scheduled task was found.'
        ($lines -join "`n") | Should -CMatch 'Microsoft'
    }

    It 'keeps every line inside the panel width' {
        $script:TaskFixtures = @((New-FakeTask -TaskName ('T' * 120) -TaskPath ('\' + ('P' * 120) + '\') -Execute ('C:\' + ('x' * 200) + '.exe')))
        $lines = Get-WtNonMicrosoftTaskLines -Width 95 -GetTasks { , @($script:TaskFixtures) } -GetTaskInfo { param($Task) New-FakeTaskInfo }

        foreach ($line in $lines) { $line.Length | Should -BeLessOrEqual 95 }
    }

    It 'filters \Microsoft\ ordinally under tr-TR, where capital I and dotted i do not case-fold like the invariant culture' {
        $old = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            $script:TaskFixtures = @(
                (New-FakeTask -TaskName 'AllCaps' -TaskPath '\MICROSOFT\Windows\Update\')
                (New-FakeTask -TaskName 'Standard' -TaskPath '\Microsoft\Windows\Defrag\')
                (New-FakeTask -TaskName 'VendorInstaller' -TaskPath '\Vendor\Installers\')
            )
            $lines = Get-WtNonMicrosoftTaskLines -Width 95 -GetTasks { , @($script:TaskFixtures) } -GetTaskInfo { param($Task) New-FakeTaskInfo }

            $lines[0] | Should -Be 'Non-Microsoft tasks: 1 (1 enabled, 0 disabled)'
            $text = $lines -join "`n"
            $text | Should -CMatch 'VendorInstaller'
            $text | Should -Not -CMatch 'AllCaps'
            $text | Should -Not -CMatch 'Standard'
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $old }
    }
}

Describe 'Get-WtInstalledUpdatesLines' {
    BeforeAll {
        function script:New-FakeHotFix {
            param(
                $HotFixID,
                $Description = 'Update',
                $InstalledOn = $null,
                $InstalledBy = 'NT AUTHORITY\SYSTEM'
            )
            [PSCustomObject]@{
                HotFixID    = $HotFixID
                Description = $Description
                InstalledOn = $InstalledOn
                InstalledBy = $InstalledBy
            }
        }
    }

    It 'lists the newest update first' {
        $script:HotFixFixtures = @(
            (New-FakeHotFix -HotFixID 'KB5000001' -InstalledOn ([datetime]::new(2026, 1, 5)))
            (New-FakeHotFix -HotFixID 'KB5000003' -InstalledOn ([datetime]::new(2026, 8, 12)))
            (New-FakeHotFix -HotFixID 'KB5000002' -InstalledOn ([datetime]::new(2026, 4, 9)))
        )
        $lines = Get-WtInstalledUpdatesLines -GetHotFixes { , @($script:HotFixFixtures) }

        $lines[0] | Should -Be 'Installed updates: 3'
        $newest = ($lines | Select-String -SimpleMatch 'KB5000003' | Select-Object -First 1).LineNumber
        $middle = ($lines | Select-String -SimpleMatch 'KB5000002' | Select-Object -First 1).LineNumber
        $oldest = ($lines | Select-String -SimpleMatch 'KB5000001' | Select-Object -First 1).LineNumber
        $newest | Should -BeLessThan $middle
        $middle | Should -BeLessThan $oldest
    }

    It 'shows a missing install date as a dash and sorts it last, instead of dying on it' {
        $script:HotFixFixtures = @(
            (New-FakeHotFix -HotFixID 'KB5000009' -InstalledOn $null)
            (New-FakeHotFix -HotFixID 'KB5000010' -InstalledOn ([datetime]::new(2026, 3, 3)))
        )
        $lines = Get-WtInstalledUpdatesLines -GetHotFixes { , @($script:HotFixFixtures) }

        $lines[0] | Should -Be 'Installed updates: 2'
        $dated = ($lines | Select-String -SimpleMatch 'KB5000010' | Select-Object -First 1).LineNumber
        $undated = ($lines | Select-String -SimpleMatch 'KB5000009' | Select-Object -First 1).LineNumber
        $dated | Should -BeLessThan $undated
        "$($lines | Select-String -SimpleMatch 'KB5000009' | Select-Object -First 1)" | Should -CMatch '-'
    }

    It 'formats the install date invariantly, even under tr-TR' {
        $old = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            $script:HotFixFixtures = @((New-FakeHotFix -HotFixID 'KB5000011' -InstalledOn ([datetime]::new(2026, 8, 12))))
            $lines = Get-WtInstalledUpdatesLines -GetHotFixes { , @($script:HotFixFixtures) }
            ($lines -join "`n") | Should -CMatch '2026-08-12'
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $old }
    }

    It 'says the list could not be read when the source throws' {
        $lines = Get-WtInstalledUpdatesLines -GetHotFixes { throw 'RPC server unavailable' }
        $lines | Should -Contain 'The installed update list could not be read.'
    }

    It 'says so when nothing is reported, and still prints the Store/driver footnote' {
        $lines = Get-WtInstalledUpdatesLines -GetHotFixes { , @() }
        $lines | Should -Contain 'No installed update was reported.'
        $lines | Should -Contain 'Store and driver updates are not in this list.'
    }
}

Describe 'Information > Software and startup group' {
    BeforeAll {
        $script:SoftwareGroup = @(Get-WtInfoToolGroups) | Where-Object { $_.HeaderKey -eq 'InfoGroupSoftwareStartup' } | Select-Object -First 1
        $script:SoftwareRows = @(& $script:SoftwareGroup.GetRows)
    }

    It 'carries exactly the four catalogue rows, in catalogue order' {
        @($script:SoftwareRows | ForEach-Object { $_.Name }) | Should -Be @(
            'InstalledProgramsList'
            'StartupProgramsList'
            'NonMicrosoftScheduledTasks'
            'InstalledUpdatesList'
        )
    }

    It 'labels every row in both languages, ASCII only, at most 45 characters' {
        foreach ($row in $script:SoftwareRows) {
            foreach ($lang in 'EN', 'TR') {
                $text = [string]$script:Translations[$lang][$row.Name]
                $text | Should -Not -BeNullOrEmpty -Because "$lang needs '$($row.Name)'"
                $text.Length | Should -BeLessOrEqual 45 -Because "$lang '$($row.Name)'"
                foreach ($ch in $text.ToCharArray()) {
                    [int]$ch | Should -BeLessOrEqual 127 -Because "$lang '$($row.Name)' must be ASCII-folded"
                }
            }
            $script:Translations['EN'][$row.Name] | Should -Not -Be $script:Translations['TR'][$row.Name] -Because "'$($row.Name)' must be translated, not copied"
        }
    }

    It 'renders every row inside the panel and never blocks on Read-Host' {
        foreach ($row in $script:SoftwareRows) {
            $row.Data.Captured | Should -BeTrue -Because $row.Name
            $row.Data.Action.ToString() | Should -Not -CMatch 'Read-Host' -Because "$($row.Name) would deadlock behind the capture"
        }
    }

    It 'keeps every information row read-only' {
        $denied = 'Set-', 'Remove-', 'Stop-', 'Start-', 'Restart-', 'New-', 'Clear-', 'Disable-', 'Enable-', 'vssadmin', 'netsh'
        foreach ($row in $script:SoftwareRows) {
            $src = $row.Data.Action.ToString()
            foreach ($verb in $denied) {
                $src | Should -Not -CMatch ([regex]::Escape($verb)) -Because "$($row.Name) must never '$verb'"
            }
        }
    }

    It 'carries no risk badge - all four rows are SAFE' {
        foreach ($row in $script:SoftwareRows) {
            $row.Risk | Should -BeNullOrEmpty -Because $row.Name
        }
    }
}
