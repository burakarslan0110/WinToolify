# The curated winget store catalog: ten categories and the apps in them.
# Covered by: tests/WingetStoreCatalog.Tests.ps1

function Get-WtWingetStoreCategories {
    <#
    .SYNOPSIS
        The ten columns of the store grid, in draw order.
    #>
    return @(
        [PSCustomObject]@{ Key = 'Browsers';   LabelKey = 'WsCatBrowsers' }
        [PSCustomObject]@{ Key = 'Dev';        LabelKey = 'WsCatDev' }
        [PSCustomObject]@{ Key = 'Comms';      LabelKey = 'WsCatComms' }
        [PSCustomObject]@{ Key = 'Document';   LabelKey = 'WsCatDocument' }
        [PSCustomObject]@{ Key = 'Games';      LabelKey = 'WsCatGames' }
        [PSCustomObject]@{ Key = 'Microsoft';  LabelKey = 'WsCatMicrosoft' }
        [PSCustomObject]@{ Key = 'Media';      LabelKey = 'WsCatMedia' }
        [PSCustomObject]@{ Key = 'ProTools';   LabelKey = 'WsCatProTools' }
        [PSCustomObject]@{ Key = 'Selfhosted'; LabelKey = 'WsCatSelfhosted' }
        [PSCustomObject]@{ Key = 'Utilities';  LabelKey = 'WsCatUtilities' }
    )
}

function Get-WtWingetStoreCatalog {
    <#
    .SYNOPSIS
        The apps the store grid offers. Id is the real winget package
        identifier and the key for both install and the "is it installed"
        match, so - like the appx catalog - a shipped id is FROZEN: exported
        profiles and muscle memory are written against it. Name is a proper
        noun, deliberately not translated; Tags is never drawn, carrying
        Turkish and English search words so the filter works in either
        language.
    #>
    return @(
        [PSCustomObject]@{ Id = 'Google.Chrome';                Name = 'Chrome';          Category = 'Browsers'; Tags = 'tarayici browser web google chrome' }
        [PSCustomObject]@{ Id = 'Mozilla.Firefox';              Name = 'Firefox';         Category = 'Browsers'; Tags = 'tarayici browser web gizlilik privacy mozilla' }
        [PSCustomObject]@{ Id = 'Brave.Brave';                  Name = 'Brave';           Category = 'Browsers'; Tags = 'tarayici browser web gizlilik privacy reklam engelleyici adblock' }
        [PSCustomObject]@{ Id = 'Microsoft.Edge';               Name = 'Edge';            Category = 'Browsers'; Tags = 'tarayici browser web microsoft edge' }
        [PSCustomObject]@{ Id = 'Opera.Opera';                  Name = 'Opera';           Category = 'Browsers'; Tags = 'tarayici browser web opera vpn' }
        [PSCustomObject]@{ Id = 'Opera.OperaGX';                Name = 'Opera GX';        Category = 'Browsers'; Tags = 'tarayici browser web oyun gaming opera gx' }
        [PSCustomObject]@{ Id = 'Vivaldi.Vivaldi';              Name = 'Vivaldi';         Category = 'Browsers'; Tags = 'tarayici browser web vivaldi ozellestirme' }
        [PSCustomObject]@{ Id = 'LibreWolf.LibreWolf';          Name = 'LibreWolf';       Category = 'Browsers'; Tags = 'tarayici browser web gizlilik privacy firefox fork' }
        [PSCustomObject]@{ Id = 'Zen-Team.Zen-Browser';         Name = 'Zen Browser';     Category = 'Browsers'; Tags = 'tarayici browser web zen dikey sekme' }
        [PSCustomObject]@{ Id = 'TorProject.TorBrowser';        Name = 'Tor Browser';     Category = 'Browsers'; Tags = 'tarayici browser web anonim gizlilik privacy tor onion' }
        [PSCustomObject]@{ Id = 'Waterfox.Waterfox';            Name = 'Waterfox';        Category = 'Browsers'; Tags = 'tarayici browser web gizlilik privacy firefox fork' }
        [PSCustomObject]@{ Id = 'Ablaze.Floorp';                Name = 'Floorp';          Category = 'Browsers'; Tags = 'tarayici browser web firefox fork' }
        [PSCustomObject]@{ Id = 'Hibbiki.Chromium';            Name = 'Chromium';        Category = 'Browsers'; Tags = 'tarayici browser web acik kaynak open source chromium' }
        [PSCustomObject]@{ Id = 'Yandex.Browser';               Name = 'Yandex Browser';  Category = 'Browsers'; Tags = 'tarayici browser web yandex' }
        [PSCustomObject]@{ Id = 'Mozilla.Firefox.ESR';          Name = 'Firefox ESR';     Category = 'Browsers'; Tags = 'tarayici browser web firefox esr kurumsal uzun sureli destek enterprise' }
        [PSCustomObject]@{ Id = 'ImputNet.Helium';              Name = 'Helium';          Category = 'Browsers'; Tags = 'tarayici browser web helium chromium hafif lightweight' }
        [PSCustomObject]@{ Id = 'MullvadVPN.MullvadBrowser';    Name = 'Mullvad Browser'; Category = 'Browsers'; Tags = 'tarayici browser web gizlilik privacy mullvad vpn anonim' }
        [PSCustomObject]@{ Id = 'eloston.ungoogled-chromium';   Name = 'Ungoogled Chromium'; Category = 'Browsers'; Tags = 'tarayici browser web chromium google olmadan degoogled gizlilik' }

        [PSCustomObject]@{ Id = 'Git.Git';                                  Name = 'Git';               Category = 'Dev'; Tags = 'gelistirme development surum kontrol version control git' }
        [PSCustomObject]@{ Id = 'Microsoft.VisualStudioCode';               Name = 'VS Code';           Category = 'Dev'; Tags = 'gelistirme development editor kod code vscode microsoft' }
        [PSCustomObject]@{ Id = 'OpenJS.NodeJS';                            Name = 'Node.js';           Category = 'Dev'; Tags = 'gelistirme development javascript node npm runtime' }
        [PSCustomObject]@{ Id = 'Python.Python.3.12';                       Name = 'Python 3.12';       Category = 'Dev'; Tags = 'gelistirme development python betik script' }
        [PSCustomObject]@{ Id = 'Docker.DockerDesktop';                     Name = 'Docker Desktop';    Category = 'Dev'; Tags = 'gelistirme development konteyner container docker' }
        [PSCustomObject]@{ Id = 'Notepad++.Notepad++';                      Name = 'Notepad++';         Category = 'Dev'; Tags = 'gelistirme development editor metin text notepad' }
        [PSCustomObject]@{ Id = 'GitHub.GitHubDesktop';                     Name = 'GitHub Desktop';    Category = 'Dev'; Tags = 'gelistirme development git github surum kontrol' }
        [PSCustomObject]@{ Id = 'JetBrains.IntelliJIDEA.Community';         Name = 'IntelliJ CE';       Category = 'Dev'; Tags = 'gelistirme development java ide jetbrains intellij' }
        [PSCustomObject]@{ Id = 'JetBrains.PyCharm.Community';              Name = 'PyCharm CE';        Category = 'Dev'; Tags = 'gelistirme development python ide jetbrains pycharm' }
        [PSCustomObject]@{ Id = 'EclipseAdoptium.Temurin.21.JDK';           Name = 'Temurin JDK 21';    Category = 'Dev'; Tags = 'gelistirme development java jdk temurin adoptium' }
        [PSCustomObject]@{ Id = 'Microsoft.DotNet.SDK.8';                   Name = '.NET SDK 8';        Category = 'Dev'; Tags = 'gelistirme development dotnet net sdk microsoft csharp' }
        [PSCustomObject]@{ Id = 'Microsoft.VisualStudio.2022.Community';    Name = 'Visual Studio CE';  Category = 'Dev'; Tags = 'gelistirme development ide visual studio microsoft' }
        [PSCustomObject]@{ Id = 'Rustlang.Rustup';                          Name = 'Rustup';            Category = 'Dev'; Tags = 'gelistirme development rust cargo rustup' }
        [PSCustomObject]@{ Id = 'GoLang.Go';                                Name = 'Go';                Category = 'Dev'; Tags = 'gelistirme development golang go' }
        [PSCustomObject]@{ Id = 'Postman.Postman';                          Name = 'Postman';           Category = 'Dev'; Tags = 'gelistirme development api rest test postman' }
        [PSCustomObject]@{ Id = 'SublimeHQ.SublimeText.4';                  Name = 'Sublime Text';      Category = 'Dev'; Tags = 'gelistirme development editor metin text sublime' }
        [PSCustomObject]@{ Id = 'WinMerge.WinMerge';                        Name = 'WinMerge';          Category = 'Dev'; Tags = 'gelistirme development karsilastirma diff merge' }
        [PSCustomObject]@{ Id = 'Kubernetes.kubectl';                       Name = 'kubectl';           Category = 'Dev'; Tags = 'gelistirme development kubernetes k8s kubectl' }
        [PSCustomObject]@{ Id = 'Microsoft.SQLServerManagementStudio';      Name = 'SSMS';              Category = 'Dev'; Tags = 'gelistirme development sql veritabani database ssms microsoft' }
        [PSCustomObject]@{ Id = 'DBBrowserForSQLite.DBBrowserForSQLite';    Name = 'DB Browser';        Category = 'Dev'; Tags = 'gelistirme development sqlite veritabani database' }
        [PSCustomObject]@{ Id = 'Bruno.Bruno';                              Name = 'Bruno';             Category = 'Dev'; Tags = 'gelistirme development api test istemci client bruno postman alternatifi' }
        [PSCustomObject]@{ Id = 'Anthropic.Claude';                         Name = 'Claude';            Category = 'Dev'; Tags = 'gelistirme development yapay zeka ai asistan claude anthropic masaustu' }
        [PSCustomObject]@{ Id = 'Anthropic.ClaudeCode';                     Name = 'Claude Code';       Category = 'Dev'; Tags = 'gelistirme development yapay zeka ai kod code claude terminal cli' }
        [PSCustomObject]@{ Id = 'Kitware.CMake';                            Name = 'CMake';             Category = 'Dev'; Tags = 'gelistirme development derleme build sistem cmake' }
        [PSCustomObject]@{ Id = 'OpenAI.Codex';                             Name = 'Codex';             Category = 'Dev'; Tags = 'gelistirme development yapay zeka ai kod code openai codex cli' }
        [PSCustomObject]@{ Id = 'Anysphere.Cursor';                         Name = 'Cursor';            Category = 'Dev'; Tags = 'gelistirme development editor kod code yapay zeka ai cursor' }
        [PSCustomObject]@{ Id = 'GitExtensionsTeam.GitExtensions';          Name = 'Git Extensions';    Category = 'Dev'; Tags = 'gelistirme development git surum kontrol version control arayuz gui' }
        [PSCustomObject]@{ Id = 'GitHub.cli';                               Name = 'GitHub CLI';        Category = 'Dev'; Tags = 'gelistirme development github komut satiri cli git' }
        [PSCustomObject]@{ Id = 'Schniz.fnm';                               Name = 'fnm';               Category = 'Dev'; Tags = 'gelistirme development node nodejs surum manager fast node manager' }
        [PSCustomObject]@{ Id = 'Amazon.Corretto.8.JDK';                    Name = 'Corretto 8';        Category = 'Dev'; Tags = 'gelistirme development java jdk amazon corretto lts' }
        [PSCustomObject]@{ Id = 'Amazon.Corretto.21.JDK';                   Name = 'Corretto 21';       Category = 'Dev'; Tags = 'gelistirme development java jdk amazon corretto lts' }
        [PSCustomObject]@{ Id = 'Amazon.Corretto.25.JDK';                   Name = 'Corretto 25';       Category = 'Dev'; Tags = 'gelistirme development java jdk amazon corretto lts' }
        [PSCustomObject]@{ Id = 'JetBrains.Toolbox';                        Name = 'JetBrains Toolbox'; Category = 'Dev'; Tags = 'gelistirme development ide yonetici manager jetbrains toolbox' }
        [PSCustomObject]@{ Id = 'JesseDuffield.lazygit';                    Name = 'lazygit';           Category = 'Dev'; Tags = 'gelistirme development git terminal arayuz tui lazygit' }
        [PSCustomObject]@{ Id = 'OpenJS.NodeJS.LTS';                        Name = 'Node.js LTS';       Category = 'Dev'; Tags = 'gelistirme development javascript node npm runtime uzun sureli destek' }
        [PSCustomObject]@{ Id = 'pnpm.pnpm';                                Name = 'pnpm';              Category = 'Dev'; Tags = 'gelistirme development javascript npm paket yonetici package manager pnpm' }
        [PSCustomObject]@{ Id = 'Neovim.Neovim';                            Name = 'Neovim';            Category = 'Dev'; Tags = 'gelistirme development editor metin text vim neovim terminal' }
        [PSCustomObject]@{ Id = 'JanDeDobbeleer.OhMyPosh';                  Name = 'Oh My Posh';        Category = 'Dev'; Tags = 'gelistirme development kabuk shell prompt tema theme ohmyposh' }
        [PSCustomObject]@{ Id = 'Starship.Starship';                        Name = 'Starship';          Category = 'Dev'; Tags = 'gelistirme development kabuk shell prompt tema theme starship' }
        [PSCustomObject]@{ Id = 'Unity.UnityHub';                           Name = 'Unity Hub';         Category = 'Dev'; Tags = 'gelistirme development oyun motoru game engine unity' }
        [PSCustomObject]@{ Id = 'Hashicorp.Vagrant';                        Name = 'Vagrant';           Category = 'Dev'; Tags = 'gelistirme development sanal makine vm konteyner container vagrant hashicorp' }
        [PSCustomObject]@{ Id = 'Microsoft.VisualStudio.Community';         Name = 'VS 2026';           Category = 'Dev'; Tags = 'gelistirme development ide visual studio microsoft' }
        [PSCustomObject]@{ Id = 'VSCodium.VSCodium';                        Name = 'VSCodium';          Category = 'Dev'; Tags = 'gelistirme development editor kod code vscode telemetrisiz open source' }
        [PSCustomObject]@{ Id = 'Yarn.Yarn';                                Name = 'Yarn';              Category = 'Dev'; Tags = 'gelistirme development javascript npm paket yonetici package manager yarn' }
        [PSCustomObject]@{ Id = 'astral-sh.uv';                             Name = 'uv';                Category = 'Dev'; Tags = 'gelistirme development python paket yonetici package manager hizli fast uv' }
        [PSCustomObject]@{ Id = 'ZedIndustries.Zed';                        Name = 'Zed';               Category = 'Dev'; Tags = 'gelistirme development editor kod code hizli fast zed' }
        [PSCustomObject]@{ Id = 'RubyInstallerTeam.Ruby.4.0';               Name = 'Ruby';              Category = 'Dev'; Tags = 'gelistirme development ruby betik script' }
        [PSCustomObject]@{ Id = 'rjpcomputing.luaforwindows';               Name = 'Lua';               Category = 'Dev'; Tags = 'gelistirme development lua betik script' }
        [PSCustomObject]@{ Id = 'WinsiderSS.SystemInformer';                Name = 'System Informer';   Category = 'Dev'; Tags = 'gelistirme development surec process sistem monitor system informer' }

        [PSCustomObject]@{ Id = 'Discord.Discord';                       Name = 'Discord';       Category = 'Comms'; Tags = 'iletisim chat sohbet sesli voice discord oyun' }
        [PSCustomObject]@{ Id = 'Telegram.TelegramDesktop';              Name = 'Telegram';      Category = 'Comms'; Tags = 'iletisim chat sohbet mesaj message telegram' }
        [PSCustomObject]@{ Id = 'OpenWhisperSystems.Signal';             Name = 'Signal';        Category = 'Comms'; Tags = 'iletisim chat sohbet mesaj gizlilik privacy signal' }
        [PSCustomObject]@{ Id = 'Zoom.Zoom';                             Name = 'Zoom';          Category = 'Comms'; Tags = 'iletisim toplanti meeting video konferans zoom' }
        [PSCustomObject]@{ Id = 'Microsoft.Teams';                       Name = 'Teams';         Category = 'Comms'; Tags = 'iletisim toplanti meeting microsoft teams' }
        [PSCustomObject]@{ Id = 'SlackTechnologies.Slack';               Name = 'Slack';         Category = 'Comms'; Tags = 'iletisim chat sohbet is work slack' }
        [PSCustomObject]@{ Id = 'Mozilla.Thunderbird';                   Name = 'Thunderbird';   Category = 'Comms'; Tags = 'iletisim eposta email mail thunderbird mozilla' }
        [PSCustomObject]@{ Id = 'Element.Element';                       Name = 'Element';       Category = 'Comms'; Tags = 'iletisim chat sohbet matrix element' }
        [PSCustomObject]@{ Id = 'Foundry376.Mailspring';                 Name = 'Mailspring';    Category = 'Comms'; Tags = 'iletisim eposta email mail mailspring' }
        [PSCustomObject]@{ Id = 'ChatterinoTeam.Chatterino';             Name = 'Chatterino';    Category = 'Comms'; Tags = 'iletisim chat sohbet twitch izleyici viewer chatterino' }
        [PSCustomObject]@{ Id = 'SpikeHD.Dorion';                        Name = 'Dorion';        Category = 'Comms'; Tags = 'iletisim chat sohbet discord alternatif hafif client dorion' }
        [PSCustomObject]@{ Id = 'Proton.ProtonMail';                     Name = 'Proton Mail';   Category = 'Comms'; Tags = 'iletisim eposta email mail gizlilik privacy proton' }
        [PSCustomObject]@{ Id = 'Tox.qTox';                              Name = 'qTox';          Category = 'Comms'; Tags = 'iletisim chat sohbet mesaj gizlilik privacy tox uctan uca encrypted' }
        [PSCustomObject]@{ Id = 'TeamSpeakSystems.TeamSpeakClient';      Name = 'TeamSpeak';     Category = 'Comms'; Tags = 'iletisim sesli voice sohbet oyun gaming teamspeak' }
        [PSCustomObject]@{ Id = 'Betterbird.Betterbird';                 Name = 'Betterbird';    Category = 'Comms'; Tags = 'iletisim eposta email mail thunderbird fork betterbird' }
        [PSCustomObject]@{ Id = 'Vencord.Vesktop';                       Name = 'Vesktop';       Category = 'Comms'; Tags = 'iletisim chat sohbet discord alternatif client vesktop vencord' }
        [PSCustomObject]@{ Id = 'Rakuten.Viber';                         Name = 'Viber';         Category = 'Comms'; Tags = 'iletisim chat sohbet mesaj arama call viber' }

        [PSCustomObject]@{ Id = 'TheDocumentFoundation.LibreOffice';     Name = 'LibreOffice';   Category = 'Document'; Tags = 'ofis office belge document yazi tablo libreoffice' }
        [PSCustomObject]@{ Id = 'ONLYOFFICE.DesktopEditors';             Name = 'ONLYOFFICE';    Category = 'Document'; Tags = 'ofis office belge document yazi tablo onlyoffice' }
        [PSCustomObject]@{ Id = 'Notion.Notion';                         Name = 'Notion';        Category = 'Document'; Tags = 'not note belge document notion' }
        [PSCustomObject]@{ Id = 'Obsidian.Obsidian';                     Name = 'Obsidian';      Category = 'Document'; Tags = 'not note markdown belge obsidian' }
        [PSCustomObject]@{ Id = 'Joplin.Joplin';                         Name = 'Joplin';        Category = 'Document'; Tags = 'not note markdown senkron joplin' }
        [PSCustomObject]@{ Id = 'Adobe.Acrobat.Reader.64-bit';           Name = 'Acrobat Reader';Category = 'Document'; Tags = 'pdf belge document okuyucu reader adobe acrobat' }
        [PSCustomObject]@{ Id = 'SumatraPDF.SumatraPDF';                 Name = 'SumatraPDF';    Category = 'Document'; Tags = 'pdf belge document okuyucu reader hafif sumatra' }
        [PSCustomObject]@{ Id = 'DigitalScholar.Zotero';                 Name = 'Zotero';        Category = 'Document'; Tags = 'kaynakca referans akademik research zotero' }
        [PSCustomObject]@{ Id = 'Foxit.FoxitReader';                     Name = 'Foxit Reader';  Category = 'Document'; Tags = 'pdf belge document okuyucu reader foxit' }
        [PSCustomObject]@{ Id = 'Cyanfish.NAPS2';                        Name = 'NAPS2';         Category = 'Document'; Tags = 'tarama scan belge document tarayici scanner naps2' }
        [PSCustomObject]@{ Id = 'KDE.Okular';                            Name = 'Okular';        Category = 'Document'; Tags = 'pdf belge document okuyucu reader goruntuleyici viewer okular' }
        [PSCustomObject]@{ Id = 'TrackerSoftware.PDF-XChangeEditor';     Name = 'PDF-XChange';   Category = 'Document'; Tags = 'pdf belge document duzenleyici editor pdf-xchange' }
        [PSCustomObject]@{ Id = 'geeksoftwareGmbH.PDF24Creator';         Name = 'PDF24 Creator'; Category = 'Document'; Tags = 'pdf belge document olusturucu creator donusturucu converter pdf24' }
        [PSCustomObject]@{ Id = 'PDFgear.PDFgear';                       Name = 'PDFgear';       Category = 'Document'; Tags = 'pdf belge document duzenleyici editor donusturucu converter pdfgear' }
        [PSCustomObject]@{ Id = 'PDFsam.PDFsam';                         Name = 'PDFsam';        Category = 'Document'; Tags = 'pdf belge document birlestir split merge ayir pdfsam' }
        [PSCustomObject]@{ Id = 'pbek.QOwnNotes';                        Name = 'QOwnNotes';     Category = 'Document'; Tags = 'not note markdown belge document qownnotes' }
        [PSCustomObject]@{ Id = 'Automattic.Simplenote';                 Name = 'Simplenote';    Category = 'Document'; Tags = 'not note basit simple senkron sync simplenote' }
        [PSCustomObject]@{ Id = 'Xournal++.Xournal++';                   Name = 'Xournal++';     Category = 'Document'; Tags = 'not note pdf belge document el yazisi handwriting annotation xournal' }

        [PSCustomObject]@{ Id = 'Valve.Steam';                           Name = 'Steam';           Category = 'Games'; Tags = 'oyun game gaming steam valve kutuphane' }
        [PSCustomObject]@{ Id = 'EpicGames.EpicGamesLauncher';           Name = 'Epic Games';      Category = 'Games'; Tags = 'oyun game gaming epic launcher' }
        [PSCustomObject]@{ Id = 'GOG.Galaxy';                            Name = 'GOG Galaxy';      Category = 'Games'; Tags = 'oyun game gaming gog galaxy' }
        [PSCustomObject]@{ Id = 'ElectronicArts.EADesktop';              Name = 'EA app';          Category = 'Games'; Tags = 'oyun game gaming ea origin electronic arts' }
        [PSCustomObject]@{ Id = 'Ubisoft.Connect';                       Name = 'Ubisoft Connect'; Category = 'Games'; Tags = 'oyun game gaming ubisoft uplay connect' }
        [PSCustomObject]@{ Id = 'Blizzard.BattleNet';                    Name = 'Battle.net';      Category = 'Games'; Tags = 'oyun game gaming blizzard battlenet' }
        [PSCustomObject]@{ Id = 'Cemu.Cemu';                             Name = 'Cemu';            Category = 'Games'; Tags = 'oyun game emulator wiiu emulasyon cemu' }
        [PSCustomObject]@{ Id = 'ES-DE.EmulationStation-DE';             Name = 'ES-DE';           Category = 'Games'; Tags = 'oyun game emulator emulasyon frontend arayuz emulationstation' }
        [PSCustomObject]@{ Id = 'Nvidia.GeForceNow';                     Name = 'GeForce NOW';     Category = 'Games'; Tags = 'oyun game bulut cloud stream yayin nvidia geforce' }
        [PSCustomObject]@{ Id = 'HeroicGamesLauncher.HeroicGamesLauncher'; Name = 'Heroic Games';  Category = 'Games'; Tags = 'oyun game epic gog launcher acik kaynak open source heroic' }
        [PSCustomObject]@{ Id = 'ItchIo.Itch';                           Name = 'itch.io';         Category = 'Games'; Tags = 'oyun game indie bagimsiz launcher itch' }
        [PSCustomObject]@{ Id = 'Modrinth.ModrinthApp';                  Name = 'Modrinth';        Category = 'Games'; Tags = 'oyun game minecraft mod yonetici manager modrinth' }
        [PSCustomObject]@{ Id = 'Playnite.Playnite';                     Name = 'Playnite';        Category = 'Games'; Tags = 'oyun game kutuphane library launcher birlestirici unifier playnite' }
        [PSCustomObject]@{ Id = 'PrismLauncher.PrismLauncher';           Name = 'Prism Launcher';  Category = 'Games'; Tags = 'oyun game minecraft launcher acik kaynak open source prism' }
        [PSCustomObject]@{ Id = 'Roblox.Roblox';                         Name = 'Roblox';          Category = 'Games'; Tags = 'oyun game roblox' }
        [PSCustomObject]@{ Id = 'VirtualDesktop.Streamer';               Name = 'Virtual Desktop'; Category = 'Games'; Tags = 'oyun game vr sanal gerceklik stream yayin streamer' }
        [PSCustomObject]@{ Id = 'Overwolf.CurseForge';                   Name = 'CurseForge';      Category = 'Games'; Tags = 'oyun game mod yonetici manager launcher curseforge overwolf' }

        [PSCustomObject]@{ Id = 'Microsoft.PowerShell';                     Name = 'PowerShell 7';      Category = 'Microsoft'; Tags = 'gelistirme development kabuk shell powershell terminal microsoft' }
        [PSCustomObject]@{ Id = 'Microsoft.WindowsTerminal';                Name = 'Windows Terminal';  Category = 'Microsoft'; Tags = 'gelistirme development terminal konsol console microsoft' }
        [PSCustomObject]@{ Id = 'Microsoft.PowerToys';                      Name = 'PowerToys';         Category = 'Microsoft'; Tags = 'arac tool microsoft powertoys fancyzones' }
        [PSCustomObject]@{ Id = 'Microsoft.Sysinternals.ProcessExplorer';   Name = 'Process Explorer';  Category = 'Microsoft'; Tags = 'surec process gorev manager sysinternals microsoft' }
        [PSCustomObject]@{ Id = 'Microsoft.Sysinternals.Autoruns';          Name = 'Autoruns';          Category = 'Microsoft'; Tags = 'baslangic startup otomatik sysinternals microsoft' }
        [PSCustomObject]@{ Id = 'Microsoft.Sysinternals.RDCMan';            Name = 'RDCMan';            Category = 'Microsoft'; Tags = 'uzak remote masaustu desktop baglanti manager rdcman sysinternals microsoft' }
        [PSCustomObject]@{ Id = 'CodingWondersSoftware.DISMTools.Stable';   Name = 'DISMTools';         Category = 'Microsoft'; Tags = 'windows imaj image dism onarim repair kurulum setup dismtools' }
        [PSCustomObject]@{ Id = 'Nlitesoft.NTLite';                         Name = 'NTLite';            Category = 'Microsoft'; Tags = 'windows imaj image ozellestirme customize kurulum setup ntlite' }
        [PSCustomObject]@{ Id = 'Microsoft.DotNet.DesktopRuntime.6';        Name = '.NET Runtime 6';    Category = 'Microsoft'; Tags = 'gelistirme development dotnet net runtime microsoft calisma zamani' }
        [PSCustomObject]@{ Id = 'Microsoft.DotNet.DesktopRuntime.8';        Name = '.NET Runtime 8';    Category = 'Microsoft'; Tags = 'gelistirme development dotnet net runtime microsoft calisma zamani' }
        [PSCustomObject]@{ Id = 'Microsoft.DotNet.DesktopRuntime.9';        Name = '.NET Runtime 9';    Category = 'Microsoft'; Tags = 'gelistirme development dotnet net runtime microsoft calisma zamani' }
        [PSCustomObject]@{ Id = 'Microsoft.DotNet.DesktopRuntime.10';       Name = '.NET Runtime 10';   Category = 'Microsoft'; Tags = 'gelistirme development dotnet net runtime microsoft calisma zamani' }
        [PSCustomObject]@{ Id = 'Microsoft.NuGet';                          Name = 'NuGet';             Category = 'Microsoft'; Tags = 'gelistirme development dotnet paket yonetici package manager nuget microsoft' }
        [PSCustomObject]@{ Id = 'Microsoft.OneDrive';                       Name = 'OneDrive';          Category = 'Microsoft'; Tags = 'bulut cloud senkron sync yedek backup onedrive microsoft' }
        [PSCustomObject]@{ Id = 'Microsoft.Sysinternals.ProcessMonitor';    Name = 'Process Monitor';   Category = 'Microsoft'; Tags = 'surec process izleme monitor sysinternals microsoft procmon' }
        [PSCustomObject]@{ Id = 'Microsoft.Sysinternals.TCPView';           Name = 'TCPView';           Category = 'Microsoft'; Tags = 'ag network baglanti connection izleme monitor sysinternals microsoft' }

        [PSCustomObject]@{ Id = 'VideoLAN.VLC';                          Name = 'VLC';             Category = 'Media'; Tags = 'medya media video oynatici player vlc film muzik' }
        [PSCustomObject]@{ Id = 'Spotify.Spotify';                       Name = 'Spotify';         Category = 'Media'; Tags = 'medya media muzik music spotify sarki' }
        [PSCustomObject]@{ Id = 'OBSProject.OBSStudio';                  Name = 'OBS Studio';      Category = 'Media'; Tags = 'medya media yayin stream kayit record obs' }
        [PSCustomObject]@{ Id = 'Audacity.Audacity';                     Name = 'Audacity';        Category = 'Media'; Tags = 'medya media ses audio duzenleme edit audacity' }
        [PSCustomObject]@{ Id = 'HandBrake.HandBrake';                   Name = 'HandBrake';       Category = 'Media'; Tags = 'medya media video donusturucu converter handbrake' }
        [PSCustomObject]@{ Id = 'GIMP.GIMP';                             Name = 'GIMP';            Category = 'Media'; Tags = 'medya media gorsel image resim photo duzenleme gimp' }
        [PSCustomObject]@{ Id = 'Inkscape.Inkscape';                     Name = 'Inkscape';        Category = 'Media'; Tags = 'medya media vektor vector svg cizim inkscape' }
        [PSCustomObject]@{ Id = 'BlenderFoundation.Blender';             Name = 'Blender';         Category = 'Media'; Tags = 'medya media 3d modelleme animasyon blender' }
        [PSCustomObject]@{ Id = 'KDE.Kdenlive';                          Name = 'Kdenlive';        Category = 'Media'; Tags = 'medya media video kurgu edit kdenlive' }
        [PSCustomObject]@{ Id = 'Gyan.FFmpeg';                           Name = 'FFmpeg';          Category = 'Media'; Tags = 'medya media video ses donusturucu ffmpeg komut satiri' }
        [PSCustomObject]@{ Id = 'CodecGuide.K-LiteCodecPack.Standard';   Name = 'K-Lite Codecs';   Category = 'Media'; Tags = 'medya media kodek codec video oynatici k-lite' }
        [PSCustomObject]@{ Id = 'clsid2.mpc-hc';                         Name = 'MPC-HC';          Category = 'Media'; Tags = 'medya media video oynatici player mpc hafif' }
        [PSCustomObject]@{ Id = 'Daum.PotPlayer';                        Name = 'PotPlayer';       Category = 'Media'; Tags = 'medya media video oynatici player potplayer' }
        [PSCustomObject]@{ Id = 'ShareX.ShareX';                         Name = 'ShareX';          Category = 'Media'; Tags = 'ekran goruntusu screenshot kayit record sharex' }
        [PSCustomObject]@{ Id = 'Flameshot.Flameshot';                   Name = 'Flameshot';       Category = 'Media'; Tags = 'ekran goruntusu screenshot flameshot' }
        [PSCustomObject]@{ Id = 'AIMP.AIMP';                             Name = 'AIMP';            Category = 'Media'; Tags = 'medya media muzik music oynatici player aimp' }
        [PSCustomObject]@{ Id = 'calibre.calibre';                       Name = 'Calibre';         Category = 'Media'; Tags = 'medya media ekitap ebook kutuphane library donusturucu converter calibre' }
        [PSCustomObject]@{ Id = 'File-New-Project.EarTrumpet';           Name = 'EarTrumpet';      Category = 'Media'; Tags = 'medya media ses audio ses seviyesi volume karistirici mixer eartrumpet' }
        [PSCustomObject]@{ Id = 'PeterPawlowski.foobar2000';             Name = 'foobar2000';      Category = 'Media'; Tags = 'medya media muzik music oynatici player foobar2000' }
        [PSCustomObject]@{ Id = 'DuongDieuPhap.ImageGlass';              Name = 'ImageGlass';      Category = 'Media'; Tags = 'medya media gorsel image goruntuleyici viewer imageglass' }
        [PSCustomObject]@{ Id = 'IrfanSkiljan.IrfanView';                Name = 'IrfanView';       Category = 'Media'; Tags = 'medya media gorsel image goruntuleyici viewer irfanview hafif' }
        [PSCustomObject]@{ Id = 'Apple.iTunes';                          Name = 'iTunes';          Category = 'Media'; Tags = 'medya media muzik music oynatici player apple itunes' }
        [PSCustomObject]@{ Id = 'mpc-qt.mpc-qt';                         Name = 'mpc-qt';          Category = 'Media'; Tags = 'medya media video oynatici player mpc-qt mpv' }
        [PSCustomObject]@{ Id = 'shinchiro.mpv';                         Name = 'mpv';             Category = 'Media'; Tags = 'medya media video oynatici player mpv hafif minimal' }
        [PSCustomObject]@{ Id = 'nomacs.nomacs';                         Name = 'nomacs';          Category = 'Media'; Tags = 'medya media gorsel image goruntuleyici viewer nomacs acik kaynak open source' }
        [PSCustomObject]@{ Id = 'dotPDN.PaintDotNet';                    Name = 'Paint.NET';       Category = 'Media'; Tags = 'medya media gorsel image duzenleme edit paint fotograf photo' }

        [PSCustomObject]@{ Id = 'CPUID.CPU-Z';                               Name = 'CPU-Z';           Category = 'ProTools'; Tags = 'donanim hardware bilgi info islemci cpu' }
        [PSCustomObject]@{ Id = 'REALiX.HWiNFO';                             Name = 'HWiNFO';          Category = 'ProTools'; Tags = 'donanim hardware bilgi info sensor sicaklik hwinfo' }
        [PSCustomObject]@{ Id = 'TechPowerUp.GPU-Z';                         Name = 'GPU-Z';           Category = 'ProTools'; Tags = 'donanim hardware bilgi info ekran karti gpu' }
        [PSCustomObject]@{ Id = 'Ventoy.Ventoy';                             Name = 'Ventoy';          Category = 'ProTools'; Tags = 'usb onyukleme boot iso ventoy' }
        [PSCustomObject]@{ Id = 'WinSCP.WinSCP';                             Name = 'WinSCP';          Category = 'ProTools'; Tags = 'ftp sftp dosya transfer winscp uzak' }
        [PSCustomObject]@{ Id = 'PuTTY.PuTTY';                               Name = 'PuTTY';           Category = 'ProTools'; Tags = 'ssh terminal uzak remote putty' }
        [PSCustomObject]@{ Id = 'WiresharkFoundation.Wireshark';             Name = 'Wireshark';       Category = 'ProTools'; Tags = 'ag network paket analiz wireshark' }
        [PSCustomObject]@{ Id = 'Famatech.AdvancedIPScanner';                Name = 'Advanced IP Scanner'; Category = 'ProTools'; Tags = 'ag network tarama scan ip adres address famatech' }
        [PSCustomObject]@{ Id = 'angryziber.AngryIPScanner';                 Name = 'Angry IP Scanner';    Category = 'ProTools'; Tags = 'ag network tarama scan ip adres address hafif lightweight' }
        [PSCustomObject]@{ Id = 'Maxon.CinebenchR23';                        Name = 'Cinebench R23';       Category = 'ProTools'; Tags = 'benchmark test performans islemci cpu render cinebench' }
        [PSCustomObject]@{ Id = 'Wagnardsoft.DisplayDriverUninstaller';      Name = 'DDU';                 Category = 'ProTools'; Tags = 'donanim hardware ekran karti gpu surucu driver kaldirma uninstall ddu' }
        [PSCustomObject]@{ Id = 'gerardog.gsudo';                            Name = 'gsudo';               Category = 'ProTools'; Tags = 'komut satiri cli yonetici admin sudo yukseltme elevate gsudo' }
        [PSCustomObject]@{ Id = 'CPUID.HWMonitor';                           Name = 'HWMonitor';           Category = 'ProTools'; Tags = 'donanim hardware sicaklik temperature sensor izleme monitor hwmonitor' }
        [PSCustomObject]@{ Id = 'MullvadVPN.MullvadVPN';                     Name = 'Mullvad VPN';         Category = 'ProTools'; Tags = 'vpn gizlilik privacy anonim mullvad' }
        [PSCustomObject]@{ Id = 'Insecure.Nmap';                             Name = 'Nmap';                Category = 'ProTools'; Tags = 'ag network tarama scan port guvenlik security nmap' }
        [PSCustomObject]@{ Id = 'OpenVPNTechnologies.OpenVPNConnect';        Name = 'OpenVPN Connect';     Category = 'ProTools'; Tags = 'vpn baglanti connection openvpn' }
        [PSCustomObject]@{ Id = 'Proton.ProtonVPN';                          Name = 'Proton VPN';          Category = 'ProTools'; Tags = 'vpn gizlilik privacy anonim proton' }
        [PSCustomObject]@{ Id = 'Henry++.simplewall';                        Name = 'simplewall';          Category = 'ProTools'; Tags = 'guvenlik duvari firewall ag network trafik kontrol simplewall' }
        [PSCustomObject]@{ Id = 'WireGuard.WireGuard';                       Name = 'WireGuard';           Category = 'ProTools'; Tags = 'vpn baglanti connection hizli fast wireguard' }

        [PSCustomObject]@{ Id = 'Nextcloud.NextcloudDesktop';                       Name = 'Nextcloud';       Category = 'Selfhosted'; Tags = 'bulut cloud senkron sync nextcloud yedek' }
        [PSCustomObject]@{ Id = 'Jellyfin.JellyfinMediaPlayer';                     Name = 'Jellyfin Player'; Category = 'Selfhosted'; Tags = 'medya media sunucu server oynatici player jellyfin selfhosted' }
        [PSCustomObject]@{ Id = 'Jellyfin.Server';                                  Name = 'Jellyfin Server'; Category = 'Selfhosted'; Tags = 'medya media sunucu server jellyfin selfhosted' }
        [PSCustomObject]@{ Id = 'XBMCFoundation.Kodi';                              Name = 'Kodi';            Category = 'Selfhosted'; Tags = 'medya media merkezi center sunucu server kodi' }
        [PSCustomObject]@{ Id = 'LocalSend.LocalSend';                              Name = 'LocalSend';       Category = 'Selfhosted'; Tags = 'dosya file transfer paylasim share yerel local ag network' }
        [PSCustomObject]@{ Id = 'MoonlightGameStreamingProject.Moonlight';          Name = 'Moonlight';       Category = 'Selfhosted'; Tags = 'oyun game stream yayin istemci client moonlight gamestream' }
        [PSCustomObject]@{ Id = 'Netbird.Netbird';                                  Name = 'NetBird';         Category = 'Selfhosted'; Tags = 'ag network vpn mesh netbird selfhosted' }
        [PSCustomObject]@{ Id = 'Plex.PlexMediaServer';                             Name = 'Plex Server';     Category = 'Selfhosted'; Tags = 'medya media sunucu server plex selfhosted' }
        [PSCustomObject]@{ Id = 'Plex.Plex';                                        Name = 'Plex';            Category = 'Selfhosted'; Tags = 'medya media oynatici player istemci client plex' }
        [PSCustomObject]@{ Id = 'LizardByte.Sunshine';                              Name = 'Sunshine';        Category = 'Selfhosted'; Tags = 'oyun game stream yayin sunucu server sunshine gamestream selfhosted' }

        [PSCustomObject]@{ Id = '7zip.7zip';                                 Name = '7-Zip';           Category = 'Utilities'; Tags = 'arsiv archive sikistirma zip rar 7zip' }
        [PSCustomObject]@{ Id = 'RARLab.WinRAR';                             Name = 'WinRAR';          Category = 'Utilities'; Tags = 'arsiv archive sikistirma zip rar winrar' }
        [PSCustomObject]@{ Id = 'voidtools.Everything';                      Name = 'Everything';      Category = 'Utilities'; Tags = 'arama search dosya file bulma everything hizli' }
        [PSCustomObject]@{ Id = 'CrystalDewWorld.CrystalDiskInfo';           Name = 'CrystalDiskInfo'; Category = 'Utilities'; Tags = 'disk saglik health smart bilgi crystaldiskinfo' }
        [PSCustomObject]@{ Id = 'CrystalDewWorld.CrystalDiskMark';           Name = 'CrystalDiskMark'; Category = 'Utilities'; Tags = 'disk hiz speed test benchmark crystaldiskmark' }
        [PSCustomObject]@{ Id = 'Rufus.Rufus';                               Name = 'Rufus';           Category = 'Utilities'; Tags = 'usb onyukleme boot iso rufus' }
        [PSCustomObject]@{ Id = 'Balena.Etcher';                             Name = 'balenaEtcher';    Category = 'Utilities'; Tags = 'usb onyukleme boot iso etcher balena' }
        [PSCustomObject]@{ Id = 'BleachBit.BleachBit';                       Name = 'BleachBit';       Category = 'Utilities'; Tags = 'temizlik cleanup disk temizleyici bleachbit' }
        [PSCustomObject]@{ Id = 'JAMSoftware.TreeSize.Free';                 Name = 'TreeSize Free';   Category = 'Utilities'; Tags = 'disk alan space analiz klasor treesize' }
        [PSCustomObject]@{ Id = 'WinDirStat.WinDirStat';                     Name = 'WinDirStat';      Category = 'Utilities'; Tags = 'disk alan space analiz klasor windirstat' }
        [PSCustomObject]@{ Id = 'Bitwarden.Bitwarden';                       Name = 'Bitwarden';       Category = 'Utilities'; Tags = 'parola password sifre yonetici manager bitwarden' }
        [PSCustomObject]@{ Id = 'KeePassXCTeam.KeePassXC';                   Name = 'KeePassXC';       Category = 'Utilities'; Tags = 'parola password sifre yonetici manager keepass' }
        [PSCustomObject]@{ Id = 'Malwarebytes.Malwarebytes';                 Name = 'Malwarebytes';    Category = 'Utilities'; Tags = 'guvenlik security virus zararli malware tarama' }
        [PSCustomObject]@{ Id = 'qBittorrent.qBittorrent';                   Name = 'qBittorrent';     Category = 'Utilities'; Tags = 'indirme download torrent qbittorrent' }
        [PSCustomObject]@{ Id = 'AnyDesk.AnyDesk';                           Name = 'AnyDesk';         Category = 'Utilities'; Tags = 'uzak remote masaustu destek anydesk' }
        [PSCustomObject]@{ Id = 'TeamViewer.TeamViewer';                     Name = 'TeamViewer';      Category = 'Utilities'; Tags = 'uzak remote masaustu destek teamviewer' }
        [PSCustomObject]@{ Id = 'Greenshot.Greenshot';                       Name = 'Greenshot';       Category = 'Utilities'; Tags = 'ekran goruntusu screenshot greenshot' }
        [PSCustomObject]@{ Id = 'Piriform.CCleaner';                         Name = 'CCleaner';        Category = 'Utilities'; Tags = 'temizlik cleanup kayit registry ccleaner' }
        [PSCustomObject]@{ Id = 'AgileBits.1Password';                       Name = '1Password';       Category = 'Utilities'; Tags = 'parola password sifre yonetici manager 1password' }
        [PSCustomObject]@{ Id = 'AutoHotkey.AutoHotkey';                     Name = 'AutoHotkey';      Category = 'Utilities'; Tags = 'otomasyon automation makro macro script betik autohotkey' }
        [PSCustomObject]@{ Id = 'Klocman.BulkCrapUninstaller';               Name = 'BCUninstaller';   Category = 'Utilities'; Tags = 'kaldirma uninstall program toplu bulk temizlik cleanup' }
        [PSCustomObject]@{ Id = 'Blur009.BlurAutoClicker';                   Name = 'BlurAutoClicker'; Category = 'Utilities'; Tags = 'otomasyon automation fare mouse tiklayici clicker oyun gaming' }
        [PSCustomObject]@{ Id = 'Dropbox.Dropbox';                           Name = 'Dropbox';         Category = 'Utilities'; Tags = 'bulut cloud senkron sync yedek backup dropbox' }
        [PSCustomObject]@{ Id = 'ente-io.auth-desktop';                      Name = 'Ente Auth';       Category = 'Utilities'; Tags = 'guvenlik security iki adimli 2fa dogrulama authenticator ente' }
        [PSCustomObject]@{ Id = 'FilesCommunity.Files';                      Name = 'Files';           Category = 'Utilities'; Tags = 'dosya file yonetici manager gezgin explorer files' }
        [PSCustomObject]@{ Id = 'flux.flux';                                 Name = 'f.lux';           Category = 'Utilities'; Tags = 'ekran screen renk sicakligi color temperature mavi isik blue light flux' }
        [PSCustomObject]@{ Id = 'Google.GoogleDrive';                        Name = 'Google Drive';    Category = 'Utilities'; Tags = 'bulut cloud senkron sync yedek backup google drive' }
        [PSCustomObject]@{ Id = 'Hugo.Hugo.Extended';                        Name = 'Hugo';            Category = 'Utilities'; Tags = 'statik site static site olusturucu generator hugo' }
        [PSCustomObject]@{ Id = 'Tonec.InternetDownloadManager';             Name = 'IDM';             Category = 'Utilities'; Tags = 'indirme download yonetici manager hizlandirici accelerator idm' }
        [PSCustomObject]@{ Id = 'sylikc.JPEGView';                           Name = 'JPEGView';        Category = 'Utilities'; Tags = 'gorsel image goruntuleyici viewer hafif lightweight jpegview' }
        [PSCustomObject]@{ Id = 'rcmaehl.MSEdgeRedirect';                    Name = 'MSEdgeRedirect';  Category = 'Utilities'; Tags = 'windows edge yonlendirme redirect varsayilan default tarayici browser' }
        [PSCustomObject]@{ Id = 'Guru3D.Afterburner';                        Name = 'MSI Afterburner'; Category = 'Utilities'; Tags = 'donanim hardware ekran karti gpu hiz artirma overclock afterburner' }
        [PSCustomObject]@{ Id = 'M2Team.NanaZip';                            Name = 'NanaZip';         Category = 'Utilities'; Tags = 'arsiv archive sikistirma zip 7z nanazip' }
        [PSCustomObject]@{ Id = 'Tailscale.Tailscale';                       Name = 'Tailscale';       Category = 'Utilities'; Tags = 'vpn ag network mesh tailscale uzak remote' }
        [PSCustomObject]@{ Id = 'TechPowerUp.NVCleanstall';                  Name = 'NVCleanstall';    Category = 'Utilities'; Tags = 'donanim hardware nvidia surucu driver kurulum install temiz clean' }
        [PSCustomObject]@{ Id = 'MiniTool.PartitionWizard.Free';             Name = 'Partition Wizard'; Category = 'Utilities'; Tags = 'disk bolumlendirme partition yonetici manager minitool' }
        [PSCustomObject]@{ Id = 'OPAutoClicker.OPAutoClicker';               Name = 'OPAutoClicker';   Category = 'Utilities'; Tags = 'otomasyon automation fare mouse tiklayici clicker oyun gaming' }
        [PSCustomObject]@{ Id = 'OpenRGB.OpenRGB';                           Name = 'OpenRGB';         Category = 'Utilities'; Tags = 'rgb aydinlatma lighting kontrol control acik kaynak open source' }
        [PSCustomObject]@{ Id = 'Oracle.VirtualBox';                         Name = 'VirtualBox';      Category = 'Utilities'; Tags = 'sanal makine virtual machine vm oracle virtualbox' }
        [PSCustomObject]@{ Id = 'Fleex255.PolicyPlus';                       Name = 'PolicyPlus';      Category = 'Utilities'; Tags = 'grup ilkesi group policy duzenleyici editor registry policyplus' }
        [PSCustomObject]@{ Id = 'Parsec.Parsec';                             Name = 'Parsec';          Category = 'Utilities'; Tags = 'uzak remote masaustu desktop oyun gaming stream parsec' }
        [PSCustomObject]@{ Id = 'Giorgiotani.Peazip';                        Name = 'PeaZip';          Category = 'Utilities'; Tags = 'arsiv archive sikistirma zip rar 7z peazip' }
        [PSCustomObject]@{ Id = 'BitSum.ProcessLasso';                       Name = 'Process Lasso';   Category = 'Utilities'; Tags = 'surec process oncelik priority cpu optimizasyon optimization processlasso' }
        [PSCustomObject]@{ Id = 'Proton.ProtonAuthenticator';                Name = 'Proton Authenticator'; Category = 'Utilities'; Tags = 'guvenlik security iki adimli 2fa dogrulama authenticator proton' }
        [PSCustomObject]@{ Id = 'Proton.ProtonDrive';                        Name = 'Proton Drive';    Category = 'Utilities'; Tags = 'bulut cloud senkron sync gizlilik privacy proton drive' }
        [PSCustomObject]@{ Id = 'Proton.ProtonPass';                         Name = 'Proton Pass';     Category = 'Utilities'; Tags = 'parola password sifre yonetici manager gizlilik privacy proton pass' }
        [PSCustomObject]@{ Id = 'RevoUninstaller.RevoUninstaller';           Name = 'Revo Uninstaller'; Category = 'Utilities'; Tags = 'kaldirma uninstall program temizlik cleanup revo' }
        [PSCustomObject]@{ Id = 'WiseCleaner.WiseProgramUninstaller';        Name = 'Wise Uninstaller'; Category = 'Utilities'; Tags = 'kaldirma uninstall program temizlik cleanup wise' }
        [PSCustomObject]@{ Id = 'GlennDelahoy.SnappyDriverInstallerOrigin';  Name = 'SDIO';            Category = 'Utilities'; Tags = 'surucu driver kurulum install guncelleme update snappy sdio' }
        [PSCustomObject]@{ Id = 'Nilesoft.Shell';                            Name = 'Nilesoft Shell';  Category = 'Utilities'; Tags = 'baglam menu context menu ozellestirme customize nilesoft shell' }
        [PSCustomObject]@{ Id = 'WhirlwindFX.SignalRgb';                     Name = 'SignalRGB';       Category = 'Utilities'; Tags = 'rgb aydinlatma lighting kontrol control signalrgb' }
        [PSCustomObject]@{ Id = 'StartIsBack.StartAllBack';                  Name = 'StartAllBack';    Category = 'Utilities'; Tags = 'baslat start menu gorev cubugu taskbar ozellestirme customize startallback' }
        [PSCustomObject]@{ Id = 'Ghisler.TotalCommander';                    Name = 'Total Commander'; Category = 'Utilities'; Tags = 'dosya file yonetici manager iki panelli dual pane total commander' }
        [PSCustomObject]@{ Id = 'CharlesMilette.TranslucentTB';              Name = 'TranslucentTB';   Category = 'Utilities'; Tags = 'gorev cubugu taskbar saydamlik transparency translucenttb' }
        [PSCustomObject]@{ Id = 'Devolutions.UniGetUI';                      Name = 'UniGetUI';        Category = 'Utilities'; Tags = 'paket yonetici package manager arayuz gui winget unigetui' }
        [PSCustomObject]@{ Id = 'AntibodySoftware.WizTree';                  Name = 'WizTree';         Category = 'Utilities'; Tags = 'disk alan space analiz klasor folder wiztree hizli fast' }
        [PSCustomObject]@{ Id = 'MHNexus.HxD';                               Name = 'HxD';             Category = 'Utilities'; Tags = 'hex editor ikili binary duzenleyici hxd' }
        [PSCustomObject]@{ Id = 'GlavSoft.TightVNC';                         Name = 'TightVNC';        Category = 'Utilities'; Tags = 'uzak remote masaustu desktop vnc tightvnc' }
        [PSCustomObject]@{ Id = 'glzr-io.glazewm';                           Name = 'GlazeWM';         Category = 'Utilities'; Tags = 'pencere yonetici window manager dosemeli tiling glazewm' }
        [PSCustomObject]@{ Id = 'xM4ddy.OFGB';                               Name = 'OFGB';            Category = 'Utilities'; Tags = 'windows reklam ad kaldirma remove debloat ofgb' }
        [PSCustomObject]@{ Id = 'Deskflow.Deskflow';                         Name = 'Deskflow';        Category = 'Utilities'; Tags = 'kvm klavye fare keyboard mouse paylasim share bilgisayarlar arasi deskflow' }
        [PSCustomObject]@{ Id = 'Cloudflare.Warp';                           Name = 'Cloudflare WARP'; Category = 'Utilities'; Tags = 'vpn dns gizlilik privacy hizli fast cloudflare warp' }
    )
}

function Select-WtWingetStoreApps {
    <#
    .SYNOPSIS
        The store tab's local filter: an app matches when the query occurs
        in its display name, its winget id or its hidden Tags string. Uses
        IndexOf with OrdinalIgnoreCase, never -like/-match, since those are
        culture sensitive and on tr-TR the dotted/dotless i turns "VLC" into
        a non-match for "vlc".
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Apps,
        [AllowNull()][AllowEmptyString()][string]$Query = ''
    )
    $q = ([string]$Query).Trim()
    if ($q -eq '') { return @($Apps) }
    $cmp = [System.StringComparison]::OrdinalIgnoreCase
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($app in $Apps) {
        $haystack = ([string]$app.Name) + ' ' + ([string]$app.Id) + ' ' + ([string]$app.Tags)
        if ($haystack.IndexOf($q, $cmp) -ge 0) { $out.Add($app) }
    }
    return $out.ToArray()
}
