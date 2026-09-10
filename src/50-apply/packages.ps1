# OneDrive removal and Invoke-WtApplyPackageSelection.
# Covered by: tests/ApplyEngine.Tests.ps1

function Invoke-WtRemoveOneDrive {
    <#
    .SYNOPSIS
        OneDrive is a Win32 per-user install, not an Appx: winget first,
        the inbox OneDriveSetup.exe /uninstall as the fallback.
    #>
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget uninstall --id Microsoft.OneDrive --accept-source-agreements --disable-interactivity --silent | Out-Null
    }
    $setup = Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe'
    if (-not (Test-Path -LiteralPath $setup)) { $setup = Join-Path $env:SystemRoot 'SysWOW64\OneDriveSetup.exe' }
    if (Test-Path -LiteralPath $setup) { Start-Process -FilePath $setup -ArgumentList '/uninstall' -Wait -ErrorAction SilentlyContinue }
}

function Invoke-WtApplyPackageSelection {
    <#
    .SYNOPSIS
        Wires the Apps screen to Invoke-WtGuardedChange: removes each selected
        package for every user profile and deprovisions it, recording state
        for Restore-WtUndoEntry to reinstall later. OneDrive's 'WinGet'
        RemovalMethod has no Appx, so it is captured without a package lookup.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleCommands', '',
        Justification = 'Get-AppxPackage/Remove-AppxPackage -AllUsers and the Dism provisioned-package cmdlets are Windows-only by design and absent from the static PS 7.0 profile; on Windows they resolve through the Appx/Dism modules on both 5.1 and 7.')]
    param(
        [Parameter(Mandatory)]
        [string[]]$SelectedNames
    )

    $catalog = Get-WtPackageCatalog

    $captureState = {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($selectedName in $SelectedNames) {
            $entry = $catalog | Where-Object Name -eq $selectedName
            if (-not $entry) { continue }
            if ([string]$entry.RemovalMethod -eq 'WinGet') {
                $items.Add([PSCustomObject]@{
                    ItemType        = 'Package'
                    Name            = $selectedName
                    PackageFullName = $selectedName
                    InstallLocation = $null
                    IsProvisioned   = $false
                    RemovalMethod   = 'WinGet'
                })
                continue
            }
            $pkg = Get-AppxPackage -Name (ConvertTo-WtPackagePattern -Name $selectedName) -AllUsers -ErrorAction SilentlyContinue |
                Where-Object { Test-WtPackageNameMatches -CatalogName $selectedName -LiveName $_.Name } |
                Select-Object -First 1
            if (-not $pkg) { continue }
            $items.Add([PSCustomObject]@{
                ItemType        = 'Package'
                Name            = $selectedName
                PackageFullName = $pkg.PackageFullName
                InstallLocation = $pkg.InstallLocation
                IsProvisioned   = [bool]$entry.IsProvisioned
                RemovalMethod   = [string]$entry.RemovalMethod
            })
        }
        return $items.ToArray()
    }

    $apply = {
        param($Item)
        if ($Item.RemovalMethod -eq 'WinGet') { Invoke-WtRemoveOneDrive; return }
        Get-AppxPackage -Name (ConvertTo-WtPackagePattern -Name $Item.Name) -AllUsers -ErrorAction SilentlyContinue |
            Where-Object { Test-WtPackageNameMatches -CatalogName $Item.Name -LiveName $_.Name } |
            ForEach-Object { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop }
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { Test-WtPackageNameMatches -CatalogName $Item.Name -LiveName $_.DisplayName } |
            ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null }
    }

    $reReadState = {
        param($Item)
        return (-not (Get-WtPackageLiveInstalled -Entry $Item).Installed)
    }

    return Invoke-WtGuardedChange -CaptureState $captureState -Apply $apply -ReReadState $reReadState -Scope User -ActionName 'Remove Packages'
}
