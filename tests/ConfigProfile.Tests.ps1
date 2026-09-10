#Requires -Modules Pester

<#
.SYNOPSIS
    Config Profiles bundle coverage: the profile section table, the live-
    state snapshot that becomes a profile, profile file save / list / read,
    the import plan (diff) and the guarded apply orchestration - every
    state and apply delegate is a fake here, since none of the real ones
    can run outside Windows.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath

    function script:New-FakeSections {
        $script:StateCalls = New-Object System.Collections.Generic.List[string]
        $script:ApplyCalls = @{}
        $script:ProgressCalls = New-Object System.Collections.Generic.List[string]

        $alpha = [PSCustomObject]@{
            Key              = 'Alpha'
            TitleKey         = 'Alpha'
            RestartsExplorer = $false
            GetCatalog       = {
                @(
                    [PSCustomObject]@{ Name = 'a1'; Risk = 'SAFE'; Consequence = $null }
                    [PSCustomObject]@{ Name = 'a2'; Risk = 'ADVANCED'; Consequence = 'bad' }
                    [PSCustomObject]@{ Name = 'a3'; Risk = 'SAFE'; Consequence = $null }
                )
            }
            GetState         = {
                param($Entry)
                $script:StateCalls.Add("Alpha:$($Entry.Name)")
                switch ($Entry.Name) {
                    'a1' { 'Applied' }
                    'a2' { 'NotApplied' }
                    'a3' { 'NotPresent' }
                }
            }
            Apply            = {
                param([string[]]$Names)
                $script:ApplyCalls['Alpha'] = @($Names)
                [PSCustomObject]@{ Aborted = $false; Results = @([PSCustomObject]@{ Item = [PSCustomObject]@{ Name = 'a2' }; Applied = $true; Error = $null }) }
            }
        }

        $beta = [PSCustomObject]@{
            Key              = 'Beta'
            TitleKey         = 'Beta'
            RestartsExplorer = $true
            GetCatalog       = {
                @(
                    [PSCustomObject]@{ Name = 'b1'; Risk = 'SAFE'; Consequence = $null }
                    [PSCustomObject]@{ Name = 'b2'; Risk = 'SAFE'; Consequence = $null }
                )
            }
            GetState         = {
                param($Entry)
                $script:StateCalls.Add("Beta:$($Entry.Name)")
                'NotApplied'
            }
            Apply            = {
                param([string[]]$Names)
                $script:ApplyCalls['Beta'] = @($Names)
                [PSCustomObject]@{ Aborted = $false; Results = @() }
            }
        }

        return @($alpha, $beta)
    }
}

Describe 'Get-WtProfileSectionCatalog' {
    It 'has exactly the twenty-one section keys in the expected order' {
        $sections = @(Get-WtProfileSectionCatalog)
        $sections.Key | Should -Be @('Services', 'Packages', 'AiPrivacy', 'CapabilityDefaults', 'Telemetry', 'ActivityAdvertising', 'SearchSuggestions', 'HardeningPrivacy', 'HardeningAppPermissions', 'HardeningAi', 'HardeningSearchUi', 'HardeningEdge', 'HardeningOffice', 'HardeningUpdate', 'HardeningSecurity', 'PowerPlan', 'GamingTweaks', 'Firewall', 'FastStartup', 'ContextMenu', 'ExplorerView')
    }

    It 'points the three telemetry sections at their own catalogs and translation titles' {
        $expected = @(
            @{ Key = 'Telemetry'; TitleKey = 'Telemetry'; First = 'SetDiagnosticDataMinimal'; Count = 7 }
            @{ Key = 'ActivityAdvertising'; TitleKey = 'ActivityAndAdvertising'; First = 'DisableActivityHistory'; Count = 4 }
            @{ Key = 'SearchSuggestions'; TitleKey = 'SearchAndSuggestions'; First = 'DisableCortana'; Count = 6 }
        )
        $sections = @(Get-WtProfileSectionCatalog)
        foreach ($exp in $expected) {
            $section = $sections | Where-Object Key -eq $exp.Key
            $section | Should -Not -BeNullOrEmpty -Because "$($exp.Key) section must exist"
            $section.TitleKey | Should -Be $exp.TitleKey
            $section.RestartsExplorer | Should -BeFalse -Because "$($exp.Key) changes nothing Explorer renders"
            $catalog = @(& $section.GetCatalog)
            $catalog.Count | Should -Be $exp.Count -Because "$($exp.Key) catalog size"
            $catalog[0].Name | Should -Be $exp.First
        }
    }

    It 'answers with a known state for a telemetry entry through the shared registry state reader' {
        $section = @(Get-WtProfileSectionCatalog) | Where-Object Key -eq 'ActivityAdvertising'
        $entry = @(& $section.GetCatalog) | Where-Object Name -eq 'DisableAdvertisingId'

        & $section.GetState $entry | Should -BeIn @('Applied', 'NotApplied')
    }

    It 'buckets the telemetry sections of a real profile through Get-WtProfileImportPlan' {
        $profile = [PSCustomObject]@{ Sections = [PSCustomObject]@{
                Telemetry           = @('DisableCeip', 'NoSuchTelemetryEntry')
                ActivityAdvertising = @('DisableAdvertisingId')
                SearchSuggestions   = @('DisableCortana')
            } }

        $plan = Get-WtProfileImportPlan -Profile $profile
        $telemetry = $plan.Sections | Where-Object Key -eq 'Telemetry'

        @(@($telemetry.ToApply) + @($telemetry.AlreadyApplied)) | Should -Contain 'DisableCeip'
        @($telemetry.Unknown) | Should -Be @('NoSuchTelemetryEntry')

        $activity = $plan.Sections | Where-Object Key -eq 'ActivityAdvertising'
        @(@($activity.ToApply) + @($activity.AlreadyApplied)) | Should -Contain 'DisableAdvertisingId'

        $search = $plan.Sections | Where-Object Key -eq 'SearchSuggestions'
        @(@($search.ToApply) + @($search.AlreadyApplied)) | Should -Contain 'DisableCortana'

        @($plan.UnknownSections) | Should -BeNullOrEmpty
    }

    It 'routes an already-applied telemetry entry to AlreadyApplied, not ToApply' {
        Mock Get-WtRegistryEntryState { [PSCustomObject]@{ Applied = $true } }

        $profile = [PSCustomObject]@{ Sections = [PSCustomObject]@{ SearchSuggestions = @('DisableCortana') } }
        $plan = Get-WtProfileImportPlan -Profile $profile
        $section = $plan.Sections | Where-Object Key -eq 'SearchSuggestions'

        @($section.AlreadyApplied) | Should -Be @('DisableCortana')
        @($section.ToApply) | Should -BeNullOrEmpty
    }

    It 'treats a profile exported before this bundle as three empty telemetry sections, not an error' {
        $profile = [PSCustomObject]@{ Sections = [PSCustomObject]@{ AiPrivacy = @('DisableRecall') } }

        $plan = Get-WtProfileImportPlan -Profile $profile

        foreach ($key in @('Telemetry', 'ActivityAdvertising', 'SearchSuggestions')) {
            $section = $plan.Sections | Where-Object Key -eq $key
            $section | Should -Not -BeNullOrEmpty -Because "$key must still appear in the plan"
            @($section.ToApply) | Should -BeNullOrEmpty
            @($section.AlreadyApplied) | Should -BeNullOrEmpty
            @($section.Unknown) | Should -BeNullOrEmpty
        }
        @($plan.UnknownSections) | Should -BeNullOrEmpty
    }

    It 'gives every section the three delegates and a catalog whose entries carry Name and Risk' {
        foreach ($section in @(Get-WtProfileSectionCatalog)) {
            $section.GetCatalog | Should -BeOfType [scriptblock] -Because "$($section.Key) needs GetCatalog"
            $section.GetState | Should -BeOfType [scriptblock] -Because "$($section.Key) needs GetState"
            $section.Apply | Should -BeOfType [scriptblock] -Because "$($section.Key) needs Apply"
            $section.TitleKey | Should -Not -BeNullOrEmpty
            $catalog = @(& $section.GetCatalog)
            $catalog.Count | Should -BeGreaterThan 0 -Because "$($section.Key) catalog must not be empty"
            foreach ($entry in $catalog) {
                $entry.Name | Should -Not -BeNullOrEmpty
                $entry.Risk | Should -BeIn @('SAFE', 'CAUTION', 'ADVANCED')
            }
        }
    }

    It 'flags only the two Customization sections as restarting Explorer' {
        $sections = @(Get-WtProfileSectionCatalog)
        ($sections | Where-Object RestartsExplorer).Key | Should -Be @('ContextMenu', 'ExplorerView')
    }
}

Describe 'New-WtProfileSnapshot' {
    BeforeEach {
        $script:Sections = New-FakeSections
    }

    It 'records only Applied entry names, and an empty array for a section with none' {
        $profile = New-WtProfileSnapshot -Sections $Sections -Name 'snap'
        @($profile.Sections.Alpha) | Should -Be @('a1')
        @($profile.Sections.Beta).Count | Should -Be 0
        @($profile.Sections.PSObject.Properties.Name) | Should -Be @('Alpha', 'Beta')
    }

    It 'fills the header: SchemaVersion 1, sortable CreatedAt, name, machine facts' {
        $profile = New-WtProfileSnapshot -Sections $Sections -Name 'snap'
        $profile.SchemaVersion | Should -Be 1
        $profile.Name | Should -Be 'snap'
        $profile.CreatedAt | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$'
        $profile.PowerShellVersion | Should -Be $PSVersionTable.PSVersion.ToString()
        $profile.OsVersion | Should -Not -BeNullOrEmpty
    }

    It 'calls -Progress once per section, in order, before reading that section' {
        New-WtProfileSnapshot -Sections $Sections -Name 'snap' -Progress { param($Key) $script:ProgressCalls.Add($Key) } | Out-Null
        @($ProgressCalls) | Should -Be @('Alpha', 'Beta')
        @($StateCalls) | Should -Be @('Alpha:a1', 'Alpha:a2', 'Alpha:a3', 'Beta:b1', 'Beta:b2')
    }
}

Describe 'ConvertTo-WtProfileFileName' {
    It 'replaces every Windows-invalid character with a hyphen' {
        ConvertTo-WtProfileFileName -Name 'gaming: rig/1' | Should -Be 'gaming- rig-1'
        ConvertTo-WtProfileFileName -Name 'a\b*c?d"e<f>g|h' | Should -Be 'a-b-c-d-e-f-g-h'
    }

    It 'falls back to a timestamped default for a blank name' {
        ConvertTo-WtProfileFileName -Name '   ' | Should -Match '^profile-\d{8}-\d{6}$'
        ConvertTo-WtProfileFileName -Name '' | Should -Match '^profile-\d{8}-\d{6}$'
    }
}

Describe 'Save-WtProfile / Get-WtProfiles / Read-WtProfile round trip' {
    BeforeEach {
        $script:FakeRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $script:Sections = New-FakeSections
    }

    It 'saves under the User-scope profiles directory as sanitized-name.json and returns the path' {
        $profile = New-WtProfileSnapshot -Sections $Sections -Name 'smoke test: one'
        $path = Save-WtProfile -Profile $profile -TestRootOverride $FakeRoot
        $expectedDir = Get-WtDataPath -Scope User -SubPath 'profiles' -TestRootOverride $FakeRoot
        $path | Should -Be (Join-Path $expectedDir 'smoke test- one.json')
        Test-Path -LiteralPath $path | Should -BeTrue
        $profile.Name | Should -Be 'smoke test- one'
    }

    It 'lists saved profiles newest first by CreatedAt, skipping a corrupt neighbour, and reloads sections intact' {
        $older = New-WtProfileSnapshot -Sections $Sections -Name 'older'
        $older.CreatedAt = '2020-12-01T00:00:00'
        $newer = New-WtProfileSnapshot -Sections $Sections -Name 'newer'
        $newer.CreatedAt = '2021-01-01T00:00:00'
        Save-WtProfile -Profile $older -TestRootOverride $FakeRoot | Out-Null
        Save-WtProfile -Profile $newer -TestRootOverride $FakeRoot | Out-Null
        $dir = Get-WtDataPath -Scope User -SubPath 'profiles' -TestRootOverride $FakeRoot
        Set-Content -LiteralPath (Join-Path $dir 'corrupt.json') -Value '{ nope' -Encoding UTF8

        $listed = @(Get-WtProfiles -TestRootOverride $FakeRoot -WarningAction SilentlyContinue)
        $listed.Count | Should -Be 2
        $listed[0].Name | Should -Be 'newer'
        $listed[1].Name | Should -Be 'older'
        $listed[0].Path | Should -Be (Join-Path $dir 'newer.json')

        $loaded = Read-WtProfile -Path $listed[0].Path
        $loaded.Error | Should -BeNullOrEmpty
        @($loaded.Profile.Sections.Alpha) | Should -Be @('a1')
        @($loaded.Profile.Sections.Beta).Count | Should -Be 0
        $loaded.Profile.SchemaVersion | Should -Be 1
    }
}

Describe 'Read-WtProfile validation' {
    BeforeEach {
        $script:JsonPath = Join-Path $TestDrive "$([guid]::NewGuid().ToString()).json"
    }

    It 'reports UnsupportedVersion for a SchemaVersion other than 1' {
        Set-Content -LiteralPath $JsonPath -Value '{ "SchemaVersion": 99, "Sections": {} }' -Encoding UTF8
        $result = Read-WtProfile -Path $JsonPath
        $result.Profile | Should -BeNullOrEmpty
        $result.Error | Should -Be 'UnsupportedVersion'
    }

    It 'reports NoSections when the header has no Sections object' {
        Set-Content -LiteralPath $JsonPath -Value '{ "SchemaVersion": 1, "Name": "x" }' -Encoding UTF8
        (Read-WtProfile -Path $JsonPath).Error | Should -Be 'NoSections'
        Set-Content -LiteralPath $JsonPath -Value '{ "SchemaVersion": 1, "Sections": "not-an-object" }' -Encoding UTF8
        (Read-WtProfile -Path $JsonPath).Error | Should -Be 'NoSections'
    }

    It 'reports NotReadable for a missing path and for non-JSON content, without throwing' {
        { Read-WtProfile -Path (Join-Path $TestDrive 'missing.json') } | Should -Not -Throw
        (Read-WtProfile -Path (Join-Path $TestDrive 'missing.json')).Error | Should -Be 'NotReadable'
        Set-Content -LiteralPath $JsonPath -Value 'hello' -Encoding UTF8
        (Read-WtProfile -Path $JsonPath -WarningAction SilentlyContinue).Error | Should -Be 'NotReadable'
    }
}

Describe 'Get-WtProfileImportPlan' {
    BeforeEach {
        $script:Sections = New-FakeSections
    }

    It 'buckets every profile name into exactly one of ToApply / AlreadyApplied / NotPresent / Unknown, and lists unknown section keys' {
        $profile = [PSCustomObject]@{
            SchemaVersion = 1
            Sections      = [PSCustomObject]@{
                Alpha   = @('a1', 'a2', 'a3', 'zz')
                Beta    = @('b1')
                Gamma   = @('g1')
            }
        }

        $plan = Get-WtProfileImportPlan -Profile $profile -Sections $Sections

        @($plan.Sections).Count | Should -Be 2
        $alpha = $plan.Sections | Where-Object Key -eq 'Alpha'
        @($alpha.ToApply) | Should -Be @('a2')
        @($alpha.AlreadyApplied) | Should -Be @('a1')
        @($alpha.NotPresent) | Should -Be @('a3')
        @($alpha.Unknown) | Should -Be @('zz')
        $alpha.TitleKey | Should -Be 'Alpha'
        @($alpha.Catalog).Count | Should -Be 3

        $beta = $plan.Sections | Where-Object Key -eq 'Beta'
        @($beta.ToApply) | Should -Be @('b1')
        @($beta.AlreadyApplied).Count | Should -Be 0
        $beta.RestartsExplorer | Should -BeTrue

        @($plan.UnknownSections) | Should -Be @('Gamma')
    }

    It 'reads live state only for the names in the profile, never the whole catalog' {
        $profile = [PSCustomObject]@{ SchemaVersion = 1; Sections = [PSCustomObject]@{ Alpha = @('a2'); Beta = @() } }
        Get-WtProfileImportPlan -Profile $profile -Sections $Sections | Out-Null
        @($StateCalls) | Should -Be @('Alpha:a2')
    }

    It 'treats a section key missing from the profile as an empty section, not an error' {
        $profile = [PSCustomObject]@{ SchemaVersion = 1; Sections = [PSCustomObject]@{ Alpha = @('a1') } }
        $plan = Get-WtProfileImportPlan -Profile $profile -Sections $Sections
        $beta = $plan.Sections | Where-Object Key -eq 'Beta'
        $beta | Should -Not -BeNullOrEmpty
        @($beta.ToApply).Count | Should -Be 0
        @($beta.AlreadyApplied).Count | Should -Be 0
        @($plan.UnknownSections).Count | Should -Be 0
    }

    It 'calls -Progress once per section in order' {
        $profile = [PSCustomObject]@{ SchemaVersion = 1; Sections = [PSCustomObject]@{ Alpha = @('a1'); Beta = @('b1') } }
        Get-WtProfileImportPlan -Profile $profile -Sections $Sections -Progress { param($Key) $script:ProgressCalls.Add($Key) } | Out-Null
        @($ProgressCalls) | Should -Be @('Alpha', 'Beta')
    }
}

Describe 'Invoke-WtApplyProfile' {
    BeforeEach {
        $script:Sections = New-FakeSections
    }

    It 'applies each section with exactly its ToApply names and skips a section with nothing to apply' {
        $profile = [PSCustomObject]@{ SchemaVersion = 1; Sections = [PSCustomObject]@{ Alpha = @('a1', 'a2'); Beta = @() } }
        $plan = Get-WtProfileImportPlan -Profile $profile -Sections $Sections

        $result = Invoke-WtApplyProfile -Plan $plan -Sections $Sections

        $result.Aborted | Should -BeFalse
        @($ApplyCalls['Alpha']) | Should -Be @('a2')
        $ApplyCalls.ContainsKey('Beta') | Should -BeFalse
        $alpha = $result.Sections | Where-Object Key -eq 'Alpha'
        $alpha.Outcome | Should -Be 'Applied'
        @($alpha.Results).Count | Should -Be 1
        $alpha.Results[0].Applied | Should -BeTrue
        ($result.Sections | Where-Object Key -eq 'Beta').Outcome | Should -Be 'NothingToApply'
    }

    It 'stops at the first Aborted section and marks the rest Skipped without calling their Apply' {
        $Sections[0].Apply = {
            param([string[]]$Names)
            $script:ApplyCalls['Alpha'] = @($Names)
            [PSCustomObject]@{ Aborted = $true; Results = @() }
        }
        $profile = [PSCustomObject]@{ SchemaVersion = 1; Sections = [PSCustomObject]@{ Alpha = @('a2'); Beta = @('b1', 'b2') } }
        $plan = Get-WtProfileImportPlan -Profile $profile -Sections $Sections

        $result = Invoke-WtApplyProfile -Plan $plan -Sections $Sections

        $result.Aborted | Should -BeTrue
        ($result.Sections | Where-Object Key -eq 'Alpha').Outcome | Should -Be 'Aborted'
        ($result.Sections | Where-Object Key -eq 'Beta').Outcome | Should -Be 'Skipped'
        $ApplyCalls.ContainsKey('Beta') | Should -BeFalse
    }

    It 'carries the section catalog and RestartsExplorer flag through to the result so the caller can offer the Explorer restart' {
        $profile = [PSCustomObject]@{ SchemaVersion = 1; Sections = [PSCustomObject]@{ Alpha = @(); Beta = @('b1') } }
        $plan = Get-WtProfileImportPlan -Profile $profile -Sections $Sections
        $result = Invoke-WtApplyProfile -Plan $plan -Sections $Sections
        $beta = $result.Sections | Where-Object Key -eq 'Beta'
        $beta.RestartsExplorer | Should -BeTrue
        @($beta.Catalog).Name | Should -Be @('b1', 'b2')
    }
}

Describe 'Format-WtProfileResultLabel' {
    It 'prefers the catalog entry, appends the item name only when it differs, and falls back to Name' {
        Format-WtProfileResultLabel -Item ([PSCustomObject]@{ CatalogEntry = 'DisableCopilot'; Name = 'TurnOffWindowsCopilot' }) | Should -Be 'DisableCopilot (TurnOffWindowsCopilot)'
        Format-WtProfileResultLabel -Item ([PSCustomObject]@{ CatalogEntry = 'AddTakeOwnership'; Hive = 'LocalMachine' }) | Should -Be 'AddTakeOwnership'
        Format-WtProfileResultLabel -Item ([PSCustomObject]@{ CatalogEntry = 'DiagTrack'; Name = 'DiagTrack' }) | Should -Be 'DiagTrack'
        Format-WtProfileResultLabel -Item ([PSCustomObject]@{ Name = 'Microsoft.BingNews' }) | Should -Be 'Microsoft.BingNews'
    }
}

Describe 'Show-WtProfileExport / Show-WtProfileImport panel flows' {
    BeforeEach {
        $script:FakeRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $script:Sections = New-FakeSections
        $script:ProgressFrames = New-Object System.Collections.Generic.List[object]
        $script:ResultLines = @()
        Mock Get-WtProfileSectionCatalog { $script:Sections }
    }

    It 'export: the -Progress callback appends one line per section and the panel sees them accumulate (regression: caller $progress shadowed by the callee -Progress parameter)' {
        Show-WtProfileExport -TestRootOverride $FakeRoot -AskName { 'snap' } -ShowProgress { param($Lines) $script:ProgressFrames.Add(@($Lines)) } -ShowResult { param($Lines) $script:ResultLines = @($Lines) }

        $ProgressFrames.Count | Should -Be 2
        @($ProgressFrames[0]).Count | Should -Be 1
        @($ProgressFrames[1]).Count | Should -Be 2
        @($ProgressFrames[1])[1] | Should -BeLike ('*' + (Get-Translation 'ProfileReadingState') + '*')
        $saved = @(Get-WtProfiles -TestRootOverride $FakeRoot)
        $saved.Count | Should -Be 1
        $ResultLines | Should -Contain ('  ' + $saved[0].Path)
    }

    It 'import: the -Progress callback appends one line per section before the diff is shown (same shadowing regression)' {
        $profile = New-WtProfileSnapshot -Sections $Sections -Name 'snap'
        Save-WtProfile -Profile $profile -TestRootOverride $FakeRoot | Out-Null

        Show-WtProfileImport -TestRootOverride $FakeRoot -Ask { param($Lines, $Prompt, $Risk) '0' } -ShowProgress { param($Lines) $script:ProgressFrames.Add(@($Lines)) } -ShowResult { param($Lines) $script:ResultLines = @($Lines) }

        $ProgressFrames.Count | Should -Be 2
        @($ProgressFrames[1]).Count | Should -Be 2
        $ResultLines | Should -Contain (Get-Translation 'ProfileNothingToApply')
    }
}
