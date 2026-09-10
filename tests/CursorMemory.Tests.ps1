BeforeAll {
    . (Join-Path (Join-Path $PSScriptRoot '..') 'dist/WinToolify.ps1')
}

Describe 'Resolve-WtCursorIndex (PURE: which row a re-entered list opens on)' {
    BeforeEach {
        $script:rows = @(
            (New-WtListItem -Kind 'Header' -Name 'H' -Label 'Head')
            (New-WtListItem -Kind 'Link'   -Name 'A' -Label 'A' -Data @{ Screen = 'X' })
            (New-WtListItem -Kind 'Link'   -Name 'B' -Label 'B' -Data @{ Screen = 'Y' })
            (New-WtListItem -Kind 'Spacer' -Name 'S' -Label '')
            (New-WtListItem -Kind 'Link'   -Name 'C' -Label 'C' -Data @{ Screen = 'Z' })
        )
    }
    It 'prefers the remembered row NAME over the remembered index' {
        Resolve-WtCursorIndex -Items $script:rows -Name 'C' -Index 1 | Should -Be 4
    }
    It 'falls back to the remembered index when that row is gone' {
        Resolve-WtCursorIndex -Items $script:rows -Name 'vanished' -Index 2 | Should -Be 2
    }
    It 'moves a fallback index that lands on an unfocusable row to the nearest focusable one' {
        Resolve-WtCursorIndex -Items $script:rows -Name 'vanished' -Index 3 | Should -Be 4
        Resolve-WtCursorIndex -Items $script:rows -Name 'vanished' -Index 0 | Should -Be 1
    }
    It 'clamps a fallback index that ran past the end of a shortened list' {
        Resolve-WtCursorIndex -Items $script:rows -Name 'vanished' -Index 99 | Should -Be 4
    }
    It 'falls back to the index when the remembered name is no longer focusable' {
        Resolve-WtCursorIndex -Items $script:rows -Name 'H' -Index 2 | Should -Be 2
    }
    It 'returns -1 when nothing is remembered, so the screen picks its own first row' {
        Resolve-WtCursorIndex -Items $script:rows -Name '' -Index -1 | Should -Be -1
    }
    It 'returns -1 for an empty list and for a list with no focusable row' {
        Resolve-WtCursorIndex -Items @() -Name 'A' -Index 0 | Should -Be -1
        $flat = @((New-WtListItem -Kind 'Info' -Name 'I' -Label 'I'))
        Resolve-WtCursorIndex -Items $flat -Name 'I' -Index 0 | Should -Be -1
    }
}

Describe 'Get-/Set-WtMainMenuCursor (session-scoped, one memory: the main menu)' {
    BeforeEach {
        $script:WtMainMenuCursor = $null
        $script:memRows = @(
            (New-WtListItem -Kind 'Link' -Name 'A' -Label 'A' -Data @{ Screen = 'X' })
            (New-WtListItem -Kind 'Link' -Name 'B' -Label 'B' -Data @{ Screen = 'Y' })
        )
    }
    It 'round-trips the row under the cursor' {
        Set-WtMainMenuCursor -Items $script:memRows -Index 1
        Get-WtMainMenuCursor -Items $script:memRows | Should -Be 1
    }
    It 'returns -1 before the first visit' {
        Get-WtMainMenuCursor -Items $script:memRows | Should -Be -1
    }
    It 'remembers nothing when the screen has no cursor at all' {
        Set-WtMainMenuCursor -Items $script:memRows -Index -1
        Get-WtMainMenuCursor -Items $script:memRows | Should -Be -1
    }
    It 'follows the row by name when the list has been reordered since' {
        Set-WtMainMenuCursor -Items $script:memRows -Index 1
        $reordered = @($script:memRows[1], $script:memRows[0])
        Get-WtMainMenuCursor -Items $reordered | Should -Be 0
    }
}

Describe 'Only the main menu reopens where it was left' {
    BeforeEach { $script:WtMainMenuCursor = $null }

    It 'the main menu reopens on the row that pushed the child screen' {
        $items = @(Get-WtMainMenuItems)
        $privacyIdx = [array]::IndexOf(@($items | ForEach-Object Name), 'Privacy')
        $script:seen = New-Object System.Collections.Generic.List[int]
        $script:navCalls = 0
        Mock Invoke-WtListScreen {
            $script:seen.Add([int]$InitialCursor)
            $script:navCalls++
            if ($script:navCalls -eq 1) {
                return @{ Emit = 'Activate'; Char = ''; Item = @($Items)[$privacyIdx]; Selection = $Selection; CursorIndex = $privacyIdx }
            }
            return @{ Emit = 'Quit'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = $privacyIdx }
        }
        (Invoke-WtMainScreen).Nav | Should -Be 'Push'
        (Invoke-WtMainScreen).Nav | Should -Be 'Exit'
        $script:seen[0] | Should -Be -1
        $script:seen[1] | Should -Be $privacyIdx
    }

    It 'a sub-menu opens on its first row every time it is entered' {
        $items = @(
            (New-WtListItem -Kind 'Link' -Name 'ActionTools' -Label 'A' -Data @{ Screen = 'ActionTools' })
            (New-WtListItem -Kind 'Link' -Name 'InfoTools'   -Label 'B' -Data @{ Screen = 'InfoTools' })
        )
        $script:seen = New-Object System.Collections.Generic.List[int]
        Mock Invoke-WtListScreen {
            $script:seen.Add([int]$InitialCursor)
            return @{ Emit = 'Back'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = 1 }
        }
        Invoke-WtNavScreen -Breadcrumb 'Temel Araclar' -Items $items | Out-Null
        Invoke-WtNavScreen -Breadcrumb 'Temel Araclar' -Items $items | Out-Null
        $script:seen[0] | Should -Be -1
        $script:seen[1] | Should -Be -1
    }

    It 'a sub-menu neither reads nor overwrites the main menu memory' {
        $items = @(
            (New-WtListItem -Kind 'Link' -Name 'A' -Label 'A' -Data @{ Screen = 'X' })
            (New-WtListItem -Kind 'Link' -Name 'B' -Label 'B' -Data @{ Screen = 'Y' })
        )
        Set-WtMainMenuCursor -Items $items -Index 1
        $script:seen = New-Object System.Collections.Generic.List[int]
        Mock Invoke-WtListScreen {
            $script:seen.Add([int]$InitialCursor)
            return @{ Emit = 'Back'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = 0 }
        }
        Invoke-WtNavScreen -Breadcrumb 'Gizlilik' -Items $items | Out-Null
        $script:seen[0] | Should -Be -1
        Get-WtMainMenuCursor -Items $items | Should -Be 1
    }

    It 'a sub-menu keeps the cursor across an inline action, inside one visit' {
        $items = @(
            (New-WtListItem -Kind 'Link'   -Name 'A'   -Label 'A' -Data @{ Screen = 'X' })
            (New-WtListItem -Kind 'Action' -Name 'Run' -Label 'R' -Data @{ Action = { } })
        )
        $script:seen = New-Object System.Collections.Generic.List[int]
        $script:runCalls = 0
        Mock Invoke-WtListScreen {
            $script:seen.Add([int]$InitialCursor)
            $script:runCalls++
            if ($script:runCalls -eq 1) {
                return @{ Emit = 'Activate'; Char = ''; Item = @($Items)[1]; Selection = $Selection; CursorIndex = 1 }
            }
            return @{ Emit = 'Back'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = 1 }
        }
        Invoke-WtNavScreen -Breadcrumb 'Eylem Araclari' -Items $items | Out-Null
        $script:seen[0] | Should -Be -1
        $script:seen[1] | Should -Be 1
    }

    It 'Invoke-WtApplyScreen opens at the top again on the next visit' {
        $groups = @(@{
                SectionKey    = 'Services'; HeaderKey = $null
                GetCatalog    = { param($g) @(
                        [PSCustomObject]@{ Name = 'a'; DisplayLabel = 'A'; Risk = 'SAFE' }
                        [PSCustomObject]@{ Name = 'b'; DisplayLabel = 'B'; Risk = 'SAFE' }
                        [PSCustomObject]@{ Name = 'c'; DisplayLabel = 'C'; Risk = 'SAFE' }
                    ) }
                GetEntryState = { param($e, $g) @{ Applied = $false; Available = $true } }
            })
        $script:seen = New-Object System.Collections.Generic.List[int]
        Mock Invoke-WtListScreen {
            $script:seen.Add([int]$InitialCursor)
            return @{ Emit = 'Back'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = 2 }
        }
        Invoke-WtApplyScreen -Breadcrumb 'Servisler' -Groups $groups | Out-Null
        Invoke-WtApplyScreen -Breadcrumb 'Servisler' -Groups $groups | Out-Null
        $script:seen[0] | Should -Be -1
        $script:seen[1] | Should -Be -1
    }

    It 'Invoke-WtApplyScreen keeps the cursor when the list rebuilds inside one visit' {
        $groups = @(@{
                SectionKey    = 'Services'; HeaderKey = $null
                GetCatalog    = { param($g) @(
                        [PSCustomObject]@{ Name = 'a'; DisplayLabel = 'A'; Risk = 'SAFE' }
                        [PSCustomObject]@{ Name = 'b'; DisplayLabel = 'B'; Risk = 'SAFE' }
                        [PSCustomObject]@{ Name = 'c'; DisplayLabel = 'C'; Risk = 'SAFE' }
                    ) }
                GetEntryState = { param($e, $g) @{ Applied = $false; Available = $true } }
            })
        $script:seen = New-Object System.Collections.Generic.List[int]
        $script:applyCalls = 0
        Mock Invoke-WtListScreen {
            $script:seen.Add([int]$InitialCursor)
            $script:applyCalls++
            if ($script:applyCalls -eq 1) {
                return @{ Emit = 'Global'; Char = 'h'; Item = $null; Selection = $Selection; CursorIndex = 2 }
            }
            return @{ Emit = 'Back'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = 2 }
        }
        Invoke-WtApplyScreen -Breadcrumb 'Servisler' -Groups $groups -OnHotkey { param($c) $true } | Out-Null
        $script:seen[0] | Should -Be -1
        $script:seen[1] | Should -Be 2
    }

    It 'Invoke-WtUndoScreen opens at the top again on the next visit' {
        Mock Get-WtUndoScreenItems {
            return @(
                (New-WtListItem -Kind 'Action' -Name 'u1' -Label 'u1' -Data @{ EntryPath = 'p1'; Action = 'A' })
                (New-WtListItem -Kind 'Action' -Name 'u2' -Label 'u2' -Data @{ EntryPath = 'p2'; Action = 'B' })
            )
        }
        $script:seen = New-Object System.Collections.Generic.List[int]
        Mock Invoke-WtListScreen {
            $script:seen.Add([int]$InitialCursor)
            return @{ Emit = 'Back'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = 1 }
        }
        Invoke-WtUndoScreen | Out-Null
        Invoke-WtUndoScreen | Out-Null
        $script:seen[0] | Should -Be -1
        $script:seen[1] | Should -Be -1
    }

    It 'the navigation stack machine brings the main menu back on the row that opened the child' {
        $names = @(Get-WtMainMenuItems | ForEach-Object Name)
        $privacyIdx = [array]::IndexOf($names, 'Privacy')
        $script:seen = New-Object System.Collections.Generic.List[int]
        $script:mainCalls = 0
        Mock Invoke-WtScreenByKey {
            if ($Key -eq 'Main') { return Invoke-WtMainScreen }
            return @{ Nav = 'Back'; Target = ''; Char = ''; HasMarks = $false }
        }
        Mock Invoke-WtListScreen {
            $script:seen.Add([int]$InitialCursor)
            $script:mainCalls++
            if ($script:mainCalls -eq 1) {
                $row = @($Items | Where-Object { $_.Name -eq 'Privacy' })[0]
                return @{ Emit = 'Activate'; Char = ''; Item = $row; Selection = $Selection; CursorIndex = $privacyIdx }
            }
            return @{ Emit = 'Quit'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = $privacyIdx }
        }
        Invoke-WtMainLoop
        $script:seen.Count | Should -Be 2
        $script:seen[0] | Should -Be -1
        $script:seen[1] | Should -Be $privacyIdx
    }

    It 'Invoke-WtPerAppScreen returns from the apps pane onto the FIRST capability' {
        Mock Get-WtConsoleUserSid { 'S-1-5-21-1-2-3-1001' }
        Mock Get-WtAppsForCapability {
            return , @([PSCustomObject]@{ Name = 'Contoso.Cam_8wekyb3d8bbwe'; DisplayLabel = 'Contoso'; Risk = 'SAFE'; Selectable = $true })
        }
        $script:capSeen = New-Object System.Collections.Generic.List[int]
        $script:capCalls = 0
        Mock Invoke-WtListScreen {
            if (-not $MultiSelect) {
                $script:capSeen.Add($(if ($PSBoundParameters.ContainsKey('InitialCursor')) { [int]$InitialCursor } else { -1 }))
                $script:capCalls++
                if ($script:capCalls -eq 1) {
                    return @{ Emit = 'Activate'; Char = ''; Item = @($Items)[1]; Selection = $Selection; CursorIndex = 1 }
                }
                return @{ Emit = 'Back'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = 1 }
            }
            return @{ Emit = 'Back'; Char = ''; Item = $null; Selection = $Selection; CursorIndex = 0 }
        }
        Invoke-WtPerAppScreen | Out-Null
        $script:capSeen.Count | Should -Be 2
        $script:capSeen[0] | Should -Be -1
        $script:capSeen[1] | Should -Be -1
    }
}
