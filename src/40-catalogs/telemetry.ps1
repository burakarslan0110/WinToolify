# Telemetry, activity/advertising and search-suggestion catalogs.
# Covered by: tests/TelemetryCatalogs.Tests.ps1

function Get-WtTelemetryCatalog {
    <#
    .SYNOPSIS
        The seven core telemetry toggles as a RegistryChanges-shaped
        catalog. AllowTelemetry is edition-gated: Microsoft silently
        clamps 0 to 1 on Home and Pro, so Enterprise/Education target 0
        and every other edition targets 1. CEIPEnable, the ink/text
        collection keys, and online-speech HasAccepted are deliberately
        Delete rather than Set, since their real Windows default is
        missing or OS-version-dependent.
    #>
    param(
        [scriptblock]$GetEditionAction = { Get-WtWindowsEdition }
    )

    $edition = & $GetEditionAction
    $telemetryTarget = 1
    if ($edition -and ($edition -match 'Enterprise' -or $edition -match 'Education')) {
        $telemetryTarget = 0
    }

    $dataPolicy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection'
    $dataGpo = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
    $appCompat = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat'
    $inputPers = 'HKCU:\Software\Microsoft\InputPersonalization'

    $entry = {
        param($name, $label, $risk, $consequence, $changes)
        [PSCustomObject]@{
            Name            = $name
            DisplayLabel    = $label
            Risk            = $risk
            Consequence     = $consequence
            RegistryChanges = @($changes)
        }
    }
    $dword = { param($p, $n, $v, $off) if ($null -eq $off) { [PSCustomObject]@{ Path = $p; Name = $n; RegType = 'DWord'; Value = $v; OffAction = 'Delete' } } else { [PSCustomObject]@{ Path = $p; Name = $n; RegType = 'DWord'; Value = $v; OffAction = 'Set'; OffValue = $off } } }

    return Resolve-WtCatalogText -KeyPrefix 'Telemetry' -Catalog @(
        (& $entry 'SetDiagnosticDataMinimal' 'Set diagnostic data to the minimum this Windows edition allows' 'SAFE' $null @(
            (& $dword $dataPolicy 'AllowTelemetry' $telemetryTarget),
            (& $dword $dataPolicy 'MaxTelemetryAllowed' 1),
            (& $dword $dataGpo 'AllowTelemetry' $telemetryTarget)))
        (& $entry 'DisableOneSettingsDownloads' 'Stop automatic cloud configuration downloads (OneSettings)' 'CAUTION' 'Windows components and apps that pull their settings from the OneSettings service stop receiving configuration updates' @(
            (& $dword $dataGpo 'DisableOneSettingsDownloads' 1)))
        (& $entry 'DisableFeedbackNotifications' 'Stop Windows feedback prompts' 'SAFE' $null @(
            (& $dword $dataGpo 'DoNotShowFeedbackNotifications' 1),
            (& $dword 'HKCU:\SOFTWARE\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0)))
        (& $entry 'DisableCeip' 'Disable the Customer Experience Improvement Program' 'SAFE' $null @(
            (& $dword 'HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows' 'CEIPEnable' 0),
            (& $dword 'HKLM:\SOFTWARE\Microsoft\SQMClient\Windows' 'CEIPEnable' 0)))
        (& $entry 'DisableApplicationExperience' 'Disable application compatibility telemetry' 'CAUTION' 'Steps Recorder (PSR) and automatic compatibility fixes for older programs stop working' @(
            (& $dword $appCompat 'AITEnable' 0),
            (& $dword $appCompat 'DisableInventory' 1),
            (& $dword $appCompat 'DisableUAR' 1)))
        (& $entry 'DisableInkingAndTyping' 'Disable inking and typing personalization' 'SAFE' $null @(
            (& $dword $inputPers 'RestrictImplicitInkCollection' 1),
            (& $dword $inputPers 'RestrictImplicitTextCollection' 1),
            (& $dword "$inputPers\TrainedDataStore" 'HarvestContacts' 0 1),
            (& $dword 'HKCU:\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 0 1),
            (& $dword 'HKCU:\Software\Microsoft\Input\TIPC' 'Enabled' 0 1)))
        (& $entry 'DisableOnlineSpeech' 'Disable online speech recognition' 'CAUTION' 'Voice typing and any app relying on Microsoft''s cloud speech service stop working; offline speech recognition is unaffected' @(
            (& $dword 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 0)))
    )
}

function Get-WtActivityAdvertisingCatalog {
    <#
    .SYNOPSIS
        The four activity-tracking and advertising toggles as a
        RegistryChanges-shaped catalog; all four are SAFE, since none
        removes a capability, only collection and personalisation.
    #>
    $system = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'

    $entry = {
        param($name, $label, $risk, $consequence, $changes)
        [PSCustomObject]@{
            Name            = $name
            DisplayLabel    = $label
            Risk            = $risk
            Consequence     = $consequence
            RegistryChanges = @($changes)
        }
    }
    $dword = { param($p, $n, $v, $off) if ($null -eq $off) { [PSCustomObject]@{ Path = $p; Name = $n; RegType = 'DWord'; Value = $v; OffAction = 'Delete' } } else { [PSCustomObject]@{ Path = $p; Name = $n; RegType = 'DWord'; Value = $v; OffAction = 'Set'; OffValue = $off } } }

    return Resolve-WtCatalogText -KeyPrefix 'ActivityAdvertising' -Catalog @(
        (& $entry 'DisableActivityHistory' 'Disable activity history collection and upload' 'SAFE' $null @(
            (& $dword $system 'EnableActivityFeed' 0),
            (& $dword $system 'PublishUserActivities' 0),
            (& $dword $system 'UploadUserActivities' 0)))
        (& $entry 'DisableAppLaunchTracking' 'Disable app-launch tracking' 'SAFE' $null @(
            (& $dword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_TrackProgs' 0)))
        (& $entry 'DisableAdvertisingId' 'Disable the advertising ID' 'SAFE' $null @(
            (& $dword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0 1),
            (& $dword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1)))
        (& $entry 'DisableTailoredExperiences' 'Disable tailored experiences from diagnostic data' 'SAFE' $null @(
            (& $dword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0 1)))
    )
}

function Get-WtSearchSuggestionsCatalog {
    <#
    .SYNOPSIS
        The six search and suggestion toggles as a RegistryChanges-shaped
        catalog. DisableWebSearch and DisableWindowsSpotlight are CAUTION
        since each removes something the user can see daily; the other
        four only stop Microsoft pushing content. DisableSearchBoxSuggestions
        and DisableWindowsSpotlightFeatures are User Configuration policies
        read from HKCU, written alongside the legacy HKLM values;
        DisableStartMenuSuggestions also writes the keys that actually
        govern Start suggestions on Windows 10 (338388) and 11
        (Start_IrisRecommendations).
    #>
    $search = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'
    $userSearch = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search'
    $cloud = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
    $userCloud = 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent'
    $userExplorerPolicy = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'
    $advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'

    $entry = {
        param($name, $label, $risk, $consequence, $changes)
        [PSCustomObject]@{
            Name            = $name
            DisplayLabel    = $label
            Risk            = $risk
            Consequence     = $consequence
            RegistryChanges = @($changes)
        }
    }
    $dword = { param($p, $n, $v, $off) if ($null -eq $off) { [PSCustomObject]@{ Path = $p; Name = $n; RegType = 'DWord'; Value = $v; OffAction = 'Delete' } } else { [PSCustomObject]@{ Path = $p; Name = $n; RegType = 'DWord'; Value = $v; OffAction = 'Set'; OffValue = $off } } }

    return Resolve-WtCatalogText -KeyPrefix 'SearchSuggestions' -Catalog @(
        (& $entry 'DisableCortana' 'Disable Cortana' 'SAFE' $null @(
            (& $dword $search 'AllowCortana' 0)))
        (& $entry 'DisableWebSearch' 'Disable web results in Start menu search' 'CAUTION' 'Start menu search returns local results only; Bing answers and web suggestions disappear' @(
            (& $dword $search 'DisableWebSearch' 1),
            (& $dword $search 'ConnectedSearchUseWeb' 0),
            (& $dword $userSearch 'BingSearchEnabled' 0)))
        (& $entry 'DisableSearchBoxSuggestions' 'Disable search box suggestions' 'SAFE' $null @(
            (& $dword $userExplorerPolicy 'DisableSearchBoxSuggestions' 1),
            (& $dword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1),
            (& $dword $userSearch 'DisableSearchBoxSuggestions' 1)))
        (& $entry 'DisableConsumerFeatures' 'Stop automatic install of suggested apps' 'SAFE' $null @(
            (& $dword $cloud 'DisableWindowsConsumerFeatures' 1),
            (& $dword $cloud 'DisableSoftLanding' 1)))
        (& $entry 'DisableWindowsSpotlight' 'Disable Windows Spotlight' 'CAUTION' 'The lock screen falls back to a static image; Spotlight backgrounds and the "welcome experience" stop appearing' @(
            (& $dword $userCloud 'DisableWindowsSpotlightFeatures' 1),
            (& $dword $cloud 'DisableWindowsSpotlightFeatures' 1)))
        (& $entry 'DisableStartMenuSuggestions' 'Disable Start menu and Settings suggestions' 'SAFE' $null @(
            (& $dword $cdm 'SubscribedContent-338388Enabled' 0),
            (& $dword $advanced 'Start_IrisRecommendations' 0 1),
            (& $dword $cdm 'SubscribedContent-338389Enabled' 0),
            (& $dword $cdm 'SubscribedContent-338393Enabled' 0),
            (& $dword $cdm 'SubscribedContent-353694Enabled' 0),
            (& $dword $cdm 'SubscribedContent-353696Enabled' 0),
            (& $dword $cdm 'SilentInstalledAppsEnabled' 0 1)))
    )
}
