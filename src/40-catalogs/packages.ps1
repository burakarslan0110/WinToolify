# Package catalog, name patterns, installed snapshot and live state.
# Covered by: tests/Catalog.Tests.ps1, tests/Blocklist.Tests.ps1

$script:WtPackageCatalogCache = @{}

function Get-WtPackageCatalog {
    <#
    .SYNOPSIS
        The individually-selectable Installed Apps catalog: the pre-V2
        hardcoded bloatware list, cross-checked against a real
        Get-AppxProvisionedPackage capture from a Windows 11 machine.
        VerifiedInCapture drives Restorable/IsProvisioned; unverified
        entries (mostly third-party OEM apps) stay selectable but
        flagged non-restorable. Every V1 package name is FROZEN, since
        it is the key an undo entry or exported profile was written
        with, so the few names with no confirmed publisher prefix are
        stored as explicit wildcard patterns rather than renamed -
        Test-WtPackageNameMatches compares a bare name EXACTLY.
        Remembered per language for the session and handed out as
        copies, so one caller's edits never leak into another's.
    #>
    $lang = [string]$script:Language
    if ($script:WtPackageCatalogCache.ContainsKey($lang)) { return @($script:WtPackageCatalogCache[$lang] | ForEach-Object { $_.PSObject.Copy() }) }
    $built = @(Resolve-WtCatalogText -KeyPrefix 'Package' -Catalog @(
        [PSCustomObject]@{ Name = 'Clipchamp.Clipchamp'; DisplayLabel = 'Clipchamp.Clipchamp - Clipchamp video editor'; Group = 'PkgGroupBasic'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'Microsoft.GetHelp'; DisplayLabel = 'Microsoft.GetHelp - Get Help'; Group = 'PkgGroupBasic'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'ADVANCED'; Consequence = 'Windows 11 troubleshooters run inside Get Help'; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'Microsoft.WindowsStore'; DisplayLabel = 'Microsoft.WindowsStore - Microsoft Store'; Group = 'PkgGroupBasic'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'ADVANCED'; Consequence = 'Removing the Store leaves no supported route to reinstall anything else'; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'Microsoft.WindowsTerminal'; DisplayLabel = 'Microsoft.WindowsTerminal - Windows Terminal'; Group = 'PkgGroupBasic'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'ADVANCED'; Consequence = 'The modern Terminal app is removed; legacy conhost-based cmd/PowerShell windows still work'; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'Microsoft.OneDrive'; DisplayLabel = 'Microsoft.OneDrive - OneDrive client (Win32, removed with winget)'; Group = 'PkgGroupBasic'; Legacy = $false; RemovalMethod = 'WinGet'; Risk = 'ADVANCED'; Consequence = 'Removes the OneDrive client for this user; files stay in the cloud. Not reversible from this tool. If Desktop/Documents/Pictures are backed up to OneDrive, they stay in the cloud and leave this PC''s folders'; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.SecHealthUI'; DisplayLabel = 'Microsoft.SecHealthUI - Windows Security app'; Group = 'PkgGroupBasic'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'ADVANCED'; Consequence = 'The Windows Security app UI is removed; underlying protection services may keep running but the management interface is gone'; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }

        [PSCustomObject]@{ Name = 'Microsoft.BingNews'; DisplayLabel = 'Microsoft.BingNews - Microsoft News'; Group = 'PkgGroupBing'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'Microsoft.BingTranslator'; DisplayLabel = 'Microsoft.BingTranslator - Translator'; Group = 'PkgGroupBing'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.BingWeather'; DisplayLabel = 'Microsoft.BingWeather - Weather'; Group = 'PkgGroupBing'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }

        [PSCustomObject]@{ Name = 'Microsoft.MicrosoftOfficeHub'; DisplayLabel = 'Microsoft.MicrosoftOfficeHub - Microsoft 365 Copilot hub app'; Group = 'PkgGroupOffice'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'CAUTION'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.Office.OneNote'; DisplayLabel = 'Microsoft.Office.OneNote - OneNote for Windows 10'; Group = 'PkgGroupOffice'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'CAUTION'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.Todos'; DisplayLabel = 'Microsoft.Todos - Microsoft To Do'; Group = 'PkgGroupOffice'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'CAUTION'; Consequence = $null; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'Microsoft.MicrosoftStickyNotes'; DisplayLabel = 'Microsoft.MicrosoftStickyNotes - Sticky Notes'; Group = 'PkgGroupOffice'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'CAUTION'; Consequence = $null; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'Microsoft.PowerAutomateDesktop'; DisplayLabel = 'Microsoft.PowerAutomateDesktop - Power Automate Desktop'; Group = 'PkgGroupOffice'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'CAUTION'; Consequence = $null; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }

        [PSCustomObject]@{ Name = 'Microsoft.Paint'; DisplayLabel = 'Microsoft.Paint - Paint (classic)'; Group = 'PkgGroupCreative'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'ADVANCED'; Consequence = 'Default image editor on Windows 11'; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'Microsoft.ScreenSketch'; DisplayLabel = 'Microsoft.ScreenSketch - Snipping Tool'; Group = 'PkgGroupCreative'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'ADVANCED'; Consequence = 'Snipping Tool - the only screenshot tool on Windows 11'; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'Microsoft.Whiteboard'; DisplayLabel = 'Microsoft.Whiteboard - Microsoft Whiteboard'; Group = 'PkgGroupCreative'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'CAUTION'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.Windows.Photos'; DisplayLabel = 'Microsoft.Windows.Photos - Photos'; Group = 'PkgGroupCreative'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'ADVANCED'; Consequence = 'The default image viewer is removed; images open in no app until another viewer is installed'; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'Microsoft.WindowsCamera'; DisplayLabel = 'Microsoft.WindowsCamera - Camera'; Group = 'PkgGroupCreative'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'CAUTION'; Consequence = $null; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'Microsoft.MicrosoftJournal'; DisplayLabel = 'Microsoft.MicrosoftJournal - Microsoft Journal (Surface pen notes)'; Group = 'PkgGroupCreative'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'CAUTION'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }

        [PSCustomObject]@{ Name = 'Microsoft.Xbox.TCUI'; DisplayLabel = 'Microsoft.Xbox.TCUI - Xbox Live in-game UI'; Group = 'PkgGroupGaming'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'ADVANCED'; Consequence = 'Xbox sign-in framework needed by Game Pass, Minecraft and the Store; hard to reinstall'; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'Microsoft.XboxGameOverlay'; DisplayLabel = 'Microsoft.XboxGameOverlay - Xbox Game Bar overlay component'; Group = 'PkgGroupGaming'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'CAUTION'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.XboxGamingOverlay'; DisplayLabel = 'Microsoft.XboxGamingOverlay - Xbox Game Bar'; Group = 'PkgGroupGaming'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'CAUTION'; Consequence = $null; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'Microsoft.XboxIdentityProvider'; DisplayLabel = 'Microsoft.XboxIdentityProvider - Xbox sign-in provider'; Group = 'PkgGroupGaming'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'ADVANCED'; Consequence = 'Xbox sign-in framework needed by Game Pass, Minecraft and the Store; hard to reinstall'; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'Microsoft.XboxSpeechToTextOverlay'; DisplayLabel = 'Microsoft.XboxSpeechToTextOverlay - Xbox speech-to-text overlay'; Group = 'PkgGroupGaming'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'ADVANCED'; Consequence = 'Xbox sign-in framework needed by Game Pass, Minecraft and the Store; hard to reinstall'; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'Microsoft.GamingApp'; DisplayLabel = 'Microsoft.GamingApp - Xbox app (Game Pass)'; Group = 'PkgGroupGaming'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'CAUTION'; Consequence = $null; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'Microsoft.MicrosoftSolitaireCollection'; DisplayLabel = 'Microsoft.MicrosoftSolitaireCollection - Microsoft Solitaire Collection'; Group = 'PkgGroupGaming'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }

        [PSCustomObject]@{ Name = 'Microsoft.ZuneMusic'; DisplayLabel = 'Microsoft.ZuneMusic - Media Player / Groove'; Group = 'PkgGroupMedia'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'ADVANCED'; Consequence = 'Media Player - default audio/video player on Windows 11'; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'Microsoft.ZuneVideo'; DisplayLabel = 'Microsoft.ZuneVideo - Movies & TV'; Group = 'PkgGroupMedia'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'CAUTION'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.YourPhone'; DisplayLabel = 'Microsoft.YourPhone - Phone Link'; Group = 'PkgGroupMedia'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'CAUTION'; Consequence = $null; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }

        [PSCustomObject]@{ Name = 'Microsoft.WindowsAlarms'; DisplayLabel = 'Microsoft.WindowsAlarms - Clock (alarms and timers)'; Group = 'PkgGroupUtilities'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'CAUTION'; Consequence = $null; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'Microsoft.WindowsCalculator'; DisplayLabel = 'Microsoft.WindowsCalculator - Calculator'; Group = 'PkgGroupUtilities'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'ADVANCED'; Consequence = 'The Calculator app is removed; Windows has no other built-in calculator'; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'Microsoft.WindowsFeedbackHub'; DisplayLabel = 'Microsoft.WindowsFeedbackHub - Feedback Hub'; Group = 'PkgGroupUtilities'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'CAUTION'; Consequence = $null; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'Microsoft.WindowsNotepad'; DisplayLabel = 'Microsoft.WindowsNotepad - Notepad'; Group = 'PkgGroupUtilities'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'ADVANCED'; Consequence = 'The only text editor on Windows 11'; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'Microsoft.WindowsSoundRecorder'; DisplayLabel = 'Microsoft.WindowsSoundRecorder - Sound Recorder'; Group = 'PkgGroupUtilities'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'CAUTION'; Consequence = $null; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'MicrosoftCorporationII.QuickAssist'; DisplayLabel = 'MicrosoftCorporationII.QuickAssist - Quick Assist remote support'; Group = 'PkgGroupUtilities'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'CAUTION'; Consequence = $null; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }

        [PSCustomObject]@{ Name = 'Microsoft.Copilot'; DisplayLabel = 'Microsoft.Copilot - Windows Copilot app'; Group = 'PkgGroupAi'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'Microsoft.BingSearch'; DisplayLabel = 'Microsoft.BingSearch - Bing Search (web results in Start)'; Group = 'PkgGroupAi'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'CAUTION'; Consequence = 'Web results in Start search stop'; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'MicrosoftWindows.Client.WebExperience'; DisplayLabel = 'MicrosoftWindows.Client.WebExperience - Widgets board'; Group = 'PkgGroupAi'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'Microsoft.WidgetsPlatformRuntime'; DisplayLabel = 'Microsoft.WidgetsPlatformRuntime - Widgets platform runtime'; Group = 'PkgGroupAi'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'MicrosoftWindows.CrossDevice'; DisplayLabel = 'MicrosoftWindows.CrossDevice - Cross Device Experience Host'; Group = 'PkgGroupAi'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'Microsoft.OutlookForWindows'; DisplayLabel = 'Microsoft.OutlookForWindows - new Outlook for Windows'; Group = 'PkgGroupAi'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'CAUTION'; Consequence = 'The only inbox mail client on 24H2'; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'MSTeams'; DisplayLabel = 'MSTeams - Microsoft Teams (new)'; Group = 'PkgGroupAi'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'Microsoft.Edge.GameAssist'; DisplayLabel = 'Microsoft.Edge.GameAssist - Edge Game Assist for Game Bar'; Group = 'PkgGroupAi'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = '7EE7776C.LinkedInforWindows'; DisplayLabel = '7EE7776C.LinkedInforWindows - LinkedIn'; Group = 'PkgGroupAi'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'MicrosoftCorporationII.MicrosoftFamily'; DisplayLabel = 'MicrosoftCorporationII.MicrosoftFamily - Microsoft Family Safety'; Group = 'PkgGroupAi'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
        [PSCustomObject]@{ Name = 'Microsoft.PCManager'; DisplayLabel = 'Microsoft.PCManager - Microsoft PC Manager'; Group = 'PkgGroupAi'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.Windows.AIHub'; DisplayLabel = 'Microsoft.Windows.AIHub - Copilot+ AI Hub'; Group = 'PkgGroupAi'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.StartExperiencesApp'; DisplayLabel = 'Microsoft.StartExperiencesApp - Widgets My Feed'; Group = 'PkgGroupAi'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.M365Companions'; DisplayLabel = 'Microsoft.M365Companions - Microsoft 365 companion mini-apps'; Group = 'PkgGroupAi'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.News'; DisplayLabel = 'Microsoft.News - Microsoft Start news feed'; Group = 'PkgGroupAi'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }

        [PSCustomObject]@{ Name = 'GAMELOFTSA.Asphalt8Airborne'; DisplayLabel = 'GAMELOFTSA.Asphalt8Airborne - Asphalt 8: Airborne racing game'; Group = 'PkgGroupGames'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'PlaytikaLTD.CaesarsSlotsFreeCasino'; DisplayLabel = 'PlaytikaLTD.CaesarsSlotsFreeCasino - Caesars Slots casino game'; Group = 'PkgGroupGames'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'NORDCURRENT.COOKINGFEVER'; DisplayLabel = 'NORDCURRENT.COOKINGFEVER - Cooking Fever game'; Group = 'PkgGroupGames'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'A278AB0D.DisneyMagicKingdoms'; DisplayLabel = 'A278AB0D.DisneyMagicKingdoms - Disney Magic Kingdoms game'; Group = 'PkgGroupGames'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'ZyngaInc.FarmVille2CountryEscape'; DisplayLabel = 'ZyngaInc.FarmVille2CountryEscape - FarmVille 2: Country Escape game'; Group = 'PkgGroupGames'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'G5Entertainment.HiddenCity'; DisplayLabel = 'G5Entertainment.HiddenCity - Hidden City game'; Group = 'PkgGroupGames'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'king.com.BubbleWitch3Saga'; DisplayLabel = 'king.com.BubbleWitch3Saga - Bubble Witch 3 Saga game'; Group = 'PkgGroupGames'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'king.com.CandyCrushSaga'; DisplayLabel = 'king.com.CandyCrushSaga - Candy Crush Saga game'; Group = 'PkgGroupGames'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'king.com.CandyCrushSodaSaga'; DisplayLabel = 'king.com.CandyCrushSodaSaga - Candy Crush Soda Saga game'; Group = 'PkgGroupGames'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'A278AB0D.MarchofEmpires'; DisplayLabel = 'A278AB0D.MarchofEmpires - March of Empires game'; Group = 'PkgGroupGames'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'flaregamesGmbH.RoyalRevolt'; DisplayLabel = 'flaregamesGmbH.RoyalRevolt - Royal Revolt game'; Group = 'PkgGroupGames'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = '*NYTCrossword*'; DisplayLabel = '*NYTCrossword* - New York Times Crossword game'; Group = 'PkgGroupGames'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }

        [PSCustomObject]@{ Name = '4DF9E0F8.Netflix'; DisplayLabel = '4DF9E0F8.Netflix - Netflix streaming app'; Group = 'PkgGroupEntertainment'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'SpotifyAB.SpotifyMusic'; DisplayLabel = 'SpotifyAB.SpotifyMusic - Spotify Music'; Group = 'PkgGroupEntertainment'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'HULULLC.HULUPLUS'; DisplayLabel = 'HULULLC.HULUPLUS - Hulu streaming app'; Group = 'PkgGroupEntertainment'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'AmazonVideo.PrimeVideo'; DisplayLabel = 'AmazonVideo.PrimeVideo - Amazon Prime Video'; Group = 'PkgGroupEntertainment'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'CAF9E577.Plex'; DisplayLabel = 'CAF9E577.Plex - Plex media client'; Group = 'PkgGroupEntertainment'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'ClearChannelRadioDigital.iHeartRadio'; DisplayLabel = 'ClearChannelRadioDigital.iHeartRadio - iHeartRadio streaming radio'; Group = 'PkgGroupEntertainment'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'TuneIn.TuneInRadio'; DisplayLabel = 'TuneIn.TuneInRadio - TuneIn Radio'; Group = 'PkgGroupEntertainment'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'ShazamEntertainmentLtd.Shazam'; DisplayLabel = 'ShazamEntertainmentLtd.Shazam - Shazam music recognition'; Group = 'PkgGroupEntertainment'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'CyberLinkCorp.hs.CyberLinkMediaSuiteEssentials'; DisplayLabel = 'CyberLinkCorp.hs.CyberLinkMediaSuiteEssentials - CyberLink Media Suite Essentials'; Group = 'PkgGroupEntertainment'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'PandoraMediaInc.29680B314EFC2'; DisplayLabel = 'PandoraMediaInc.29680B314EFC2 - Pandora music streaming'; Group = 'PkgGroupEntertainment'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = '*SlingTV*'; DisplayLabel = '*SlingTV* - Sling TV streaming app'; Group = 'PkgGroupEntertainment'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Disney.37853FC22B2CE'; DisplayLabel = 'Disney.37853FC22B2CE - Disney+ streaming app'; Group = 'PkgGroupEntertainment'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }

        [PSCustomObject]@{ Name = 'FACEBOOK.FACEBOOK'; DisplayLabel = 'FACEBOOK.FACEBOOK - Facebook app'; Group = 'PkgGroupSocial'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Facebook.Instagram'; DisplayLabel = 'Facebook.Instagram - Instagram app'; Group = 'PkgGroupSocial'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = '9E2F88E3.Twitter'; DisplayLabel = '9E2F88E3.Twitter - Twitter / X app'; Group = 'PkgGroupSocial'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'BytedancePte.Ltd.TikTok'; DisplayLabel = 'BytedancePte.Ltd.TikTok - TikTok app'; Group = 'PkgGroupSocial'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'ViberMediaSARL.ViberPC'; DisplayLabel = 'ViberMediaSARL.ViberPC - Viber messenger'; Group = 'PkgGroupSocial'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Flipboard.Flipboard'; DisplayLabel = 'Flipboard.Flipboard - Flipboard news reader'; Group = 'PkgGroupSocial'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'XINGAG.XING'; DisplayLabel = 'XINGAG.XING - XING business network'; Group = 'PkgGroupSocial'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }

        [PSCustomObject]@{ Name = 'ActiproSoftwareLLC.562882FEEB491'; DisplayLabel = 'ActiproSoftwareLLC.562882FEEB491 - Actipro Code Writer'; Group = 'PkgGroupProductivity'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'AdobeSystemsIncorporated.AdobePhotoshopExpress'; DisplayLabel = 'AdobeSystemsIncorporated.AdobePhotoshopExpress - Adobe Photoshop Express'; Group = 'PkgGroupProductivity'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = '89006A2E.AutodeskSketchBook'; DisplayLabel = '89006A2E.AutodeskSketchBook - Autodesk SketchBook'; Group = 'PkgGroupProductivity'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Drawboard.DrawboardPDF'; DisplayLabel = 'Drawboard.DrawboardPDF - Drawboard PDF'; Group = 'PkgGroupProductivity'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = '*EclipseManager*'; DisplayLabel = '*EclipseManager* - Eclipse Manager (OEM bundle)'; Group = 'PkgGroupProductivity'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = '*OneCalendar*'; DisplayLabel = '*OneCalendar* - OneCalendar'; Group = 'PkgGroupProductivity'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'ThumbmunkeysLtd.PhototasticCollage'; DisplayLabel = 'ThumbmunkeysLtd.PhototasticCollage - Phototastic Collage'; Group = 'PkgGroupProductivity'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = '*PicsArt-PhotoStudio*'; DisplayLabel = '*PicsArt-PhotoStudio* - PicsArt Photo Studio'; Group = 'PkgGroupProductivity'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = '*PolarrPhotoEditorAcademicEdition*'; DisplayLabel = '*PolarrPhotoEditorAcademicEdition* - Polarr Photo Editor'; Group = 'PkgGroupProductivity'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'WinZipComputing.WinZipUniversal'; DisplayLabel = 'WinZipComputing.WinZipUniversal - WinZip Universal'; Group = 'PkgGroupProductivity'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'D5EA27B7.Duolingo-LearnLanguagesforFree'; DisplayLabel = 'D5EA27B7.Duolingo-LearnLanguagesforFree - Duolingo language learning'; Group = 'PkgGroupProductivity'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }

        [PSCustomObject]@{ Name = 'Amazon.com.Amazon'; DisplayLabel = 'Amazon.com.Amazon - Amazon Shopping'; Group = 'PkgGroupLifestyle'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Fitbit.FitbitCoach'; DisplayLabel = 'Fitbit.FitbitCoach - Fitbit Coach fitness app'; Group = 'PkgGroupLifestyle'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Sidia.LiveWallpaper'; DisplayLabel = 'Sidia.LiveWallpaper - Live wallpaper (OEM)'; Group = 'PkgGroupLifestyle'; Legacy = $false; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }

        [PSCustomObject]@{ Name = 'Microsoft.3DBuilder'; DisplayLabel = 'Microsoft.3DBuilder - 3D Builder (retired)'; Group = 'PkgGroupLegacy'; Legacy = $true; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.549981C3F5F10'; DisplayLabel = 'Microsoft.549981C3F5F10 - Cortana (retired)'; Group = 'PkgGroupLegacy'; Legacy = $true; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.Getstarted'; DisplayLabel = 'Microsoft.Getstarted - Tips (retired)'; Group = 'PkgGroupLegacy'; Legacy = $true; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.BingFinance'; DisplayLabel = 'Microsoft.BingFinance - Bing Finance (retired)'; Group = 'PkgGroupLegacy'; Legacy = $true; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.BingFoodAndDrink'; DisplayLabel = 'Microsoft.BingFoodAndDrink - Bing Food and Drink (retired)'; Group = 'PkgGroupLegacy'; Legacy = $true; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.BingHealthAndFitness'; DisplayLabel = 'Microsoft.BingHealthAndFitness - Bing Health and Fitness (retired)'; Group = 'PkgGroupLegacy'; Legacy = $true; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.BingSports'; DisplayLabel = 'Microsoft.BingSports - Bing Sports (retired)'; Group = 'PkgGroupLegacy'; Legacy = $true; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.BingTravel'; DisplayLabel = 'Microsoft.BingTravel - Bing Travel (retired)'; Group = 'PkgGroupLegacy'; Legacy = $true; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.Office.Sway'; DisplayLabel = 'Microsoft.Office.Sway - Sway (retired)'; Group = 'PkgGroupLegacy'; Legacy = $true; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.MicrosoftPowerBIForWindows'; DisplayLabel = 'Microsoft.MicrosoftPowerBIForWindows - Power BI for Windows (retired)'; Group = 'PkgGroupLegacy'; Legacy = $true; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.MSPaint'; DisplayLabel = 'Microsoft.MSPaint - Paint 3D (retired)'; Group = 'PkgGroupLegacy'; Legacy = $true; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.Microsoft3DViewer'; DisplayLabel = 'Microsoft.Microsoft3DViewer - 3D Viewer (retired)'; Group = 'PkgGroupLegacy'; Legacy = $true; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.Print3D'; DisplayLabel = 'Microsoft.Print3D - Print 3D (retired)'; Group = 'PkgGroupLegacy'; Legacy = $true; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.XboxApp'; DisplayLabel = 'Microsoft.XboxApp - Xbox Console Companion (retired)'; Group = 'PkgGroupLegacy'; Legacy = $true; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.Messaging'; DisplayLabel = 'Microsoft.Messaging - Messaging (retired)'; Group = 'PkgGroupLegacy'; Legacy = $true; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.People'; DisplayLabel = 'Microsoft.People - People (retired)'; Group = 'PkgGroupLegacy'; Legacy = $true; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.windowscommunicationsapps'; DisplayLabel = 'Microsoft.windowscommunicationsapps - Mail and Calendar (retired)'; Group = 'PkgGroupLegacy'; Legacy = $true; RemovalMethod = 'Appx'; Risk = 'CAUTION'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'MicrosoftTeams'; DisplayLabel = 'MicrosoftTeams - Teams Chat, personal (retired)'; Group = 'PkgGroupLegacy'; Legacy = $true; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.SkypeApp'; DisplayLabel = 'Microsoft.SkypeApp - Skype (retired)'; Group = 'PkgGroupLegacy'; Legacy = $true; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.RemoteDesktop'; DisplayLabel = 'Microsoft.RemoteDesktop - Remote Desktop Store app (retired)'; Group = 'PkgGroupLegacy'; Legacy = $true; RemovalMethod = 'Appx'; Risk = 'CAUTION'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.WindowsMaps'; DisplayLabel = 'Microsoft.WindowsMaps - Maps (retired)'; Group = 'PkgGroupLegacy'; Legacy = $true; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.MixedReality.Portal'; DisplayLabel = 'Microsoft.MixedReality.Portal - Mixed Reality Portal (retired)'; Group = 'PkgGroupLegacy'; Legacy = $true; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.NetworkSpeedTest'; DisplayLabel = 'Microsoft.NetworkSpeedTest - Network Speed Test (retired)'; Group = 'PkgGroupLegacy'; Legacy = $true; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.OneConnect'; DisplayLabel = 'Microsoft.OneConnect - Mobile Plans (retired)'; Group = 'PkgGroupLegacy'; Legacy = $true; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = '6Wunderkinder.Wunderlist'; DisplayLabel = '6Wunderkinder.Wunderlist - Wunderlist (service shut down)'; Group = 'PkgGroupLegacy'; Legacy = $true; RemovalMethod = 'Appx'; Risk = 'SAFE'; Consequence = $null; IsProvisioned = $false; Restorable = $false; VerifiedInCapture = $false }
        [PSCustomObject]@{ Name = 'Microsoft.Windows.DevHome'; DisplayLabel = 'Microsoft.Windows.DevHome - Dev Home (retired)'; Group = 'PkgGroupLegacy'; Legacy = $true; RemovalMethod = 'Appx'; Risk = 'ADVANCED'; Consequence = 'Dev Home and any dev-loop configuration it manages is removed'; IsProvisioned = $true; Restorable = $true; VerifiedInCapture = $true }
    ))
    $script:WtPackageCatalogCache[$lang] = $built
    return @($built | ForEach-Object { $_.PSObject.Copy() })
}

function ConvertTo-WtPackagePattern {
    <#
    .SYNOPSIS
        Get-AppxPackage -Name pattern for a catalog name: wrapped in
        wildcards unless the catalog already supplied one. Matching is
        then narrowed to an exact family-name prefix by the caller.
    #>
    param([Parameter(Mandatory)][string]$Name)
    if ($Name.Contains('*')) { return $Name }
    return ('*' + $Name + '*')
}

function Test-WtPackageNameMatches {
    <#
    .SYNOPSIS
        True when a live package name equals the catalog name (case-
        insensitive) or the catalog name is an explicit wildcard pattern
        it matches. '*Facebook*' must NOT swallow Facebook.Instagram.
    #>
    param([Parameter(Mandatory)][string]$CatalogName, [Parameter(Mandatory)][string]$LiveName)
    if ($CatalogName.Contains('*')) { return ($LiveName -like $CatalogName) }
    return ([string]::Equals($CatalogName, $LiveName, [System.StringComparison]::OrdinalIgnoreCase))
}

function Get-WtPackageState {
    <#
    .SYNOPSIS
        Live state of a catalog package: Installed or Removed. Defaults
        to Get-AppxPackage -AllUsers across every profile, since a
        package another account still has counts as installed;
        -AllUsers throws a TERMINATING access-denied error without
        elevation that -ErrorAction SilentlyContinue does not swallow,
        so an unelevated run falls back to the current user's own
        packages. -Name is a wildcard fragment, narrowed to an exact
        match by Test-WtPackageNameMatches; tests inject a fake list,
        since Get-AppxPackage does not exist on macOS.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleCommands', '',
        Justification = 'Import-Module -UseWindowsPowerShell only executes in the PS7+ branch, guarded by $PSVersionTable.PSVersion.Major -ge 6; PSScriptAnalyzer cannot see the runtime version guard. Get-AppxPackage -AllUsers is Windows-only by design and absent from the static PS 7.0 profile.')]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [scriptblock]$GetPackageAction = {
            if ($PSVersionTable.PSVersion.Major -ge 6) {
                Import-Module Appx -UseWindowsPowerShell -ErrorAction SilentlyContinue
            }
            $pattern = ConvertTo-WtPackagePattern -Name $Name
            try { Get-AppxPackage -Name $pattern -AllUsers -ErrorAction SilentlyContinue }
            catch { Get-AppxPackage -Name $pattern -ErrorAction SilentlyContinue }
        }
    )

    $pkg = @(& $GetPackageAction) | Where-Object { Test-WtPackageNameMatches -CatalogName $Name -LiveName $_.Name } | Select-Object -First 1

    if (-not $pkg) {
        return [PSCustomObject]@{ Name = $Name; Installed = $false }
    }

    return [PSCustomObject]@{ Name = $pkg.Name; Installed = $true }
}

function Get-WtPackageStatesFromSnapshot {
    <#
    .SYNOPSIS
        Live states for a whole catalog against ONE package snapshot,
        keyed by catalog Name, each in Get-WtPackageState's shape (Name
        being the LIVE package name when installed). Exact names go
        through one dictionary instead of a Where-Object pipeline per
        row - matching every row against every snapshot entry cost
        thousands of calls and over a second on every rebuild of the
        Apps screen. The first snapshot hit wins, as Select-Object
        -First 1 did. WinGet rows still ask Get-WtPackageLiveInstalled
        (a file check).
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Catalog,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Snapshot,
        [scriptblock]$TestPathAction
    )
    $firstByName = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $liveNames = New-Object System.Collections.Generic.List[string]
    foreach ($pkg in $Snapshot) {
        $live = [string]$pkg.Name
        if ($live -eq '') { continue }
        if (-not $firstByName.ContainsKey($live)) { $firstByName[$live] = $live }
        $liveNames.Add($live)
    }
    $pathArgs = @{}
    if ($TestPathAction) { $pathArgs['TestPathAction'] = $TestPathAction }
    $states = @{}
    foreach ($entry in $Catalog) {
        $catalogName = [string]$entry.Name
        if ([string]$entry.RemovalMethod -eq 'WinGet') {
            $states[$catalogName] = Get-WtPackageLiveInstalled -Entry $entry @pathArgs
            continue
        }
        $hit = $null
        if ($catalogName.Contains('*')) {
            foreach ($live in $liveNames) { if ($live -like $catalogName) { $hit = $live; break } }
        }
        elseif ($firstByName.ContainsKey($catalogName)) { $hit = $firstByName[$catalogName] }
        $states[$catalogName] = $(if ($null -eq $hit) { [PSCustomObject]@{ Name = $catalogName; Installed = $false } }
                                  else { [PSCustomObject]@{ Name = $hit; Installed = $true } })
    }
    return $states
}

function Get-WtInstalledPackageSnapshot {
    <#
    .SYNOPSIS
        Every Appx package on the machine, read ONCE, so building the
        Apps screen no longer costs one Get-AppxPackage -AllUsers call
        per catalog row; callers match rows against this snapshot in
        memory. -AllUsers throws a TERMINATING access-denied error
        without elevation that -ErrorAction SilentlyContinue does not
        swallow, so an unelevated run falls back to the current user's
        own packages.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleCommands', '',
        Justification = 'Import-Module -UseWindowsPowerShell only executes in the PS7+ branch, guarded by $PSVersionTable.PSVersion.Major -ge 6; PSScriptAnalyzer cannot see the runtime version guard. Get-AppxPackage -AllUsers is Windows-only by design and absent from the static PS 7.0 profile.')]
    param()
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        Import-Module Appx -UseWindowsPowerShell -ErrorAction SilentlyContinue
    }
    try { return @(Get-AppxPackage -AllUsers -ErrorAction Stop) }
    catch { return @(Get-AppxPackage -ErrorAction SilentlyContinue) }
}

function Get-WtPackageLiveInstalled {
    <#
    .SYNOPSIS
        Live "is this catalog entry present" for BOTH removal methods.
        Get-WtPackageState only understands Appx, so a WinGet row (like
        Microsoft.OneDrive, a per-user Win32 install Get-AppxPackage can
        never see) would otherwise read Removed forever - hidden,
        unselectable, and permanently "Applied" in an exported profile.
        This dispatches on RemovalMethod instead. -GetPackageAction is
        handed to Get-WtPackageState; pass a
        Get-WtInstalledPackageSnapshot result to probe many entries with
        one enumeration.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Entry,
        [scriptblock]$GetPackageAction,
        [scriptblock]$TestPathAction = { param($p) Test-Path -LiteralPath $p }
    )
    $entryName = [string]$Entry.Name
    if ([string]$Entry.RemovalMethod -eq 'WinGet') {
        $localAppData = [string]$env:LOCALAPPDATA
        $relative = 'Microsoft\OneDrive\OneDrive.exe'
        $onedrive = if ($localAppData) { Join-Path $localAppData $relative } else { $relative }
        return [PSCustomObject]@{ Name = $entryName; Installed = [bool](& $TestPathAction $onedrive) }
    }
    if ($GetPackageAction) { return Get-WtPackageState -Name $entryName -GetPackageAction $GetPackageAction }
    return Get-WtPackageState -Name $entryName
}
