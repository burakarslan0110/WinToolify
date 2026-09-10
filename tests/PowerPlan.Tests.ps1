#Requires -Modules Pester

<#
.SYNOPSIS
    The powercfg wrapper, the two locale-independent parsers (GUIDs and
    0x setting indexes), the power-plan catalog and live state, and the
    capture/apply/re-read delegates behind
    Invoke-WtApplyPowerPlanSelection.

    powercfg.exe does not exist on the macOS dev host, so every function
    here goes through Invoke-WtPowercfg's injectable -PowercfgAction; the
    fixtures below are shaped like real powercfg output (English AND
    Turkish labels - the parsers must key on GUIDs and hex tokens only,
    never label text).
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath

    $script:BalancedGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'
    $script:HighPerfGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'

    $script:ListEnglish = @(
        'Existing Power Schemes (* Active)',
        '-----------------------------------',
        'Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced) *',
        'Power Scheme GUID: 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c  (High performance)'
    )
    $script:ListTurkish = @(
        'Mevcut Guc Duzenleri (* Etkin)',
        '-----------------------------------',
        "Guc Duzeni GUID'i: 381b4222-f694-41f0-9685-ff5bb260df2e  (Dengeli) *",
        "Guc Duzeni GUID'i: 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c  (Yuksek performans)"
    )
    $script:QueryBlock = @(
        'Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)',
        '  Subgroup GUID: 54533251-82be-4824-96c1-47b60b740d00  (Processor power management)',
        '    Power Setting GUID: 0cc5b647-c1df-4637-891a-dec35c318583  (Processor performance core parking min cores)',
        '      Minimum Possible Setting: 0x00000000',
        '      Maximum Possible Setting: 0x00000064',
        '      Possible Settings increment: 0x00000001',
        '      Possible Settings units: %',
        '    Current AC Power Setting Index: 0x00000064',
        '    Current DC Power Setting Index: 0x00000032'
    )

    function New-FakePowercfg {
        param([hashtable]$Responses)
        $calls = New-Object System.Collections.Generic.List[object]
        $action = {
            param($Arguments)
            $calls.Add(@($Arguments))
            $key = ($Arguments[0]).ToLowerInvariant()
            if ($Responses.ContainsKey($key)) {
                $r = $Responses[$key]
                if ($r -is [scriptblock]) { return (& $r $Arguments) }
                return $r
            }
            return [PSCustomObject]@{ ExitCode = 0; Output = @() }
        }.GetNewClosure()
        return [PSCustomObject]@{ Action = $action; Calls = $calls }
    }
    function Ok { param([string[]]$Lines) [PSCustomObject]@{ ExitCode = 0; Output = @($Lines) } }
    function Fail { param([string[]]$Lines) [PSCustomObject]@{ ExitCode = 1; Output = @($Lines) } }
}

Describe 'Get-WtPowercfgGuids' {
    It 'extracts every GUID from an English /list block, lower-cased, in order' {
        Get-WtPowercfgGuids -Lines $ListEnglish | Should -Be @($BalancedGuid, $HighPerfGuid)
    }

    It 'extracts the identical list from the same block with Turkish labels' {
        Get-WtPowercfgGuids -Lines $ListTurkish | Should -Be @($BalancedGuid, $HighPerfGuid)
    }

    It 'returns an empty array for lines without a GUID' {
        @(Get-WtPowercfgGuids -Lines @('nothing here', '')).Count | Should -Be 0
    }
}

Describe 'Get-WtPowerSettingIndexes' {
    It 'returns Ac/Dc from the LAST two hex tokens, ignoring the Min/Max/Increment tokens before them' {
        $r = Get-WtPowerSettingIndexes -Lines $QueryBlock
        $r.Ac | Should -Be 100
        $r.Dc | Should -Be 50
    }

    It 'returns $null when fewer than two hex tokens exist' {
        Get-WtPowerSettingIndexes -Lines @('Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e', 'only one 0x00000064') | Should -BeNullOrEmpty
    }
}

Describe 'Get-WtPowerSettingCurrentIndexes' {
    It 'calls /query first with the three GUIDs verbatim and does not fall back when it parses' {
        $fake = New-FakePowercfg -Responses @{ '/query' = (Ok $QueryBlock) }
        $r = Get-WtPowerSettingCurrentIndexes -SchemeGuid $BalancedGuid -SubGroupGuid $script:WtPowerProcessorSubGroupGuid -SettingGuid $script:WtPowerCoreParkingSettings[0].Guid -PowercfgAction $fake.Action
        $r.Ac | Should -Be 100
        $r.Dc | Should -Be 50
        $fake.Calls.Count | Should -Be 1
        $fake.Calls[0] | Should -Be @('/query', $BalancedGuid, $script:WtPowerProcessorSubGroupGuid, $script:WtPowerCoreParkingSettings[0].Guid)
    }

    It 'falls back to /qh only when /query yields no index pair' {
        $fake = New-FakePowercfg -Responses @{ '/query' = (Ok @('no indexes here')); '/qh' = (Ok $QueryBlock) }
        $r = Get-WtPowerSettingCurrentIndexes -SchemeGuid $BalancedGuid -SubGroupGuid 'sub' -SettingGuid 'set' -PowercfgAction $fake.Action
        $r.Ac | Should -Be 100
        $fake.Calls.Count | Should -Be 2
        $fake.Calls[1][0] | Should -Be '/qh'
    }

    It 'returns $null when both variants fail to yield a pair' {
        $fake = New-FakePowercfg -Responses @{ '/query' = (Fail @('bad')); '/qh' = (Fail @('bad')) }
        Get-WtPowerSettingCurrentIndexes -SchemeGuid 'a' -SubGroupGuid 'b' -SettingGuid 'c' -PowercfgAction $fake.Action | Should -BeNullOrEmpty
    }
}

Describe 'Get-WtPowerPlanCatalog' {
    BeforeAll { $script:PowerCatalog = @(Get-WtPowerPlanCatalog) }

    It 'has exactly UltimatePerformance and DisableCoreParking, both CAUTION with a consequence and a DisplayLabel' {
        @($PowerCatalog | Select-Object -ExpandProperty Name) | Should -Be @('UltimatePerformance', 'DisableCoreParking')
        foreach ($entry in $PowerCatalog) {
            $entry.Risk | Should -Be 'CAUTION'
            $entry.Consequence | Should -Not -BeNullOrEmpty
            $entry.DisplayLabel | Should -Not -BeNullOrEmpty
        }
    }

    It 'exposes its fixed GUIDs as script constants' {
        $script:WtPowerUltimateGuid | Should -Be 'e9a42b02-d5df-448d-aa00-03f14749eb61'
        $script:WtPowerWinToolifyUltimateGuid | Should -Be '4b56727b-66b4-485a-8d8b-a8bef4f7dfb8'
        $script:WtPowerProcessorSubGroupGuid | Should -Be '54533251-82be-4824-96c1-47b60b740d00'
        @($script:WtPowerCoreParkingSettings | Select-Object -ExpandProperty Guid) | Should -Be @('0cc5b647-c1df-4637-891a-dec35c318583', '0cc5b647-c1df-4637-891a-dec35c318584')
        @($script:WtPowerCoreParkingSettings | Select-Object -ExpandProperty Label) | Should -Be @('CPMINCORES', 'CPMINCORES1')
    }
}

Describe 'Get-WtPowerPlanState' {
    BeforeAll { $script:PowerCatalog = @(Get-WtPowerPlanCatalog) }

    It 'reports UltimatePerformance Applied when the active GUID is the native Ultimate GUID' {
        $fake = New-FakePowercfg -Responses @{ '/getactivescheme' = (Ok @("Power Scheme GUID: $($script:WtPowerUltimateGuid)  (Ultimate Performance)")) }
        (Get-WtPowerPlanState -Entry ($PowerCatalog | Where-Object Name -eq 'UltimatePerformance') -PowercfgAction $fake.Action).Applied | Should -BeTrue
    }

    It 'reports UltimatePerformance Applied when the active GUID is the WinToolify copy' {
        $fake = New-FakePowercfg -Responses @{ '/getactivescheme' = (Ok @("Power Scheme GUID: $($script:WtPowerWinToolifyUltimateGuid)  (Ultimate Performance (WinToolify))")) }
        (Get-WtPowerPlanState -Entry ($PowerCatalog | Where-Object Name -eq 'UltimatePerformance') -PowercfgAction $fake.Action).Applied | Should -BeTrue
    }

    It 'reports UltimatePerformance NotApplied for Balanced' {
        $fake = New-FakePowercfg -Responses @{ '/getactivescheme' = (Ok @("Power Scheme GUID: $BalancedGuid  (Balanced)")) }
        (Get-WtPowerPlanState -Entry ($PowerCatalog | Where-Object Name -eq 'UltimatePerformance') -PowercfgAction $fake.Action).Applied | Should -BeFalse
    }

    It 'reports DisableCoreParking Applied only when both parsed indexes are 100' {
        $entry = $PowerCatalog | Where-Object Name -eq 'DisableCoreParking'
        $bothHundred = $QueryBlock | ForEach-Object { $_ -replace '0x00000032', '0x00000064' }
        $fakeYes = New-FakePowercfg -Responses @{ '/getactivescheme' = (Ok @("Power Scheme GUID: $BalancedGuid  (Balanced)")); '/query' = (Ok $bothHundred) }
        (Get-WtPowerPlanState -Entry $entry -PowercfgAction $fakeYes.Action).Applied | Should -BeTrue

        $fakeNo = New-FakePowercfg -Responses @{ '/getactivescheme' = (Ok @("Power Scheme GUID: $BalancedGuid  (Balanced)")); '/query' = (Ok $QueryBlock) }
        (Get-WtPowerPlanState -Entry $entry -PowercfgAction $fakeNo.Action).Applied | Should -BeFalse
    }

    It 'reports DisableCoreParking NotApplied when the indexes are unreadable' {
        $entry = $PowerCatalog | Where-Object Name -eq 'DisableCoreParking'
        $fake = New-FakePowercfg -Responses @{ '/getactivescheme' = (Ok @("Power Scheme GUID: $BalancedGuid  (Balanced)")); '/query' = (Fail @()); '/qh' = (Fail @()) }
        (Get-WtPowerPlanState -Entry $entry -PowercfgAction $fake.Action).Applied | Should -BeFalse
    }
}

Describe 'Get-WtPowerPlanCaptureState' {
    BeforeAll {
        $script:ActiveBalanced = Ok @("Power Scheme GUID: $BalancedGuid  (Balanced)")
        $script:UltimateNative = $script:WtPowerUltimateGuid
        $script:UltimateCopy = $script:WtPowerWinToolifyUltimateGuid
    }

    It 'creates a PowerPlan item targeting the WinToolify copy and marks it CreatedScheme when neither Ultimate GUID exists yet' {
        $fake = New-FakePowercfg -Responses @{ '/getactivescheme' = $ActiveBalanced; '/list' = (Ok $ListEnglish); '/query' = (Fail @('does not exist')) }
        $capture = Get-WtPowerPlanCaptureState -SelectedNames @('UltimatePerformance') -PowercfgAction $fake.Action
        $item = @($capture.Items)[0]
        $item.ItemType | Should -Be 'PowerPlan'
        $item.PreviousActiveScheme | Should -Be $BalancedGuid
        $item.TargetScheme | Should -Be $UltimateCopy
        $item.CreatedScheme | Should -Be $UltimateCopy
    }

    It 'targets the native Ultimate GUID with no CreatedScheme when it is listed' {
        $fake = New-FakePowercfg -Responses @{ '/getactivescheme' = $ActiveBalanced; '/list' = (Ok ($ListEnglish + "Power Scheme GUID: $UltimateNative  (Ultimate Performance)")) }
        $item = @((Get-WtPowerPlanCaptureState -SelectedNames @('UltimatePerformance') -PowercfgAction $fake.Action).Items)[0]
        $item.TargetScheme | Should -Be $UltimateNative
        $item.CreatedScheme | Should -BeNullOrEmpty
    }

    It 'targets the WinToolify copy with no CreatedScheme when the copy is already listed' {
        $fake = New-FakePowercfg -Responses @{ '/getactivescheme' = $ActiveBalanced; '/list' = (Ok ($ListEnglish + "Power Scheme GUID: $UltimateCopy  (Ultimate Performance (WinToolify))")) }
        $item = @((Get-WtPowerPlanCaptureState -SelectedNames @('UltimatePerformance') -PowercfgAction $fake.Action).Items)[0]
        $item.TargetScheme | Should -Be $UltimateCopy
        $item.CreatedScheme | Should -BeNullOrEmpty
    }

    It 'records core-parking items on the pre-run active scheme when only DisableCoreParking is selected, one per readable setting' {
        $fake = New-FakePowercfg -Responses @{ '/getactivescheme' = $ActiveBalanced; '/list' = (Ok $ListEnglish); '/query' = (Ok $QueryBlock) }
        $capture = Get-WtPowerPlanCaptureState -SelectedNames @('DisableCoreParking') -PowercfgAction $fake.Action
        $items = @($capture.Items)
        $items.Count | Should -Be 2
        foreach ($item in $items) {
            $item.ItemType | Should -Be 'PowerSetting'
            $item.SchemeGuid | Should -Be $BalancedGuid
            $item.SubGroupGuid | Should -Be $script:WtPowerProcessorSubGroupGuid
            $item.PreviousAc | Should -Be 100
            $item.PreviousDc | Should -Be 50
        }
        @($items | Select-Object -ExpandProperty SettingLabel) | Should -Be @('CPMINCORES', 'CPMINCORES1')
        @($capture.Skipped).Count | Should -Be 0
    }

    It 'orders the PowerPlan item first and points the core-parking items at the Ultimate TargetScheme when both are selected' {
        $fake = New-FakePowercfg -Responses @{ '/getactivescheme' = $ActiveBalanced; '/list' = (Ok $ListEnglish); '/query' = (Ok $QueryBlock) }
        $items = @((Get-WtPowerPlanCaptureState -SelectedNames @('DisableCoreParking', 'UltimatePerformance') -PowercfgAction $fake.Action).Items)
        $items[0].ItemType | Should -Be 'PowerPlan'
        foreach ($item in $items[1..($items.Count - 1)]) {
            $item.ItemType | Should -Be 'PowerSetting'
            $item.SchemeGuid | Should -Be $UltimateCopy
        }
    }

    It 'omits a setting whose indexes are unreadable and names it in Skipped (CPMINCORES1 only when its query succeeds)' {
        $responder = {
            param($Arguments)
            if ($Arguments[3] -eq $script:WtPowerCoreParkingSettings[1].Guid) { return (Fail @('The power scheme, subgroup or setting specified does not exist.')) }
            return (Ok $QueryBlock)
        }
        $fake = New-FakePowercfg -Responses @{ '/getactivescheme' = $ActiveBalanced; '/list' = (Ok $ListEnglish); '/query' = $responder; '/qh' = $responder }
        $capture = Get-WtPowerPlanCaptureState -SelectedNames @('DisableCoreParking') -PowercfgAction $fake.Action
        @($capture.Items).Count | Should -Be 1
        @($capture.Items)[0].SettingLabel | Should -Be 'CPMINCORES'
        @($capture.Skipped) | Should -Be @('CPMINCORES1')
    }
    It 'reports every core-parking setting as Skipped (and captures no items) when the active scheme is unreadable' {
        $fake = New-FakePowercfg -Responses @{ '/getactivescheme' = (Fail @('boom')); '/list' = (Ok $ListEnglish) }
        $capture = Get-WtPowerPlanCaptureState -SelectedNames @('DisableCoreParking') -PowercfgAction $fake.Action
        @($capture.Items).Count | Should -Be 0
        @($capture.Skipped) | Should -Be @('CPMINCORES', 'CPMINCORES1')
    }
}

Describe 'Invoke-WtApplyPowerPlanItem / Test-WtPowerPlanItemApplied' {
    BeforeAll {
        $script:UltimateNative = $script:WtPowerUltimateGuid
        $script:UltimateCopy = $script:WtPowerWinToolifyUltimateGuid
    }

    It 'issues /duplicatescheme, /changename, /setactive in that order for a PowerPlan item that needs creation' {
        $fake = New-FakePowercfg -Responses @{}
        $item = [PSCustomObject]@{ ItemType = 'PowerPlan'; CatalogEntry = 'UltimatePerformance'; PreviousActiveScheme = $BalancedGuid; TargetScheme = $UltimateCopy; CreatedScheme = $UltimateCopy }
        Invoke-WtApplyPowerPlanItem -Item $item -PowercfgAction $fake.Action
        @($fake.Calls | ForEach-Object { $_[0] }) | Should -Be @('/duplicatescheme', '/changename', '/setactive')
        $fake.Calls[0] | Should -Be @('/duplicatescheme', $UltimateNative, $UltimateCopy)
        $fake.Calls[1][1] | Should -Be $UltimateCopy
        $fake.Calls[2] | Should -Be @('/setactive', $UltimateCopy)
    }

    It 'skips creation and only activates when CreatedScheme is null' {
        $fake = New-FakePowercfg -Responses @{}
        $item = [PSCustomObject]@{ ItemType = 'PowerPlan'; CatalogEntry = 'UltimatePerformance'; PreviousActiveScheme = $BalancedGuid; TargetScheme = $UltimateNative; CreatedScheme = $null }
        Invoke-WtApplyPowerPlanItem -Item $item -PowercfgAction $fake.Action
        @($fake.Calls | ForEach-Object { $_[0] }) | Should -Be @('/setactive')
    }

    It 'throws with powercfg output on a failed duplicate and attempts no /setactive afterwards' {
        $fake = New-FakePowercfg -Responses @{ '/duplicatescheme' = (Fail @('Invalid Parameters -- try "/?" for help')) }
        $item = [PSCustomObject]@{ ItemType = 'PowerPlan'; CatalogEntry = 'UltimatePerformance'; PreviousActiveScheme = $BalancedGuid; TargetScheme = $UltimateCopy; CreatedScheme = $UltimateCopy }
        { Invoke-WtApplyPowerPlanItem -Item $item -PowercfgAction $fake.Action } | Should -Throw '*Invalid Parameters*'
        @($fake.Calls | ForEach-Object { $_[0] }) | Should -Not -Contain '/setactive'
    }

    It 'throws before any index write when a PowerSetting item''s scheme does not exist' {
        $fake = New-FakePowercfg -Responses @{ '/list' = (Ok $ListEnglish); '/query' = (Fail @('does not exist')) }
        $item = [PSCustomObject]@{ ItemType = 'PowerSetting'; CatalogEntry = 'DisableCoreParking'; SchemeGuid = $UltimateCopy; SubGroupGuid = 'sub'; SettingGuid = 'set'; SettingLabel = 'CPMINCORES'; PreviousAc = 10; PreviousDc = 10 }
        { Invoke-WtApplyPowerPlanItem -Item $item -PowercfgAction $fake.Action } | Should -Throw '*not available*'
        @($fake.Calls | ForEach-Object { $_[0] }) | Should -Not -Contain '/setacvalueindex'
    }

    It 'writes both indexes and re-activates only when the scheme is the active one' {
        $active = New-FakePowercfg -Responses @{ '/list' = (Ok $ListEnglish); '/getactivescheme' = (Ok @("Power Scheme GUID: $BalancedGuid  (Balanced)")) }
        $item = [PSCustomObject]@{ ItemType = 'PowerSetting'; CatalogEntry = 'DisableCoreParking'; SchemeGuid = $BalancedGuid; SubGroupGuid = 'sub'; SettingGuid = 'set'; SettingLabel = 'CPMINCORES'; PreviousAc = 10; PreviousDc = 10 }
        Invoke-WtApplyPowerPlanItem -Item $item -PowercfgAction $active.Action
        $switches = @($active.Calls | ForEach-Object { $_[0] })
        $switches | Should -Contain '/setacvalueindex'
        $switches | Should -Contain '/setdcvalueindex'
        $switches[-1] | Should -Be '/setactive'
        $active.Calls.Where({ $_[0] -eq '/setacvalueindex' })[0] | Should -Be @('/setacvalueindex', $BalancedGuid, 'sub', 'set', '100')

        $inactive = New-FakePowercfg -Responses @{ '/list' = (Ok $ListEnglish); '/getactivescheme' = (Ok @("Power Scheme GUID: $HighPerfGuid  (High performance)")) }
        Invoke-WtApplyPowerPlanItem -Item $item -PowercfgAction $inactive.Action
        $switches2 = @($inactive.Calls | ForEach-Object { $_[0] })
        $switches2 | Should -Contain '/setacvalueindex'
        $switches2 | Should -Contain '/setdcvalueindex'
        $switches2 | Should -Not -Contain '/setactive'
    }

    It 'Test-WtPowerPlanItemApplied: PowerPlan compares the active GUID to TargetScheme; PowerSetting requires 100/100' {
        $planItem = [PSCustomObject]@{ ItemType = 'PowerPlan'; TargetScheme = $UltimateCopy }
        $yes = New-FakePowercfg -Responses @{ '/getactivescheme' = (Ok @("Power Scheme GUID: $UltimateCopy  (x)")) }
        Test-WtPowerPlanItemApplied -Item $planItem -PowercfgAction $yes.Action | Should -BeTrue
        $no = New-FakePowercfg -Responses @{ '/getactivescheme' = (Ok @("Power Scheme GUID: $BalancedGuid  (x)")) }
        Test-WtPowerPlanItemApplied -Item $planItem -PowercfgAction $no.Action | Should -BeFalse

        $settingItem = [PSCustomObject]@{ ItemType = 'PowerSetting'; SchemeGuid = $BalancedGuid; SubGroupGuid = 'sub'; SettingGuid = 'set' }
        $bothHundred = $QueryBlock | ForEach-Object { $_ -replace '0x00000032', '0x00000064' }
        Test-WtPowerPlanItemApplied -Item $settingItem -PowercfgAction (New-FakePowercfg -Responses @{ '/query' = (Ok $bothHundred) }).Action | Should -BeTrue
        Test-WtPowerPlanItemApplied -Item $settingItem -PowercfgAction (New-FakePowercfg -Responses @{ '/query' = (Ok $QueryBlock) }).Action | Should -BeFalse
    }
}

Describe 'Restore-WtPowerPlanItem / Restore-WtPowerSettingItem' {
    BeforeAll { $script:UltimateCopy = $script:WtPowerWinToolifyUltimateGuid }

    It 'PowerPlan restore re-activates PreviousActiveScheme and deletes CreatedScheme only when non-null' {
        $fake = New-FakePowercfg -Responses @{}
        Restore-WtPowerPlanItem -Item ([PSCustomObject]@{ PreviousActiveScheme = $BalancedGuid; CreatedScheme = $UltimateCopy }) -PowercfgAction $fake.Action
        @($fake.Calls | ForEach-Object { $_[0] }) | Should -Be @('/setactive', '/delete')
        $fake.Calls[0] | Should -Be @('/setactive', $BalancedGuid)
        $fake.Calls[1] | Should -Be @('/delete', $UltimateCopy)

        $fake2 = New-FakePowercfg -Responses @{}
        Restore-WtPowerPlanItem -Item ([PSCustomObject]@{ PreviousActiveScheme = $BalancedGuid; CreatedScheme = $null }) -PowercfgAction $fake2.Action
        @($fake2.Calls | ForEach-Object { $_[0] }) | Should -Be @('/setactive')
    }

    It 'PowerPlan restore throws when re-activation fails' {
        $fake = New-FakePowercfg -Responses @{ '/setactive' = (Fail @('boom')) }
        { Restore-WtPowerPlanItem -Item ([PSCustomObject]@{ PreviousActiveScheme = $BalancedGuid; CreatedScheme = $null }) -PowercfgAction $fake.Action } | Should -Throw
    }

    It 'PowerSetting restore writes PreviousAc/PreviousDc and re-activates only the active scheme' {
        $item = [PSCustomObject]@{ SchemeGuid = $BalancedGuid; SubGroupGuid = 'sub'; SettingGuid = 'set'; PreviousAc = 10; PreviousDc = 25 }
        $active = New-FakePowercfg -Responses @{ '/getactivescheme' = (Ok @("Power Scheme GUID: $BalancedGuid  (Balanced)")) }
        Restore-WtPowerSettingItem -Item $item -PowercfgAction $active.Action
        $active.Calls.Where({ $_[0] -eq '/setacvalueindex' })[0] | Should -Be @('/setacvalueindex', $BalancedGuid, 'sub', 'set', '10')
        $active.Calls.Where({ $_[0] -eq '/setdcvalueindex' })[0] | Should -Be @('/setdcvalueindex', $BalancedGuid, 'sub', 'set', '25')
        @($active.Calls | ForEach-Object { $_[0] })[-1] | Should -Be '/setactive'

        $inactive = New-FakePowercfg -Responses @{ '/getactivescheme' = (Ok @("Power Scheme GUID: $HighPerfGuid  (High performance)")) }
        Restore-WtPowerSettingItem -Item $item -PowercfgAction $inactive.Action
        @($inactive.Calls | ForEach-Object { $_[0] }) | Should -Not -Contain '/setactive'
    }
}

Describe 'Hidden power schemes (a duplicated Ultimate plan is not in /list on a laptop)' {
    BeforeEach {
        $script:wt = $script:WtPowerWinToolifyUltimateGuid
        $script:calls = New-Object 'System.Collections.Generic.List[string]'
        $script:hiddenPowercfg = {
            param([string[]]$ArgumentList)
            $script:calls.Add($ArgumentList -join ' ')
            switch ($ArgumentList[0]) {
                '/list' { @{ ExitCode = 0; Output = @('Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced) *') } }
                '/getactivescheme' { @{ ExitCode = 0; Output = @('Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)') } }
                '/query' {
                    if ($ArgumentList[1] -eq $script:wt) { @{ ExitCode = 0; Output = @("Power Scheme GUID: $($script:wt)  (Ultimate Performance (WinToolify))") } }
                    else { @{ ExitCode = 1; Output = @('The power scheme, subgroup or setting specified does not exist.') } }
                }
                '/duplicatescheme' { @{ ExitCode = 1; Output = @('Unable to create a new power scheme', 'The scheme could not be duplicated because a power scheme with the specified GUID already exists.') } }
                default { @{ ExitCode = 0; Output = @() } }
            }
        }
    }

    It 'Test-WtPowerSchemeExists trusts /query, not /list' {
        Test-WtPowerSchemeExists -SchemeGuid $script:wt -PowercfgAction $script:hiddenPowercfg | Should -BeTrue
        Test-WtPowerSchemeExists -SchemeGuid 'ffffffff-0000-0000-0000-000000000000' -PowercfgAction $script:hiddenPowercfg | Should -BeFalse
    }

    It 'does not try to duplicate a scheme that already exists but is hidden from /list' {
        $capture = Get-WtPowerPlanCaptureState -SelectedNames @('UltimatePerformance') -PowercfgAction $script:hiddenPowercfg
        $item = @($capture.Items)[0]
        $item.CreatedScheme | Should -BeNullOrEmpty -Because 'the copy is already there; duplicating again is what powercfg refuses'
        $item.TargetScheme | Should -Be $script:wt
    }

    It 'applies by activating the hidden scheme, with no /duplicatescheme call at all' {
        $capture = Get-WtPowerPlanCaptureState -SelectedNames @('UltimatePerformance') -PowercfgAction $script:hiddenPowercfg
        $script:calls.Clear()
        Invoke-WtApplyPowerPlanItem -Item (@($capture.Items)[0]) -PowercfgAction $script:hiddenPowercfg
        @($script:calls | Where-Object { $_ -like '/duplicatescheme*' }).Count | Should -Be 0
        @($script:calls | Where-Object { $_ -like "/setactive $($script:wt)*" }).Count | Should -Be 1
    }

    It 'still duplicates when the scheme genuinely does not exist yet' {
        $fresh = {
            param([string[]]$ArgumentList)
            $script:calls.Add($ArgumentList -join ' ')
            switch ($ArgumentList[0]) {
                '/list' { @{ ExitCode = 0; Output = @('Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced) *') } }
                '/getactivescheme' { @{ ExitCode = 0; Output = @('Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)') } }
                '/query' { @{ ExitCode = 1; Output = @('does not exist') } }
                default { @{ ExitCode = 0; Output = @() } }
            }
        }
        $capture = Get-WtPowerPlanCaptureState -SelectedNames @('UltimatePerformance') -PowercfgAction $fresh
        $item = @($capture.Items)[0]
        $item.CreatedScheme | Should -Be $script:wt
        $script:calls.Clear()
        Invoke-WtApplyPowerPlanItem -Item $item -PowercfgAction $fresh
        @($script:calls | Where-Object { $_ -like '/duplicatescheme*' }).Count | Should -Be 1
    }

    It 'writes core-parking settings to a hidden scheme instead of refusing' {
        $item = [PSCustomObject]@{
            ItemType = 'PowerSetting'; SchemeGuid = $script:wt
            SubGroupGuid = '54533251-82be-4824-96c1-47b60b740d00'; SettingGuid = '0cc5b647-c1df-4637-891a-dec35c318583'
            AcIndex = 0; DcIndex = 0
        }
        { Invoke-WtApplyPowerPlanItem -Item $item -PowercfgAction $script:hiddenPowercfg } | Should -Not -Throw
    }
}

Describe 'Invoke-WtRemovePowerPlanSelection' {
    BeforeEach {
        $script:active = $script:WtPowerUltimateGuid
        $script:calls = New-Object 'System.Collections.Generic.List[string]'
        $script:fake = {
            param([string[]]$Arguments)
            $script:calls.Add(($Arguments -join ' '))
            switch ($Arguments[0]) {
                '/getactivescheme' { return @{ ExitCode = 0; Output = @("Power Scheme GUID: $script:active  (X)") } }
                '/setactive' { $script:active = $Arguments[1]; return @{ ExitCode = 0; Output = @() } }
                default { return @{ ExitCode = 0; Output = @() } }
            }
        }
        Mock Write-WtUndoEntry { $script:undoItems = @($Items); 'fake.json' }
    }
    It 'activates Balanced, records the Ultimate plan as the previous scheme and re-reads Applied' {
        $r = Invoke-WtRemovePowerPlanSelection -SelectedNames @('UltimatePerformance') -PowercfgAction $fake
        @($calls) | Should -Contain ('/setactive ' + $script:WtPowerBalancedGuid)
        $r.Results[0].Applied | Should -BeTrue
        $undoItems[0].ItemType | Should -Be 'PowerPlan'
        $undoItems[0].PreviousActiveScheme | Should -Be $script:WtPowerUltimateGuid
        $undoItems[0].TargetScheme | Should -Be $script:WtPowerBalancedGuid
        $undoItems[0].CreatedScheme | Should -BeNullOrEmpty
    }
    It 'ignores DisableCoreParking and the section marks only UltimatePerformance removable' {
        $r = Invoke-WtRemovePowerPlanSelection -SelectedNames @('DisableCoreParking') -PowercfgAction $fake
        @($r.Results).Count | Should -Be 0
        $row = (Get-WtProfileSectionCatalog) | Where-Object Key -eq 'PowerPlan'
        (& $row.IsRemovable ([PSCustomObject]@{ Name = 'UltimatePerformance' })) | Should -BeTrue
        (& $row.IsRemovable ([PSCustomObject]@{ Name = 'DisableCoreParking' })) | Should -BeFalse
        $row.TurnOff | Should -Not -BeNullOrEmpty
        $script:Translations['TR']['UndoAction.Revert Power Plan Settings'] | Should -Not -BeNullOrEmpty
    }
}
