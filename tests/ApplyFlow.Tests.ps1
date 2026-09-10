#Requires -Modules Pester

<#
.SYNOPSIS
    Coverage for Invoke-WtGuardedChange, the shared orchestrator behind
    both the service and package apply paths. Every dependency (undo
    write, apply, re-read) is injected, so the load-bearing ordering
    claim - capture -> undo write -> apply -> re-read - is proven
    directly. There is no restore-point step any more: the only restore
    point WinToolify makes is the one the main menu row makes.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Invoke-WtGuardedChange - ordering' {
    It 'invokes the undo-write action before any Apply call' {
        $callOrder = New-Object System.Collections.Generic.List[string]

        $captureState = { @([PSCustomObject]@{ ItemType = 'Service'; Name = 'Svc1' }) }
        $writeUndo = { param($Scope, $ActionName, $Items, $TestRootOverride) $callOrder.Add('WriteUndo') }.GetNewClosure()
        $apply = { param($Item) $callOrder.Add('Apply') }.GetNewClosure()
        $reReadState = { param($Item) $true }

        Invoke-WtGuardedChange -CaptureState $captureState -Apply $apply -ReReadState $reReadState `
            -Scope Machine -ActionName 'test-order' -WriteUndoAction $writeUndo | Out-Null

        @($callOrder) | Should -Be @('WriteUndo', 'Apply')
    }

    It 'never aborts on its own - nothing gates an apply before the undo record is written' {
        $captureState = { @([PSCustomObject]@{ ItemType = 'Service'; Name = 'Svc1' }) }
        $result = Invoke-WtGuardedChange -CaptureState $captureState -Apply { param($Item) } -ReReadState { param($Item) $true } `
            -Scope Machine -ActionName 'test-no-gate' -WriteUndoAction { param($s, $a, $i, $t) }
        $result.Aborted | Should -BeFalse
        @($result.Results).Count | Should -Be 1
    }

    It 'takes no restore-point parameters any more' {
        $names = @((Get-Command Invoke-WtGuardedChange).Parameters.Keys)
        foreach ($gone in 'RestorePointFlow', 'GetProtectionEnabled', 'GetLastPointAgeHours') {
            $names | Should -Not -Contain $gone
        }
    }
}

Describe 'Per-row service start type (the Services screen cycles a target)' {
    It 'a name the cycle never touched keeps the historical meaning of "selected"' {
        Get-WtServiceTargetStartType -Name 'DiagTrack' -Targets @{} | Should -Be 'Disabled'
        Get-WtServiceTargetStartType -Name 'DiagTrack' -Targets $null | Should -Be 'Disabled'
        Get-WtServiceTargetStartType -Name 'DiagTrack' -Targets @{ Fax = 'Manual' } | Should -Be 'Disabled'
    }
    It 'honours the target the row carries' {
        foreach ($t in 'Disabled', 'Manual', 'Automatic') {
            Get-WtServiceTargetStartType -Name 'Fax' -Targets @{ Fax = $t } | Should -Be $t
        }
    }
    It 'refuses a word Set-Service would not accept instead of passing it through' {
        Get-WtServiceTargetStartType -Name 'Fax' -Targets @{ Fax = 'Boot' } | Should -Be 'Disabled'
        Get-WtServiceTargetStartType -Name 'Fax' -Targets @{ Fax = '' } | Should -Be 'Disabled'
    }
    It 'maps a target to the Start value a per-user TEMPLATE key needs' {
        ConvertTo-WtServiceStartValue -StartType 'Automatic' | Should -Be 2
        ConvertTo-WtServiceStartValue -StartType 'Manual' | Should -Be 3
        ConvertTo-WtServiceStartValue -StartType 'Disabled' | Should -Be 4
    }
    It 'the cycle order starts at Disabled - one press still means "turn it off"' {
        (Get-WtServiceCycleTargets)[0] | Should -Be 'Disabled'
        @(Get-WtServiceCycleTargets) | Should -Be @('Disabled', 'Manual', 'Automatic')
    }
    It 'a cycled mark becomes Data.Target on the record' {
        $sel = New-Object 'System.Collections.Generic.HashSet[string]'
        $null = $sel.Add('Fax')
        $meta = @{ Fax = @{ SectionKey = 'Services'; Entry = [PSCustomObject]@{ Name = 'Fax' }; Data = $null } }
        $records = @(ConvertTo-WtApplyRecords -Selection $sel -Meta $meta -Cycle @{ Fax = 'Manual' })
        $records.Count | Should -Be 1
        $records[0].Data.Target | Should -Be 'Manual'
    }
    It 'an uncycled mark carries no Target at all' {
        $sel = New-Object 'System.Collections.Generic.HashSet[string]'
        $null = $sel.Add('Fax')
        $meta = @{ Fax = @{ SectionKey = 'Services'; Entry = [PSCustomObject]@{ Name = 'Fax' }; Data = $null } }
        $records = @(ConvertTo-WtApplyRecords -Selection $sel -Meta $meta)
        $records[0].Data | Should -BeNullOrEmpty
    }
    It 'the cycle does not overwrite the Data a group already put on the row' {
        $sel = New-Object 'System.Collections.Generic.HashSet[string]'
        $null = $sel.Add('Fax')
        $meta = @{ Fax = @{ SectionKey = 'Services'; Entry = [PSCustomObject]@{ Name = 'Fax' }; Data = @{ Sid = 'S-1-5-21' } } }
        $records = @(ConvertTo-WtApplyRecords -Selection $sel -Meta $meta -Cycle @{ Fax = 'Automatic' })
        $records[0].Data.Sid | Should -Be 'S-1-5-21'
        $records[0].Data.Target | Should -Be 'Automatic'
    }
    It 'the section plan carries EVERY row target, not just the first record"s Data' {
        $records = @(
            New-WtApplyRecord -SectionKey 'Services' -EntryName 'Fax' -Data @{ Target = 'Manual' }
            New-WtApplyRecord -SectionKey 'Services' -EntryName 'DiagTrack' -Data @{ Target = 'Automatic' }
        )
        $plan = Get-WtCommitPlan -ChangeSet $records -GetPackageCatalog { @() }
        $section = @($plan.Sections | Where-Object Key -eq 'Services')[0]
        $section.Data.Targets['Fax'] | Should -Be 'Manual'
        $section.Data.Targets['DiagTrack'] | Should -Be 'Automatic'
    }
    It 'a plan with no cycled row gets no Targets map' {
        $records = @(New-WtApplyRecord -SectionKey 'Services' -EntryName 'Fax')
        $plan = Get-WtCommitPlan -ChangeSet $records -GetPackageCatalog { @() }
        $section = @($plan.Sections | Where-Object Key -eq 'Services')[0]
        $section.Data | Should -BeNullOrEmpty
    }
    It 'the Services section hands the map to the apply entry point' {
        $section = @(Get-WtApplySectionCatalog | Where-Object Key -eq 'Services')[0]
        $script:seen = $null
        function Invoke-WtApplyServiceSelection { param([string[]]$SelectedNames, [hashtable]$Targets) $script:seen = $Targets }
        & $section.Apply ([string[]]@('Fax')) @{ Targets = @{ Fax = 'Manual' } }
        $script:seen['Fax'] | Should -Be 'Manual'
    }
}
