#Requires -Modules Pester

<#
.SYNOPSIS
    The curated winget catalog: shape, uniqueness, category coverage and
    the local name+tag filter. The winget ids themselves are verified
    against a live winget by hand, not here.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
    $script:Cats = @(Get-WtWingetStoreCategories)
    $script:Apps = @(Get-WtWingetStoreCatalog)
}

Describe 'Get-WtWingetStoreCategories' {
    It 'is exactly the ten fixed columns the grid draws' {
        $Cats.Count | Should -Be 10
        $Cats.Key   | Should -Be @('Browsers', 'Dev', 'Comms', 'Document', 'Games', 'Microsoft', 'Media', 'ProTools', 'Selfhosted', 'Utilities')
    }

    It 'names every column through a translation key' {
        foreach ($c in $Cats) { $c.LabelKey | Should -Not -BeNullOrEmpty }
    }
}

Describe 'Get-WtWingetStoreCatalog' {
    It 'has no duplicate winget id - the id is the install and match key' {
        $ids = @($Apps.Id)
        ($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
    }

    It 'puts every app in one of the ten categories' {
        $keys = @($Cats.Key)
        foreach ($a in $Apps) { $keys | Should -Contain $a.Category }
    }

    It 'fills every column - an empty category would draw a blank grid column' {
        foreach ($c in $Cats) {
            @($Apps | Where-Object { $_.Category -eq $c.Key }).Count | Should -BeGreaterThan 5
        }
    }

    It 'has at least one app in every category' {
        foreach ($c in $Cats) {
            @($Apps | Where-Object { $_.Category -eq $c.Key }).Count | Should -BeGreaterThan 0
        }
    }

    It 'ships the catalog this pass actually grew to' {
        $Apps.Count | Should -Be 252
    }

    It 'gives every app a display name and search tags' {
        foreach ($a in $Apps) {
            $a.Name | Should -Not -BeNullOrEmpty
            $a.Tags | Should -Not -BeNullOrEmpty
            $a.Id   | Should -Match '\.'      # winget ids are Publisher.Package
        }
    }

    It 'keeps names inside the narrowest five-column cell without gibberish' {
        foreach ($a in $Apps) { ([string]$a.Name).Length | Should -BeLessOrEqual 20 }
    }
}

Describe 'Select-WtWingetStoreApps' {
    It 'returns everything for an empty query' {
        (Select-WtWingetStoreApps -Apps $Apps -Query '').Count | Should -Be $Apps.Count
    }

    It 'matches on the display name' {
        $hit = @(Select-WtWingetStoreApps -Apps $Apps -Query 'firefox')
        $hit.Id | Should -Contain 'Mozilla.Firefox'
    }

    It 'matches on the hidden tags, which is what they exist for' {
        $browserCount = @($Apps | Where-Object { $_.Category -eq 'Browsers' }).Count
        $hit = @(Select-WtWingetStoreApps -Apps $Apps -Query 'tarayici')
        $hit.Count | Should -BeGreaterOrEqual $browserCount
    }

    It 'matches on the winget id' {
        $hit = @(Select-WtWingetStoreApps -Apps $Apps -Query 'VideoLAN')
        $hit.Id | Should -Contain 'VideoLAN.VLC'
    }

    It 'is case insensitive without tripping over the Turkish dotless i' {
        $upper = @(Select-WtWingetStoreApps -Apps $Apps -Query 'ILETISIM')
        $lower = @(Select-WtWingetStoreApps -Apps $Apps -Query 'iletisim')
        $upper.Count | Should -Be 17
        $lower.Count | Should -Be 17
    }
}
