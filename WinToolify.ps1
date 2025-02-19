# WinToolify
# Windows System Optimization Tool
# Author: Burak A.
# Version: 1.0

<#
.SYNOPSIS
    WinToolify - Windows System Optimization Tool - By Burak A.
.DESCRIPTION
    Simple and effective Windows optimization tool that helps users to:
    - Clean up system
    - Optimize performance
    - Manage Windows services
    - Configure privacy settings
    - Remove bloatware
#>

# Yönetici olarak çalışıp çalışmadığını kontrol et
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    # Yönetici olarak yeniden başlat
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# Pencere boyutunu dinamik olarak ayarla
function Set-WindowSize {
    param (
        [int]$fixedWidth = 120,  # Genişlik (karakter cinsinden)
        [int]$fixedHeight = 65   # Yükseklik (satır cinsinden)
    )
    
    try {
        $pshost = Get-Host
        $pswindow = $pshost.UI.RawUI

        # Yeni buffer boyutunu ayarla
        $newSize = $pswindow.BufferSize
        $newSize.Width = $fixedWidth
        $newSize.Height = 1000  # Kaydırma çubuğunu önlemek için
        $pswindow.BufferSize = $newSize

        # Yeni pencere boyutunu ayarla
        $newSize = $pswindow.WindowSize
        $newSize.Width = $fixedWidth
        $newSize.Height = $fixedHeight
        $pswindow.WindowSize = $newSize

        # Pencere başlığını değiştir
        $Host.UI.RawUI.WindowTitle = "WinToolify v1.0"

        return $true
    }
    catch {
        Write-Host "Pencere boyutu ayarlanamadı. Program devam ediyor..." -ForegroundColor Yellow
        return $false
    }
}

# Language settings
$script:Language = "EN" # Default language
$script:Translations = @{
    "EN" = @{
        "MainTitle" = "WinToolify"
        "CreatedBy" = "Created by Burak A."
        "BasicTools" = "Basic Tools"
        "ServicesManagement" = "Windows Services Management"
        "PrivacySettings" = "Privacy Settings"
        "BloatwareRemoval" = "Bloatware Removal"
        "Exit" = "Exit"
        "SelectOption" = "Select an option"
        "ReturnMainMenu" = "Return to Main Menu"
        "RunDiskCleanup" = "Run Disk Cleanup"
        "OptimizePerformance" = "Optimize Performance"
        "Language" = "Language Settings"
        "InvalidSelection" = "Invalid selection!"
        "ShowComputerAndUserName" = "Show Computer and User Name"
        "ShowComputerSerialNumber" = "Show Computer Serial Number"
        "GetSystemInformation" = "Get System Information"
        "ActionTools" = "Action Tools"
        "InformationTools" = "Information Tools"
        "ShowWindowsLicenseStatus" = "Show Windows License Status"
        "ShowActiveWindowsLicense" = "Show Active Windows License"
        "ShowWindowsVersion" = "Show Windows Version"
        "ShowSystemInfo" = "Show System Info"
        "ListUserAccounts" = "List User Accounts"
        "ShowWifiPassword" = "Show Wi-Fi Password"
        "ShowIPAddress" = "Show IP Address"
        "ShowFullIPConfig" = "Show Full IP Config"
        "CheckDiskStatus" = "Check Disk Status"
        "ShowStorageStatus" = "Show Storage Status"
        "ScanHardDisk" = "Scan Hard Disk"
        "ShowCPUInfo" = "Show CPU Info"
        "ShowRAMUsage" = "Show RAM Usage"
        "ShowPrinterStatus" = "Show Printer Status"
        "ListInstalledPrinters" = "List Installed Printers"
        "OpeningPort" = "List Opening Ports"
        "ReturnBasicToolsMenu" = "Return to Basic Tools Menu"
        "UpdateWindowsStoreApps" = "Update Windows Store Apps"
        "UpdateAllProgramsWithWinGet" = "Update All Programs with WinGet"
        "RepairWindowsSystemFiles" = "Repair Windows System Files"
        "WindowsDiskCleanup" = "Windows Disk Cleanup"
        "CleanUnnecessaryFiles" = "Clean Unnecessary Files"
        "ReleaseIPConfig" = "Release IP Configuration"
        "RenewIPConfig" = "Renew IP Configuration"
        "FlushDNSCache" = "Flush DNS Cache"
        "PingTest" = "Run Ping Test"
        "RestartPrinter" = "Restart Printer"
        "ClearPrintQueue" = "Clear Print Queue"
        "EnableFirewall" = "Enable Firewall"
        "DisableFirewall" = "Disable Firewall"
        "UpdateGroupPolicies" = "Update Group Policies"
        "StartSafeMode" = "Start in Safe Mode"
        "ShutdownComputer" = "Shutdown Computer"
        "RestartComputer" = "Restart Computer"
        "RestartInSafeMode" = "Restart in Safe Mode"
        "DisableFastStartup" = "Disable Fast Startup"
        "Pinging" = "Enter Address to Ping"
        "Deleted" = "Deleted"
        "ShutUp10++" = "Manage Privacy with ShutUp10"
        "ShutUp10Info1" = "You can manage privacy with ShutUp10"
        "ShutUp10Info2" = "Select recommended sett. from Action"
        "GoToServicesMenu" = "Return to Services Menu"
        "SelectService" = "Select a service to disable"
        "DisableUnnecessaryServices" = "Disable Unnecessary Services"
        "HasBeenDisabled" = "Has Been Disabled"
        "WingetNotInstalled" = "Winget is not installed, starting installation..."
        "WingetInstalled" = "Winget has been successfully installed."
        "WingetAlreadyInstalled" = "Winget is already installed."
        "WingetInstallError" = "An error occurred during Winget installation."
        "BloatwareRemovalPage" = "Bloatware Removal - Page"
        "CurrentGroup" = "Current Group"
        "Navigation" = "Navigation"
        "NextPage" = "Next Page"
        "PreviousPage" = "Previous Page"
        "SelectAllOnPage" = "Select All on Page"
        "ClearAllSelections" = "Clear All Selections"
        "RemoveSelectedApps" = "Remove Selected Apps"
        "Quit" = "Quit"
        "YourChoice" = "Your Choice"
        "RemovingSelectedApps" = "Removing selected apps..."
        "Removing" = "Removing"
        "SelectedAppsRemoved" = "Selected apps removed."
        "SelectAppsFirst" = "Please select apps to remove first."
        "InstallVCRedist" = "Install VCRedist Packages"
        "SelectAndRemoveBloatware" = "Select And Remove Bloatware"
        "VCRedistInstalling" = "VCRedist Packages successfully installed!"
        "VCRedistDownloading" = "Vcredist packages are being downloaded..."
        "WiFiName" = "Wi-Fi Name"
        "WiFiProfileNotFound" = "Wi-Fi profile not found! Please check the name and try again."
        "WiFiPassword" = "Wi-Fi Password"
        "NoPasswordFound" = "No password found for this Wi-Fi network!"
    }
    "TR" = @{
        "MainTitle" = "WinToolify"
        "CreatedBy" = "Burak A. tarafindan gelistirildi"
        "BasicTools" = "Temel Araclar"
        "ServicesManagement" = "Windows Servis Yonetimi"
        "PrivacySettings" = "Gizlilik Ayarlari"
        "BloatwareRemoval" = "Gereksiz Uygulama Kaldirma"
        "Exit" = "Cikis"
        "RunDiskCleanup" = "Disk Temizleme"
        "OptimizePerformance" = "Performansizi Islemler"
        "SelectOption" = "Secenek seciniz"
        "ReturnMainMenu" = "Ana Menuye Don"
        "Language" = "Dil Ayarlari"
        "InvalidSelection" = "Gecersiz secim!"
        "ShowComputerAndUserName" = "Bil. ve Kullanici Adini Goster"
        "ShowComputerSerialNumber" = "Sistem Seri Numarasini Goster"
        "GetSystemInformation" = "Sistem Bilgilerini Listele"
        "ActionTools" = "Islem Araclari"
        "InformationTools" = "Bilgi Araclari"
        "ShowWindowsLicenseStatus" = "Windows Lisans Durumunu Goster"
        "ShowActiveWindowsLicense" = "Aktif Windows Lisansini Goster"
        "ShowWindowsVersion" = "Windows Versiyonunu Goster"
        "ShowSystemInfo" = "Sistem Bilgilerini Goster"
        "ListUserAccounts" = "Kullanici Hesaplarini Listele"
        "ShowWifiPassword" = "Wi-Fi Sifresini Goster"
        "ShowIPAddress" = "IP Adresini Goster"
        "ShowFullIPConfig" = "Tum IP Yapilandirmasini Goster"
        "CheckDiskStatus" = "Disk Durumunu Kontrol Et"
        "ShowStorageStatus" = "Depolama Durumunu Goster"
        "ScanHardDisk" = "Disk Hatalarini Tara"
        "ShowCPUInfo" = "CPU Bilgilerini Goster"
        "ShowRAMUsage" = "RAM Kullanimini Goster"
        "ShowPrinterStatus" = "Yazici Durumunu Goster"
        "ListInstalledPrinters" = "Var Olan Yazicilari Listele"
        "OpeningPort" = "Acik Portlari Listele"
        "ReturnBasicToolsMenu" = "Temel Araclar Menusune Don"
        "UpdateWindowsStoreApps" = "Store Uygulamalarini Guncelle"
        "UpdateAllProgramsWithWinGet" = "Programlari WinGet'le Guncelle"
        "RepairWindowsSystemFiles" = "Windows Sistem Dosyalarini Onar"
        "WindowsDiskCleanup" = "Windows Disk Temizligi Yap"
        "CleanUnnecessaryFiles" = "Gereksiz Dosyalari Temizle"
        "ReleaseIPConfig" = "IP Yapilandirmayi Serbest Birak"
        "RenewIPConfig" = "IP Yapilandirmasini Yenile"
        "FlushDNSCache" = "Ag DNS On bellegini Temizle"
        "PingTest" = "Ping Testi Yap"
        "RestartPrinter" = "Yaziciyi Yeniden Baslat"
        "ClearPrintQueue" = "Yazici Kuyrugunu Temizle"
        "EnableFirewall" = "Guvenlik Duvarini Ac"
        "DisableFirewall" = "Guvenlik Duvarini Kapat"
        "UpdateGroupPolicies" = "Grup Politikalarini Guncelle"
        "StartSafeMode" = "Guvenli Modda Ac"
        "ShutdownComputer" = "Bilgisayari Kapat"
        "RestartComputer" = "Bilgisayari Yeniden Baslat"
        "RestartInSafeMode" = "Guvenli Modda Yeniden Baslat"
        "DisableFastStartup" = "Hizli Baslat Ozelligini Kapat"
        "Pinging" = "Ping Atilacak Adresi Giriniz"
        "Deleted" = "Siliniyor"
        "ShutUp10++" = "ShutUp10 ile Gizliligi Yonet"
        "ShutUp10Info1" = "OOSU10 ile Gizlilik Ayari Yapabilir"
        "ShutUp10Info2" = "Actions'tan onerilen ayari secin!"
        "GoToServicesMenu" = "Servisler Menu'sune Don"
        "SelectService" = "Devre Disi Birakilacak Servisi Seciniz"
        "DisableUnnecessaryServices" = "Gereksiz Servisleri Durdur"
        "HasBeenDisabled" = "Devre Disi Birakildi"
        "WingetNotInstalled" = "Winget yuklu degil, kurulum baslatiliyor..."
        "WingetInstalled" = "Winget basariyla yuklendi."
        "WingetAlreadyInstalled" = "Winget zaten yuklu."
        "WingetInstallError" = "Winget kurulumu sirasinda bir hata olustu."
        "BloatwareRemovalPage" = "Gereksiz Uygulama Kaldirma - Sayfa"
        "CurrentGroup" = "Guncel Grup"
        "Navigation" = "Navigasyon"
        "NextPage" = "Sonraki Sayfa"
        "PreviousPage" = "Onceki Sayfa"
        "SelectAllOnPage" = "Sayfadaki Tum Uygulamalari Sec"
        "ClearAllSelections" = "Sayfadaki Tum Secimleri Temizle"
        "RemoveSelectedApps" = "Secili Uygulamalari Kaldir"
        "Quit" = "Cikis"
        "YourChoice" = "Seciminiz"
        "RemovingSelectedApps" = "Secili uygulamalar kaldiriliyor..."
        "Removing" = "Kaldiriliyor"
        "SelectedAppsRemoved" = "Secili uygulamalar kaldirildi."
        "SelectAppsFirst" = "Lutfen once kaldirilacak uygulamalari secin."
        "InstallVCRedist" = "VCRedist Paketlerini Kur"
        "SelectAndRemoveBloatware" = "Gereksiz Uygulamalari Sec"
        "VCRedistInstalling" = "VCRedist Paketleri basariyla kuruldu!"
        "VCRedistDownloading" = "Vcredist paketleri indiriliyor..."
        "WiFiName" = "Wi-Fi Adi"
        "WiFiProfileNotFound" = "Wi-Fi profili bulunamadi! Lutfen adini kontrol edin ve tekrar deneyin."
        "WiFiPassword" = "Wi-Fi Sifresi"
        "NoPasswordFound" = "Bu Wi-Fi agi icin sifre bulunamadi!"
    }
}

function Get-Translation($Key) {
    return $script:Translations[$script:Language][$Key]
}

function Show-LanguageMenu {
    $contentHeight = 12
    $contentWidth = 80
    Set-WindowSize -contentHeight $contentHeight -contentWidth $contentWidth

    Clear-Host

    Show-AsciiArt
    
    Write-Host "`n"
    $width = $Host.UI.RawUI.WindowSize.Width
    $padding = " " * [math]::Floor(($width - 40) / 2)
    
    Write-Host "$padding+======================================+" -ForegroundColor Cyan
    Write-Host "$padding|           Language Settings          |" -ForegroundColor Cyan
    Write-Host "$padding|            Dil Ayarlari              |" -ForegroundColor Cyan
    Write-Host "$padding+======================================+" -ForegroundColor Cyan
    Write-Host "`n"
    Write-Host "$padding+--------------------------------------+" -ForegroundColor Yellow
    Write-Host ("$padding|  [1] English").PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [2] Turkce").PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [3] " + $(Get-Translation 'ReturnMainMenu')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host "$padding+--------------------------------------+" -ForegroundColor Yellow
    Write-Host "`n"
    Write-Host "$padding$(Get-Translation 'SelectOption'): " -NoNewline -ForegroundColor Green
}

# Function to display ASCII art
function Show-AsciiArt {
    $width = $Host.UI.RawUI.WindowSize.Width
    $padding = " " * [math]::Floor(($width - 85) / 2)
    Write-Host "$padding+=====================================================================================+" -ForegroundColor Cyan
    Write-Host "$padding|##      ## #### ##    ## ########  #######   #######  ##       #### ######## ##    ##|" -ForegroundColor Cyan
    Write-Host "$padding|##  ##  ##  ##  ###   ##    ##    ##     ## ##     ## ##        ##  ##        ##  ## |" -ForegroundColor Cyan
    Write-Host "$padding|##  ##  ##  ##  ####  ##    ##    ##     ## ##     ## ##        ##  ##         ####  |" -ForegroundColor Cyan
    Write-Host "$padding|##  ##  ##  ##  ## ## ##    ##    ##     ## ##     ## ##        ##  ######      ##   |" -ForegroundColor Cyan
    Write-Host "$padding|##  ##  ##  ##  ##  ####    ##    ##     ## ##     ## ##        ##  ##          ##   |" -ForegroundColor Cyan
    Write-Host "$padding|##  ##  ##  ##  ##   ###    ##    ##     ## ##     ## ##        ##  ##          ##   |" -ForegroundColor Cyan
    Write-Host "$padding| ###  ###  #### ##    ##    ##     #######   #######  ######## #### ##          ##   |" -ForegroundColor Cyan
    Write-Host "$padding+=====================================================================================+" -ForegroundColor Cyan
}

# Functions for system optimization
function Show-Menu {
    $contentHeight = 20  # Ana menü için yaklaşık satır sayısı
    $contentWidth = 80  # Menü genişliği
    Set-WindowSize -contentHeight $contentHeight -contentWidth $contentWidth

    Clear-Host

    Show-AsciiArt

    Write-Host "`n"
    $width = $Host.UI.RawUI.WindowSize.Width
    $padding = " " * [math]::Floor(($width - 40) / 2)
    
    Write-Host "$padding+======================================+" -ForegroundColor Cyan
    Write-Host "$padding|             WinToolify               |" -ForegroundColor Cyan
    Write-Host "$padding|         Created by Burak A.          |" -ForegroundColor Cyan
    Write-Host "$padding|       https://burakarslan.me         |" -ForegroundColor Cyan
    Write-Host "$padding+======================================+" -ForegroundColor Cyan
    Write-Host "`n"
    Write-Host "$padding+--------------------------------------+" -ForegroundColor Yellow
    Write-Host ("$padding|  [1] " + $(Get-Translation 'BasicTools')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [2] " + $(Get-Translation 'ServicesManagement')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [3] " + $(Get-Translation 'PrivacySettings')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [4] " + $(Get-Translation 'BloatwareRemoval')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [5] " + $(Get-Translation 'InstallVCRedist')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [6] " + $(Get-Translation 'Language')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host  "$padding|                                      |" -ForegroundColor White
    Write-Host ("$padding|  [Q] " + $(Get-Translation 'Exit')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host "$padding+--------------------------------------+" -ForegroundColor Yellow
    Write-Host "`n"
    Write-Host "$padding$(Get-Translation 'SelectOption'): " -NoNewline -ForegroundColor Green
}

function Show-BasicToolsMenu {
    # Alt menü için içerik boyutunu hesapla
    $contentHeight = 15  # Alt menü için yaklaşık satır sayısı
    $contentWidth = [math]::Max(80, ($padding.Length + 38))  # Menü genişliği, en uzun seçeneğe göre ayarlanır
    Set-WindowSize -contentHeight $contentHeight -contentWidth $contentWidth

    Clear-Host

    Show-AsciiArt

    Write-Host "`n"
    $width = $Host.UI.RawUI.WindowSize.Width
    $padding = " " * [math]::Floor(($width - 40) / 2)
    
    $title = $(Get-Translation 'BasicTools')
    $titlePadding = " " * [math]::Floor(($width - $title.Length) / 2)
    Write-Host "$padding+======================================+" -ForegroundColor Cyan
    Write-Host "$titlePadding$title$titlePadding" -ForegroundColor Cyan
    Write-Host "$padding+======================================+" -ForegroundColor Cyan
    Write-Host "`n"
    Write-Host "$padding+--------------------------------------+" -ForegroundColor Yellow
    Write-Host ("$padding|  [1] " + $(Get-Translation 'ActionTools')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [2] " + $(Get-Translation 'InformationTools')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [3] " + $(Get-Translation 'ReturnMainMenu')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host "$padding+--------------------------------------+" -ForegroundColor Yellow
    Write-Host "`n"
    Write-Host "$padding$(Get-Translation 'SelectOption'): " -NoNewline -ForegroundColor Green
}

function Show-ActionToolsMenu {
    $contentHeight = 10
    $contentWidth = 80
    Set-WindowSize -contentHeight $contentHeight -contentWidth $contentWidth

    Clear-Host

    Show-AsciiArt

    Write-Host "`n"
    $width = $Host.UI.RawUI.WindowSize.Width
    $padding = " " * [math]::Floor(($width - 40) / 2)
    
    $title = $(Get-Translation 'ActionTools')
    $titlePadding = " " * [math]::Floor(($width - $title.Length) / 2)
    Write-Host "$padding+======================================+" -ForegroundColor Cyan
    Write-Host "$titlePadding$title$titlePadding" -ForegroundColor Cyan
    Write-Host "$padding+======================================+" -ForegroundColor Cyan
    Write-Host "`n"
    Write-Host "$padding+--------------------------------------+" -ForegroundColor Yellow
    Write-Host ("$padding|  [1] " + $(Get-Translation 'UpdateWindowsStoreApps')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [2] " + $(Get-Translation 'UpdateAllProgramsWithWinGet')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [3] " + $(Get-Translation 'RepairWindowsSystemFiles')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [4] " + $(Get-Translation 'WindowsDiskCleanup')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [5] " + $(Get-Translation 'CleanUnnecessaryFiles')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [6] " + $(Get-Translation 'ReleaseIPConfig')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [7] " + $(Get-Translation 'RenewIPConfig')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [8] " + $(Get-Translation 'FlushDNSCache')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [9] " + $(Get-Translation 'PingTest')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [10] " + $(Get-Translation 'RestartPrinter')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [11] " + $(Get-Translation 'ClearPrintQueue')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [12] " + $(Get-Translation 'EnableFirewall')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [13] " + $(Get-Translation 'DisableFirewall')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [14] " + $(Get-Translation 'UpdateGroupPolicies')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [15] " + $(Get-Translation 'StartSafeMode')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [16] " + $(Get-Translation 'ShutdownComputer')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [17] " + $(Get-Translation 'RestartComputer')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [18] " + $(Get-Translation 'RestartInSafeMode')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [19] " + $(Get-Translation 'DisableFastStartup')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [20] " + $(Get-Translation 'ReturnBasicToolsMenu')).PadRight($padding.Length + 38) "|" -ForegroundColor Red
    Write-Host "$padding+--------------------------------------+" -ForegroundColor Yellow
    Write-Host "`n"
    Write-Host "$padding$(Get-Translation 'SelectOption'): " -NoNewline -ForegroundColor Green
}

function Show-InformationToolsMenu {
    $contentHeight = 10
    $contentWidth = 80
    Set-WindowSize -contentHeight $contentHeight -contentWidth $contentWidth

    Clear-Host

    Show-AsciiArt

    Write-Host "`n"
    $width = $Host.UI.RawUI.WindowSize.Width
    $padding = " " * [math]::Floor(($width - 40) / 2)
    
    $title = $(Get-Translation 'InformationTools')
    $titlePadding = " " * [math]::Floor(($width - $title.Length) / 2)
    Write-Host "$padding+======================================+" -ForegroundColor Cyan
    Write-Host "$titlePadding$title$titlePadding" -ForegroundColor Cyan
    Write-Host "$padding+======================================+" -ForegroundColor Cyan
    Write-Host "`n"
    Write-Host "$padding+--------------------------------------+" -ForegroundColor Yellow
    Write-Host ("$padding|  [1] " + $(Get-Translation 'ShowComputerAndUserName')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [2] " + $(Get-Translation 'ShowComputerSerialNumber')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [3] " + $(Get-Translation 'GetSystemInformation')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [4] " + $(Get-Translation 'ShowWindowsLicenseStatus')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [5] " + $(Get-Translation 'ShowActiveWindowsLicense')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [6] " + $(Get-Translation 'ShowWindowsVersion')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [7] " + $(Get-Translation 'ShowSystemInfo')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [8] " + $(Get-Translation 'ListUserAccounts')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [9] " + $(Get-Translation 'ShowWifiPassword')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [10] " + $(Get-Translation 'ShowIPAddress')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [11] " + $(Get-Translation 'ShowFullIPConfig')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [12] " + $(Get-Translation 'CheckDiskStatus')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [13] " + $(Get-Translation 'ShowStorageStatus')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [14] " + $(Get-Translation 'ScanHardDisk')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [15] " + $(Get-Translation 'ShowCPUInfo')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [16] " + $(Get-Translation 'ShowRAMUsage')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [17] " + $(Get-Translation 'ShowPrinterStatus')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [18] " + $(Get-Translation 'ListInstalledPrinters')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [19] " + $(Get-Translation 'OpeningPort')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [20] " + $(Get-Translation 'ReturnBasicToolsMenu')).PadRight($padding.Length + 38) "|" -ForegroundColor Red
    Write-Host "$padding+--------------------------------------+" -ForegroundColor Yellow
    Write-Host "`n"
    Write-Host "$padding$(Get-Translation 'SelectOption'): " -NoNewline -ForegroundColor Green
}

function Show-ServicesMenu {
    $contentHeight = 15
    $contentWidth = 80
    Set-WindowSize -contentHeight $contentHeight -contentWidth $contentWidth

    Clear-Host

    Show-AsciiArt

    Write-Host "`n"
    $width = $Host.UI.RawUI.WindowSize.Width
    $padding = " " * [math]::Floor(($width - 40) / 2)
    
    $title = $(Get-Translation 'ServicesManagement')
    $titlePadding = " " * [math]::Floor(($width - $title.Length) / 2)
    Write-Host "$padding+======================================+" -ForegroundColor Cyan
    Write-Host "$titlePadding$title$titlePadding" -ForegroundColor Cyan
    Write-Host "$padding+======================================+" -ForegroundColor Cyan
    Write-Host "`n"
    Write-Host "$padding+--------------------------------------+" -ForegroundColor Yellow
    Write-Host ("$padding|  [1] " + $(Get-Translation 'DisableUnnecessaryServices')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [2] " + $(Get-Translation 'ReturnMainMenu')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host "$padding+--------------------------------------+" -ForegroundColor Yellow
    Write-Host "`n"
    Write-Host "$padding$(Get-Translation 'SelectOption'): " -NoNewline -ForegroundColor Green
}

function Show-PrivacyMenu {
    $contentHeight = 15
    $contentWidth = 80
    Set-WindowSize -contentHeight $contentHeight -contentWidth $contentWidth

    Clear-Host

    Show-AsciiArt

    Write-Host "`n"
    $width = $Host.UI.RawUI.WindowSize.Width
    $padding = " " * [math]::Floor(($width - 40) / 2)
    
    $title = $(Get-Translation 'PrivacySettings')
    $titlePadding = " " * [math]::Floor(($width - $title.Length) / 2)
    Write-Host "$padding+======================================+" -ForegroundColor Cyan
    Write-Host "$titlePadding$title$titlePadding" -ForegroundColor Cyan
    Write-Host "$padding+======================================+" -ForegroundColor Cyan
    Write-Host "`n"
    Write-Host "$padding+--------------------------------------+" -ForegroundColor Yellow
    Write-Host ("$padding| " + $(Get-Translation 'ShutUp10Info1')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding| " + $(Get-Translation 'ShutUp10Info2')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  " + $(Get-Translation 'space')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [1] " + $(Get-Translation 'ShutUp10++')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [2] " + $(Get-Translation 'ReturnMainMenu')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host "$padding+--------------------------------------+" -ForegroundColor Yellow
    Write-Host "`n"
    Write-Host "$padding$(Get-Translation 'SelectOption'): " -NoNewline -ForegroundColor Green
}

function Show-BloatwareMenu {
    $contentHeight = 15
    $contentWidth = 80
    Set-WindowSize -contentHeight $contentHeight -contentWidth $contentWidth

    Clear-Host

    Show-AsciiArt

    Write-Host "`n"
    $width = $Host.UI.RawUI.WindowSize.Width
    $padding = " " * [math]::Floor(($width - 40) / 2)
    
    $title = $(Get-Translation 'BloatwareRemoval')
    $titlePadding = " " * [math]::Floor(($width - $title.Length) / 2)
    Write-Host "$padding+======================================+" -ForegroundColor Cyan
    Write-Host "$titlePadding$title$titlePadding" -ForegroundColor Cyan
    Write-Host "$padding+======================================+" -ForegroundColor Cyan
    Write-Host "`n"
    Write-Host "$padding+--------------------------------------+" -ForegroundColor Yellow
    Write-Host ("$padding|  [1] " + $(Get-Translation 'SelectAndRemoveBloatware')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host ("$padding|  [2] " + $(Get-Translation 'ReturnMainMenu')).PadRight($padding.Length + 38) "|" -ForegroundColor White
    Write-Host "$padding+--------------------------------------+" -ForegroundColor Yellow
    Write-Host "`n"
    Write-Host "$padding$(Get-Translation 'SelectOption'): " -NoNewline -ForegroundColor Green
}

function Remove-SelectedBloatware {
    $bloatwareList = @(
        # Microsoft Temel Uygulamalar
        @{Name="Clipchamp.Clipchamp"; Group="Microsoft Basic"},
        @{Name="Microsoft.3DBuilder"; Group="Microsoft Basic"},
        @{Name="Microsoft.549981C3F5F10"; Group="Microsoft Basic"},
        @{Name="Microsoft.GetHelp"; Group="Microsoft Basic"},
        @{Name="Microsoft.Getstarted"; Group="Microsoft Basic"},
        @{Name="Microsoft.WindowsStore"; Group="Microsoft Basic"},
        @{Name="Microsoft.WindowsTerminal"; Group="Microsoft Basic"},
        @{Name="Microsoft.Windows.DevHome"; Group="Microsoft Basic"},

        # Microsoft Bing Uygulamaları
        @{Name="Microsoft.BingSearch"; Group="Microsoft Bing"},
        @{Name="Microsoft.BingFinance"; Group="Microsoft Bing"},
        @{Name="Microsoft.BingFoodAndDrink"; Group="Microsoft Bing"},
        @{Name="Microsoft.BingHealthAndFitness"; Group="Microsoft Bing"},
        @{Name="Microsoft.BingNews"; Group="Microsoft Bing"},
        @{Name="Microsoft.BingSports"; Group="Microsoft Bing"},
        @{Name="Microsoft.BingTranslator"; Group="Microsoft Bing"},
        @{Name="Microsoft.BingTravel"; Group="Microsoft Bing"},
        @{Name="Microsoft.BingWeather"; Group="Microsoft Bing"},

        # Microsoft Ofis ve Üretkenlik
        @{Name="Microsoft.MicrosoftOfficeHub"; Group="Microsoft Office"},
        @{Name="Microsoft.Office.OneNote"; Group="Microsoft Office"},
        @{Name="Microsoft.Office.Sway"; Group="Microsoft Office"},
        @{Name="Microsoft.Todos"; Group="Microsoft Office"},
        @{Name="Microsoft.MicrosoftStickyNotes"; Group="Microsoft Office"},
        @{Name="Microsoft.OutlookForWindows"; Group="Microsoft Office"},
        @{Name="Microsoft.PowerAutomateDesktop"; Group="Microsoft Office"},
        @{Name="Microsoft.MicrosoftPowerBIForWindows"; Group="Microsoft Office"},

        # Microsoft Yaratıcı Araçlar
        @{Name="Microsoft.MSPaint"; Group="Microsoft Creative"},
        @{Name="Microsoft.Paint"; Group="Microsoft Creative"},
        @{Name="Microsoft.ScreenSketch"; Group="Microsoft Creative"},
        @{Name="Microsoft.Whiteboard"; Group="Microsoft Creative"},
        @{Name="Microsoft.Windows.Photos"; Group="Microsoft Creative"},
        @{Name="Microsoft.WindowsCamera"; Group="Microsoft Creative"},
        @{Name="Microsoft.Microsoft3DViewer"; Group="Microsoft Creative"},
        @{Name="Microsoft.Print3D"; Group="Microsoft Creative"},
        @{Name="Microsoft.MicrosoftJournal"; Group="Microsoft Creative"},

        # Microsoft Xbox ve Oyun
        @{Name="Microsoft.XboxApp"; Group="Microsoft Gaming"},
        @{Name="Microsoft.Xbox.TCUI"; Group="Microsoft Gaming"},
        @{Name="Microsoft.XboxGameOverlay"; Group="Microsoft Gaming"},
        @{Name="Microsoft.XboxGamingOverlay"; Group="Microsoft Gaming"},
        @{Name="Microsoft.XboxIdentityProvider"; Group="Microsoft Gaming"},
        @{Name="Microsoft.XboxSpeechToTextOverlay"; Group="Microsoft Gaming"},
        @{Name="Microsoft.GamingApp"; Group="Microsoft Gaming"},
        @{Name="Microsoft.MicrosoftSolitaireCollection"; Group="Microsoft Gaming"},

        # Microsoft İletişim ve Medya
        @{Name="Microsoft.ZuneMusic"; Group="Microsoft Media"},
        @{Name="Microsoft.ZuneVideo"; Group="Microsoft Media"},
        @{Name="Microsoft.YourPhone"; Group="Microsoft Communication"},
        @{Name="Microsoft.Messaging"; Group="Microsoft Communication"},
        @{Name="Microsoft.People"; Group="Microsoft Communication"},
        @{Name="Microsoft.windowscommunicationsapps"; Group="Microsoft Communication"},
        @{Name="MicrosoftTeams"; Group="Microsoft Communication"},
        @{Name="MSTeams"; Group="Microsoft Communication"},
        @{Name="Microsoft.SkypeApp"; Group="Microsoft Communication"},
        @{Name="Microsoft.RemoteDesktop"; Group="Microsoft Communication"},
        @{Name="MicrosoftWindows.CrossDevice"; Group="Microsoft Communication"},

        # Microsoft Yardımcı Araçlar
        @{Name="Microsoft.WindowsAlarms"; Group="Microsoft Utilities"},
        @{Name="Microsoft.WindowsCalculator"; Group="Microsoft Utilities"},
        @{Name="Microsoft.WindowsFeedbackHub"; Group="Microsoft Utilities"},
        @{Name="Microsoft.WindowsMaps"; Group="Microsoft Utilities"},
        @{Name="Microsoft.WindowsNotepad"; Group="Microsoft Utilities"},
        @{Name="Microsoft.WindowsSoundRecorder"; Group="Microsoft Utilities"},
        @{Name="Microsoft.MixedReality.Portal"; Group="Microsoft Utilities"},
        @{Name="Microsoft.NetworkSpeedTest"; Group="Microsoft Utilities"},
        @{Name="Microsoft.OneConnect"; Group="Microsoft Utilities"},
        @{Name="MicrosoftCorporationII.QuickAssist"; Group="Microsoft Utilities"},

        # Microsoft AI ve Copilot
        @{Name="Microsoft.Copilot"; Group="Microsoft AI"},
        @{Name="Microsoft.OneDrive"; Group="Microsoft Cloud"},

        # Oyunlar ve Eğlence
        @{Name="Asphalt8Airborne"; Group="Games"},
        @{Name="CaesarsSlotsFreeCasino"; Group="Games"},
        @{Name="COOKINGFEVER"; Group="Games"},
        @{Name="DisneyMagicKingdoms"; Group="Games"},
        @{Name="FarmVille2CountryEscape"; Group="Games"},
        @{Name="HiddenCity"; Group="Games"},
        @{Name="king.com.BubbleWitch3Saga"; Group="Games"},
        @{Name="king.com.CandyCrushSaga"; Group="Games"},
        @{Name="king.com.CandyCrushSodaSaga"; Group="Games"},
        @{Name="MarchofEmpires"; Group="Games"},
        @{Name="Royal Revolt"; Group="Games"},

        # Medya ve Eğlence Uygulamaları
        @{Name="Netflix"; Group="Entertainment"},
        @{Name="Spotify"; Group="Entertainment"},
        @{Name="HULULLC.HULUPLUS"; Group="Entertainment"},
        @{Name="AmazonVideo.PrimeVideo"; Group="Entertainment"},
        @{Name="Plex"; Group="Entertainment"},
        @{Name="iHeartRadio"; Group="Entertainment"},
        @{Name="TuneInRadio"; Group="Entertainment"},
        @{Name="Shazam"; Group="Entertainment"},
        @{Name="ACGMediaPlayer"; Group="Entertainment"},
        @{Name="CyberLinkMediaSuiteEssentials"; Group="Entertainment"},

        # Sosyal Medya Uygulamaları
        @{Name="Facebook"; Group="Social Media"},
        @{Name="Instagram"; Group="Social Media"},
        @{Name="Twitter"; Group="Social Media"},
        @{Name="LinkedInforWindows"; Group="Social Media"},
        @{Name="TikTok"; Group="Social Media"},
        @{Name="Viber"; Group="Social Media"},
        @{Name="Flipboard"; Group="Social Media"},

        # Üretkenlik ve Araçlar
        @{Name="ActiproSoftwareLLC"; Group="Productivity"},
        @{Name="AdobeSystemsIncorporated.AdobePhotoshopExpress"; Group="Productivity"},
        @{Name="AutodeskSketchBook"; Group="Productivity"},
        @{Name="DrawboardPDF"; Group="Productivity"},
        @{Name="EclipseManager"; Group="Productivity"},
        @{Name="OneCalendar"; Group="Productivity"},
        @{Name="PhototasticCollage"; Group="Productivity"},
        @{Name="PicsArt-PhotoStudio"; Group="Productivity"},
        @{Name="PolarrPhotoEditorAcademicEdition"; Group="Productivity"},
        @{Name="WinZipUniversal"; Group="Productivity"},
        @{Name="Wunderlist"; Group="Productivity"},

        # Alışveriş ve Yaşam Tarzı
        @{Name="Amazon.com.Amazon"; Group="Shopping"},
        @{Name="Disney"; Group="Lifestyle"},
        @{Name="Duolingo-LearnLanguagesforFree"; Group="Education"},
        @{Name="fitbit"; Group="Health"},
        @{Name="NYTCrossword"; Group="Entertainment"},
        @{Name="PandoraMediaInc"; Group="Entertainment"},
        @{Name="Sidia.LiveWallpaper"; Group="Customization"},
        @{Name="SlingTV"; Group="Entertainment"},
        @{Name="XING"; Group="Business"}
    )

    $itemsPerPage = 10
    $currentPage = 0
    $totalPages = [math]::Ceiling($bloatwareList.Count / $itemsPerPage)
    $selectedApps = New-Object System.Collections.ArrayList

    do {
        $width = $Host.UI.RawUI.WindowSize.Width
        $padding = " " * [math]::Floor(($width - 40) / 2)

        Clear-Host

        Show-AsciiArt

        Write-Host "`n" $padding (Get-Translation 'BloatwareRemovalPage') "$($currentPage + 1) of $totalPages`n" -ForegroundColor Cyan
        Write-Host $padding (Get-Translation 'CurrentGroup')": $($bloatwareList[$currentPage * $itemsPerPage].Group)`n" -ForegroundColor Yellow

        # Sayfadaki öğeleri göster
        $startIndex = $currentPage * $itemsPerPage
        $endIndex = [Math]::Min($startIndex + $itemsPerPage, $bloatwareList.Count)

        for ($i = $startIndex; $i -lt $endIndex; $i++) {
            $isSelected = $selectedApps.Contains($i)
            $marker = if ($isSelected) { "[X]" } else { "[ ]" }
            Write-Host $padding "$marker [$i] $($bloatwareList[$i].Name)" -ForegroundColor $(if ($isSelected) { "Green" } else { "White" })
        }

        Write-Host "`n" $padding(Get-Translation 'Navigation') -ForegroundColor Cyan
        Write-Host ""
        Write-Host $padding "[N] " (Get-Translation 'NextPage') -ForegroundColor Yellow
        Write-Host $padding "[P] " (Get-Translation 'PreviousPage') -ForegroundColor Yellow
        Write-Host $padding "[A] " (Get-Translation 'SelectAllOnPage') -ForegroundColor Yellow
        Write-Host $padding "[C] " (Get-Translation 'ClearAllSelections') -ForegroundColor Yellow
        Write-Host $padding "[R] " (Get-Translation 'RemoveSelectedApps') -ForegroundColor Red
        Write-Host $padding "[Q] " (Get-Translation 'Quit') -ForegroundColor Magenta

        $choice = Read-Host "`n" $padding + (Get-Translation 'YourChoice')
        
        switch ($choice) {
            "N" { 
                if ($currentPage -lt $totalPages - 1) { $currentPage++ } 
            }
            "P" { 
                if ($currentPage -gt 0) { $currentPage-- } 
            }
            "A" { 
                # Sayfadaki tüm uygulamaları seç
                for ($i = $startIndex; $i -lt $endIndex; $i++) {
                    if (-not $selectedApps.Contains($i)) {
                        $selectedApps.Add($i) | Out-Null
                    }
                }
            }
            "C" { 
                # Sayfadaki seçimleri temizle
                for ($i = $startIndex; $i -lt $endIndex; $i++) {
                    $selectedApps.Remove($i) | Out-Null
                }
            }
            "R" { 
                if ($selectedApps.Count -gt 0) {
                    Write-Host "`n " $padding (Get-Translation 'RemovingSelectedApps') -ForegroundColor Yellow
                    foreach ($index in $selectedApps) {
                        $app = $bloatwareList[$index].Name
                        Write-Host $padding (Get-Translation 'Removing') ": $app" -ForegroundColor Yellow
                        Get-AppxPackage -Name $app | Remove-AppxPackage -ErrorAction SilentlyContinue
                    }
                    $selectedApps.Clear()
                    Write-Host $padding (Get-Translation 'SelectedAppsRemoved') -ForegroundColor Green
                    pause
                } else {
                    Write-Host "`n" $padding (Get-Translation 'SelectAppsFirst') -ForegroundColor Red
                    pause
                }
            }
            "Q" { return }
            default {
                if ($choice -match "^\d+$") {
                    $num = [int]$choice
                    if ($num -ge $startIndex -and $num -lt $endIndex) {
                        if ($selectedApps.Contains($num)) {
                            $selectedApps.Remove($num) | Out-Null
                        } else {
                            $selectedApps.Add($num) | Out-Null
                        }
                    }
                }
            }
        }
    } while ($choice -ne "Q")
}

# Winget kontrol ve kurulum fonksiyonu
function Test-WingetInstalled {
    try {
        # Winget yüklü mü kontrol et
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Write-Host (Get-Translation 'WingetNotInstalled') -ForegroundColor Yellow
            
            # Winget kurulumunu başlat
            Install-PackageProvider -Name NuGet -Force | Out-Null
            Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery | Out-Null
            
            # Winget yükleme işlemi tamamlanana kadar bekle
            Start-Process -FilePath "powershell.exe" -ArgumentList "-Command Repair-WinGetPackageManager" -Wait -NoNewWindow
            
            Write-Host (Get-Translation 'WingetInstalled') -ForegroundColor Green
        } else {
            Write-Host (Get-Translation 'WingetAlreadyInstalled') -ForegroundColor Green
        }
    } catch {
        Write-Host (Get-Translation 'WingetInstallError') -ForegroundColor Red
    }
}

# Main program loop
try {
    # Ana program döngüsünden önce winget kontrolü
    Test-WingetInstalled

    do {
        Clear-Host
        Show-Menu
        $selection = Read-Host
        switch ($selection) {
            "1" {
                do {
                    Clear-Host
                    Show-BasicToolsMenu
                    $choice = Read-Host
                    switch ($choice) {
                        "1" {
                            do {
                                Clear-Host
                                Show-ActionToolsMenu
                                $actionChoice = Read-Host
                                switch ($actionChoice) {
                                    "1" { Start-Process "ms-windows-store://updates" }
                                    "2" { winget upgrade --all }
                                    "3" { sfc /scannow }
                                    "4" { Start-Process "cleanmgr" }
                                    "5" {
                                        $paths = @(
                                            "$env:SystemDrive\*.old", "$env:SystemDrive\*._mp", "$env:SystemDrive\*.bak",
                                            "$env:SystemDrive\*.log", "$env:SystemDrive\*.tmp", "$env:SystemDrive\*.chk",
                                            "$env:SystemDrive\*.gid", "$env:SystemDrive\RECYCLER\*.*", "$env:WinDir\Temp\*.*",
                                            "$env:WinDir\Prefetch\*.*", "$env:WinDir\Driver Cache\i386\*.*",
                                            "$env:WinDir\SoftwareDistribution\Download\*.*", "$env:UserProfile\AppData\Local\Temp\*.*"
                                        )
                                        foreach ($path in $paths) {
                                            if (Test-Path $path) {
                                                Remove-Item -Path $path -Force -Recurse -ErrorAction SilentlyContinue
                                                Write-Host "$(Get-Translation 'Deleted'): $path"
                                            }
                                        }
                                        Pause
                                    }
                                    "6" { ipconfig /release }
                                    "7" { ipconfig /renew }
                                    "8" { ipconfig /flushdns }
                                    "9" { $target = Read-Host "$(Get-Translation 'Pinging')"; ping $target }
                                    "10" { Restart-Service Spooler }
                                    "11" { net stop spooler; Remove-Item C:\Windows\System32\spool\PRINTERS\* -Force; net start spooler }
                                    "12" { Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True }
                                    "13" { Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False }
                                    "14" { gpupdate /force }
                                    "15" { bcdedit /set {default} safeboot minimal; Restart-Computer }
                                    "16" { Stop-Computer }
                                    "17" { Restart-Computer }
                                    "18" { bcdedit /set {default} safeboot minimal; Restart-Computer }
                                    "19" { powercfg /h off }
                                    "20" { break }
                                    default { Write-Host "`n     [!] " $(Get-Translation 'InvalidSelection') -ForegroundColor Red; pause }
                                }
                            } while ($actionChoice -ne "20")
                        }
                        "2" {
                            do {
                                Clear-Host
                                Show-InformationToolsMenu
                                $infoChoice = Read-Host
                                switch ($infoChoice) {
                                    "1" {
                                        Write-Host "`n     [*] Computer Name: $env:COMPUTERNAME" -ForegroundColor Green
                                        Write-Host "     [*] Active User: $env:USERNAME" -ForegroundColor Green
                                        pause
                                    }
                                    "2" {
                                        $serialNumber = Get-WmiObject -Class Win32_BIOS | Select-Object -ExpandProperty SerialNumber
                                        Write-Host "`n     [*] Computer Serial Number: $serialNumber" -ForegroundColor Green
                                        pause
                                    }
                                    "3" { systeminfo; pause }
                                    "4" { slmgr /xpr; pause }
                                    "5" { slmgr /dlv; pause }
                                    "6" { Start-Process "winver"; pause }
                                    "7" { systeminfo; pause }
                                    "8" { Get-LocalUser; pause }
                                    "9" {
                                        $wifiName = Read-Host (Get-Translation 'WiFiName')
                                        $wifiInfo = netsh wlan show profile name="$wifiName" key=clear 2>&1

                                        # Hata kontrolü (Wi-Fi profili bulunamazsa)
                                        if ($wifiInfo -match "The system cannot find the file specified|belirtilen dosya bulunamıyor") {
                                            Write-Host "`n[ERROR] "(Get-Translation 'WiFiProfileNotFound') -ForegroundColor Red
                                            pause
                                            exit
                                        }

                                        # Çıktıdaki "Key Content" satırını bul ve içeriğini al
                                        $keyContent = ($wifiInfo | Select-String "Key Content") -replace ".*Key Content\s+:\s+",""

                                        if ($keyContent) {
                                            Write-Host "`n" (Get-Translation 'WiFiPassword')": $keyContent" -ForegroundColor Green
                                        } else {
                                            Write-Host "`n[ERROR] "(Get-Translation 'NoPasswordFound') -ForegroundColor Yellow
                                        }

                                        pause

                                    }
                                    "10" { ipconfig; pause }
                                    "11" { ipconfig /all; pause }
                                    "12" { Get-PhysicalDisk; pause }
                                    "13" { Get-PSDrive; pause }
                                    "14" { chkdsk; pause }
                                    "15" { Get-CimInstance Win32_Processor; pause }
                                    "16" {
                                        $freeRAM = [math]::Round((Get-WmiObject Win32_OperatingSystem).FreePhysicalMemory / 1024, 2)
                                        Write-Host "$freeRAM MB RAM bos durumda." -ForegroundColor Green
                                        pause
                                    }
                                    "17" { Get-Printer; pause }
                                    "18" { Get-Printer | Select-Object Name; pause }
                                    "19" {  netstat -an; pause }
                                    "20" { break }
                                    default { Write-Host "`n     [!] " $(Get-Translation 'InvalidSelection') -ForegroundColor Red; pause }
                                }
                            } while ($infoChoice -ne "20")
                        }
                        "3" { break }
                        default { Write-Host "`n     [!] " $(Get-Translation 'InvalidSelection') -ForegroundColor Red; pause }
                    }
                } while ($choice -ne "3")
            }
            "2" {
                do {
                    Clear-Host
                    Show-ServicesMenu
                    $choice = Read-Host
                    switch ($choice) {
                        "1" {
                            $services = @(
                                "DiagTrack","dmwappushservice","lfsvc","MapsBroker","NetTcpPortSharing","RemoteAccess","RemoteRegistry","SharedAccess","TrkWks","WbioSrvc","WMPNetworkSvc","WSearch","XblAuthManager","XblGameSave","XboxNetApiSvc",
                                "XboxGipSvc","WerSvc","Spooler","Fax","fhsvc","gupdate","gupdatem","stisvc","AJRouter","MSDTC","WpcMonSvc","PhoneSvc",
                                "PcaSvc","WPDBusEnum","SysMain","wisvc","FontCache","RetailDemo","SCardSvr","SCPolicySvc","ScDeviceEnum",
                                "EntAppSvc","BDESVC","BcastDVRUserService_48486de","CaptureService_48486de","DoSvc","tapisrv","PenService_34048","SensorDataService","SEMgrSvc"
                            )
                            $itemsPerPage = 10
                            $currentPage = 0
                            $totalPages = [math]::Ceiling($services.Count / $itemsPerPage)
                            do {
                                Clear-Host
                                $width = $Host.UI.RawUI.WindowSize.Width
                                $padding = " " * [math]::Floor(($width - 40) / 2)

                                Show-AsciiArt

                                Write-Host "`n" $padding (Get-Translation 'ServicesManagement') "- Page $($currentPage + 1) of $totalPages`n" -ForegroundColor Cyan

                                $startIndex = $currentPage * $itemsPerPage
                                $endIndex = [Math]::Min($startIndex + $itemsPerPage, $services.Count)

                                for ($i = $startIndex; $i -lt $endIndex; $i++) {
                                    Write-Host $padding "[$($i + 1)] $($services[$i])" -ForegroundColor White
                                }

                                Write-Host "`n" $padding(Get-Translation 'Navigation') -ForegroundColor Cyan
                                Write-Host ""
                                Write-Host $padding "[N] " (Get-Translation 'NextPage') -ForegroundColor Yellow
                                Write-Host $padding "[P] " (Get-Translation 'PreviousPage') -ForegroundColor Yellow
                                Write-Host $padding "[Q] " (Get-Translation 'Quit') -ForegroundColor Red
                                
                                $serviceChoice = Read-Host "`n" $padding "[*] " (Get-Translation 'SelectService')
                            
                                switch ($serviceChoice) {
                                    "N" {
                                        if ($currentPage -lt $totalPages - 1) { $currentPage++ }
                                    }
                                    "P" {
                                        if ($currentPage -gt 0) { $currentPage-- }
                                    }
                                    default {
                                        if ($serviceChoice -eq "Q") { break }
                                        if ($serviceChoice -match "^\d+$") {
                                            $num = [int]$serviceChoice - 1
                                            if ($num -ge $startIndex -and $num -lt $endIndex) {
                                                $selectedService = $services[$num]
                                                Get-Service -Name $selectedService | Stop-Service -Force | Out-File -FilePath  ".\log.txt" -Append
                                                Get-Service -Name $selectedService | Set-Service -StartupType Disabled | Out-File -FilePath  ".\log.txt" -Append
                                                Write-Output "Disabled $selectedService" | Out-File -FilePath  ".\log.txt" -Append
                                                Write-Host "`n" $padding "[*] $selectedService" (Get-Translation 'HasBeenDisabled') -ForegroundColor Green
                                            } else {
                                                Write-Host "`n" $padding "[!] " (Get-Translation 'InvalidSelection') -ForegroundColor Red
                                            }
                                        }
                                        pause
                                    }
                                }
                            } while ($serviceChoice -ne "Q")
                            
                        }
                        "2" { break }
                        default { Write-Host "`n     [!] " $(Get-Translation 'InvalidSelection') -ForegroundColor Red; pause }
                    }
                } while ($choice -ne "2")
            }
            "3" {
                do {
                    Clear-Host
                    Show-PrivacyMenu
                    $choice = Read-Host
                    switch ($choice) {
                        "1" {
                            Write-Host "`n     [*] O&O ShutUp10++ is running..." -ForegroundColor Green
                            winget install --id=OO-Software.ShutUp10 -e; Start-Process "shutup10.exe"
                            pause
                        }
                        "2" {break}
                        default { Write-Host "`n     [!] " $(Get-Translation 'InvalidSelection') -ForegroundColor Red; pause }

                    }
                } while ($choice -ne "2")
            }
            "4" {
                do {
                    Clear-Host
                    Show-BloatwareMenu
                    $choice = Read-Host
                    switch ($choice) {
                        "1" {
                            Remove-SelectedBloatware
                        }
                        "2" { break }
                        default { Write-Host "`n     [!] " $(Get-Translation 'InvalidSelection') -ForegroundColor Red; pause }
                    }
                } while ($choice -ne "2")
            }
            "5" {
                $repoUrl = "https://github.com/burakarslan0110/WinToolify/archive/refs/heads/main.zip"
                $zipPath = "$env:TEMP\WinToolify-main.zip"
                $extractPath = "$env:TEMP\WinToolify-main"

                Write-Host "`n"
                Write-Host (Get-Translation 'VCRedistDownloading') -ForegroundColor Green
                # ZIP dosyasını indir
                $webClient = New-Object System.Net.WebClient
                $webClient.DownloadFile($repoUrl, $zipPath)


                # ZIP içeriğini çıkart
                Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

                # BAT dosyasının tam yolu
                $batFilePath = "$extractPath\WinToolify-main\Visual-C-Runtimes-WinToolify\install_all.bat"

                # BAT dosyasını çalıştır
                Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$batFilePath`"" -Wait -NoNewWindow

                Write-Host (Get-Translation 'VCRedistInstalling') -ForegroundColor Green
                cmd.exe /c "pause"
            }
            "6" {
                do {
                    Clear-Host
                    Show-LanguageMenu
                    $choice = Read-Host
                    switch ($choice) {
                        "1" {
                            $script:Language = "EN"
                            Write-Host "`n     [*] Language set to English..." -ForegroundColor Green
                            pause
                        }
                        "2" {
                            $script:Language = "TR"
                            Write-Host "`n     [*] Language set to Turkish..." -ForegroundColor Green
                            pause
                        }
                        "3" { break }
                        default { Write-Host "`n     [!] " $(Get-Translation 'InvalidSelection') -ForegroundColor Red; pause }
                    }
                } while ($choice -ne "3")
            }
            
            "Q" { return }
            "q" { return }
            default { Write-Host "`n     [!] " $(Get-Translation 'InvalidSelection') -ForegroundColor Red; pause }
        }
    } while ($true)
} finally {
    # Eğer yeni bir pencere açıldıysa, kapat
    if ($Host.Name -eq 'ConsoleHost') {
        Stop-Process -Id $PID
    }
}
