BeforeAll {
    . (Join-Path (Join-Path $PSScriptRoot '..') 'dist/WinToolify.ps1')
}

Describe 'Apply records' {
    It 'New-WtApplyRecord produces the commit-plan record shape with defaults' {
        $r = New-WtApplyRecord -SectionKey 'Services' -EntryName 'Fax'
        $r.SectionKey | Should -Be 'Services'
        $r.EntryName | Should -Be 'Fax'
        $r.DisplayLabel | Should -Be 'Fax'
        $r.Risk | Should -Be 'SAFE'
        $r.RestartsExplorer | Should -BeFalse
        $r.RequiresReboot | Should -BeFalse
        $r.Data | Should -BeNullOrEmpty
    }
    It 'ConvertTo-WtApplyRecords builds one record per marked name from Meta, sorted' {
        $sel = New-Object 'System.Collections.Generic.HashSet[string]'
        'b', 'a' | ForEach-Object { $sel.Add($_) | Out-Null }
        $meta = @{
            a = @{ SectionKey = 'ExplorerView'; Entry = [PSCustomObject]@{ Name = 'a'; DisplayLabel = 'Alpha'; Risk = 'CAUTION'; RestartsExplorer = $true }; Data = $null }
            b = @{ SectionKey = 'GamingTweaks'; Entry = [PSCustomObject]@{ Name = 'b'; DisplayLabel = 'Beta'; Risk = 'SAFE'; RestartRequired = $true }; Data = @{ Mechanism = 'Hosts' } }
            c = @{ SectionKey = 'Services'; Entry = [PSCustomObject]@{ Name = 'c' }; Data = $null }
        }
        $records = @(ConvertTo-WtApplyRecords -Selection $sel -Meta $meta)
        @($records | ForEach-Object EntryName) | Should -Be @('a', 'b')
        $records[0].RestartsExplorer | Should -BeTrue
        $records[0].Risk | Should -Be 'CAUTION'
        $records[1].RequiresReboot | Should -BeTrue
        $records[1].Data.Mechanism | Should -Be 'Hosts'
    }
    It 'ignores marked names that are not in Meta' {
        $sel = New-Object 'System.Collections.Generic.HashSet[string]'
        $sel.Add('ghost') | Out-Null
        @(ConvertTo-WtApplyRecords -Selection $sel -Meta @{}).Count | Should -Be 0
    }
    It 'records default to Direction Apply and accept Remove' {
        (New-WtApplyRecord -SectionKey 'Telemetry' -EntryName 'X').Direction | Should -Be 'Apply'
        (New-WtApplyRecord -SectionKey 'Telemetry' -EntryName 'X' -Direction 'Remove').Direction | Should -Be 'Remove'
    }
    It 'ConvertTo-WtApplyRecords marks a name whose row is Applied as a Remove' {
        $sel = New-Object 'System.Collections.Generic.HashSet[string]'
        'on', 'off' | ForEach-Object { $sel.Add($_) | Out-Null }
        $meta = @{
            on  = @{ SectionKey = 'Telemetry'; Entry = [PSCustomObject]@{ Name = 'on'; DisplayLabel = 'On'; Risk = 'ADVANCED' }; Data = $null }
            off = @{ SectionKey = 'Telemetry'; Entry = [PSCustomObject]@{ Name = 'off'; DisplayLabel = 'Off'; Risk = 'SAFE' }; Data = $null }
        }
        $items = @(
            New-WtListItem -Kind 'Check' -Name 'on' -Label 'On' -Applied $true -Removable $true
            New-WtListItem -Kind 'Check' -Name 'off' -Label 'Off'
        )
        $records = @(ConvertTo-WtApplyRecords -Selection $sel -Meta $meta -Items $items)
        ($records | Where-Object EntryName -eq 'on').Direction | Should -Be 'Remove'
        ($records | Where-Object EntryName -eq 'off').Direction | Should -Be 'Apply'
        @(ConvertTo-WtApplyRecords -Selection $sel -Meta $meta | ForEach-Object Direction) | Should -Be @('Apply', 'Apply')
    }
}

Describe 'Get-WtApplySectionCatalog' {
    It 'contains every profile section plus the stage-only sections' {
        $keys = @((Get-WtApplySectionCatalog) | ForEach-Object Key)
        foreach ($k in @((Get-WtProfileSectionCatalog) | ForEach-Object Key)) { $keys | Should -Contain $k }
        foreach ($k in 'DnsPreset', 'Blocklist', 'PerAppPermissions') { $keys | Should -Contain $k }
    }
    It 'keeps Explorer-touching sections last' {
        $rows = @(Get-WtApplySectionCatalog)
        $firstExplorer = 0..($rows.Count - 1) | Where-Object { $rows[$_].RestartsExplorer } | Select-Object -First 1
        $lastNonExplorer = 0..($rows.Count - 1) | Where-Object { -not $rows[$_].RestartsExplorer } | Select-Object -Last 1
        $lastNonExplorer | Should -BeLessThan $firstExplorer
    }
    It 'profile catalog gained Firewall and FastStartup between GamingTweaks and ContextMenu' {
        $keys = @((Get-WtProfileSectionCatalog) | ForEach-Object Key)
        $keys.IndexOf('Firewall') | Should -BeGreaterThan $keys.IndexOf('GamingTweaks')
        $keys.IndexOf('FastStartup') | Should -BeGreaterThan $keys.IndexOf('Firewall')
        $keys.IndexOf('ContextMenu') | Should -BeGreaterThan $keys.IndexOf('FastStartup')
    }
    It 'stage-only rows are flagged and stateless' {
        $dns = @(Get-WtApplySectionCatalog) | Where-Object Key -eq 'DnsPreset'
        $dns.StageOnly | Should -BeTrue
        $dns.GetState | Should -BeNullOrEmpty
    }
}

Describe 'Get-WtCommitPlan' {
    BeforeEach {
        $script:fakeSections = @(
            [PSCustomObject]@{ Key = 'Services'; TitleKey = 'T1'; RestartsExplorer = $false }
            [PSCustomObject]@{ Key = 'Packages'; TitleKey = 'T2'; RestartsExplorer = $false }
            [PSCustomObject]@{ Key = 'Firewall'; TitleKey = 'T3'; RestartsExplorer = $false }
            [PSCustomObject]@{ Key = 'ExplorerView'; TitleKey = 'T4'; RestartsExplorer = $true }
        )
        $script:pkgCatalog = { @(
            [PSCustomObject]@{ Name = 'Good.App'; Restorable = $true }
            [PSCustomObject]@{ Name = 'Gone.App'; Restorable = $false }
        ) }
    }

    It 'groups by section in catalog order and skips empty sections' {
        $records = @(
            New-WtApplyRecord -SectionKey 'ExplorerView' -EntryName 'ShowExt' -RestartsExplorer $true
            New-WtApplyRecord -SectionKey 'Services' -EntryName 'Svc1'
        )
        $plan = Get-WtCommitPlan -ChangeSet $records -Sections $fakeSections -GetPackageCatalog $pkgCatalog
        @($plan.Sections | ForEach-Object Key) -join ',' | Should -Be 'Services,ExplorerView'
        $plan.HasExplorerRestart | Should -BeTrue
    }
    It 'collects ADVANCED and non-restorable gates' {
        $records = @(
            New-WtApplyRecord -SectionKey 'Packages' -EntryName 'Gone.App' -Risk 'ADVANCED'
            New-WtApplyRecord -SectionKey 'Packages' -EntryName 'Good.App'
        )
        $plan = Get-WtCommitPlan -ChangeSet $records -Sections $fakeSections -GetPackageCatalog $pkgCatalog
        @($plan.AdvancedEntries).Count | Should -Be 1
        @($plan.NonRestorablePackageNames) | Should -Be @('Gone.App')
    }
    It 'keeps only the last staged firewall direction' {
        $records = @(
            New-WtApplyRecord -SectionKey 'Firewall' -EntryName 'DisableFirewall'
            New-WtApplyRecord -SectionKey 'Firewall' -EntryName 'EnableFirewall'
        )
        $plan = Get-WtCommitPlan -ChangeSet $records -Sections $fakeSections -GetPackageCatalog $pkgCatalog
        @(($plan.Sections | Where-Object Key -eq 'Firewall').EntryNames) | Should -Be @('EnableFirewall')
    }
    It 'reports unknown sections and reboot entries' {
        $records = @(
            New-WtApplyRecord -SectionKey 'Mystery' -EntryName 'X'
            New-WtApplyRecord -SectionKey 'Services' -EntryName 'GpuThing' -RequiresReboot $true
        )
        $plan = Get-WtCommitPlan -ChangeSet $records -Sections $fakeSections -GetPackageCatalog $pkgCatalog
        @($plan.UnknownEntries).Count | Should -Be 1
        @($plan.RebootEntryNames) | Should -Be @('GpuThing')
    }
    It 'carries section Data (blocklist mechanism)' {
        $sections = @([PSCustomObject]@{ Key = 'Blocklist'; TitleKey = 'T'; RestartsExplorer = $false })
        $records = @(New-WtApplyRecord -SectionKey 'Blocklist' -EntryName 'Spy' -Data @{ Mechanism = 'Both' })
        $plan = Get-WtCommitPlan -ChangeSet $records -Sections $sections -GetPackageCatalog $pkgCatalog
        ($plan.Sections[0]).Data.Mechanism | Should -Be 'Both'
    }
    It 'splits each section into ApplyNames and RemoveNames and gates only Apply-direction ADVANCED rows' {
        $records = @(
            New-WtApplyRecord -SectionKey 'Services' -EntryName 'On' -Risk 'ADVANCED' -Direction 'Remove'
            New-WtApplyRecord -SectionKey 'Services' -EntryName 'Off' -Risk 'ADVANCED'
            New-WtApplyRecord -SectionKey 'Services' -EntryName 'Plain'
        )
        $plan = Get-WtCommitPlan -ChangeSet $records -Sections $fakeSections -GetPackageCatalog $pkgCatalog
        @($plan.Sections[0].EntryNames) | Should -Be @('On', 'Off', 'Plain')
        @($plan.Sections[0].ApplyNames) | Should -Be @('Off', 'Plain')
        @($plan.Sections[0].RemoveNames) | Should -Be @('On')
        @($plan.AdvancedEntries | ForEach-Object EntryName) | Should -Be @('Off')
    }
}

Describe 'Invoke-WtCommitChangeSet' {
    BeforeEach {
        $script:applied = New-Object 'System.Collections.Generic.List[string]'
        $script:okApply = { param([string[]]$Names, $Data) $script:applied.Add(($Names -join '+')); [PSCustomObject]@{ Aborted = $false; Results = @($Names | ForEach-Object { [PSCustomObject]@{ Item = [PSCustomObject]@{ Name = $_ }; Applied = $true; Error = $null } }) } }
        $script:abortApply = { param([string[]]$Names, $Data) [PSCustomObject]@{ Aborted = $true; Results = @() } }
    }

    It 'applies sections in order and aggregates outcomes' {
        $sections = @(
            [PSCustomObject]@{ Key = 'A'; TitleKey = 'TA'; RestartsExplorer = $false; Apply = $okApply }
            [PSCustomObject]@{ Key = 'B'; TitleKey = 'TB'; RestartsExplorer = $true; Apply = $okApply }
        )
        $records = @(
            New-WtApplyRecord -SectionKey 'B' -EntryName 'X' -RestartsExplorer $true
            New-WtApplyRecord -SectionKey 'A' -EntryName 'Y'
        )
        $plan = Get-WtCommitPlan -ChangeSet $records -Sections $sections -GetPackageCatalog { @() }
        $r = Invoke-WtCommitChangeSet -Plan $plan -Sections $sections
        $r.Aborted | Should -BeFalse
        @($script:applied) -join ',' | Should -Be 'Y,X'
        $r.NeedsExplorerRestart | Should -BeTrue
        @($r.Sections | ForEach-Object Outcome) | Should -Be @('Applied', 'Applied')
    }
    It 'first section abort skips the rest' {
        $sections = @(
            [PSCustomObject]@{ Key = 'A'; TitleKey = 'TA'; RestartsExplorer = $false; Apply = $abortApply }
            [PSCustomObject]@{ Key = 'B'; TitleKey = 'TB'; RestartsExplorer = $false; Apply = $okApply }
        )
        $records = @(
            New-WtApplyRecord -SectionKey 'A' -EntryName 'Y'
            New-WtApplyRecord -SectionKey 'B' -EntryName 'X'
        )
        $plan = Get-WtCommitPlan -ChangeSet $records -Sections $sections -GetPackageCatalog { @() }
        $r = Invoke-WtCommitChangeSet -Plan $plan -Sections $sections
        @($r.Sections | ForEach-Object Outcome) | Should -Be @('Aborted', 'Skipped')
        @($script:applied).Count | Should -Be 0
    }
    It 'contains a section that THROWS: reports its entries as failed and still runs the next section' {
        $throwApply = { param([string[]]$Names, $Data) throw 'The term Get-DnsClientDohServerAddress is not recognized' }
        $sections = @(
            [PSCustomObject]@{ Key = 'A'; TitleKey = 'TA'; RestartsExplorer = $false; Apply = $throwApply }
            [PSCustomObject]@{ Key = 'B'; TitleKey = 'TB'; RestartsExplorer = $false; Apply = $okApply }
        )
        $records = @(
            New-WtApplyRecord -SectionKey 'A' -EntryName 'Cloudflare'
            New-WtApplyRecord -SectionKey 'B' -EntryName 'X'
        )
        $plan = Get-WtCommitPlan -ChangeSet $records -Sections $sections -GetPackageCatalog { @() }
        $r = Invoke-WtCommitChangeSet -Plan $plan -Sections $sections
        @($r.Sections | ForEach-Object Outcome) | Should -Be @('Applied', 'Applied')
        $r.Aborted | Should -BeFalse
        @($script:applied) -join ',' | Should -Be 'X'
        $failedRow = @($r.Sections | Where-Object Key -eq 'A' | ForEach-Object Results)[0]
        $failedRow.Item.Name | Should -Be 'Cloudflare'
        $failedRow.Applied | Should -BeFalse
        $failedRow.Direction | Should -Be 'Apply'
        $failedRow.Error | Should -BeLike '*Get-DnsClientDohServerAddress*'
    }
    It 'contains a TurnOff that throws the same way' {
        $sections = @([PSCustomObject]@{ Key = 'A'; TitleKey = 'TA'; RestartsExplorer = $false; Apply = $okApply; TurnOff = { param([string[]]$Names, $Data) throw 'boom' } })
        $records = @(New-WtApplyRecord -SectionKey 'A' -EntryName 'Y' -Direction 'Remove')
        $plan = Get-WtCommitPlan -ChangeSet $records -Sections $sections -GetPackageCatalog { @() }
        $r = Invoke-WtCommitChangeSet -Plan $plan -Sections $sections
        $row = @($r.Sections[0].Results)[0]
        $row.Direction | Should -Be 'Remove'
        $row.Error | Should -Be 'boom'
    }
    It 'reports reboot entries when something applied' {
        $sections = @([PSCustomObject]@{ Key = 'A'; TitleKey = 'TA'; RestartsExplorer = $false; Apply = $okApply })
        $records = @(New-WtApplyRecord -SectionKey 'A' -EntryName 'Gpu' -RequiresReboot $true)
        $plan = Get-WtCommitPlan -ChangeSet $records -Sections $sections -GetPackageCatalog { @() }
        (Invoke-WtCommitChangeSet -Plan $plan -Sections $sections).RebootEntryNames | Should -Be @('Gpu')
    }
    It 'runs Apply for the apply names, then TurnOff for the remove names, tagging rows with their direction' {
        $script:turnedOff = New-Object 'System.Collections.Generic.List[string]'
        $turnOff = { param([string[]]$Names, $Data) $script:turnedOff.Add(($Names -join '+')); [PSCustomObject]@{ Aborted = $false; Results = @($Names | ForEach-Object { [PSCustomObject]@{ Item = [PSCustomObject]@{ Name = $_ }; Applied = $true; Error = $null } }) } }
        $sections = @([PSCustomObject]@{ Key = 'A'; TitleKey = 'TA'; RestartsExplorer = $false; Apply = $okApply; TurnOff = $turnOff })
        $records = @(
            New-WtApplyRecord -SectionKey 'A' -EntryName 'Keep' -Direction 'Remove'
            New-WtApplyRecord -SectionKey 'A' -EntryName 'New'
        )
        $plan = Get-WtCommitPlan -ChangeSet $records -Sections $sections -GetPackageCatalog { @() }
        $r = Invoke-WtCommitChangeSet -Plan $plan -Sections $sections
        @($script:applied) | Should -Be @('New')
        @($script:turnedOff) | Should -Be @('Keep')
        $r.Sections[0].Outcome | Should -Be 'Applied'
        @($r.Sections[0].Results | ForEach-Object { "$($_.Item.Name):$($_.Direction)" }) | Should -Be @('New:Apply', 'Keep:Remove')
    }
    It 'a section without TurnOff reports its removes as failed with the unavailable note and still applies the rest' {
        $sections = @([PSCustomObject]@{ Key = 'A'; TitleKey = 'TA'; RestartsExplorer = $false; Apply = $okApply })
        $records = @(
            New-WtApplyRecord -SectionKey 'A' -EntryName 'Keep' -Direction 'Remove'
            New-WtApplyRecord -SectionKey 'A' -EntryName 'New'
        )
        $plan = Get-WtCommitPlan -ChangeSet $records -Sections $sections -GetPackageCatalog { @() }
        $r = Invoke-WtCommitChangeSet -Plan $plan -Sections $sections
        $rows = @($r.Sections[0].Results)
        ($rows | Where-Object { $_.Item.Name -eq 'Keep' }).Applied | Should -BeFalse
        ($rows | Where-Object { $_.Item.Name -eq 'Keep' }).Error | Should -Be (Get-Translation 'RemoveUnavailable')
        ($rows | Where-Object { $_.Item.Name -eq 'New' }).Applied | Should -BeTrue
    }
    It 'a TurnOff abort marks the section Aborted and skips later sections' {
        $abortOff = { param([string[]]$Names, $Data) [PSCustomObject]@{ Aborted = $true; Results = @() } }
        $sections = @(
            [PSCustomObject]@{ Key = 'A'; TitleKey = 'TA'; RestartsExplorer = $false; Apply = $okApply; TurnOff = $abortOff }
            [PSCustomObject]@{ Key = 'B'; TitleKey = 'TB'; RestartsExplorer = $false; Apply = $okApply }
        )
        $records = @(
            New-WtApplyRecord -SectionKey 'A' -EntryName 'Keep' -Direction 'Remove'
            New-WtApplyRecord -SectionKey 'B' -EntryName 'Later'
        )
        $plan = Get-WtCommitPlan -ChangeSet $records -Sections $sections -GetPackageCatalog { @() }
        $r = Invoke-WtCommitChangeSet -Plan $plan -Sections $sections
        @($r.Sections | ForEach-Object Outcome) | Should -Be @('Aborted', 'Skipped')
    }
    It 'keeps the Apply half rows when the TurnOff half aborts, and still offers the Explorer restart' {
        $abortOff = { param([string[]]$Names, $Data) [PSCustomObject]@{ Aborted = $true; Results = @() } }
        $sections = @([PSCustomObject]@{ Key = 'A'; TitleKey = 'TA'; RestartsExplorer = $true; Apply = $okApply; TurnOff = $abortOff })
        $records = @(
            New-WtApplyRecord -SectionKey 'A' -EntryName 'New'
            New-WtApplyRecord -SectionKey 'A' -EntryName 'Keep' -Direction 'Remove'
        )
        $plan = Get-WtCommitPlan -ChangeSet $records -Sections $sections -GetPackageCatalog { @() }
        $r = Invoke-WtCommitChangeSet -Plan $plan -Sections $sections
        $r.Sections[0].Outcome | Should -Be 'Aborted'
        $newRow = $r.Sections[0].Results | Where-Object { $_.Item.Name -eq 'New' }
        $newRow.Direction | Should -Be 'Apply'
        $newRow.Applied | Should -BeTrue
        $r.NeedsExplorerRestart | Should -BeTrue
        $r.Aborted | Should -BeTrue
    }
}

Describe 'ConvertTo-WtBlocklistMechanism' {
    It 'maps 1/2/3 and rejects anything else' {
        ConvertTo-WtBlocklistMechanism -Answer '1' | Should -Be 'Hosts'
        ConvertTo-WtBlocklistMechanism -Answer ' 2 ' | Should -Be 'Firewall'
        ConvertTo-WtBlocklistMechanism -Answer '3' | Should -Be 'Both'
        ConvertTo-WtBlocklistMechanism -Answer 'x' | Should -BeNullOrEmpty
        ConvertTo-WtBlocklistMechanism -Answer $null | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-WtApplyGates' {
    BeforeEach {
        $script:fakeSections = @(
            [PSCustomObject]@{ Key = 'Services'; TitleKey = 'ServicesManagement'; RestartsExplorer = $false; GetCatalog = { @([PSCustomObject]@{ Name = 'Fax'; Risk = 'SAFE' }) } }
            [PSCustomObject]@{ Key = 'Packages'; TitleKey = 'InstalledApps'; RestartsExplorer = $false; GetCatalog = { @([PSCustomObject]@{ Name = 'Gone.App'; Risk = 'ADVANCED'; Consequence = 'gone'; Restorable = $false }) } }
            [PSCustomObject]@{ Key = 'DnsPreset'; TitleKey = 'DnsPreset'; RestartsExplorer = $false; GetCatalog = { @([PSCustomObject]@{ Name = 'Quad9'; Risk = 'CAUTION' }) } }
            [PSCustomObject]@{ Key = 'Blocklist'; TitleKey = 'BlocklistSection'; RestartsExplorer = $false; GetCatalog = { @([PSCustomObject]@{ Name = 'Spy'; Risk = 'SAFE' }) } }
        )
        $script:pkgCatalog = { @([PSCustomObject]@{ Name = 'Gone.App'; Risk = 'ADVANCED'; Restorable = $false }) }
        $script:dns = { param($p) "dns:$p" }
        $script:queue = { param([string[]]$Answers) $q = New-Object 'System.Collections.Generic.Queue[string]'; foreach ($a in $Answers) { $q.Enqueue($a) }; return { param($Lines, $Prompt, $Risk) $q.Dequeue() }.GetNewClosure() }
    }
    It 'drops ADVANCED records unless CONFIRM is typed' {
        $records = @((New-WtApplyRecord -SectionKey 'Services' -EntryName 'Fax'), (New-WtApplyRecord -SectionKey 'Packages' -EntryName 'Gone.App' -Risk 'ADVANCED'))
        $r = Invoke-WtApplyGates -Records $records -Sections $fakeSections -GetPackageCatalog $pkgCatalog -ReadAnswer (& $queue @('nope')) -GetDnsDisclosure $dns
        @($r.Records | ForEach-Object EntryName) | Should -Be @('Fax')
        @($r.Plan.Sections | ForEach-Object Key) | Should -Be @('Services')
    }
    It 'CONFIRM then YES keeps the non-restorable ADVANCED package' {
        $records = @((New-WtApplyRecord -SectionKey 'Packages' -EntryName 'Gone.App' -Risk 'ADVANCED'))
        $r = Invoke-WtApplyGates -Records $records -Sections $fakeSections -GetPackageCatalog $pkgCatalog -ReadAnswer (& $queue @('CONFIRM', 'YES')) -GetDnsDisclosure $dns
        @($r.Records | ForEach-Object EntryName) | Should -Be @('Gone.App')
    }
    It '-PreApprovedAdvanced keeps ADVANCED and non-restorable records without asking (the assistant approval already did)' {
        $records = @((New-WtApplyRecord -SectionKey 'Services' -EntryName 'Fax'), (New-WtApplyRecord -SectionKey 'Packages' -EntryName 'Gone.App' -Risk 'ADVANCED'))
        $never = { param($Lines, $Prompt, $Risk) throw ('gate asked again: ' + $Prompt) }
        $r = Invoke-WtApplyGates -Records $records -Sections $fakeSections -GetPackageCatalog $pkgCatalog -ReadAnswer $never -GetDnsDisclosure $dns -PreApprovedAdvanced
        @($r.Records | ForEach-Object EntryName) | Should -Be @('Fax', 'Gone.App')
        $r.TypedConfirmation | Should -BeTrue
        @($r.Dropped).Count | Should -Be 0
        $script:asked = 0
        $dnsRecords = @((New-WtApplyRecord -SectionKey 'DnsPreset' -EntryName 'Quad9' -Risk 'CAUTION'))
        $null = Invoke-WtApplyGates -Records $dnsRecords -Sections $fakeSections -GetPackageCatalog $pkgCatalog -ReadAnswer { param($Lines, $Prompt, $Risk) $script:asked++; 'YES' } -GetDnsDisclosure $dns -PreApprovedAdvanced
        $script:asked | Should -Be 1
    }
    It 'CONFIRM then a non-YES drops the non-restorable package' {
        $records = @((New-WtApplyRecord -SectionKey 'Packages' -EntryName 'Gone.App' -Risk 'ADVANCED'))
        $r = Invoke-WtApplyGates -Records $records -Sections $fakeSections -GetPackageCatalog $pkgCatalog -ReadAnswer (& $queue @('CONFIRM', 'no')) -GetDnsDisclosure $dns
        @($r.Records).Count | Should -Be 0
    }
    It 'DNS needs YES and the disclosure is shown' {
        $script:shown = @()
        $reader = { param($Lines, $Prompt, $Risk) $script:shown += @($Lines); 'YES' }
        $records = @((New-WtApplyRecord -SectionKey 'DnsPreset' -EntryName 'Quad9' -Risk 'CAUTION'))
        $r = Invoke-WtApplyGates -Records $records -Sections $fakeSections -GetPackageCatalog $pkgCatalog -ReadAnswer $reader -GetDnsDisclosure $dns
        @($r.Records).Count | Should -Be 1
        $script:shown | Should -Contain 'dns:Quad9'
        $r2 = Invoke-WtApplyGates -Records $records -Sections $fakeSections -GetPackageCatalog $pkgCatalog -ReadAnswer { param($Lines, $Prompt, $Risk) '' } -GetDnsDisclosure $dns
        @($r2.Records).Count | Should -Be 0
    }
    It 'blocklist tiers get the chosen mechanism in Data, or are dropped on a bad answer' {
        $records = @((New-WtApplyRecord -SectionKey 'Blocklist' -EntryName 'Spy'))
        $r = Invoke-WtApplyGates -Records $records -Sections $fakeSections -GetPackageCatalog $pkgCatalog -ReadAnswer { param($Lines, $Prompt, $Risk) '3' } -GetDnsDisclosure $dns
        $r.Records[0].Data.Mechanism | Should -Be 'Both'
        ($r.Plan.Sections | Where-Object Key -eq 'Blocklist').Data.Mechanism | Should -Be 'Both'
        $r2 = Invoke-WtApplyGates -Records $records -Sections $fakeSections -GetPackageCatalog $pkgCatalog -ReadAnswer { param($Lines, $Prompt, $Risk) 'z' } -GetDnsDisclosure $dns
        @($r2.Records).Count | Should -Be 0
    }
    It 'SAFE-only records pass through without prompting' {
        $records = @((New-WtApplyRecord -SectionKey 'Services' -EntryName 'Fax'))
        $r = Invoke-WtApplyGates -Records $records -Sections $fakeSections -GetPackageCatalog $pkgCatalog -ReadAnswer { throw 'must not prompt' } -GetDnsDisclosure $dns
        @($r.Records).Count | Should -Be 1
    }
}

Describe 'Direction-aware result lines and counts' {
    BeforeEach {
        $script:result = [PSCustomObject]@{
            Aborted = $false; NeedsExplorerRestart = $false; RebootEntryNames = [string[]]@()
            Sections = @([PSCustomObject]@{
                Key = 'Telemetry'; TitleKey = 'Telemetry'; RestartsExplorer = $false; Outcome = 'Applied'
                Results = @(
                    [PSCustomObject]@{ Item = [PSCustomObject]@{ CatalogEntry = 'A'; Name = 'A' }; Applied = $true; Error = $null; Direction = 'Apply' }
                    [PSCustomObject]@{ Item = [PSCustomObject]@{ CatalogEntry = 'B'; Name = 'B' }; Applied = $true; Error = $null; Direction = 'Remove' }
                    [PSCustomObject]@{ Item = [PSCustomObject]@{ CatalogEntry = 'C'; Name = 'C' }; Applied = $false; Error = 'denied'; Direction = 'Remove' }
                    [PSCustomObject]@{ Item = [PSCustomObject]@{ CatalogEntry = 'D'; Name = 'D' }; Applied = $false; Error = $null }
                )
            })
        }
    }
    It 'prints Removed / Not removed for remove rows and Applied / Not applied otherwise' {
        $lines = @(Get-WtApplyResultLines -Result $result -Sections @([PSCustomObject]@{ Key = 'Telemetry'; TitleKey = 'Telemetry' }))
        $lines[1] | Should -Be ('  A: ' + (Get-Translation 'Applied'))
        $lines[2] | Should -Be ('  B: ' + (Get-Translation 'Removed'))
        $lines[3] | Should -Be ('  C: ' + (Get-Translation 'NotRemoved') + ' - denied')
        $lines[4] | Should -Be ('  D: ' + (Get-Translation 'NotApplied'))
    }
    It 'counts applied, removed and failed rows' {
        $c = Get-WtApplyResultCounts -Result $result
        $c.Applied | Should -Be 1
        $c.Removed | Should -Be 1
        $c.Failed | Should -Be 2
    }
    It 'an Aborted section prints the row it already applied before the cancelled line' {
        $abortedResult = [PSCustomObject]@{
            Aborted = $true; NeedsExplorerRestart = $false; RebootEntryNames = [string[]]@()
            Sections = @([PSCustomObject]@{
                Key = 'Telemetry'; TitleKey = 'Telemetry'; RestartsExplorer = $false; Outcome = 'Aborted'
                Results = @(
                    [PSCustomObject]@{ Item = [PSCustomObject]@{ CatalogEntry = 'A'; Name = 'A' }; Applied = $true; Error = $null; Direction = 'Apply' }
                )
            })
        }
        $lines = @(Get-WtApplyResultLines -Result $abortedResult -Sections @([PSCustomObject]@{ Key = 'Telemetry'; TitleKey = 'Telemetry' }))
        $lines[1] | Should -Be ('  A: ' + (Get-Translation 'Applied'))
        $lines[2] | Should -Be ('  ' + (Get-Translation 'ActionCancelled'))
    }
}

Describe 'A refused gate says what it cost, not just "nothing left"' {
    BeforeEach {
        $script:gSections = @(
            [PSCustomObject]@{ Key = 'Services'; TitleKey = 'ServicesManagement'; RestartsExplorer = $false; GetCatalog = { @([PSCustomObject]@{ Name = 'Fax'; Risk = 'SAFE' }) } }
            [PSCustomObject]@{ Key = 'Packages'; TitleKey = 'InstalledApps'; RestartsExplorer = $false; GetCatalog = { @([PSCustomObject]@{ Name = 'Gone.App'; Risk = 'ADVANCED'; Restorable = $false }) } }
            [PSCustomObject]@{ Key = 'DnsPreset'; TitleKey = 'DnsPreset'; RestartsExplorer = $false; GetCatalog = { @([PSCustomObject]@{ Name = 'Quad9'; Risk = 'CAUTION' }) } }
            [PSCustomObject]@{ Key = 'Blocklist'; TitleKey = 'BlocklistSection'; RestartsExplorer = $false; GetCatalog = { @([PSCustomObject]@{ Name = 'Spy'; Risk = 'SAFE' }) } }
        )
        $script:gPkg = { @([PSCustomObject]@{ Name = 'Gone.App'; Risk = 'ADVANCED'; Restorable = $false }) }
        $script:gDns = { param($p) "dns:$p" }
        $script:gQueue = { param([string[]]$Answers) $q = New-Object 'System.Collections.Generic.Queue[string]'; foreach ($a in $Answers) { $q.Enqueue($a) }; return { param($Lines, $Prompt, $Risk) $q.Dequeue() }.GetNewClosure() }
    }
    It 'a refused CONFIRM gate reports the rows it dropped, by label' {
        $records = @(
            (New-WtApplyRecord -SectionKey 'Services' -EntryName 'Fax')
            (New-WtApplyRecord -SectionKey 'Packages' -EntryName 'Gone.App' -DisplayLabel 'Gone App - the risky one' -Risk 'ADVANCED')
        )
        $r = Invoke-WtApplyGates -Records $records -Sections $gSections -GetPackageCatalog $gPkg -ReadAnswer (& $gQueue @('nope')) -GetDnsDisclosure $gDns
        @($r.Dropped).Count | Should -Be 1
        $r.Dropped[0].Kind | Should -Be 'Confirm'
        @($r.Dropped[0].Labels) | Should -Be @('Gone App - the risky one')
    }
    It 'a refused YES gate on a package reports it too' {
        $records = @((New-WtApplyRecord -SectionKey 'Packages' -EntryName 'Gone.App' -DisplayLabel 'Gone App' -Risk 'ADVANCED'))
        $r = Invoke-WtApplyGates -Records $records -Sections $gSections -GetPackageCatalog $gPkg -ReadAnswer (& $gQueue @('CONFIRM', 'no')) -GetDnsDisclosure $gDns
        @($r.Dropped | ForEach-Object Kind) | Should -Be @('Yes')
        @($r.Dropped[0].Labels) | Should -Be @('Gone App')
    }
    It 'a refused DNS gate and an unchosen mechanism report their own reasons' {
        $dnsRec = @((New-WtApplyRecord -SectionKey 'DnsPreset' -EntryName 'Quad9' -DisplayLabel 'Quad9 DNS' -Risk 'CAUTION'))
        $r = Invoke-WtApplyGates -Records $dnsRec -Sections $gSections -GetPackageCatalog $gPkg -ReadAnswer { param($Lines, $Prompt, $Risk) '' } -GetDnsDisclosure $gDns
        $r.Dropped[0].Kind | Should -Be 'Yes'
        @($r.Dropped[0].Labels) | Should -Be @('Quad9 DNS')
        $blRec = @((New-WtApplyRecord -SectionKey 'Blocklist' -EntryName 'Spy' -DisplayLabel 'Spy list'))
        $r2 = Invoke-WtApplyGates -Records $blRec -Sections $gSections -GetPackageCatalog $gPkg -ReadAnswer { param($Lines, $Prompt, $Risk) 'z' } -GetDnsDisclosure $gDns
        $r2.Dropped[0].Kind | Should -Be 'Mechanism'
        @($r2.Dropped[0].Labels) | Should -Be @('Spy list')
    }
    It 'nothing is reported when nothing was refused' {
        $records = @((New-WtApplyRecord -SectionKey 'Services' -EntryName 'Fax'))
        $r = Invoke-WtApplyGates -Records $records -Sections $gSections -GetPackageCatalog $gPkg -ReadAnswer { throw 'must not prompt' } -GetDnsDisclosure $gDns
        @($r.Dropped).Count | Should -Be 0
        @(Get-WtGateRefusalLines -Dropped @($r.Dropped)).Count | Should -Be 0
    }
    It 'every gate panel tells the user case does not matter BEFORE they type' {
        $script:gShown = New-Object 'System.Collections.Generic.List[string]'
        $reader = { param($Lines, $Prompt, $Risk) foreach ($l in @($Lines)) { $script:gShown.Add([string]$l) }; 'no' }
        $records = @(
            (New-WtApplyRecord -SectionKey 'Packages' -EntryName 'Gone.App' -DisplayLabel 'Gone App' -Risk 'ADVANCED')
            (New-WtApplyRecord -SectionKey 'DnsPreset' -EntryName 'Quad9' -DisplayLabel 'Quad9' -Risk 'CAUTION')
        )
        Invoke-WtApplyGates -Records $records -Sections $gSections -GetPackageCatalog $gPkg -ReadAnswer $reader -GetDnsDisclosure $gDns | Out-Null
        @($script:gShown | Where-Object { $_ -eq (Get-WtGateWordHint -Kind 'Confirm') }).Count | Should -BeGreaterThan 0
        @($script:gShown | Where-Object { $_ -eq (Get-WtGateWordHint -Kind 'Yes') }).Count | Should -BeGreaterThan 0
    }
}

Describe 'Get-WtGateRefusalLines' {
    It 'names the word, lists the labels, then repeats the case hint once per word' {
        $lines = @(Get-WtGateRefusalLines -Dropped @(
            [PSCustomObject]@{ Kind = 'Confirm'; Labels = [string[]]@('Row one', 'Row two') }
            [PSCustomObject]@{ Kind = 'Yes'; Labels = [string[]]@('Row three') }
        ))
        $lines | Should -Contain ((Get-Translation 'GateRefusedTyped') -f (Get-WtTypedWord -Kind 'Confirm'))
        $lines | Should -Contain '  - Row one'
        $lines | Should -Contain '  - Row two'
        $lines | Should -Contain ((Get-Translation 'GateRefusedTyped') -f (Get-WtTypedWord -Kind 'Yes'))
        $lines | Should -Contain '  - Row three'
        @($lines | Where-Object { $_ -eq (Get-WtGateWordHint -Kind 'Confirm') }).Count | Should -Be 1
    }
    It 'the mechanism refusal reads differently - no word was asked for' {
        $lines = @(Get-WtGateRefusalLines -Dropped @([PSCustomObject]@{ Kind = 'Mechanism'; Labels = [string[]]@('Spy list') }))
        $lines[0] | Should -Be (Get-Translation 'GateRefusedMechanism')
        @($lines | Where-Object { $_ -like '*' + (Get-WtTypedWord -Kind 'Confirm') + '*' }).Count | Should -Be 0
    }
    It 'an entry that cost nothing is not reported' {
        @(Get-WtGateRefusalLines -Dropped @([PSCustomObject]@{ Kind = 'Confirm'; Labels = [string[]]@() })).Count | Should -Be 0
        @(Get-WtGateRefusalLines -Dropped @()).Count | Should -Be 0
        @(Get-WtGateRefusalLines).Count | Should -Be 0
    }
    It 'reads in Turkish on a Turkish screen, with both accepted words named' {
        $script:Language = 'TR'
        try {
            $lines = @(Get-WtGateRefusalLines -Dropped @([PSCustomObject]@{ Kind = 'Confirm'; Labels = [string[]]@('Bir satir') }))
            $lines[0] | Should -Match 'ONAYLA'
            $lines[0] | Should -Match 'uygulanmadi'
            ($lines -join ' ') | Should -Match 'CONFIRM'
            ($lines -join ' ') | Should -Match 'buyuk kucuk harf farketmez'
        }
        finally { $script:Language = 'EN' }
    }
    It 'the English screen does not say "Type CONFIRM (or CONFIRM)"' {
        Get-WtGateWordHint -Kind 'Confirm' | Should -Be ((Get-Translation 'GateWordHintOne') -f 'CONFIRM')
        Get-WtGateWordHint -Kind 'Yes' | Should -Be ((Get-Translation 'GateWordHintOne') -f 'YES')
    }
}