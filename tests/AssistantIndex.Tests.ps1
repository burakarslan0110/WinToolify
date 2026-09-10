#Requires -Modules Pester

<#
.SYNOPSIS
    The state-aware WinToolify tool index v2: every apply-section entry,
    every Actions/Info row, the screens and the winget catalog, with two
    languages, risk, removability and the assistant's runnable rule.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
    Reset-WtAssistantIndexCache
    $script:Index = Get-WtAssistantToolIndex
    $script:Sections = @(Get-WtApplySectionCatalog)

    function Search-WtAssistantTools {
        <#
        .SYNOPSIS
            Test-only convenience: Find-WtAssistantEntries' entries, capped
            at -Take (0 = all). Production code calls Find-WtAssistantEntries
            directly since it also needs Relaxed/MatchedWords for the
            search hint.
        #>
        param(
            [Parameter(Mandatory)][AllowEmptyString()][string]$Query,
            [AllowNull()][AllowEmptyString()][string]$Section = '',
            [AllowNull()][array]$Index = $null,
            [int]$Take = 12
        )
        $found = Find-WtAssistantEntries -Query $Query -Section $Section -Index $Index
        $ranked = @($found.Entries)
        if ($Take -gt 0) { $ranked = @($ranked | Select-Object -First $Take) }
        return @($ranked)
    }
}

Describe 'Get-WtAssistantToolIndex (v2)' {
    It 'derives exactly one Toggle per entry of every non-stage apply section' {
        foreach ($section in @($Sections | Where-Object { -not $_.StageOnly })) {
            $expected = @(& $section.GetCatalog).Count
            @($Index | Where-Object { $_.Kind -eq 'Toggle' -and $_.SectionKey -eq $section.Key }).Count | Should -Be $expected -Because $section.Key
        }
    }

    It 'lists the stage-only DNS preset and blocklist rows as non-runnable toggles and skips per-app permissions' {
        $dns = @($Index | Where-Object { $_.Kind -eq 'Toggle' -and $_.SectionKey -eq 'DnsPreset' })
        $dns.Count | Should -Be 6
        foreach ($e in $dns) { $e.Runnable | Should -BeFalse }
        @($Index | Where-Object { $_.SectionKey -eq 'Blocklist' }).Count | Should -Be 3
        @($Index | Where-Object { $_.SectionKey -eq 'PerAppPermissions' }).Count | Should -Be 0
    }

    It 'stage-only toggles name the System Settings screen, so a digit takes the user there instead of a dead-end apply' {
        foreach ($e in @($Index | Where-Object { $_.Kind -eq 'Toggle' -and $_.SectionKey -in 'DnsPreset', 'Blocklist' })) {
            $e.Screen | Should -Be 'SystemSettings' -Because $e.Id
        }
        (Get-WtAssistantIndexEntry -Id 'Services:DiagTrack' -Index $Index).Screen | Should -Be ''
    }

    It 'indexes the navigation-screen action rows: restore point and profile export/import are suggest-only (inline); VCRedist is a table row now (captured, runnable)' {
        $vc = Get-WtAssistantIndexEntry -Id 'InstallVCRedist' -Index $Index
        $vc.Kind | Should -Be 'Action'
        $vc.Runnable | Should -BeTrue
        $vc.Item.Data.Captured | Should -BeTrue
        $vc.PathEn | Should -Be 'Action Tools > Software'
        $vc.Section | Should -Be 'ActionGroupSoftware'
        $vc.LabelTr | Should -Not -BeNullOrEmpty
        foreach ($id in 'CreateRestorePoint', 'ExportProfile', 'ImportProfile') {
            $e = Get-WtAssistantIndexEntry -Id $id -Index $Index
            $e.Kind | Should -Be 'Action' -Because $id
            $e.Runnable | Should -BeFalse -Because $id
            $e.Item.Data.Action | Should -Not -BeNullOrEmpty -Because $id
        }
        (Get-WtAssistantIndexEntry -Id 'ExportProfile' -Index $Index).PathEn | Should -Be 'Main Menu > Config Profiles'
        Get-WtAssistantIndexEntry -Id 'Exit' -Index $Index | Should -BeNullOrEmpty
        Get-WtAssistantIndexEntry -Id 'MainAssistantRule' -Index $Index | Should -BeNullOrEmpty
        Get-WtAssistantIndexEntry -Id 'MainExitSpacer' -Index $Index | Should -BeNullOrEmpty
    }

    It 'has unique ids and SectionKey:Name ids for toggles' {
        $ids = @($Index | ForEach-Object Id)
        @($ids | Select-Object -Unique).Count | Should -Be $ids.Count
        $one = @($Index | Where-Object { $_.Kind -eq 'Toggle' -and $_.SectionKey -eq 'Services' })[0]
        $one.Id | Should -Be ('Services:' + $one.Entry.Name)
    }

    It 'carries both languages for every toggle - including the three AI privacy entries' {
        foreach ($e in @($Index | Where-Object Kind -eq 'Toggle')) {
            $e.LabelEn | Should -Not -BeNullOrEmpty -Because $e.Id
            $e.LabelTr | Should -Not -BeNullOrEmpty -Because $e.Id
        }
        $copilot = Get-WtAssistantIndexEntry -Id 'AiPrivacy:DisableCopilot' -Index $Index
        $copilot.LabelTr | Should -Not -Be $copilot.LabelEn
        $copilot.LabelTr | Should -Match 'Copilot'
    }

    It 'marks removability from the section TurnOff/IsRemovable pair' {
        (Get-WtAssistantIndexEntry -Id 'Telemetry:SetDiagnosticDataMinimal' -Index $Index).Removable | Should -BeTrue
        (Get-WtAssistantIndexEntry -Id 'Services:DiagTrack' -Index $Index).Removable | Should -BeFalse
    }

    It 'applies the runnable rule to Action/Info rows: captured and native yes; inline, power, Delete* and the never-run list no' {
        (Get-WtAssistantIndexEntry -Id 'RepairWindowsSystemFiles' -Index $Index).Runnable | Should -BeTrue
        (Get-WtAssistantIndexEntry -Id 'RepairStartMenu' -Index $Index).Runnable | Should -BeTrue
        (Get-WtAssistantIndexEntry -Id 'FreeMemory' -Index $Index).Runnable | Should -BeFalse
        (Get-WtAssistantIndexEntry -Id 'RestartComputer' -Index $Index).Runnable | Should -BeFalse
        (Get-WtAssistantIndexEntry -Id 'ClearPrintQueue' -Index $Index).Runnable | Should -BeFalse
        (Get-WtAssistantIndexEntry -Id 'DeleteOldRestorePoints' -Index $Index).Runnable | Should -BeFalse
        (Get-WtAssistantIndexEntry -Id 'RepairWindowsSystemFiles' -Index $Index).Kind | Should -Be 'Action'
        (Get-WtAssistantIndexEntry -Id 'StartupProgramsList' -Index $Index).Kind | Should -Be 'Info'
        (Get-WtAssistantIndexEntry -Id 'StartupProgramsList' -Index $Index).Item | Should -Not -BeNullOrEmpty
    }

    It 'lists the twelve screens - main-menu rows, Basic Tools and its two sub-menus, per-app permissions, Language - and the winget catalog as suggest-only entries' {
        $screens = @($Index | Where-Object Kind -eq 'Screen')
        $screens.Count | Should -Be 12
        foreach ($key in 'Services', 'SystemSettings', 'Privacy', 'Packages', 'WingetStore', 'Undo', 'Profiles', 'BasicTools', 'ActionTools', 'InfoTools', 'PerApp', 'Language') {
            $e = Get-WtAssistantIndexEntry -Id ('Screen:' + $key) -Index $Index
            $e | Should -Not -BeNullOrEmpty -Because $key
            $e.Screen | Should -Be $key
            $e.LabelTr | Should -Not -BeNullOrEmpty -Because $key
        }
        (Get-WtAssistantIndexEntry -Id 'Screen:ActionTools' -Index $Index).PathEn | Should -Be 'Main Menu > Basic Tools'
        (Get-WtAssistantIndexEntry -Id 'Screen:PerApp' -Index $Index).PathEn | Should -BeLike 'Main Menu > Privacy Settings > *'
        $chrome = Get-WtAssistantIndexEntry -Id 'Winget:Google.Chrome' -Index $Index
        $chrome.Kind | Should -Be 'Winget'
        $chrome.Runnable | Should -BeFalse
        $chrome.Screen | Should -Be 'WingetStore'
        $chrome.Haystack | Should -Match 'tarayici'
    }

    It 'every action, info and screen entry carries a description in both languages and search tags - a new row without a tag-table record fails here' {
        foreach ($e in @($Index | Where-Object { $_.Kind -in 'Action', 'Info', 'Screen' })) {
            $e.DescriptionEn | Should -Not -BeNullOrEmpty -Because $e.Id
            $e.DescriptionTr | Should -Not -BeNullOrEmpty -Because $e.Id
            $e.DescriptionTr | Should -Not -Be $e.DescriptionEn -Because $e.Id
            $e.Tags | Should -Not -BeNullOrEmpty -Because $e.Id
        }
    }

    It 'every toggle outside the app catalog has a consequence or a description in both languages' {
        foreach ($e in @($Index | Where-Object { $_.Kind -eq 'Toggle' -and $_.SectionKey -ne 'Packages' })) {
            ([string]$e.ConsequenceEn + [string]$e.DescriptionEn) | Should -Not -BeNullOrEmpty -Because $e.Id
            ([string]$e.ConsequenceTr + [string]$e.DescriptionTr) | Should -Not -BeNullOrEmpty -Because $e.Id
        }
    }

    It 'the tag table names only ids that exist - a renamed row must not leave an orphan record' {
        $ids = @{}
        foreach ($e in $Index) { $ids[[string]$e.Id] = $true }
        foreach ($key in @((Get-WtAssistantSearchTagTable).Keys)) { $ids.ContainsKey([string]$key) | Should -BeTrue -Because $key }
    }

    It 'descriptions and tags are searchable: symptom and synonym queries in Turkish reach the right entry' {
        $cases = @(
            @{ Q = 'bilgisayarim yavas'; Id = 'FreeMemory' }
            @{ Q = 'internet yok'; Id = 'ResetTcpIpStack' }
            @{ Q = 'ses yok'; Id = 'RestartAudioServices' }
            @{ Q = 'wifi sifresi'; Id = 'ShowWifiPassword' }
            @{ Q = 'guvenli mod'; Id = 'RestartInSafeMode' }
            @{ Q = 'oyun modu'; Id = 'GamingTweaks:DisableFullscreenOptimizations' }
            @{ Q = 'ram bosalt'; Id = 'FreeMemory' }
            @{ Q = 'cift dosya'; Id = 'DuplicateFinder' }
            @{ Q = 'hosts sifirla'; Id = 'ResetHostsFile' }
            @{ Q = 'vcredist'; Id = 'InstallVCRedist' }
            @{ Q = 'dil degistir'; Id = 'Screen:Language' }
            @{ Q = 'geri yukleme noktasi olustur'; Id = 'CreateRestorePoint' }
            @{ Q = 'profil disa aktar'; Id = 'ExportProfile' }
            @{ Q = 'yazici sorunu'; Id = 'RestartPrinter' }
            @{ Q = 'uygulama izinleri kamera'; Id = 'Screen:PerApp' }
            @{ Q = 'donmus program'; Id = 'CloseNotRespondingApps' }
            @{ Q = 'mavi ekran'; Id = 'BlueScreenHistory' }
            @{ Q = 'reklam engelle'; Id = 'DnsPreset:AdGuard (Ads & Trackers)' }
        )
        foreach ($c in $cases) {
            $ids = @(Search-WtAssistantTools -Query $c.Q -Index $Index -Take 5 | ForEach-Object Id)
            $ids | Should -Contain $c.Id -Because $c.Q
        }
    }

    It 'the search row is id | label | state | risk; what appears only for three or fewer matches or on detail' {
        $entry = Get-WtAssistantIndexEntry -Id 'Services:DiagTrack' -Index $Index
        $row = ConvertTo-WtAssistantSearchRow -Entry $entry -State 'Applied'
        @($row.PSObject.Properties.Name) | Should -Be @('id', 'label', 'state', 'risk')
        $row.state | Should -Be 'on'
        $row.risk | Should -Be 'S'
        $withWhat = ConvertTo-WtAssistantSearchRow -Entry $entry -State 'NotPresent' -What 'x'
        @($withWhat.PSObject.Properties.Name) | Should -Be @('id', 'label', 'state', 'risk', 'what')
        $withWhat.state | Should -Be 'n/a'
        (ConvertTo-WtAssistantSearchRow -Entry (Get-WtAssistantIndexEntry -Id 'Screen:Privacy' -Index $Index) -State '').state | Should -Be '-'
        ConvertTo-WtAssistantRiskCode -Risk 'ADVANCED' | Should -Be 'A'
        ConvertTo-WtAssistantRiskCode -Risk '' | Should -Be '-'
        (Get-WtAssistantEntryWhat -Entry (Get-WtAssistantIndexEntry -Id 'HardeningOffice:HD_F002' -Index $Index) -Max 30).Length | Should -Be 30
    }

    It 'folds the haystack and tokenizes it' {
        $e = Get-WtAssistantIndexEntry -Id 'Services:DiagTrack' -Index $Index
        $e.Haystack | Should -Be $e.Haystack.ToLowerInvariant()
        @($e.Tokens) | Should -Contain 'diagtrack'
    }

    It 'caches the built index and rebuilds on -NoCache' {
        $a = Get-WtAssistantToolIndex
        $b = Get-WtAssistantToolIndex
        [object]::ReferenceEquals($a, $b) | Should -BeTrue
        $c = Get-WtAssistantToolIndex -NoCache
        [object]::ReferenceEquals($a, $c) | Should -BeFalse
    }

    It 'Packages labels drop the "<Name> - " prefix in both languages (the id carries the name); Services keep theirs' {
        $help = Get-WtAssistantIndexEntry -Id 'Packages:Microsoft.GetHelp' -Index $Index
        $help.LabelEn | Should -Be 'Get Help'
        $help.LabelTr | Should -Be 'Yardim Al'
        foreach ($e in @($Index | Where-Object { $_.SectionKey -eq 'Packages' })) {
            $e.LabelEn | Should -Not -Match ('^' + [regex]::Escape([string]$e.Entry.Name) + ' - ') -Because $e.Id
            $e.LabelEn | Should -Not -BeNullOrEmpty -Because $e.Id
        }
        (Get-WtAssistantIndexEntry -Id 'Services:DiagTrack' -Index $Index).LabelEn | Should -Match '^DiagTrack - '
        Remove-WtAssistantLabelPrefix -Label 'X - Y' -Prefix 'X - ' | Should -Be 'Y'
        Remove-WtAssistantLabelPrefix -Label 'X - ' -Prefix 'X - ' | Should -Be 'X - '
        Remove-WtAssistantLabelPrefix -Label 'Other' -Prefix 'X - ' | Should -Be 'Other'
    }

    It 'DnsPreset and Blocklist entries carry a label beyond the name, a risk and a tag record' {
        $tags = Get-WtAssistantSearchTagTable
        foreach ($e in @($Index | Where-Object { $_.SectionKey -in 'DnsPreset', 'Blocklist' })) {
            $e.LabelEn | Should -Not -Be ([string]$e.Entry.Name) -Because $e.Id
            $e.Risk | Should -BeIn @('SAFE', 'CAUTION', 'ADVANCED') -Because $e.Id
            $tags.ContainsKey([string]$e.Id) | Should -BeTrue -Because $e.Id
            $e.DescriptionEn | Should -Not -BeNullOrEmpty -Because $e.Id
        }
        $cf = Get-WtAssistantIndexEntry -Id 'DnsPreset:Cloudflare' -Index $Index
        $cf.LabelEn | Should -Be 'Cloudflare DNS (1.1.1.1, 1.0.0.1)'
        $cf.LabelTr | Should -Be 'Cloudflare DNS (1.1.1.1, 1.0.0.1)'
        $cf.Risk | Should -Be 'CAUTION'
        (Get-WtDnsPresetCatalog | Where-Object Name -eq 'Quad9').Risk | Should -Be 'CAUTION'
        $update = Get-WtAssistantIndexEntry -Id 'Blocklist:Update' -Index $Index
        $update.LabelEn | Should -Be 'Update - Windows Update hosts'
        $update.LabelTr | Should -Be 'Update - Windows Update sunuculari'
        $update.Risk | Should -Be 'CAUTION'
        (ConvertTo-WtAssistantSearchRow -Entry $cf -State '').risk | Should -Be 'C'
    }

    It 'every Information row carries a risk in the index: an unrisked row reads SAFE, an explicit CAUTION stays, Action rows are untouched' {
        foreach ($e in @($Index | Where-Object { $_.Kind -eq 'Info' })) { $e.Risk | Should -Not -BeNullOrEmpty -Because $e.Id }
        (Get-WtAssistantIndexEntry -Id 'BlueScreenHistory' -Index $Index).Risk | Should -Be 'SAFE'
        (Get-WtAssistantIndexEntry -Id 'ShowWifiPassword' -Index $Index).Risk | Should -Be 'CAUTION'
        (Get-WtAssistantIndexEntry -Id 'FreeMemory' -Index $Index).Risk | Should -Be ''
        (ConvertTo-WtAssistantSearchRow -Entry (Get-WtAssistantIndexEntry -Id 'BlueScreenHistory' -Index $Index) -State '').risk | Should -Be 'S'
    }
}

Describe 'Get-WtAssistantCatalogText' {
    It 'reads the requested language from the key, falls back to the literal, then to empty' {
        $script:Translations['EN']['CatAssistantIndexProbeLabel'] = 'Probe'
        $script:Translations['TR']['CatAssistantIndexProbeLabel'] = 'Sonda'
        $keyed = [PSCustomObject]@{ Name = 'X'; LabelKey = 'CatAssistantIndexProbeLabel'; DisplayLabel = 'Probe' }
        Get-WtAssistantCatalogText -Entry $keyed -KeyProperty 'LabelKey' -TextProperty 'DisplayLabel' -Language 'TR' | Should -Be 'Sonda'
        $literal = [PSCustomObject]@{ Name = 'Y'; DisplayLabel = 'Literal' }
        Get-WtAssistantCatalogText -Entry $literal -KeyProperty 'LabelKey' -TextProperty 'DisplayLabel' -Language 'TR' | Should -Be 'Literal'
        $bare = [PSCustomObject]@{ Name = 'Z' }
        Get-WtAssistantCatalogText -Entry $bare -KeyProperty 'LabelKey' -TextProperty 'DisplayLabel' -Language 'EN' | Should -Be ''
        $script:Translations['EN'].Remove('CatAssistantIndexProbeLabel')
        $script:Translations['TR'].Remove('CatAssistantIndexProbeLabel')
    }
}

Describe 'Search-WtAssistantTools (v2)' {
    BeforeAll {
        function New-WtIdxProbe { param([string]$Id, [string]$Kind = 'Toggle', [string]$SectionKey = 'Telemetry', [string]$LabelEn = '', [string]$LabelTr = '', [string]$ConsequenceEn = '', [bool]$Runnable = $true, $Entry = $null)
            New-WtAssistantIndexEntry -Id $Id -Kind $Kind -SectionKey $SectionKey -Section $SectionKey -LabelEn $LabelEn -LabelTr $LabelTr -ConsequenceEn $ConsequenceEn -Runnable $Runnable -Entry $Entry
        }
        $script:Probe = @(
            (New-WtIdxProbe -Id 'Telemetry:Diag' -LabelEn 'Set diagnostic data to minimum' -LabelTr 'Tanilama verisini en aza indir' -ConsequenceEn 'less telemetry leaves the machine')
            (New-WtIdxProbe -Id 'Services:DiagTrack' -SectionKey 'Services' -LabelEn 'DiagTrack - Connected User Experiences and Telemetry' -LabelTr 'DiagTrack - Bagli Kullanici Deneyimleri ve Telemetri hizmetini kapat')
            (New-WtIdxProbe -Id 'HardeningEdge:E1' -SectionKey 'HardeningEdge' -LabelEn 'Disable Edge spell check' -LabelTr 'Edge yazim denetimini kapat')
            (New-WtIdxProbe -Id 'Winget:X.Y' -Kind 'Winget' -SectionKey '' -LabelEn 'Foo' -LabelTr 'Foo' -Runnable $false)
        )
    }

    It 'finds a Turkish suffixed word through the 5-char prefix rule and scores exact hits above prefix hits' {
        $q = 'telemetriyi kapat'
        $hits = @(Search-WtAssistantTools -Query $q -Index $Probe)
        @($hits | ForEach-Object Id) | Should -Contain 'Services:DiagTrack'
        @($hits | ForEach-Object Id) | Should -Not -Contain 'HardeningEdge:E1'
    }

    It 'a two-word query needs both words; when only one word is known it falls back to OR and says so' {
        $both = Find-WtAssistantEntries -Query 'wifi' -Index $Index
        @($both.Entries).Count | Should -BeGreaterThan 0
        $both.Relaxed | Should -BeFalse
        $relaxed = Find-WtAssistantEntries -Query 'wifi cekmiyor' -Index $Index
        @($relaxed.Entries).Count | Should -BeGreaterThan 0
        $relaxed.Relaxed | Should -BeTrue
        $relaxed.MatchedWords | Should -Be @('wifi')
        $none = Find-WtAssistantEntries -Query 'zzqx yyqx' -Index $Index
        @($none.Entries).Count | Should -Be 0
        $none.Relaxed | Should -BeFalse
    }

    It 'searches consequence text and the id' {
        @(Search-WtAssistantTools -Query 'leaves machine' -Index $Probe | ForEach-Object Id) | Should -Contain 'Telemetry:Diag'
        @(Search-WtAssistantTools -Query 'DiagTrack' -Index $Probe | ForEach-Object Id) | Should -Be @('Services:DiagTrack')
    }

    It 'filters by section (ordinal, case-insensitive) and caps at -Take' {
        @(Search-WtAssistantTools -Query 'telemetri' -Section 'services' -Index $Probe | ForEach-Object Id) | Should -Be @('Services:DiagTrack')
        @(Search-WtAssistantTools -Query 'diag' -Index $Probe -Take 1).Count | Should -Be 1
        @(Search-WtAssistantTools -Query 'onar' -Section 'Tools' -Index $Index | Where-Object { $_.Kind -ne 'Action' -and $_.Kind -ne 'Info' }).Count | Should -Be 0
        @(Search-WtAssistantTools -Query 'gizlilik' -Section 'Screens' -Index $Index | Where-Object Kind -ne 'Screen').Count | Should -Be 0
        @(Search-WtAssistantTools -Query 'chrome' -Section 'Winget' -Index $Index | Where-Object Kind -ne 'Winget').Count | Should -Be 0
        @(Search-WtAssistantTools -Query 'telemetri' -Section 'Gizlilik' -Index $Index).Count | Should -Be 0
    }

    It 'returns nothing for an empty or one-letter query' {
        @(Search-WtAssistantTools -Query '' -Index $Probe).Count | Should -Be 0
        @(Search-WtAssistantTools -Query 'a' -Index $Probe).Count | Should -Be 0
    }

    It 'token hit: exact 2, prefix either way 1 (only from 5 chars), else 0' {
        Get-WtAssistantTokenHit -Tokens @('telemetri', 'kapat') -Word 'kapat' | Should -Be 2
        Get-WtAssistantTokenHit -Tokens @('telemetri') -Word 'telemetriyi' | Should -Be 1
        Get-WtAssistantTokenHit -Tokens @('telemetriyi') -Word 'telemetri' | Should -Be 1
        Get-WtAssistantTokenHit -Tokens @('kapatma') -Word 'kapa' | Should -Be 0
        Get-WtAssistantTokenHit -Tokens @('edge') -Word 'telemetri' | Should -Be 0
    }

    It 'weights label and tag hits over description hits and description over path: the clipboard rows no longer lead a telemetry query' {
        $top = @(Search-WtAssistantTools -Query 'telemetri' -Index $Index -Take 8 | ForEach-Object Id)
        $top | Should -Contain 'Services:DiagTrack'
        @($top | Where-Object { $_ -like 'Telemetry:*' }).Count | Should -BeGreaterThan 0
        $top | Should -Not -Contain 'HardeningPrivacy:HD_A004'
    }

    It 'generic verbs are stop words: they neither count toward the two-word rule nor score' {
        (Get-WtAssistantSearchStopWords) | Should -Contain 'kapat'
        $r = Find-WtAssistantEntries -Query 'telemetri kapat' -Index $Index
        $r.Relaxed | Should -BeFalse
        $r.EffectiveWords | Should -Be @('telemetri')
        @($r.Entries | Select-Object -First 8 | Where-Object { $_.Id -like 'Telemetry:*' }).Count | Should -BeGreaterThan 0
        (Find-WtAssistantEntries -Query 'kapat' -Index $Index).EffectiveWords | Should -Be @('kapat')
    }

    It 'rare words outrank common ones (idf), ties prefer toggles and tools over screens and winget' {
        $idf = Get-WtAssistantIndexIdf -Index $Index
        $idf['diagtrack'] | Should -BeGreaterThan $idf['windows']
        [object]::ReferenceEquals((Get-WtAssistantIndexIdf -Index $Index), $idf) | Should -BeTrue
        $ranked = @(Search-WtAssistantTools -Query 'gizlilik' -Index $Index -Take 0)
        $firstScreen = [array]::IndexOf(@($ranked | ForEach-Object Kind), 'Screen')
        $lastToggle = [array]::LastIndexOf(@($ranked | ForEach-Object Kind), 'Toggle')
        if ($firstScreen -ge 0 -and $lastToggle -ge 0) {
            $screenScore = (Get-WtAssistantEntryScore -Entry $ranked[$firstScreen] -Words @('gizlilik') -Idf $idf).Score
            foreach ($e in @($ranked | Where-Object { $_.Kind -eq 'Toggle' -and (Get-WtAssistantEntryScore -Entry $_ -Words @('gizlilik') -Idf $idf).Score -eq $screenScore })) {
                [array]::IndexOf(@($ranked | ForEach-Object Id), $e.Id) | Should -BeLessThan $firstScreen
            }
        }
    }

    It 'a winget app is a candidate only when a query word names it or its tags exactly - a prefix hit is not enough' {
        @(Search-WtAssistantTools -Query 'chrome' -Index $Index | Where-Object Id -eq 'Winget:Google.Chrome').Count | Should -Be 1
        $tiny = @(
            (New-WtAssistantIndexEntry -Id 'Winget:Acme.Barbaz' -Kind 'Winget' -LabelEn 'Barbaz Tool' -LabelTr 'Barbaz Tool' -ExtraSearchText 'barbaz')
            (New-WtAssistantIndexEntry -Id 'Probe:Toggle' -Kind 'Toggle' -SectionKey 'Probe' -LabelEn 'Some toggle' -LabelTr 'Bir ayar' -ConsequenceEn 'affects barbazzy things' -ConsequenceTr 'barbazzy seyleri etkiler')
        )
        @(Search-WtAssistantTools -Query 'barbazzy' -Index $tiny | ForEach-Object Id) | Should -Be @('Probe:Toggle')
        @(Search-WtAssistantTools -Query 'barbaz' -Index $tiny | ForEach-Object Id) | Should -Contain 'Winget:Acme.Barbaz'
    }

    It 'the Turkish symptom queries that used to return nothing now return rows' {
        foreach ($q in @('wifi cekmiyor', 'guncelleme yapamiyorum', 'yazicim gorunmuyor', 'bilgisayarim yavas')) {
            @(Search-WtAssistantTools -Query $q -Index $Index).Count | Should -BeGreaterThan 0 -Because $q
        }
    }
}

Describe 'state on match' {
    BeforeAll {
        $script:FakeSections = @(
            [PSCustomObject]@{ Key = 'Telemetry'; TitleKey = 'Telemetry'; GetCatalog = { @() }; GetState = { param($Entry) if ($Entry.Name -eq 'On') { 'Applied' } else { 'NotApplied' } }; TurnOff = $null; IsRemovable = $null }
            [PSCustomObject]@{ Key = 'Broken'; TitleKey = 'Telemetry'; GetCatalog = { @() }; GetState = { param($Entry) throw 'no' }; TurnOff = $null; IsRemovable = $null }
        )
        $script:StateIndex = @(
            (New-WtAssistantIndexEntry -Id 'Telemetry:On' -Kind 'Toggle' -SectionKey 'Telemetry' -Section 'Telemetry' -LabelEn 'Telemetry on thing' -LabelTr 'x' -Runnable $true -Entry ([PSCustomObject]@{ Name = 'On' }))
            (New-WtAssistantIndexEntry -Id 'Telemetry:Off' -Kind 'Toggle' -SectionKey 'Telemetry' -Section 'Telemetry' -LabelEn 'Telemetry off thing' -LabelTr 'x' -Runnable $true -Entry ([PSCustomObject]@{ Name = 'Off' }))
            (New-WtAssistantIndexEntry -Id 'Broken:Z' -Kind 'Toggle' -SectionKey 'Broken' -Section 'Telemetry' -LabelEn 'Telemetry broken thing' -LabelTr 'x' -Runnable $true -Entry ([PSCustomObject]@{ Name = 'Z' }))
            (New-WtAssistantIndexEntry -Id 'RepairX' -Kind 'Action' -LabelEn 'Telemetry repair' -LabelTr 'x' -Runnable $true)
        )
    }

    It 'reads Applied/NotApplied through the section GetState, Unknown when it throws, empty for non-toggles' {
        Get-WtAssistantEntryState -Entry $StateIndex[0] -Sections $FakeSections | Should -Be 'Applied'
        Get-WtAssistantEntryState -Entry $StateIndex[1] -Sections $FakeSections | Should -Be 'NotApplied'
        Get-WtAssistantEntryState -Entry $StateIndex[2] -Sections $FakeSections | Should -Be 'Unknown'
        Get-WtAssistantEntryState -Entry $StateIndex[3] -Sections $FakeSections | Should -Be ''
    }

    It 'the search result is rows with state codes, a more: facet line past 8 hits, and the what column for a narrow query' {
        $r = Get-WtAssistantSearchResult -Query 'telemetri' -Index $Index -Sections $FakeSections
        @($r['rows']).Count | Should -Be 8
        @($r['rows'] | ForEach-Object { $_.PSObject.Properties.Name }) | Should -Not -Contain 'what'
        $r['more'] | Should -Match '^\d+ \(.+\) - narrow with section=$'
        $r.Contains('hint') | Should -BeFalse
        $text = ConvertTo-WtAssistantToolText -Value $r
        $text.Length | Should -BeLessOrEqual 1000
        @($text -split "`n")[1] | Should -Be '  id | label | state | risk'
        @($text -split "`n" | Where-Object { $_.StartsWith('more: ') }).Count | Should -Be 1
        $text | Should -Not -Match 'more: more:'
        $narrow = Get-WtAssistantSearchResult -Query 'diagtrack' -Index $Index -Sections $FakeSections
        @($narrow['rows'] | ForEach-Object { $_.PSObject.Properties.Name }) | Should -Contain 'what'
        $detail = Get-WtAssistantSearchResult -Query 'telemetri' -Detail $true -Index $Index -Sections $FakeSections
        @($detail['rows']).Count | Should -Be 5
        @($detail['rows'][0].PSObject.Properties.Name) | Should -Contain 'what'
        $empty = Get-WtAssistantSearchResult -Query 'zzqx' -Index $Index -Sections $FakeSections
        $empty['rows'] | Should -Be 'none'
        $empty['hint'] | Should -Not -BeNullOrEmpty
    }

    It 'the more: line counts every ranked match beyond the eight rows, over the real index' {
        $r = Get-WtAssistantSearchResult -Query 'kapat gizlilik' -Index $Index -Sections $Sections
        @($r['rows']).Count | Should -Be 8
        $r['more'] | Should -Match '^\d+ \('
    }

    It 'the status tool counts applied entries per section' {
        $s = Get-WtAssistantWintoolifyStatus -Index $StateIndex -Sections $FakeSections
        $telemetry = @($s.sections | Where-Object section -eq 'Telemetry')[0]
        $telemetry.applied | Should -Be 1
        $telemetry.total | Should -Be 2
        $s.total | Should -Be 3
        $s.applied_total | Should -Be 1
    }
}

Describe 'Resolve-WtAssistantSuggestions' {
    It 'keeps valid ids in order, dedupes, caps at 9 and names the invalid ones' {
        $index = @(
            (New-WtAssistantIndexEntry -Id 'A' -Kind 'Action' -LabelEn 'a' -LabelTr 'a')
            (New-WtAssistantIndexEntry -Id 'B' -Kind 'Action' -LabelEn 'b' -LabelTr 'b')
        )
        $r = Resolve-WtAssistantSuggestions -Ids @('B', 'yok', 'A', 'B') -Index $index
        @($r.Valid | ForEach-Object Id) | Should -Be @('B', 'A')
        @($r.Invalid) | Should -Be @('yok')
    }

    It 'caps at nine suggestions - the digit shortcuts stop at 9' {
        $index = @(1..12 | ForEach-Object { New-WtAssistantIndexEntry -Id "T$_" -Kind 'Action' -LabelEn 'x' -LabelTr 'x' })
        $r = Resolve-WtAssistantSuggestions -Ids @($index | ForEach-Object Id) -Index $index
        @($r.Valid).Count | Should -Be 9
    }
}

Describe 'twins' {
    BeforeAll {
        function New-WtTwinProbe { param([string]$Id, [string]$SectionKey, [string]$LabelEn, [string]$Twin = '', [string]$DescriptionEn = '')
            New-WtAssistantIndexEntry -Id $Id -Kind 'Toggle' -SectionKey $SectionKey -Section $SectionKey -LabelEn $LabelEn -LabelTr $LabelEn -DescriptionEn $DescriptionEn -DescriptionTr $DescriptionEn -Runnable $true -Twin $Twin -Entry ([PSCustomObject]@{ Name = $Id })
        }
        $script:TwinProbe = @(
            (New-WtTwinProbe -Id 'CapabilityDefaults:webcam' -SectionKey 'CapabilityDefaults' -LabelEn 'Camera' -DescriptionEn 'Denies apps the camera by default.')
            (New-WtTwinProbe -Id 'HardeningAppPermissions:HD_P034' -SectionKey 'HardeningAppPermissions' -LabelEn 'Disable app access to your camera' -Twin 'CapabilityDefaults:webcam')
            (New-WtTwinProbe -Id 'Other:X' -SectionKey 'Other' -LabelEn 'Camera driver')
        )
    }

    It 'the twin table maps only to ids that exist; every twin key present on this OS is a hardening row carrying its Twin; a preferred row carries none' {
        $table = Get-WtAssistantTwinTable
        $table.Count | Should -Be 28
        $byId = @{}
        foreach ($e in $Index) { $byId[[string]$e.Id] = $e }
        foreach ($key in @($table.Keys)) {
            $byId.ContainsKey([string]$table[$key]) | Should -BeTrue -Because ('preferred ' + $table[$key])
            ([string]$key).StartsWith('Hardening', [System.StringComparison]::Ordinal) | Should -BeTrue -Because $key
            if ($byId.ContainsKey([string]$key)) { $byId[[string]$key].Twin | Should -Be ([string]$table[$key]) -Because $key }
        }
        (Get-WtAssistantIndexEntry -Id 'CapabilityDefaults:webcam' -Index $Index).Twin | Should -Be ''
        (Get-WtAssistantIndexEntry -Id 'HardeningAppPermissions:HD_P034' -Index $Index).Twin | Should -Be 'CapabilityDefaults:webcam'
        (Get-WtAssistantIndexEntry -Id 'HardeningPrivacy:HD_P005' -Index $Index).Twin | Should -Be 'ActivityAdvertising:DisableAdvertisingId'
    }

    It 'search folds a twin pair into the preferred row and notes the fold in what; a section filter that shows only the dropped side keeps it' {
        $fold = Get-WtAssistantFoldedHits -Entries $TwinProbe
        @($fold.Entries | ForEach-Object Id) | Should -Be @('CapabilityDefaults:webcam', 'Other:X')
        $fold.Folded['CapabilityDefaults:webcam'] | Should -Be 'HardeningAppPermissions:HD_P034'
        $r = Get-WtAssistantSearchResult -Query 'camera' -Index $TwinProbe -Sections @()
        $ids = @($r['rows'] | ForEach-Object id)
        $ids | Should -Contain 'CapabilityDefaults:webcam'
        $ids | Should -Not -Contain 'HardeningAppPermissions:HD_P034'
        @($r['rows'] | Where-Object id -eq 'CapabilityDefaults:webcam')[0].what | Should -Match '\(twin: HardeningAppPermissions:HD_P034\)$'
        $narrow = Get-WtAssistantSearchResult -Query 'camera' -Section 'HardeningAppPermissions' -Index $TwinProbe -Sections @()
        @($narrow['rows'] | ForEach-Object id) | Should -Be @('HardeningAppPermissions:HD_P034')
        $table = Get-WtAssistantTwinTable
        foreach ($q in 'kamera', 'reklam kimligi', 'konum') {
            $live = @((Get-WtAssistantSearchResult -Query $q -Index $Index -Sections @())['rows'] | ForEach-Object id)
            foreach ($id in $live) { if ($table.ContainsKey($id)) { $live | Should -Not -Contain $table[$id] -Because ($q + ' / ' + $id) } }
        }
    }

    It 'the twin fold keeps the BETTER rank of the pair regardless of scan order' {
        $reversed = Get-WtAssistantFoldedHits -Entries @($TwinProbe[1], $TwinProbe[2], $TwinProbe[0])
        @($reversed.Entries | ForEach-Object Id) | Should -Be @('CapabilityDefaults:webcam', 'Other:X')
        $reversed.Folded['CapabilityDefaults:webcam'] | Should -Be 'HardeningAppPermissions:HD_P034'
        $original = Get-WtAssistantFoldedHits -Entries $TwinProbe
        @($original.Entries | ForEach-Object Id) | Should -Be @('CapabilityDefaults:webcam', 'Other:X')
        $original.Folded['CapabilityDefaults:webcam'] | Should -Be 'HardeningAppPermissions:HD_P034'
    }

    It 'the (twin: id) note stays inside the 120-char what cap even when the description is long' {
        $longEn = ('x' * 200)
        $preferred = New-WtAssistantIndexEntry -Id 'CapabilityDefaults:webcam' -Kind 'Toggle' -SectionKey 'CapabilityDefaults' -Section 'CapabilityDefaults' -LabelEn 'Camera' -LabelTr 'Camera' -DescriptionEn $longEn -DescriptionTr $longEn -Runnable $true -Entry ([PSCustomObject]@{ Name = 'CapabilityDefaults:webcam' })
        $twin = New-WtAssistantIndexEntry -Id 'HardeningAppPermissions:HD_P034' -Kind 'Toggle' -SectionKey 'HardeningAppPermissions' -Section 'HardeningAppPermissions' -LabelEn 'Disable app access to your camera' -LabelTr 'Disable app access to your camera' -Twin 'CapabilityDefaults:webcam' -Runnable $true -Entry ([PSCustomObject]@{ Name = 'HardeningAppPermissions:HD_P034' })
        $probe = @($preferred, $twin)
        $r = Get-WtAssistantSearchResult -Query 'camera' -Index $probe -Sections @()
        $row = @($r['rows'] | Where-Object id -eq 'CapabilityDefaults:webcam')[0]
        $row.what.Length | Should -BeLessOrEqual 120
        $row.what | Should -Match '\(twin: HardeningAppPermissions:HD_P034\)$'
    }

    It 'a suggestion list naming both twins keeps only the preferred one; the dropped side alone is still valid' {
        $smallIndex = @(
            (New-WtAssistantIndexEntry -Id 'A' -Kind 'Action' -LabelEn 'a' -LabelTr 'a')
            (New-WtAssistantIndexEntry -Id 'B' -Kind 'Action' -LabelEn 'b' -LabelTr 'b' -Twin 'A')
            (New-WtAssistantIndexEntry -Id 'C' -Kind 'Action' -LabelEn 'c' -LabelTr 'c')
        )
        @((Resolve-WtAssistantSuggestions -Ids @('B', 'C', 'A') -Index $smallIndex).Valid | ForEach-Object Id) | Should -Be @('C', 'A')
        @((Resolve-WtAssistantSuggestions -Ids @('B', 'C') -Index $smallIndex).Valid | ForEach-Object Id) | Should -Be @('B', 'C')
        @((Resolve-WtAssistantSuggestions -Ids @('HardeningAppPermissions:HD_P034', 'CapabilityDefaults:webcam') -Index $Index).Valid | ForEach-Object Id) | Should -Be @('CapabilityDefaults:webcam')
    }
}
