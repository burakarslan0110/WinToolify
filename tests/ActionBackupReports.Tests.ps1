#Requires -Modules Pester

<#
.SYNOPSIS
    The Backup and Reports group of the Actions screen: registry export
    targets, the driver export space gate, the battery report guard, and
    the Wi-Fi profile export with its typed gate. Every Windows-only
    source (reg.exe, Export-WindowsDriver, powercfg, netsh, Win32_Battery,
    explorer.exe) is behind an injectable scriptblock, so nothing here
    touches the real machine.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath

    function script:Get-LineIndex {
        <#
        .SYNOPSIS
            Ordinal line search: String.Contains, not -match/-like, since
            tr-TR's dotless-I makes those culture-dependent.
        #>
        param([string[]]$Lines, [string]$Needle)
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i].Contains($Needle)) { return $i }
        }
        return -1
    }
}

Describe 'Get-WtRegistryBackupTargets' {
    It 'exports SOFTWARE, SYSTEM and the interactive user hive, in that order' {
        $t = @(Get-WtRegistryBackupTargets -UserSid 'S-1-5-21-9-9-9-1001')
        @($t | ForEach-Object Key) | Should -Be @('HKLM\SOFTWARE', 'HKLM\SYSTEM', 'HKU\S-1-5-21-9-9-9-1001')
    }

    It 'never offers HKLM\SYSTEM as a re-importable restore' {
        $t = @(Get-WtRegistryBackupTargets -UserSid 'S-1-5-21-9-9-9-1001')
        ($t | Where-Object { $_.Key -eq 'HKLM\SYSTEM' }).Reimportable | Should -BeFalse
        ($t | Where-Object { $_.Key -eq 'HKLM\SOFTWARE' }).Reimportable | Should -BeTrue
    }

    It 'addresses the user hive through HKU and never through HKCU' {
        $t = @(Get-WtRegistryBackupTargets -UserSid 'S-1-5-21-9-9-9-1001')
        (@($t | ForEach-Object Key) -join ' ').Contains('HKCU') | Should -BeFalse
    }

    It 'drops the user hive when no SID could be resolved' {
        $t = @(Get-WtRegistryBackupTargets -UserSid $null)
        $t.Count | Should -Be 2
        @($t | ForEach-Object Key) | Should -Be @('HKLM\SOFTWARE', 'HKLM\SYSTEM')
    }

    It 'gives every target a distinct .reg file name' {
        $t = @(Get-WtRegistryBackupTargets -UserSid 'S-1-5-21-9-9-9-1001')
        @($t | ForEach-Object FileName | Sort-Object -Unique).Count | Should -Be 3
        foreach ($x in $t) { $x.FileName.EndsWith('.reg') | Should -BeTrue }
    }
}

Describe 'Invoke-WtBackupRegistryAction' {
    BeforeEach {
        $script:exported = New-Object System.Collections.Generic.List[string]
        $script:okExport = {
            param($Key, $File)
            Write-Host ('CALL:' + $Key)
            $script:exported.Add($Key)
            $true
        }
    }

    It 'prints the machine-scope folder and a line BEFORE every export' {
        $p = @{
            GetUserSid   = { 'S-1-5-21-9-9-9-1001' }
            GetFolder    = { 'C:\ProgramData\WinToolify\RegistryBackup\20260823-101500' }
            ExportAction = $script:okExport
            GetFileSize  = { param($File) 2048 }
        }
        $out = @(Invoke-WtBackupRegistryAction @p 6>&1 | ForEach-Object { [string]$_ })

        @($script:exported) | Should -Be @('HKLM\SOFTWARE', 'HKLM\SYSTEM', 'HKU\S-1-5-21-9-9-9-1001')
        (Get-LineIndex -Lines $out -Needle 'C:\ProgramData\WinToolify\RegistryBackup\20260823-101500') | Should -Be 0
        foreach ($key in 'HKLM\SOFTWARE', 'HKLM\SYSTEM', 'HKU\S-1-5-21-9-9-9-1001') {
            $announce = Get-LineIndex -Lines $out -Needle $key
            $call = Get-LineIndex -Lines $out -Needle ('CALL:' + $key)
            $announce | Should -BeGreaterOrEqual 0
            $announce | Should -BeLessThan $call
        }
    }

    It 'warns that the SYSTEM export must never be imported back' {
        $p = @{
            GetUserSid   = { 'S-1-5-21-9-9-9-1001' }
            GetFolder    = { 'C:\backup' }
            ExportAction = $script:okExport
            GetFileSize  = { param($File) 4096 }
        }
        $out = @(Invoke-WtBackupRegistryAction @p 6>&1 | ForEach-Object { [string]$_ })
        (Get-LineIndex -Lines $out -Needle (Get-Translation 'BackupRegistrySystemWarning')) | Should -BeGreaterOrEqual 0
    }

    It 'still exports the machine hives and says so when the user SID is missing' {
        $p = @{
            GetUserSid   = { $null }
            GetFolder    = { 'C:\backup' }
            ExportAction = $script:okExport
            GetFileSize  = { param($File) 1024 }
        }
        $out = @(Invoke-WtBackupRegistryAction @p 6>&1 | ForEach-Object { [string]$_ })
        @($script:exported) | Should -Be @('HKLM\SOFTWARE', 'HKLM\SYSTEM')
        (Get-LineIndex -Lines $out -Needle (Get-Translation 'BackupRegistryNoUserHive')) | Should -BeGreaterOrEqual 0
    }

    It 'treats a throwing SID lookup as "no user hive" instead of killing the row' {
        $p = @{
            GetUserSid   = { throw 'Windows Principal functionality is not supported on this platform' }
            GetFolder    = { 'C:\backup' }
            ExportAction = $script:okExport
            GetFileSize  = { param($File) 1024 }
        }
        $out = @(Invoke-WtBackupRegistryAction @p 6>&1 | ForEach-Object { [string]$_ })
        @($script:exported) | Should -Be @('HKLM\SOFTWARE', 'HKLM\SYSTEM')
        (Get-LineIndex -Lines $out -Needle (Get-Translation 'BackupRegistryNoUserHive')) | Should -BeGreaterOrEqual 0
    }

    It 'reports a failed hive and counts only the ones that really landed' {
        $p = @{
            GetUserSid   = { 'S-1-5-21-9-9-9-1001' }
            GetFolder    = { 'C:\backup' }
            ExportAction = { param($Key, $File) if ($Key -eq 'HKLM\SYSTEM') { return $false } ; $true }
            GetFileSize  = { param($File) 512 }
        }
        $out = @(Invoke-WtBackupRegistryAction @p 6>&1 | ForEach-Object { [string]$_ })
        (Get-LineIndex -Lines $out -Needle ((Get-Translation 'BackupRegistryFailed') -f 'HKLM\SYSTEM')) | Should -BeGreaterOrEqual 0
        (Get-LineIndex -Lines $out -Needle ((Get-Translation 'BackupRegistryDone') -f 2, 3)) | Should -BeGreaterOrEqual 0
    }

    It 'hardens the backup folder ACL before any export, and reports success' {
        $script:aclCalls = New-Object System.Collections.Generic.List[string]
        $p = @{
            GetUserSid      = { 'S-1-5-21-9-9-9-1001' }
            GetFolder       = { 'C:\backup' }
            HardenFolderAcl = { param($Folder) $script:aclCalls.Add($Folder) }
            ExportAction    = $script:okExport
            GetFileSize     = { param($File) 1024 }
        }
        $out = @(Invoke-WtBackupRegistryAction @p 6>&1 | ForEach-Object { [string]$_ })
        @($script:aclCalls) | Should -Be @('C:\backup')
        $aclIndex = Get-LineIndex -Lines $out -Needle (Get-Translation 'BackupRegistryAclHardened')
        $firstExportCall = Get-LineIndex -Lines $out -Needle 'CALL:HKLM\SOFTWARE'
        $aclIndex | Should -BeGreaterOrEqual 0
        $aclIndex | Should -BeLessThan $firstExportCall
    }

    It 'says so plainly, and still exports, when hardening the ACL fails' {
        $p = @{
            GetUserSid      = { 'S-1-5-21-9-9-9-1001' }
            GetFolder       = { 'C:\backup' }
            HardenFolderAcl = { param($Folder) throw 'Access to the path is denied' }
            ExportAction    = $script:okExport
            GetFileSize     = { param($File) 1024 }
        }
        $out = @(Invoke-WtBackupRegistryAction @p 6>&1 | ForEach-Object { [string]$_ })
        @($script:exported) | Should -Be @('HKLM\SOFTWARE', 'HKLM\SYSTEM', 'HKU\S-1-5-21-9-9-9-1001')
        (Get-LineIndex -Lines $out -Needle (Get-Translation 'BackupRegistryAclFailed')) | Should -BeGreaterOrEqual 0
        (Get-LineIndex -Lines $out -Needle (Get-Translation 'BackupRegistryAclHardened')) | Should -Be -1
    }

    It 'restricts the default ACL to Administrators and SYSTEM by well-known SID, not group name' {
        $def = (Get-Command Invoke-WtBackupRegistryAction).Definition
        $def.Contains('S-1-5-32-544') | Should -BeTrue
        $def.Contains('S-1-5-18') | Should -BeTrue
        $def.Contains('SetAccessRuleProtection') | Should -BeTrue
        $def.Contains('BUILTIN\Administrators') | Should -BeFalse
    }

    It 'never calls Read-Host - it runs behind Invoke-WtCapturedAction' {
        (Get-Command Invoke-WtBackupRegistryAction).Definition.Contains('Read-Host') | Should -BeFalse
    }
}

Describe 'Backup and Reports group - BackupRegistry row' {
    BeforeAll {
        $script:backupGroup = @(Get-WtActionToolGroups) | Where-Object { $_.HeaderKey -eq 'ActionGroupBackupReports' } | Select-Object -First 1
        $script:backupRows = @(& $script:backupGroup.GetRows)
    }

    It 'carries a BackupRegistry row that is captured, SAFE and Read-Host free' {
        $row = $script:backupRows | Where-Object { $_.Name -eq 'BackupRegistry' } | Select-Object -First 1
        $row | Should -Not -BeNullOrEmpty
        $row.Kind | Should -Be 'Action'
        $row.Risk | Should -Be 'SAFE'
        $row.Data.Captured | Should -BeTrue
        $row.Data.Action.ToString().Contains('Read-Host') | Should -BeFalse
        $row.Data.Action.ToString().Contains('Invoke-WtBackupRegistryAction') | Should -BeTrue
    }

    It 'resolves the BackupRegistry label in both languages' {
        $script:Translations['EN'].ContainsKey('BackupRegistry') | Should -BeTrue
        $script:Translations['TR'].ContainsKey('BackupRegistry') | Should -BeTrue
    }

    It 'resolves the ACL disclosure strings in both languages' {
        foreach ($key in 'BackupRegistryAclHardened', 'BackupRegistryAclFailed') {
            $script:Translations['EN'].ContainsKey($key) | Should -BeTrue
            $script:Translations['TR'].ContainsKey($key) | Should -BeTrue
        }
    }
}

Describe 'Test-WtDriverExportSpace' {
    It 'reports the drive root of the target folder and clears a roomy disk' {
        $r = Test-WtDriverExportSpace -Path 'C:\ProgramData\WinToolify\DriverBackup\20260823-101500' -GetFreeBytes { param($Root) 20GB }
        $r.Root | Should -Be 'C:'
        $r.FreeBytes | Should -Be 21474836480
        $r.RequiredBytes | Should -Be 5368709120
        $r.Sufficient | Should -BeTrue
    }

    It 'flags a drive that cannot hold the 5 GB a driver export can need' {
        $r = Test-WtDriverExportSpace -Path 'D:\DriverBackup' -GetFreeBytes { param($Root) 1GB }
        $r.Root | Should -Be 'D:'
        $r.Sufficient | Should -BeFalse
    }

    It 'passes the bare drive id (C:) to the source, the way Win32_LogicalDisk wants it' {
        $script:askedRoot = ''
        $null = Test-WtDriverExportSpace -Path 'C:\x\y' -GetFreeBytes { param($Root) $script:askedRoot = $Root; 9GB }
        $script:askedRoot | Should -Be 'C:'
    }

    It 'treats a throwing free-space source as no space rather than crashing the row' {
        $r = Test-WtDriverExportSpace -Path 'C:\x' -GetFreeBytes { param($Root) throw 'Generic failure' }
        $r.FreeBytes | Should -Be 0
        $r.Sufficient | Should -BeFalse
    }
}

Describe 'Invoke-WtExportDriversAction' {
    BeforeAll {
        function script:New-FakeDriver {
            param($OriginalFileName)
            [PSCustomObject]@{
                Driver           = 'oem12.inf'
                OriginalFileName = $OriginalFileName
                ClassName        = 'Net'
                ProviderName     = 'Contoso'
                Date             = (Get-Date '2024-01-01')
                Version          = '1.2.3.4'
            }
        }
    }

    It 'prints the machine-scope folder and the space check before anything is copied' {
        $p = @{
            GetFolder     = { 'C:\ProgramData\WinToolify\DriverBackup\20260823-101500' }
            CheckSpace    = { param($Folder) [PSCustomObject]@{ Root = 'C:'; FreeBytes = 21474836480; RequiredBytes = 5368709120; Sufficient = $true } }
            ExportAction  = { param($Folder) Write-Host 'CALL:export'; New-FakeDriver 'C:\Windows\System32\DriverStore\a.inf' }
            GetFolderSize = { param($Folder) 1288490189 }
        }
        $out = @(Invoke-WtExportDriversAction @p 6>&1 | ForEach-Object { [string]$_ })
        (Get-LineIndex -Lines $out -Needle 'C:\ProgramData\WinToolify\DriverBackup\20260823-101500') | Should -Be 0
        (Get-LineIndex -Lines $out -Needle (Get-Translation 'ExportDriversRunning')) | Should -BeLessThan (Get-LineIndex -Lines $out -Needle 'CALL:export')
    }

    It 'streams one line per exported package and closes with the count and the size' {
        $p = @{
            GetFolder     = { 'C:\backup' }
            CheckSpace    = { param($Folder) [PSCustomObject]@{ Root = 'C:'; FreeBytes = 21474836480; RequiredBytes = 5368709120; Sufficient = $true } }
            ExportAction  = { param($Folder) New-FakeDriver 'C:\a.inf'; New-FakeDriver 'C:\b.inf'; New-FakeDriver 'C:\c.inf' }
            GetFolderSize = { param($Folder) 1288490189 }
        }
        $out = @(Invoke-WtExportDriversAction @p 6>&1 | ForEach-Object { [string]$_ })
        (Get-LineIndex -Lines $out -Needle 'C:\a.inf') | Should -BeGreaterOrEqual 0
        (Get-LineIndex -Lines $out -Needle 'C:\b.inf') | Should -BeGreaterOrEqual 0
        (Get-LineIndex -Lines $out -Needle 'C:\c.inf') | Should -BeGreaterOrEqual 0
        (Get-LineIndex -Lines $out -Needle ((Get-Translation 'ExportDriversDone') -f 3, '1.2 GB')) | Should -BeGreaterOrEqual 0
    }

    It 'refuses and never starts the export when the drive is too small' {
        $script:started = $false
        $p = @{
            GetFolder     = { 'C:\backup' }
            CheckSpace    = { param($Folder) [PSCustomObject]@{ Root = 'C:'; FreeBytes = 1073741824; RequiredBytes = 5368709120; Sufficient = $false } }
            ExportAction  = { param($Folder) $script:started = $true }
            GetFolderSize = { param($Folder) 0 }
        }
        $out = @(Invoke-WtExportDriversAction @p 6>&1 | ForEach-Object { [string]$_ })
        $script:started | Should -BeFalse
        (Get-LineIndex -Lines $out -Needle (Get-Translation 'ExportDriversNoSpace')) | Should -BeGreaterOrEqual 0
    }

    It 'says so when the machine has no third-party driver package' {
        $p = @{
            GetFolder     = { 'C:\backup' }
            CheckSpace    = { param($Folder) [PSCustomObject]@{ Root = 'C:'; FreeBytes = 21474836480; RequiredBytes = 5368709120; Sufficient = $true } }
            ExportAction  = { param($Folder) }
            GetFolderSize = { param($Folder) 0 }
        }
        $out = @(Invoke-WtExportDriversAction @p 6>&1 | ForEach-Object { [string]$_ })
        (Get-LineIndex -Lines $out -Needle (Get-Translation 'ExportDriversNone')) | Should -BeGreaterOrEqual 0
    }

    It 'reports a throwing Export-WindowsDriver instead of blowing up the panel' {
        $p = @{
            GetFolder     = { 'C:\backup' }
            CheckSpace    = { param($Folder) [PSCustomObject]@{ Root = 'C:'; FreeBytes = 21474836480; RequiredBytes = 5368709120; Sufficient = $true } }
            ExportAction  = { param($Folder) throw 'The term Export-WindowsDriver is not recognized' }
            GetFolderSize = { param($Folder) 0 }
        }
        $out = @(Invoke-WtExportDriversAction @p 6>&1 | ForEach-Object { [string]$_ })
        (Get-LineIndex -Lines $out -Needle 'Export-WindowsDriver is not recognized') | Should -BeGreaterOrEqual 0
    }

    It 'exports to a Machine-scope path, never a User-scope one' {
        $def = (Get-Command Invoke-WtExportDriversAction).Definition
        $def.Contains("Get-WtDataPath -Scope Machine") | Should -BeTrue
        $def.Contains("Get-WtDataPath -Scope User") | Should -BeFalse
        $def.Contains('Read-Host') | Should -BeFalse
    }
}

Describe 'Backup and Reports group - ExportDrivers row' {
    BeforeAll {
        $script:driverGroup = @(Get-WtActionToolGroups) | Where-Object { $_.HeaderKey -eq 'ActionGroupBackupReports' } | Select-Object -First 1
        $script:driverRows = @(& $script:driverGroup.GetRows)
    }

    It 'carries an ExportDrivers row that is captured, SAFE and Read-Host free' {
        $row = $script:driverRows | Where-Object { $_.Name -eq 'ExportDrivers' } | Select-Object -First 1
        $row | Should -Not -BeNullOrEmpty
        $row.Kind | Should -Be 'Action'
        $row.Risk | Should -Be 'SAFE'
        $row.Data.Captured | Should -BeTrue
        $row.Data.Action.ToString().Contains('Read-Host') | Should -BeFalse
        $row.Data.Action.ToString().Contains('Invoke-WtExportDriversAction') | Should -BeTrue
    }

    It 'puts the cost of the export in the label itself, in both languages' {
        $script:Translations['EN']['ExportDrivers'].Contains('min') | Should -BeTrue
        $script:Translations['TR']['ExportDrivers'].Contains('dk') | Should -BeTrue
    }
}

Describe 'Invoke-WtBatteryReportAction' {
    It 'says there is no battery instead of producing an empty report' {
        $script:ranPowercfg = $false
        $p = @{
            GetBattery  = { @() }
            GetFolder   = { 'C:\ProgramData\WinToolify\Reports' }
            RunPowercfg = { param($File) $script:ranPowercfg = $true }
            TestReport  = { param($File) $false }
            OpenReport  = { param($File) }
        }
        $out = @(Invoke-WtBatteryReportAction @p 6>&1 | ForEach-Object { [string]$_ })
        $script:ranPowercfg | Should -BeFalse
        (Get-LineIndex -Lines $out -Needle (Get-Translation 'BatteryReportNoBattery')) | Should -BeGreaterOrEqual 0
    }

    It 'says there is no battery when the battery source itself throws (a broken WMI repository)' {
        $script:ranPowercfg = $false
        $script:opened = $false
        $p = @{
            GetBattery  = { throw 'Generic failure' }
            GetFolder   = { 'C:\ProgramData\WinToolify\Reports' }
            RunPowercfg = { param($File) $script:ranPowercfg = $true }
            TestReport  = { param($File) $false }
            OpenReport  = { param($File) $script:opened = $true }
        }
        $out = @(Invoke-WtBatteryReportAction @p 6>&1 | ForEach-Object { [string]$_ })
        $script:ranPowercfg | Should -BeFalse
        $script:opened | Should -BeFalse
        (Get-LineIndex -Lines $out -Needle (Get-Translation 'BatteryReportNoBattery')) | Should -BeGreaterOrEqual 0
    }

    It 'prints the report path BEFORE powercfg runs' {
        $p = @{
            GetBattery  = { @([PSCustomObject]@{ Name = 'DELL 0MGP41'; EstimatedChargeRemaining = 88 }) }
            GetFolder   = { 'C:\ProgramData\WinToolify\Reports' }
            RunPowercfg = { param($File) Write-Host 'CALL:powercfg' }
            TestReport  = { param($File) $true }
            OpenReport  = { param($File) }
        }
        $out = @(Invoke-WtBatteryReportAction @p 6>&1 | ForEach-Object { [string]$_ })
        $pathIndex = Get-LineIndex -Lines $out -Needle 'C:\ProgramData\WinToolify\Reports'
        $pathIndex | Should -BeGreaterOrEqual 0
        $pathIndex | Should -BeLessThan (Get-LineIndex -Lines $out -Needle 'CALL:powercfg')
        (Get-LineIndex -Lines $out -Needle 'DELL 0MGP41') | Should -BeGreaterOrEqual 0
    }

    It 'hands the finished .html to the opener and reports success' {
        $script:opened = ''
        $p = @{
            GetBattery  = { @([PSCustomObject]@{ Name = 'DELL 0MGP41' }) }
            GetFolder   = { 'C:\reports' }
            RunPowercfg = { param($File) }
            TestReport  = { param($File) $true }
            OpenReport  = { param($File) $script:opened = [string]$File }
        }
        $out = @(Invoke-WtBatteryReportAction @p 6>&1 | ForEach-Object { [string]$_ })
        $script:opened.StartsWith('C:\reports\battery-report-') | Should -BeTrue
        $script:opened.EndsWith('.html') | Should -BeTrue
        (Get-LineIndex -Lines $out -Needle (Get-Translation 'BatteryReportDone')) | Should -BeGreaterOrEqual 0
    }

    It 'says the report failed and opens nothing when the file never appeared' {
        $script:opened = ''
        $p = @{
            GetBattery  = { @([PSCustomObject]@{ Name = 'DELL 0MGP41' }) }
            GetFolder   = { 'C:\reports' }
            RunPowercfg = { param($File) }
            TestReport  = { param($File) $false }
            OpenReport  = { param($File) $script:opened = [string]$File }
        }
        $out = @(Invoke-WtBatteryReportAction @p 6>&1 | ForEach-Object { [string]$_ })
        $script:opened | Should -Be ''
        (Get-LineIndex -Lines $out -Needle (Get-Translation 'BatteryReportFailed')) | Should -BeGreaterOrEqual 0
    }

    It 'never starts the report file itself - the default opener is explorer.exe' {
        $def = (Get-Command Invoke-WtBatteryReportAction).Definition
        $def.Contains('explorer.exe') | Should -BeTrue
        $def.Contains('Start-Process -FilePath $file') | Should -BeFalse
        $def.Contains('Read-Host') | Should -BeFalse
    }
}

Describe 'Backup and Reports group - BatteryReport row' {
    BeforeAll {
        $script:batteryGroup = @(Get-WtActionToolGroups) | Where-Object { $_.HeaderKey -eq 'ActionGroupBackupReports' } | Select-Object -First 1
        $script:batteryRows = @(& $script:batteryGroup.GetRows)
    }

    It 'carries a BatteryReport row that is captured, SAFE and Read-Host free' {
        $row = $script:batteryRows | Where-Object { $_.Name -eq 'BatteryReport' } | Select-Object -First 1
        $row | Should -Not -BeNullOrEmpty
        $row.Kind | Should -Be 'Action'
        $row.Risk | Should -Be 'SAFE'
        $row.Data.Captured | Should -BeTrue
        $row.Data.Action.ToString().Contains('Read-Host') | Should -BeFalse
        $row.Data.Action.ToString().Contains('Invoke-WtBatteryReportAction') | Should -BeTrue
    }

    It 'resolves the BatteryReport label in both languages' {
        $script:Translations['EN'].ContainsKey('BatteryReport') | Should -BeTrue
        $script:Translations['TR'].ContainsKey('BatteryReport') | Should -BeTrue
    }
}

Describe 'Invoke-WtWifiProfileExport' {
    BeforeAll {
        function script:New-FakeXml {
            param($FullName)
            [PSCustomObject]@{ FullName = $FullName; Name = (Split-Path $FullName -Leaf) }
        }
    }

    It 'creates the folder, runs the export and prints the folder first' {
        $script:created = ''
        $script:exportedTo = ''
        $p = @{
            Folder       = 'C:\Users\Ada\Desktop\WinToolify-WiFi'
            EnsureFolder = { param($Path) $script:created = [string]$Path }
            ExportAction = { param($Path) Write-Host 'CALL:netsh'; $script:exportedTo = [string]$Path }
            GetFiles     = { param($Path) @(New-FakeXml 'C:\Users\Ada\Desktop\WinToolify-WiFi\Wi-Fi-Home.xml') }
        }
        $out = @(Invoke-WtWifiProfileExport @p 6>&1 | ForEach-Object { [string]$_ })
        $script:created | Should -Be 'C:\Users\Ada\Desktop\WinToolify-WiFi'
        $script:exportedTo | Should -Be 'C:\Users\Ada\Desktop\WinToolify-WiFi'
        (Get-LineIndex -Lines $out -Needle 'C:\Users\Ada\Desktop\WinToolify-WiFi') | Should -Be 0
        (Get-LineIndex -Lines $out -Needle (Get-Translation 'ExportWifiProfilesRunning')) | Should -BeLessThan (Get-LineIndex -Lines $out -Needle 'CALL:netsh')
    }

    It 'prints one restorable netsh line per exported file' {
        $p = @{
            Folder       = 'C:\wifi'
            EnsureFolder = { param($Path) }
            ExportAction = { param($Path) }
            GetFiles     = { param($Path) @((New-FakeXml 'C:\wifi\Wi-Fi-Home.xml'), (New-FakeXml 'C:\wifi\Wi-Fi-Cafe.xml')) }
        }
        $out = @(Invoke-WtWifiProfileExport @p 6>&1 | ForEach-Object { [string]$_ })
        (Get-LineIndex -Lines $out -Needle 'netsh wlan add profile filename="C:\wifi\Wi-Fi-Home.xml"') | Should -BeGreaterOrEqual 0
        (Get-LineIndex -Lines $out -Needle 'netsh wlan add profile filename="C:\wifi\Wi-Fi-Cafe.xml"') | Should -BeGreaterOrEqual 0
        (Get-LineIndex -Lines $out -Needle ((Get-Translation 'ExportWifiProfilesDone') -f 2, 'C:\wifi')) | Should -BeGreaterOrEqual 0
    }

    It 'repeats in the output that the files are clear text and stay on disk' {
        $p = @{
            Folder       = 'C:\wifi'
            EnsureFolder = { param($Path) }
            ExportAction = { param($Path) }
            GetFiles     = { param($Path) @(New-FakeXml 'C:\wifi\Wi-Fi-Home.xml') }
        }
        $out = @(Invoke-WtWifiProfileExport @p 6>&1 | ForEach-Object { [string]$_ })
        (Get-LineIndex -Lines $out -Needle (Get-Translation 'ExportWifiProfilesClearTextWarning')) | Should -BeGreaterOrEqual 0
    }

    It 'says so when nothing came out - no wireless adapter, or no saved network' {
        $p = @{
            Folder       = 'C:\wifi'
            EnsureFolder = { param($Path) }
            ExportAction = { param($Path) }
            GetFiles     = { param($Path) @() }
        }
        $out = @(Invoke-WtWifiProfileExport @p 6>&1 | ForEach-Object { [string]$_ })
        (Get-LineIndex -Lines $out -Needle (Get-Translation 'ExportWifiProfilesNone')) | Should -BeGreaterOrEqual 0
    }

    It 'reports an unusable target folder instead of throwing' {
        $script:ran = $false
        $p = @{
            Folder       = 'Q:\nope'
            EnsureFolder = { param($Path) throw 'The device is not ready' }
            ExportAction = { param($Path) $script:ran = $true }
            GetFiles     = { param($Path) @() }
        }
        $out = @(Invoke-WtWifiProfileExport @p 6>&1 | ForEach-Object { [string]$_ })
        $script:ran | Should -BeFalse
        (Get-LineIndex -Lines $out -Needle 'The device is not ready') | Should -BeGreaterOrEqual 0
    }

    It 'the default command uses key=clear and passes folder= as ONE argument' {
        $def = (Get-Command Invoke-WtWifiProfileExport).Definition
        $def.Contains('netsh wlan export profile key=clear') | Should -BeTrue
        $def.Contains("'folder=' + ") | Should -BeTrue
        $def.Contains('Read-Host') | Should -BeFalse
    }
}

Describe 'Invoke-WtExportWifiProfilesAction' {
    BeforeEach {
        $script:gateConsequence = ''
        $script:gateLines = @()
        $script:ranFolder = ''
        $script:notified = @()
    }

    It 'offers the desktop folder as the default and uses it when the answer is blank' {
        $p = @{
            GetDefaultFolder = { 'C:\Users\Ada\Desktop\WinToolify-WiFi' }
            AskFolder        = { param($Default) '' }
            Confirm          = { param($Consequence, $Lines) $script:gateConsequence = [string]$Consequence; $script:gateLines = @($Lines); $true }
            Notify           = { param($Lines) $script:notified = @($Lines) }
            Run              = { param($Folder, $Crumb) $script:ranFolder = [string]$Folder }
        }
        Invoke-WtExportWifiProfilesAction @p
        $script:ranFolder | Should -Be 'C:\Users\Ada\Desktop\WinToolify-WiFi'
    }

    It 'exports into the folder the user typed, quotes and spaces trimmed' {
        $p = @{
            GetDefaultFolder = { 'C:\Users\Ada\Desktop\WinToolify-WiFi' }
            AskFolder        = { param($Default) '  "D:\My Backups\wifi"  ' }
            Confirm          = { param($Consequence, $Lines) $true }
            Notify           = { param($Lines) $script:notified = @($Lines) }
            Run              = { param($Folder, $Crumb) $script:ranFolder = [string]$Folder }
        }
        Invoke-WtExportWifiProfilesAction @p
        $script:ranFolder | Should -Be 'D:\My Backups\wifi'
    }

    It 'exports nothing when the typed gate is refused, and says so in the panel' {
        $p = @{
            GetDefaultFolder = { 'C:\wifi' }
            AskFolder        = { param($Default) '' }
            Confirm          = { param($Consequence, $Lines) $false }
            Notify           = { param($Lines) $script:notified = @($Lines) }
            Run              = { param($Folder, $Crumb) $script:ranFolder = [string]$Folder }
        }
        Invoke-WtExportWifiProfilesAction @p
        $script:ranFolder | Should -Be ''
        @($script:notified) | Should -Contain (Get-Translation 'ExportWifiProfilesCancelled')
    }

    It 'exports nothing when the panel answer is null (input exhausted)' {
        $script:asked = $false
        $p = @{
            GetDefaultFolder = { 'C:\wifi' }
            AskFolder        = { param($Default) $null }
            Confirm          = { param($Consequence, $Lines) $script:asked = $true; $true }
            Notify           = { param($Lines) }
            Run              = { param($Folder, $Crumb) $script:ranFolder = [string]$Folder }
        }
        Invoke-WtExportWifiProfilesAction @p
        $script:asked | Should -BeFalse
        $script:ranFolder | Should -Be ''
    }

    It 'the gate names the target folder and both facts: clear text, and stays on disk' {
        $p = @{
            GetDefaultFolder = { 'C:\wifi' }
            AskFolder        = { param($Default) '' }
            Confirm          = { param($Consequence, $Lines) $script:gateConsequence = [string]$Consequence; $script:gateLines = @($Lines); $false }
            Notify           = { param($Lines) }
            Run              = { param($Folder, $Crumb) }
        }
        Invoke-WtExportWifiProfilesAction @p
        $script:gateConsequence | Should -Be (Get-Translation 'ExportWifiProfilesConsequence')
        @($script:gateLines) | Should -Contain ((Get-Translation 'ExportWifiProfilesTargetLine') -f 'C:\wifi')
        @($script:gateLines) | Should -Contain (Get-Translation 'ExportWifiProfilesClearTextLine')
        @($script:gateLines) | Should -Contain (Get-Translation 'ExportWifiProfilesStaysOnDiskLine')
    }

    It 'says clear text and stays on disk in plain words in BOTH languages' {
        $old = $script:Language
        try {
            $script:Language = 'EN'
            $script:Translations['EN']['ExportWifiProfilesConsequence'].Contains('CLEAR TEXT') | Should -BeTrue
            $script:Translations['EN']['ExportWifiProfilesStaysOnDiskLine'].Contains('STAY on disk') | Should -BeTrue
            $script:Language = 'TR'
            $script:Translations['TR']['ExportWifiProfilesConsequence'].Contains('DUZ METIN') | Should -BeTrue
            $script:Translations['TR']['ExportWifiProfilesStaysOnDiskLine'].Contains('KALIR') | Should -BeTrue
        }
        finally { $script:Language = $old }
    }

    It 'runs the export through the typed gate and inside the captured panel' {
        $def = (Get-Command Invoke-WtExportWifiProfilesAction).Definition
        $def.Contains('Confirm-WtDestructiveAction') | Should -BeTrue
        $def.Contains('Invoke-WtCapturedAction') | Should -BeTrue
    }
}

Describe 'Backup and Reports group - ExportWifiProfiles row' {
    BeforeAll {
        $script:wifiGroup = @(Get-WtActionToolGroups) | Where-Object { $_.HeaderKey -eq 'ActionGroupBackupReports' } | Select-Object -First 1
        $script:wifiRows = @(& $script:wifiGroup.GetRows)
    }

    It 'carries an ExportWifiProfiles row that is inline and ADVANCED' {
        $row = $script:wifiRows | Where-Object { $_.Name -eq 'ExportWifiProfiles' } | Select-Object -First 1
        $row | Should -Not -BeNullOrEmpty
        $row.Kind | Should -Be 'Action'
        $row.Risk | Should -Be 'ADVANCED'
        $row.Data.Captured | Should -Not -BeTrue
        $row.Data.Power | Should -Not -BeTrue
        $row.Data.Action.ToString().Contains('Invoke-WtExportWifiProfilesAction') | Should -BeTrue
    }

    It 'the ADVANCED row is gated: its inline flow calls the typed confirmation' {
        (Get-Command Invoke-WtExportWifiProfilesAction).Definition.Contains('Confirm-WtDestructiveAction') | Should -BeTrue
    }
}

Describe 'Backup and Reports group - as a whole' {
    BeforeAll {
        $script:group = @(Get-WtActionToolGroups) | Where-Object { $_.HeaderKey -eq 'ActionGroupBackupReports' } | Select-Object -First 1
        $script:rows = @(& $script:group.GetRows)
    }

    It 'holds exactly the four catalogue rows, in catalogue order' {
        @($script:rows | ForEach-Object Name) | Should -Be @('BackupRegistry', 'ExportDrivers', 'BatteryReport', 'ExportWifiProfiles')
    }

    It 'resolves every label in both dictionaries, ASCII only and at most 45 characters' {
        foreach ($row in $script:rows) {
            foreach ($lang in 'EN', 'TR') {
                $script:Translations[$lang].ContainsKey($row.Name) | Should -BeTrue -Because "$lang needs '$($row.Name)'"
                $value = [string]$script:Translations[$lang][$row.Name]
                $value.Length | Should -BeLessOrEqual 45 -Because "$lang label '$($row.Name)' must fit the panel"
                foreach ($ch in $value.ToCharArray()) {
                    [int]$ch | Should -BeLessThan 128 -Because "$lang label '$($row.Name)' must be pure ASCII"
                }
            }
        }
    }

    It 'never calls Read-Host from a captured row or from the functions those rows run' {
        foreach ($row in $script:rows) {
            if ($row.Data.Captured) { $row.Data.Action.ToString().Contains('Read-Host') | Should -BeFalse }
        }
        foreach ($fn in 'Invoke-WtBackupRegistryAction', 'Invoke-WtExportDriversAction', 'Invoke-WtBatteryReportAction', 'Invoke-WtWifiProfileExport') {
            (Get-Command $fn).Definition.Contains('Read-Host') | Should -BeFalse -Because "$fn runs behind Invoke-WtCapturedAction"
        }
    }

    It 'writes its backups to a machine-scope path, never a user-scope one' {
        foreach ($fn in 'Invoke-WtBackupRegistryAction', 'Invoke-WtExportDriversAction', 'Invoke-WtBatteryReportAction') {
            $def = (Get-Command $fn).Definition
            $def.Contains('Get-WtDataPath -Scope Machine') | Should -BeTrue -Because "$fn must not land in the admin profile"
            $def.Contains('Get-WtDataPath -Scope User') | Should -BeFalse
        }
    }

    It 'uses no Get-WmiObject and no Win32_Product anywhere in the group' {
        foreach ($fn in 'Get-WtRegistryBackupTargets', 'Invoke-WtBackupRegistryAction', 'Test-WtDriverExportSpace', 'Invoke-WtExportDriversAction', 'Invoke-WtBatteryReportAction', 'Invoke-WtWifiProfileExport', 'Invoke-WtExportWifiProfilesAction') {
            $def = (Get-Command $fn).Definition
            $def.Contains('Get-WmiObject') | Should -BeFalse
            $def.Contains('Win32_Product') | Should -BeFalse
        }
    }
}
