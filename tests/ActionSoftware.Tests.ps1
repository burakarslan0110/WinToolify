#Requires -Modules Pester

<#
.SYNOPSIS
    Coverage for the four Software rows on the Actions screen -
    WingetUpgradeSinglePackage, UninstallProgram, ResetStoreCache and
    ReRegisterStoreApp. Every Windows data source is injected; nothing in
    this file touches the real registry, winget, Appx or Start-Process.
    Guards the winget exit-code helper against a real PS 5.1 trap: an
    eight-digit hex literal like 0x8A15002B parses as the same negative
    Int32 $LASTEXITCODE carries, but casting that literal to [uint32]
    throws instead of comparing false.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'

    function Get-WtCodeOnlyDefinition {
        <#
        .SYNOPSIS
            Strips comment-based help blocks and line comments from a
            function's Definition text before a guard scan runs, so a
            docstring that WARNS about a forbidden API (e.g. "NEVER
            Win32_Product" or an explanation of why GetNewClosure is not
            used) does not itself trip the scan for real usage.
        #>
        param([Parameter(Mandatory)][string]$Body)
        $noBlockComments = [regex]::Replace($Body, '(?s)<#.*?#>', '')
        return [regex]::Replace($noBlockComments, '(?m)#.*$', '')
    }

    . $TargetPath
}

Describe 'ConvertTo-WtWingetExitCode' {
    It 'reads a negative Int32 back as the documented unsigned winget code' {
        ConvertTo-WtWingetExitCode -ExitCode -1978335189 | Should -Be ([Convert]::ToUInt32('8A15002B', 16))
        ConvertTo-WtWingetExitCode -ExitCode -1978335212 | Should -Be ([Convert]::ToUInt32('8A150014', 16))
    }

    It 'leaves success alone and survives a null exit code' {
        ConvertTo-WtWingetExitCode -ExitCode 0 | Should -Be ([uint32]0)
        ConvertTo-WtWingetExitCode -ExitCode $null | Should -BeNullOrEmpty
    }

    It 'proves the naive comparison the code must never make is unsafe' {
        (-1978335189 -eq 0x8A15002B) | Should -BeTrue
        { -1978335189 -eq [uint32]0x8A15002B } | Should -Throw
    }
}

Describe 'Get-WtWingetUpgradeArguments' {
    It 'pins the id run to --exact and disables every interactive path' {
        $args = @(Get-WtWingetUpgradeArguments -Package 'Mozilla.Firefox')
        $args[0] | Should -Be 'upgrade'
        $args | Should -Contain '--id'
        $args | Should -Contain 'Mozilla.Firefox'
        $args | Should -Contain '--exact'
        $args | Should -Contain '--include-unknown'
        $args | Should -Contain '--silent'
        $args | Should -Contain '--disable-interactivity'
    }

    It 'retries by name WITHOUT --exact' {
        $args = @(Get-WtWingetUpgradeArguments -Package 'Firefox' -ByName)
        $args | Should -Contain '--name'
        $args | Should -Contain 'Firefox'
        $args | Should -Not -Contain '--exact'
        $args | Should -Not -Contain '--id'
        $args | Should -Contain '--silent'
        $args | Should -Contain '--disable-interactivity'
    }

    It 'never lets the typed text become a second command' {
        $args = @(Get-WtWingetUpgradeArguments -Package 'x; shutdown /s')
        $args | Should -Contain 'x; shutdown /s'
        @($args | Where-Object { $_ -eq 'shutdown' }).Count | Should -Be 0
    }
}

Describe 'Test-WtWingetShouldRetryByName' {
    It 'retries only on NO_APPLICATIONS_FOUND (0x8A150014)' {
        Test-WtWingetShouldRetryByName -ExitCode -1978335212 | Should -BeTrue
    }

    It 'does not retry on success, on up-to-date, or with no code at all' {
        Test-WtWingetShouldRetryByName -ExitCode 0 | Should -BeFalse
        Test-WtWingetShouldRetryByName -ExitCode -1978335189 | Should -BeFalse
        Test-WtWingetShouldRetryByName -ExitCode $null | Should -BeFalse
    }
}

Describe 'Get-WtWingetUpgradeResultLines' {
    It 'reports success' {
        $lines = @(Get-WtWingetUpgradeResultLines -Package 'Mozilla.Firefox' -ExitCode 0)
        $lines.Count | Should -Be 1
        $lines[0] | Should -Be ((Get-Translation 'WingetSingleDone') -f 'Mozilla.Firefox')
    }

    It 'turns the unsigned "update not applicable" code into "already up to date"' {
        $lines = @(Get-WtWingetUpgradeResultLines -Package 'Mozilla.Firefox' -ExitCode -1978335189)
        $lines[0] | Should -Be ((Get-Translation 'WingetSingleUpToDate') -f 'Mozilla.Firefox')
    }

    It 'says nothing matched when even the name retry found no package' {
        $lines = @(Get-WtWingetUpgradeResultLines -Package 'Nope' -ExitCode -1978335212)
        $lines[0] | Should -Be ((Get-Translation 'WingetSingleNotFound') -f 'Nope')
    }

    It 'prints an unknown failure as the unsigned hex code, never as a negative number' {
        $lines = @(Get-WtWingetUpgradeResultLines -Package 'Some.App' -ExitCode -1978335100)
        $lines[0] | Should -Match '8A15'
        $lines[0] | Should -Not -Match '-1978335100'
    }

    It 'degrades honestly when no exit code was captured at all' {
        $lines = @(Get-WtWingetUpgradeResultLines -Package 'Some.App' -ExitCode $null)
        $lines.Count | Should -Be 1
        $lines[0] | Should -Not -BeNullOrEmpty
    }
}

Describe 'Invoke-WtWingetUpgradeSinglePackageAction' {
    BeforeEach {
        $script:Runs = New-Object 'System.Collections.Generic.List[object]'
        $script:Shown = @()
    }

    It 'runs nothing when the answer is blank' {
        Invoke-WtWingetUpgradeSinglePackageAction `
            -AskPackage { '   ' } `
            -EnsureWinget { $true } `
            -RunWinget { param($Arguments, $Notice, $Crumb) $script:Runs.Add(@($Arguments)); return 0 } `
            -Show { param($Lines) $script:Shown = @($Lines) }
        $script:Runs.Count | Should -Be 0
    }

    It 'says so when winget is not available, without running it' {
        Invoke-WtWingetUpgradeSinglePackageAction `
            -AskPackage { 'Mozilla.Firefox' } `
            -EnsureWinget { $false } `
            -RunWinget { param($Arguments, $Notice, $Crumb) $script:Runs.Add(@($Arguments)); return 0 } `
            -Show { param($Lines) $script:Shown = @($Lines) }
        $script:Runs.Count | Should -Be 0
        $script:Shown[0] | Should -Be (Get-Translation 'WingetInstallError')
    }

    It 'runs the id pass once and reports success' {
        Invoke-WtWingetUpgradeSinglePackageAction `
            -AskPackage { '  Mozilla.Firefox  ' } `
            -EnsureWinget { $true } `
            -RunWinget { param($Arguments, $Notice, $Crumb) $script:Runs.Add(@($Arguments)); return 0 } `
            -Show { param($Lines) $script:Shown = @($Lines) }
        $script:Runs.Count | Should -Be 1
        $script:Runs[0] | Should -Contain '--exact'
        $script:Runs[0] | Should -Contain 'Mozilla.Firefox'
        $script:Shown[0] | Should -Be ((Get-Translation 'WingetSingleDone') -f 'Mozilla.Firefox')
    }

    It 'falls back to a --name pass when the id matched nothing' {
        Invoke-WtWingetUpgradeSinglePackageAction `
            -AskPackage { 'Firefox' } `
            -EnsureWinget { $true } `
            -RunWinget {
                param($Arguments, $Notice, $Crumb)
                $script:Runs.Add(@($Arguments))
                if ($script:Runs.Count -eq 1) { return -1978335212 }
                return 0
            } `
            -Show { param($Lines) $script:Shown = @($Lines) }
        $script:Runs.Count | Should -Be 2
        $script:Runs[0] | Should -Contain '--id'
        $script:Runs[1] | Should -Contain '--name'
        $script:Runs[1] | Should -Not -Contain '--exact'
        $script:Shown[0] | Should -Be ((Get-Translation 'WingetSingleDone') -f 'Firefox')
    }

    It 'does not retry a package that is simply up to date' {
        Invoke-WtWingetUpgradeSinglePackageAction `
            -AskPackage { 'Mozilla.Firefox' } `
            -EnsureWinget { $true } `
            -RunWinget { param($Arguments, $Notice, $Crumb) $script:Runs.Add(@($Arguments)); return -1978335189 } `
            -Show { param($Lines) $script:Shown = @($Lines) }
        $script:Runs.Count | Should -Be 1
        $script:Shown[0] | Should -Be ((Get-Translation 'WingetSingleUpToDate') -f 'Mozilla.Firefox')
    }
}

Describe 'Get-WtUninstallRegistryRoots' {
    It 'always reads both machine views' {
        $roots = @(Get-WtUninstallRegistryRoots -GetUserSid { $null })
        $paths = @($roots | ForEach-Object { $_.Path })
        $paths | Should -Contain 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        $paths | Should -Contain 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    }

    It 'reaches the interactive user through HKEY_USERS, never through HKCU' {
        $roots = @(Get-WtUninstallRegistryRoots -GetUserSid { 'S-1-5-21-11-22-33-1001' })
        $paths = @($roots | ForEach-Object { $_.Path })
        $paths | Should -Contain 'Registry::HKEY_USERS\S-1-5-21-11-22-33-1001\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        $paths | Should -Contain 'Registry::HKEY_USERS\S-1-5-21-11-22-33-1001\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        @($paths | Where-Object { $_ -like 'HKCU*' }).Count | Should -Be 0
    }

    It 'degrades to the machine views when the SID cannot be resolved' {
        $roots = @(Get-WtUninstallRegistryRoots -GetUserSid { $null })
        $roots.Count | Should -Be 2
        @($roots | Where-Object { $_.ScopeKey -eq 'UninstallScopeUser' }).Count | Should -Be 0
        Test-WtUninstallUserHiveVisible -GetRoots { Get-WtUninstallRegistryRoots -GetUserSid { $null } } | Should -BeFalse
    }

    It 'tags each root with a scope key that resolves in both languages' {
        $roots = @(Get-WtUninstallRegistryRoots -GetUserSid { 'S-1-5-21-11-22-33-1001' })
        foreach ($root in $roots) {
            $script:Translations['EN'].ContainsKey($root.ScopeKey) | Should -BeTrue -Because "EN needs '$($root.ScopeKey)'"
            $script:Translations['TR'].ContainsKey($root.ScopeKey) | Should -BeTrue -Because "TR needs '$($root.ScopeKey)'"
        }
        Test-WtUninstallUserHiveVisible -GetRoots { Get-WtUninstallRegistryRoots -GetUserSid { 'S-1-5-21-11-22-33-1001' } } | Should -BeTrue
    }
}

Describe 'Get-WtInstalledProgramEntries' {
    BeforeAll {
        $script:FakeRoots = {
            @(
                @{ Path = 'M64'; ScopeKey = 'UninstallScopeMachine' }
                @{ Path = 'M32'; ScopeKey = 'UninstallScopeMachine' }
                @{ Path = 'U64'; ScopeKey = 'UninstallScopeUser' }
            )
        }
        $script:FakeEntries = {
            param($Path)
            switch ($Path) {
                'M64' {
                    @(
                        [PSCustomObject]@{ PSChildName = '{11111111-2222-3333-4444-555555555555}'; DisplayName = 'Contoso Suite'; DisplayVersion = '3.1'; Publisher = 'Contoso'; UninstallString = 'MsiExec.exe /X{11111111-2222-3333-4444-555555555555}' }
                        [PSCustomObject]@{ PSChildName = 'HiddenThing'; DisplayName = 'Hidden Thing'; SystemComponent = 1; UninstallString = 'x.exe' }
                        [PSCustomObject]@{ PSChildName = 'KB5000001'; DisplayName = 'Update for Contoso'; ReleaseType = 'Security Update'; UninstallString = 'x.exe' }
                        [PSCustomObject]@{ PSChildName = 'NoName'; DisplayName = '   '; UninstallString = 'x.exe' }
                        [PSCustomObject]@{ PSChildName = 'NoCommand'; DisplayName = 'No Command At All' }
                    )
                }
                'M32' {
                    @(
                        [PSCustomObject]@{ PSChildName = '{11111111-2222-3333-4444-555555555555}'; DisplayName = 'Contoso Suite (32-bit ghost)'; UninstallString = 'x.exe' }
                        [PSCustomObject]@{ PSChildName = 'Acme32'; DisplayName = 'Acme Tool'; DisplayVersion = '1.0'; Publisher = 'Acme'; UninstallString = '"C:\Acme\uninst.exe"'; QuietUninstallString = '"C:\Acme\uninst.exe" /S' }
                    )
                }
                'U64' {
                    @(
                        [PSCustomObject]@{ PSChildName = 'AcmeUser'; DisplayName = 'Acme Tool'; DisplayVersion = '2.0'; Publisher = 'Acme'; UninstallString = 'C:\Users\a\uninst.exe'; QuietUninstallString = 'C:\Users\a\uninst.exe /quiet' }
                    )
                }
                default { @() }
            }
        }
    }

    It 'keeps real programs and drops components, updates, nameless and uninstallable keys' {
        $entries = @(Get-WtInstalledProgramEntries -GetRoots $script:FakeRoots -GetEntries $script:FakeEntries)
        $names = @($entries | ForEach-Object { $_.Key })
        $names | Should -Contain '{11111111-2222-3333-4444-555555555555}'
        $names | Should -Contain 'Acme32'
        $names | Should -Contain 'AcmeUser'
        $names | Should -Not -Contain 'HiddenThing'
        $names | Should -Not -Contain 'KB5000001'
        $names | Should -Not -Contain 'NoName'
        $names | Should -Not -Contain 'NoCommand'
    }

    It 'de-duplicates on PSChildName, keeping the first root that carried it' {
        $entries = @(Get-WtInstalledProgramEntries -GetRoots $script:FakeRoots -GetEntries $script:FakeEntries)
        $guidRows = @($entries | Where-Object { $_.Key -eq '{11111111-2222-3333-4444-555555555555}' })
        $guidRows.Count | Should -Be 1
        $guidRows[0].DisplayName | Should -Be 'Contoso Suite'
    }

    It 'keeps two different keys that share one DisplayName' {
        $entries = @(Get-WtInstalledProgramEntries -GetRoots $script:FakeRoots -GetEntries $script:FakeEntries)
        @($entries | Where-Object { $_.DisplayName -eq 'Acme Tool' }).Count | Should -Be 2
    }

    It 'records which hive each program came from' {
        $entries = @(Get-WtInstalledProgramEntries -GetRoots $script:FakeRoots -GetEntries $script:FakeEntries)
        ($entries | Where-Object { $_.Key -eq 'Acme32' }).ScopeKey | Should -Be 'UninstallScopeMachine'
        ($entries | Where-Object { $_.Key -eq 'AcmeUser' }).ScopeKey | Should -Be 'UninstallScopeUser'
    }

    It 'returns an empty list, not an error, when nothing is readable' {
        $entries = @(Get-WtInstalledProgramEntries -GetRoots { @() } -GetEntries { param($Path) @() })
        $entries.Count | Should -Be 0
    }

    It 'never touches Win32_Product (it triggers MSI reconfiguration) or Get-WmiObject' {
        $body = Get-WtCodeOnlyDefinition -Body (Get-Command Get-WtInstalledProgramEntries).Definition
        $body | Should -Not -Match 'Win32_Product'
        $body | Should -Not -Match 'Get-WmiObject'
    }
}

Describe 'Get-WtUninstallCommand' {
    It 'uses msiexec /x for a product GUID key' {
        $entry = [PSCustomObject]@{ Key = '{11111111-2222-3333-4444-555555555555}'; QuietUninstallString = '' }
        $command = Get-WtUninstallCommand -Entry $entry
        $command.Kind | Should -Be 'Msi'
        $command.FilePath | Should -Be 'msiexec.exe'
        $command.Arguments | Should -Be '/x {11111111-2222-3333-4444-555555555555} /qn /norestart'
    }

    It 'splits a quoted QuietUninstallString into executable and arguments' {
        $entry = [PSCustomObject]@{ Key = 'Acme32'; QuietUninstallString = '"C:\Program Files\Acme\uninst.exe" /S /norestart' }
        $command = Get-WtUninstallCommand -Entry $entry
        $command.Kind | Should -Be 'Quiet'
        $command.FilePath | Should -Be 'C:\Program Files\Acme\uninst.exe'
        $command.Arguments | Should -Be '/S /norestart'
    }

    It 'splits an unquoted path that contains spaces at the .exe boundary' {
        $entry = [PSCustomObject]@{ Key = 'Acme32'; QuietUninstallString = 'C:\Program Files\Acme\uninst.exe /S' }
        $command = Get-WtUninstallCommand -Entry $entry
        $command.FilePath | Should -Be 'C:\Program Files\Acme\uninst.exe'
        $command.Arguments | Should -Be '/S'
    }

    It 'handles an executable with no arguments' {
        $entry = [PSCustomObject]@{ Key = 'Acme32'; QuietUninstallString = 'C:\Acme\uninst.exe' }
        $command = Get-WtUninstallCommand -Entry $entry
        $command.FilePath | Should -Be 'C:\Acme\uninst.exe'
        $command.Arguments | Should -Be ''
    }

    It 'refuses when there is no silent command - a UI uninstaller would hang the panel' {
        $entry = [PSCustomObject]@{ Key = 'Acme32'; QuietUninstallString = ''; UninstallString = '"C:\Acme\uninst.exe"' }
        (Get-WtUninstallCommand -Entry $entry).Kind | Should -Be 'None'
    }

    It 'does not mistake a non-GUID key for an MSI product' {
        $entry = [PSCustomObject]@{ Key = '{not-a-guid}'; QuietUninstallString = 'C:\Acme\uninst.exe /S' }
        (Get-WtUninstallCommand -Entry $entry).Kind | Should -Be 'Quiet'
    }
}

Describe 'Get-WtUninstallProgramCatalog / Get-WtUninstallProgramStateItems' {
    BeforeAll {
        $script:PickEntries = @(
            [PSCustomObject]@{ Key = 'Acme32'; DisplayName = 'Acme Tool'; DisplayVersion = '1.0'; Publisher = 'Acme'; QuietUninstallString = '"C:\Acme\uninst.exe" /S'; ScopeKey = 'UninstallScopeMachine' }
            [PSCustomObject]@{ Key = 'AcmeUser'; DisplayName = 'Acme Tool'; DisplayVersion = '2.0'; Publisher = 'Acme'; QuietUninstallString = 'C:\Users\a\uninst.exe /quiet'; ScopeKey = 'UninstallScopeUser' }
            [PSCustomObject]@{ Key = 'LoudApp'; DisplayName = 'Loud App'; DisplayVersion = '5'; Publisher = 'Loud'; QuietUninstallString = ''; ScopeKey = 'UninstallScopeMachine' }
        )
    }

    It 'keys every catalog row on PSChildName, so two rows named the same stay apart' {
        $catalog = @(Get-WtUninstallProgramCatalog -Entries $script:PickEntries)
        @($catalog | ForEach-Object { $_.Name }) | Should -Be @('Acme32', 'AcmeUser', 'LoudApp')
        @($catalog | ForEach-Object { $_.Name } | Sort-Object -Unique).Count | Should -Be 3
    }

    It 'shows version and publisher in the label so identical names are distinguishable' {
        $catalog = @(Get-WtUninstallProgramCatalog -Entries $script:PickEntries)
        $catalog[0].DisplayLabel | Should -Be 'Acme Tool 1.0 - Acme'
        $catalog[1].DisplayLabel | Should -Be 'Acme Tool 2.0 - Acme'
    }

    It 'names the program in each consequence line' {
        $catalog = @(Get-WtUninstallProgramCatalog -Entries $script:PickEntries)
        $catalog[2].Consequence | Should -Be ((Get-Translation 'UninstallConsequence') -f 'Loud App')
    }

    It 'marks the scope, and makes a program with no silent uninstaller unselectable' {
        $states = @(Get-WtUninstallProgramStateItems -Entries $script:PickEntries)
        ($states | Where-Object { $_.Name -eq 'Acme32' }).StateLabel | Should -Be (Get-Translation 'UninstallScopeMachine')
        ($states | Where-Object { $_.Name -eq 'AcmeUser' }).StateLabel | Should -Be (Get-Translation 'UninstallScopeUser')
        ($states | Where-Object { $_.Name -eq 'LoudApp' }).Selectable | Should -BeFalse
        ($states | Where-Object { $_.Name -eq 'LoudApp' }).StateLabel | Should -Be (Get-Translation 'UninstallNoSilentState')
        ($states | Where-Object { $_.Name -eq 'Acme32' }).Selectable | Should -BeTrue
    }
}

Describe 'Invoke-WtUninstallProgramAction' {
    BeforeEach {
        $script:Ran = New-Object 'System.Collections.Generic.List[object]'
        $script:Shown = @()
        $script:Info = @()
        $script:Entries = @(
            [PSCustomObject]@{ Key = 'Acme32'; DisplayName = 'Acme Tool'; DisplayVersion = '1.0'; Publisher = 'Acme'; QuietUninstallString = '"C:\Acme\uninst.exe" /S'; ScopeKey = 'UninstallScopeMachine' }
            [PSCustomObject]@{ Key = 'AcmeUser'; DisplayName = 'Acme Tool'; DisplayVersion = '2.0'; Publisher = 'Acme'; QuietUninstallString = 'C:\Users\a\uninst.exe /quiet'; ScopeKey = 'UninstallScopeUser' }
        )
    }

    It 'says so when the registry holds nothing removable' {
        Invoke-WtUninstallProgramAction `
            -GetEntries { @() } `
            -GetUserHiveVisible { $true } `
            -Select { param($Catalog, $StateItems, $Crumb, $InfoLines) @('Acme32') } `
            -Confirm { param($Consequence, $Lines, $Crumb) $true } `
            -RunUninstall { param($Command, $ProgramName, $Crumb) $script:Ran.Add($Command); return 0 } `
            -Show { param($Lines) $script:Shown = @($Lines) }
        $script:Ran.Count | Should -Be 0
        $script:Shown[0] | Should -Be (Get-Translation 'UninstallNoPrograms')
    }

    It 'takes only the FIRST selection, because Show-WtSelector is multi-select' {
        Invoke-WtUninstallProgramAction `
            -GetEntries { $script:Entries } `
            -GetUserHiveVisible { $true } `
            -Select { param($Catalog, $StateItems, $Crumb, $InfoLines) @('AcmeUser', 'Acme32') } `
            -Confirm { param($Consequence, $Lines, $Crumb) $true } `
            -RunUninstall { param($Command, $ProgramName, $Crumb) $script:Ran.Add(@{ Command = $Command; Name = $ProgramName }); return 0 } `
            -Show { param($Lines) $script:Shown = @($Lines) }
        $script:Ran.Count | Should -Be 1
        $script:Ran[0].Command.FilePath | Should -Be 'C:\Users\a\uninst.exe'
        $script:Ran[0].Name | Should -Be 'Acme Tool'
        $script:Shown[0] | Should -Be ((Get-Translation 'UninstallDone') -f 'Acme Tool', '0')
    }

    It 'runs nothing when the typed gate is refused' {
        Invoke-WtUninstallProgramAction `
            -GetEntries { $script:Entries } `
            -GetUserHiveVisible { $true } `
            -Select { param($Catalog, $StateItems, $Crumb, $InfoLines) @('Acme32') } `
            -Confirm { param($Consequence, $Lines, $Crumb) $false } `
            -RunUninstall { param($Command, $ProgramName, $Crumb) $script:Ran.Add($Command); return 0 } `
            -Show { param($Lines) $script:Shown = @($Lines) }
        $script:Ran.Count | Should -Be 0
        $script:Shown[0] | Should -Be (Get-Translation 'UninstallCancelled')
    }

    It 'runs nothing when the picker is left empty' {
        Invoke-WtUninstallProgramAction `
            -GetEntries { $script:Entries } `
            -GetUserHiveVisible { $true } `
            -Select { param($Catalog, $StateItems, $Crumb, $InfoLines) @() } `
            -Confirm { param($Consequence, $Lines, $Crumb) $true } `
            -RunUninstall { param($Command, $ProgramName, $Crumb) $script:Ran.Add($Command); return 0 } `
            -Show { param($Lines) $script:Shown = @($Lines) }
        $script:Ran.Count | Should -Be 0
        $script:Shown[0] | Should -Be (Get-Translation 'UninstallCancelled')
    }

    It 'warns in the picker when the interactive user hive could not be read' {
        Invoke-WtUninstallProgramAction `
            -GetEntries { $script:Entries } `
            -GetUserHiveVisible { $false } `
            -Select { param($Catalog, $StateItems, $Crumb, $InfoLines) $script:Info = @($InfoLines); @() } `
            -Confirm { param($Consequence, $Lines, $Crumb) $true } `
            -RunUninstall { param($Command, $ProgramName, $Crumb) $script:Ran.Add($Command); return 0 } `
            -Show { param($Lines) $script:Shown = @($Lines) }
        $script:Info | Should -Contain (Get-Translation 'UninstallUserHiveMissing')
    }

    It 'treats 3010 (reboot required) as a successful uninstall and anything else as a failure' {
        Invoke-WtUninstallProgramAction `
            -GetEntries { $script:Entries } `
            -GetUserHiveVisible { $true } `
            -Select { param($Catalog, $StateItems, $Crumb, $InfoLines) @('Acme32') } `
            -Confirm { param($Consequence, $Lines, $Crumb) $true } `
            -RunUninstall { param($Command, $ProgramName, $Crumb) return 3010 } `
            -Show { param($Lines) $script:Shown = @($Lines) }
        $script:Shown[0] | Should -Be ((Get-Translation 'UninstallDone') -f 'Acme Tool', '3010')

        Invoke-WtUninstallProgramAction `
            -GetEntries { $script:Entries } `
            -GetUserHiveVisible { $true } `
            -Select { param($Catalog, $StateItems, $Crumb, $InfoLines) @('Acme32') } `
            -Confirm { param($Consequence, $Lines, $Crumb) $true } `
            -RunUninstall { param($Command, $ProgramName, $Crumb) return 1603 } `
            -Show { param($Lines) $script:Shown = @($Lines) }
        $script:Shown[0] | Should -Be ((Get-Translation 'UninstallFailed') -f 'Acme Tool', '1603')
    }
}

Describe 'Get-WtResetStoreCacheLines' {
    It 'says so when the Store package is gone (the debloat screen may have removed it)' {
        $started = $false
        $lines = @(Get-WtResetStoreCacheLines `
            -GetStorePackage { $null } `
            -WsResetPath 'C:\Windows\System32\WSReset.exe' `
            -TestWsReset { param($Path) $true } `
            -StartWsReset { param($Path) $script:StoreStarted = $true })
        $lines[0] | Should -Be (Get-Translation 'StoreCacheNoStore')
        $script:StoreStarted | Should -Not -BeTrue
    }

    It 'says so when WSReset.exe is missing' {
        $lines = @(Get-WtResetStoreCacheLines `
            -GetStorePackage { [PSCustomObject]@{ Name = 'Microsoft.WindowsStore' } } `
            -WsResetPath 'C:\Windows\System32\WSReset.exe' `
            -TestWsReset { param($Path) $false } `
            -StartWsReset { param($Path) throw 'must not be called' })
        $lines[0] | Should -Be (Get-Translation 'StoreCacheNoWsReset')
    }

    It 'starts WSReset in the background and names whose cache it is' {
        $script:StorePath = ''
        $lines = @(Get-WtResetStoreCacheLines `
            -GetStorePackage { [PSCustomObject]@{ Name = 'Microsoft.WindowsStore' } } `
            -WsResetPath 'C:\Windows\System32\WSReset.exe' `
            -TestWsReset { param($Path) $true } `
            -StartWsReset { param($Path) $script:StorePath = $Path })
        $script:StorePath | Should -Be 'C:\Windows\System32\WSReset.exe'
        $lines | Should -Contain (Get-Translation 'StoreCacheStarted')
        $lines | Should -Contain (Get-Translation 'StoreCacheAccountNote')
    }

    It 'reports a start failure instead of claiming success' {
        $lines = @(Get-WtResetStoreCacheLines `
            -GetStorePackage { [PSCustomObject]@{ Name = 'Microsoft.WindowsStore' } } `
            -WsResetPath 'C:\Windows\System32\WSReset.exe' `
            -TestWsReset { param($Path) $true } `
            -StartWsReset { param($Path) throw 'Access is denied' })
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match 'Access is denied'
    }

    It 'survives a throwing package lookup' {
        $lines = @(Get-WtResetStoreCacheLines `
            -GetStorePackage { throw 'Generic failure' } `
            -WsResetPath 'C:\Windows\System32\WSReset.exe' `
            -TestWsReset { param($Path) $true } `
            -StartWsReset { param($Path) throw 'must not be called' })
        $lines[0] | Should -Be (Get-Translation 'StoreCacheNoStore')
    }
}

Describe 'Get-WtStoreRepairPackageNames' {
    It 'is exactly two packages - never a blanket -AllUsers sweep' {
        $names = @(Get-WtStoreRepairPackageNames)
        $names.Count | Should -Be 2
        $names | Should -Contain 'Microsoft.WindowsStore'
        $names | Should -Contain 'Microsoft.DesktopAppInstaller'
    }
}

Describe 'Get-WtStoreRepairLines' {
    It 'registers each package once and reports OK per PackageFullName' {
        $script:Registered = New-Object 'System.Collections.Generic.List[string]'
        $lines = @(Get-WtStoreRepairLines `
            -GetPackages {
                param($Name)
                @([PSCustomObject]@{ PackageFullName = "$Name`_1.0_x64__8wekyb3d8bbwe"; InstallLocation = "C:\Program Files\WindowsApps\$Name" })
            } `
            -RegisterPackage { param($ManifestPath) $script:Registered.Add($ManifestPath) })
        $lines[0] | Should -Be (Get-Translation 'StoreRepairHeader')
        $script:Registered.Count | Should -Be 2
        $script:Registered[0] | Should -Match 'AppXManifest.xml$'
        $lines | Should -Contain ((Get-Translation 'StoreRepairOk') -f 'Microsoft.WindowsStore_1.0_x64__8wekyb3d8bbwe')
        $lines | Should -Contain ((Get-Translation 'StoreRepairOk') -f 'Microsoft.DesktopAppInstaller_1.0_x64__8wekyb3d8bbwe')
    }

    It 'de-duplicates the objects -AllUsers returns once per user profile' {
        $script:Registered = New-Object 'System.Collections.Generic.List[string]'
        $lines = @(Get-WtStoreRepairLines `
            -GetPackages {
                param($Name)
                @(
                    [PSCustomObject]@{ PackageFullName = "$Name`_1.0_x64__8wekyb3d8bbwe"; InstallLocation = "C:\WindowsApps\$Name" }
                    [PSCustomObject]@{ PackageFullName = "$Name`_1.0_x64__8wekyb3d8bbwe"; InstallLocation = "C:\WindowsApps\$Name" }
                    [PSCustomObject]@{ PackageFullName = "$Name`_1.0_x64__8wekyb3d8bbwe"; InstallLocation = "C:\WindowsApps\$Name" }
                )
            } `
            -RegisterPackage { param($ManifestPath) $script:Registered.Add($ManifestPath) })
        $script:Registered.Count | Should -Be 2
        @($lines | Where-Object { $_ -eq ((Get-Translation 'StoreRepairOk') -f 'Microsoft.WindowsStore_1.0_x64__8wekyb3d8bbwe') }).Count | Should -Be 1
    }

    It 'says "not installed" instead of failing silently' {
        $lines = @(Get-WtStoreRepairLines `
            -GetPackages { param($Name) @() } `
            -RegisterPackage { param($ManifestPath) throw 'must not be called' })
        $lines | Should -Contain ((Get-Translation 'StoreRepairMissing') -f 'Microsoft.WindowsStore')
        $lines | Should -Contain ((Get-Translation 'StoreRepairMissing') -f 'Microsoft.DesktopAppInstaller')
    }

    It 'prints FAIL with the reason when registration throws' {
        $lines = @(Get-WtStoreRepairLines `
            -GetPackages {
                param($Name)
                @([PSCustomObject]@{ PackageFullName = "$Name`_1.0"; InstallLocation = "C:\WindowsApps\$Name" })
            } `
            -RegisterPackage { param($ManifestPath) throw 'Deployment failed with HRESULT 0x80073CF9' })
        @($lines | Where-Object { $_ -match '0x80073CF9' }).Count | Should -Be 2
    }

    It 'reports a package that has no install location rather than building a bogus manifest path' {
        $lines = @(Get-WtStoreRepairLines `
            -GetPackages {
                param($Name)
                @([PSCustomObject]@{ PackageFullName = "$Name`_1.0"; InstallLocation = '' })
            } `
            -RegisterPackage { param($ManifestPath) throw 'must not be called' })
        $lines | Should -Contain ((Get-Translation 'StoreRepairFail') -f 'Microsoft.WindowsStore_1.0', (Get-Translation 'StoreRepairNoLocation'))
    }

    It 'survives a throwing package lookup on both names' {
        $lines = @(Get-WtStoreRepairLines `
            -GetPackages { param($Name) throw 'Generic failure' } `
            -RegisterPackage { param($ManifestPath) throw 'must not be called' })
        $lines | Should -Contain ((Get-Translation 'StoreRepairMissing') -f 'Microsoft.WindowsStore')
    }
}

Describe 'ActionGroupSoftware wiring' {
    BeforeAll {
        $script:SoftwareGroup = @(Get-WtActionToolGroups) | Where-Object { $_.HeaderKey -eq 'ActionGroupSoftware' } | Select-Object -First 1
        $script:SoftwareRows = @(& $script:SoftwareGroup.GetRows)
        $script:NewNames = @('WingetUpgradeSinglePackage', 'UninstallProgram', 'ResetStoreCache', 'ReRegisterStoreApp')
    }

    It 'carries the four new rows on top of the two it already had, plus the VCRedist installer that moved in' {
        $names = @($script:SoftwareRows | ForEach-Object { $_.Name })
        foreach ($n in $script:NewNames) { $names | Should -Contain $n }
        $names | Should -Contain 'UpdateWindowsStoreApps'
        $names | Should -Contain 'UpdateAllProgramsWithWinGet'
        $names | Should -Contain 'InstallVCRedist'
        $script:SoftwareRows.Count | Should -Be 7
    }

    It 'gives every new row its designed risk badge' {
        ($script:SoftwareRows | Where-Object { $_.Name -eq 'WingetUpgradeSinglePackage' }).Risk | Should -Be 'SAFE'
        ($script:SoftwareRows | Where-Object { $_.Name -eq 'UninstallProgram' }).Risk | Should -Be 'ADVANCED'
        ($script:SoftwareRows | Where-Object { $_.Name -eq 'ResetStoreCache' }).Risk | Should -Be 'SAFE'
        ($script:SoftwareRows | Where-Object { $_.Name -eq 'ReRegisterStoreApp' }).Risk | Should -Be 'CAUTION'
    }

    It 'renders every new row inside the box and gives each one a runnable action' {
        foreach ($n in $script:NewNames) {
            $row = $script:SoftwareRows | Where-Object { $_.Name -eq $n }
            $row.Kind | Should -Be 'Action'
            $row.Data.Action | Should -Not -BeNullOrEmpty
        }
    }

    It 'labels every new row in both languages, in imperative mood and under 45 characters' {
        foreach ($n in $script:NewNames) {
            foreach ($lang in 'EN', 'TR') {
                $script:Translations[$lang].ContainsKey($n) | Should -BeTrue -Because "$lang needs '$n'"
                ([string]$script:Translations[$lang][$n]).Length | Should -BeLessOrEqual 45 -Because "$lang '$n'"
            }
            $script:Translations['EN'][$n] | Should -Not -Be $script:Translations['TR'][$n]
        }
    }

    It 'keeps every string this task added ASCII-only' {
        $keys = $script:NewNames + @(
            'WingetSingleHint', 'WingetSinglePrompt', 'WingetSingleRunning', 'WingetSingleRetry',
            'WingetSingleUpToDate', 'WingetSingleDone', 'WingetSingleNotFound', 'WingetSingleFailed',
            'UninstallNoPrograms', 'UninstallUserHiveMissing', 'UninstallConsequence',
            'UninstallNoSilentCommand', 'UninstallNoSilentState', 'UninstallStarting',
            'UninstallWaiting', 'UninstallDone', 'UninstallFailed', 'UninstallCancelled',
            'UninstallScopeMachine', 'UninstallScopeUser', 'StoreCacheNoStore', 'StoreCacheNoWsReset',
            'StoreCacheStartFailed', 'StoreCacheStarted', 'StoreCacheAccountNote', 'StoreRepairHeader',
            'StoreRepairMissing', 'StoreRepairOk', 'StoreRepairFail', 'StoreRepairNoLocation'
        )
        foreach ($lang in 'EN', 'TR') {
            foreach ($key in $keys) {
                $script:Translations[$lang].ContainsKey($key) | Should -BeTrue -Because "$lang needs '$key'"
                $value = [string]$script:Translations[$lang][$key]
                foreach ($ch in $value.ToCharArray()) {
                    [int]$ch | Should -BeLessOrEqual 127 -Because "$lang '$key' must be ASCII"
                }
            }
        }
    }

    It 'never reaches Windows through Get-WmiObject or Win32_Product' {
        foreach ($fn in 'Get-WtUninstallRegistryRoots', 'Get-WtInstalledProgramEntries', 'Get-WtUninstallCommand',
                        'Invoke-WtUninstallProgramAction', 'Get-WtResetStoreCacheLines', 'Get-WtStoreRepairLines',
                        'Invoke-WtWingetUpgradeSinglePackageAction') {
            $body = Get-WtCodeOnlyDefinition -Body (Get-Command $fn).Definition
            $body | Should -Not -Match 'Get-WmiObject' -Because "$fn"
            $body | Should -Not -Match 'Win32_Product' -Because "$fn"
        }
    }

    It 'never uses .GetNewClosure(), which breaks when this file is executed rather than dot-sourced' {
        foreach ($fn in 'Invoke-WtWingetUpgradeSinglePackageAction', 'Invoke-WtUninstallProgramAction') {
            (Get-Command $fn).Definition | Should -Not -Match '\.GetNewClosure\(\)' -Because "$fn"
        }
    }
}

Describe 'Invoke-WtWingetUpgradeSinglePackageAction and the user scope' {
    BeforeEach {
        $script:Runs = New-Object 'System.Collections.Generic.List[object]'
        $script:AsUser = New-Object 'System.Collections.Generic.List[object]'
        $script:Shown = @()
        $script:AdminCtx = [System.BitConverter]::ToInt32(
            [System.BitConverter]::GetBytes([Convert]::ToUInt32('8A15007D', 16)), 0)
    }

    It 'retries as the signed-in user when the elevated session was refused' {
        Invoke-WtWingetUpgradeSinglePackageAction `
            -AskPackage { 'Google.Antigravity' } `
            -EnsureWinget { $true } `
            -RunWinget { param($Arguments, $Notice, $Crumb) $script:Runs.Add(@($Arguments)); return $script:AdminCtx } `
            -RunAsUser {
                param($Arguments, $Notice, $Crumb)
                $script:AsUser.Add(@($Arguments))
                return @{ Ran = $true; ExitCode = 0; Lines = [string[]]@('Successfully installed'); Reason = '' }
            } `
            -Show { param($Lines) $script:Shown = @($Lines) }
        $script:Runs.Count | Should -Be 1
        $script:AsUser.Count | Should -Be 1
        $script:AsUser[0] | Should -Contain 'Google.Antigravity'
        ($script:Shown -join "`n") | Should -BeLike '*Successfully installed*'
        $script:Shown[-1] | Should -Be ((Get-Translation 'WingetSingleDone') -f 'Google.Antigravity')
    }

    It 'explains the refusal instead of a hex code when the retry could not run' {
        Invoke-WtWingetUpgradeSinglePackageAction `
            -AskPackage { 'Google.Antigravity' } `
            -EnsureWinget { $true } `
            -RunWinget { param($Arguments, $Notice, $Crumb) $script:Runs.Add(@($Arguments)); return $script:AdminCtx } `
            -RunAsUser {
                param($Arguments, $Notice, $Crumb)
                return @{ Ran = $false; ExitCode = $null; Lines = [string[]]@(); Reason = 'NoInteractiveUser' }
            } `
            -Show { param($Lines) $script:Shown = @($Lines) }
        $script:Shown[0] | Should -Be (Get-Translation 'WsRetryNoUser')
        ($script:Shown -join "`n") | Should -Not -BeLike '*8A15007D*'
        $script:Shown[-1] | Should -Be ((Get-Translation 'WsResultAdminContext') -f 'Google.Antigravity')
    }

    It 'never reaches for the user session on a failure de-elevation cannot fix' {
        Invoke-WtWingetUpgradeSinglePackageAction `
            -AskPackage { 'Mozilla.Firefox' } `
            -EnsureWinget { $true } `
            -RunWinget { param($Arguments, $Notice, $Crumb) $script:Runs.Add(@($Arguments)); return 0 } `
            -RunAsUser { param($Arguments, $Notice, $Crumb) $script:AsUser.Add(@($Arguments)); return $null } `
            -Show { param($Lines) $script:Shown = @($Lines) }
        $script:AsUser.Count | Should -Be 0
    }

    It 'retries with the arguments the --name pass used, not the id ones' {
        Invoke-WtWingetUpgradeSinglePackageAction `
            -AskPackage { 'Antigravity' } `
            -EnsureWinget { $true } `
            -RunWinget {
                param($Arguments, $Notice, $Crumb)
                $script:Runs.Add(@($Arguments))
                if ($script:Runs.Count -eq 1) { return -1978335212 }
                return $script:AdminCtx
            } `
            -RunAsUser {
                param($Arguments, $Notice, $Crumb)
                $script:AsUser.Add(@($Arguments))
                return @{ Ran = $true; ExitCode = 0; Lines = [string[]]@(); Reason = '' }
            } `
            -Show { param($Lines) $script:Shown = @($Lines) }
        $script:Runs.Count | Should -Be 2
        $script:AsUser.Count | Should -Be 1
        $script:AsUser[0] | Should -Contain '--name'
        $script:AsUser[0] | Should -Not -Contain '--exact'
    }
}
