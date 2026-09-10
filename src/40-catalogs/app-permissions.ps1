# App permission catalog and state.
# Covered by: tests/AiAndPermissionCatalogs.Tests.ps1

function Get-WtAppPermissionCatalog {
    <#
    .SYNOPSIS
        The individually-selectable app-permission capability-defaults
        catalog: 25 CapabilityAccessManager\ConsentStore capabilities,
        each with a friendly DisplayLabel. 17 are
        SAFE; the 8 library/broad-file-access/screen-capture capabilities
        are CAUTION (denying them can break apps that need broad access to
        a media library, the file system, or the screen). Nothing here is
        ADVANCED.
    #>
    return Resolve-WtCatalogText -KeyPrefix 'AppPermission' -Catalog @(
        [PSCustomObject]@{ Name = 'location'; DisplayLabel = 'Location'; Risk = 'SAFE'; Consequence = $null }
        [PSCustomObject]@{ Name = 'webcam'; DisplayLabel = 'Camera'; Risk = 'SAFE'; Consequence = $null }
        [PSCustomObject]@{ Name = 'microphone'; DisplayLabel = 'Microphone'; Risk = 'SAFE'; Consequence = $null }
        [PSCustomObject]@{ Name = 'userNotificationListener'; DisplayLabel = 'Notifications'; Risk = 'SAFE'; Consequence = $null }
        [PSCustomObject]@{ Name = 'userAccountInformation'; DisplayLabel = 'Account Info'; Risk = 'SAFE'; Consequence = $null }
        [PSCustomObject]@{ Name = 'appDiagnostics'; DisplayLabel = 'App Diagnostics'; Risk = 'SAFE'; Consequence = $null }
        [PSCustomObject]@{ Name = 'contacts'; DisplayLabel = 'Contacts'; Risk = 'SAFE'; Consequence = $null }
        [PSCustomObject]@{ Name = 'appointments'; DisplayLabel = 'Calendar'; Risk = 'SAFE'; Consequence = $null }
        [PSCustomObject]@{ Name = 'email'; DisplayLabel = 'Email'; Risk = 'SAFE'; Consequence = $null }
        [PSCustomObject]@{ Name = 'chat'; DisplayLabel = 'Messaging'; Risk = 'SAFE'; Consequence = $null }
        [PSCustomObject]@{ Name = 'phoneCall'; DisplayLabel = 'Phone Calls'; Risk = 'SAFE'; Consequence = $null }
        [PSCustomObject]@{ Name = 'phoneCallHistory'; DisplayLabel = 'Call History'; Risk = 'SAFE'; Consequence = $null }
        [PSCustomObject]@{ Name = 'userDataTasks'; DisplayLabel = 'Tasks'; Risk = 'SAFE'; Consequence = $null }
        [PSCustomObject]@{ Name = 'activity'; DisplayLabel = 'Activity History'; Risk = 'SAFE'; Consequence = $null }
        [PSCustomObject]@{ Name = 'bluetoothSync'; DisplayLabel = 'Other Devices (Bluetooth Sync)'; Risk = 'SAFE'; Consequence = $null }
        [PSCustomObject]@{ Name = 'radios'; DisplayLabel = 'Radios'; Risk = 'SAFE'; Consequence = $null }
        [PSCustomObject]@{ Name = 'cellularData'; DisplayLabel = 'Cellular Data'; Risk = 'SAFE'; Consequence = $null }
        [PSCustomObject]@{ Name = 'documentsLibrary'; DisplayLabel = 'Documents Library'; Risk = 'CAUTION'; Consequence = 'Apps that need broad access to your Documents folder (backup tools, some editors) may stop working' }
        [PSCustomObject]@{ Name = 'picturesLibrary'; DisplayLabel = 'Pictures Library'; Risk = 'CAUTION'; Consequence = 'Apps needing broad access to your Pictures folder (Photos imports, some editors) may stop working' }
        [PSCustomObject]@{ Name = 'videosLibrary'; DisplayLabel = 'Videos Library'; Risk = 'CAUTION'; Consequence = 'Apps needing broad access to your Videos folder (Movies & TV imports, some editors) may stop working' }
        [PSCustomObject]@{ Name = 'musicLibrary'; DisplayLabel = 'Music Library'; Risk = 'CAUTION'; Consequence = 'Apps needing broad access to your Music folder (media players) may stop working' }
        [PSCustomObject]@{ Name = 'downloadsFolder'; DisplayLabel = 'Downloads Folder'; Risk = 'CAUTION'; Consequence = 'Apps needing broad access to your Downloads folder may stop working' }
        [PSCustomObject]@{ Name = 'broadFileSystemAccess'; DisplayLabel = 'File System (Broad Access)'; Risk = 'CAUTION'; Consequence = 'Apps needing full file-system access (some backup, sync, and antivirus tools) may stop working' }
        [PSCustomObject]@{ Name = 'graphicsCaptureProgrammatic'; DisplayLabel = 'Screen Capture (Apps)'; Risk = 'CAUTION'; Consequence = 'Xbox Game Bar, screen recording, and remote-support tools that capture your screen may stop working' }
        [PSCustomObject]@{ Name = 'graphicsCaptureWithoutBorder'; DisplayLabel = 'Screen Capture (No Border)'; Risk = 'CAUTION'; Consequence = 'Borderless screen-capture used by some recording/remote-support tools may stop working' }
    )
}

function Get-WtAppPermissionState {
    <#
    .SYNOPSIS
        Live state of one capability's global default: Applied only for a
        Value of exactly 'Deny'. A missing key, a missing value, and
        'Allow' all collapse to NotApplied - this catalog is not
        attempting Windows' own tri-state Settings UI.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Capability,

        [scriptblock]$GetPropertyAction = {
            param($p, $n)
            Get-WtRegistryProperty -Path $p -Name $n
        }
    )

    $path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$Capability"
    $current = Get-WtRegistryValue -Path $path -Name 'Value' -GetPropertyAction $GetPropertyAction
    return [PSCustomObject]@{ Applied = ($current.Present -and $current.Value -eq 'Deny') }
}
