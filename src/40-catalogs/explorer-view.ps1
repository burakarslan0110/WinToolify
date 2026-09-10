# Explorer view catalog.
# Covered by: tests/ExplorerViewCatalog.Tests.ps1

function Get-WtExplorerViewCatalog {
    <#
    .SYNOPSIS
        The seven File Explorer default-view tweaks as a RegistryChanges-
        shaped catalog, all HKCU DWORDs, sharing Get-WtRegistryEntryState /
        Invoke-WtApplyRegistryEntrySelection with no new code. Every entry
        needs an Explorer restart to become visible (RestartsExplorer).
    #>
    $advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $explorer = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'

    $entry = {
        param($name, $label, $risk, $consequence, $changes)
        [PSCustomObject]@{
            Name             = $name
            DisplayLabel     = $label
            Risk             = $risk
            Consequence      = $consequence
            RestartsExplorer = $true
            RegistryChanges  = @($changes)
        }
    }
    $dword = { param($p, $n, $v, $off) if ($null -eq $off) { [PSCustomObject]@{ Path = $p; Name = $n; RegType = 'DWord'; Value = $v; OffAction = 'Delete' } } else { [PSCustomObject]@{ Path = $p; Name = $n; RegType = 'DWord'; Value = $v; OffAction = 'Set'; OffValue = $off } } }

    return Resolve-WtCatalogText -KeyPrefix 'ExplorerView' -Catalog @(
        (& $entry 'ShowFileExtensions' 'Show file extensions' 'SAFE' $null @((& $dword $advanced 'HideFileExt' 0 1)))
        (& $entry 'ShowHiddenFiles' 'Show hidden files and folders' 'SAFE' $null @((& $dword $advanced 'Hidden' 1 2)))
        (& $entry 'OpenExplorerToThisPC' 'Open File Explorer to This PC' 'SAFE' $null @((& $dword $advanced 'LaunchTo' 1)))
        (& $entry 'UseCompactView' 'Use compact view (smaller row spacing)' 'SAFE' $null @((& $dword $advanced 'UseCompactMode' 1)))
        (& $entry 'ShowProtectedOsFiles' 'Show protected operating-system files' 'CAUTION' 'Exposes system files that Windows hides on purpose - deleting or moving them can break the install' @((& $dword $advanced 'ShowSuperHidden' 1 0)))
        (& $entry 'ShowFullPathInTitleBar' 'Show the full path in the title bar' 'SAFE' $null @((& $dword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState' 'FullPath' 1)))
        (& $entry 'HideRecentAndFrequent' 'Hide recent files and frequent folders in Quick Access' 'SAFE' $null @((& $dword $explorer 'ShowRecent' 0), (& $dword $explorer 'ShowFrequent' 0)))
    )
}
