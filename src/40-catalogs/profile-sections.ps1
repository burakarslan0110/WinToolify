# Get-WtProfileSectionCatalog.
# Covered by: tests/ConfigProfile.Tests.ps1

function Get-WtProfileSectionCatalog {
    <#
    .SYNOPSIS
        The Config Profiles section table: one row per state-aware catalog,
        in the fixed profile order. Each row carries the catalog getter, a
        tri-state live-state reader (Applied / NotApplied / NotPresent), and
        the existing Invoke-WtApply*Selection entry point, so export and
        import iterate one table and never re-encode what "Applied" means.
        Rows may add TurnOff (same signature as Apply; writes the Windows
        default and its own undo entry) and IsRemovable (Entry -> bool); a
        row without TurnOff cannot remove from a screen. Packages reads
        Get-WtPackageLiveInstalled rather than Get-WtPackageState, since a
        WinGet-removed row is a Win32 install no Appx lookup can see.
    #>
    return @(
        [PSCustomObject]@{
            Key              = 'Services'
            TitleKey         = 'ServicesManagement'
            RestartsExplorer = $false
            GetCatalog       = { Get-WtServiceCatalog }
            GetState         = {
                param($Entry)
                $state = Get-WtServiceState -Name $Entry.Name -IsPerUser $Entry.IsPerUser
                if (-not $state.Present) { return 'NotPresent' }
                if ($state.Status -eq 'Stopped' -and $state.StartType -eq 'Disabled') { return 'Applied' }
                return 'NotApplied'
            }
            Apply            = {
                param([string[]]$Names, $Data)
                $targets = $(if ($Data -and $Data.Targets) { [hashtable]$Data.Targets } else { @{} })
                Invoke-WtApplyServiceSelection -SelectedNames $Names -Targets $targets
            }
        }
        [PSCustomObject]@{
            Key              = 'Packages'
            TitleKey         = 'InstalledApps'
            RestartsExplorer = $false
            GetCatalog       = { Get-WtPackageCatalog }
            GetState         = {
                param($Entry)
                if ((Get-WtPackageLiveInstalled -Entry $Entry).Installed) { return 'NotApplied' }
                return 'Applied'
            }
            Apply            = { param([string[]]$Names) Invoke-WtApplyPackageSelection -SelectedNames $Names }
        }
        [PSCustomObject]@{
            Key              = 'AiPrivacy'
            TitleKey         = 'AICopilot'
            RestartsExplorer = $false
            GetCatalog       = { Get-WtAiPrivacyCatalog }
            GetState         = {
                param($Entry)
                if ((Get-WtAiPrivacyState -Entry $Entry).Applied) { return 'Applied' }
                return 'NotApplied'
            }
            Apply            = { param([string[]]$Names) Invoke-WtApplyAiPrivacySelection -SelectedNames $Names }
            TurnOff          = { param([string[]]$Names) Invoke-WtRemoveRegistryEntrySelection -Catalog (Get-WtAiPrivacyCatalog) -SelectedNames $Names -ActionName 'Revert AI Privacy Settings' }
            IsRemovable      = { param($Entry) Test-WtRegistryEntryRemovable -Entry $Entry }
        }
        [PSCustomObject]@{
            Key              = 'CapabilityDefaults'
            TitleKey         = 'CapabilityDefaults'
            RestartsExplorer = $false
            GetCatalog       = { Get-WtAppPermissionCatalog }
            GetState         = {
                param($Entry)
                if ((Get-WtAppPermissionState -Capability $Entry.Name).Applied) { return 'Applied' }
                return 'NotApplied'
            }
            Apply            = { param([string[]]$Names) Invoke-WtApplyAppPermissionSelection -SelectedNames $Names }
            TurnOff          = { param([string[]]$Names) Invoke-WtApplyAppPermissionSelection -SelectedNames $Names -Value 'Allow' -ActionName 'Revert App Permission Defaults' }
        }
        [PSCustomObject]@{
            Key              = 'Telemetry'
            TitleKey         = 'Telemetry'
            RestartsExplorer = $false
            GetCatalog       = { Get-WtTelemetryCatalog }
            GetState         = {
                param($Entry)
                if ((Get-WtRegistryEntryState -Entry $Entry).Applied) { return 'Applied' }
                return 'NotApplied'
            }
            Apply            = { param([string[]]$Names) Invoke-WtApplyRegistryEntrySelection -Catalog (Get-WtTelemetryCatalog) -SelectedNames $Names -ActionName 'Apply Telemetry Settings' }
            TurnOff          = { param([string[]]$Names) Invoke-WtRemoveRegistryEntrySelection -Catalog (Get-WtTelemetryCatalog) -SelectedNames $Names -ActionName 'Revert Telemetry Settings' }
            IsRemovable      = { param($Entry) Test-WtRegistryEntryRemovable -Entry $Entry }
        }
        [PSCustomObject]@{
            Key              = 'ActivityAdvertising'
            TitleKey         = 'ActivityAndAdvertising'
            RestartsExplorer = $false
            GetCatalog       = { Get-WtActivityAdvertisingCatalog }
            GetState         = {
                param($Entry)
                if ((Get-WtRegistryEntryState -Entry $Entry).Applied) { return 'Applied' }
                return 'NotApplied'
            }
            Apply            = { param([string[]]$Names) Invoke-WtApplyRegistryEntrySelection -Catalog (Get-WtActivityAdvertisingCatalog) -SelectedNames $Names -ActionName 'Apply Activity & Advertising Settings' }
            TurnOff          = { param([string[]]$Names) Invoke-WtRemoveRegistryEntrySelection -Catalog (Get-WtActivityAdvertisingCatalog) -SelectedNames $Names -ActionName 'Revert Activity & Advertising Settings' }
            IsRemovable      = { param($Entry) Test-WtRegistryEntryRemovable -Entry $Entry }
        }
        [PSCustomObject]@{
            Key              = 'SearchSuggestions'
            TitleKey         = 'SearchAndSuggestions'
            RestartsExplorer = $false
            GetCatalog       = { Get-WtSearchSuggestionsCatalog }
            GetState         = {
                param($Entry)
                if ((Get-WtRegistryEntryState -Entry $Entry).Applied) { return 'Applied' }
                return 'NotApplied'
            }
            Apply            = { param([string[]]$Names) Invoke-WtApplyRegistryEntrySelection -Catalog (Get-WtSearchSuggestionsCatalog) -SelectedNames $Names -ActionName 'Apply Search & Suggestions Settings' }
            TurnOff          = { param([string[]]$Names) Invoke-WtRemoveRegistryEntrySelection -Catalog (Get-WtSearchSuggestionsCatalog) -SelectedNames $Names -ActionName 'Revert Search & Suggestions Settings' }
            IsRemovable      = { param($Entry) Test-WtRegistryEntryRemovable -Entry $Entry }
        }
        [PSCustomObject]@{
            Key              = 'HardeningPrivacy'
            TitleKey         = 'PrivacyTelemetryScreen'
            RestartsExplorer = $false
            GetCatalog       = { Get-WtHardeningCatalog -Group 'PrivacyTelemetry' }
            GetState         = { param($Entry) if ((Get-WtRegistryEntryState -Entry $Entry).Applied) { 'Applied' } else { 'NotApplied' } }
            Apply            = { param([string[]]$Names) Invoke-WtApplyRegistryEntrySelection -Catalog (Get-WtHardeningCatalog -Group 'PrivacyTelemetry') -SelectedNames $Names -ActionName 'Apply Privacy Settings' }
            TurnOff          = { param([string[]]$Names) Invoke-WtRemoveRegistryEntrySelection -Catalog (Get-WtHardeningCatalog -Group 'PrivacyTelemetry') -SelectedNames $Names -ActionName 'Revert Privacy Settings' }
            IsRemovable      = { param($Entry) Test-WtRegistryEntryRemovable -Entry $Entry }
        }
        [PSCustomObject]@{
            Key              = 'HardeningAppPermissions'
            TitleKey         = 'PrivacyAppPermissionsScreen'
            RestartsExplorer = $false
            GetCatalog       = { Get-WtHardeningCatalog -Group 'AppPermissions' }
            GetState         = { param($Entry) if ((Get-WtRegistryEntryState -Entry $Entry).Applied) { 'Applied' } else { 'NotApplied' } }
            Apply            = { param([string[]]$Names) Invoke-WtApplyRegistryEntrySelection -Catalog (Get-WtHardeningCatalog -Group 'AppPermissions') -SelectedNames $Names -ActionName 'Apply App Permission Settings' }
            TurnOff          = { param([string[]]$Names) Invoke-WtRemoveRegistryEntrySelection -Catalog (Get-WtHardeningCatalog -Group 'AppPermissions') -SelectedNames $Names -ActionName 'Revert App Permission Settings' }
            IsRemovable      = { param($Entry) Test-WtRegistryEntryRemovable -Entry $Entry }
        }
        [PSCustomObject]@{
            Key              = 'HardeningAi'
            TitleKey         = 'PrivacyAiScreen'
            RestartsExplorer = $false
            GetCatalog       = { Get-WtHardeningCatalog -Group 'Ai' }
            GetState         = { param($Entry) if ((Get-WtRegistryEntryState -Entry $Entry).Applied) { 'Applied' } else { 'NotApplied' } }
            Apply            = { param([string[]]$Names) Invoke-WtApplyRegistryEntrySelection -Catalog (Get-WtHardeningCatalog -Group 'Ai') -SelectedNames $Names -ActionName 'Apply AI Settings' }
            TurnOff          = { param([string[]]$Names) Invoke-WtRemoveRegistryEntrySelection -Catalog (Get-WtHardeningCatalog -Group 'Ai') -SelectedNames $Names -ActionName 'Revert AI Settings' }
            IsRemovable      = { param($Entry) Test-WtRegistryEntryRemovable -Entry $Entry }
        }
        [PSCustomObject]@{
            Key              = 'HardeningSearchUi'
            TitleKey         = 'PrivacySearchUiScreen'
            RestartsExplorer = $false
            GetCatalog       = { Get-WtHardeningCatalog -Group 'SearchUi' }
            GetState         = { param($Entry) if ((Get-WtRegistryEntryState -Entry $Entry).Applied) { 'Applied' } else { 'NotApplied' } }
            Apply            = { param([string[]]$Names) Invoke-WtApplyRegistryEntrySelection -Catalog (Get-WtHardeningCatalog -Group 'SearchUi') -SelectedNames $Names -ActionName 'Apply Search and UI Settings' }
            TurnOff          = { param([string[]]$Names) Invoke-WtRemoveRegistryEntrySelection -Catalog (Get-WtHardeningCatalog -Group 'SearchUi') -SelectedNames $Names -ActionName 'Revert Search and UI Settings' }
            IsRemovable      = { param($Entry) Test-WtRegistryEntryRemovable -Entry $Entry }
        }
        [PSCustomObject]@{
            Key              = 'HardeningEdge'
            TitleKey         = 'PrivacyEdgeScreen'
            RestartsExplorer = $false
            GetCatalog       = { Get-WtHardeningCatalog -Group 'Edge' }
            GetState         = { param($Entry) if ((Get-WtRegistryEntryState -Entry $Entry).Applied) { 'Applied' } else { 'NotApplied' } }
            Apply            = { param([string[]]$Names) Invoke-WtApplyRegistryEntrySelection -Catalog (Get-WtHardeningCatalog -Group 'Edge') -SelectedNames $Names -ActionName 'Apply Edge Settings' }
            TurnOff          = { param([string[]]$Names) Invoke-WtRemoveRegistryEntrySelection -Catalog (Get-WtHardeningCatalog -Group 'Edge') -SelectedNames $Names -ActionName 'Revert Edge Settings' }
            IsRemovable      = { param($Entry) Test-WtRegistryEntryRemovable -Entry $Entry }
        }
        [PSCustomObject]@{
            Key              = 'HardeningOffice'
            TitleKey         = 'PrivacyOfficeScreen'
            RestartsExplorer = $false
            GetCatalog       = { Get-WtHardeningCatalog -Group 'Office' }
            GetState         = { param($Entry) if ((Get-WtRegistryEntryState -Entry $Entry).Applied) { 'Applied' } else { 'NotApplied' } }
            Apply            = { param([string[]]$Names) Invoke-WtApplyRegistryEntrySelection -Catalog (Get-WtHardeningCatalog -Group 'Office') -SelectedNames $Names -ActionName 'Apply Office and Sync Settings' }
            TurnOff          = { param([string[]]$Names) Invoke-WtRemoveRegistryEntrySelection -Catalog (Get-WtHardeningCatalog -Group 'Office') -SelectedNames $Names -ActionName 'Revert Office and Sync Settings' }
            IsRemovable      = { param($Entry) Test-WtRegistryEntryRemovable -Entry $Entry }
        }
        [PSCustomObject]@{
            Key              = 'HardeningUpdate'
            TitleKey         = 'PrivacyUpdateScreen'
            RestartsExplorer = $false
            GetCatalog       = { Get-WtHardeningCatalog -Group 'Update' }
            GetState         = { param($Entry) if ((Get-WtRegistryEntryState -Entry $Entry).Applied) { 'Applied' } else { 'NotApplied' } }
            Apply            = { param([string[]]$Names) Invoke-WtApplyRegistryEntrySelection -Catalog (Get-WtHardeningCatalog -Group 'Update') -SelectedNames $Names -ActionName 'Apply Windows Update Settings' }
            TurnOff          = { param([string[]]$Names) Invoke-WtRemoveRegistryEntrySelection -Catalog (Get-WtHardeningCatalog -Group 'Update') -SelectedNames $Names -ActionName 'Revert Windows Update Settings' }
            IsRemovable      = { param($Entry) Test-WtRegistryEntryRemovable -Entry $Entry }
        }
        [PSCustomObject]@{
            Key              = 'HardeningSecurity'
            TitleKey         = 'PrivacySecurityScreen'
            RestartsExplorer = $false
            GetCatalog       = { Get-WtHardeningCatalog -Group 'Security' }
            GetState         = { param($Entry) if ((Get-WtRegistryEntryState -Entry $Entry).Applied) { 'Applied' } else { 'NotApplied' } }
            Apply            = { param([string[]]$Names) Invoke-WtApplyRegistryEntrySelection -Catalog (Get-WtHardeningCatalog -Group 'Security') -SelectedNames $Names -ActionName 'Apply Security Settings' }
            TurnOff          = { param([string[]]$Names) Invoke-WtRemoveRegistryEntrySelection -Catalog (Get-WtHardeningCatalog -Group 'Security') -SelectedNames $Names -ActionName 'Revert Security Settings' }
            IsRemovable      = { param($Entry) Test-WtRegistryEntryRemovable -Entry $Entry }
        }
        [PSCustomObject]@{
            Key              = 'PowerPlan'
            TitleKey         = 'PowerPlan'
            RestartsExplorer = $false
            GetCatalog       = { Get-WtPowerPlanCatalog }
            GetState         = {
                param($Entry)
                if ((Get-WtPowerPlanState -Entry $Entry).Applied) { return 'Applied' }
                return 'NotApplied'
            }
            Apply            = { param([string[]]$Names) Invoke-WtApplyPowerPlanSelection -SelectedNames $Names }
            TurnOff          = { param([string[]]$Names) Invoke-WtRemovePowerPlanSelection -SelectedNames $Names }
            IsRemovable      = { param($Entry) $Entry.Name -eq 'UltimatePerformance' }
        }
        [PSCustomObject]@{
            Key              = 'GamingTweaks'
            TitleKey         = 'GamingTweaks'
            RestartsExplorer = $false
            GetCatalog       = { Get-WtGamingTweakCatalog }
            GetState         = {
                param($Entry)
                if ($Entry.Name -eq 'EnableGpuScheduling' -and -not (Test-WtGpuSchedulingSupported)) { return 'NotPresent' }
                if ((Get-WtRegistryEntryState -Entry $Entry).Applied) { return 'Applied' }
                return 'NotApplied'
            }
            Apply            = { param([string[]]$Names) Invoke-WtApplyRegistryEntrySelection -Catalog (Get-WtGamingTweakCatalog) -SelectedNames $Names -ActionName 'Apply Gaming Tweaks' }
            TurnOff          = { param([string[]]$Names) Invoke-WtRemoveRegistryEntrySelection -Catalog (Get-WtGamingTweakCatalog) -SelectedNames $Names -ActionName 'Revert Gaming Tweaks' }
            IsRemovable      = { param($Entry) Test-WtRegistryEntryRemovable -Entry $Entry }
        }
        [PSCustomObject]@{
            Key              = 'Firewall'
            TitleKey         = 'FirewallSection'
            RestartsExplorer = $false
            GetCatalog       = { Get-WtFirewallCatalog }
            GetState         = {
                param($Entry)
                if ((Get-WtFirewallState -Entry $Entry).Applied) { return 'Applied' }
                return 'NotApplied'
            }
            Apply            = { param([string[]]$Names) Invoke-WtApplyFirewallSelection -SelectedNames $Names }
        }
        [PSCustomObject]@{
            Key              = 'FastStartup'
            TitleKey         = 'FastStartupSection'
            RestartsExplorer = $false
            GetCatalog       = { Get-WtFastStartupCatalog }
            GetState         = {
                param($Entry)
                if ((Get-WtFastStartupState -Entry $Entry).Applied) { return 'Applied' }
                return 'NotApplied'
            }
            Apply            = { param([string[]]$Names) Invoke-WtApplyFastStartupSelection -SelectedNames $Names }
            TurnOff          = { param([string[]]$Names) Invoke-WtApplyFastStartupSelection -SelectedNames $Names -Enable }
        }
        [PSCustomObject]@{
            Key              = 'ContextMenu'
            TitleKey         = 'ContextMenu'
            RestartsExplorer = $true
            GetCatalog       = { Get-WtContextMenuCatalog }
            GetState         = {
                param($Entry)
                if ((Get-WtShellEntryState -Entry $Entry).Applied) { return 'Applied' }
                return 'NotApplied'
            }
            Apply            = { param([string[]]$Names) Invoke-WtApplyContextMenuSelection -SelectedNames $Names }
            TurnOff          = { param([string[]]$Names) Invoke-WtRemoveShellEntrySelection -Catalog (Get-WtContextMenuCatalog) -SelectedNames $Names -ActionName 'Remove Context Menu Entries' }
        }
        [PSCustomObject]@{
            Key              = 'ExplorerView'
            TitleKey         = 'ExplorerView'
            RestartsExplorer = $true
            GetCatalog       = { Get-WtExplorerViewCatalog }
            GetState         = {
                param($Entry)
                if ((Get-WtRegistryEntryState -Entry $Entry).Applied) { return 'Applied' }
                return 'NotApplied'
            }
            Apply            = { param([string[]]$Names) Invoke-WtApplyRegistryEntrySelection -Catalog (Get-WtExplorerViewCatalog) -SelectedNames $Names -ActionName 'Apply Explorer View Settings' }
            TurnOff          = { param([string[]]$Names) Invoke-WtRemoveRegistryEntrySelection -Catalog (Get-WtExplorerViewCatalog) -SelectedNames $Names -ActionName 'Revert Explorer View Settings' }
            IsRemovable      = { param($Entry) Test-WtRegistryEntryRemovable -Entry $Entry }
        }
    )
}
