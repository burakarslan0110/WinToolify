#Requires -Modules Pester

<#
.SYNOPSIS
    Telemetry & Policy bundle coverage: Get-WtWindowsEdition (the injectable
    EditionID probe) and the three RegistryChanges-shaped catalogs -
    Get-WtTelemetryCatalog (edition-gated AllowTelemetry),
    Get-WtActivityAdvertisingCatalog and Get-WtSearchSuggestionsCatalog.
    Registry access runs against injected fakes, since the Registry
    PSProvider does not exist outside Windows.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath

    function New-RegistryFake {
        param([hashtable]$Values)
        return {
            param($p, $n)
            $key = "$p|$n"
            if ($Values.ContainsKey($key)) {
                $o = New-Object PSObject
                $o | Add-Member -NotePropertyName $n -NotePropertyValue $Values[$key]
                return $o
            }
            return $null
        }.GetNewClosure()
    }

    function Assert-WtCatalogMatches {
        param($Catalog, $Expected)

        @($Catalog | ForEach-Object Name) | Should -Be @($Expected | ForEach-Object { $_.Name })
        foreach ($exp in $Expected) {
            $entry = $Catalog | Where-Object Name -eq $exp.Name
            $entry | Should -Not -BeNullOrEmpty -Because "$($exp.Name) must exist"
            $entry.DisplayLabel | Should -Not -BeNullOrEmpty -Because "$($exp.Name) needs a DisplayLabel"
            $entry.Risk | Should -Be $exp.Risk -Because "$($exp.Name) risk tag"
            @($entry.RegistryChanges).Count | Should -Be $exp.Changes.Count -Because "$($exp.Name) change count"
            for ($i = 0; $i -lt $exp.Changes.Count; $i++) {
                $entry.RegistryChanges[$i].Path | Should -Be $exp.Changes[$i].Path -Because "$($exp.Name) change $i path"
                $entry.RegistryChanges[$i].Name | Should -Be $exp.Changes[$i].Name -Because "$($exp.Name) change $i name"
                $entry.RegistryChanges[$i].Value | Should -Be $exp.Changes[$i].Value -Because "$($exp.Name) change $i value"
                $entry.RegistryChanges[$i].RegType | Should -Be 'DWord' -Because "$($exp.Name) change $i type"
            }
        }
    }
}

Describe 'Get-WtWindowsEdition' {
    It 'returns the EditionID string the registry reports' {
        $fake = New-RegistryFake -Values @{ 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion|EditionID' = 'Enterprise' }
        Get-WtWindowsEdition -GetPropertyAction $fake | Should -Be 'Enterprise'
    }

    It 'returns $null when EditionID is absent' {
        $fake = New-RegistryFake -Values @{}
        Get-WtWindowsEdition -GetPropertyAction $fake | Should -BeNullOrEmpty
    }
}

Describe 'Get-WtTelemetryCatalog' {
    BeforeAll {
        $script:HomeCatalog = Get-WtTelemetryCatalog -GetEditionAction { 'Core' }
    }

    It 'writes exactly its expected paths, names and values' {
        $dataPolicy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection'
        $dataGpo = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
        $appCompat = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat'
        $inputPers = 'HKCU:\Software\Microsoft\InputPersonalization'

        $expected = @(
            @{ Name = 'SetDiagnosticDataMinimal'; Risk = 'SAFE'; Changes = @(
                    @{ Path = $dataPolicy; Name = 'AllowTelemetry'; Value = 1 },
                    @{ Path = $dataPolicy; Name = 'MaxTelemetryAllowed'; Value = 1 },
                    @{ Path = $dataGpo; Name = 'AllowTelemetry'; Value = 1 }) }
            @{ Name = 'DisableOneSettingsDownloads'; Risk = 'CAUTION'; Changes = @(
                    @{ Path = $dataGpo; Name = 'DisableOneSettingsDownloads'; Value = 1 }) }
            @{ Name = 'DisableFeedbackNotifications'; Risk = 'SAFE'; Changes = @(
                    @{ Path = $dataGpo; Name = 'DoNotShowFeedbackNotifications'; Value = 1 },
                    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Siuf\Rules'; Name = 'NumberOfSIUFInPeriod'; Value = 0 }) }
            @{ Name = 'DisableCeip'; Risk = 'SAFE'; Changes = @(
                    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows'; Name = 'CEIPEnable'; Value = 0 },
                    @{ Path = 'HKLM:\SOFTWARE\Microsoft\SQMClient\Windows'; Name = 'CEIPEnable'; Value = 0 }) }
            @{ Name = 'DisableApplicationExperience'; Risk = 'CAUTION'; Changes = @(
                    @{ Path = $appCompat; Name = 'AITEnable'; Value = 0 },
                    @{ Path = $appCompat; Name = 'DisableInventory'; Value = 1 },
                    @{ Path = $appCompat; Name = 'DisableUAR'; Value = 1 }) }
            @{ Name = 'DisableInkingAndTyping'; Risk = 'SAFE'; Changes = @(
                    @{ Path = $inputPers; Name = 'RestrictImplicitInkCollection'; Value = 1 },
                    @{ Path = $inputPers; Name = 'RestrictImplicitTextCollection'; Value = 1 },
                    @{ Path = "$inputPers\TrainedDataStore"; Name = 'HarvestContacts'; Value = 0 },
                    @{ Path = 'HKCU:\Software\Microsoft\Personalization\Settings'; Name = 'AcceptedPrivacyPolicy'; Value = 0 },
                    @{ Path = 'HKCU:\Software\Microsoft\Input\TIPC'; Name = 'Enabled'; Value = 0 }) }
            @{ Name = 'DisableOnlineSpeech'; Risk = 'CAUTION'; Changes = @(
                    @{ Path = 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'; Name = 'HasAccepted'; Value = 0 }) }
        )

        Assert-WtCatalogMatches -Catalog $HomeCatalog -Expected $expected
    }

    It 'names the diagnostic-data entry after the level the edition allows, not "disable telemetry"' {
        ($HomeCatalog | Where-Object Name -eq 'SetDiagnosticDataMinimal').DisplayLabel |
            Should -Be 'Set diagnostic data to the minimum this Windows edition allows'
    }

    It 'targets AllowTelemetry 0 on Enterprise and Education, 1 everywhere else including an unreadable edition' {
        foreach ($edition in @('Enterprise', 'EnterpriseS', 'Education')) {
            $catalog = Get-WtTelemetryCatalog -GetEditionAction { $edition }.GetNewClosure()
            $entry = $catalog | Where-Object Name -eq 'SetDiagnosticDataMinimal'
            @($entry.RegistryChanges | Where-Object Name -eq 'AllowTelemetry' | ForEach-Object Value) |
                Should -Be @(0, 0) -Because "$edition enforces AllowTelemetry 0"
        }
        foreach ($edition in @('Core', 'Professional', 'CoreSingleLanguage', $null)) {
            $catalog = Get-WtTelemetryCatalog -GetEditionAction { $edition }.GetNewClosure()
            $entry = $catalog | Where-Object Name -eq 'SetDiagnosticDataMinimal'
            @($entry.RegistryChanges | Where-Object Name -eq 'AllowTelemetry' | ForEach-Object Value) |
                Should -Be @(1, 1) -Because "Windows clamps 0 to 1 on $edition, so 0 would be a lie"
        }
    }

    It 'always targets MaxTelemetryAllowed 1, whatever the edition' {
        foreach ($edition in @('Enterprise', 'Core', $null)) {
            $catalog = Get-WtTelemetryCatalog -GetEditionAction { $edition }.GetNewClosure()
            $entry = $catalog | Where-Object Name -eq 'SetDiagnosticDataMinimal'
            @($entry.RegistryChanges | Where-Object Name -eq 'MaxTelemetryAllowed' | ForEach-Object Value) | Should -Be @(1)
        }
    }

    It 'tags four entries SAFE and three CAUTION, every CAUTION carrying a consequence, none ADVANCED' {
        @($HomeCatalog | Where-Object Risk -eq 'SAFE' | ForEach-Object Name) |
            Should -Be @('SetDiagnosticDataMinimal', 'DisableFeedbackNotifications', 'DisableCeip', 'DisableInkingAndTyping')
        @($HomeCatalog | Where-Object Risk -eq 'CAUTION' | ForEach-Object Name) |
            Should -Be @('DisableOneSettingsDownloads', 'DisableApplicationExperience', 'DisableOnlineSpeech')
        foreach ($entry in $HomeCatalog | Where-Object Risk -eq 'CAUTION') {
            $entry.Consequence | Should -Not -BeNullOrEmpty -Because "$($entry.Name) is CAUTION"
        }
        @($HomeCatalog | Where-Object Risk -eq 'ADVANCED') | Should -BeNullOrEmpty
    }

    It 'defaults its edition probe to the real Get-WtWindowsEdition' {
        $param = (Get-Command Get-WtTelemetryCatalog).ScriptBlock.Ast.Body.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'GetEditionAction' }
        $param.DefaultValue.Extent.Text | Should -Match 'Get-WtWindowsEdition'
    }

    It 'is reported NotApplied by Get-WtRegistryEntryState until every one of an entry\''s values matches' {
        $entry = $HomeCatalog | Where-Object Name -eq 'DisableApplicationExperience'
        $appCompat = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat'

        $partial = New-RegistryFake -Values @{ "$appCompat|AITEnable" = 0; "$appCompat|DisableInventory" = 1 }
        (Get-WtRegistryEntryState -Entry $entry -GetPropertyAction $partial).Applied | Should -BeFalse

        $full = New-RegistryFake -Values @{ "$appCompat|AITEnable" = 0; "$appCompat|DisableInventory" = 1; "$appCompat|DisableUAR" = 1 }
        (Get-WtRegistryEntryState -Entry $entry -GetPropertyAction $full).Applied | Should -BeTrue
    }
}

Describe 'Get-WtActivityAdvertisingCatalog' {
    BeforeAll { $script:ActivityCatalog = Get-WtActivityAdvertisingCatalog }

    It 'writes exactly its expected paths, names and values' {
        $system = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
        $expected = @(
            @{ Name = 'DisableActivityHistory'; Risk = 'SAFE'; Changes = @(
                    @{ Path = $system; Name = 'EnableActivityFeed'; Value = 0 },
                    @{ Path = $system; Name = 'PublishUserActivities'; Value = 0 },
                    @{ Path = $system; Name = 'UploadUserActivities'; Value = 0 }) }
            @{ Name = 'DisableAppLaunchTracking'; Risk = 'SAFE'; Changes = @(
                    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_TrackProgs'; Value = 0 }) }
            @{ Name = 'DisableAdvertisingId'; Risk = 'SAFE'; Changes = @(
                    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; Value = 0 },
                    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo'; Name = 'DisabledByGroupPolicy'; Value = 1 }) }
            @{ Name = 'DisableTailoredExperiences'; Risk = 'SAFE'; Changes = @(
                    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'; Name = 'TailoredExperiencesWithDiagnosticDataEnabled'; Value = 0 }) }
        )

        Assert-WtCatalogMatches -Catalog $ActivityCatalog -Expected $expected
    }

    It 'tags every entry SAFE' {
        @($ActivityCatalog | Where-Object Risk -ne 'SAFE') | Should -BeNullOrEmpty
    }
}

Describe 'Get-WtSearchSuggestionsCatalog' {
    <#
    .SYNOPSIS
        Some entries write more than one registry path for what looks like
        one setting: DisableSearchBoxSuggestions and DisableWindowsSpotlight
        are User Configuration policies whose authoritative value lives
        under an HKCU policy key, with the other paths kept only for
        compatibility; DisableStartMenuSuggestions writes both the
        Windows 10 and Windows 11 keys, since either half alone leaves
        that OS's suggestions untouched.
    #>
    BeforeAll { $script:SearchCatalog = Get-WtSearchSuggestionsCatalog }

    It 'writes exactly its expected paths, names and values' {
        $search = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'
        $userSearch = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search'
        $cloud = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
        $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        $userCloud = 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent'
        $userExplorerPolicy = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'
        $advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

        $expected = @(
            @{ Name = 'DisableCortana'; Risk = 'SAFE'; Changes = @(
                    @{ Path = $search; Name = 'AllowCortana'; Value = 0 }) }
            @{ Name = 'DisableWebSearch'; Risk = 'CAUTION'; Changes = @(
                    @{ Path = $search; Name = 'DisableWebSearch'; Value = 1 },
                    @{ Path = $search; Name = 'ConnectedSearchUseWeb'; Value = 0 },
                    @{ Path = $userSearch; Name = 'BingSearchEnabled'; Value = 0 }) }
            @{ Name = 'DisableSearchBoxSuggestions'; Risk = 'SAFE'; Changes = @(
                    @{ Path = $userExplorerPolicy; Name = 'DisableSearchBoxSuggestions'; Value = 1 },
                    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; Value = 1 },
                    @{ Path = $userSearch; Name = 'DisableSearchBoxSuggestions'; Value = 1 }) }
            @{ Name = 'DisableConsumerFeatures'; Risk = 'SAFE'; Changes = @(
                    @{ Path = $cloud; Name = 'DisableWindowsConsumerFeatures'; Value = 1 },
                    @{ Path = $cloud; Name = 'DisableSoftLanding'; Value = 1 }) }
            @{ Name = 'DisableWindowsSpotlight'; Risk = 'CAUTION'; Changes = @(
                    @{ Path = $userCloud; Name = 'DisableWindowsSpotlightFeatures'; Value = 1 },
                    @{ Path = $cloud; Name = 'DisableWindowsSpotlightFeatures'; Value = 1 }) }
            @{ Name = 'DisableStartMenuSuggestions'; Risk = 'SAFE'; Changes = @(
                    @{ Path = $cdm; Name = 'SubscribedContent-338388Enabled'; Value = 0 },
                    @{ Path = $advanced; Name = 'Start_IrisRecommendations'; Value = 0 },
                    @{ Path = $cdm; Name = 'SubscribedContent-338389Enabled'; Value = 0 },
                    @{ Path = $cdm; Name = 'SubscribedContent-338393Enabled'; Value = 0 },
                    @{ Path = $cdm; Name = 'SubscribedContent-353694Enabled'; Value = 0 },
                    @{ Path = $cdm; Name = 'SubscribedContent-353696Enabled'; Value = 0 },
                    @{ Path = $cdm; Name = 'SilentInstalledAppsEnabled'; Value = 0 }) }
        )

        Assert-WtCatalogMatches -Catalog $SearchCatalog -Expected $expected
    }

    It 'tags DisableWebSearch and DisableWindowsSpotlight CAUTION with consequences, everything else SAFE' {
        @($SearchCatalog | Where-Object Risk -eq 'CAUTION' | ForEach-Object Name) |
            Should -Be @('DisableWebSearch', 'DisableWindowsSpotlight')
        foreach ($entry in $SearchCatalog | Where-Object Risk -eq 'CAUTION') {
            $entry.Consequence | Should -Not -BeNullOrEmpty -Because "$($entry.Name) is CAUTION"
        }
        @($SearchCatalog | Where-Object Risk -eq 'ADVANCED') | Should -BeNullOrEmpty
    }
}

Describe 'the three telemetry catalogs together' {
    It 'use entry names that are unique across all three, so a Config Profile section can never collide' {
        $names = @(Get-WtTelemetryCatalog -GetEditionAction { 'Core' }) + @(Get-WtActivityAdvertisingCatalog) + @(Get-WtSearchSuggestionsCatalog) |
            ForEach-Object Name
        @($names).Count | Should -Be 17
        @($names | Sort-Object -Unique).Count | Should -Be 17
    }

    It 'tag nothing ADVANCED, since no entry here is irreversible' {
        $all = @(Get-WtTelemetryCatalog -GetEditionAction { 'Core' }) + @(Get-WtActivityAdvertisingCatalog) + @(Get-WtSearchSuggestionsCatalog)
        @($all | Where-Object Risk -notin @('SAFE', 'CAUTION')) | Should -BeNullOrEmpty
    }
}
