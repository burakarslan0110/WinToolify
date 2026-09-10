#Requires -Modules Pester

<#
.SYNOPSIS
    The menu-tree invariants of the V2 design: every settings screen
    carries at least 10 selectable entries, and every V1 action /
    information tool is reachable by its original translation key.
    Navigation menus (Main, Basic Tools, Privacy) are exempt.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Menu tree - V1 coverage' {
    It 'Basic Tools exposes the two V1 tool screens and nothing else (the VCRedist installer is a Software row)' {
        $items = @(Get-WtBasicToolsItems)
        @($items | Where-Object Kind -eq 'Link' | ForEach-Object { $_.Data.Screen }) | Should -Be @('ActionTools', 'InfoTools')
        $items.Count | Should -Be 2
        @($items | Where-Object Name -eq 'InstallVCRedist').Count | Should -Be 0
        $software = @(Get-WtActionToolGroups) | Where-Object HeaderKey -eq 'ActionGroupSoftware'
        @(& $software.GetRows | ForEach-Object Name) | Should -Contain 'InstallVCRedist'
    }
    It 'System Settings moved out of Basic Tools into the 3rd main-menu row' {
        @(Get-WtBasicToolsItems | ForEach-Object Name) | Should -Not -Contain 'SystemSettings'
        $main = @(Get-WtMainMenuItems)
        $main[3].Name | Should -Be 'SystemSettings'
        $main[3].Data.Screen | Should -Be 'SystemSettings'
    }
    It 'the main menu carries the restore-point shortcut just above Undo' {
        $names = @(Get-WtMainMenuItems | Where-Object { Test-WtItemFocusable -Item $_ } | ForEach-Object Name)
        $names | Should -Be @('BasicTools', 'Services', 'SystemSettings', 'Privacy', 'Packages', 'WingetStore', 'Language', 'CreateRestorePoint', 'Undo', 'Profiles', 'Assistant', 'Exit')
        $shortcut = @(Get-WtMainMenuItems)[8]
        $shortcut.Kind | Should -Be 'Action'
        $shortcut.Data.Action | Should -Not -BeNullOrEmpty
        $shortcut.Data.Screen | Should -BeNullOrEmpty
    }
    It 'ends on Exit - the restore-point footnote left with the tip line' {
        $items = @(Get-WtMainMenuItems)
        $names = @($items | ForEach-Object Name)
        $names | Should -Not -Contain 'MainRestoreHint'
        $names | Should -Not -Contain 'MainHintSpacer'
        $items[-1].Name | Should -Be 'Exit'
    }
    It 'under the ten plain rows sits the assistant block - spacer, titled rule, the row - and Exit follows it as the last row' {
        $items = @(Get-WtMainMenuItems)
        $names = @($items | ForEach-Object Name)
        $assistantAt = [array]::IndexOf($names, 'Assistant')
        $exitAt = [array]::IndexOf($names, 'Exit')
        $items[0].Kind | Should -Be 'Rule'
        $items[0].Name | Should -Be 'MainToolsRule'
        $items[0].Label | Should -Be (Get-Translation 'MainToolsRule')
        Test-WtItemFocusable -Item $items[0] | Should -BeFalse
        $assistantAt | Should -Be 13
        @($items[($assistantAt - 2)..$assistantAt] | ForEach-Object Kind) | Should -Be @('Spacer', 'Rule', 'Link')
        $items[$assistantAt - 1].Label | Should -Be (Get-Translation 'Assistant')
        $items[$assistantAt].Data.Screen | Should -Be 'Assistant'
        $items[$assistantAt].Label | Should -Be (Get-Translation 'MainAssistantRow')
        $names | Should -Not -Contain 'MainAssistantDesc'
        $items[$assistantAt].Desc | Should -Be (Get-Translation 'MainDescAssistant')
        foreach ($i in -2, -1) { Test-WtItemFocusable -Item $items[$assistantAt + $i] | Should -BeFalse }
        $exitAt | Should -Be ($assistantAt + 2)
        $items[$exitAt - 1].Kind | Should -Be 'Spacer'
        @($items | Where-Object { Test-WtItemFocusable -Item $_ } | ForEach-Object Name)[-1] | Should -Be 'Exit'
        $exitAt | Should -Be ($items.Count - 1)
    }
    It 'the assistant row is named after the product in both languages' {
        $script:Translations['TR']['MainAssistantRow'] | Should -Be 'WinToolify AI Asistan'
        $script:Translations['EN']['MainAssistantRow'] | Should -Be 'WinToolify AI Assistant'
        $script:Translations['TR']['MainToolsRule'] | Should -Be 'Araclar ve Ayarlar'
        $script:Translations['EN']['MainToolsRule'] | Should -Be 'Tools and Settings'
    }
    It 'every main-menu row that takes the cursor carries a description, in both languages, ASCII only' {
        try {
            foreach ($lang in 'EN', 'TR') {
                $script:Language = $lang
                $rows = @(Get-WtMainMenuItems | Where-Object { Test-WtItemFocusable -Item $_ })
                $rows.Count | Should -Be 12 -Because "$lang menu"
                foreach ($row in $rows) {
                    $desc = [string]$row.Desc
                    $desc | Should -Not -BeNullOrEmpty -Because "$lang description for '$($row.Name)'"
                    $desc.Length | Should -BeLessOrEqual 130 -Because "$lang description for '$($row.Name)'"
                    ([regex]::Matches($desc, '[^\x00-\x7F]')).Count | Should -Be 0 -Because "$lang '$($row.Name)' must be ASCII-folded"
                }
                @($rows | ForEach-Object { [string]$_.Desc } | Sort-Object -Unique).Count | Should -Be 12 -Because "$lang menu"
            }
        }
        finally { $script:Language = 'EN' }
    }
    It 'no other screen carries row descriptions - the band belongs to the main menu' {
        foreach ($item in @(Get-WtBasicToolsItems)) { [string]$item.Desc | Should -BeNullOrEmpty }
    }

    It 'every main-menu row has a label in both languages' {
        try {
            foreach ($lang in 'EN', 'TR') {
                $script:Language = $lang
                foreach ($item in @(Get-WtMainMenuItems | Where-Object Kind -ne 'Spacer')) {
                    $item.Label | Should -Not -BeNullOrEmpty -Because "$lang row '$($item.Name)'"
                }
            }
        }
        finally { $script:Language = 'EN' }
    }
    It 'the System Settings breadcrumb no longer goes through Basic Tools' {
        $src = Get-Content -LiteralPath $script:TargetPath -Raw
        $src | Should -Not -Match "Get-WtBreadcrumb -Keys 'MainMenu', 'BasicTools', 'SystemSettings'"
        $src | Should -Match "Get-WtBreadcrumb -Keys 'MainMenu', 'SystemSettings'"
    }
}

Describe 'Menu tree - Actions' {
    BeforeAll { $script:actions = @(Get-WtActionToolsItems | Where-Object { Test-WtItemFocusable -Item $_ }) }
    It 'has at least 10 entries (design rule) - in fact 51 since the VCRedist installer moved in' {
        $actions.Count | Should -BeGreaterOrEqual 10
        $actions.Count | Should -Be 51
    }
    It 'covers every V1 Action Tools key by Name, except the two folded into RenewIpLease' {
        $v1 = 'UpdateWindowsStoreApps', 'UpdateAllProgramsWithWinGet', 'RepairWindowsSystemFiles', 'WindowsDiskCleanup', 'CleanUnnecessaryFiles', 'FlushDNSCache', 'PingTest', 'RestartPrinter', 'ClearPrintQueue', 'UpdateGroupPolicies', 'RestartInSafeMode', 'ShutdownComputer', 'RestartComputer'
        $names = @($actions | ForEach-Object Name)
        foreach ($k in $v1) { $names | Should -Contain $k }
        $names | Should -Contain 'RenewIpLease'
        foreach ($folded in 'ReleaseIPConfig', 'RenewIPConfig') { $names | Should -Not -Contain $folded }
    }
    It 'every entry is an Action whose label resolves in both languages' {
        foreach ($a in $actions) {
            $a.Kind | Should -Be 'Action'
            $script:Translations['EN'].ContainsKey($a.Name) | Should -BeTrue -Because "EN needs '$($a.Name)'"
            $script:Translations['TR'].ContainsKey($a.Name) | Should -BeTrue -Because "TR needs '$($a.Name)'"
        }
    }
    It 'destructive entries go through the YES gate' {
        foreach ($n in 'RestartInSafeMode', 'ExitSafeMode', 'ShutdownComputer', 'RestartComputer') {
            ($actions | Where-Object Name -eq $n).Data.Power | Should -BeTrue
            ($actions | Where-Object Name -eq $n).Risk | Should -Be 'ADVANCED'
        }
    }
}

Describe 'Menu tree - Information' {
    BeforeAll { $script:info = @(Get-WtInfoToolsItems | Where-Object { Test-WtItemFocusable -Item $_ }) }
    It 'has 50 entries (>= 10)' { $info.Count | Should -Be 50 }
    It 'covers every V1 Information Tools key by Name, except the five folded into richer rows' {
        $v1 = 'ShowComputerAndUserName', 'GetSystemInformation', 'ShowWindowsLicenseStatus', 'ShowWindowsVersion', 'ListUserAccounts', 'ShowWifiPassword', 'ShowFullIPConfig', 'CheckDiskStatus', 'ShowStorageStatus', 'ScanHardDisk', 'ShowCPUInfo', 'ShowRAMUsage', 'ShowPrinterStatus'
        $names = @($info | ForEach-Object Name)
        foreach ($k in $v1) { $names | Should -Contain $k }

        $folded = @{
            'ShowComputerSerialNumber' = 'MotherboardBiosInfo'
            'ShowIPAddress'            = 'ShowIPConfigSummary'
            'OpeningPort'              = 'ShowListeningPorts'
            'ShowActiveWindowsLicense' = 'ShowWindowsLicenseStatus'
            'ListInstalledPrinters'    = 'ShowPrinterStatus'
        }
        foreach ($old in $folded.Keys) {
            $names | Should -Not -Contain $old
            $names | Should -Contain $folded[$old]
        }
    }
    It 'labels resolve in both languages' {
        foreach ($i in $info) {
            $script:Translations['EN'].ContainsKey($i.Name) | Should -BeTrue -Because "EN needs '$($i.Name)'"
            $script:Translations['TR'].ContainsKey($i.Name) | Should -BeTrue -Because "TR needs '$($i.Name)'"
        }
    }
    It 'every row renders in the box - captured, or an inline flow that paints its own panel' {
        foreach ($i in $info) {
            $i.Kind | Should -Be 'Action'
            $i.Data.Console | Should -BeNullOrEmpty -Because "$($i.Name) must not clear the screen any more"
            if (-not $i.Data.Captured) {
                $i.Name | Should -BeIn @('ShowWifiPassword', 'SystemHealthReport', 'LargestFoldersReport', 'LargestFilesReport', 'DnsResolutionTest')
            }
            $i.Data.Action | Should -Not -BeNullOrEmpty
        }
    }
    It 'no captured action calls Read-Host - it would deadlock behind the capture' {
        foreach ($i in @($info | Where-Object { $_.Data.Captured })) {
            [string]$i.Data.Action | Should -Not -Match 'Read-Host' -Because $i.Name
        }
    }
    It 'never calls Get-WmiObject (absent in PowerShell 7)' {
        (Get-Command Get-WtInfoToolsItems).Definition | Should -Not -Match 'Get-WmiObject'
    }
}

Describe 'Menu tree - System Settings' {
    It 'the 8 groups hold at least 10 settings in total (design rule) - 28 in fact' {
        $groups = @(Get-WtSystemSettingsGroups -GpuSupported $true -FirewallState @{ Enabled = $true; Known = $true } -DohSupported $true)
        @($groups | ForEach-Object SectionKey) | Should -Be @('PowerPlan', 'GamingTweaks', 'FastStartup', 'Firewall', 'ContextMenu', 'ExplorerView', 'DnsPreset', 'Blocklist')
        $count = 0
        foreach ($g in $groups) { $count += @(& $g.GetCatalog $g).Count }
        $count | Should -BeGreaterOrEqual 10
        $count | Should -Be 28
    }
    It 'V1 firewall + fast startup live here as undoable entries' {
        $groups = @(Get-WtSystemSettingsGroups -GpuSupported $true -FirewallState @{ Enabled = $true; Known = $true } -DohSupported $true)
        $fw = $groups | Where-Object SectionKey -eq 'Firewall'
        (@(& $fw.GetCatalog $fw))[0].Name | Should -Be 'DisableFirewall'
        $fs = $groups | Where-Object SectionKey -eq 'FastStartup'
        @(& $fs.GetCatalog $fs).Count | Should -Be 1
    }
}

Describe 'Menu tree - Services' {
    It 'has >= 10 services' { @(Get-WtServiceCatalog).Count | Should -BeGreaterOrEqual 10 }
}

Describe 'Menu tree - Apps' {
    It 'has >= 10 packages and the hidden-by-default legacy group' {
        @(Get-WtPackageCatalog).Count | Should -BeGreaterOrEqual 10
        @((Get-WtPackageCatalog) | Where-Object Legacy).Count | Should -BeGreaterOrEqual 10
    }
}

Describe 'Menu tree - Privacy' {
    It 'the Privacy menu links the seven screens' {
        @((Get-WtPrivacyMenuItems) | ForEach-Object { $_.Data.Screen }) | Should -Be @('PrivacyTelemetry', 'PrivacyAppPermissions', 'PrivacyAi', 'PrivacySearchUi', 'PrivacyEdge', 'PrivacyOffice', 'PrivacyUpdate')
    }
    It 'every Privacy screen holds >= 10 settings on Windows 11 and on Windows 10' {
        $sections = @(Get-WtApplySectionCatalog)
        foreach ($screen in @(Get-WtPrivacyScreenCatalog)) {
            foreach ($isW11 in $true, $false) {
                $count = 0
                foreach ($g in @(Get-WtPrivacyGroups -Key $screen.Key -IsWindows11 $isW11 -Sections $sections)) { $count += @(& $g.GetCatalog $g).Count }
                $count | Should -BeGreaterOrEqual 10 -Because "$($screen.Key) on W11=$isW11"
            }
        }
    }
    It 'privacy screens carry their hardening groups plus the existing sections' {
        $cat = @(Get-WtPrivacyScreenCatalog)
        ($cat | Where-Object Key -eq 'PrivacyTelemetry').ExistingSections | Should -Be @('Telemetry', 'ActivityAdvertising')
        ($cat | Where-Object Key -eq 'PrivacyAppPermissions').ExistingSections | Should -Be @('CapabilityDefaults')
        ($cat | Where-Object Key -eq 'PrivacyAi').ExistingSections | Should -Be @('AiPrivacy')
        ($cat | Where-Object Key -eq 'PrivacySearchUi').ExistingSections | Should -Be @('SearchSuggestions')
        foreach ($key in 'PrivacyEdge', 'PrivacyOffice', 'PrivacyUpdate') {
            @(($cat | Where-Object Key -eq $key).ExistingSections).Count | Should -Be 0 -Because "$key hosts hardening rows only"
        }
    }
    It 'hosts the Security group on the Windows Update screen - no Security screen of its own' {
        $cat = @(Get-WtPrivacyScreenCatalog)
        $cat.Count | Should -Be 7
        $cat | Where-Object Key -eq 'PrivacySecurity' | Should -BeNullOrEmpty
        @(($cat | Where-Object Key -eq 'PrivacyUpdate').HardeningGroups | ForEach-Object Group) | Should -Be @('Update', 'Security')
        @(($cat | Where-Object Key -eq 'PrivacyUpdate').HardeningGroups | ForEach-Object Section) | Should -Be @('HardeningUpdate', 'HardeningSecurity')
    }
}
