#Requires -Modules Pester

<#
.SYNOPSIS
    Coverage for the service and package catalogs (risk tags,
    consequences, uniqueness) and their live-state lookups. Get-Service
    / Get-AppxPackage do not exist on macOS, so the state-lookup
    functions take an injectable enumeration action; tests supply a
    fake list.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath

    $script:ValidRisks = @('SAFE', 'CAUTION', 'ADVANCED')
}

Describe 'Get-WtServiceCatalog' {
    BeforeAll {
        $script:ServiceCatalog = Get-WtServiceCatalog
    }

    It 'has every entry with a non-empty name and a valid risk tag' {
        foreach ($entry in $ServiceCatalog) {
            $entry.Name | Should -Not -BeNullOrEmpty
            $entry.Risk | Should -BeIn $ValidRisks
        }
    }

    It 'has unique service names' {
        $names = $ServiceCatalog | Select-Object -ExpandProperty Name
        ($names | Select-Object -Unique).Count | Should -Be $names.Count
    }

    It 'contains no literal per-user LUID suffix' {
        foreach ($entry in $ServiceCatalog) {
            $entry.Name | Should -Not -Match '_[0-9a-fA-F]+$'
        }
    }

    It 'gives every CAUTION and ADVANCED entry a non-empty consequence' {
        $risky = $ServiceCatalog | Where-Object { $_.Risk -in @('CAUTION', 'ADVANCED') }
        $risky.Count | Should -BeGreaterThan 0
        foreach ($entry in $risky) {
            $entry.Consequence | Should -Not -BeNullOrEmpty
        }
    }

    It 'carries the 43 Windows services (Google updater services gupdate/gupdatem are not Windows services and were dropped)' {
        $names = @((Get-WtServiceCatalog) | ForEach-Object Name)
        $names.Count | Should -Be 43
        $names | Should -Not -Contain 'gupdate'
        $names | Should -Not -Contain 'gupdatem'
        foreach ($n in 'DiagTrack', 'SysMain', 'WSearch', 'Spooler', 'BcastDVRUserService', 'SEMgrSvc') { $names | Should -Contain $n }
    }
    It 'applies the spec risk corrections' {
        $cat = Get-WtServiceCatalog
        foreach ($n in 'SysMain', 'WSearch', 'FontCache', 'BDESVC', 'DoSvc', 'WbioSrvc') { ($cat | Where-Object Name -eq $n).Risk | Should -Be 'ADVANCED' -Because $n }
        foreach ($n in 'Spooler', 'SharedAccess', 'dmwappushservice', 'stisvc', 'WPDBusEnum', 'MSDTC', 'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc', 'CaptureService') { ($cat | Where-Object Name -eq $n).Risk | Should -Be 'CAUTION' -Because $n }
    }
    It 'every service carries a "<Name> - <description>" label in both languages' {
        foreach ($e in (Get-WtServiceCatalog)) {
            $e.DisplayLabel | Should -Match ('^' + [regex]::Escape($e.Name) + ' - .+')
            $key = 'CatService' + ($e.Name -creplace '[^A-Za-z0-9]', '') + 'Label'
            $script:Translations['EN'].ContainsKey($key) | Should -BeTrue -Because "EN needs '$key'"
            $script:Translations['TR'].ContainsKey($key) | Should -BeTrue -Because "TR needs '$key'"
        }
    }

    It 'marks BcastDVRUserService, CaptureService, and PenService as per-user templates' {
        foreach ($template in @('BcastDVRUserService', 'CaptureService', 'PenService')) {
            $entry = $ServiceCatalog | Where-Object Name -eq $template
            $entry | Should -Not -BeNullOrEmpty
            $entry.IsPerUser | Should -BeTrue
        }
    }
}

Describe 'Get-WtServiceState' {
    It 'resolves a per-user template by prefix, matching a simulated instance with a different suffix' {
        $fakeServices = @(
            [PSCustomObject]@{ Name = 'BcastDVRUserService_9f9f9f9'; Status = 'Running'; StartType = 'Automatic' }
        )
        $state = Get-WtServiceState -Name 'BcastDVRUserService' -IsPerUser $true -GetServiceAction { $fakeServices }
        $state.Present | Should -BeTrue
        $state.Name | Should -Be 'BcastDVRUserService_9f9f9f9'
        $state.Status | Should -Be 'Running'
    }

    It 'reports Present=$false for a per-user template with no matching instance, without throwing' {
        $state = Get-WtServiceState -Name 'BcastDVRUserService' -IsPerUser $true -GetServiceAction { @() }
        $state.Present | Should -BeFalse
        $state.Status | Should -BeNullOrEmpty
    }

    It 'reports Present=$false for a non-per-user service absent from the machine' {
        $state = Get-WtServiceState -Name 'DiagTrack' -GetServiceAction { @() }
        $state.Present | Should -BeFalse
    }

    It 'resolves a present non-per-user service by exact name' {
        $fakeServices = @([PSCustomObject]@{ Name = 'DiagTrack'; Status = 'Stopped'; StartType = 'Disabled' })
        $state = Get-WtServiceState -Name 'DiagTrack' -GetServiceAction { $fakeServices }
        $state.Present | Should -BeTrue
        $state.Status | Should -Be 'Stopped'
        $state.StartType | Should -Be 'Disabled'
    }
}

Describe 'Get-WtPackageCatalog' {
    BeforeAll {
        $script:PackageCatalog = Get-WtPackageCatalog
        $script:CapturePath = Join-Path $RepoRoot 'tests/fixtures/appx-capture.json'
    }

    It 'has every entry with a non-empty name, a valid risk tag, and explicit Restorable/IsProvisioned booleans' {
        foreach ($entry in $PackageCatalog) {
            $entry.Name | Should -Not -BeNullOrEmpty
            $entry.Risk | Should -BeIn $ValidRisks
            $entry.Restorable | Should -BeOfType [bool]
            $entry.IsProvisioned | Should -BeOfType [bool]
        }
    }

    It 'has unique package names' {
        $names = $PackageCatalog | Select-Object -ExpandProperty Name
        ($names | Select-Object -Unique).Count | Should -Be $names.Count
    }

    It 'tags Microsoft.WindowsStore as ADVANCED' {
        $entry = $PackageCatalog | Where-Object Name -eq 'Microsoft.WindowsStore'
        $entry | Should -Not -BeNullOrEmpty
        $entry.Risk | Should -Be 'ADVANCED'
    }

    It 'gives every ADVANCED entry a non-empty consequence' {
        $advanced = $PackageCatalog | Where-Object Risk -eq 'ADVANCED'
        $advanced.Count | Should -BeGreaterThan 0
        foreach ($entry in $advanced) {
            $entry.Consequence | Should -Not -BeNullOrEmpty
        }
    }

    It 'has the TS-005 capture fixture available and every entry''s VerifiedInCapture flag matches presence in it' {
        Test-Path -LiteralPath $CapturePath | Should -BeTrue
        $capture = Get-Content -LiteralPath $CapturePath -Raw | ConvertFrom-Json
        $provisionedSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($capture.provisioned), [System.StringComparer]::OrdinalIgnoreCase)

        foreach ($entry in $PackageCatalog) {
            if ($entry.VerifiedInCapture) {
                $provisionedSet.Contains($entry.Name) | Should -BeTrue -Because "entry '$($entry.Name)' claims VerifiedInCapture but is not in the capture's provisioned list"
            }
        }
    }

    It 'marks every unverified entry Restorable=$false rather than silently dropping it' {
        $unverified = $PackageCatalog | Where-Object { -not $_.VerifiedInCapture }
        $unverified.Count | Should -BeGreaterThan 0
        foreach ($entry in $unverified) {
            $entry.Restorable | Should -BeFalse
        }
    }

    It 'still carries every V1 Microsoft package name plus the capture-confirmed Microsoft.SecHealthUI addition' {
        $names = @($PackageCatalog | ForEach-Object Name)
        $v1Microsoft = @(
            'Clipchamp.Clipchamp', 'Microsoft.3DBuilder', 'Microsoft.549981C3F5F10', 'Microsoft.GetHelp',
            'Microsoft.Getstarted', 'Microsoft.WindowsStore', 'Microsoft.WindowsTerminal', 'Microsoft.Windows.DevHome',
            'Microsoft.BingSearch', 'Microsoft.BingFinance', 'Microsoft.BingFoodAndDrink', 'Microsoft.BingHealthAndFitness',
            'Microsoft.BingNews', 'Microsoft.BingSports', 'Microsoft.BingTranslator', 'Microsoft.BingTravel',
            'Microsoft.BingWeather', 'Microsoft.MicrosoftOfficeHub', 'Microsoft.Office.OneNote', 'Microsoft.Office.Sway',
            'Microsoft.Todos', 'Microsoft.MicrosoftStickyNotes', 'Microsoft.OutlookForWindows', 'Microsoft.PowerAutomateDesktop',
            'Microsoft.MicrosoftPowerBIForWindows', 'Microsoft.MSPaint', 'Microsoft.Paint', 'Microsoft.ScreenSketch',
            'Microsoft.Whiteboard', 'Microsoft.Windows.Photos', 'Microsoft.WindowsCamera', 'Microsoft.Microsoft3DViewer',
            'Microsoft.Print3D', 'Microsoft.MicrosoftJournal', 'Microsoft.XboxApp', 'Microsoft.Xbox.TCUI',
            'Microsoft.XboxGameOverlay', 'Microsoft.XboxGamingOverlay', 'Microsoft.XboxIdentityProvider',
            'Microsoft.XboxSpeechToTextOverlay', 'Microsoft.GamingApp', 'Microsoft.MicrosoftSolitaireCollection',
            'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo', 'Microsoft.YourPhone', 'Microsoft.Messaging', 'Microsoft.People',
            'Microsoft.windowscommunicationsapps', 'MicrosoftTeams', 'MSTeams', 'Microsoft.SkypeApp',
            'Microsoft.RemoteDesktop', 'MicrosoftWindows.CrossDevice', 'Microsoft.WindowsAlarms',
            'Microsoft.WindowsCalculator', 'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsMaps',
            'Microsoft.WindowsNotepad', 'Microsoft.WindowsSoundRecorder', 'Microsoft.MixedReality.Portal',
            'Microsoft.NetworkSpeedTest', 'Microsoft.OneConnect', 'MicrosoftCorporationII.QuickAssist',
            'Microsoft.Copilot', 'Microsoft.OneDrive', 'Microsoft.SecHealthUI',
            'king.com.BubbleWitch3Saga', 'king.com.CandyCrushSaga', 'king.com.CandyCrushSodaSaga',
            'HULULLC.HULUPLUS', 'AmazonVideo.PrimeVideo', 'AdobeSystemsIncorporated.AdobePhotoshopExpress',
            'Amazon.com.Amazon', 'Sidia.LiveWallpaper'
        )
        foreach ($n in $v1Microsoft) { $names | Should -Contain $n -Because "V1 name '$n' is a frozen undo/profile key" }
    }
}

Describe 'Get-WtPackageState' {
    It 'reports Removed for a package absent from the machine, without throwing' {
        $state = Get-WtPackageState -Name 'Contoso.NotInstalled' -GetPackageAction { @() }
        $state.Installed | Should -BeFalse
    }

    It 'reports Installed for a package present on the machine' {
        $fakePackages = @([PSCustomObject]@{ Name = 'Microsoft.BingWeather' })
        $state = Get-WtPackageState -Name 'Microsoft.BingWeather' -GetPackageAction { $fakePackages }
        $state.Installed | Should -BeTrue
    }
}

Describe 'Per-user service template Start value' {
    It 'reads the template Start value or null' {
        Get-WtServiceTemplateStart -Template 'CaptureService' -GetValue { param($p) 3 } | Should -Be 3
        Get-WtServiceTemplateStart -Template 'CaptureService' -GetValue { param($p) $null } | Should -BeNullOrEmpty
    }
    It 'writes the Start value to the template key under CurrentControlSet\Services' {
        $script:written = $null
        Set-WtServiceTemplateStart -Template 'CaptureService' -Start 4 -SetValue { param($p, $v) $script:written = @{ Path = $p; Value = $v } }
        $script:written.Path | Should -Be 'HKLM:\SYSTEM\CurrentControlSet\Services\CaptureService'
        $script:written.Value | Should -Be 4
    }
}

Describe 'Get-WtPackageCatalog (V2)' {
    BeforeAll { $script:pkgs = @(Get-WtPackageCatalog) }
    It 'has no partial or space-containing names' {
        foreach ($bad in 'Royal Revolt', 'Netflix', 'Spotify', 'Facebook', 'Instagram', 'Twitter', 'Disney', 'fitbit', 'Plex', 'TikTok', 'LinkedInforWindows', 'Asphalt8Airborne', 'Viber', 'Flipboard') {
            @($pkgs | ForEach-Object Name) | Should -Not -Contain $bad
        }
        foreach ($n in $pkgs | ForEach-Object Name) { $n | Should -Not -Match '\s' }
    }
    It 'carries the real package family prefixes for former partial names' {
        foreach ($good in 'flaregamesGmbH.RoyalRevolt', '4DF9E0F8.Netflix', 'SpotifyAB.SpotifyMusic', 'FACEBOOK.FACEBOOK', 'Facebook.Instagram', '9E2F88E3.Twitter', 'Disney.37853FC22B2CE', 'BytedancePte.Ltd.TikTok', '7EE7776C.LinkedInforWindows') {
            @($pkgs | ForEach-Object Name) | Should -Contain $good
        }
    }
    It 'adds the 2024+ inbox and AI packages' {
        foreach ($n in 'Microsoft.Copilot', 'Microsoft.BingSearch', 'MicrosoftWindows.Client.WebExperience', 'Microsoft.WidgetsPlatformRuntime', 'MicrosoftWindows.CrossDevice', 'Microsoft.OutlookForWindows', 'MSTeams', 'Microsoft.Edge.GameAssist', 'MicrosoftCorporationII.MicrosoftFamily', 'Microsoft.PCManager', 'Microsoft.Windows.AIHub', 'Microsoft.StartExperiencesApp') {
            @($pkgs | ForEach-Object Name) | Should -Contain $n
        }
    }
    It 'flags dangerous packages ADVANCED with a consequence' {
        foreach ($n in 'Microsoft.WindowsStore', 'Microsoft.WindowsTerminal', 'Microsoft.WindowsCalculator', 'Microsoft.WindowsNotepad', 'Microsoft.Windows.Photos', 'Microsoft.ScreenSketch', 'Microsoft.Paint', 'Microsoft.Xbox.TCUI', 'Microsoft.XboxIdentityProvider', 'Microsoft.XboxSpeechToTextOverlay', 'Microsoft.GetHelp', 'Microsoft.ZuneMusic', 'Microsoft.OneDrive') {
            $e = $pkgs | Where-Object Name -eq $n
            $e.Risk | Should -Be 'ADVANCED' -Because $n
            $e.Consequence | Should -Not -BeNullOrEmpty -Because $n
        }
    }
    It 'marks retired packages Legacy and every entry has a Group, DisplayLabel and RemovalMethod' {
        foreach ($n in 'Microsoft.549981C3F5F10', 'Microsoft.SkypeApp', 'Microsoft.Windows.DevHome', 'Microsoft.WindowsMaps', 'Microsoft.MixedReality.Portal', 'Microsoft.People', 'Microsoft.windowscommunicationsapps', 'Microsoft.Print3D') {
            ($pkgs | Where-Object Name -eq $n).Legacy | Should -BeTrue -Because $n
        }
        foreach ($e in $pkgs) {
            $e.Group | Should -Match '^PkgGroup'
            $e.DisplayLabel | Should -Match ('^' + [regex]::Escape($e.Name) + ' - .+')
            @('Appx', 'WinGet') | Should -Contain $e.RemovalMethod
        }
        ($pkgs | Where-Object Name -eq 'Microsoft.OneDrive').RemovalMethod | Should -Be 'WinGet'
    }
    It 'stores every non-dotted fragment name as an explicit wildcard pattern' {
        foreach ($e in $pkgs | Where-Object { $_.Name -notmatch '\.' -and $_.Name -ne 'MSTeams' -and $_.Name -ne 'MicrosoftTeams' }) {
            $e.Name | Should -Match '\*' -Because $e.Name
        }
        Test-WtPackageNameMatches -CatalogName '*EclipseManager*' -LiveName '46928bounde.EclipseManager' | Should -BeTrue
        Test-WtPackageNameMatches -CatalogName '*SlingTV*' -LiveName 'SlingTVLLC.SlingTV' | Should -BeTrue
        Test-WtPackageNameMatches -CatalogName '*PicsArt-PhotoStudio*' -LiveName 'PicsArt.PicsArt-PhotoStudio' | Should -BeTrue
    }
    It 'has unique names and >= 120 entries' {
        @($pkgs | ForEach-Object Name | Sort-Object -Unique).Count | Should -Be $pkgs.Count
        $pkgs.Count | Should -BeGreaterOrEqual 120
    }
    It 'every group header key and label key exist in both languages' {
        foreach ($g in ($pkgs | ForEach-Object Group | Sort-Object -Unique)) {
            $script:Translations['EN'].ContainsKey($g) | Should -BeTrue -Because "EN needs '$g'"
            $script:Translations['TR'].ContainsKey($g) | Should -BeTrue -Because "TR needs '$g'"
        }
        foreach ($e in $pkgs) {
            $key = 'CatPackage' + ($e.Name -creplace '[^A-Za-z0-9]', '') + 'Label'
            $script:Translations['EN'].ContainsKey($key) | Should -BeTrue -Because "EN needs '$key'"
            $script:Translations['TR'].ContainsKey($key) | Should -BeTrue -Because "TR needs '$key'"
        }
    }
}

Describe 'ConvertTo-WtPackagePattern' {
    It 'wraps a bare name in wildcards and leaves explicit patterns alone' {
        ConvertTo-WtPackagePattern -Name 'Microsoft.BingWeather' | Should -Be '*Microsoft.BingWeather*'
        ConvertTo-WtPackagePattern -Name 'Microsoft.Copilot*' | Should -Be 'Microsoft.Copilot*'
    }
}

Describe 'Get-WtPackageLiveInstalled' {
    BeforeAll {
        $script:oneDrive = @(Get-WtPackageCatalog) | Where-Object Name -eq 'Microsoft.OneDrive'
        $script:weather = @(Get-WtPackageCatalog) | Where-Object Name -eq 'Microsoft.BingWeather'
    }
    It 'probes a WinGet row through the filesystem, which no Appx lookup can see' {
        $oneDrive.RemovalMethod | Should -Be 'WinGet'
        (Get-WtPackageLiveInstalled -Entry $oneDrive -GetPackageAction { @() } -TestPathAction { param($p) $true }).Installed | Should -BeTrue
        (Get-WtPackageLiveInstalled -Entry $oneDrive -GetPackageAction { @() } -TestPathAction { param($p) $false }).Installed | Should -BeFalse
    }
    It 'probes the per-user OneDrive.exe path' {
        $script:probedPath = $null
        $null = Get-WtPackageLiveInstalled -Entry $oneDrive -TestPathAction { param($p) $script:probedPath = $p; $false }
        $script:probedPath | Should -BeLike '*Microsoft?OneDrive?OneDrive.exe'
    }
    It 'falls through to the Appx lookup for an Appx row' {
        $fake = { @([PSCustomObject]@{ Name = 'Microsoft.BingWeather'; PackageFullName = 'Microsoft.BingWeather_1_x64__8wekyb3d8bbwe' }) }
        (Get-WtPackageLiveInstalled -Entry $weather -GetPackageAction $fake).Installed | Should -BeTrue
        (Get-WtPackageLiveInstalled -Entry $weather -GetPackageAction { @() }).Installed | Should -BeFalse
        (Get-WtPackageLiveInstalled -Entry $weather -GetPackageAction { @() } -TestPathAction { param($p) $true }).Installed | Should -BeFalse
    }
}

Describe 'Get-WtPackageState (wildcard, all users)' {
    It 'reports Installed when any user has a package matching the pattern' {
        $fake = { @([PSCustomObject]@{ Name = 'Microsoft.BingWeather'; PackageFullName = 'Microsoft.BingWeather_4.53_x64__8wekyb3d8bbwe' }) }
        (Get-WtPackageState -Name 'Microsoft.BingWeather' -GetPackageAction $fake).Installed | Should -BeTrue
        (Get-WtPackageState -Name 'Microsoft.BingNews' -GetPackageAction { @() }).Installed | Should -BeFalse
    }
    It 'does not let *Facebook* swallow Facebook.Instagram (exact family prefix match)' {
        $fake = { @([PSCustomObject]@{ Name = 'Facebook.Instagram'; PackageFullName = 'Facebook.Instagram_1_x64__abc' }) }
        (Get-WtPackageState -Name 'FACEBOOK.FACEBOOK' -GetPackageAction $fake).Installed | Should -BeFalse
    }
}

Describe 'Catalogs remembered per language and handed out as copies' {
    It 'Get-WtServiceCatalog: the second call is a copy of the first, not the same objects, and a language switch rebuilds' {
        $old = $script:Language
        try {
            $script:WtServiceCatalogCache = @{}
            $script:Language = 'EN'
            $a = @(Get-WtServiceCatalog)
            $b = @(Get-WtServiceCatalog)
            $a.Count | Should -Be 43
            $b.Count | Should -Be 43
            [object]::ReferenceEquals($a[0], $b[0]) | Should -BeFalse
            $b[0].DisplayLabel | Should -Be $a[0].DisplayLabel
            $script:WtServiceCatalogCache.ContainsKey('EN') | Should -BeTrue
            $b[0] | Add-Member -NotePropertyName 'CycleTargets' -NotePropertyValue @('x') -Force
            (@(Get-WtServiceCatalog)[0].PSObject.Properties.Name) | Should -Not -Contain 'CycleTargets'
            $script:Language = 'TR'
            @(Get-WtServiceCatalog) | Out-Null
            $script:WtServiceCatalogCache.ContainsKey('TR') | Should -BeTrue
        }
        finally { $script:Language = $old; $script:WtServiceCatalogCache = @{} }
    }
    It 'Get-WtPackageCatalog: the same contract' {
        $old = $script:Language
        try {
            $script:WtPackageCatalogCache = @{}
            $script:Language = 'EN'
            $a = @(Get-WtPackageCatalog)
            $b = @(Get-WtPackageCatalog)
            $a.Count | Should -BeGreaterOrEqual 120
            [object]::ReferenceEquals($a[0], $b[0]) | Should -BeFalse
            $b[0].DisplayLabel | Should -Be $a[0].DisplayLabel
            $b[0] | Add-Member -NotePropertyName 'PendingVerbKey' -NotePropertyValue 'x' -Force
            (@(Get-WtPackageCatalog)[0].PSObject.Properties.Name) | Should -Not -Contain 'PendingVerbKey'
            $script:WtPackageCatalogCache.ContainsKey('EN') | Should -BeTrue
        }
        finally { $script:Language = $old; $script:WtPackageCatalogCache = @{} }
    }
}
