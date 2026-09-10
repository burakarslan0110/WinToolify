#Requires -Modules Pester

<#
.SYNOPSIS
    Coverage for the four Windows repair rows - Windows Update
    component reset, Search index rebuild, WMI repository
    verify/salvage and the power scheme default restore. Nothing here
    touches Windows: every row's logic sits behind injectable
    scriptblocks, and the tests feed fixtures shaped like the real
    output through them.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath

    function Get-WtFakeServiceInfo {
        param(
            [string]$Name,
            [string]$StartMode = 'Auto',
            [string]$State = 'Running'
        )
        return [PSCustomObject]@{ Name = $Name; StartMode = $StartMode; State = $State }
    }
}

Describe 'Get-WtWindowsUpdateServicePlan' {
    It 'resolves the five update services in stop order' {
        $lookup = { param($Name) Get-WtFakeServiceInfo -Name $Name }
        $plan = @(Get-WtWindowsUpdateServicePlan -GetServiceInfo $lookup)
        @($plan | ForEach-Object { [string]$_.Name }) | Should -Be @('wuauserv', 'UsoSvc', 'BITS', 'DoSvc', 'CryptSvc')
        @($plan | Where-Object { $_.Disabled }).Count | Should -Be 0
        @($plan | Where-Object { $_.Missing }).Count | Should -Be 0
        @($plan | Where-Object { $_.Running }).Count | Should -Be 5
    }

    It 'flags a service the Services screen set to Disabled' {
        $lookup = {
            param($Name)
            if ($Name -ceq 'BITS') { return Get-WtFakeServiceInfo -Name $Name -StartMode 'Disabled' -State 'Stopped' }
            return Get-WtFakeServiceInfo -Name $Name
        }
        $plan = @(Get-WtWindowsUpdateServicePlan -GetServiceInfo $lookup)
        @($plan | Where-Object { $_.Disabled } | ForEach-Object { [string]$_.Name }) | Should -Be @('BITS')
    }

    It 'flags a service that is not installed at all' {
        $lookup = {
            param($Name)
            if ($Name -ceq 'DoSvc') { return $null }
            return Get-WtFakeServiceInfo -Name $Name
        }
        $plan = @(Get-WtWindowsUpdateServicePlan -GetServiceInfo $lookup)
        @($plan | Where-Object { $_.Missing } | ForEach-Object { [string]$_.Name }) | Should -Be @('DoSvc')
        @($plan | Where-Object { $_.Missing } | ForEach-Object { [string]$_.StartMode }) | Should -Be @('')
    }

    It 'treats a lookup that throws as "not installed" instead of blowing up' {
        $lookup = { param($Name) throw 'WMI is unhappy' }
        $plan = @(Get-WtWindowsUpdateServicePlan -GetServiceInfo $lookup)
        @($plan).Count | Should -Be 5
        @($plan | Where-Object { $_.Missing }).Count | Should -Be 5
    }
}

Describe 'Invoke-WtResetWindowsUpdateComponentsAction' {
    BeforeEach {
        $script:Stopped = New-Object System.Collections.Generic.List[string]
        $script:Started = New-Object System.Collections.Generic.List[string]
        $script:Renamed = New-Object System.Collections.Generic.List[string]
        $script:Removed = New-Object System.Collections.Generic.List[string]
        $script:FakeRoot = Join-Path $TestDrive 'Windows'
        $script:Seams = @{
            ConfirmAction      = { param($Consequence, $Lines) return $true }
            GetPlan            = {
                @(
                    [PSCustomObject]@{ Name = 'wuauserv'; StartMode = 'Auto'; State = 'Running'; Missing = $false; Disabled = $false; Running = $true }
                    [PSCustomObject]@{ Name = 'CryptSvc'; StartMode = 'Auto'; State = 'Running'; Missing = $false; Disabled = $false; Running = $true }
                )
            }
            StopServiceAction  = { param($Name) $script:Stopped.Add([string]$Name) }
            StartServiceAction = { param($Name) $script:Started.Add([string]$Name) }
            GetServiceRunning  = { param($Name) return $true }
            TestPathAction     = { param($Path) return $true }
            RenamePathAction   = { param($Path, $NewName) $script:Renamed.Add([string]$NewName) }
            RemovePathAction   = { param($Path) $script:Removed.Add([string]$Path) }
            SystemRoot         = $script:FakeRoot
            Stamp              = '20260823-101500'
        }
    }

    It 'stops, renames with the timestamp, restarts backwards and only then deletes' {
        $seams = $script:Seams
        $out = @(Invoke-WtResetWindowsUpdateComponentsAction @seams 6>&1 | ForEach-Object { [string]$_ })
        @($script:Stopped) | Should -Be @('wuauserv', 'CryptSvc')
        @($script:Started) | Should -Be @('CryptSvc', 'wuauserv')
        @($script:Renamed) | Should -Be @('SoftwareDistribution.20260823-101500.bak', 'catroot2.20260823-101500.bak')
        @($script:Removed) | Should -Be @(
            (Join-Path $script:FakeRoot 'SoftwareDistribution.20260823-101500.bak'),
            (Join-Path (Join-Path $script:FakeRoot 'System32') 'catroot2.20260823-101500.bak')
        )
        $out | Should -Contain (Get-Translation 'WuResetStarting')
        $out | Should -Contain (Get-Translation 'WuResetDone')
    }

    It 'never touches msiserver - it holds no handle in SoftwareDistribution' {
        $plan = @(Get-WtWindowsUpdateServicePlan -GetServiceInfo { param($Name) Get-WtFakeServiceInfo -Name $Name })
        @($plan | ForEach-Object { [string]$_.Name }) | Should -Not -Contain 'msiserver'
    }

    It 'touches nothing when the consequence gate is refused' {
        $seams = $script:Seams
        $seams['ConfirmAction'] = { param($Consequence, $Lines) return $false }
        $out = @(Invoke-WtResetWindowsUpdateComponentsAction @seams 6>&1 | ForEach-Object { [string]$_ })
        @($script:Stopped).Count | Should -Be 0
        @($script:Renamed).Count | Should -Be 0
        @($script:Removed).Count | Should -Be 0
        $out | Should -Contain (Get-Translation 'ActionCancelled')
    }

    It 'refuses the whole reset when the Services screen disabled one of them' {
        $seams = $script:Seams
        $seams['GetPlan'] = {
            @(
                [PSCustomObject]@{ Name = 'wuauserv'; StartMode = 'Auto'; State = 'Running'; Missing = $false; Disabled = $false; Running = $true }
                [PSCustomObject]@{ Name = 'BITS'; StartMode = 'Disabled'; State = 'Stopped'; Missing = $false; Disabled = $true; Running = $false }
            )
        }
        $out = @(Invoke-WtResetWindowsUpdateComponentsAction @seams 6>&1 | ForEach-Object { [string]$_ })
        @($script:Stopped).Count | Should -Be 0
        @($script:Renamed).Count | Should -Be 0
        $out | Should -Contain ((Get-Translation 'WuResetServiceDisabled') -f 'BITS')
        $out | Should -Contain (Get-Translation 'WuResetAbortedDisabled')
    }

    It 'keeps the renamed trees when a service does not come back' {
        $seams = $script:Seams
        $seams['GetServiceRunning'] = { param($Name) return ($Name -cne 'wuauserv') }
        $out = @(Invoke-WtResetWindowsUpdateComponentsAction @seams 6>&1 | ForEach-Object { [string]$_ })
        @($script:Renamed).Count | Should -Be 2
        @($script:Removed).Count | Should -Be 0
        $out | Should -Contain ((Get-Translation 'WuResetNotRunning') -f 'wuauserv')
        $out | Should -Contain (Get-Translation 'WuResetKeepingBackups')
    }

    It 'reports a folder that is not there instead of renaming it' {
        $seams = $script:Seams
        $seams['TestPathAction'] = { param($Path) return ([string]$Path -clike '*SoftwareDistribution') }
        $out = @(Invoke-WtResetWindowsUpdateComponentsAction @seams 6>&1 | ForEach-Object { [string]$_ })
        @($script:Renamed) | Should -Be @('SoftwareDistribution.20260823-101500.bak')
        @($script:Removed).Count | Should -Be 1
        $out | Should -Contain ((Get-Translation 'WuResetMissingFolder') -f (Join-Path (Join-Path $script:FakeRoot 'System32') 'catroot2'))
    }

    It 'skips a missing service without stopping or starting it' {
        $seams = $script:Seams
        $seams['GetPlan'] = {
            @(
                [PSCustomObject]@{ Name = 'wuauserv'; StartMode = 'Auto'; State = 'Running'; Missing = $false; Disabled = $false; Running = $true }
                [PSCustomObject]@{ Name = 'DoSvc'; StartMode = ''; State = ''; Missing = $true; Disabled = $false; Running = $false }
            )
        }
        $out = @(Invoke-WtResetWindowsUpdateComponentsAction @seams 6>&1 | ForEach-Object { [string]$_ })
        @($script:Stopped) | Should -Be @('wuauserv')
        @($script:Started) | Should -Be @('wuauserv')
        $out | Should -Contain ((Get-Translation 'WuResetServiceMissing') -f 'DoSvc')
    }
}

Describe 'Invoke-WtRebuildSearchIndexAction' {
    BeforeEach {
        $script:Flags = New-Object System.Collections.Generic.List[int]
        $script:SearchStopped = New-Object System.Collections.Generic.List[string]
        $script:SearchStarted = New-Object System.Collections.Generic.List[string]
        $script:SearchSeams = @{
            GetServiceInfo     = { param($Name) Get-WtFakeServiceInfo -Name 'WSearch' -StartMode 'Auto' -State 'Running' }
            StopServiceAction  = { param($Name) $script:SearchStopped.Add([string]$Name) }
            StartServiceAction = { param($Name) $script:SearchStarted.Add([string]$Name) }
            SetSetupFlagAction = { param($Value) $script:Flags.Add([int]$Value) }
        }
    }

    It 'stops WSearch, clears the setup flag and starts it again' {
        $seams = $script:SearchSeams
        $out = @(Invoke-WtRebuildSearchIndexAction @seams 6>&1 | ForEach-Object { [string]$_ })
        @($script:SearchStopped) | Should -Be @('WSearch')
        @($script:SearchStarted) | Should -Be @('WSearch')
        @($script:Flags) | Should -Be @(0)
        $out | Should -Contain (Get-Translation 'SearchIndexRestarted')
    }

    It 'prints the hours-long reindex cost and says why no undo record is kept' {
        $seams = $script:SearchSeams
        $out = @(Invoke-WtRebuildSearchIndexAction @seams 6>&1 | ForEach-Object { [string]$_ })
        $out | Should -Contain (Get-Translation 'SearchIndexCost')
        $out | Should -Contain (Get-Translation 'SearchIndexNoUndoRecord')
    }

    It 'refuses when the Services screen disabled WSearch and never calls Stop-Service' {
        $seams = $script:SearchSeams
        $seams['GetServiceInfo'] = { param($Name) Get-WtFakeServiceInfo -Name 'WSearch' -StartMode 'Disabled' -State 'Stopped' }
        $out = @(Invoke-WtRebuildSearchIndexAction @seams 6>&1 | ForEach-Object { [string]$_ })
        @($script:SearchStopped).Count | Should -Be 0
        @($script:Flags).Count | Should -Be 0
        $out | Should -Contain (Get-Translation 'SearchIndexServiceDisabled')
    }

    It 'says so when WSearch is not installed at all' {
        $seams = $script:SearchSeams
        $seams['GetServiceInfo'] = { param($Name) return $null }
        $out = @(Invoke-WtRebuildSearchIndexAction @seams 6>&1 | ForEach-Object { [string]$_ })
        @($script:SearchStopped).Count | Should -Be 0
        @($script:Flags).Count | Should -Be 0
        $out | Should -Contain (Get-Translation 'SearchIndexServiceMissing')
    }

    It 'puts the flag back to 1 when the service will not start again' {
        $seams = $script:SearchSeams
        $seams['StartServiceAction'] = { param($Name) throw 'Access is denied' }
        $out = @(Invoke-WtRebuildSearchIndexAction @seams 6>&1 | ForEach-Object { [string]$_ })
        @($script:Flags) | Should -Be @(0, 1)
        $out | Should -Contain (Get-Translation 'SearchIndexFlagRolledBack')
    }

    It 'leaves the flag alone when the service cannot even be stopped' {
        $seams = $script:SearchSeams
        $seams['StopServiceAction'] = { param($Name) throw 'The service cannot accept control messages' }
        $out = @(Invoke-WtRebuildSearchIndexAction @seams 6>&1 | ForEach-Object { [string]$_ })
        @($script:Flags).Count | Should -Be 0
        @($script:SearchStarted).Count | Should -Be 0
        $out | Should -Contain ((Get-Translation 'SearchIndexStopFailed') -f 'The service cannot accept control messages')
    }
}

Describe 'Get-WtWmiRepositoryVerdict' {
    It 'calls exit code 0 consistent' {
        (Get-WtWmiRepositoryVerdict -ExitCode 0 -Output @('WMI deposu tutarli')) | Should -Be 'Consistent'
    }

    It 'calls exit code 1 without an error code inconsistent' {
        (Get-WtWmiRepositoryVerdict -ExitCode 1 -Output @('WMI repository is inconsistent')) | Should -Be 'Inconsistent'
    }

    It 'calls exit code 1 carrying 0x80041003 a check that could not run' {
        (Get-WtWmiRepositoryVerdict -ExitCode 1 -Output @('Hata: 0x80041003 Erisim engellendi')) | Should -Be 'CheckFailed'
    }

    It 'does not care about the case of the hex digits' {
        (Get-WtWmiRepositoryVerdict -ExitCode 1 -Output @('0x8004100D')) | Should -Be 'CheckFailed'
        (Get-WtWmiRepositoryVerdict -ExitCode 1 -Output @('0x8004100d')) | Should -Be 'CheckFailed'
    }

    It 'treats any other non-zero exit code as a check that could not run' {
        (Get-WtWmiRepositoryVerdict -ExitCode 2 -Output @('something else entirely')) | Should -Be 'CheckFailed'
    }

    It 'survives empty output' {
        (Get-WtWmiRepositoryVerdict -ExitCode 1 -Output @()) | Should -Be 'Inconsistent'
        (Get-WtWmiRepositoryVerdict -ExitCode 0) | Should -Be 'Consistent'
    }
}

Describe 'Invoke-WtRepairWmiRepositoryAction' {
    BeforeEach {
        $script:WinmgmtCalls = New-Object System.Collections.Generic.List[string]
        $script:VerifyExitCode = 1
        $script:VerifyOutput = @('WMI deposu tutarsiz')
        $script:Winmgmt = {
            param($Arguments)
            $joined = @($Arguments) -join ' '
            $script:WinmgmtCalls.Add([string]$joined)
            if ($joined -ceq '/verifyrepository') {
                return [PSCustomObject]@{ ExitCode = $script:VerifyExitCode; Output = @($script:VerifyOutput) }
            }
            return [PSCustomObject]@{ ExitCode = 0; Output = @('WMI deposu kurtarildi') }
        }
    }

    It 'prints winmgmt output as it came and stops when the repository is consistent' {
        $script:VerifyExitCode = 0
        $script:VerifyOutput = @('WMI deposu tutarli')
        $out = @(Invoke-WtRepairWmiRepositoryAction -WinmgmtAction $script:Winmgmt -ConfirmAction { param($c, $l) return $true } 6>&1 | ForEach-Object { [string]$_ })
        @($script:WinmgmtCalls) | Should -Be @('/verifyrepository')
        $out | Should -Contain 'WMI deposu tutarli'
        $out | Should -Contain (Get-Translation 'WmiRepairConsistent')
    }

    It 'never salvages when the check itself could not run' {
        $script:VerifyExitCode = 1
        $script:VerifyOutput = @('Hata: 0x80041003 Erisim engellendi')
        $out = @(Invoke-WtRepairWmiRepositoryAction -WinmgmtAction $script:Winmgmt -ConfirmAction { param($c, $l) return $true } 6>&1 | ForEach-Object { [string]$_ })
        @($script:WinmgmtCalls) | Should -Be @('/verifyrepository')
        $out | Should -Contain (Get-Translation 'WmiRepairCheckFailed')
    }

    It 'salvages only after the gate is accepted' {
        $out = @(Invoke-WtRepairWmiRepositoryAction -WinmgmtAction $script:Winmgmt -ConfirmAction { param($c, $l) return $true } 6>&1 | ForEach-Object { [string]$_ })
        @($script:WinmgmtCalls) | Should -Be @('/verifyrepository', '/salvagerepository')
        $out | Should -Contain (Get-Translation 'WmiRepairInconsistent')
        $out | Should -Contain 'WMI deposu kurtarildi'
        $out | Should -Contain (Get-Translation 'WmiRepairSalvageOk')
    }

    It 'does not salvage when the gate is refused' {
        $out = @(Invoke-WtRepairWmiRepositoryAction -WinmgmtAction $script:Winmgmt -ConfirmAction { param($c, $l) return $false } 6>&1 | ForEach-Object { [string]$_ })
        @($script:WinmgmtCalls) | Should -Be @('/verifyrepository')
        $out | Should -Contain (Get-Translation 'ActionCancelled')
    }

    It 'never offers /resetrepository' {
        $out = @(Invoke-WtRepairWmiRepositoryAction -WinmgmtAction $script:Winmgmt -ConfirmAction { param($c, $l) return $true } 6>&1 | ForEach-Object { [string]$_ })
        @($script:WinmgmtCalls) | Should -Not -Contain '/resetrepository'
    }

    It 'reports the salvage exit code when salvage itself fails' {
        $failing = {
            param($Arguments)
            $joined = @($Arguments) -join ' '
            $script:WinmgmtCalls.Add([string]$joined)
            if ($joined -ceq '/verifyrepository') { return [PSCustomObject]@{ ExitCode = 1; Output = @('inconsistent') } }
            return [PSCustomObject]@{ ExitCode = 3; Output = @('salvage failed') }
        }
        $out = @(Invoke-WtRepairWmiRepositoryAction -WinmgmtAction $failing -ConfirmAction { param($c, $l) return $true } 6>&1 | ForEach-Object { [string]$_ })
        $out | Should -Contain ((Get-Translation 'WmiRepairSalvageFailed') -f 3)
    }
}

Describe 'Invoke-WtRestorePowerSchemeDefaultsAction' {
    BeforeEach {
        $script:PowercfgCalls = New-Object System.Collections.Generic.List[string]
        $script:RetireCalls = New-Object System.Collections.Generic.List[string]
        $script:RestoreExitCode = 0
        $script:RetiredCount = 3
        $script:Powercfg = {
            param($Arguments)
            $joined = @($Arguments) -join ' '
            $script:PowercfgCalls.Add([string]$joined)
            if ($joined -ceq '-restoredefaultschemes') {
                return [PSCustomObject]@{ ExitCode = $script:RestoreExitCode; Output = @() }
            }
            return [PSCustomObject]@{
                ExitCode = 0
                Output   = @(
                    'Mevcut Guc Semalari (* Etkin)',
                    'Guc Semasi GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Dengeli) *'
                )
            }
        }
        $script:Retire = {
            param($ActionNames, $RetiredBy)
            $script:RetireCalls.Add(('{0}|{1}' -f ($ActionNames -join ','), $RetiredBy))
            return $script:RetiredCount
        }
    }

    It 'restores, reads the plan list back with /list and retires the PowerPlan undo records' {
        $out = @(Invoke-WtRestorePowerSchemeDefaultsAction -ConfirmAction { param($c, $l) return $true } -PowercfgAction $script:Powercfg -RetireUndoAction $script:Retire 6>&1 | ForEach-Object { [string]$_ })
        @($script:PowercfgCalls) | Should -Be @('-restoredefaultschemes', '/list')
        @($script:PowercfgCalls) | Should -Not -Contain '/query'
        @($script:RetireCalls) | Should -Be @('Apply Power Plan Settings,Revert Power Plan Settings|RestorePowerSchemeDefaults')
        $out | Should -Contain (Get-Translation 'PowerRestoreSchemesHeader')
        $out | Should -Contain 'Guc Semasi GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Dengeli) *'
        $out | Should -Contain ((Get-Translation 'PowerRestoreRetired') -f 3)
        $out | Should -Contain (Get-Translation 'PowerRestoreDone')
    }

    It 'names both the Ultimate Performance plan and core parking in the gate' {
        $script:GateLines = @()
        $confirm = {
            param($Consequence, $Lines)
            $script:GateLines = @($Lines)
            return $true
        }
        $null = Invoke-WtRestorePowerSchemeDefaultsAction -ConfirmAction $confirm -PowercfgAction $script:Powercfg -RetireUndoAction $script:Retire 6>&1
        @($script:GateLines) | Should -Contain (Get-Translation 'PowerRestoreGateLine1')
        @($script:GateLines) | Should -Contain (Get-Translation 'PowerRestoreGateLine2')
    }

    It 'runs nothing at all when the gate is refused' {
        $out = @(Invoke-WtRestorePowerSchemeDefaultsAction -ConfirmAction { param($c, $l) return $false } -PowercfgAction $script:Powercfg -RetireUndoAction $script:Retire 6>&1 | ForEach-Object { [string]$_ })
        @($script:PowercfgCalls).Count | Should -Be 0
        @($script:RetireCalls).Count | Should -Be 0
        $out | Should -Contain (Get-Translation 'ActionCancelled')
    }

    It 'leaves the undo records alone when powercfg failed' {
        $script:RestoreExitCode = 1
        $out = @(Invoke-WtRestorePowerSchemeDefaultsAction -ConfirmAction { param($c, $l) return $true } -PowercfgAction $script:Powercfg -RetireUndoAction $script:Retire 6>&1 | ForEach-Object { [string]$_ })
        @($script:PowercfgCalls) | Should -Be @('-restoredefaultschemes')
        @($script:RetireCalls).Count | Should -Be 0
        $out | Should -Contain ((Get-Translation 'PowerRestoreFailed') -f 1)
    }

    It 'says so when there was no undo record left to retire' {
        $script:RetiredCount = 0
        $out = @(Invoke-WtRestorePowerSchemeDefaultsAction -ConfirmAction { param($c, $l) return $true } -PowercfgAction $script:Powercfg -RetireUndoAction $script:Retire 6>&1 | ForEach-Object { [string]$_ })
        @($script:RetireCalls) | Should -Be @('Apply Power Plan Settings,Revert Power Plan Settings|RestorePowerSchemeDefaults')
        $out | Should -Contain (Get-Translation 'PowerRestoreRetiredNone')
    }
}

Describe 'Windows repair group wiring' {
    BeforeAll {
        $script:RepairGroup = @(Get-WtActionToolGroups) | Where-Object { $_.HeaderKey -ceq 'ActionGroupWindowsRepair' } | Select-Object -First 1
        $script:RepairRows = @(& $script:RepairGroup.GetRows)
        $script:NewRowKeys = @('ResetWindowsUpdateComponents', 'RebuildSearchIndex', 'RepairWmiRepository', 'RestorePowerSchemeDefaults')
        $script:NewMessageKeys = @(
            'WuResetConsequence', 'WuResetGateLine1', 'WuResetGateLine2', 'WuResetStarting',
            'WuResetServiceDisabled', 'WuResetAbortedDisabled', 'WuResetServiceMissing',
            'WuResetStopping', 'WuResetStopFailed', 'WuResetMissingFolder', 'WuResetRenamed',
            'WuResetRenameFailed', 'WuResetStartingService', 'WuResetStartFailed',
            'WuResetNotRunning', 'WuResetKeepingBackups', 'WuResetDeletedBackup',
            'WuResetDeleteFailed', 'WuResetDone',
            'SearchIndexStarting', 'SearchIndexServiceMissing', 'SearchIndexServiceDisabled',
            'SearchIndexStopFailed', 'SearchIndexFlagSet', 'SearchIndexNoUndoRecord',
            'SearchIndexRestarted', 'SearchIndexStartFailed', 'SearchIndexFlagRolledBack',
            'SearchIndexCost',
            'WmiRepairVerifying', 'WmiRepairConsistent', 'WmiRepairCheckFailed',
            'WmiRepairInconsistent', 'WmiRepairConsequence', 'WmiRepairGateLine',
            'WmiRepairSalvaging', 'WmiRepairSalvageOk', 'WmiRepairSalvageFailed',
            'PowerRestoreConsequence', 'PowerRestoreGateLine1', 'PowerRestoreGateLine2',
            'PowerRestoreStarting', 'PowerRestoreFailed', 'PowerRestoreSchemesHeader',
            'PowerRestoreRetired', 'PowerRestoreRetiredNone', 'PowerRestoreDone'
        )
    }

    It 'carries the seven repair rows in catalogue order' {
        @($script:RepairRows | ForEach-Object { [string]$_.Name }) | Should -Be @(
            'RepairWindowsSystemFiles',
            'RepairComponentStore',
            'ResetWindowsUpdateComponents',
            'RebuildSearchIndex',
            'RepairWmiRepository',
            'RestorePowerSchemeDefaults',
            'UpdateGroupPolicies'
        )
    }

    It 'marks the Windows Update reset ADVANCED and the other three CAUTION' {
        $byName = @{}
        foreach ($row in $script:RepairRows) { $byName[[string]$row.Name] = $row }
        [string]$byName['ResetWindowsUpdateComponents'].Risk | Should -Be 'ADVANCED'
        [string]$byName['RebuildSearchIndex'].Risk | Should -Be 'CAUTION'
        [string]$byName['RepairWmiRepository'].Risk | Should -Be 'CAUTION'
        [string]$byName['RestorePowerSchemeDefaults'].Risk | Should -Be 'CAUTION'
    }

    It 'runs all four new rows through the captured panel' {
        foreach ($key in $script:NewRowKeys) {
            $row = @($script:RepairRows) | Where-Object { [string]$_.Name -ceq $key } | Select-Object -First 1
            $row | Should -Not -BeNullOrEmpty -Because "row '$key' must be in the Windows repair group"
            [bool]$row.Data.Captured | Should -BeTrue -Because "row '$key' is a Captured row"
        }
    }

    It 'has an ASCII label under 46 characters for every new row in both languages' {
        foreach ($key in $script:NewRowKeys) {
            foreach ($lang in 'EN', 'TR') {
                $script:Translations[$lang].ContainsKey($key) | Should -BeTrue -Because "$lang needs '$key'"
                $value = [string]$script:Translations[$lang][$key]
                $value.Length | Should -BeLessOrEqual 45 -Because "$lang '$key' is a list label"
                foreach ($ch in $value.ToCharArray()) {
                    [int]$ch | Should -BeLessThan 128 -Because "$lang '$key' must be ASCII-folded"
                }
            }
        }
    }

    It 'has both languages, ASCII only, for every message the four rows print' {
        foreach ($key in $script:NewMessageKeys) {
            foreach ($lang in 'EN', 'TR') {
                $script:Translations[$lang].ContainsKey($key) | Should -BeTrue -Because "$lang needs '$key'"
                $value = [string]$script:Translations[$lang][$key]
                $value | Should -Not -BeNullOrEmpty -Because "$lang '$key' must not be blank"
                foreach ($ch in $value.ToCharArray()) {
                    [int]$ch | Should -BeLessThan 128 -Because "$lang '$key' must be ASCII-folded"
                }
            }
        }
    }
}
