# Extra Windows hardening rows as native registry entries.
# Covered by: tests/HardeningCatalog.Tests.ps1

function Test-WtIsWindows11 {
    <#
    .SYNOPSIS
        True on Windows 11 (build 22000 and later). Injectable so the OS
        filter can be exercised for both families from the tests.
    #>
    param([int]$Build = [System.Environment]::OSVersion.Version.Build)
    return ($Build -ge 22000)
}

function Get-WtHardeningRows {
    <#
    .SYNOPSIS
        The hardening setting table, one compact string per registry value:
        Id|Risk|Path[;Path]|ValueName|RegType|ValueOn|OS|CategoryKey|Off. Off:
        '-' = delete on removal, '?' = no known default (not removable),
        anything else = the Windows default written on removal. Excludes rows
        a pre-V2 catalog already owns, service-scoped rows, the bitwise WiFi
        Sense pair, EdgeHTML, and the Defender kill switch (not shipped).
    #>
    return @{
        PrivacyTelemetry = @(
            'A004|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows\System|AllowClipboardHistory|DWord|0|W10,W11|HdCatActivity|-'
            'A005|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows\System|AllowCrossDeviceClipboard|DWord|0|W10,W11|HdCatActivity|-'
            'A006|SAFE|HKCU:\Software\Microsoft\Clipboard|EnableClipboardHistory|DWord|0|W10,W11|HdCatActivity|-'
            'M005|SAFE|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager|SoftLandingEnabled|DWord|0|W10,W11|HdCatMisc|1'
            'M012|CAUTION|HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\CurrentVersion\Software Protection Platform|NoGenTicket|DWord|1|W10,W11|HdCatMisc|-'
            'M013|CAUTION|HKLM:\SOFTWARE\Policies\Microsoft\Windows\Maps|AutoDownloadAndUpdateMapData|DWord|0|W10,W11|HdCatMisc|-'
            'M014|CAUTION|HKLM:\SOFTWARE\Policies\Microsoft\Windows\Maps|AllowUntriggeredNetworkTrafficOnSettingsPage|DWord|0|W10,W11|HdCatMisc|-'
            'M023|CAUTION|HKLM:\SOFTWARE\Microsoft\PCHC|PreviousUninstall|DWord|1|W10|HdCatMisc|-'
            'M024|SAFE|HKCU:\SOFTWARE\Microsoft\MediaPlayer\Preferences|UsageTracking|DWord|0|W10,W11|HdCatMisc|-'
            'M026|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services|fAllowToGetHelp|DWord|0|W10,W11|HdCatMisc|-'
            'M027|CAUTION|HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server|fDenyTSConnections|DWord|1|W10,W11|HdCatMisc|?'
            'M028|SAFE|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel|{2cc5ca98-6485-489a-920e-b3e88a6ccce3}|DWord|1|W10,W11|HdCatMisc|-'
            'M033|SAFE|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced|Start_AccountNotifications|DWord|0|W11|HdCatMisc|1'
            'M034|SAFE|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications|EnableAccountNotifications|DWord|0|W11|HdCatMisc|1'
            'N001|ADVANCED|HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet|EnableActiveProbing|DWord|0|W10,W11|HdCatMisc|1'
            'P001|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows\TabletPC|PreventHandwritingDataSharing|DWord|1|W10,W11|HdCatPrivacy|-'
            'P002|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows\HandwritingErrorReports|PreventHandwritingErrorReports|DWord|1|W10,W11|HdCatPrivacy|-'
            'P004|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization|NoLockScreenCamera|DWord|1|W10,W11|HdCatPrivacy|-'
            'P005|SAFE|HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo|Enabled|DWord|0|W10,W11|HdCatPrivacy|1'
            'P009|ADVANCED|HKLM:\SOFTWARE\Policies\Microsoft\Biometrics|Enabled|DWord|0|W10,W11|HdCatPrivacy|-'
            'P010|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications|ToastEnabled|DWord|0|W10,W11|HdCatPrivacy|1'
            'P015|CAUTION|HKCU:\Control Panel\International\User Profile|HttpAcceptLanguageOptOut|DWord|1|W10,W11|HdCatPrivacy|-'
            'P016|ADVANCED|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost|EnableWebContentEvaluation|DWord|0|W10,W11|HdCatPrivacy|-'
            'P026|SAFE|HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Bluetooth|AllowAdvertising|DWord|0|W10,W11|HdCatPrivacy|-'
            'P028|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows\Messaging|AllowMessageSync|DWord|0|W10,W11|HdCatPrivacy|-'
            'P064|SAFE|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager|SubscribedContent-353698Enabled|DWord|0|W10,W11|HdCatPrivacy|-'
            'P068|CAUTION|HKCU:\SOFTWARE\Microsoft\TabletTip\1.7|EnableTextPrediction|DWord|0|W10,W11|HdCatPrivacy|-'
            'P069|SAFE|HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting|Disabled|DWord|1|W10,W11|HdCatPrivacy|-'
            'P070~1|SAFE|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement|ScoobeSystemSettingEnabled|DWord|0|W10,W11|HdCatPrivacy|-'
            'P070~2|SAFE|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager|SubscribedContent-310093Enabled|DWord|0|W10,W11|HdCatPrivacy|-'
            'P095|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent|DisableConsumerAccountStateContent|DWord|1|W10,W11|HdCatPrivacy|-'
            'P096|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection|LimitDumpCollection|DWord|1|W10,W11|HdCatPrivacy|-'
            'P099|CAUTION|HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer|DisableGraphRecentItems|DWord|1|W11|HdCatPrivacy|-'
            'U004|SAFE|HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy|TailoredExperiencesWithDiagnosticDataEnabled|DWord|0|W10,W11|HdCatUserBehavior|-'
            'U006|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection|LimitDiagnosticLogCollection|DWord|1|W10,W11|HdCatUserBehavior|-'
            'U008|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection|AllowDeviceNameInTelemetry|DWord|0|W10,W11|HdCatUserBehavior|-'
        )
        AppPermissions = @(
            'P007|SAFE|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeviceAccess\Global\{C1D23ACC-752B-43E5-8448-8D0E519CD6D6}|Value|String|Deny|W10|HdCatAppPrivacy|Allow'
            'P011|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeviceAccess\Global\{D89823BA-7180-4B81-B50C-7E471E6121A3}|Value|String|Deny|W10|HdCatAppPrivacy|Allow'
            'P012|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeviceAccess\Global\{E5323777-F976-4f5b-9B55-B94699C46E44}|Value|String|Deny|W10|HdCatAppPrivacy|Allow'
            'P013|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeviceAccess\Global\{2EEF81BE-33FA-4800-9670-1CD474972C3F}|Value|String|Deny|W10|HdCatAppPrivacy|Allow'
            'P014|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeviceAccess\Global\{992AFA70-6F47-4148-B3E9-3003349C1548}|Value|String|Deny|W10|HdCatAppPrivacy|Allow'
            'P018|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeviceAccess\Global\{8BC668CF-7728-45BD-93F8-CF2B3B41D7AB}|Value|String|Deny|W10|HdCatAppPrivacy|Allow'
            'P019|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userNotificationListener|Value|String|Deny|W10,W11|HdCatAppPrivacy|Allow'
            'P020|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\contacts|Value|String|Deny|W10,W11|HdCatAppPrivacy|Allow'
            'P021|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\email|Value|String|Deny|W10,W11|HdCatAppPrivacy|Allow'
            'P022|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userDataTasks|Value|String|Deny|W10,W11|HdCatAppPrivacy|Allow'
            'P023|SAFE|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\appDiagnostics|Value|String|Deny|W10,W11|HdCatAppPrivacy|Allow'
            'P024|ADVANCED|HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications|GlobalUserDisabled|DWord|1|W10,W11|HdCatAppPrivacy|0'
            'P034|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam|Value|String|Deny|W10,W11|HdCatAppPrivacy|Allow'
            'P035|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone|Value|String|Deny|W10,W11|HdCatAppPrivacy|Allow'
            'P036|SAFE|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userAccountInformation|Value|String|Deny|W10,W11|HdCatAppPrivacy|Allow'
            'P038|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\appointments|Value|String|Deny|W10,W11|HdCatAppPrivacy|Allow'
            'P039|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\phoneCallHistory|Value|String|Deny|W10,W11|HdCatAppPrivacy|Allow'
            'P042|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\chat|Value|String|Deny|W10,W11|HdCatAppPrivacy|Allow'
            'P043|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\documentsLibrary|Value|String|Deny|W10,W11|HdCatAppPrivacy|Allow'
            'P044|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\picturesLibrary|Value|String|Deny|W10,W11|HdCatAppPrivacy|Allow'
            'P045|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\videosLibrary|Value|String|Deny|W10,W11|HdCatAppPrivacy|Allow'
            'P046|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\broadFileSystemAccess|Value|String|Deny|W10,W11|HdCatAppPrivacy|Allow'
            'P049|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\activity|Value|String|Deny|W10,W11|HdCatAppPrivacy|Allow'
            'P051|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\phoneCall|Value|String|Deny|W10,W11|HdCatAppPrivacy|Allow'
            'P053|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\radios|Value|String|Deny|W10,W11|HdCatAppPrivacy|Allow'
            'P055|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\bluetoothSync|Value|String|Deny|W10,W11|HdCatAppPrivacy|Allow'
            'P057|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location|Value|String|Deny|W10,W11|HdCatAppPrivacy|Allow'
            'P059|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\cellularData|Value|String|Deny|W10,W11|HdCatAppPrivacy|Allow'
            'P060|CAUTION|HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\gazeInput|Value|String|Deny|W10,W11|HdCatAppPrivacy|Allow'
            'P061|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\gazeInput|Value|String|Deny|W10,W11|HdCatAppPrivacy|Allow'
            'P062|CAUTION|HKCU:\Software\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps|AgentActivationEnabled|DWord|0|W10,W11|HdCatAppPrivacy|1'
            'P063|CAUTION|HKCU:\Software\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps|AgentActivationOnLockScreenEnabled|DWord|0|W10,W11|HdCatAppPrivacy|1'
            'P072|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\graphicsCaptureProgrammatic|Value|String|Deny|W11|HdCatAppPrivacy|Allow'
            'P073|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\graphicsCaptureProgrammatic\NonPackaged|Value|String|Deny|W11|HdCatAppPrivacy|Allow'
            'P075|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\graphicsCaptureWithoutBorder|Value|String|Deny|W11|HdCatAppPrivacy|Allow'
            'P076|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\graphicsCaptureWithoutBorder\NonPackaged|Value|String|Deny|W11|HdCatAppPrivacy|Allow'
            'P078|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\musicLibrary|Value|String|Deny|W11|HdCatAppPrivacy|Allow'
            'P080|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\downloadsFolder|Value|String|Deny|W10,W11|HdCatAppPrivacy|Allow'
            'P081|CAUTION|HKCU:\Software\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps|AgentActivationLastUsed|DWord|0|W10,W11|HdCatAppPrivacy|1'
            'P082|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy|LetAppsAccessGenerativeAI|DWord|2|W11|HdCatAppPrivacy|-'
            'P083|SAFE|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\generativeAI|Value|String|Deny|W11|HdCatAppPrivacy|Allow'
            'P084|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy|LetAppsAccessHumanPresence|DWord|2|W11|HdCatAppPrivacy|-'
            'P085|SAFE|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\humanPresence|Value|String|Deny|W11|HdCatAppPrivacy|Allow'
            'P086|ADVANCED|HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\passkeys;HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\passkeys|Value|String|Deny|W11|HdCatAppPrivacy|Allow'
            'P087|ADVANCED|HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\bluetooth;HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\bluetooth|Value|String|Deny|W11|HdCatAppPrivacy|Allow'
            'P088|ADVANCED|HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\humanInterfaceDevice;HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\humanInterfaceDevice|Value|String|Deny|W11|HdCatAppPrivacy|Allow'
            'P089|ADVANCED|HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\passkeysEnumeration;HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\passkeysEnumeration|Value|String|Deny|W11|HdCatAppPrivacy|Allow'
            'P090|ADVANCED|HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\sensors.custom;HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\sensors.custom|Value|String|Deny|W11|HdCatAppPrivacy|Allow'
            'P091|ADVANCED|HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\serialCommunication;HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\serialCommunication|Value|String|Deny|W11|HdCatAppPrivacy|Allow'
            'P092|ADVANCED|HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\usb;HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\usb|Value|String|Deny|W11|HdCatAppPrivacy|Allow'
            'P093|ADVANCED|HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\wifiData;HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\wifiData|Value|String|Deny|W11|HdCatAppPrivacy|Allow'
            'P094|ADVANCED|HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\wiFiDirect;HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\wiFiDirect|Value|String|Deny|W11|HdCatAppPrivacy|Allow'
            'P098|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CPSS\Store\UserLocationOverridePrivacySetting|Value|DWord|0|W11|HdCatAppPrivacy|-'
            'L001~1|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors|DisableLocation|DWord|1|W10,W11|HdCatLocation|-'
            'L001~2|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors|DisableWindowsLocationProvider|DWord|1|W10,W11|HdCatLocation|-'
            'L003|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors|DisableLocationScripting|DWord|1|W10,W11|HdCatLocation|-'
            'L004|CAUTION|HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors|DisableSensors|DWord|1|W10,W11|HdCatLocation|-'
            'L005|CAUTION|HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}|SensorPermissionState|DWord|0|W10,W11|HdCatLocation|-'
            'L007|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeviceAccess\Global\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}|Value|String|Deny|W10|HdCatLocation|Allow'
            'L008|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\FindMyDevice|AllowFindMyDevice|DWord|0|W10,W11|HdCatLocation|-'
        )
        Ai = @(
            'C104|SAFE|HKCU:\SOFTWARE\Microsoft\Windows\Shell\Copilot\BingChat|IsUserEligible|DWord|0|W10,W11|HdCatAi|-'
            'C205|SAFE|HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint|DisableImageCreator|DWord|1|W11|HdCatAi|-'
            'C206|CAUTION|HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint|DisableCocreator|DWord|1|W11|HdCatAi|-'
            'C207|CAUTION|HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint|DisableGenerativeFill|DWord|1|W11|HdCatAi|-'
            'C209|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI|DisableSettingsAgent|DWord|1|W11|HdCatAi|-'
            'C210|SAFE|HKLM:\SOFTWARE\Policies\WindowsNotepad|DisableAIFeatures|DWord|1|W11|HdCatAi|-'
            'C211|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer|HideAIActionsMenu|DWord|1|W11|HdCatAi|-'
            'E128|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|HubsSidebarEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E135|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|NewTabPageBingChatEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E137|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|AIGenThemesEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E140|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|CopilotPageContext|DWord|0|W10,W11|HdCatEdge|-'
            'E145|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|Microsoft365CopilotChatIconEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E152|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|GenAILocalFoundationalModelSettings|DWord|1|W10,W11|HdCatEdge|-'
        )
        SearchUi = @(
            'C007|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search|AllowSearchToUseLocation|DWord|0|W10,W11|HdCatCortana|-'
            'C010|SAFE|HKLM:\SOFTWARE\Microsoft\Speech_OneCore\Preferences|ModelDownloadAllowed|DWord|0|W10,W11|HdCatCortana|-'
            'C011|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search|AllowCloudSearch|DWord|0|W10,W11|HdCatCortana|-'
            'C012|SAFE|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Windows Search|CortanaConsent|DWord|0|W10,W11|HdCatCortana|-'
            'C013|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization|AllowInputPersonalization|DWord|0|W10,W11|HdCatCortana|-'
            'C014|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search|AllowCortanaAboveLock|DWord|0|W10,W11|HdCatCortana|-'
            'C015|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search|EnableDynamicContentInWSB|DWord|0|W10,W11|HdCatCortana|-'
            'M006|SAFE|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager|SystemPaneSuggestionsEnabled|DWord|0|W10,W11|HdCatExplorer|1'
            'M010|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced|ShowSyncProviderNotifications|DWord|0|W10,W11|HdCatExplorer|1'
            'M011|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced|Start_TrackDocs|DWord|0|W10,W11|HdCatExplorer|1'
            'O001|ADVANCED|HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive|DisableFileSyncNGSC|DWord|1|W10,W11|HdCatExplorer|-'
            'O003|CAUTION|HKLM:\SOFTWARE\Microsoft\OneDrive|PreventNetworkTrafficPreUserSignIn|DWord|1|W10,W11|HdCatExplorer|0'
            'G001|CAUTION|HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR|AllowGameDVR|DWord|0|W10,W11|HdCatGaming|-'
            'K001|SAFE|HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager|RotatingLockScreenEnabled|DWord|0|W10,W11|HdCatLockScreen|1'
            'K002~1|SAFE|HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager|SubscribedContent-338387Enabled|DWord|0|W10,W11|HdCatLockScreen|1'
            'K002~2|SAFE|HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager|RotatingLockScreenOverlayEnabled|DWord|0|W10,W11|HdCatLockScreen|1'
            'K005~1|SAFE|HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings|NOC_GLOBAL_SETTING_ALLOW_TOASTS_ABOVE_LOCK|DWord|0|W10,W11|HdCatLockScreen|-'
            'K005~2|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows\System|DisableLockScreenAppNotifications|DWord|1|W10,W11|HdCatLockScreen|-'
            'D001|SAFE|HKCU:\Software\Microsoft\Windows\CurrentVersion\Mobility|CrossDeviceEnabled|DWord|0|W11|HdCatMobile|-'
            'D002|SAFE|HKCU:\Software\Microsoft\Windows\CurrentVersion\Mobility|PhoneLinkEnabled|DWord|0|W11|HdCatMobile|-'
            'D003|SAFE|HKCU:\Software\Microsoft\Windows\CurrentVersion\Mobility|OptedIn|DWord|0|W11|HdCatMobile|1'
            'D104|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows\System|EnableMmx|DWord|0|W10,W11|HdCatMobile|-'
            'M025|SAFE|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings|IsDynamicSearchBoxEnabled|DWord|0|W11|HdCatSearch|1'
            'M029|SAFE|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings|IsMSACloudSearchEnabled|DWord|0|W10,W11|HdCatSearch|1'
            'M030|SAFE|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings|IsAADCloudSearchEnabled|DWord|0|W10,W11|HdCatSearch|1'
            'M031|SAFE|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings|IsDeviceSearchHistoryEnabled|DWord|0|W10,W11|HdCatSearch|1'
            'M015|CAUTION|HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\People|PeopleBand|DWord|0|W10|HdCatTaskbar|1'
            'M016|CAUTION|HKCU:\Software\Microsoft\Windows\CurrentVersion\Search|SearchboxTaskbarMode|DWord|0|W10,W11|HdCatTaskbar|2'
            'M017|CAUTION|HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer|HideSCAMeetNow|DWord|1|W10|HdCatTaskbar|-'
            'M018|CAUTION|HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer|HideSCAMeetNow|DWord|1|W10|HdCatTaskbar|-'
            'M019~1|CAUTION|HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds|EnableFeeds|DWord|0|W10,W11|HdCatTaskbar|-'
            'M019~2|CAUTION|HKLM:\SOFTWARE\Policies\Microsoft\Dsh|AllowNewsAndInterests|DWord|0|W10,W11|HdCatTaskbar|-'
            'M020|CAUTION|HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds|ShellFeedsTaskbarViewMode|DWord|2|W10|HdCatTaskbar|0'
            'M021|SAFE|HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|TaskbarDa|DWord|0|W11|HdCatTaskbar|1'
        )
        Edge = @(
            'E101|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|ConfigureDoNotTrack|DWord|1|W10,W11|HdCatEdge|-'
            'E103|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|SearchSuggestEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E106|ADVANCED|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|SmartScreenEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E107|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|AddressBarMicrosoftSearchInBingProviderEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E109|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|AutofillAddressEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E111|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|UserFeedbackAllowed|DWord|0|W10,W11|HdCatEdge|-'
            'E112|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|AutofillCreditCardEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E115|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|PaymentMethodQueryEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E116|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|SendSiteInfoToImproveServices|DWord|0|W10,W11|HdCatEdge|-'
            'E117|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|MetricsReportingEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E118|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|PersonalizationReportingEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E119|CAUTION|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|ResolveNavigationErrorsUseWebService|DWord|0|W10,W11|HdCatEdge|-'
            'E120|CAUTION|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|AlternateErrorPagesEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E121|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|LocalProvidersEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E122|CAUTION|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|NetworkPredictionOptions|DWord|2|W10,W11|HdCatEdge|-'
            'E123|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|EdgeShoppingAssistantEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E124|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|WebWidgetAllowed|DWord|0|W10,W11|HdCatEdge|-'
            'E125|CAUTION|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|PasswordManagerEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E126|CAUTION|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|SiteSafetyServicesEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E127|ADVANCED|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|TyposquattingCheckerEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E129|CAUTION|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|BrowserSignin|DWord|0|W10,W11|HdCatEdge|-'
            'E130|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|MicrosoftEditorProofingEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E131|CAUTION|HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Ext\CLSID|{1FD49718-1D00-4B19-AF5F-070AF6D5D54C}|String|0|W10|HdCatEdge|-'
            'E132|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|HideFirstRunExperience|DWord|1|W10,W11|HdCatEdge|-'
            'E133|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|SpotlightExperiencesAndRecommendationsEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E134|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|WebToBrowserSignInEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E136|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|NewTabPageContentEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E138|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|BuiltInAIAPIsEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E139|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|ComposeInlineEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E141|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|DefaultBrowserSettingEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E142|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|DefaultBrowserSettingsCampaignEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E143|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|DiagnosticData|DWord|0|W10,W11|HdCatEdge|-'
            'E146|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|ShowMicrosoftRewards|DWord|0|W10,W11|HdCatEdge|-'
            'E147|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|ShowRecommendationsEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E148|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|TabServicesEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E149|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|TextPredictionEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E150|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|VisualSearchEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E151|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|EdgeHistoryAISearchEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E153|CAUTION|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|StartupBoostEnabled|DWord|0|W10,W11|HdCatEdge|-'
            'E154|CAUTION|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|NewTabPageHideDefaultTopSites|DWord|1|W10,W11|HdCatEdge|-'
            'E155|CAUTION|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|ShowAcrobatSubscriptionButton|DWord|0|W10,W11|HdCatEdge|-'
            'E156|SAFE|HKCU:\SOFTWARE\Policies\Microsoft\Edge;HKLM:\SOFTWARE\Policies\Microsoft\Edge|EdgeSecureNetworkEnabled|DWord|0|W10,W11|HdCatEdge|-'
        )
        Office = @(
            'F001|SAFE|HKCU:\Software\Microsoft\Office\16.0\Common\MailSettings|InlineTextPrediction|DWord|0|W10,W11|HdCatOffice|-'
            'F002|SAFE|HKCU:\Software\Policies\Microsoft\Office\Common\ClientTelemetry|DisableTelemetry|DWord|1|W10,W11|HdCatOffice|-'
            'F003|SAFE|HKCU:\Software\Policies\Microsoft\Office\16.0\OSM|EnableLogging|DWord|0|W10,W11|HdCatOffice|-'
            'F004|SAFE|HKCU:\Software\Policies\Microsoft\Office\16.0\OSM|EnableUpload|DWord|0|W10,W11|HdCatOffice|-'
            'F005|SAFE|HKCU:\Software\Policies\Microsoft\Office\16.0\OSM|EnableFileObfuscation|DWord|1|W10,W11|HdCatOffice|-'
            'F006|CAUTION|HKCU:\Software\Policies\Microsoft\Office\16.0\Common|UpdateReliabilityData|DWord|0|W10,W11|HdCatOffice|-'
            'F007|SAFE|HKCU:\Software\Policies\Microsoft\Office\16.0\Common\Feedback|SurveyEnabled|DWord|0|W10,W11|HdCatOffice|-'
            'F008|SAFE|HKCU:\Software\Policies\Microsoft\Office\16.0\Common\Feedback|Enabled|DWord|0|W10,W11|HdCatOffice|-'
            'F009|SAFE|HKCU:\Software\Policies\Microsoft\Office\16.0\Common\Feedback|IncludeEmail|DWord|0|W10,W11|HdCatOffice|-'
            'F010|CAUTION|HKCU:\Software\Policies\Microsoft\Office\16.0\Common\Privacy|DisconnectedState|DWord|2|W10,W11|HdCatOffice|-'
            'F011|CAUTION|HKCU:\Software\Policies\Microsoft\Office\16.0\Common\Privacy|UserContentDisabled|DWord|2|W10,W11|HdCatOffice|-'
            'F012|CAUTION|HKCU:\Software\Policies\Microsoft\Office\16.0\Common\Privacy|DownloadContentDisabled|DWord|2|W10,W11|HdCatOffice|-'
            'F013|CAUTION|HKCU:\Software\Policies\Microsoft\Office\16.0\Common\Privacy|ControllerConnectedServicesEnabled|DWord|2|W10,W11|HdCatOffice|-'
            'F014|SAFE|HKCU:\Software\Policies\Microsoft\Office\Common\ClientTelemetry|SendTelemetry|DWord|3|W10,W11|HdCatOffice|-'
            'F015|SAFE|HKCU:\Software\Policies\Microsoft\Office\16.0\Common|QMEnable|DWord|0|W10,W11|HdCatOffice|-'
            'F016|SAFE|HKCU:\Software\Policies\Microsoft\Office\16.0\Common|LinkedIn|DWord|0|W10,W11|HdCatOffice|-'
            'F019|SAFE|HKCU:\Software\Policies\Microsoft\Office\16.0\Common\General|ShownFirstRunOptin|DWord|1|W10,W11|HdCatOffice|-'
            'F020|SAFE|HKCU:\Software\Policies\Microsoft\Office\16.0\FirstRun|disablemovie|DWord|1|W10,W11|HdCatOffice|-'
            'F021|ADVANCED|HKCU:\Software\Policies\Microsoft\Office\16.0\Common\SignIn|SignInOptions|DWord|3|W10,W11|HdCatOffice|-'
            'Y001|SAFE|HKCU:\Software\Microsoft\Windows\CurrentVersion\SettingSync|SyncPolicy|DWord|5|W10,W11|HdCatSync|1'
            'Y002|SAFE|HKCU:\Software\Microsoft\Windows\CurrentVersion\SettingSync\Groups\Personalization|Enabled|DWord|0|W10,W11|HdCatSync|1'
            'Y003|SAFE|HKCU:\Software\Microsoft\Windows\CurrentVersion\SettingSync\Groups\BrowserSettings|Enabled|DWord|0|W10,W11|HdCatSync|1'
            'Y004|SAFE|HKCU:\Software\Microsoft\Windows\CurrentVersion\SettingSync\Groups\Credentials|Enabled|DWord|0|W10,W11|HdCatSync|1'
            'Y005|SAFE|HKCU:\Software\Microsoft\Windows\CurrentVersion\SettingSync\Groups\Language|Enabled|DWord|0|W10,W11|HdCatSync|1'
            'Y006|SAFE|HKCU:\Software\Microsoft\Windows\CurrentVersion\SettingSync\Groups\Accessibility|Enabled|DWord|0|W10,W11|HdCatSync|1'
            'Y007|SAFE|HKCU:\Software\Microsoft\Windows\CurrentVersion\SettingSync\Groups\Windows|Enabled|DWord|0|W10,W11|HdCatSync|1'
        )
        Update = @(
            'P017~1|CAUTION|HKLM:\SOFTWARE\Policies\Microsoft\Windows\PreviewBuilds|EnableConfigFlighting|DWord|0|W10,W11|HdCatUpdate|-'
            'P017~2|CAUTION|HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\System|AllowExperimentation|DWord|0|W10,W11|HdCatUpdate|-'
            'P017~3|CAUTION|HKLM:\SOFTWARE\Policies\Microsoft\Windows\PreviewBuilds|EnableExperimentation|DWord|0|W10,W11|HdCatUpdate|-'
            'W001~1|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization|DODownloadMode|DWord|0|W10,W11|HdCatUpdate|-'
            'W001~2|SAFE|HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config|DODownloadMode|DWord|0|W10,W11|HdCatUpdate|-'
            'W001~3|SAFE|HKCU:\Software\Microsoft\Windows\CurrentVersion\DeliveryOptimization|SystemSettingsDownloadMode|DWord|0|W10,W11|HdCatUpdate|-'
            'W004~1|CAUTION|HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate|DeferUpgrade|DWord|1|W10,W11|HdCatUpdate|-'
            'W004~2|CAUTION|HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate|DeferFeatureUpdates|DWord|1|W10,W11|HdCatUpdate|-'
            'W004~3|CAUTION|HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate|DeferFeatureUpdatesPeriodInDays|DWord|365|W10,W11|HdCatUpdate|-'
            'W005~1|CAUTION|HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata|PreventDeviceMetadataFromNetwork|DWord|1|W10,W11|HdCatUpdate|-'
            'W005~2|CAUTION|HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata|PreventDeviceMetadataFromNetwork|DWord|1|W10,W11|HdCatUpdate|0'
            'W006|ADVANCED|HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU|NoAutoUpdate|DWord|1|W10,W11|HdCatUpdate|-'
            'W008|ADVANCED|HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU|AllowMUUpdateService|DWord|0|W10,W11|HdCatUpdate|-'
            'W009~1|CAUTION|HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore|AutoDownload|DWord|2|W10,W11|HdCatUpdate|-'
            'W009~2|CAUTION|HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate|AutoDownload|DWord|2|W10,W11|HdCatUpdate|4'
            'W010~1|CAUTION|HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate|ExcludeWUDriversInQualityUpdate|DWord|1|W10,W11|HdCatUpdate|-'
            'W010~2|CAUTION|HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings|ExcludeWUDriversInQualityUpdate|DWord|1|W10,W11|HdCatUpdate|-'
            'W010~3|CAUTION|HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching|SearchOrderConfig|DWord|0|W10,W11|HdCatUpdate|1'
            'W011|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Speech|AllowSpeechModelUpdate|DWord|0|W10,W11|HdCatUpdate|-'
            'W012|CAUTION|HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate|AllowOptionalContent|DWord|0|W10,W11|HdCatUpdate|-'
        )
        Security = @(
            'S012|CAUTION|HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet|SpynetReporting|DWord|0|W10,W11|HdCatDefender|-'
            'S013|CAUTION|HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet|SubmitSamplesConsent|DWord|2|W10,W11|HdCatDefender|-'
            'S014|CAUTION|HKLM:\SOFTWARE\Policies\Microsoft\MRT|DontReportInfectionInformation|DWord|1|W10,W11|HdCatDefender|-'
            'S001|SAFE|HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredUI|DisablePasswordReveal|DWord|1|W10,W11|HdCatSecurity|-'
            'S003|SAFE|HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\AutoLogger-Diagtrack-Listener|Start|DWord|0|W10,W11|HdCatSecurity|1'
            'S008|CAUTION|HKLM:\SOFTWARE\Policies\Microsoft\WMDRM|DisableOnline|DWord|1|W10,W11|HdCatSecurity|-'
            'S009|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeviceAccess\Global\{A8804298-2D5F-42E3-9531-9C8C39EB29CE}|Value|String|Deny|W10|HdCatSecurity|Allow'
            'S010|CAUTION|HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeviceAccess\Global\LooselyCoupled|Value|String|Deny|W10|HdCatSecurity|Allow'
            'S015|SAFE|HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\config|AutoConnectAllowedOEM|DWord|0|W10|HdCatSecurity|-'
            'S117|CAUTION|HKLM:\SOFTWARE\Policies\Microsoft\Windows\Connect|AllowProjectionToPC|DWord|0|W10,W11|HdCatSecurity|-'
            'S120|ADVANCED|HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Connectivity\AllowBluetooth|value|DWord|0|W10,W11|HdCatSecurity|-'
        )
    }
}

function ConvertFrom-WtHardeningRows {
    <#
    .SYNOPSIS
        Rows -> RegistryChanges-shaped entries. Rows sharing a base id
        (P067~1, P067~2) become ONE entry with several changes; a
        multi-path row writes the same value under every path. Format:
        Id|Risk|Path[;Path]|ValueName|RegType|ValueOn|OS|CategoryKey|Off,
        where Off is '-' (delete), '?' (no default), or the Windows default.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Rows)
    $entries = New-Object System.Collections.Generic.List[object]
    $byId = @{}
    foreach ($row in $Rows) {
        $p = $row -split '\|'
        if ($p.Count -ne 9) { throw "Hardening row must have 9 fields: $row" }
        $baseId = ($p[0] -split '~')[0]
        $regType = $p[4]
        $value = switch ($regType) {
            'DWord' { [int]$p[5] }
            'QWord' { [long]$p[5] }
            default { [string]$p[5] }
        }
        $offField = $p[8]
        $offAction = 'Set'
        $offValue = $null
        if ($offField -eq '-') { $offAction = 'Delete' }
        elseif ($offField -eq '?') { $offAction = 'None' }
        else {
            $offValue = switch ($regType) {
                'DWord' { [int]$offField }
                'QWord' { [long]$offField }
                default { [string]$offField }
            }
        }
        if (-not $byId.ContainsKey($baseId)) {
            $entry = [PSCustomObject]@{
                Name            = 'HD_' + $baseId
                Risk            = $p[1]
                Os              = [string[]]($p[6] -split ',')
                Category        = $p[7]
                LabelKey        = 'CatHardening' + $baseId + 'Label'
                ConsequenceKey  = 'CatHardening' + $baseId + 'Consequence'
                DisplayLabel    = $baseId
                Consequence     = $null
                RegistryChanges = (New-Object System.Collections.Generic.List[object])
            }
            $byId[$baseId] = $entry
            $entries.Add($entry)
        }
        foreach ($path in ($p[2] -split ';')) {
            $byId[$baseId].RegistryChanges.Add([PSCustomObject]@{ Path = $path.Trim(); Name = $p[3]; RegType = $regType; Value = $value; OffAction = $offAction; OffValue = $offValue })
        }
    }
    foreach ($e in $entries) { $e.RegistryChanges = $e.RegistryChanges.ToArray() }
    return $entries.ToArray()
}

function Get-WtRegistryChangeKeys {
    <#
    .SYNOPSIS
        Every "<path>|<name>" a catalog writes, lower-cased, so two
        catalogs can be compared for the same registry value. Entries
        without RegistryChanges (prose-only catalogs) contribute nothing.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Catalog)
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($e in $Catalog) {
        if (-not ($e.PSObject.Properties.Name -contains 'RegistryChanges')) { continue }
        foreach ($c in @($e.RegistryChanges)) { $keys.Add(((([string]$c.Path) + '|' + ([string]$c.Name)).ToLowerInvariant())) }
    }
    return [string[]]$keys.ToArray()
}

$script:WtExistingRegistryKeysCache = $null

function Get-WtExistingRegistryKeys {
    <#
    .SYNOPSIS
        path|name keys already owned by the pre-V2 registry catalogs (their
        Names are frozen undo/profile keys, so a hardening twin is dropped,
        never the original) plus the 25 ConsentStore capability defaults.
        Built once per session: nothing in it depends on the machine or
        the language.
    #>
    if ($null -ne $script:WtExistingRegistryKeysCache) { return [string[]]$script:WtExistingRegistryKeysCache }
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($catalog in @((Get-WtAiPrivacyCatalog), (Get-WtTelemetryCatalog), (Get-WtActivityAdvertisingCatalog), (Get-WtSearchSuggestionsCatalog), (Get-WtGamingTweakCatalog), (Get-WtExplorerViewCatalog))) {
        foreach ($k in @(Get-WtRegistryChangeKeys -Catalog @($catalog))) { $keys.Add($k) }
    }
    foreach ($cap in @(Get-WtAppPermissionCatalog)) {
        $keys.Add(('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\' + $cap.Name + '|Value').ToLowerInvariant())
    }
    $script:WtExistingRegistryKeysCache = [string[]]($keys | Select-Object -Unique)
    return [string[]]$script:WtExistingRegistryKeysCache
}

$script:WtHardeningCatalogCache = @{}

function Get-WtHardeningCatalog {
    <#
    .SYNOPSIS
        One screen group's entries: OS-filtered for this machine, minus
        entries that touch a path|name an existing catalog already owns,
        localized through Resolve-WtCatalogText (explicit LabelKey /
        ConsequenceKey per entry). An unknown group name yields an empty
        catalog rather than a parameter-binding error. Remembered for the
        session per group, OS family and language (see the cache above).
    #>
    param(
        [Parameter(Mandatory)][string]$Group,
        [bool]$IsWindows11 = (Test-WtIsWindows11),
        [AllowEmptyCollection()][string[]]$ExcludeKeys = (Get-WtExistingRegistryKeys),
        [AllowEmptyCollection()][string[]]$Rows = @((Get-WtHardeningRows)[$Group] | Where-Object { $_ })
    )
    $osTag = if ($IsWindows11) { 'W11' } else { 'W10' }
    $remember = -not ($PSBoundParameters.ContainsKey('ExcludeKeys') -or $PSBoundParameters.ContainsKey('Rows'))
    $cacheKey = $Group + '|' + $osTag + '|' + [string]$script:Language
    if ($remember -and $script:WtHardeningCatalogCache.ContainsKey($cacheKey)) { return @($script:WtHardeningCatalogCache[$cacheKey]) }
    $exclude = @{}
    foreach ($k in $ExcludeKeys) { $exclude[$k] = $true }
    $kept = New-Object System.Collections.Generic.List[object]
    foreach ($e in @(ConvertFrom-WtHardeningRows -Rows $Rows)) {
        if ($e.Os -notcontains $osTag) { continue }
        $dup = $false
        foreach ($k in @(Get-WtRegistryChangeKeys -Catalog @($e))) { if ($exclude.ContainsKey($k)) { $dup = $true; break } }
        if (-not $dup) { $kept.Add($e) }
    }
    $result = @(Resolve-WtCatalogText -Catalog $kept.ToArray())
    if ($remember) { $script:WtHardeningCatalogCache[$cacheKey] = $result }
    return $result
}
