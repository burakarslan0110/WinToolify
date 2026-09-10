#Requires -Modules Pester

<#
.SYNOPSIS
    Coverage for the catalog-agnostic paged selector's pure logic
    (paging math, selection-by-name, ADVANCED-confirmation detection,
    non-selectable items). The Write-Host rendering and Read-Host
    interaction loop are real UI code and are not unit-tested here.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath

    function New-FakeSelectorItem($Name, $Risk = 'SAFE', $Selectable = $true) {
        [PSCustomObject]@{ Name = $Name; Risk = $Risk; Selectable = $Selectable; StateLabel = 'fake' }
    }
}

Describe 'Get-WtSelectorPage' {
    It 'has no empty final page when the catalog size is an exact multiple of the page size' {
        $items = 1..20 | ForEach-Object { New-FakeSelectorItem "Item$_" }
        $page0 = Get-WtSelectorPage -Items $items -PageIndex 0 -PageSize 10
        $page1 = Get-WtSelectorPage -Items $items -PageIndex 1 -PageSize 10

        $page0.TotalPages | Should -Be 2
        $page0.Items.Count | Should -Be 10
        $page1.Items.Count | Should -Be 10
    }

    It 'has no out-of-range index on a non-multiple catalog size (last page is partial)' {
        $items = 1..25 | ForEach-Object { New-FakeSelectorItem "Item$_" }
        $lastPage = Get-WtSelectorPage -Items $items -PageIndex 2 -PageSize 10

        $lastPage.TotalPages | Should -Be 3
        $lastPage.Items.Count | Should -Be 5
        $lastPage.Items[0].Name | Should -Be 'Item21'
        $lastPage.Items[-1].Name | Should -Be 'Item25'
    }

    It 'clamps a page index beyond the last page to the last page' {
        $items = 1..5 | ForEach-Object { New-FakeSelectorItem "Item$_" }
        $page = Get-WtSelectorPage -Items $items -PageIndex 99 -PageSize 10
        $page.PageIndex | Should -Be 0
        $page.Items.Count | Should -Be 5
    }

    It 'handles an empty catalog without throwing' {
        { Get-WtSelectorPage -Items @() -PageIndex 0 -PageSize 10 } | Should -Not -Throw
        $page = Get-WtSelectorPage -Items @() -PageIndex 0 -PageSize 10
        $page.Items.Count | Should -Be 0
    }
}

Describe 'Set-WtSelectionToggle' {
    It 'adds then removes an item by name (idempotent toggle)' {
        $selection = New-Object 'System.Collections.Generic.HashSet[string]'
        $item = New-FakeSelectorItem 'Foo'

        Set-WtSelectionToggle -SelectionSet $selection -Item $item | Out-Null
        $selection.Contains('Foo') | Should -BeTrue

        Set-WtSelectionToggle -SelectionSet $selection -Item $item | Out-Null
        $selection.Contains('Foo') | Should -BeFalse
    }

    It 'preserves a page-1 selection across navigation to page 3 and back' {
        $items = 1..30 | ForEach-Object { New-FakeSelectorItem "Item$_" }
        $selection = New-Object 'System.Collections.Generic.HashSet[string]'

        $page1 = Get-WtSelectorPage -Items $items -PageIndex 0 -PageSize 10
        Set-WtSelectionToggle -SelectionSet $selection -Item $page1.Items[0] | Out-Null

        Get-WtSelectorPage -Items $items -PageIndex 2 -PageSize 10 | Out-Null

        $backToPage1 = Get-WtSelectorPage -Items $items -PageIndex 0 -PageSize 10
        $selection.Contains($backToPage1.Items[0].Name) | Should -BeTrue
    }

    It 'refuses to add an item that is not selectable (already in target state)' {
        $selection = New-Object 'System.Collections.Generic.HashSet[string]'
        $notSelectable = New-FakeSelectorItem -Name 'AlreadyDone' -Selectable $false

        Set-WtSelectionToggle -SelectionSet $selection -Item $notSelectable | Out-Null
        $selection.Contains('AlreadyDone') | Should -BeFalse
    }
}

Describe 'Test-WtSelectionNeedsAdvancedConfirm' {
    BeforeAll {
        $script:Catalog = @(
            New-FakeSelectorItem -Name 'SafeOne' -Risk 'SAFE'
            New-FakeSelectorItem -Name 'CautionOne' -Risk 'CAUTION'
            New-FakeSelectorItem -Name 'AdvancedOne' -Risk 'ADVANCED'
        )
    }

    It 'returns $false for an empty selection' {
        Test-WtSelectionNeedsAdvancedConfirm -Catalog $Catalog -SelectionSet @() | Should -BeFalse
    }

    It 'returns $false when the selection has only SAFE/CAUTION items' {
        Test-WtSelectionNeedsAdvancedConfirm -Catalog $Catalog -SelectionSet @('SafeOne', 'CautionOne') | Should -BeFalse
    }

    It 'returns $true only when the selection contains at least one ADVANCED item' {
        Test-WtSelectionNeedsAdvancedConfirm -Catalog $Catalog -SelectionSet @('SafeOne', 'AdvancedOne') | Should -BeTrue
    }
}
