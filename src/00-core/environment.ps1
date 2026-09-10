# Windows edition, winget presence, Windows 11 detection.
# Covered by: tests/Guard.Tests.ps1

function Get-WtWindowsEdition {
    <#
    .SYNOPSIS
        The installed Windows edition as its raw EditionID string
        ('Enterprise', 'Professional', 'Core', ...), or $null when the
        value cannot be read. Injectable for the same reason as
        Test-WtGpuSchedulingSupported: there is no Registry PSProvider on
        the macOS dev host.
    #>
    param(
        [scriptblock]$GetPropertyAction = {
            param($p, $n)
            Get-WtRegistryProperty -Path $p -Name $n
        }
    )

    $current = Get-WtRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'EditionID' -GetPropertyAction $GetPropertyAction
    if (-not $current.Present) { return $null }
    return [string]$current.Value
}


function Test-WingetInstalled {
    <#
    .SYNOPSIS
        Ensures winget exists; on Windows 10 / LTSC without App Installer
        bootstraps it the way Microsoft documents (TLS 1.2 for the
        gallery, Microsoft.WinGet.Client, Repair-WinGetPackageManager).
        Called lazily from the actions that need winget, never at startup.
    #>
    try {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Host (Get-Translation 'WingetAlreadyInstalled') -ForegroundColor Green
            return
        }
        Write-Host (Get-Translation 'WingetNotInstalled') -ForegroundColor Yellow
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Install-PackageProvider -Name NuGet -Force | Out-Null
        Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery | Out-Null
        Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile -Command Repair-WinGetPackageManager -AllUsers -Force -Latest' -Wait -NoNewWindow
        Write-Host (Get-Translation 'WingetInstalled') -ForegroundColor Green
    }
    catch {
        Write-Host (Get-Translation 'WingetInstallError') -ForegroundColor Red
    }
}
