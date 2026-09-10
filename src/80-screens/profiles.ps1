# Profiles menu screen.
# Covered by: tests/ConfigProfile.Tests.ps1

function Get-WtProfilesMenuItems {
    <#
    .SYNOPSIS
        PURE: Export / Import as inline actions - both flows draw their
        own panels (prompts, progress and results all inside the box).
    #>
    return @(
        New-WtListItem -Kind 'Action' -Name 'ExportProfile' -Label (Get-Translation 'ExportProfile') -Data @{ Action = { Show-WtProfileExport } }
        New-WtListItem -Kind 'Action' -Name 'ImportProfile' -Label (Get-Translation 'ImportProfile') -Data @{ Action = { Show-WtProfileImport } }
    )
}

function Invoke-WtProfilesScreen {
    return Invoke-WtNavScreen -Breadcrumb (Get-WtBreadcrumb -Keys 'MainMenu', 'ConfigProfiles') -Items (Get-WtProfilesMenuItems)
}

function Test-WtProfileRebootNeeded {
    <#
    .SYNOPSIS
        PURE: does any applied profile-import row map to a catalog entry
        flagged RestartRequired (today: the gaming GPU-scheduling row)?
        Ensures the profile-import path prints the same reboot note the
        normal apply path does.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Sections)
    foreach ($section in $Sections) {
        if ($section.Outcome -ne 'Applied') { continue }
        foreach ($row in @($section.Results)) {
            if (-not $row.Applied) { continue }
            $entryName = if ($row.Item.PSObject.Properties.Name -contains 'CatalogEntry') { [string]$row.Item.CatalogEntry } else { [string]$row.Item.Name }
            $entry = @($section.Catalog) | Where-Object Name -eq $entryName | Select-Object -First 1
            if ($entry -and ($entry.PSObject.Properties.Name -contains 'RestartRequired') -and $entry.RestartRequired) { return $true }
        }
    }
    return $false
}
