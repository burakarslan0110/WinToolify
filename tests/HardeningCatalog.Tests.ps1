#Requires -Modules Pester

<#
.SYNOPSIS
    The native hardening catalog: row grammar, loader, OS filter, dedupe
    against the pre-existing registry catalogs, translations.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
    $script:AllRows = @((Get-WtHardeningRows).Values | ForEach-Object { $_ })
    $script:GroupNames = @('Ai', 'AppPermissions', 'Edge', 'Office', 'PrivacyTelemetry', 'SearchUi', 'Security', 'Update')
}

Describe 'ConvertFrom-WtHardeningRows' {
    It 'parses one row into an entry with one registry change' {
        $e = @(ConvertFrom-WtHardeningRows -Rows @('P001|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows\TabletPC|PreventHandwritingDataSharing|DWord|1|W10,W11|HdCatPrivacy|-'))
        $e.Count | Should -Be 1
        $e[0].Name | Should -Be 'HD_P001'
        $e[0].Risk | Should -Be 'SAFE'
        $e[0].Os | Should -Be @('W10', 'W11')
        $e[0].Category | Should -Be 'HdCatPrivacy'
        $e[0].LabelKey | Should -Be 'CatHardeningP001Label'
        $e[0].ConsequenceKey | Should -Be 'CatHardeningP001Consequence'
        $e[0].RegistryChanges.Count | Should -Be 1
        $e[0].RegistryChanges[0].Path | Should -Be 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\TabletPC'
        $e[0].RegistryChanges[0].Name | Should -Be 'PreventHandwritingDataSharing'
        $e[0].RegistryChanges[0].RegType | Should -Be 'DWord'
        $e[0].RegistryChanges[0].Value | Should -Be 1
    }
    It 'expands multiple paths and groups ~n rows into one entry' {
        $rows = @(
            'P034|CAUTION|HKCU:\A\webcam;HKLM:\A\webcam|Value|String|Deny|W10,W11|HdCatAppPrivacy|Allow'
            'M001~1|SAFE|HKCU:\S|NumberOfSIUFInPeriod|DWord|0|W10,W11|HdCatMisc|-'
            'M001~2|SAFE|HKCU:\S|PeriodInNanoSeconds|DWord|0|W10,W11|HdCatMisc|-'
        )
        $e = @(ConvertFrom-WtHardeningRows -Rows $rows)
        $e.Count | Should -Be 2
        $e[0].RegistryChanges.Count | Should -Be 2
        $e[0].RegistryChanges[1].Path | Should -Be 'HKLM:\A\webcam'
        $e[0].RegistryChanges[0].Value | Should -Be 'Deny'
        $e[1].Name | Should -Be 'HD_M001'
        $e[1].RegistryChanges.Count | Should -Be 2
    }
    It 'types the value from the RegType column' {
        $e = @(ConvertFrom-WtHardeningRows -Rows @(
                'A|SAFE|HKLM:\A|V|DWord|3|W10,W11|HdCatPrivacy|-'
                'B|SAFE|HKLM:\B|V|QWord|9|W10,W11|HdCatPrivacy|-'
                'C|SAFE|HKLM:\C|V|String|Deny|W10,W11|HdCatPrivacy|Allow'
            ))
        $e[0].RegistryChanges[0].Value | Should -BeOfType [int]
        $e[1].RegistryChanges[0].Value | Should -BeOfType [long]
        $e[2].RegistryChanges[0].Value | Should -BeOfType [string]
    }
    It 'leaves the prose to the translation layer' {
        $e = @(ConvertFrom-WtHardeningRows -Rows @('P001|SAFE|HKLM:\A|V|DWord|1|W11|HdCatPrivacy|-'))
        $e[0].DisplayLabel | Should -Be 'P001'
        $e[0].Consequence | Should -BeNullOrEmpty
        $e[0].Os | Should -Be @('W11')
    }
    It 'accepts an empty row set' {
        @(ConvertFrom-WtHardeningRows -Rows @()).Count | Should -Be 0
    }
    It 'rejects a malformed row loudly' {
        { ConvertFrom-WtHardeningRows -Rows @('P001|SAFE|only-three') } | Should -Throw
    }
    It 'parses the 9th field into OffAction / OffValue' {
        $rows = @(
            'T001|SAFE|HKLM:\SOFTWARE\Policies\X|A|DWord|1|W10,W11|HdCatMisc|-'
            'T002|SAFE|HKCU:\SOFTWARE\X|B|DWord|0|W10,W11|HdCatMisc|1'
            'T003|SAFE|HKLM:\SOFTWARE\X\ConsentStore\c|Value|String|Deny|W10,W11|HdCatMisc|Allow'
            'T004|SAFE|HKLM:\SOFTWARE\X|D|DWord|0|W10,W11|HdCatMisc|?'
        )
        $entries = @(ConvertFrom-WtHardeningRows -Rows $rows)
        $entries[0].RegistryChanges[0].OffAction | Should -Be 'Delete'
        $entries[1].RegistryChanges[0].OffAction | Should -Be 'Set'
        $entries[1].RegistryChanges[0].OffValue | Should -Be 1
        $entries[1].RegistryChanges[0].OffValue | Should -BeOfType [int]
        $entries[2].RegistryChanges[0].OffValue | Should -Be 'Allow'
        $entries[3].RegistryChanges[0].OffAction | Should -Be 'None'
        Test-WtRegistryEntryRemovable -Entry $entries[3] | Should -BeFalse
        Test-WtRegistryEntryRemovable -Entry $entries[1] | Should -BeTrue
    }
    It 'rejects an 8-field row' {
        { ConvertFrom-WtHardeningRows -Rows @('T001|SAFE|HKLM:\SOFTWARE\X|A|DWord|1|W10,W11|HdCatMisc') } | Should -Throw '*9 fields*'
    }
}

Describe 'Shipped Hardening rows' {
    It 'has the eight screen groups' {
        @((Get-WtHardeningRows).Keys | Sort-Object) | Should -Be $GroupNames
    }
    It 'every row has 9 fields, a known risk, HKLM:/HKCU: paths, a known type and OS list' {
        foreach ($row in $AllRows) {
            $parts = $row -split '\|'
            $parts.Count | Should -Be 9 -Because $row
            @('SAFE', 'CAUTION', 'ADVANCED') | Should -Contain $parts[1] -Because $row
            foreach ($p in ($parts[2] -split ';')) { $p | Should -Match '^HK(LM|CU):\\' -Because $row }
            $parts[3] | Should -Not -BeNullOrEmpty -Because $row
            @('DWord', 'String', 'QWord', 'ExpandString', 'Binary', 'MultiString') | Should -Contain $parts[4] -Because $row
            foreach ($o in ($parts[6] -split ',')) { @('W10', 'W11') | Should -Contain $o -Because $row }
            $parts[7] | Should -Match '^HdCat' -Because $row
            $parts[8] | Should -Match '^(-|\?|-?\d+|[A-Za-z][A-Za-z0-9 _.-]*)$' -Because $row
        }
    }
    It 'never ships the Defender kill switch or bitwise WiFi Sense rows' {
        foreach ($row in $AllRows) { ($row -split '\|')[0] | Should -Not -Match '^(S011|S006|S007)(~|$)' }
    }
    It 'has no duplicate path|name within the shipped rows' {
        $keys = foreach ($row in $AllRows) { $p = $row -split '\|'; foreach ($path in ($p[2] -split ';')) { ($path + '|' + $p[3]).ToLowerInvariant() } }
        @($keys | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name) | Should -BeNullOrEmpty
    }
    It 'every entry has an EN and TR label and consequence key' {
        foreach ($e in @(ConvertFrom-WtHardeningRows -Rows $AllRows)) {
            foreach ($key in $e.LabelKey, $e.ConsequenceKey) {
                $script:Translations['EN'].ContainsKey($key) | Should -BeTrue -Because "EN needs '$key'"
                $script:Translations['TR'].ContainsKey($key) | Should -BeTrue -Because "TR needs '$key'"
            }
        }
    }
    It 'resolves every sub-header key in both languages' {
        $categories = @($AllRows | ForEach-Object { ($_ -split '\|')[7] } | Select-Object -Unique)
        $categories.Count | Should -BeGreaterOrEqual 15
        foreach ($key in $categories) {
            $script:Translations['EN'].ContainsKey($key) | Should -BeTrue -Because "EN needs '$key'"
            $script:Translations['TR'].ContainsKey($key) | Should -BeTrue -Because "TR needs '$key'"
        }
    }
    It 'ships at least 220 distinct settings' {
        @(ConvertFrom-WtHardeningRows -Rows $AllRows).Count | Should -BeGreaterOrEqual 220
    }
    It 'gives every screen group at least ten settings of its own' {
        $rowTable = Get-WtHardeningRows
        foreach ($group in $GroupNames) {
            @(ConvertFrom-WtHardeningRows -Rows @($rowTable[$group])).Count | Should -BeGreaterOrEqual 10 -Because "group '$group'"
        }
    }
    It 'ships the sibling values that make W004 and P017 actually bite' {
        $entries = @(ConvertFrom-WtHardeningRows -Rows $AllRows)
        $w004 = @($entries | Where-Object Name -eq 'HD_W004')
        $w004.Count | Should -Be 1
        $w004[0].RegistryChanges.Count | Should -Be 3
        $period = @($w004[0].RegistryChanges | Where-Object Name -eq 'DeferFeatureUpdatesPeriodInDays')
        $period.Count | Should -Be 1 -Because 'DeferFeatureUpdates=1 without a period defers by zero days'
        $period[0].Value | Should -Be 365
        $period[0].Path | Should -Be 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
        $p017 = @($entries | Where-Object Name -eq 'HD_P017')
        @($p017[0].RegistryChanges | Where-Object { $_.Name -eq 'EnableExperimentation' -and $_.Path -eq 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PreviewBuilds' }).Count | Should -Be 1
    }
}

Describe 'Get-WtHardeningCatalog' {
    It 'filters by OS' {
        $rows = @('X1|SAFE|HKLM:\A|V|DWord|1|W11|HdCatPrivacy|-', 'X2|SAFE|HKLM:\B|V|DWord|1|W10,W11|HdCatPrivacy|-')
        $w10 = @(Get-WtHardeningCatalog -Group 'PrivacyTelemetry' -IsWindows11 $false -Rows $rows -ExcludeKeys @())
        @($w10 | ForEach-Object Name) | Should -Be @('HD_X2')
        @(Get-WtHardeningCatalog -Group 'PrivacyTelemetry' -IsWindows11 $true -Rows $rows -ExcludeKeys @()).Count | Should -Be 2
    }
    It 'drops entries that write a path|name an existing catalog already owns' {
        $rows = @('X1|SAFE|HKLM:\A|V|DWord|1|W10,W11|HdCatPrivacy|-', 'X2|SAFE|HKLM:\B|V|DWord|1|W10,W11|HdCatPrivacy|-')
        $cat = @(Get-WtHardeningCatalog -Group 'PrivacyTelemetry' -IsWindows11 $true -Rows $rows -ExcludeKeys @('hklm:\a|v'))
        @($cat | ForEach-Object Name) | Should -Be @('HD_X2')
    }
    It 'localizes the label through the active language' {
        $old = $script:Language
        try {
            $script:Language = 'EN'
            $rows = @('P001|SAFE|HKLM:\A|V|DWord|1|W10,W11|HdCatPrivacy|-')
            $en = @(Get-WtHardeningCatalog -Group 'PrivacyTelemetry' -IsWindows11 $true -Rows $rows -ExcludeKeys @())
            $en[0].DisplayLabel | Should -Be $script:Translations['EN']['CatHardeningP001Label']
            $script:Language = 'TR'
            $tr = @(Get-WtHardeningCatalog -Group 'PrivacyTelemetry' -IsWindows11 $true -Rows $rows -ExcludeKeys @())
            $tr[0].Consequence | Should -Be $script:Translations['TR']['CatHardeningP001Consequence']
        }
        finally { $script:Language = $old }
    }
    It 'returns an empty catalog for a group that does not exist' {
        @(Get-WtHardeningCatalog -Group 'NoSuchGroup' -IsWindows11 $true -ExcludeKeys @()).Count | Should -Be 0
    }
    It 'reads the shipped rows for the group when none are passed' {
        $names = @(Get-WtHardeningCatalog -Group 'Update' -IsWindows11 $true -ExcludeKeys @() | ForEach-Object Name)
        $names | Should -Contain 'HD_W006'
    }
    It 'the shipped rows themselves avoid every pre-existing registry key' {
        $existing = @(Get-WtExistingRegistryKeys)
        $existing.Count | Should -BeGreaterThan 50
        foreach ($g in $GroupNames) {
            foreach ($e in @(Get-WtHardeningCatalog -Group $g -IsWindows11 $true -ExcludeKeys @())) {
                foreach ($k in @(Get-WtRegistryChangeKeys -Catalog @($e))) { $existing | Should -Not -Contain $k -Because "$($e.Name) duplicates an existing entry" }
            }
        }
    }
    It 'Get-WtRegistryChangeKeys lower-cases path|name and skips prose-only entries' {
        $catalog = @(
            [PSCustomObject]@{ Name = 'A'; RegistryChanges = @([PSCustomObject]@{ Path = 'HKLM:\Foo'; Name = 'Bar'; RegType = 'DWord'; Value = 1 }) }
            [PSCustomObject]@{ Name = 'B' }
        )
        @(Get-WtRegistryChangeKeys -Catalog $catalog) | Should -Be @('hklm:\foo|bar')
    }
    It 'Test-WtIsWindows11 keys off build 22000' {
        Test-WtIsWindows11 -Build 19045 | Should -BeFalse
        Test-WtIsWindows11 -Build 22631 | Should -BeTrue
        Test-WtIsWindows11 -Build 22000 | Should -BeTrue
    }
}

Describe 'Risk review of screens 5-8' {
    BeforeAll { $script:rows = Get-WtHardeningRows }
    It 'Windows Update rows that disable updates entirely are ADVANCED' {
        $advancedNeeded = @($rows['Update'] | Where-Object { $_ -match '\|NoAutoUpdate\||\|DoNotConnectToWindowsUpdateInternetLocations\||\|DisableWindowsUpdateAccess\|' })
        $advancedNeeded.Count | Should -BeGreaterThan 0
        foreach ($r in $advancedNeeded) { ($r -split '\|')[1] | Should -Be 'ADVANCED' -Because $r }
    }
    It 'Defender SpyNet / sample submission rows are at least CAUTION' {
        foreach ($r in @($rows['Security'] | Where-Object { $_ -match 'Spynet' })) { @('CAUTION', 'ADVANCED') | Should -Contain (($r -split '\|')[1]) -Because $r }
    }
    It 'no SAFE row writes under Windows Defender policies' {
        foreach ($r in @($rows.Values | ForEach-Object { $_ } | Where-Object { $_ -match 'Policies\\Microsoft\\Windows Defender' })) {
            ($r -split '\|')[1] | Should -Not -Be 'SAFE' -Because $r
        }
    }
    It 'each of the eight groups holds >= 10 base settings' {
        foreach ($g in $rows.Keys) {
            @(ConvertFrom-WtHardeningRows -Rows $rows[$g]).Count | Should -BeGreaterOrEqual 10 -Because $g
        }
    }
}

Describe 'Session memory for the hardening catalog and the exclusion keys' {
    It 'Get-WtExistingRegistryKeys is built once and handed back unchanged afterwards' {
        $script:WtExistingRegistryKeysCache = $null
        $first = @(Get-WtExistingRegistryKeys)
        $script:WtExistingRegistryKeysCache | Should -Not -BeNullOrEmpty
        $second = @(Get-WtExistingRegistryKeys)
        $second.Count | Should -Be $first.Count
        $second | Should -Be $first
    }
    It 'the same default build twice returns the same objects; OS family and language get their own; explicit rows or keys bypass the memory' {
        $old = $script:Language
        try {
            $script:WtHardeningCatalogCache = @{}
            $script:Language = 'EN'
            $a = @(Get-WtHardeningCatalog -Group 'PrivacyTelemetry' -IsWindows11 $true)
            $b = @(Get-WtHardeningCatalog -Group 'PrivacyTelemetry' -IsWindows11 $true)
            $a.Count | Should -BeGreaterThan 0
            $b.Count | Should -Be $a.Count
            [object]::ReferenceEquals($a[0], $b[0]) | Should -BeTrue
            $script:WtHardeningCatalogCache.ContainsKey('PrivacyTelemetry|W11|EN') | Should -BeTrue
            @(Get-WtHardeningCatalog -Group 'PrivacyTelemetry' -IsWindows11 $false) | Out-Null
            $script:WtHardeningCatalogCache.ContainsKey('PrivacyTelemetry|W10|EN') | Should -BeTrue
            $script:Language = 'TR'
            $c = @(Get-WtHardeningCatalog -Group 'PrivacyTelemetry' -IsWindows11 $true)
            $script:WtHardeningCatalogCache.ContainsKey('PrivacyTelemetry|W11|TR') | Should -BeTrue
            [object]::ReferenceEquals($a[0], $c[0]) | Should -BeFalse
            $before = $script:WtHardeningCatalogCache.Count
            @(Get-WtHardeningCatalog -Group 'PrivacyTelemetry' -IsWindows11 $true -ExcludeKeys @()) | Out-Null
            @(Get-WtHardeningCatalog -Group 'PrivacyTelemetry' -IsWindows11 $true -Rows @()) | Out-Null
            $script:WtHardeningCatalogCache.Count | Should -Be $before
        }
        finally {
            $script:Language = $old
            $script:WtHardeningCatalogCache = @{}
        }
    }
}
