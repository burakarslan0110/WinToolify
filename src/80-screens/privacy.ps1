# Privacy menu and group screens.
# Covered by: tests/MenuTree.Tests.ps1

function Get-WtPrivacyScreenCatalog {
    <#
    .SYNOPSIS
        The seven Privacy screens: which existing sections each one hosts
        (first, with their own headers) and which hardening groups follow.
        Security has no screen of its own - after the OS filter its group
        falls below the ten-setting floor, so it rides under its own
        header on the Windows Update screen; its profile section stays
        separate.
    #>
    return @(
        @{ Key = 'PrivacyTelemetry'; TitleKey = 'PrivacyTelemetryScreen'; ExistingSections = [string[]]@('Telemetry', 'ActivityAdvertising')
           HardeningGroups = @(@{ Group = 'PrivacyTelemetry'; Section = 'HardeningPrivacy'; HeaderKey = 'HardeningMoreSettings' }) }
        @{ Key = 'PrivacyAppPermissions'; TitleKey = 'PrivacyAppPermissionsScreen'; ExistingSections = [string[]]@('CapabilityDefaults')
           HardeningGroups = @(@{ Group = 'AppPermissions'; Section = 'HardeningAppPermissions'; HeaderKey = 'HardeningMoreSettings' }) }
        @{ Key = 'PrivacyAi'; TitleKey = 'PrivacyAiScreen'; ExistingSections = [string[]]@('AiPrivacy')
           HardeningGroups = @(@{ Group = 'Ai'; Section = 'HardeningAi'; HeaderKey = 'HardeningMoreSettings' }) }
        @{ Key = 'PrivacySearchUi'; TitleKey = 'PrivacySearchUiScreen'; ExistingSections = [string[]]@('SearchSuggestions')
           HardeningGroups = @(@{ Group = 'SearchUi'; Section = 'HardeningSearchUi'; HeaderKey = 'HardeningMoreSettings' }) }
        @{ Key = 'PrivacyEdge'; TitleKey = 'PrivacyEdgeScreen'; ExistingSections = [string[]]@()
           HardeningGroups = @(@{ Group = 'Edge'; Section = 'HardeningEdge'; HeaderKey = $null }) }
        @{ Key = 'PrivacyOffice'; TitleKey = 'PrivacyOfficeScreen'; ExistingSections = [string[]]@()
           HardeningGroups = @(@{ Group = 'Office'; Section = 'HardeningOffice'; HeaderKey = $null }) }
        @{ Key = 'PrivacyUpdate'; TitleKey = 'PrivacyUpdateScreen'; ExistingSections = [string[]]@()
           HardeningGroups = @(
               @{ Group = 'Update'; Section = 'HardeningUpdate'; HeaderKey = $null }
               @{ Group = 'Security'; Section = 'HardeningSecurity'; HeaderKey = 'PrivacySecuritySection' }
           ) }
    )
}

function Get-WtPrivacyMenuItems {
    <#
    .SYNOPSIS
        The Privacy menu - one link per screen, in catalog order. Pure.
    #>
    return @(foreach ($s in @(Get-WtPrivacyScreenCatalog)) {
        New-WtListItem -Kind 'Link' -Name $s.Key -Label (Get-Translation $s.TitleKey) -Data @{ Screen = $s.Key }
    })
}

function Get-WtPrivacyGroups {
    <#
    .SYNOPSIS
        Apply groups for one Privacy screen: each existing section as its
        own headed group, then one group per hardening group with Category
        sub-headers. Every hardening catalog is resolved once here and
        carried in Data, since Get-WtHardeningCatalog re-parses the row
        table on every call.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [bool]$IsWindows11 = (Test-WtIsWindows11),
        [array]$Sections = (Get-WtApplySectionCatalog)
    )
    $screen = @(Get-WtPrivacyScreenCatalog) | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
    if (-not $screen) { throw "Unknown privacy screen '$Key'" }
    $groups = New-Object System.Collections.Generic.List[object]
    foreach ($sectionKey in @($screen.ExistingSections)) {
        $section = $Sections | Where-Object { $_.Key -eq $sectionKey } | Select-Object -First 1
        if (-not $section) { continue }
        $groups.Add(@{
            SectionKey    = $sectionKey
            HeaderKey     = $section.TitleKey
            Data          = @{ Section = $section }
            GetCatalog    = { param($g) @(& $g.Data.Section.GetCatalog) }
            GetEntryState = { param($e, $g) @{ Applied = ((& $g.Data.Section.GetState $e) -eq 'Applied'); Available = $true } }
        })
    }
    foreach ($hardening in @($screen.HardeningGroups)) {
        $groups.Add(@{
            SectionKey    = $hardening.Section
            HeaderKey     = $hardening.HeaderKey
            HeaderField   = 'Category'
            Data          = @{ Catalog = @(Get-WtHardeningCatalog -Group $hardening.Group -IsWindows11 $IsWindows11) }
            GetCatalog    = { param($g) $g.Data.Catalog }
            GetEntryState = { param($e, $g) Get-WtRegistryEntryLiveState -Entry $e }
        })
    }
    return $groups.ToArray()
}

function Get-WtPrivacyExtraItems {
    <#
    .SYNOPSIS
        Rows above the catalog rows of a Privacy screen - only App
        Permissions has one: the link to the per-app permission screen.
    #>
    param([Parameter(Mandatory)][string]$Key)
    if ($Key -eq 'PrivacyAppPermissions') {
        return @(New-WtListItem -Kind 'Link' -Name 'PerAppLink' -Label (Get-Translation 'PerAppPermissions') -Data @{ Screen = 'PerApp' })
    }
    return @()
}

function Invoke-WtPrivacyMenuScreen {
    return Invoke-WtNavScreen -Breadcrumb (Get-WtBreadcrumb -Keys 'MainMenu', 'PrivacySettings') -Items (Get-WtPrivacyMenuItems)
}

function Invoke-WtPrivacyGroupScreen {
    param([Parameter(Mandatory)][string]$Key)
    $screen = @(Get-WtPrivacyScreenCatalog) | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
    if (-not $screen) { throw "Unknown privacy screen '$Key'" }
    $crumb = Get-WtBreadcrumb -Keys 'MainMenu', 'PrivacySettings', $screen.TitleKey
    return Invoke-WtApplyScreen -Breadcrumb $crumb -Groups (Get-WtPrivacyGroups -Key $Key) -ExtraItems (Get-WtPrivacyExtraItems -Key $Key)
}
