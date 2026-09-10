#Requires -Modules Pester

<#
.SYNOPSIS
    Explorer & Context-Menu bundle: Get-WtShellEntryState (live Applied /
    NotApplied for a KeyChanges-shaped catalog entry) and
    Invoke-WtApplyShellEntrySelection (capture -> undo-write -> apply ->
    re-read for entries that create registry key trees). Everything runs
    against an in-memory fake registry injected through the key-level
    primitives' actions - no real key is touched on the macOS dev host.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath

    $script:TwoKeyEntry = [PSCustomObject]@{
        Name            = 'TestVerb'
        DisplayLabel    = 'Test verb'
        Risk            = 'SAFE'
        Consequence     = $null
        RestartsExplorer = $true
        KeyChanges      = @(
            [PSCustomObject]@{
                Hive = 'LocalMachine'; SubKey = 'SOFTWARE\Classes\*\shell\TestVerb'; RootBoundary = 'SOFTWARE\Classes\*\shell'
                Values = @(
                    [PSCustomObject]@{ Name = ''; Kind = 'String'; Value = 'Test Verb' },
                    [PSCustomObject]@{ Name = 'HasLUAShield'; Kind = 'String'; Value = '' }
                )
            }
            [PSCustomObject]@{
                Hive = 'LocalMachine'; SubKey = 'SOFTWARE\Classes\*\shell\TestVerb\command'; RootBoundary = 'SOFTWARE\Classes\*\shell'
                Values = @(
                    [PSCustomObject]@{ Name = ''; Kind = 'String'; Value = 'cmd.exe /c echo %1' }
                )
            }
        )
    }

    function New-FakeRegistry {
        <#
        .SYNOPSIS
            In-memory registry keyed "Hive|SubKey" -> hashtable of Name ->
            Value. Returns the actions the primitives take, plus the
            call-order log.
        #>
        param([hashtable]$Keys = @{})
        $reg = @{}
        foreach ($k in $Keys.Keys) { $reg[$k] = @{} + $Keys[$k] }
        $order = New-Object System.Collections.Generic.List[string]
        return [PSCustomObject]@{
            Keys  = $reg
            Order = $order
            Get   = {
                param($h, $s, $n)
                $key = $reg["$h|$s"]
                if ($null -eq $key) { return $null }
                if ($key.ContainsKey($n)) { return [PSCustomObject]@{ Present = $true; Value = $key[$n] } }
                return [PSCustomObject]@{ Present = $false; Value = $null }
            }.GetNewClosure()
            Test  = { param($h, $s) $reg.ContainsKey("$h|$s") }.GetNewClosure()
            Set   = {
                param($h, $s, $v)
                if (-not $reg.ContainsKey("$h|$s")) { $reg["$h|$s"] = @{} }
                foreach ($e in @($v)) { $reg["$h|$s"][$e.Name] = $e.Value }
                $order.Add("Set:$s")
            }.GetNewClosure()
        }
    }
}

Describe 'Get-WtShellEntryState' {
    It 'reports Applied when every value of every KeyChanges item is present and equal' {
        $fake = New-FakeRegistry @{
            'LocalMachine|SOFTWARE\Classes\*\shell\TestVerb'         = @{ '' = 'Test Verb'; 'HasLUAShield' = '' }
            'LocalMachine|SOFTWARE\Classes\*\shell\TestVerb\command' = @{ '' = 'cmd.exe /c echo %1' }
        }
        (Get-WtShellEntryState -Entry $TwoKeyEntry -GetKeyValueAction $fake.Get).Applied | Should -BeTrue
    }

    It 'reports NotApplied when one value is absent from an otherwise complete entry' {
        $fake = New-FakeRegistry @{
            'LocalMachine|SOFTWARE\Classes\*\shell\TestVerb'         = @{ '' = 'Test Verb' }
            'LocalMachine|SOFTWARE\Classes\*\shell\TestVerb\command' = @{ '' = 'cmd.exe /c echo %1' }
        }
        (Get-WtShellEntryState -Entry $TwoKeyEntry -GetKeyValueAction $fake.Get).Applied | Should -BeFalse
    }

    It 'reports NotApplied when one value differs' {
        $fake = New-FakeRegistry @{
            'LocalMachine|SOFTWARE\Classes\*\shell\TestVerb'         = @{ '' = 'Test Verb'; 'HasLUAShield' = '' }
            'LocalMachine|SOFTWARE\Classes\*\shell\TestVerb\command' = @{ '' = 'notepad.exe' }
        }
        (Get-WtShellEntryState -Entry $TwoKeyEntry -GetKeyValueAction $fake.Get).Applied | Should -BeFalse
    }

    It 'reports NotApplied when a key is missing entirely' {
        $fake = New-FakeRegistry @{
            'LocalMachine|SOFTWARE\Classes\*\shell\TestVerb' = @{ '' = 'Test Verb'; 'HasLUAShield' = '' }
        }
        (Get-WtShellEntryState -Entry $TwoKeyEntry -GetKeyValueAction $fake.Get).Applied | Should -BeFalse
    }

    It 'reports NotApplied for a key that exists with no default value while the entry targets the empty string' {
        $entry = [PSCustomObject]@{
            Name = 'ClassicMenu'
            KeyChanges = @(
                [PSCustomObject]@{
                    Hive = 'CurrentUser'; SubKey = 'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'; RootBoundary = 'Software\Classes\CLSID'
                    Values = @([PSCustomObject]@{ Name = ''; Kind = 'String'; Value = '' })
                }
            )
        }
        $fake = New-FakeRegistry @{ 'CurrentUser|Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' = @{} }
        (Get-WtShellEntryState -Entry $entry -GetKeyValueAction $fake.Get).Applied | Should -BeFalse

        $fake.Keys['CurrentUser|Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'][''] = ''
        (Get-WtShellEntryState -Entry $entry -GetKeyValueAction $fake.Get).Applied | Should -BeTrue
    }
}

Describe 'Invoke-WtApplyShellEntrySelection' {
    BeforeEach {
    }

    It 'writes the undo entry before any key is created, one RegistryKey item per key in declaration order, each carrying the creation plan CreatedRoot' {
        $fake = New-FakeRegistry @{ 'LocalMachine|SOFTWARE\Classes\*\shell' = @{} }
        $captured = @{}
        $writeUndo = {
            param($Scope, $ActionName, $Items, $TestRootOverride)
            $fake.Order.Add('WriteUndo')
            $captured.Scope = $Scope; $captured.ActionName = $ActionName; $captured.Items = @($Items)
        }.GetNewClosure()

        $result = Invoke-WtApplyShellEntrySelection -Catalog @($TwoKeyEntry) -SelectedNames @('TestVerb') -ActionName 'Apply Test Verb' `
            -GetKeyValueAction $fake.Get -TestKeyAction $fake.Test -SetKeyValuesAction $fake.Set -WriteUndoAction $writeUndo

        $result.Aborted | Should -BeFalse
        $fake.Order[0] | Should -Be 'WriteUndo'
        $fake.Order.Count | Should -Be 3
        $captured.Scope | Should -Be 'Machine'
        $captured.ActionName | Should -Be 'Apply Test Verb'
        $captured.Items.Count | Should -Be 2
        $captured.Items[0].ItemType | Should -Be 'RegistryKey'
        $captured.Items[0].CatalogEntry | Should -Be 'TestVerb'
        $captured.Items[0].Hive | Should -Be 'LocalMachine'
        $captured.Items[0].SubKey | Should -Be 'SOFTWARE\Classes\*\shell\TestVerb'
        $captured.Items[1].SubKey | Should -Be 'SOFTWARE\Classes\*\shell\TestVerb\command'
        $captured.Items[0].CreatedRoot | Should -Be 'SOFTWARE\Classes\*\shell\TestVerb'
        $captured.Items[1].CreatedRoot | Should -Be 'SOFTWARE\Classes\*\shell\TestVerb'
        @($captured.Items[0].PreviousValues).Count | Should -Be 2
        @($captured.Items[0].PreviousValues)[1].Name | Should -Be 'HasLUAShield'
        @($captured.Items[0].PreviousValues)[1].Present | Should -BeFalse
        @($captured.Items[0].PreviousValues)[1].Kind | Should -Be 'String'

        $fake.Keys['LocalMachine|SOFTWARE\Classes\*\shell\TestVerb'][''] | Should -Be 'Test Verb'
        $fake.Keys['LocalMachine|SOFTWARE\Classes\*\shell\TestVerb\command'][''] | Should -Be 'cmd.exe /c echo %1'
        @($result.Results).Count | Should -Be 2
        $result.Results | ForEach-Object { $_.Applied | Should -BeTrue }
    }

    It 'records CreatedRoot = $null and the previous values when the key already exists' {
        $fake = New-FakeRegistry @{
            'LocalMachine|SOFTWARE\Classes\*\shell'                  = @{}
            'LocalMachine|SOFTWARE\Classes\*\shell\TestVerb'         = @{ '' = 'Old Label' }
            'LocalMachine|SOFTWARE\Classes\*\shell\TestVerb\command' = @{ '' = 'old.exe' }
        }
        $captured = @{}
        $writeUndo = { param($Scope, $ActionName, $Items, $TestRootOverride) $captured.Items = @($Items) }.GetNewClosure()

        Invoke-WtApplyShellEntrySelection -Catalog @($TwoKeyEntry) -SelectedNames @('TestVerb') -ActionName 'Apply Test Verb' `
            -GetKeyValueAction $fake.Get -TestKeyAction $fake.Test -SetKeyValuesAction $fake.Set -WriteUndoAction $writeUndo | Out-Null

        $captured.Items[0].CreatedRoot | Should -BeNullOrEmpty
        $captured.Items[1].CreatedRoot | Should -BeNullOrEmpty
        $prev = @($captured.Items[0].PreviousValues)
        ($prev | Where-Object Name -eq '').Present | Should -BeTrue
        ($prev | Where-Object Name -eq '').Value | Should -Be 'Old Label'
        ($prev | Where-Object Name -eq 'HasLUAShield').Present | Should -BeFalse
    }

    It 'reports Applied only from the post-apply re-read - a write that returns without changing anything is NotApplied' {
        $fake = New-FakeRegistry @{ 'LocalMachine|SOFTWARE\Classes\*\shell' = @{} }
        $noOpSet = { param($h, $s, $v) }

        $result = Invoke-WtApplyShellEntrySelection -Catalog @($TwoKeyEntry) -SelectedNames @('TestVerb') -ActionName 'Apply Test Verb' `
            -GetKeyValueAction $fake.Get -TestKeyAction $fake.Test -SetKeyValuesAction $noOpSet -WriteUndoAction { param($s, $a, $i, $t) }

        $result.Aborted | Should -BeFalse
        @($result.Results).Count | Should -Be 2
        $result.Results | ForEach-Object { $_.Applied | Should -BeFalse }
        $result.Results | ForEach-Object { $_.Error | Should -BeNullOrEmpty }
    }

    It 'ignores selected names that are not in the catalog and captures nothing for them' {
        $fake = New-FakeRegistry @{ 'LocalMachine|SOFTWARE\Classes\*\shell' = @{} }
        $captured = @{}
        $writeUndo = { param($Scope, $ActionName, $Items, $TestRootOverride) $captured.Items = @($Items) }.GetNewClosure()

        $result = Invoke-WtApplyShellEntrySelection -Catalog @($TwoKeyEntry) -SelectedNames @('NoSuchEntry') -ActionName 'Apply Test Verb' `
            -GetKeyValueAction $fake.Get -TestKeyAction $fake.Test -SetKeyValuesAction $fake.Set -WriteUndoAction $writeUndo

        $captured.Items.Count | Should -Be 0
        @($result.Results).Count | Should -Be 0
    }
}
