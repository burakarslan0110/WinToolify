# The assistant's search-tag table: tags and a one-sentence description in
# each language for every row, screen, action and toggle the search index folds.
# Covered by: tests/AssistantIndex.Tests.ps1

function Get-WtAssistantSearchTagTable {
    <#
    .SYNOPSIS
        Id -> @{ Tags; En; Tr }. Ids are index ids: a row name, Screen:X or
        Section:Name. Tags are one space-separated string.
    #>
    return @{
        'RestartExplorerAction' = @{ Tags = 'explorer gezgin donuyor gorev cubugu taskbar kayboldu masaustu yanit vermiyor yeniden baslat restart'
            En = 'Kills and restarts explorer.exe - the taskbar, Start menu and desktop - for a frozen taskbar or a desktop that stopped responding.'
            Tr = 'explorer.exe surecini (gorev cubugu, Baslat menusu, masaustu) kapatip yeniden baslatir; donan gorev cubugu veya yanit vermeyen masaustu icin.' }
        'RepairStartMenu' = @{ Tags = 'baslat menusu acilmiyor calismiyor start menu broken arama kutusu'
            En = 'Re-registers the Start menu and shell experience packages when the Start menu will not open or its search is dead.'
            Tr = 'Baslat menusu acilmiyor veya aramasi calismiyorsa Baslat menusu ve kabuk paketlerini yeniden kaydeder.' }
        'RebuildExplorerCaches' = @{ Tags = 'simge onbellek bozuk ikon kucuk resim thumbnail icon cache beyaz simgeler yanlis simge'
            En = 'Deletes the icon and thumbnail cache databases so wrong, blank or stale icons and thumbnails are rebuilt.'
            Tr = 'Yanlis, bos veya eski simge ve kucuk resimler icin simge ve kucuk resim onbellek veritabanlarini silip yeniden olusturtur.' }
        'RestartAudioServices' = @{ Tags = 'ses yok ses gelmiyor ses calismiyor hoparlor kulaklik mikrofon no sound audio'
            En = 'Restarts the Windows Audio and Audio Endpoint Builder services - the first thing to try when there is suddenly no sound.'
            Tr = 'Windows Audio ve Audio Endpoint Builder hizmetlerini yeniden baslatir; aniden ses gelmiyorsa ilk denenecek adim.' }
        'RestartPrinter' = @{ Tags = 'yazici sorunu yazdirmiyor yazici calismiyor yazdirma kuyrugu takildi printer not printing spooler'
            En = 'Restarts the Print Spooler service so a stuck printer starts taking jobs again.'
            Tr = 'Takilan yazicinin yeniden is almasi icin Print Spooler (yazdirma bicimlendirici) hizmetini yeniden baslatir.' }
        'ClearPrintQueue' = @{ Tags = 'yazici kuyrugu temizle takilan yazdirma isi silinmiyor print queue stuck job'
            En = 'Stops the spooler, deletes every waiting print job from the queue and starts the spooler again.'
            Tr = 'Yazdirma bicimlendiriciyi durdurur, kuyruktaki tum bekleyen isleri siler ve hizmeti yeniden baslatir.' }
        'CloseNotRespondingApps' = @{ Tags = 'donmus donan program kilitlenen uygulama yanit vermiyor kapat frozen hang not responding kill'
            En = 'Lists the programs Windows reports as not responding and closes the ones you pick.'
            Tr = 'Windows''un yanit vermiyor dedigi programlari listeler ve sectiklerinizi kapatir.' }
        'FreeMemory' = @{ Tags = 'ram bosalt bellek doldu bilgisayarim yavas yavasladi kasiyor donuyor performans hizlandir slow pc lag memory full'
            En = 'Trims the working sets of running processes and empties the standby list to free RAM on a slow, memory-starved machine.'
            Tr = 'Calisan islemlerin bellek kumelerini kirpar ve bekleme listesini bosaltir; RAM''i dolmus, yavaslamis bir bilgisayarda bellek acar.' }
        'RepairWindowsSystemFiles' = @{ Tags = 'sfc scannow sistem dosyalari bozuk windows onar hata veriyor corrupt system files repair'
            En = 'Runs sfc /scannow to find and replace corrupted Windows system files; takes 5-15 minutes.'
            Tr = 'Bozuk Windows sistem dosyalarini bulup degistirmek icin sfc /scannow calistirir; 5-15 dakika surer.' }
        'RepairComponentStore' = @{ Tags = 'dism restorehealth bilesen deposu onar sfc calismiyor windows update hatasi windows onar'
            En = 'Runs DISM /RestoreHealth to repair the component store that sfc and Windows Update draw from; 10-30 minutes.'
            Tr = 'sfc ve Windows Update''in kaynak aldigi bilesen deposunu onarmak icin DISM /RestoreHealth calistirir; 10-30 dakika.' }
        'ResetWindowsUpdateComponents' = @{ Tags = 'windows update calismiyor guncelleme hatasi guncelleme takildi indirmiyor yukleme basarisiz update stuck failed'
            En = 'Stops the update services, renames SoftwareDistribution and catroot2 and re-registers the update components for updates that fail or hang.'
            Tr = 'Basarisiz olan veya takilan guncellemeler icin update hizmetlerini durdurur, SoftwareDistribution ve catroot2 klasorlerini yeniden adlandirir ve bilesenleri yeniden kaydeder.' }
        'RebuildSearchIndex' = @{ Tags = 'arama calismiyor dosya bulamiyor windows search dizin indeks search index broken'
            En = 'Deletes and rebuilds the Windows Search index when search finds nothing or shows stale results.'
            Tr = 'Windows aramasi hicbir sey bulmuyor veya eski sonuc gosteriyorsa arama dizinini silip yeniden olusturur.' }
        'RepairWmiRepository' = @{ Tags = 'wmi hatasi wmi repository bozuk sistem bilgisi alinamiyor powershell get-ciminstance hata'
            En = 'Verifies the WMI repository and salvages it when inconsistent - for WMI errors, failing management tools or missing system information.'
            Tr = 'WMI deposunu dogrular, tutarsizsa kurtarir; WMI hatalari, calismayan yonetim araclari veya alinamayan sistem bilgisi icin.' }
        'RestorePowerSchemeDefaults' = @{ Tags = 'guc plani kayboldu yuksek performans yok guc ayarlari bozuk power plan missing restore'
            En = 'Restores the built-in Balanced, High performance and Power saver plans when they are missing or misconfigured.'
            Tr = 'Yerlesik Dengeli, Yuksek performans ve Guc tasarrufu planlari kaybolmus veya bozulmussa geri getirir.' }
        'UpdateGroupPolicies' = @{ Tags = 'gpupdate grup ilkesi yenile politika uygulanmadi group policy refresh'
            En = 'Runs gpupdate /force so changed local or domain policies take effect without a reboot.'
            Tr = 'Degisen yerel veya etki alani ilkelerinin yeniden baslatmadan uygulanmasi icin gpupdate /force calistirir.' }
        'FlushDNSCache' = @{ Tags = 'dns onbellek temizle site acilmiyor sayfa bulunamadi dns hatasi flushdns'
            En = 'Clears the DNS resolver cache so stale or wrong name lookups stop breaking sites that will not open.'
            Tr = 'Acilmayan siteler ve yanlis ad cozumlemeleri icin DNS cozumleyici onbellegini temizler.' }
        'RenewIpLease' = @{ Tags = 'ip adresi yenile ip al dhcp baglanti sinirli internet yok limited connectivity'
            En = 'Releases and renews the DHCP lease to get a fresh IP address on a limited or broken connection.'
            Tr = 'Sinirli veya bozuk baglantida yeni bir IP adresi almak icin DHCP kirasini birakip yeniler.' }
        'PingTest' = @{ Tags = 'ping gecikme paket kaybi baglanti testi sunucuya ulasilamiyor latency packet loss'
            En = 'Pings a host you name and reports reachability, latency and packet loss.'
            Tr = 'Belirttiginiz adrese ping atar; erisilebilirlik, gecikme ve paket kaybini bildirir.' }
        'RestartNetworkAdapters' = @{ Tags = 'ag adaptoru yeniden baslat ethernet wifi kart calismiyor baglanti kopuyor network adapter reset'
            En = 'Disables and re-enables every physical network adapter - a quick fix for a dropping or dead connection.'
            Tr = 'Tum fiziksel ag adaptorlerini kapatip yeniden acar; kopan veya olmus baglanti icin hizli cozum.' }
        'ForgetWifiProfile' = @{ Tags = 'wifi agi unut kayitli ag sil kablosuz sifre degisti baglanamiyor forget network'
            En = 'Deletes a saved Wi-Fi profile so you can reconnect from scratch, e.g. after the router password changed.'
            Tr = 'Kayitli bir Wi-Fi profilini siler; modem sifresi degistiginde bastan baglanmak icin.' }
        'ResetWinsock' = @{ Tags = 'winsock sifirla internet yok tarayici acilmiyor lsp ag sifirla netsh'
            En = 'Runs netsh winsock reset to clear a corrupted Winsock catalog when programs cannot reach the network although Windows says it is connected.'
            Tr = 'Windows bagli dese de programlar aga cikamiyorsa bozuk Winsock katalogunu netsh winsock reset ile temizler.' }
        'ResetTcpIpStack' = @{ Tags = 'internet yok baglanti yok ag sorunu tcp ip sifirla ag ayarlari sifirla no internet connection network reset'
            En = 'Resets the TCP/IP stack to its installation defaults - the deep network reset for no internet at all; needs a restart.'
            Tr = 'TCP/IP yiginini kurulum varsayilanlarina dondurur; hic internet yoksa uygulanan derin ag sifirlamasi, yeniden baslatma ister.' }
        'ResetWinHttpProxy' = @{ Tags = 'proxy sifirla proxy sunucusu yanit vermiyor windows update proxy hatasi vekil sunucu'
            En = 'Clears the WinHTTP proxy setting that Windows Update and system services use when a leftover proxy blocks them.'
            Tr = 'Windows Update ve sistem hizmetlerinin kullandigi WinHTTP proxy ayarini temizler; kalan bir proxy onlari engelliyorsa.' }
        'ResetHostsFile' = @{ Tags = 'hosts sifirla hosts dosyasi varsayilan site engellendi yonlendirme reset hosts'
            En = 'Replaces the Hosts file with the Windows default, removing every custom or malicious redirect.'
            Tr = 'Hosts dosyasini Windows varsayilaniyla degistirir; tum ozel veya kotu amacli yonlendirmeleri kaldirir.' }
        'ResetFirewallRules' = @{ Tags = 'guvenlik duvari sifirla firewall kurallari program engelleniyor baglanti engelleniyor reset firewall'
            En = 'Resets Windows Firewall to its default rule set, dropping every custom allow and block rule.'
            Tr = 'Windows Guvenlik Duvari''ni varsayilan kural setine dondurur; tum ozel izin ve engel kurallarini kaldirir.' }
        'WindowsDiskCleanup' = @{ Tags = 'disk temizle disk doldu yer ac gecici dosyalar cleanmgr disk cleanup free space'
            En = 'Opens the built-in Disk Cleanup with the system categories preselected to free space.'
            Tr = 'Yer acmak icin yerlesik Disk Temizleme''yi sistem kategorileri onceden secili olarak acar.' }
        'CleanUnnecessaryFiles' = @{ Tags = 'gereksiz dosya temizle disk doldu yer ac temp gecici dosyalar onbellek cop kutusu junk files'
            En = 'Previews the temp folders, caches, logs and Recycle Bin it would clear with their sizes, then deletes what you confirm.'
            Tr = 'Temizleyecegi gecici klasor, onbellek, gunluk ve Geri Donusum Kutusu icerigini boyutlariyla onizler, onayladiklarinizi siler.' }
        'ClearBrowserCaches' = @{ Tags = 'tarayici onbellek temizle chrome edge firefox cache yer ac browser cache'
            En = 'Clears the cache folders of Chrome, Edge, Firefox and other installed browsers (not passwords or history).'
            Tr = 'Chrome, Edge, Firefox ve diger kurulu tarayicilarin onbellek klasorlerini temizler (sifre ve gecmise dokunmaz).' }
        'CleanComponentStore' = @{ Tags = 'winsxs kucult bilesen deposu temizle disk doldu windows klasoru buyuk dism cleanup'
            En = 'Runs DISM /StartComponentCleanup to shrink WinSxS by removing superseded component versions; 10-30 minutes.'
            Tr = 'Eski bilesen surumlerini kaldirarak WinSxS''i kucultmek icin DISM /StartComponentCleanup calistirir; 10-30 dakika.' }
        'DuplicateFinder' = @{ Tags = 'cift dosya kopya dosya ayni dosya yinelenen bul duplicate files yer ac'
            En = 'Scans a folder you choose for files with identical content and lets you delete the duplicates.'
            Tr = 'Sectiginiz klasorde icerigi ayni olan dosyalari bulur ve kopyalarini silmenizi saglar.' }
        'OptimizeVolumes' = @{ Tags = 'disk birlestir defrag trim ssd optimize disk yavas defragment'
            En = 'Runs Optimize-Volume on every fixed drive: TRIM for SSDs, defragmentation for hard disks; can take up to an hour.'
            Tr = 'Her sabit surucude Optimize-Volume calistirir: SSD icin TRIM, sabit disk icin birlestirme; bir saate kadar surebilir.' }
        'ScheduleDiskRepair' = @{ Tags = 'chkdsk onar disk hatasi bozuk sektor acilista disk kontrolu disk repair'
            En = 'Schedules chkdsk /f on the system drive for the next boot to repair file-system errors and bad sectors.'
            Tr = 'Dosya sistemi hatalari ve bozuk sektorler icin bir sonraki acilista sistem surucusunde chkdsk /f planlar.' }
        'DeleteOldRestorePoints' = @{ Tags = 'geri yukleme noktalari sil eski restore point yer ac golge kopya'
            En = 'Deletes every restore point except the newest to reclaim shadow storage space.'
            Tr = 'Golge depolama alani kazanmak icin en yenisi disindaki tum geri yukleme noktalarini siler.' }
        'UpdateWindowsStoreApps' = @{ Tags = 'store uygulamalari guncelle magaza guncelleme microsoft store update apps'
            En = 'Asks the Microsoft Store to check for and install updates for every installed Store app.'
            Tr = 'Microsoft Store''dan kurulu tum Store uygulamalari icin guncelleme denetleyip yuklemesini ister.' }
        'UpdateAllProgramsWithWinGet' = @{ Tags = 'programlari guncelle tum programlar winget upgrade all yazilim guncelleme'
            En = 'Runs winget upgrade --all to update every program winget knows about.'
            Tr = 'winget''in tanidigi tum programlari guncellemek icin winget upgrade --all calistirir.' }
        'WingetUpgradeSinglePackage' = @{ Tags = 'tek program guncelle winget upgrade paket guncelle'
            En = 'Updates one program you name through winget.'
            Tr = 'Adini verdiginiz tek bir programi winget ile gunceller.' }
        'UninstallProgram' = @{ Tags = 'program kaldir yazilim sil uninstall remove program masaustu uygulama'
            En = 'Lists the installed desktop programs and uninstalls the one you pick through its own uninstaller.'
            Tr = 'Kurulu masaustu programlarini listeler ve sectiginizi kendi kaldiricisiyla kaldirir.' }
        'ResetStoreCache' = @{ Tags = 'microsoft store acilmiyor store hatasi wsreset magaza onbellek'
            En = 'Runs wsreset to clear the Microsoft Store cache when the Store will not open or downloads hang.'
            Tr = 'Store acilmiyor veya indirmeler takiliyorsa Microsoft Store onbellegini wsreset ile temizler.' }
        'ReRegisterStoreApp' = @{ Tags = 'microsoft store onar store yok store kayboldu magaza yeniden kur re-register'
            En = 'Re-registers the Microsoft Store app package when the Store is missing or broken.'
            Tr = 'Microsoft Store kaybolmus veya bozulmussa Store uygulama paketini yeniden kaydeder.' }
        'BackupRegistry' = @{ Tags = 'kayit defteri yedekle regedit yedek registry backup export'
            En = 'Exports the HKLM and HKCU hives to .reg files on the desktop; 1-3 minutes.'
            Tr = 'HKLM ve HKCU dallarini masaustune .reg dosyalari olarak disa aktarir; 1-3 dakika.' }
        'ExportDrivers' = @{ Tags = 'surucu yedekle driver backup export format oncesi suruculeri kaydet'
            En = 'Exports every installed third-party driver to a folder so they can be reinstalled after a clean install.'
            Tr = 'Temiz kurulumdan sonra geri yuklenebilmeleri icin kurulu tum ucuncu parti suruculeri bir klasore aktarir.' }
        'BatteryReport' = @{ Tags = 'pil raporu powercfg batarya omru battery report html'
            En = 'Generates the powercfg battery report as an HTML file and opens it.'
            Tr = 'powercfg pil raporunu HTML olarak olusturur ve acar.' }
        'ExportWifiProfiles' = @{ Tags = 'wifi profilleri disa aktar kablosuz sifreleri yedekle wifi backup'
            En = 'Exports every saved Wi-Fi profile, including passwords, to XML files for moving to another PC.'
            Tr = 'Kayitli tum Wi-Fi profillerini sifreleriyle birlikte XML olarak disa aktarir; baska PC''ye tasimak icin.' }
        'ShutdownTimer' = @{ Tags = 'kapatma zamanlayicisi otomatik kapat suresi zamanli kapatma shutdown timer iptal'
            En = 'Shuts the PC down after the number of minutes you enter; entering 0 cancels a pending timer.'
            Tr = 'Girdiginiz dakika sonra bilgisayari kapatir; 0 girmek bekleyen zamanlayiciyi iptal eder.' }
        'RestartComputer' = @{ Tags = 'bilgisayari yeniden baslat restart reboot'
            En = 'Restarts the computer immediately after a confirmation.'
            Tr = 'Onaydan sonra bilgisayari hemen yeniden baslatir.' }
        'ShutdownComputer' = @{ Tags = 'bilgisayari kapat shutdown power off'
            En = 'Shuts the computer down immediately after a confirmation.'
            Tr = 'Onaydan sonra bilgisayari hemen kapatir.' }
        'RestartToAdvancedStartup' = @{ Tags = 'gelismis baslangic kurtarma ortami winre sorun giderme onyukleme onarimi advanced startup recovery'
            En = 'Restarts into the Windows Recovery Environment (troubleshooting, startup repair, safe mode menu).'
            Tr = 'Windows Kurtarma Ortami''na (sorun giderme, baslangic onarimi, guvenli mod menusu) yeniden baslatir.' }
        'RestartToFirmwareSettings' = @{ Tags = 'bios ayarlari uefi gir bios a gir onyukleme sirasi firmware settings'
            En = 'Restarts straight into the UEFI firmware (BIOS) settings on UEFI machines.'
            Tr = 'UEFI makinelerde dogrudan UEFI (BIOS) ayarlarina yeniden baslatir.' }
        'RestartInSafeMode' = @{ Tags = 'guvenli mod safe mode surucu sorunu acilmiyor minimal'
            En = 'Sets the boot flag for minimal Safe Mode and restarts; use Exit Safe Mode afterwards.'
            Tr = 'Minimal Guvenli Mod onyukleme bayragini ayarlar ve yeniden baslatir; sonra Guvenli Moddan Cik kullanin.' }
        'ExitSafeMode' = @{ Tags = 'guvenli moddan cik normal mod safe mode exit surekli guvenli modda aciliyor'
            En = 'Removes the Safe Mode boot flag so the next restart boots normally.'
            Tr = 'Bir sonraki acilisin normal olmasi icin Guvenli Mod onyukleme bayragini kaldirir.' }
        'ShowComputerAndUserName' = @{ Tags = 'bilgisayar adi kullanici adi hostname computer name user'
            En = 'Shows the computer name and the signed-in user name.'
            Tr = 'Bilgisayar adini ve oturum acmis kullanici adini gosterir.' }
        'ShowWindowsVersion' = @{ Tags = 'windows surumu versiyon build hangi windows winver 10 11'
            En = 'Shows the Windows edition, version and build and opens winver.'
            Tr = 'Windows surumunu, versiyonunu ve build numarasini gosterir, winver''i acar.' }
        'WindowsUpgradeHistory' = @{ Tags = 'windows kurulum tarihi surum gecmisi yukseltme gecmisi install date upgrade history'
            En = 'Lists when Windows was installed and every feature upgrade since, from the setup registry keys.'
            Tr = 'Windows''un ne zaman kuruldugunu ve o zamandan beri yapilan ozellik yukseltmelerini listeler.' }
        'GetSystemInformation' = @{ Tags = 'sistem bilgisi systeminfo donanim ozet bilgisayar ozellikleri system info'
            En = 'Runs systeminfo: OS, hardware, memory, hotfixes and network summary in one listing.'
            Tr = 'systeminfo calistirir: isletim sistemi, donanim, bellek, duzeltmeler ve ag ozeti tek listede.' }
        'ShowWindowsLicenseStatus' = @{ Tags = 'lisans durumu windows etkin mi aktivasyon slmgr etkinlestirme license activation'
            En = 'Shows whether Windows is activated and the licence details (slmgr /xpr and /dlv).'
            Tr = 'Windows''un etkin olup olmadigini ve lisans ayrintilarini gosterir (slmgr /xpr ve /dlv).' }
        'PendingRebootCheck' = @{ Tags = 'bekleyen yeniden baslatma restart gerekli mi guncelleme sonrasi pending reboot'
            En = 'Checks the registry flags that mean Windows is waiting for a restart (updates, renames, component servicing).'
            Tr = 'Windows''un yeniden baslatma bekleyip beklemedigini gosteren kayit defteri bayraklarini denetler.' }
        'ShowTimeSyncStatus' = @{ Tags = 'saat yanlis saat senkron zaman sunucusu ntp time sync w32tm'
            En = 'Shows the time source, last sync and the Windows Time service state for a clock that drifts.'
            Tr = 'Kayan bir saat icin zaman kaynagini, son senkronu ve Windows Time hizmet durumunu gosterir.' }
        'ShutdownHistory' = @{ Tags = 'calisma suresi uptime kapanma gecmisi ne zaman kapandi beklenmedik kapanma'
            En = 'Shows the uptime and the recent shutdown, restart and unexpected power-loss events.'
            Tr = 'Calisma suresini ve son kapanma, yeniden baslatma ve beklenmedik guc kaybi olaylarini gosterir.' }
        'HardwareSummary' = @{ Tags = 'donanim ozeti cpu sicaklik gpu sicaklik ram sensor isi hardware temperature'
            En = 'Shows the machine model, CPU, RAM, GPU and the sensor readings (temperatures, loads) it can read.'
            Tr = 'Makine modelini, CPU, RAM, GPU ve okuyabildigi sensor degerlerini (sicaklik, yuk) gosterir.' }
        'ShowRAMUsage' = @{ Tags = 'ram kullanimi bos bellek ne kadar ram memory usage'
            En = 'Shows free and total physical memory.'
            Tr = 'Bos ve toplam fiziksel bellegi gosterir.' }
        'MemoryModuleReport' = @{ Tags = 'ram modulleri bos slot ram yuvasi kac gb ram hizi mhz ram yukseltme memory slots'
            En = 'Lists each installed memory module (size, speed, slot) and the empty slots, for RAM upgrades.'
            Tr = 'Takili her RAM modulunu (boyut, hiz, yuva) ve bos yuvalari listeler; RAM yukseltmesi icin.' }
        'MotherboardBiosInfo' = @{ Tags = 'anakart bios surumu bios tarihi motherboard model bios version'
            En = 'Shows the motherboard maker and model and the BIOS version and date.'
            Tr = 'Anakart ureticisi ve modeli ile BIOS surumu ve tarihini gosterir.' }
        'ShowCPUInfo' = @{ Tags = 'islemci bilgisi cpu cekirdek sayisi hiz processor cores'
            En = 'Shows the processor name, core and thread counts and maximum clock.'
            Tr = 'Islemci adini, cekirdek ve is parcacigi sayilarini ve en yuksek hizini gosterir.' }
        'GpuDriverDetails' = @{ Tags = 'ekran karti surucu surumu gpu driver nvidia amd intel goruntu surucusu'
            En = 'Shows each GPU with its driver version and date and the display adapter details.'
            Tr = 'Her ekran kartini surucu surumu ve tarihiyle, goruntu baglayici ayrintilariyla gosterir.' }
        'BatteryHealthReport' = @{ Tags = 'pil sagligi batarya kapasitesi pil omru asinma battery health wear'
            En = 'Compares design capacity with full-charge capacity to show battery wear, plus cycle count when available.'
            Tr = 'Tasarim kapasitesini tam sarj kapasitesiyle karsilastirip pil asinmasini, varsa dongu sayisini gosterir.' }
        'ProblemDeviceReport' = @{ Tags = 'sorunlu aygit sari unlem aygit yoneticisi surucu eksik device manager error code'
            En = 'Lists the devices Device Manager flags with an error code (missing or failing drivers).'
            Tr = 'Aygit Yoneticisi''nin hata koduyla isaretledigi aygitlari (eksik veya bozuk surucu) listeler.' }
        'ShowPrinterStatus' = @{ Tags = 'yazici durumu yazici listesi cevrimdisi yazici printer status offline'
            En = 'Lists the installed printers with their status, driver and port.'
            Tr = 'Kurulu yazicilari durumu, surucusu ve baglanti noktasiyla listeler.' }
        'ShowStorageStatus' = @{ Tags = 'depolama durumu disk doluluk bos alan c surucusu doldu storage free space'
            En = 'Shows every volume with its size, free space and fill percentage.'
            Tr = 'Her birimi boyutu, bos alani ve doluluk yuzdesiyle gosterir.' }
        'CheckDiskStatus' = @{ Tags = 'disk sagligi ssd durumu hdd saglik smart disk bozuk mu physical disk health'
            En = 'Lists the physical disks with media type, health and operational status.'
            Tr = 'Fiziksel diskleri ortam turu, saglik ve calisma durumuyla listeler.' }
        'LargestFoldersReport' = @{ Tags = 'en buyuk klasorler yer kaplayan klasor disk doldu ne yer kapliyor largest folders'
            En = 'Scans a drive or folder and lists the biggest folders by total size.'
            Tr = 'Bir surucu veya klasoru tarar, toplam boyuta gore en buyuk klasorleri listeler.' }
        'LargestFilesReport' = @{ Tags = 'en buyuk dosyalar yer kaplayan dosya buyuk dosya bul largest files'
            En = 'Scans a drive or folder and lists the biggest individual files.'
            Tr = 'Bir surucu veya klasoru tarar, en buyuk tekil dosyalari listeler.' }
        'ComponentStoreAnalysis' = @{ Tags = 'winsxs boyutu bilesen deposu analiz temizlenebilir mi dism analyze'
            En = 'Runs DISM /AnalyzeComponentStore to report the real WinSxS size and whether cleanup is recommended.'
            Tr = 'Gercek WinSxS boyutunu ve temizlik onerilip onerilmedigini bildirmek icin DISM /AnalyzeComponentStore calistirir.' }
        'RestorePointShadowStorage' = @{ Tags = 'geri yukleme noktalari listele golge depo boyutu sistem koruma restore points list'
            En = 'Lists the existing restore points and the shadow storage they use.'
            Tr = 'Mevcut geri yukleme noktalarini ve kullandiklari golge depolama alanini listeler.' }
        'DiskPartitionLayout' = @{ Tags = 'disk bolumleri partition duzeni gpt mbr bolum tablosu'
            En = 'Shows each disk with its partition style (GPT/MBR) and partitions.'
            Tr = 'Her diski bolum stili (GPT/MBR) ve bolumleriyle gosterir.' }
        'ScanHardDisk' = @{ Tags = 'chkdsk tara disk hatalari kontrol bozuk sektor scan disk'
            En = 'Runs chkdsk /scan on the system drive - an online check that reports errors without fixing them.'
            Tr = 'Sistem surucusunde chkdsk /scan calistirir; hatalari duzeltmeden bildiren cevrimici denetim.' }
        'ShowIPConfigSummary' = @{ Tags = 'ip adresim nedir ag gecidi dns sunucusu ip config ozet'
            En = 'Shows the IP address, gateway and DNS servers of each active adapter.'
            Tr = 'Her etkin adaptorun IP adresini, ag gecidini ve DNS sunucularini gosterir.' }
        'ShowNetworkAdapters' = @{ Tags = 'ag adaptorleri baglanti hizi ethernet wifi kart link speed mac adresi'
            En = 'Lists the network adapters with status, link speed and MAC address.'
            Tr = 'Ag adaptorlerini durum, baglanti hizi ve MAC adresiyle listeler.' }
        'ShowWifiLinkDetails' = @{ Tags = 'wifi sinyal gucu kablosuz hiz kanal ssid wifi zayif signal strength'
            En = 'Shows the connected Wi-Fi network, signal strength, band, channel and link speed.'
            Tr = 'Bagli Wi-Fi agini, sinyal gucunu, bandi, kanali ve baglanti hizini gosterir.' }
        'ShowWifiPassword' = @{ Tags = 'wifi sifresi parola kablosuz sifre unuttum wifi password show'
            En = 'Shows the saved password of a Wi-Fi profile you pick.'
            Tr = 'Sectiginiz Wi-Fi profilinin kayitli sifresini gosterir.' }
        'ShowNetworkProfileState' = @{ Tags = 'ag profili genel ozel guvenlik duvari durumu public private network profile'
            En = 'Shows whether each connection is Public or Private and the firewall state per profile.'
            Tr = 'Her baglantinin Genel mi Ozel mi oldugunu ve profil basina guvenlik duvari durumunu gosterir.' }
        'ShowListeningPorts' = @{ Tags = 'acik portlar dinleyen port hangi program port kullaniyor listening ports netstat'
            En = 'Lists the TCP/UDP ports being listened on and the program behind each.'
            Tr = 'Dinlenen TCP/UDP portlarini ve her birinin arkasindaki programi listeler.' }
        'ShowActiveConnections' = @{ Tags = 'acik baglantilar hangi program internete baglaniyor aktif baglanti netstat'
            En = 'Lists the established network connections with the owning program.'
            Tr = 'Kurulu ag baglantilarini sahibi olan programla listeler.' }
        'ShowHostsFile' = @{ Tags = 'hosts dosyasi icerigi goster site engeli yonlendirme hosts file'
            En = 'Prints the Hosts file so you can see custom or suspicious entries.'
            Tr = 'Ozel veya supheli kayitlari gorebilmeniz icin Hosts dosyasini yazdirir.' }
        'InternetConnectivityTest' = @{ Tags = 'internet var mi baglanti testi internet calisiyor mu connectivity test'
            En = 'Pings well-known public hosts and reports which are reachable.'
            Tr = 'Bilinen genel sunuculara ping atar ve hangilerine ulasilabildigini bildirir.' }
        'DnsResolutionTest' = @{ Tags = 'dns cozumleme testi site acilmiyor dns calismiyor nslookup'
            En = 'Resolves a host name you enter through the current DNS servers and reports the answer.'
            Tr = 'Girdiginiz sunucu adini mevcut DNS sunucularindan cozer ve yaniti bildirir.' }
        'ShowFullIPConfig' = @{ Tags = 'ipconfig all tum ip yapilandirmasi mac adresi dhcp'
            En = 'Runs ipconfig /all.'
            Tr = 'ipconfig /all calistirir.' }
        'InstalledProgramsList' = @{ Tags = 'kurulu programlar program listesi hangi programlar yuklu installed programs'
            En = 'Lists the installed desktop programs with version and publisher.'
            Tr = 'Kurulu masaustu programlarini surum ve yayimciyla listeler.' }
        'StartupProgramsList' = @{ Tags = 'baslangic programlari acilista calisan programlar yavas acilis startup programs'
            En = 'Lists the programs that start with Windows and where each is registered.'
            Tr = 'Windows ile baslayan programlari ve her birinin nereden kayitli oldugunu listeler.' }
        'NonMicrosoftScheduledTasks' = @{ Tags = 'zamanlanmis gorevler arka plan gorev microsoft disi scheduled tasks'
            En = 'Lists the scheduled tasks not made by Microsoft - background jobs installed by other software.'
            Tr = 'Microsoft disi zamanlanmis gorevleri, yani baska yazilimlarin kurdugu arka plan islerini listeler.' }
        'InstalledUpdatesList' = @{ Tags = 'kurulu guncellemeler kb listesi yuklenen guncellemeler installed updates hotfix'
            En = 'Lists the installed Windows updates (KB numbers) with install dates.'
            Tr = 'Kurulu Windows guncellemelerini (KB numaralari) kurulum tarihleriyle listeler.' }
        'DefenderStatusInfo' = @{ Tags = 'defender durumu antivirus acik mi gercek zamanli koruma tanim guncel mi windows security'
            En = 'Shows Defender real-time protection, signature age and last scan.'
            Tr = 'Defender gercek zamanli korumasini, tanim yasini ve son taramayi gosterir.' }
        'SecureBootTpmStatus' = @{ Tags = 'secure boot tpm windows 11 uyumlu mu guvenli onyukleme tpm 2.0'
            En = 'Shows Secure Boot state and TPM presence and version - the Windows 11 requirements.'
            Tr = 'Guvenli Onyukleme durumunu ve TPM varligini ve surumunu gosterir; Windows 11 gereksinimleri.' }
        'LocalAdministrators' = @{ Tags = 'yonetici hesaplari administrators grubu kim yonetici local admins'
            En = 'Lists the members of the local Administrators group.'
            Tr = 'Yerel Administrators grubunun uyelerini listeler.' }
        'ListUserAccounts' = @{ Tags = 'kullanici hesaplari hesap listesi user accounts etkin devre disi'
            En = 'Lists the local user accounts with enabled state and last logon.'
            Tr = 'Yerel kullanici hesaplarini etkinlik durumu ve son oturumla listeler.' }
        'SecurityPostureInfo' = @{ Tags = 'guvenlik ayarlari uac rdp uzak masaustu winrm acik mi security posture'
            En = 'Shows UAC level, Remote Desktop and WinRM state and other exposure settings.'
            Tr = 'UAC duzeyini, Uzak Masaustu ve WinRM durumunu ve diger acik yuzey ayarlarini gosterir.' }
        'SystemHealthReport' = @{ Tags = 'sistem saglik raporu genel kontrol bilgisayar durumu sorun var mi health check'
            En = 'One combined report: disk fill, disk health, pending reboot, recent errors, Defender and uptime, with a save option.'
            Tr = 'Tek birlesik rapor: disk doluluk, disk sagligi, bekleyen yeniden baslatma, son hatalar, Defender ve calisma suresi; kaydedilebilir.' }
        'RecentSystemErrors' = @{ Tags = 'son hatalar olay gunlugu event log hata kritik cokme crash'
            En = 'Lists recent Error and Critical events from the System and Application logs.'
            Tr = 'Sistem ve Uygulama gunluklerinden son Hata ve Kritik olaylari listeler.' }
        'BlueScreenHistory' = @{ Tags = 'mavi ekran bsod bugcheck aniden yeniden basliyor minidump stop hatasi'
            En = 'Lists the bugcheck (blue screen) and unexpected shutdown events and the dump files on disk.'
            Tr = 'Bugcheck (mavi ekran) ve beklenmedik kapanma olaylarini ve diskteki dump dosyalarini listeler.' }
        'DiskErrorEvents' = @{ Tags = 'disk hatasi olaylari disk bozuluyor mu ntfs hatasi bad block disk events'
            En = 'Lists disk, NTFS and storage controller error events - early warnings of a failing drive.'
            Tr = 'Disk, NTFS ve depolama denetleyici hata olaylarini listeler; bozulan surucunun erken uyarilari.' }
        'TopProcessesByMemory' = @{ Tags = 'en cok ram kullanan program bellek yiyen islem yavas top processes memory'
            En = 'Lists the processes using the most memory.'
            Tr = 'En cok bellek kullanan islemleri listeler.' }
        'CreateRestorePoint' = @{ Tags = 'geri yukleme noktasi olustur sistem geri yukleme yedek al degisiklik oncesi restore point create'
            En = 'Creates a System Restore point now, so any WinToolify or Windows change can be rolled back.'
            Tr = 'Hemen bir Sistem Geri Yukleme noktasi olusturur; WinToolify veya Windows degisiklikleri geri alinabilsin diye.' }
        'InstallVCRedist' = @{ Tags = 'vcredist visual c++ yukle kur runtime calisma zamani dll eksik msvcp140 vcruntime140 oyun acilmiyor program acilmiyor'
            En = 'Installs the Microsoft Visual C++ Redistributables (2005-2022, x86 and x64) that games and programs need, skipping the ones already installed; fixes missing MSVCP/VCRUNTIME DLL errors.'
            Tr = 'Oyun ve programlarin ihtiyac duydugu Microsoft Visual C++ Redistributable paketlerini (2005-2022, x86 ve x64) kurar, zaten kurulu olanlari atlar; eksik MSVCP/VCRUNTIME DLL hatalarini cozer.' }
        'ExportProfile' = @{ Tags = 'profil disa aktar ayarlari kaydet ayarlari yedekle yapilandirma export baska bilgisayara tasi'
            En = 'Saves the current state of every WinToolify section to a profile file that can be imported on another PC.'
            Tr = 'Her WinToolify bolumunun mevcut durumunu baska bir PC''de ice aktarilabilecek bir profil dosyasina kaydeder.' }
        'ImportProfile' = @{ Tags = 'profil ice aktar ayarlari yukle yapilandirma import profil uygula'
            En = 'Applies a saved WinToolify profile file, section by section, with the usual gates.'
            Tr = 'Kaydedilmis bir WinToolify profil dosyasini bolum bolum, olagan onay kapilariyla uygular.' }
        'Screen:BasicTools' = @{ Tags = 'temel araclar islem araclari bilgi araclari basic tools menu'
            En = 'The Basic Tools menu: Action Tools and Information Tools.'
            Tr = 'Temel Araclar menusu: Islem Araclari ve Bilgi Araclari.' }
        'Screen:ActionTools' = @{ Tags = 'islem araclari onarim temizlik ag guc yedekleme actions repair menu'
            En = 'The Action Tools screen: quick fixes, Windows repair, network repair, cleanup, software, backup and power rows.'
            Tr = 'Islem Araclari ekrani: hizli duzeltmeler, Windows onarimi, ag onarimi, temizlik, yazilim, yedekleme ve guc satirlari.' }
        'Screen:InfoTools' = @{ Tags = 'bilgi araclari sistem bilgisi donanim depolama ag guvenlik olaylar information menu'
            En = 'The Information Tools screen: read-only reports on system, hardware, storage, network, software, security and events.'
            Tr = 'Bilgi Araclari ekrani: sistem, donanim, depolama, ag, yazilim, guvenlik ve olaylar hakkinda salt okunur raporlar.' }
        'Screen:Services' = @{ Tags = 'servisler hizmetler servis yonetimi devre disi birak baslangic turu services'
            En = 'The Windows services screen: 43 services with their start type, each switchable to Disabled, Manual or Automatic.'
            Tr = 'Windows servisleri ekrani: 43 servis baslangic turuyle; her biri Devre Disi, El Ile veya Otomatik yapilabilir.' }
        'Screen:SystemSettings' = @{ Tags = 'sistem ayarlari guc plani oyun hizli baslatma guvenlik duvari sag tik menusu gezgin dns blocklist'
            En = 'The System Settings screen: power plan, gaming tweaks, fast startup, firewall, context menu, Explorer view, DNS preset and blocklists.'
            Tr = 'Sistem Ayarlari ekrani: guc plani, oyun ayarlari, hizli baslatma, guvenlik duvari, sag tik menusu, Gezgin gorunumu, DNS on ayari ve engel listeleri.' }
        'Screen:Privacy' = @{ Tags = 'gizlilik ayarlari telemetri izinler yapay zeka arama edge office update guvenlik privacy'
            En = 'The Privacy menu: telemetry, app permissions, AI, search and UI, Edge, Office, Windows Update and security screens.'
            Tr = 'Gizlilik menusu: telemetri, uygulama izinleri, yapay zeka, arama ve arayuz, Edge, Office, Windows Update ve guvenlik ekranlari.' }
        'Screen:PerApp' = @{ Tags = 'uygulama izinleri kamera mikrofon konum uygulama bazli izin hangi uygulama kameraya erisiyor app permissions per app'
            En = 'The per-app permissions screen: for each capability (camera, microphone, location...) which installed app may use it, per app.'
            Tr = 'Uygulama bazli izinler ekrani: her yetenek (kamera, mikrofon, konum...) icin hangi kurulu uygulamanin onu kullanabilecegi, uygulama uygulama.' }
        'Screen:Packages' = @{ Tags = 'gereksiz uygulamalar bloatware kaldir onceden yuklu uygulamalar xbox cortana onedrive remove apps'
            En = 'The Apps screen: preinstalled and bloatware packages installed on this machine, removable one by one.'
            Tr = 'Uygulamalar ekrani: bu makinede kurulu onceden yuklu ve gereksiz paketler; tek tek kaldirilabilir.' }
        'Screen:WingetStore' = @{ Tags = 'winget magazasi program kur uygulama yukle indir install software store'
            En = 'The winget store: a catalog of 250+ programs to install, plus a live winget search and the installed list.'
            Tr = 'Winget magazasi: kurulacak 250+ programlik katalog, canli winget aramasi ve kurulu program listesi.' }
        'Screen:Language' = @{ Tags = 'dil degistir turkce ingilizce arayuz dili language english turkish'
            En = 'The language screen: switches the WinToolify interface between Turkish and English.'
            Tr = 'Dil ekrani: WinToolify arayuzunu Turkce ve Ingilizce arasinda degistirir.' }
        'Screen:Undo' = @{ Tags = 'geri al son degisiklik undo eski haline dondur wintoolify degisikligi'
            En = 'The undo screen: every change WinToolify made, newest first, each restorable.'
            Tr = 'Geri alma ekrani: WinToolify''in yaptigi her degisiklik, en yeniden baslayarak, her biri geri alinabilir.' }
        'Screen:Profiles' = @{ Tags = 'yapilandirma profilleri profil disa aktar ice aktar ayarlari tasi config profiles'
            En = 'The profiles screen: export the current settings to a file or import one.'
            Tr = 'Profiller ekrani: mevcut ayarlari dosyaya aktarir veya bir dosyadan ice aktarir.' }
        'Services:DiagTrack' = @{ Tags = 'telemetri servisi veri toplama diagtrack kapat'
            En = 'The telemetry upload service; disabling it stops diagnostic data leaving the machine.'
            Tr = 'Telemetri yukleme servisi; kapatilinca tanilama verisi makineden cikmaz.' }
        'Services:MapsBroker' = @{ Tags = 'harita indirme cevrimdisi haritalar maps'
            En = 'Manages offline map downloads for the Maps app; safe to disable if you do not use offline maps.'
            Tr = 'Haritalar uygulamasinin cevrimdisi harita indirmelerini yonetir; cevrimdisi harita kullanmiyorsaniz kapatilabilir.' }
        'Services:NetTcpPortSharing' = @{ Tags = 'net tcp port paylasimi wcf'
            En = 'WCF Net.Tcp port sharing; only developer or server software needs it.'
            Tr = 'WCF Net.Tcp port paylasimi; yalnizca gelistirici veya sunucu yazilimlari kullanir.' }
        'Services:RemoteAccess' = @{ Tags = 'vpn sunucu internet paylasimi yonlendirme uzaktan erisim'
            En = 'Hosts VPN and Internet Connection Sharing; disabling it does not affect VPN clients you connect with.'
            Tr = 'VPN sunucusu ve Internet Baglanti Paylasimi barindirir; kapatilmasi baglandiginiz VPN istemcilerini etkilemez.' }
        'Services:RemoteRegistry' = @{ Tags = 'uzaktan kayit defteri guvenlik kapat remote registry'
            En = 'Lets other computers edit this registry over the network; disabling it removes an attack surface.'
            Tr = 'Baska bilgisayarlarin bu kayit defterini agdan duzenlemesine izin verir; kapatilmasi bir saldiri yuzeyini kaldirir.' }
        'Services:TrkWks' = @{ Tags = 'kisayol izleme ntfs baglanti izleme'
            En = 'Tracks moved NTFS files for shortcuts across the network; rarely needed on a home PC.'
            Tr = 'Agdaki kisayollar icin tasinan NTFS dosyalarini izler; ev bilgisayarinda nadiren gerekir.' }
        'Services:WMPNetworkSvc' = @{ Tags = 'media player paylasimi dlna medya akisi'
            En = 'Windows Media Player DLNA sharing; disable if you do not stream media to other devices.'
            Tr = 'Windows Media Player DLNA paylasimi; baska cihazlara medya aktarmiyorsaniz kapatin.' }
        'Services:WerSvc' = @{ Tags = 'hata bildirimi microsofta gonder error reporting'
            En = 'Windows Error Reporting uploads crash reports to Microsoft; disabling stops the uploads and the report prompts.'
            Tr = 'Windows Hata Bildirimi cokme raporlarini Microsoft''a yukler; kapatilinca yuklemeler ve bildirim pencereleri durur.' }
        'Services:Fax' = @{ Tags = 'faks servisi fax kapat'
            En = 'The fax service; no use without a fax modem.'
            Tr = 'Faks servisi; faks modemi yoksa ise yaramaz.' }
        'Services:AJRouter' = @{ Tags = 'alljoyn iot yonlendirici'
            En = 'AllJoyn IoT router for a retired protocol; safe to disable.'
            Tr = 'Kullanim disi bir protokol icin AllJoyn IoT yonlendirici; guvenle kapatilabilir.' }
        'Services:PhoneSvc' = @{ Tags = 'telefon baglantisi phone link arama'
            En = 'Backs Phone Link calls; disable if you do not pair a phone.'
            Tr = 'Phone Link aramalarini destekler; telefon eslestirmiyorsaniz kapatin.' }
        'Services:wisvc' = @{ Tags = 'insider programi onizleme surumu'
            En = 'Windows Insider Program service; only needed while enrolled in Insider builds.'
            Tr = 'Windows Insider Programi servisi; yalnizca Insider surumlerine kayitliyken gerekir.' }
        'Services:RetailDemo' = @{ Tags = 'perakende demo magaza modu'
            En = 'Retail demo mode for store display PCs; safe to disable.'
            Tr = 'Magaza tesir bilgisayarlari icin perakende tanitim modu; guvenle kapatilabilir.' }
        'Services:BcastDVRUserService' = @{ Tags = 'game dvr oyun kaydi arka plan kayit xbox game bar fps'
            En = 'Game DVR background recording; disabling frees resources while gaming if you do not record.'
            Tr = 'Game DVR arka plan kaydi; kayit yapmiyorsaniz kapatmak oyunda kaynak acar.' }
        'AiPrivacy:DisableCopilot' = @{ Tags = 'copilot kapat yapay zeka gorev cubugu dugmesi kaldir'
            En = 'Turns Copilot off by policy and removes its taskbar button.'
            Tr = 'Copilot''u ilkeyle kapatir ve gorev cubugu dugmesini kaldirir.' }
        'AiPrivacy:DisableRecall' = @{ Tags = 'recall kapat ekran goruntusu kaydi yapay zeka gizlilik'
            En = 'Disables Recall, which takes periodic screenshots of your activity on Copilot+ PCs.'
            Tr = 'Copilot+ PC''lerde etkinliginizin duzenli ekran goruntusunu alan Recall''u kapatir.' }
        'AiPrivacy:DisableClickToDo' = @{ Tags = 'click to do kapat yapay zeka ekran eylemleri'
            En = 'Disables Click to Do, the on-screen AI action overlay.'
            Tr = 'Ekran uzerindeki yapay zeka eylem katmani Click to Do''yu kapatir.' }
        'CapabilityDefaults:location' = @{ Tags = 'konum izni kapat gps konum erisimi'
            En = 'Denies apps access to your location by default.'
            Tr = 'Uygulamalarin konumunuza erisimini varsayilan olarak reddeder.' }
        'CapabilityDefaults:webcam' = @{ Tags = 'kamera izni kapat webcam erisimi'
            En = 'Denies apps access to the camera by default.'
            Tr = 'Uygulamalarin kameraya erisimini varsayilan olarak reddeder.' }
        'CapabilityDefaults:microphone' = @{ Tags = 'mikrofon izni kapat mikrofon erisimi'
            En = 'Denies apps access to the microphone by default.'
            Tr = 'Uygulamalarin mikrofona erisimini varsayilan olarak reddeder.' }
        'CapabilityDefaults:userNotificationListener' = @{ Tags = 'bildirim erisimi bildirimleri okuma izni'
            En = 'Denies apps the right to read your notifications.'
            Tr = 'Uygulamalarin bildirimlerinizi okuma hakkini reddeder.' }
        'CapabilityDefaults:userAccountInformation' = @{ Tags = 'hesap bilgisi erisimi ad resim hesap'
            En = 'Denies apps access to your account name and picture.'
            Tr = 'Uygulamalarin hesap adiniza ve resminize erisimini reddeder.' }
        'CapabilityDefaults:appDiagnostics' = @{ Tags = 'uygulama tanilama diger uygulamalari izleme'
            En = 'Denies apps diagnostic information about other running apps.'
            Tr = 'Uygulamalarin calisan diger uygulamalar hakkinda tanilama bilgisi almasini reddeder.' }
        'CapabilityDefaults:contacts' = @{ Tags = 'kisiler erisimi rehber izni'
            En = 'Denies apps access to your contacts.'
            Tr = 'Uygulamalarin kisilerinize erisimini reddeder.' }
        'CapabilityDefaults:appointments' = @{ Tags = 'takvim erisimi randevu izni'
            En = 'Denies apps access to your calendar.'
            Tr = 'Uygulamalarin takviminize erisimini reddeder.' }
        'CapabilityDefaults:email' = @{ Tags = 'e-posta erisimi mail izni'
            En = 'Denies apps access to your email.'
            Tr = 'Uygulamalarin e-postaniza erisimini reddeder.' }
        'CapabilityDefaults:chat' = @{ Tags = 'mesajlasma erisimi sms izni'
            En = 'Denies apps access to messaging (SMS/MMS).'
            Tr = 'Uygulamalarin mesajlasmaya (SMS/MMS) erisimini reddeder.' }
        'CapabilityDefaults:phoneCall' = @{ Tags = 'telefon arama izni arama yapma'
            En = 'Denies apps the right to make phone calls.'
            Tr = 'Uygulamalarin telefon aramasi yapma hakkini reddeder.' }
        'CapabilityDefaults:phoneCallHistory' = @{ Tags = 'arama gecmisi erisimi'
            En = 'Denies apps access to the call history.'
            Tr = 'Uygulamalarin arama gecmisine erisimini reddeder.' }
        'CapabilityDefaults:userDataTasks' = @{ Tags = 'gorevler erisimi yapilacaklar izni'
            En = 'Denies apps access to your tasks (to-do data).'
            Tr = 'Uygulamalarin gorevlerinize (yapilacaklar) erisimini reddeder.' }
        'CapabilityDefaults:activity' = @{ Tags = 'etkinlik gecmisi erisimi zaman cizelgesi'
            En = 'Denies apps access to the activity history.'
            Tr = 'Uygulamalarin etkinlik gecmisine erisimini reddeder.' }
        'CapabilityDefaults:bluetoothSync' = @{ Tags = 'bluetooth esitleme diger cihazlar eslesmemis cihaz'
            En = 'Denies apps communication with unpaired devices over Bluetooth.'
            Tr = 'Uygulamalarin Bluetooth uzerinden eslesmemis cihazlarla iletisimini reddeder.' }
        'CapabilityDefaults:radios' = @{ Tags = 'radyo kontrolu bluetooth wifi acma kapama izni'
            En = 'Denies apps the right to switch radios (Wi-Fi, Bluetooth) on and off.'
            Tr = 'Uygulamalarin radyolari (Wi-Fi, Bluetooth) acip kapama hakkini reddeder.' }
        'CapabilityDefaults:cellularData' = @{ Tags = 'hucresel veri mobil veri izni'
            En = 'Denies apps use of cellular data.'
            Tr = 'Uygulamalarin hucresel veri kullanimini reddeder.' }
        'Telemetry:SetDiagnosticDataMinimal' = @{ Tags = 'tanilama verisi telemetri en dusuk gerekli veri'
            En = 'Sets the diagnostic data level to the lowest this edition allows (Security on Enterprise, Required elsewhere).'
            Tr = 'Tanilama veri duzeyini bu surumun izin verdigi en dusuge ayarlar (Enterprise''da Guvenlik, digerlerinde Gerekli).' }
        'Telemetry:DisableFeedbackNotifications' = @{ Tags = 'geri bildirim istegi kapat feedback hub bildirimi'
            En = 'Stops Windows from asking for feedback.'
            Tr = 'Windows''un geri bildirim istemesini durdurur.' }
        'Telemetry:DisableCeip' = @{ Tags = 'musteri deneyimi programi ceip kapat'
            En = 'Opts out of the Customer Experience Improvement Program and its scheduled upload tasks.'
            Tr = 'Musteri Deneyimini Gelistirme Programi''ndan ve zamanlanmis yukleme gorevlerinden cikar.' }
        'Telemetry:DisableInkingAndTyping' = @{ Tags = 'yazma kisisellestirme murekkep klavye verisi'
            En = 'Stops sending inking and typing data for personalization.'
            Tr = 'Kisisellestirme icin murekkep ve yazma verisi gonderimini durdurur.' }
        'ActivityAdvertising:DisableActivityHistory' = @{ Tags = 'etkinlik gecmisi zaman cizelgesi kapat'
            En = 'Stops collecting and uploading the activity history (Timeline).'
            Tr = 'Etkinlik gecmisi (Zaman Cizelgesi) toplama ve yuklemeyi durdurur.' }
        'ActivityAdvertising:DisableAppLaunchTracking' = @{ Tags = 'uygulama baslatma izleme en cok kullanilan'
            En = 'Stops Windows tracking which apps you launch for Start menu suggestions.'
            Tr = 'Windows''un Baslat onerileri icin hangi uygulamalari baslattiginizi izlemesini durdurur.' }
        'ActivityAdvertising:DisableAdvertisingId' = @{ Tags = 'reklam kimligi kapat kisisellestirilmis reklam'
            En = 'Disables the advertising ID apps use for personalized ads.'
            Tr = 'Uygulamalarin kisisellestirilmis reklam icin kullandigi reklam kimligini kapatir.' }
        'ActivityAdvertising:DisableTailoredExperiences' = @{ Tags = 'uyarlanmis deneyimler oneriler kapat'
            En = 'Stops tailored tips and ads built from diagnostic data.'
            Tr = 'Tanilama verisinden uretilen uyarlanmis ipucu ve reklamlari durdurur.' }
        'SearchSuggestions:DisableCortana' = @{ Tags = 'cortana kapat sesli asistan'
            En = 'Disables Cortana by policy.'
            Tr = 'Cortana''yi ilkeyle kapatir.' }
        'SearchSuggestions:DisableSearchBoxSuggestions' = @{ Tags = 'arama kutusu onerileri bing web aramasi kapat'
            En = 'Removes Bing web suggestions from the search box.'
            Tr = 'Arama kutusundan Bing web onerilerini kaldirir.' }
        'SearchSuggestions:DisableConsumerFeatures' = @{ Tags = 'onerilen uygulamalar otomatik kurulum candy crush'
            En = 'Stops Windows silently installing suggested third-party apps.'
            Tr = 'Windows''un onerilen ucuncu parti uygulamalari sessizce kurmasini durdurur.' }
        'SearchSuggestions:DisableStartMenuSuggestions' = @{ Tags = 'baslat menusu onerileri ayarlar onerileri kapat'
            En = 'Removes suggestions from the Start menu and the Settings app.'
            Tr = 'Baslat menusu ve Ayarlar uygulamasindan onerileri kaldirir.' }
        'GamingTweaks:DisableFullscreenOptimizations' = @{ Tags = 'oyun modu fps tam ekran iyilestirme kapat gecikme input lag gaming'
            En = 'Disables fullscreen optimizations globally so games run true exclusive fullscreen with less input latency.'
            Tr = 'Oyunlarin daha az giris gecikmesiyle gercek ozel tam ekranda calismasi icin tam ekran iyilestirmelerini genel olarak kapatir.' }
        'GamingTweaks:ThrottleBackgroundInput' = @{ Tags = 'arka plan girisi oyun performansi fps'
            En = 'Limits background window input polling to 50 Hz so the foreground game keeps more CPU.'
            Tr = 'On plandaki oyuna daha cok CPU kalmasi icin arka plan pencere giris yoklamasini 50 Hz ile sinirlar.' }
        'Firewall:EnableFirewall' = @{ Tags = 'guvenlik duvari ac firewall etkinlestir'
            En = 'Turns Windows Firewall on for the Domain, Private and Public profiles.'
            Tr = 'Windows Guvenlik Duvari''ni Etki Alani, Ozel ve Genel profiller icin acar.' }
        'DnsPreset:Cloudflare' = @{ Tags = 'dns degistir cloudflare 1.1.1.1 hizli dns'
            En = 'Sets Cloudflare DNS (1.1.1.1 / 1.0.0.1) on every adapter.'
            Tr = 'Her adaptorde Cloudflare DNS (1.1.1.1 / 1.0.0.1) ayarlar.' }
        'DnsPreset:Cloudflare (Malware Blocking)' = @{ Tags = 'dns zararli yazilim engelleme cloudflare 1.1.1.2 guvenli dns'
            En = 'Sets Cloudflare malware-blocking DNS (1.1.1.2 / 1.0.0.2).'
            Tr = 'Cloudflare zararli yazilim engelleyen DNS (1.1.1.2 / 1.0.0.2) ayarlar.' }
        'DnsPreset:Quad9' = @{ Tags = 'dns quad9 9.9.9.9 guvenli dns zararli engelleme'
            En = 'Sets Quad9 DNS (9.9.9.9 / 149.112.112.112), which blocks known malicious domains.'
            Tr = 'Bilinen zararli alan adlarini engelleyen Quad9 DNS (9.9.9.9 / 149.112.112.112) ayarlar.' }
        'DnsPreset:Google' = @{ Tags = 'dns google 8.8.8.8 dns degistir'
            En = 'Sets Google Public DNS (8.8.8.8 / 8.8.4.4).'
            Tr = 'Google Public DNS (8.8.8.8 / 8.8.4.4) ayarlar.' }
        'DnsPreset:OpenDNS' = @{ Tags = 'dns opendns aile filtresi'
            En = 'Sets OpenDNS (208.67.222.222 / 208.67.220.220).'
            Tr = 'OpenDNS (208.67.222.222 / 208.67.220.220) ayarlar.' }
        'DnsPreset:AdGuard (Ads & Trackers)' = @{ Tags = 'reklam engelle dns adguard reklamsiz izleyici engelleme ad block'
            En = 'Sets AdGuard DNS, which blocks ads and trackers at the DNS level for the whole machine.'
            Tr = 'Tum makine icin DNS duzeyinde reklam ve izleyicileri engelleyen AdGuard DNS ayarlar.' }
        'Blocklist:Spy' = @{ Tags = 'telemetri sunuculari engelle hosts blocklist casus'
            En = 'Blocks the known telemetry and tracking hosts of Windows through the Hosts file or firewall.'
            Tr = 'Windows''un bilinen telemetri ve izleme sunucularini Hosts dosyasi veya guvenlik duvariyla engeller.' }
        'Blocklist:Update' = @{ Tags = 'windows update engelle guncelleme sunucularini durdur update hosts'
            En = 'Blocks the Windows Update hosts; the tier must be removed again (Undo) to receive updates.'
            Tr = 'Windows Update sunucularini engeller; guncelleme almak icin katman yeniden kaldirilmali (Geri Al).' }
        'Blocklist:Extra' = @{ Tags = 'ekstra engelleme office skype outlook ncsi ileri duzey hosts'
            En = 'Blocks the extra third-party host list; can break Office, Skype, Outlook and the connectivity check.'
            Tr = 'Ek ucuncu taraf sunucu listesini engeller; Office, Skype, Outlook ve baglanti denetimini bozabilir.' }
        'ContextMenu:AddRestartExplorer' = @{ Tags = 'sag tik gezgini yeniden baslat masaustu menusu'
            En = 'Adds a "Restart Explorer" entry to the desktop right-click menu.'
            Tr = 'Masaustu sag tik menusune "Gezgini Yeniden Baslat" ogesi ekler.' }
        'ExplorerView:ShowFileExtensions' = @{ Tags = 'dosya uzantilari goster uzanti gizli exe txt'
            En = 'Makes File Explorer show file extensions (.exe, .txt) for every file.'
            Tr = 'Dosya Gezgini''nin her dosya icin uzantiyi (.exe, .txt) gostermesini saglar.' }
        'ExplorerView:ShowHiddenFiles' = @{ Tags = 'gizli dosyalar goster gizli klasor appdata'
            En = 'Makes File Explorer show hidden files and folders.'
            Tr = 'Dosya Gezgini''nin gizli dosya ve klasorleri gostermesini saglar.' }
        'ExplorerView:OpenExplorerToThisPC' = @{ Tags = 'gezgin bu bilgisayar ac hizli erisim yerine'
            En = 'Opens File Explorer to This PC instead of Quick Access / Home.'
            Tr = 'Dosya Gezgini''ni Hizli Erisim / Giris yerine Bu Bilgisayar''da acar.' }
        'ExplorerView:UseCompactView' = @{ Tags = 'sikisik gorunum dar satir araligi gezgin'
            En = 'Uses the compact row spacing in File Explorer lists.'
            Tr = 'Dosya Gezgini listelerinde sikisik satir araligi kullanir.' }
        'ExplorerView:ShowFullPathInTitleBar' = @{ Tags = 'tam yol baslik cubugu gezgin'
            En = 'Shows the full folder path in the File Explorer title bar.'
            Tr = 'Dosya Gezgini baslik cubugunda tam klasor yolunu gosterir.' }
        'ExplorerView:HideRecentAndFrequent' = @{ Tags = 'son dosyalar gizle sik kullanilan klasorler hizli erisim gizlilik'
            En = 'Hides recent files and frequent folders from Quick Access.'
            Tr = 'Hizli Erisim''den son dosyalari ve sik kullanilan klasorleri gizler.' }
    }
}

function Get-WtAssistantTwinTable {
    <#
    .SYNOPSIS
        Dropped id -> preferred id for entries that write the same setting
        from two catalogs: the 25 hardening app-permission rows mirror
        CapabilityDefaults, and three hardening privacy rows mirror
        WinToolify's own registry entries. Search folds a pair into the
        preferred row. Keyed by the hardening side - the W11-only rows
        (P072, P075, P078) simply never appear on W10.
    #>
    return @{
        'HardeningAppPermissions:HD_P019' = 'CapabilityDefaults:userNotificationListener'
        'HardeningAppPermissions:HD_P020' = 'CapabilityDefaults:contacts'
        'HardeningAppPermissions:HD_P021' = 'CapabilityDefaults:email'
        'HardeningAppPermissions:HD_P022' = 'CapabilityDefaults:userDataTasks'
        'HardeningAppPermissions:HD_P023' = 'CapabilityDefaults:appDiagnostics'
        'HardeningAppPermissions:HD_P034' = 'CapabilityDefaults:webcam'
        'HardeningAppPermissions:HD_P035' = 'CapabilityDefaults:microphone'
        'HardeningAppPermissions:HD_P036' = 'CapabilityDefaults:userAccountInformation'
        'HardeningAppPermissions:HD_P038' = 'CapabilityDefaults:appointments'
        'HardeningAppPermissions:HD_P039' = 'CapabilityDefaults:phoneCallHistory'
        'HardeningAppPermissions:HD_P042' = 'CapabilityDefaults:chat'
        'HardeningAppPermissions:HD_P043' = 'CapabilityDefaults:documentsLibrary'
        'HardeningAppPermissions:HD_P044' = 'CapabilityDefaults:picturesLibrary'
        'HardeningAppPermissions:HD_P045' = 'CapabilityDefaults:videosLibrary'
        'HardeningAppPermissions:HD_P046' = 'CapabilityDefaults:broadFileSystemAccess'
        'HardeningAppPermissions:HD_P049' = 'CapabilityDefaults:activity'
        'HardeningAppPermissions:HD_P051' = 'CapabilityDefaults:phoneCall'
        'HardeningAppPermissions:HD_P053' = 'CapabilityDefaults:radios'
        'HardeningAppPermissions:HD_P055' = 'CapabilityDefaults:bluetoothSync'
        'HardeningAppPermissions:HD_P057' = 'CapabilityDefaults:location'
        'HardeningAppPermissions:HD_P059' = 'CapabilityDefaults:cellularData'
        'HardeningAppPermissions:HD_P072' = 'CapabilityDefaults:graphicsCaptureProgrammatic'
        'HardeningAppPermissions:HD_P075' = 'CapabilityDefaults:graphicsCaptureWithoutBorder'
        'HardeningAppPermissions:HD_P078' = 'CapabilityDefaults:musicLibrary'
        'HardeningAppPermissions:HD_P080' = 'CapabilityDefaults:downloadsFolder'
        'HardeningPrivacy:HD_P005' = 'ActivityAdvertising:DisableAdvertisingId'
        'HardeningPrivacy:HD_U004' = 'ActivityAdvertising:DisableTailoredExperiences'
        'HardeningPrivacy:HD_M005' = 'SearchSuggestions:DisableConsumerFeatures'
    }
}
