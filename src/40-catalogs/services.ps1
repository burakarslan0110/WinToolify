# Service catalog and live state.
# Covered by: tests/Catalog.Tests.ps1

$script:WtServiceCatalogCache = @{}

function Get-WtServiceCatalog {
    <#
    .SYNOPSIS
        The individually-selectable Services catalog: Windows services
        each tagged SAFE / CAUTION / ADVANCED with a one-line consequence
        above SAFE and a localized "<Name> - <description>" DisplayLabel.
        BcastDVRUserService, CaptureService and PenService are stored as
        per-account template names (IsPerUser = $true), since Windows
        appends a per-account LUID suffix to these three that a
        hardcoded suffix would only ever match on one machine;
        Get-WtServiceState resolves the live instance by prefix. Cached
        per language for the session; callers get copies so the
        CycleTargets a screen pins on its rows never leaks into another
        caller's catalog.
    #>
    $lang = [string]$script:Language
    if ($script:WtServiceCatalogCache.ContainsKey($lang)) { return @($script:WtServiceCatalogCache[$lang] | ForEach-Object { $_.PSObject.Copy() }) }
    $built = @(Resolve-WtCatalogText -KeyPrefix 'Service' -Catalog @(
        [PSCustomObject]@{ Name = 'DiagTrack'; Risk = 'SAFE'; Consequence = $null; IsPerUser = $false; DisplayLabel = 'DiagTrack - Connected User Experiences and Telemetry' }
        [PSCustomObject]@{ Name = 'MapsBroker'; Risk = 'SAFE'; Consequence = $null; IsPerUser = $false; DisplayLabel = 'MapsBroker - Downloaded maps manager' }
        [PSCustomObject]@{ Name = 'NetTcpPortSharing'; Risk = 'SAFE'; Consequence = $null; IsPerUser = $false; DisplayLabel = 'NetTcpPortSharing - Net.Tcp port sharing (off by default)' }
        [PSCustomObject]@{ Name = 'RemoteAccess'; Risk = 'SAFE'; Consequence = $null; IsPerUser = $false; DisplayLabel = 'RemoteAccess - Routing and Remote Access (VPN/ICS host)' }
        [PSCustomObject]@{ Name = 'RemoteRegistry'; Risk = 'SAFE'; Consequence = $null; IsPerUser = $false; DisplayLabel = 'RemoteRegistry - Remote registry access' }
        [PSCustomObject]@{ Name = 'TrkWks'; Risk = 'SAFE'; Consequence = $null; IsPerUser = $false; DisplayLabel = 'TrkWks - Distributed Link Tracking Client' }
        [PSCustomObject]@{ Name = 'WMPNetworkSvc'; Risk = 'SAFE'; Consequence = $null; IsPerUser = $false; DisplayLabel = 'WMPNetworkSvc - Windows Media Player network sharing (DLNA)' }
        [PSCustomObject]@{ Name = 'WerSvc'; Risk = 'SAFE'; Consequence = $null; IsPerUser = $false; DisplayLabel = 'WerSvc - Windows Error Reporting' }
        [PSCustomObject]@{ Name = 'Fax'; Risk = 'SAFE'; Consequence = $null; IsPerUser = $false; DisplayLabel = 'Fax - Fax service' }
        [PSCustomObject]@{ Name = 'AJRouter'; Risk = 'SAFE'; Consequence = $null; IsPerUser = $false; DisplayLabel = 'AJRouter - AllJoyn Router (retired protocol)' }
        [PSCustomObject]@{ Name = 'PhoneSvc'; Risk = 'SAFE'; Consequence = $null; IsPerUser = $false; DisplayLabel = 'PhoneSvc - Phone calls and Phone Link service' }
        [PSCustomObject]@{ Name = 'wisvc'; Risk = 'SAFE'; Consequence = $null; IsPerUser = $false; DisplayLabel = 'wisvc - Windows Insider Service' }
        [PSCustomObject]@{ Name = 'RetailDemo'; Risk = 'SAFE'; Consequence = $null; IsPerUser = $false; DisplayLabel = 'RetailDemo - Retail Demo Mode' }
        [PSCustomObject]@{ Name = 'BcastDVRUserService'; Risk = 'SAFE'; Consequence = $null; IsPerUser = $true; DisplayLabel = 'BcastDVRUserService - Game DVR background recording' }

        [PSCustomObject]@{ Name = 'lfsvc'; Risk = 'CAUTION'; Consequence = 'Location-based features (Find My Device, weather, maps) stop working'; IsPerUser = $false; DisplayLabel = 'lfsvc - Geolocation service' }
        [PSCustomObject]@{ Name = 'SharedAccess'; Risk = 'CAUTION'; Consequence = 'Mobile hotspot and internet connection sharing stop working'; IsPerUser = $false; DisplayLabel = 'SharedAccess - Internet Connection Sharing / mobile hotspot' }
        [PSCustomObject]@{ Name = 'Spooler'; Risk = 'CAUTION'; Consequence = 'Printing stops; the printer tools in Actions fail'; IsPerUser = $false; DisplayLabel = 'Spooler - Print Spooler' }
        [PSCustomObject]@{ Name = 'fhsvc'; Risk = 'CAUTION'; Consequence = 'File History backups stop running'; IsPerUser = $false; DisplayLabel = 'fhsvc - File History backups' }
        [PSCustomObject]@{ Name = 'stisvc'; Risk = 'CAUTION'; Consequence = 'Scanners and camera import stop'; IsPerUser = $false; DisplayLabel = 'stisvc - Windows Image Acquisition (scanners/cameras)' }
        [PSCustomObject]@{ Name = 'PcaSvc'; Risk = 'CAUTION'; Consequence = 'Compatibility warnings/fixes for older programs stop being applied'; IsPerUser = $false; DisplayLabel = 'PcaSvc - Program Compatibility Assistant' }
        [PSCustomObject]@{ Name = 'WPDBusEnum'; Risk = 'CAUTION'; Consequence = 'MTP phones and cameras no longer mount'; IsPerUser = $false; DisplayLabel = 'WPDBusEnum - Portable device enumerator (MTP phones/cameras)' }
        [PSCustomObject]@{ Name = 'PenService'; Risk = 'CAUTION'; Consequence = 'Pen and stylus input stops working'; IsPerUser = $true; DisplayLabel = 'PenService - Pen and stylus input' }
        [PSCustomObject]@{ Name = 'SensorDataService'; Risk = 'CAUTION'; Consequence = 'Ambient light/accelerometer-based features (auto-brightness, auto-rotate) stop working'; IsPerUser = $false; DisplayLabel = 'SensorDataService - Sensor data (auto-rotate, ambient light)' }
        [PSCustomObject]@{ Name = 'SEMgrSvc'; Risk = 'CAUTION'; Consequence = 'Tap-to-pay and NFC secure-element features stop working'; IsPerUser = $false; DisplayLabel = 'SEMgrSvc - Payments / NFC secure element manager' }
        [PSCustomObject]@{ Name = 'WpcMonSvc'; Risk = 'CAUTION'; Consequence = 'Family Safety activity monitoring stops'; IsPerUser = $false; DisplayLabel = 'WpcMonSvc - Family Safety activity monitoring' }
        [PSCustomObject]@{ Name = 'dmwappushservice'; Risk = 'CAUTION'; Consequence = 'Intune/MDM enrollment breaks on managed devices'; IsPerUser = $false; DisplayLabel = 'dmwappushservice - WAP push routing (Intune/MDM)' }
        [PSCustomObject]@{ Name = 'CaptureService'; Risk = 'CAUTION'; Consequence = 'Snipping Tool, Game Bar and Teams/Discord screen sharing stop'; IsPerUser = $true; DisplayLabel = 'CaptureService - Snipping Tool / Game Bar screen capture' }
        [PSCustomObject]@{ Name = 'MSDTC'; Risk = 'CAUTION'; Consequence = 'SQL Server / MSMQ transactional apps break'; IsPerUser = $false; DisplayLabel = 'MSDTC - Distributed Transaction Coordinator' }
        [PSCustomObject]@{ Name = 'XblAuthManager'; Risk = 'CAUTION'; Consequence = 'Xbox app, Game Pass sign-in, cloud saves, multiplayer or Xbox accessories stop working'; IsPerUser = $false; DisplayLabel = 'XblAuthManager - Xbox Live sign-in' }
        [PSCustomObject]@{ Name = 'XblGameSave'; Risk = 'CAUTION'; Consequence = 'Xbox app, Game Pass sign-in, cloud saves, multiplayer or Xbox accessories stop working'; IsPerUser = $false; DisplayLabel = 'XblGameSave - Xbox Live game save sync' }
        [PSCustomObject]@{ Name = 'XboxNetApiSvc'; Risk = 'CAUTION'; Consequence = 'Xbox app, Game Pass sign-in, cloud saves, multiplayer or Xbox accessories stop working'; IsPerUser = $false; DisplayLabel = 'XboxNetApiSvc - Xbox Live networking (multiplayer)' }
        [PSCustomObject]@{ Name = 'XboxGipSvc'; Risk = 'CAUTION'; Consequence = 'Xbox app, Game Pass sign-in, cloud saves, multiplayer or Xbox accessories stop working'; IsPerUser = $false; DisplayLabel = 'XboxGipSvc - Xbox controller/accessory management' }

        [PSCustomObject]@{ Name = 'SCardSvr'; Risk = 'ADVANCED'; Consequence = 'Smart card login and smart-card-based authentication stop working'; IsPerUser = $false; DisplayLabel = 'SCardSvr - Smart Card service' }
        [PSCustomObject]@{ Name = 'SCPolicySvc'; Risk = 'ADVANCED'; Consequence = 'Smart card removal lock/logoff policy stops enforcing'; IsPerUser = $false; DisplayLabel = 'SCPolicySvc - Smart card removal policy' }
        [PSCustomObject]@{ Name = 'ScDeviceEnum'; Risk = 'ADVANCED'; Consequence = 'Windows stops detecting Plug and Play smart card readers'; IsPerUser = $false; DisplayLabel = 'ScDeviceEnum - Smart card reader enumeration' }
        [PSCustomObject]@{ Name = 'EntAppSvc'; Risk = 'ADVANCED'; Consequence = 'Enterprise-managed app provisioning/removal via MDM stops working'; IsPerUser = $false; DisplayLabel = 'EntAppSvc - Enterprise App Management (MDM)' }
        [PSCustomObject]@{ Name = 'BDESVC'; Risk = 'ADVANCED'; Consequence = 'BitLocker unlock and key management UI break (Windows 11 24H2 encrypts by default)'; IsPerUser = $false; DisplayLabel = 'BDESVC - BitLocker Drive Encryption Service' }
        [PSCustomObject]@{ Name = 'tapisrv'; Risk = 'ADVANCED'; Consequence = 'Modem/VoIP/fax telephony APIs used by dial-up and some VPN clients stop working'; IsPerUser = $false; DisplayLabel = 'tapisrv - Telephony API (modem/VoIP/dial-up)' }
        [PSCustomObject]@{ Name = 'SysMain'; Risk = 'ADVANCED'; Consequence = 'Superfetch/prefetch off: slower cold starts on HDDs, little effect on SSDs'; IsPerUser = $false; DisplayLabel = 'SysMain - Superfetch/prefetch caching' }
        [PSCustomObject]@{ Name = 'WSearch'; Risk = 'ADVANCED'; Consequence = 'Start menu, Explorer and Outlook search stop working'; IsPerUser = $false; DisplayLabel = 'WSearch - Windows Search indexer' }
        [PSCustomObject]@{ Name = 'FontCache'; Risk = 'ADVANCED'; Consequence = 'Text rendering gets slower; some apps glitch'; IsPerUser = $false; DisplayLabel = 'FontCache - Windows font cache' }
        [PSCustomObject]@{ Name = 'DoSvc'; Risk = 'ADVANCED'; Consequence = 'Windows Update and Store downloads can stall'; IsPerUser = $false; DisplayLabel = 'DoSvc - Delivery Optimization (peer-to-peer updates)' }
        [PSCustomObject]@{ Name = 'WbioSrvc'; Risk = 'ADVANCED'; Consequence = 'Windows Hello fingerprint/face sign-in stops'; IsPerUser = $false; DisplayLabel = 'WbioSrvc - Windows Hello biometrics (fingerprint/face)' }
    ))
    $script:WtServiceCatalogCache[$lang] = $built
    return @($built | ForEach-Object { $_.PSObject.Copy() })
}

function Get-WtServiceState {
    <#
    .SYNOPSIS
        Live state of a catalog service. For a per-user template, resolves
        the actual live instance by prefix ("<Template>_<suffix>") rather
        than the literal template name, since Windows appends a per-account
        LUID suffix to these services.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [bool]$IsPerUser = $false,

        [scriptblock]$GetServiceAction = { Get-Service -ErrorAction SilentlyContinue }
    )

    $allServices = & $GetServiceAction

    if ($IsPerUser) {
        $svc = $allServices | Where-Object { $_.Name -like "${Name}_*" } | Select-Object -First 1
    }
    else {
        $svc = $allServices | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    }

    if (-not $svc) {
        return [PSCustomObject]@{ Name = $Name; Present = $false; Status = $null; StartType = $null }
    }

    return [PSCustomObject]@{ Name = $svc.Name; Present = $true; Status = [string]$svc.Status; StartType = [string]$svc.StartType }
}
