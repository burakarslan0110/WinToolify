BeforeAll {
    . (Join-Path (Join-Path $PSScriptRoot '..') 'dist/WinToolify.ps1')
}

Describe 'ConvertFrom-WtWifiProfileXml' {
    It 'extracts name and key from an exported profile' {
        $xml = [xml]@'
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>HomeNet</name>
  <MSM><security>
    <authEncryption><authentication>WPA2PSK</authentication></authEncryption>
    <sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>s3cret-pw</keyMaterial></sharedKey>
  </security></MSM>
</WLANProfile>
'@
        $r = ConvertFrom-WtWifiProfileXml -ProfileXml $xml
        $r.Name | Should -Be 'HomeNet'
        $r.Key | Should -Be 's3cret-pw'
        $r.Authentication | Should -Be 'WPA2PSK'
    }
    It 'returns null key for an open network' {
        $xml = [xml]@'
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>CafeOpen</name>
  <MSM><security>
    <authEncryption><authentication>open</authentication></authEncryption>
  </security></MSM>
</WLANProfile>
'@
        (ConvertFrom-WtWifiProfileXml -ProfileXml $xml).Key | Should -BeNullOrEmpty
    }
}

Describe 'Get-WtWifiProfileKey' {
    It 'parses the exported file via the injected export action and removes the clear-text export' {
        $script:exportFolder = $null
        $fakeExport = {
            param($Name, $Folder)
            $script:exportFolder = $Folder
            $content = @'
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>HomeNet</name>
  <MSM><security>
    <authEncryption><authentication>WPA2PSK</authentication></authEncryption>
    <sharedKey><keyMaterial>pw-123</keyMaterial></sharedKey>
  </security></MSM>
</WLANProfile>
'@
            Set-Content -Path (Join-Path $Folder 'Wi-Fi-HomeNet.xml') -Value $content -Encoding UTF8
        }
        $r = Get-WtWifiProfileKey -ProfileName 'HomeNet' -ExportAction $fakeExport
        $r.Found | Should -BeTrue
        $r.Key | Should -Be 'pw-123'
        Test-Path $script:exportFolder | Should -BeFalse
    }
    It 'reports not found when the export produced nothing' {
        $r = Get-WtWifiProfileKey -ProfileName 'Nope' -ExportAction { param($Name, $Folder) }
        $r.Found | Should -BeFalse
        $r.Key | Should -BeNullOrEmpty
    }
}

Describe 'Get-WtLicenseInfoLines' {
    It 'labels and combines the two slmgr outputs via the injected action' {
        $fake = { param($Switch) if ($Switch -eq '/xpr') { @('Volume activation will expire 1.1.2030') } else { @('Name: Windows(R)', 'License Status: Licensed') } }
        $lines = Get-WtLicenseInfoLines -RunSlmgrAction $fake
        ($lines -join "`n") | Should -Match 'expire'
        ($lines -join "`n") | Should -Match 'License Status'
    }
    It 'queries /xpr then /dlv' {
        $script:switches = New-Object 'System.Collections.Generic.List[string]'
        $null = Get-WtLicenseInfoLines -RunSlmgrAction { param($Switch) $script:switches.Add($Switch); @() }
        @($script:switches) | Should -Be @('/xpr', '/dlv')
    }
}

Describe 'source-level defect guards' {
    BeforeAll { $script:src = Get-Content -Raw (Join-Path (Join-Path $PSScriptRoot '..') 'dist/WinToolify.ps1') }
    It 'undo menu wraps Get-WtUndoEntries in @() (PS 5.1 single-entry bug)' {
        $src | Should -Match '\$entries\s*=\s*@\(Get-WtUndoEntries'
    }
    It 'no startup winget check before the main loop' {
        $src | Should -Not -Match '(?m)^\s*Test-WingetInstalled\s*$'
    }
    It 'finally-kill is gated on the spawned-console marker' {
        $src | Should -Match 'WINTOOLIFY_SPAWNED'
    }
    It 'no Turkish literal remains in the window-size or RAM output paths' {
        $src | Should -Not -Match 'Write-Host "Pencere boyutu'
        $src | Should -Not -Match 'Write-Host "\$freeRAM MB RAM'
        'Write-Host "$freeRAM MB RAM bos durumda."' | Should -Match 'Write-Host "\$freeRAM MB RAM'
    }
    It 'has WindowSizeFailed and RamUsageLine keys in both languages' {
        foreach ($key in 'WindowSizeFailed', 'RamUsageLine') {
            $script:Translations['EN'].ContainsKey($key) | Should -BeTrue
            $script:Translations['TR'].ContainsKey($key) | Should -BeTrue
        }
        $script:Translations['EN']['RamUsageLine'] | Should -Match '\{0\}'
    }
}
