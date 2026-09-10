BeforeAll {
    . (Join-Path (Join-Path $PSScriptRoot '..') 'dist/WinToolify.ps1')
    $script:catalogGetters = @(
        @{ Name = 'AiPrivacy'; Get = { Get-WtAiPrivacyCatalog } }
        @{ Name = 'Telemetry'; Get = { Get-WtTelemetryCatalog } }
        @{ Name = 'ActivityAdvertising'; Get = { Get-WtActivityAdvertisingCatalog } }
        @{ Name = 'SearchSuggestions'; Get = { Get-WtSearchSuggestionsCatalog } }
        @{ Name = 'AppPermission'; Get = { Get-WtAppPermissionCatalog } }
        @{ Name = 'ContextMenu'; Get = { Get-WtContextMenuCatalog } }
        @{ Name = 'ExplorerView'; Get = { Get-WtExplorerViewCatalog } }
        @{ Name = 'PowerPlan'; Get = { Get-WtPowerPlanCatalog } }
        @{ Name = 'GamingTweak'; Get = { Get-WtGamingTweakCatalog } }
        @{ Name = 'MemoryFlush'; Get = { Get-WtMemoryFlushCatalog } }
        @{ Name = 'Cleanup'; Get = { Get-WtCleanupCatalog } }
        @{ Name = 'BlocklistTier'; Get = { Get-WtBlocklistTierCatalog } }
        @{ Name = 'DnsPreset'; Get = { Get-WtDnsPresetCatalog } }
        @{ Name = 'DuplicateScanRoot'; Get = { Get-WtDuplicateScanRootCatalog } }
        @{ Name = 'Service'; Get = { Get-WtServiceCatalog } }
        @{ Name = 'Package'; Get = { Get-WtPackageCatalog } }
        @{ Name = 'Firewall'; Get = { Get-WtFirewallCatalog } }
        @{ Name = 'FastStartup'; Get = { Get-WtFastStartupCatalog } }
    )
}

Describe 'Resolve-WtCatalogText' {
    It 'resolves LabelKey/ConsequenceKey through the active language' {
        $old = $script:Language
        try {
            $script:Language = 'EN'
            $catalog = @([PSCustomObject]@{ Name = 'X'; LabelKey = 'Exit'; ConsequenceKey = 'Exit'; DisplayLabel = 'stale'; Consequence = 'stale' })
            $resolved = Resolve-WtCatalogText -Catalog $catalog
            $resolved[0].DisplayLabel | Should -Be $script:Translations['EN']['Exit']
            $script:Language = 'TR'
            $resolved2 = Resolve-WtCatalogText -Catalog $catalog
            $resolved2[0].Consequence | Should -Be $script:Translations['TR']['Exit']
        }
        finally { $script:Language = $old }
    }
    It 'passes entries without keys through untouched' {
        $catalog = @([PSCustomObject]@{ Name = 'X'; DisplayLabel = 'keep me' })
        (Resolve-WtCatalogText -Catalog $catalog)[0].DisplayLabel | Should -Be 'keep me'
    }
    It 'synthesizes keys from -KeyPrefix for prose-carrying entries only' {
        $catalog = @(
            [PSCustomObject]@{ Name = 'Some.Thing-1'; DisplayLabel = 'Label'; Consequence = $null }
            [PSCustomObject]@{ Name = 'Silent'; Consequence = $null }
        )
        $resolved = Resolve-WtCatalogText -Catalog $catalog -KeyPrefix 'Test'
        $resolved[0].LabelKey | Should -Be 'CatTestSomeThing1Label'
        $resolved[0].PSObject.Properties.Name | Should -Not -Contain 'ConsequenceKey'
        $resolved[1].PSObject.Properties.Name | Should -Not -Contain 'LabelKey'
    }
    It 'keeps an explicit key over the synthesized one' {
        $catalog = @([PSCustomObject]@{ Name = 'X'; DisplayLabel = 'stale'; LabelKey = 'Exit' })
        (Resolve-WtCatalogText -Catalog $catalog -KeyPrefix 'Test')[0].LabelKey | Should -Be 'Exit'
    }
    It 'leaves the shipped literal in place when the key is missing from the table' {
        $catalog = @([PSCustomObject]@{ Name = 'X'; DisplayLabel = 'shipped'; LabelKey = 'NoSuchKey__' })
        (Resolve-WtCatalogText -Catalog $catalog)[0].DisplayLabel | Should -Be 'shipped'
    }
}

Describe 'Catalog translation completeness' {
    It 'every prose-carrying entry has keys present in BOTH languages' {
        $failures = New-Object System.Collections.Generic.List[string]
        foreach ($getter in $catalogGetters) {
            foreach ($entry in @(& $getter.Get)) {
                $props = $entry.PSObject.Properties.Name
                if ($props -contains 'DisplayLabel' -and $entry.DisplayLabel -and -not ($props -contains 'LabelKey' -and $entry.LabelKey)) {
                    $failures.Add("$($getter.Name)/$($entry.Name): DisplayLabel without LabelKey")
                }
                if ($props -contains 'Consequence' -and $entry.Consequence -and -not ($props -contains 'ConsequenceKey' -and $entry.ConsequenceKey)) {
                    $failures.Add("$($getter.Name)/$($entry.Name): Consequence without ConsequenceKey")
                }
                foreach ($keyProp in 'LabelKey', 'ConsequenceKey') {
                    if ($props -contains $keyProp -and $entry.$keyProp) {
                        foreach ($lang in 'EN', 'TR') {
                            if (-not $script:Translations[$lang].ContainsKey($entry.$keyProp) -or -not $script:Translations[$lang][$entry.$keyProp]) {
                                $failures.Add("$($getter.Name)/$($entry.Name): $keyProp '$($entry.$keyProp)' missing in $lang")
                            }
                        }
                    }
                }
            }
        }
        ($failures -join "`n") | Should -BeNullOrEmpty
    }
    It 'TR catalog prose is ASCII and actually translated' {
        $failures = New-Object System.Collections.Generic.List[string]
        foreach ($key in @($script:Translations['TR'].Keys | Where-Object { $_ -like 'Cat*Label' -or $_ -like 'Cat*Consequence' })) {
            $tr = [string]$script:Translations['TR'][$key]
            if ($tr -cmatch '[^\x00-\x7F]') { $failures.Add("$key is not ASCII") }
            if ($tr -eq [string]$script:Translations['EN'][$key]) { $failures.Add("$key is identical in EN and TR") }
        }
        ($failures -join "`n") | Should -BeNullOrEmpty
    }
    It 'labels differ between EN and TR for a prose catalog' {
        $old = $script:Language
        try {
            $script:Language = 'EN'
            $en = (Get-WtTelemetryCatalog)[0].DisplayLabel
            $script:Language = 'TR'
            $tr = (Get-WtTelemetryCatalog)[0].DisplayLabel
            $tr | Should -Not -Be $en
        }
        finally { $script:Language = $old }
    }
}
