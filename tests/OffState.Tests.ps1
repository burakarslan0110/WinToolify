#Requires -Modules Pester

<#
.SYNOPSIS
    The "turn back to the Windows default" side of RegistryChanges-shaped
    catalogs: the OffAction contract (Delete / Set OffValue / None), the
    guarded remove selection (with mocked registry primitives), and the
    catalog sweep that every shipped change declares a valid off state.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'OffAction contract helpers' {
    It 'defaults to Delete when a change carries no OffAction' {
        Get-WtRegistryChangeOffAction -Change ([PSCustomObject]@{ Path = 'HKLM:\X'; Name = 'v'; RegType = 'DWord'; Value = 1 }) | Should -Be 'Delete'
        Get-WtRegistryChangeOffAction -Change ([PSCustomObject]@{ Path = 'HKLM:\X'; Name = 'v'; RegType = 'DWord'; Value = 1; OffAction = '' }) | Should -Be 'Delete'
    }
    It 'returns Set / None when declared' {
        Get-WtRegistryChangeOffAction -Change ([PSCustomObject]@{ Path = 'HKLM:\X'; Name = 'v'; RegType = 'DWord'; Value = 0; OffAction = 'Set'; OffValue = 1 }) | Should -Be 'Set'
        Get-WtRegistryChangeOffAction -Change ([PSCustomObject]@{ Path = 'HKLM:\X'; Name = 'v'; RegType = 'DWord'; Value = 0; OffAction = 'None' }) | Should -Be 'None'
    }
    It 'an entry is removable unless one of its changes is None' {
        $ok = [PSCustomObject]@{ Name = 'A'; RegistryChanges = @(
            [PSCustomObject]@{ Path = 'HKLM:\X'; Name = 'a'; RegType = 'DWord'; Value = 1; OffAction = 'Delete' }
            [PSCustomObject]@{ Path = 'HKLM:\X'; Name = 'b'; RegType = 'DWord'; Value = 0; OffAction = 'Set'; OffValue = 1 }) }
        $no = [PSCustomObject]@{ Name = 'B'; RegistryChanges = @(
            [PSCustomObject]@{ Path = 'HKLM:\X'; Name = 'a'; RegType = 'DWord'; Value = 1; OffAction = 'Delete' }
            [PSCustomObject]@{ Path = 'HKLM:\X'; Name = 'c'; RegType = 'DWord'; Value = 0; OffAction = 'None' }) }
        Test-WtRegistryEntryRemovable -Entry $ok | Should -BeTrue
        Test-WtRegistryEntryRemovable -Entry $no | Should -BeFalse
    }
    It 'throws for a declared OffAction value it does not recognize' {
        $bad = [PSCustomObject]@{ Path = 'HKLM:\X'; Name = 'v'; RegType = 'DWord'; Value = 1; OffAction = 'Non' }
        { Get-WtRegistryChangeOffAction -Change $bad } | Should -Throw "*unknown OffAction 'Non' for HKLM:\X\v*"
    }
}

Describe 'Get-WtRegistryEntryCaptureItems' {
    BeforeEach {
        $script:store = @{ 'HKLM:\X|a' = 1; 'HKLM:\X|b' = 0 }
        Mock Get-WtRegistryValue { $k = "$Path|$Name"; if ($script:store.ContainsKey($k)) { [PSCustomObject]@{ Present = $true; Value = $script:store[$k] } } else { [PSCustomObject]@{ Present = $false; Value = $null } } }
        $script:catalog = @(
            [PSCustomObject]@{ Name = 'A'; RegistryChanges = @(
                [PSCustomObject]@{ Path = 'HKLM:\X'; Name = 'a'; RegType = 'DWord'; Value = 1; OffAction = 'Delete' }
                [PSCustomObject]@{ Path = 'HKLM:\X'; Name = 'b'; RegType = 'DWord'; Value = 0; OffAction = 'Set'; OffValue = 1 }) }
            [PSCustomObject]@{ Name = 'B'; RegistryChanges = @(
                [PSCustomObject]@{ Path = 'HKLM:\X'; Name = 'c'; RegType = 'DWord'; Value = 0; OffAction = 'None' }) }
        )
    }
    It 'captures one item per RegistryChanges value, in catalog/declaration order, with the current value from the store' {
        $items = Get-WtRegistryEntryCaptureItems -Catalog $catalog -Names @('A', 'B', 'Ghost')
        @($items).Count | Should -Be 3
        @($items | ForEach-Object ItemType) | Should -Be @('Registry', 'Registry', 'Registry')
        @($items | ForEach-Object CatalogEntry) | Should -Be @('A', 'A', 'B')
        @($items | ForEach-Object Name) | Should -Be @('a', 'b', 'c')
        @($items | ForEach-Object Path) | Should -Be @('HKLM:\X', 'HKLM:\X', 'HKLM:\X')
        @($items | ForEach-Object RegType) | Should -Be @('DWord', 'DWord', 'DWord')
        ($items | Where-Object Name -eq 'a').PreviousPresent | Should -BeTrue
        ($items | Where-Object Name -eq 'a').PreviousValue | Should -Be 1
        ($items | Where-Object Name -eq 'b').PreviousPresent | Should -BeTrue
        ($items | Where-Object Name -eq 'b').PreviousValue | Should -Be 0
        ($items | Where-Object Name -eq 'c').PreviousPresent | Should -BeFalse
    }
    It 'skips entries Test-WtRegistryEntryRemovable rejects only when -RequireRemovable is passed' {
        $withoutFilter = Get-WtRegistryEntryCaptureItems -Catalog $catalog -Names @('A', 'B')
        @($withoutFilter | ForEach-Object CatalogEntry) | Should -Be @('A', 'A', 'B')

        $filtered = Get-WtRegistryEntryCaptureItems -Catalog $catalog -Names @('A', 'B') -RequireRemovable
        @($filtered | ForEach-Object CatalogEntry) | Should -Be @('A', 'A')
        @($filtered | ForEach-Object Name) | Should -Be @('a', 'b')
    }
    It 'returns an empty array, not $null, for an empty Names list' {
        $items = Get-WtRegistryEntryCaptureItems -Catalog $catalog -Names @()
        ($null -eq $items) | Should -BeFalse
        @($items).Count | Should -Be 0
    }
}

Describe 'Invoke-WtRemoveRegistryEntrySelection' {
    BeforeEach {
        $script:store = @{ 'HKLM:\X|a' = 1; 'HKLM:\X|b' = 0; 'HKCU:\Y|c' = 5 }
        $script:undoWritten = $null
        Mock Write-WtUndoEntry { $script:undoWritten = @{ Action = $Action; Items = @($Items) }; 'fake.json' }
        Mock Get-WtRegistryValue { $k = "$Path|$Name"; if ($script:store.ContainsKey($k)) { [PSCustomObject]@{ Present = $true; Value = $script:store[$k] } } else { [PSCustomObject]@{ Present = $false; Value = $null } } }
        Mock Set-WtRegistryValue { $script:store["$Path|$Name"] = $Value }
        Mock Remove-WtRegistryValue { $script:store.Remove("$Path|$Name") }
        $script:catalog = @(
            [PSCustomObject]@{ Name = 'A'; RegistryChanges = @(
                [PSCustomObject]@{ Path = 'HKLM:\X'; Name = 'a'; RegType = 'DWord'; Value = 1; OffAction = 'Delete' }
                [PSCustomObject]@{ Path = 'HKLM:\X'; Name = 'b'; RegType = 'DWord'; Value = 0; OffAction = 'Set'; OffValue = 1 }) }
            [PSCustomObject]@{ Name = 'B'; RegistryChanges = @(
                [PSCustomObject]@{ Path = 'HKCU:\Y'; Name = 'c'; RegType = 'DWord'; Value = 5; OffAction = 'None' }) }
        )
    }
    It 'deletes Delete changes, writes OffValue for Set changes, and reports each as Applied after re-reading the off state' {
        $r = Invoke-WtRemoveRegistryEntrySelection -Catalog $catalog -SelectedNames @('A') -ActionName 'Revert Telemetry Settings'
        $r.Aborted | Should -BeFalse
        @($r.Results).Count | Should -Be 2
        @($r.Results | ForEach-Object Applied) | Should -Be @($true, $true)
        $script:store.ContainsKey('HKLM:\X|a') | Should -BeFalse
        $script:store['HKLM:\X|b'] | Should -Be 1
    }
    It 'records the previous (on) values as Registry undo items under the given action name' {
        Invoke-WtRemoveRegistryEntrySelection -Catalog $catalog -SelectedNames @('A') -ActionName 'Revert Telemetry Settings' | Out-Null
        $undoWritten.Action | Should -Be 'Revert Telemetry Settings'
        @($undoWritten.Items | ForEach-Object ItemType) | Should -Be @('Registry', 'Registry')
        ($undoWritten.Items | Where-Object Name -eq 'a').PreviousValue | Should -Be 1
        ($undoWritten.Items | Where-Object Name -eq 'a').CatalogEntry | Should -Be 'A'
        ($undoWritten.Items | Where-Object Name -eq 'b').PreviousPresent | Should -BeTrue
    }
    It 'skips an entry that is not removable and unknown names' {
        $r = Invoke-WtRemoveRegistryEntrySelection -Catalog $catalog -SelectedNames @('B', 'Ghost') -ActionName 'Revert Telemetry Settings'
        @($r.Results).Count | Should -Be 0
        $script:store['HKCU:\Y|c'] | Should -Be 5
    }
    It 'reports Not applied when the value is still there after a failed delete' {
        Mock Remove-WtRegistryValue { throw 'access denied' }
        $r = Invoke-WtRemoveRegistryEntrySelection -Catalog $catalog -SelectedNames @('A') -ActionName 'Revert Telemetry Settings'
        ($r.Results | Where-Object { $_.Item.Name -eq 'a' }).Applied | Should -BeFalse
        ($r.Results | Where-Object { $_.Item.Name -eq 'a' }).Error | Should -Match 'access denied'
    }
}

Describe 'Hand-written registry catalogs declare their Windows default' {
    BeforeAll {
        $script:catalogs = @{
            AiPrivacy           = { Get-WtAiPrivacyCatalog }
            Telemetry           = { Get-WtTelemetryCatalog -GetEditionAction { 'Professional' } }
            ActivityAdvertising = { Get-WtActivityAdvertisingCatalog }
            SearchSuggestions   = { Get-WtSearchSuggestionsCatalog }
            ExplorerView        = { Get-WtExplorerViewCatalog }
            GamingTweaks        = { Get-WtGamingTweakCatalog }
        }
    }
    It 'every change has an explicit OffAction of Delete / Set / None, and Set carries an OffValue' {
        foreach ($k in $catalogs.Keys) {
            foreach ($entry in @(& $catalogs[$k])) {
                foreach ($c in @($entry.RegistryChanges)) {
                    $c.PSObject.Properties.Name | Should -Contain 'OffAction' -Because "$k/$($entry.Name)/$($c.Name)"
                    @('Delete', 'Set', 'None') | Should -Contain $c.OffAction -Because "$k/$($entry.Name)/$($c.Name)"
                    if ($c.OffAction -eq 'Set') { $c.OffValue | Should -Not -BeNullOrEmpty -Because "$k/$($entry.Name)/$($c.Name)" }
                    if ($c.OffAction -eq 'Set') { $c.OffValue | Should -Not -Be $c.Value -Because "$k/$($entry.Name)/$($c.Name): off must differ from on" }
                }
            }
        }
    }
    It 'every Set value is one of the verified Windows-shipped defaults; everything else is Delete' {
        $expectSet = @{
            'Telemetry|HarvestContacts|HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore'                        = 1
            'Telemetry|AcceptedPrivacyPolicy|HKCU:\Software\Microsoft\Personalization\Settings'                               = 1
            'Telemetry|Enabled|HKCU:\Software\Microsoft\Input\TIPC'                                                          = 1
            'ActivityAdvertising|Enabled|HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'                     = 1
            'ActivityAdvertising|TailoredExperiencesWithDiagnosticDataEnabled|HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' = 1
            'SearchSuggestions|Start_IrisRecommendations|HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'    = 1
            'SearchSuggestions|SilentInstalledAppsEnabled|HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' = 1
            'GamingTweaks|GameDVR_HonorUserFSEBehaviorMode|HKCU:\System\GameConfigStore'                                      = 0
            'GamingTweaks|GameDVR_DXGIHonorFSEWindowsCompatible|HKCU:\System\GameConfigStore'                                 = 0
            'ExplorerView|HideFileExt|HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'                      = 1
            'ExplorerView|Hidden|HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'                           = 2
            'ExplorerView|ShowSuperHidden|HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'                  = 0
        }
        $seenSet = New-Object System.Collections.Generic.HashSet[string]
        foreach ($k in $catalogs.Keys) {
            foreach ($entry in @(& $catalogs[$k])) {
                foreach ($c in @($entry.RegistryChanges)) {
                    $key = "$k|$($c.Name)|$($c.Path)"
                    if ($expectSet.ContainsKey($key)) {
                        $c.OffAction | Should -Be 'Set' -Because $key
                        [int]$c.OffValue | Should -Be $expectSet[$key] -Because $key
                        [void]$seenSet.Add($key)
                    }
                    else {
                        $c.OffAction | Should -Be 'Delete' -Because $key
                    }
                }
            }
        }
        @($expectSet.Keys | Sort-Object) | Should -Be @($seenSet | Sort-Object)
        foreach ($c in @((Get-WtGamingTweakCatalog) | ForEach-Object RegistryChanges | Where-Object { $_.Name -in 'HwSchMode', 'RawMouseThrottleEnabled', 'RawMouseThrottleDuration', 'GameDVR_FSEBehaviorMode', 'GameDVR_FSEBehavior' })) {
            $c.OffAction | Should -Be 'Delete' -Because $c.Name
        }
    }
    It 'the six sections expose TurnOff + IsRemovable and their ActionNames are translated' {
        $table = Get-WtProfileSectionCatalog
        foreach ($key in 'AiPrivacy', 'Telemetry', 'ActivityAdvertising', 'SearchSuggestions', 'GamingTweaks', 'ExplorerView') {
            $row = $table | Where-Object Key -eq $key
            $row.TurnOff | Should -Not -BeNullOrEmpty -Because $key
            $row.IsRemovable | Should -Not -BeNullOrEmpty -Because $key
            (& $row.IsRemovable (@(& $row.GetCatalog)[0])) | Should -BeTrue -Because $key
        }
        foreach ($n in 'Revert AI Privacy Settings', 'Revert Telemetry Settings', 'Revert Activity & Advertising Settings', 'Revert Search & Suggestions Settings', 'Revert Gaming Tweaks', 'Revert Explorer View Settings') {
            $script:Translations['EN']['UndoAction.' + $n] | Should -Be $n
            $script:Translations['TR']['UndoAction.' + $n] | Should -Not -BeNullOrEmpty
        }
    }
    It 'TurnOff hands the section catalog and a Revert action name to the remove engine, for every one of the six sections' {
        Mock Invoke-WtRemoveRegistryEntrySelection { [PSCustomObject]@{ Aborted = $false; Results = @(); Seen = @{ Names = $SelectedNames; Action = $ActionName; Count = @($Catalog).Count } } }
        $expected = @{
            AiPrivacy           = @{ ActionName = 'Revert AI Privacy Settings'; Catalog = { Get-WtAiPrivacyCatalog } }
            Telemetry           = @{ ActionName = 'Revert Telemetry Settings'; Catalog = { Get-WtTelemetryCatalog -GetEditionAction { 'Professional' } } }
            ActivityAdvertising = @{ ActionName = 'Revert Activity & Advertising Settings'; Catalog = { Get-WtActivityAdvertisingCatalog } }
            SearchSuggestions   = @{ ActionName = 'Revert Search & Suggestions Settings'; Catalog = { Get-WtSearchSuggestionsCatalog } }
            GamingTweaks        = @{ ActionName = 'Revert Gaming Tweaks'; Catalog = { Get-WtGamingTweakCatalog } }
            ExplorerView        = @{ ActionName = 'Revert Explorer View Settings'; Catalog = { Get-WtExplorerViewCatalog } }
        }
        $table = Get-WtProfileSectionCatalog
        foreach ($key in $expected.Keys) {
            $row = $table | Where-Object Key -eq $key
            $r = & $row.TurnOff ([string[]]@('Probe')) $null
            $r.Seen.Action | Should -Be $expected[$key].ActionName -Because $key
            @($r.Seen.Names) | Should -Be @('Probe') -Because $key
            $r.Seen.Count | Should -Be @(& $expected[$key].Catalog).Count -Because $key
        }
    }
}

Describe 'Hardening sections can remove' {
    BeforeAll {
        $script:CatalogVariants = @(
            @{ Label = 'host-default'; Get = { param($g) Get-WtHardeningCatalog -Group $g } }
            @{ Label = 'W11'; Get = { param($g) Get-WtHardeningCatalog -Group $g -IsWindows11 $true } }
        )
    }
    It 'every shipped Hardening change has a valid off state, Set never equals ValueOn, and at most a handful are None' {
        foreach ($variant in $CatalogVariants) {
            $none = New-Object 'System.Collections.Generic.List[string]'
            foreach ($group in @((Get-WtHardeningRows).Keys)) {
                foreach ($entry in @(& $variant.Get $group)) {
                    foreach ($c in @($entry.RegistryChanges)) {
                        $ctx = "$($variant.Label) $group/$($entry.Name)/$($c.Name)"
                        @('Delete', 'Set', 'None') | Should -Contain $c.OffAction -Because $ctx
                        if ($c.OffAction -eq 'Set') {
                            $c.OffValue | Should -Not -BeNullOrEmpty -Because $ctx
                            $c.OffValue | Should -Not -Be $c.Value -Because "$ctx : off must differ from on"
                        }
                        if ($c.OffAction -eq 'None') { $none.Add($ctx) }
                    }
                }
            }
            $none.Count | Should -BeLessOrEqual 8 -Because ('None rows (' + $variant.Label + '): ' + ($none -join ', '))
        }
    }
    It 'policy / PolicyManager paths are never Set to a value (a policy is removed, not rewritten)' {
        foreach ($variant in $CatalogVariants) {
            foreach ($group in @((Get-WtHardeningRows).Keys)) {
                foreach ($entry in @(& $variant.Get $group)) {
                    foreach ($c in @($entry.RegistryChanges | Where-Object { $_.Path -match '\\(Policies|PolicyManager)\\' })) {
                        $c.OffAction | Should -Not -Be 'Set' -Because "$($variant.Label) $group/$($entry.Name)/$($c.Name)"
                    }
                }
            }
        }
    }
    It 'the eight Hardening sections expose TurnOff + IsRemovable with translated Revert action names' {
        $table = Get-WtProfileSectionCatalog
        $expected = @{
            HardeningPrivacy = 'Revert Privacy Settings'; HardeningAppPermissions = 'Revert App Permission Settings'; HardeningAi = 'Revert AI Settings'
            HardeningSearchUi = 'Revert Search and UI Settings'; HardeningEdge = 'Revert Edge Settings'; HardeningOffice = 'Revert Office and Sync Settings'
            HardeningUpdate = 'Revert Windows Update Settings'; HardeningSecurity = 'Revert Security Settings'
        }
        Mock Invoke-WtRemoveRegistryEntrySelection { [PSCustomObject]@{ Aborted = $false; Results = @(); Action = $ActionName } }
        foreach ($key in $expected.Keys) {
            $row = $table | Where-Object Key -eq $key
            $row.TurnOff | Should -Not -BeNullOrEmpty -Because $key
            $row.IsRemovable | Should -Not -BeNullOrEmpty -Because $key
            (& $row.TurnOff ([string[]]@('HD_X')) $null).Action | Should -Be $expected[$key]
            $script:Translations['TR']['UndoAction.' + $expected[$key]] | Should -Not -BeNullOrEmpty
        }
    }
}
