#Requires -Modules Pester

<#
.SYNOPSIS
    Get-WtRegistryValue / Set-WtRegistryValue / Remove-WtRegistryValue.
    The Registry PSProvider does not exist outside Windows, so every
    primitive here takes an injectable action and nothing in this file
    exercises a real registry operation.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'Get-WtRegistryValue' {
    It 'calls the injected GetPropertyAction with the exact Path and Name' {
        $seen = @{}
        $action = {
            param($p, $n)
            $seen.Path = $p
            $seen.Name = $n
            [PSCustomObject]@{ X = 1 }
        }.GetNewClosure()

        Get-WtRegistryValue -Path 'HKLM:\SOFTWARE\Test' -Name 'X' -GetPropertyAction $action | Out-Null

        $seen.Path | Should -Be 'HKLM:\SOFTWARE\Test'
        $seen.Name | Should -Be 'X'
    }

    It 'reports Present=$true and the value when the returned object has the named property' {
        $action = { param($p, $n) [PSCustomObject]@{ X = 42 } }
        $result = Get-WtRegistryValue -Path 'HKLM:\SOFTWARE\Test' -Name 'X' -GetPropertyAction $action
        $result.Present | Should -BeTrue
        $result.Value | Should -Be 42
    }

    It 'reports Present=$false without throwing when the injected action returns $null' {
        $action = { param($p, $n) $null }
        { Get-WtRegistryValue -Path 'HKLM:\SOFTWARE\Test' -Name 'X' -GetPropertyAction $action } | Should -Not -Throw
        (Get-WtRegistryValue -Path 'HKLM:\SOFTWARE\Test' -Name 'X' -GetPropertyAction $action).Present | Should -BeFalse
    }

    It 'reports Present=$false when the returned object exists but lacks the named property' {
        $action = { param($p, $n) [PSCustomObject]@{ SomeOtherName = 1 } }
        (Get-WtRegistryValue -Path 'HKLM:\SOFTWARE\Test' -Name 'X' -GetPropertyAction $action).Present | Should -BeFalse
    }
}

Describe 'Set-WtRegistryValue' {
    It 'calls the injected SetValueAction with Path, Name, RegType, and Value - no real registry cmdlet' {
        $seen = @{}
        $action = {
            param($p, $n, $t, $v)
            $seen.Path = $p; $seen.Name = $n; $seen.RegType = $t; $seen.Value = $v
        }.GetNewClosure()

        Set-WtRegistryValue -Path 'HKLM:\SOFTWARE\Test' -Name 'X' -RegType 'DWord' -Value 1 -SetValueAction $action

        $seen.Path | Should -Be 'HKLM:\SOFTWARE\Test'
        $seen.Name | Should -Be 'X'
        $seen.RegType | Should -Be 'DWord'
        $seen.Value | Should -Be 1
    }
}

Describe 'Remove-WtRegistryValue' {
    It 'calls the injected RemoveValueAction with the exact Path and Name' {
        $seen = @{}
        $action = {
            param($p, $n)
            $seen.Path = $p; $seen.Name = $n
        }.GetNewClosure()

        Remove-WtRegistryValue -Path 'HKLM:\SOFTWARE\Test' -Name 'X' -RemoveValueAction $action

        $seen.Path | Should -Be 'HKLM:\SOFTWARE\Test'
        $seen.Name | Should -Be 'X'
    }
}

Describe 'Get-WtRegistryProperty - the .NET read behind every default' {
    <#
    .SYNOPSIS
        $script:hasRegistry is set twice on purpose: once here at discovery
        time so -Skip can see it, and again inside BeforeAll, since Pester
        runs discovery separately from execution and a variable the
        Describe body sets at discovery is not visible at run time.
    #>
    $script:hasRegistry = [bool](Get-PSDrive -Name HKCU -ErrorAction SilentlyContinue)
    BeforeAll {
        $script:regTestKey = $null
        $script:hasRegistry = [bool](Get-PSDrive -Name HKCU -ErrorAction SilentlyContinue)
        if ($script:hasRegistry) {
            $script:regTestKey = 'HKCU:\Software\WinToolifyTests\' + [guid]::NewGuid().ToString('N')
            New-Item -Path $script:regTestKey -Force | Out-Null
            New-ItemProperty -Path $script:regTestKey -Name 'Dword' -Value 7 -PropertyType DWord | Out-Null
            New-ItemProperty -Path $script:regTestKey -Name 'Qword' -Value 5000000000 -PropertyType QWord | Out-Null
            New-ItemProperty -Path $script:regTestKey -Name 'Str' -Value 'abc' -PropertyType String | Out-Null
            New-ItemProperty -Path $script:regTestKey -Name 'Expand' -Value '%SystemRoot%\x' -PropertyType ExpandString | Out-Null
            New-ItemProperty -Path $script:regTestKey -Name 'Multi' -Value @('a', 'b') -PropertyType MultiString | Out-Null
            New-ItemProperty -Path $script:regTestKey -Name 'Bin' -Value ([byte[]](1, 2, 3)) -PropertyType Binary | Out-Null
            New-ItemProperty -Path $script:regTestKey -Name 'Empty' -Value '' -PropertyType String | Out-Null
        }
    }
    AfterAll {
        if ($script:regTestKey) { Remove-Item -Path $script:regTestKey -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'ConvertTo-WtRegistryHivePath maps the provider spellings and refuses anything else' {
        $s = ConvertTo-WtRegistryHivePath -Path 'HKLM:\SOFTWARE\Policies\X'
        $s.Hive.Name | Should -Be 'HKEY_LOCAL_MACHINE'
        $s.SubKey | Should -Be 'SOFTWARE\Policies\X'
        (ConvertTo-WtRegistryHivePath -Path 'Registry::HKEY_CURRENT_USER\Software\Y\').Hive.Name | Should -Be 'HKEY_CURRENT_USER'
        (ConvertTo-WtRegistryHivePath -Path 'Registry::HKEY_CURRENT_USER\Software\Y\').SubKey | Should -Be 'Software\Y'
        (ConvertTo-WtRegistryHivePath -Path 'HKCU:').SubKey | Should -Be ''
        (ConvertTo-WtRegistryHivePath -Path 'hkcr:\.txt').Hive.Name | Should -Be 'HKEY_CLASSES_ROOT'
        ConvertTo-WtRegistryHivePath -Path 'Foo:\Bar' | Should -BeNullOrEmpty
        ConvertTo-WtRegistryHivePath -Path 'C:\Windows' | Should -BeNullOrEmpty
    }
    It 'returns exactly what Get-ItemProperty returns, value and type, for every value kind' -Skip:(-not $script:hasRegistry) {
        foreach ($n in 'Dword', 'Qword', 'Str', 'Expand', 'Multi', 'Bin', 'Empty') {
            $fast = Get-WtRegistryProperty -Path $script:regTestKey -Name $n
            $slow = Get-ItemProperty -LiteralPath $script:regTestKey -Name $n
            $fast.PSObject.Properties.Name | Should -Contain $n
            @($fast.$n) | Should -Be @($slow.$n) -Because $n
            ($fast.$n).GetType().FullName | Should -Be ($slow.$n).GetType().FullName -Because $n
        }
    }
    It 'a missing value, a missing key and a hive-less path all come back $null, never a throw' -Skip:(-not $script:hasRegistry) {
        Get-WtRegistryProperty -Path $script:regTestKey -Name 'Nope' | Should -BeNullOrEmpty
        Get-WtRegistryProperty -Path ($script:regTestKey + '\Nope') -Name 'Dword' | Should -BeNullOrEmpty
        Get-WtRegistryProperty -Path 'Foo:\Bar' -Name 'X' | Should -BeNullOrEmpty
    }
    It 'Get-WtRegistryValue reads through it by default, Registry:: spelling included' -Skip:(-not $script:hasRegistry) {
        (Get-WtRegistryValue -Path $script:regTestKey -Name 'Dword').Value | Should -Be 7
        (Get-WtRegistryValue -Path ('Registry::HKEY_CURRENT_USER' + $script:regTestKey.Substring(5)) -Name 'Str').Value | Should -Be 'abc'
        (Get-WtRegistryValue -Path ($script:regTestKey + '\Nope') -Name 'X').Present | Should -BeFalse
    }
    It 'is the read every GetPropertyAction default in the script goes through' {
        $src = Get-Content -LiteralPath $script:TargetPath -Raw
        ([regex]::Matches($src, 'GetPropertyAction = \{\s*param\(\$p, \$n\)\s*Get-ItemProperty')).Count | Should -Be 0
        ([regex]::Matches($src, 'GetPropertyAction = \{\s*param\(\$p, \$n\)\s*Get-WtRegistryProperty -Path \$p -Name \$n')).Count | Should -BeGreaterOrEqual 8
    }
    It 'reads a missing key in well under a millisecond where the provider needs twenty' -Skip:(-not $script:hasRegistry) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        for ($i = 0; $i -lt 100; $i++) { $null = Get-WtRegistryProperty -Path ($script:regTestKey + '\Nope') -Name 'X' }
        $sw.Stop()
        $sw.Elapsed.TotalMilliseconds | Should -BeLessThan 500
    }
}
