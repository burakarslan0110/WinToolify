#Requires -Modules Pester

<#
.SYNOPSIS
    The store frame composer: cell segments, the flowed row list drawn as a
    whole screen, and the table composer. Pure - Write-WtFrame only prints
    what these return.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
    $script:Glyphs = Get-WtGlyphSet -Unicode $false

    function Get-RowText($Row) { (@($Row) | ForEach-Object { [string]$_.T }) -join '' }
    function Get-FrameText($Rows) { (@($Rows) | ForEach-Object { Get-RowText $_ }) -join "`n" }
}

Describe 'Get-WtStoreChromeHeight' {
    It 'counts the shared banner header, so it varies with the console width' {
        Get-WtStoreChromeHeight -Layout 'Grid' -Width 120 | Should -Be 21
        Get-WtStoreChromeHeight -Layout 'Grid' -Width 80  | Should -Be 13
        Get-WtStoreChromeHeight -Layout 'Grid' -Width 89  | Should -Be 21
        Get-WtStoreChromeHeight -Layout 'Grid' -Width 88  | Should -Be 13
    }

    It 'spends eight box rows on the grid and ten on the installed table, which has its own search row' {
        Get-WtStoreChromeHeight -Layout 'Grid'  -Width 120 | Should -Be 21
        Get-WtStoreChromeHeight -Layout 'Table' -Width 120 | Should -Be 23
        Get-WtStoreChromeHeight -Layout 'Table' -Width 80  | Should -Be 15
    }

    It 'spends three more on the results page - search row, separator, query heading' {
        Get-WtStoreChromeHeight -Layout 'Results' -Width 120 | Should -Be 24
        Get-WtStoreChromeHeight -Layout 'Results' -Width 80  | Should -Be 16
    }

    It 'defaults to the table layout' {
        Get-WtStoreChromeHeight -Width 120 | Should -Be 23
        Get-WtStoreChromeHeight -Width 120 | Should -Be (Get-WtStoreChromeHeight -Layout 'Table' -Width 120)
    }
}

Describe 'Get-WtStoreHeaderRows' {
    It 'draws the block banner, the credit and the repository URL, exactly as every other screen does' {
        $rows = Get-WtStoreHeaderRows -Width 120
        @($rows).Count | Should -Be 13
        $text = Get-FrameText $rows
        $text | Should -BeLike '*https://github.com/burakarslan0110/WinToolify*'
        $text | Should -BeLike '*Created by Burak Arslan*'
        $text | Should -BeLike '*+=====*'
    }

    It 'falls back to the one-line brand below 89 columns, like Get-WtBannerLines' {
        $rows = Get-WtStoreHeaderRows -Width 80
        @($rows).Count | Should -Be 5
        (Get-FrameText $rows) | Should -BeLike '*WinToolify V2*'
        (Get-FrameText $rows) | Should -Not -BeLike '*+=====*'
    }

    It 'owns exactly Width-1 columns on every row so no header row can wrap' {
        foreach ($w in 120, 100, 89, 88, 70) {
            foreach ($row in (Get-WtStoreHeaderRows -Width $w)) {
                (Get-RowText $row).Length | Should -Be ($w - 1) -Because "width $w"
            }
        }
    }
}

Describe 'Get-WtStoreCellSegments' {
    It 'shows an unmarked app with an empty checkbox' {
        $segs = Get-WtStoreCellSegments -Cell @{ Kind = 'App'; Id = 'A.B'; Name = 'Firefox' } `
            -NameWidth 10 -IsCursor $false -Marked $false -Installed $false -Glyphs $Glyphs
        (Get-RowText $segs) | Should -BeLike '`[ `] Firefox*'
    }

    It 'shows a marked app with a filled checkbox' {
        $segs = Get-WtStoreCellSegments -Cell @{ Kind = 'App'; Id = 'A.B'; Name = 'Firefox' } `
            -NameWidth 10 -IsCursor $false -Marked $true -Installed $false -Glyphs $Glyphs
        (Get-RowText $segs) | Should -BeLike '`[x`] Firefox*'
    }

    It 'paints an installed app green so the state is visible without a legend' {
        $segs = Get-WtStoreCellSegments -Cell @{ Kind = 'App'; Id = 'A.B'; Name = 'Firefox' } `
            -NameWidth 10 -IsCursor $false -Marked $false -Installed $true -Glyphs $Glyphs
        (@($segs | Where-Object { $_.F -eq 'Green' })).Count | Should -BeGreaterThan 0
    }

    It 'pads every cell to exactly the cell width so the rows stay aligned' {
        $segs = Get-WtStoreCellSegments -Cell @{ Kind = 'App'; Id = 'A.B'; Name = 'X' } `
            -NameWidth 10 -IsCursor $false -Marked $false -Installed $false -Glyphs $Glyphs
        (Get-RowText $segs).Length | Should -Be 14
    }

    It 'truncates a name that cannot fit instead of pushing the next cell along' {
        $segs = Get-WtStoreCellSegments -Cell @{ Kind = 'App'; Id = 'A.B'; Name = 'Visual Studio Community' } `
            -NameWidth 9 -IsCursor $false -Marked $false -Installed $false -Glyphs $Glyphs
        (Get-RowText $segs).Length | Should -Be 13
        (Get-RowText $segs) | Should -BeLike '*~*'
    }
}

Describe 'Get-WtStoreFrameRows' {
    BeforeAll {
        $script:Labels = @{ Browsers = 'Tarayicilar'; Dev = 'Gelistirme'; Media = 'Medya'; Comms = 'Iletisim'; Utilities = 'Yardimci' }
        $script:Apps = @(
            [PSCustomObject]@{ Id = 'M.F'; Name = 'Firefox'; Category = 'Browsers' }
            [PSCustomObject]@{ Id = 'G.C'; Name = 'Chrome';  Category = 'Browsers' }
            [PSCustomObject]@{ Id = 'G.G'; Name = 'Git';     Category = 'Dev' }
        )
        $script:Keys = @('Browsers', 'Dev', 'Media', 'Comms', 'Utilities')
        $script:GridRows = Get-WtStoreGridRows -Apps $Apps -CategoryKeys $Keys -CellsPerRow 5 -CategoryLabels $Labels
    }

    It 'owns every console row so nothing from the previous screen survives' {
        $rows = Get-WtStoreFrameRows -State (New-WtStoreState) -Rows $GridRows `
            -Width 120 -Height 40 -Glyphs $Glyphs -FooterText 'x'
        @($rows).Count | Should -Be 40
    }

    It 'holds its contract at every width the tool supports, and on a short console' {
        foreach ($pair in @(@(120, 40), @(100, 40), @(80, 40), @(70, 24), @(120, 12))) {
            $w = $pair[0]
            $h = $pair[1]
            $geo = Get-WtGridGeometry -Inner ([Math]::Max(20, $w - 1) - 4)
            $flowed = Get-WtStoreGridRows -Apps $Apps -CategoryKeys $Keys -CellsPerRow $geo.ColumnCount -CategoryLabels $Labels
            $rows = Get-WtStoreFrameRows -State (New-WtStoreState) -Rows $flowed `
                -Width $w -Height $h -Glyphs $Glyphs -FooterText 'x'
            @($rows).Count | Should -Be $h -Because "width $w height $h"
            foreach ($row in $rows) {
                (Get-RowText $row).Length | Should -BeLessOrEqual ($w - 1) -Because "width $w height $h"
            }
            $last = Get-RowText ($rows | Select-Object -Last 1)
            $last.Substring(0, 1) | Should -Be $Glyphs.BL -Because "width $w height $h"
            $last.Substring($last.Length - 1, 1) | Should -Be $Glyphs.BR -Because "width $w height $h"
        }
    }

    It 'draws each category heading as a full-width row, with its app count' {
        $rows = Get-WtStoreFrameRows -State (New-WtStoreState) -Rows $GridRows `
            -Width 120 -Height 40 -Glyphs $Glyphs -FooterText 'x'
        $head = @($rows | ForEach-Object { Get-RowText $_ } | Where-Object { $_ -like '*Tarayicilar*' })
        $head.Count | Should -Be 1 -Because 'the chrome title row is gone - the heading is a row of the list'
        $head[0] | Should -BeLike '*Tarayicilar (2)*'
        $head[0].Length | Should -Be 119
        $head[0] | Should -BeLike "*$($Glyphs.H)$($Glyphs.H)$($Glyphs.H)*"
    }

    It 'names an empty category nowhere at all - it has no rows to draw' {
        $rows = Get-WtStoreFrameRows -State (New-WtStoreState) -Rows $GridRows `
            -Width 120 -Height 40 -Glyphs $Glyphs -FooterText 'x'
        $text = Get-FrameText $rows
        $text | Should -BeLike '*Gelistirme*'
        foreach ($absent in 'Medya', 'Iletisim', 'Yardimci', 'Browsers', 'Utilities') {
            $text | Should -Not -BeLike "*$absent*" -Because "$absent has no apps and no rows"
        }
    }

    It 'flows the apps of one category across a row, in reading order' {
        $rows = Get-WtStoreFrameRows -State (New-WtStoreState) -Rows $GridRows `
            -Width 120 -Height 40 -Glyphs $Glyphs -FooterText 'x'
        $cells = @($rows | ForEach-Object { Get-RowText $_ } | Where-Object { $_ -like '*Firefox*' })
        $cells.Count | Should -Be 1
        $cells[0] | Should -BeLike '*Firefox*Chrome*' -Because 'both browsers share one row, left to right'
        $cells[0] | Should -Not -BeLike '*Git*' -Because 'Git belongs to the next category, under its own heading'
    }

    It 'marks the active tab so the user can see which list they are in' {
        $s = New-WtStoreState
        $s.Tab = 'Installed'
        $rows = Get-WtStoreFrameRows -State $s -Rows $GridRows `
            -Width 120 -Height 40 -Glyphs $Glyphs -FooterText 'x' `
            -TabLabels @{ Store = 'Magaza'; Search = 'Arama'; Installed = 'Kurulu' }
        (Get-FrameText $rows) | Should -BeLike '*[Kurulu]*'
    }

    It 'draws exactly two tabs - the Search tab is gone from the bar' {
        $rows = Get-WtStoreFrameRows -State (New-WtStoreState) -Rows $GridRows `
            -Width 120 -Height 40 -Glyphs $Glyphs -FooterText 'x' `
            -TabLabels @{ Store = 'Magaza'; Search = 'Arama'; Installed = 'Kurulu' }
        $bar = @($rows | ForEach-Object { Get-RowText $_ } | Where-Object { $_ -like '*Magaza*' })
        $bar.Count | Should -Be 1
        $bar[0] | Should -BeLike '*[Magaza]*'
        $bar[0] | Should -BeLike '*Kurulu*'
        $bar[0] | Should -Not -BeLike '*Arama*' -Because 'the Search tab was removed entirely'
    }

    It 'keeps the search box on a row of its own whether or not it has focus' {
        $blur = New-WtStoreState
        $blur.Query = 'vlc'
        $focus = New-WtStoreState
        $focus.Focus = 'Input'; $focus.Query = 'vlc'
        $blurRows = Get-WtStoreFrameRows -State $blur -Rows $GridRows `
            -Width 120 -Height 40 -Glyphs $Glyphs -FooterText 'x'
        $focusRows = Get-WtStoreFrameRows -State $focus -Rows $GridRows `
            -Width 120 -Height 40 -Glyphs $Glyphs -FooterText 'x'
        foreach ($set in @($blurRows, $focusRows)) {
            (Get-FrameText $set) | Should -BeLike '*Search apps: vlc*'
            @($set).Count | Should -Be 40
            foreach ($row in $set) { (Get-RowText $row).Length | Should -BeLessOrEqual 119 }
        }
        (Get-FrameText $focusRows) | Should -BeLike '*vlc_*'
        (Get-FrameText $blurRows)  | Should -Not -BeLike '*vlc_*'
        $blurAt = 0
        for ($i = 0; $i -lt @($blurRows).Count; $i++) { if ((Get-RowText $blurRows[$i]) -like '*Tarayicilar*') { $blurAt = $i } }
        $focusAt = 0
        for ($i = 0; $i -lt @($focusRows).Count; $i++) { if ((Get-RowText $focusRows[$i]) -like '*Tarayicilar*') { $focusAt = $i } }
        $blurAt | Should -BeGreaterThan 0
        $focusAt | Should -Be $blurAt
    }

    It 'right-aligns the catalog total, and the match count while a query is active' {
        $s = New-WtStoreState
        $s.Query = 'fir'
        $rows = Get-WtStoreFrameRows -State $s -Rows $GridRows `
            -Width 120 -Height 40 -Glyphs $Glyphs -FooterText 'x' `
            -SearchCountText '252 uygulama - 3 sonuc'
        $box = @($rows | ForEach-Object { Get-RowText $_ } | Where-Object { $_ -like '*Search apps: fir*' })
        $box.Count | Should -Be 1
        $box[0] | Should -BeLike '*252 uygulama - 3 sonuc*'
        $box[0].TrimEnd().TrimEnd($Glyphs.V).TrimEnd() | Should -BeLike '*252 uygulama - 3 sonuc'
    }

    It 'draws the banner and the repository URL above the box, like every other screen' {
        $rows = Get-WtStoreFrameRows -State (New-WtStoreState) -Rows $GridRows `
            -Width 120 -Height 40 -Glyphs $Glyphs -FooterText 'x'
        $text = Get-FrameText $rows
        $text | Should -BeLike '*https://github.com/burakarslan0110/WinToolify*'
        $text | Should -BeLike '*Created by Burak Arslan*'
        $text | Should -BeLike '*+=====*'
        $topAt = -1
        for ($i = 0; $i -lt @($rows).Count; $i++) {
            if ($topAt -lt 0 -and (Get-RowText $rows[$i]).StartsWith($Glyphs.TL)) { $topAt = $i }
        }
        $topAt | Should -Be 13 -Because 'nine banner rows, a blank, the credit, the URL and a blank sit above it'
    }

    It 'highlights the cell the cursor stands on, and only that one' {
        $s = New-WtStoreState
        $s.Cursor = @{ Row = 1; Col = 1 }
        $rows = Get-WtStoreFrameRows -State $s -Rows $GridRows `
            -Width 120 -Height 40 -Glyphs $Glyphs -FooterText 'x'
        $hit = @($rows | ForEach-Object { @($_) } | Where-Object { $_.B -eq 'DarkCyan' })
        $hit.Count | Should -Be 1
        $hit[0].T | Should -BeLike '*Chrome*'
    }

    It 'survives an empty row list - a query that matched nothing' {
        $empty = Get-WtStoreGridRows -Apps @() -CategoryKeys $Keys -CellsPerRow 5 -CategoryLabels $Labels
        $rows = Get-WtStoreFrameRows -State (New-WtStoreState) -Rows $empty `
            -Width 100 -Height 20 -Glyphs $Glyphs -FooterText 'x'
        @($rows).Count | Should -Be 20
        foreach ($row in $rows) { (Get-RowText $row).Length | Should -Be 99 }
    }

    It 'closes the box - the last row is the bottom border, not an open frame' {
        $rows = Get-WtStoreFrameRows -State (New-WtStoreState) -Rows $GridRows `
            -Width 100 -Height 20 -Glyphs $Glyphs -FooterText 'x'
        $last = Get-RowText ($rows | Select-Object -Last 1)
        $last.Substring(0, 1) | Should -Be $Glyphs.BL
        $last.Substring($last.Length - 1, 1) | Should -Be $Glyphs.BR
        $middle = $last.Substring(1, $last.Length - 2)
        $middle | Should -Be ($Glyphs.H * $middle.Length)
    }
}

Describe 'Get-WtStoreTableLayout' {
    It 'gives the id column real room - it is what the user copies' {
        $l = Get-WtStoreTableLayout -Inner 115 -ShowAvailable $false
        ($l.NameWidth + $l.IdWidth + $l.VersionWidth) | Should -BeLessOrEqual 115
        $l.IdWidth | Should -BeGreaterThan 20
    }

    It 'makes room for the available-version column on the installed tab' {
        $with = Get-WtStoreTableLayout -Inner 115 -ShowAvailable $true
        $without = Get-WtStoreTableLayout -Inner 115 -ShowAvailable $false
        $with.AvailableWidth | Should -BeGreaterThan 0
        $without.AvailableWidth | Should -Be 0
        $with.NameWidth | Should -BeLessThan $without.NameWidth
    }

    It 'never returns a negative width on a narrow console' {
        $l = Get-WtStoreTableLayout -Inner 30 -ShowAvailable $true
        foreach ($k in 'NameWidth', 'IdWidth', 'VersionWidth', 'AvailableWidth') {
            $l[$k] | Should -BeGreaterOrEqual 0
        }
    }
}

Describe 'Get-WtStoreTableRows' {
    BeforeAll {
        $script:TableRows = @(
            @{ Name = '7-Zip';   Id = '7zip.7zip';       Version = '23.01'; Available = '24.09' }
            @{ Name = 'Firefox'; Id = 'Mozilla.Firefox'; Version = '129.0'; Available = '' }
        )
        $script:Heads = @{ Name = 'Ad'; Id = 'Kimlik'; Version = 'Surum'; Available = 'Yeni' }
    }

    It 'owns every console row' {
        $s = New-WtStoreState; $s.Tab = 'Installed'
        $rows = Get-WtStoreTableRows -State $s -Rows $TableRows -Width 120 -Height 30 `
            -Glyphs $Glyphs -Headers $Heads -FooterText 'x'
        @($rows).Count | Should -Be 30
        foreach ($row in $rows) { (Get-RowText $row).Length | Should -BeLessOrEqual 119 }
    }

    It 'prints the id and the version of every row' {
        $s = New-WtStoreState; $s.Tab = 'Installed'
        $rows = Get-WtStoreTableRows -State $s -Rows $TableRows -Width 120 -Height 30 `
            -Glyphs $Glyphs -Headers $Heads -FooterText 'x'
        $text = Get-FrameText $rows
        $text | Should -BeLike '*7zip.7zip*'
        $text | Should -BeLike '*24.09*'
    }

    It 'shows an empty-result message instead of a blank box' {
        $s = New-WtStoreState; $s.Mode = 'Results'
        $rows = Get-WtStoreTableRows -State $s -Rows @() -Width 120 -Height 30 `
            -Glyphs $Glyphs -Headers $Heads -FooterText 'x' -EmptyText 'Sonuc yok'
        (Get-FrameText $rows) | Should -BeLike '*Sonuc yok*'
    }

    It 'draws no rule of its own next to the box separator under the column header' {
        $s = New-WtStoreState; $s.Tab = 'Installed'
        $rows = Get-WtStoreTableRows -State $s -Rows $TableRows -Width 120 -Height 30 `
            -Glyphs $Glyphs -Headers $Heads -TabLabels @{ Store = 'Magaza'; Installed = 'Kurulu' } -FooterText 'x'
        $texts = @($rows | ForEach-Object { Get-RowText $_ })
        $headerAt = -1
        for ($i = 0; $i -lt $texts.Count; $i++) { if ($headerAt -lt 0 -and $texts[$i] -like "*$($Heads.Id)*") { $headerAt = $i } }
        $headerAt | Should -BeGreaterThan 0 -Because 'the column header row must be findable'
        $texts[$headerAt + 1].StartsWith($Glyphs.LT) | Should -BeTrue -Because 'the box separator follows the header'
        $texts[$headerAt + 2] | Should -BeLike '*7zip.7zip*' -Because 'data follows the separator, not a second rule'
        for ($i = 1; $i -lt $texts.Count; $i++) {
            $prev = $texts[$i - 1]
            $body = $texts[$i]
            if (-not $body.StartsWith($Glyphs.V)) { continue }
            $stripped = $body.Trim($Glyphs.V).Trim()
            if ($stripped.Length -lt 4) { continue }
            $isRule = ($stripped -eq ($Glyphs.H * $stripped.Length))
            $nextTo = ($prev.StartsWith($Glyphs.LT) -or $prev.StartsWith($Glyphs.TL))
            ($isRule -and $nextTo) | Should -BeFalse -Because "row $i must not be a rule drawn against a box separator"
        }
    }

    It 'gives the results page its own search row and a heading naming the query' {
        $s = New-WtStoreState; $s.Mode = 'Results'; $s.Query = 'vlc'
        $rows = Get-WtStoreTableRows -State $s -Rows $TableRows -Width 120 -Height 30 `
            -Glyphs $Glyphs -Headers $Heads -TabLabels @{ Store = 'Magaza'; Installed = 'Kurulu' } `
            -FooterText 'x' -SearchCountText '252 uygulama - 2 sonuc' -HeadingText "Winget sonuclari: 'vlc'" `
            -EmptyText 'yok'
        $text = Get-FrameText $rows
        $text | Should -BeLike "*Winget sonuclari: 'vlc'*"
        $text | Should -BeLike '*Search apps: vlc*'
        $text | Should -BeLike '*252 uygulama - 2 sonuc*'
        $text | Should -Not -BeLike '*vlc_*' -Because 'the caret marks focus, and the box does not have it here'
        $text | Should -BeLike '*[Magaza]*'
        @($rows).Count | Should -Be 30
    }

    It 'draws the search row on the installed tab from ITS query - never the store query - with the caret while focused' {
        $s = New-WtStoreState; $s.Tab = 'Installed'; $s.Query = 'vlc'; $s.InstalledQuery = 'git'; $s.Focus = 'Input'
        $rows = Get-WtStoreTableRows -State $s -Rows $TableRows -Width 120 -Height 30 `
            -Glyphs $Glyphs -Headers $Heads -TabLabels @{ Store = 'Magaza'; Installed = 'Kurulu' } `
            -FooterText 'x' -SearchCountText '67 uygulama - 3 sonuc'
        $text = Get-FrameText $rows
        $text | Should -BeLike '*Search apps: git_*'
        $text | Should -Not -BeLike '*vlc*'
        $text | Should -BeLike '*67 uygulama - 3 sonuc*'
        $text.Contains('[Kurulu]') | Should -BeTrue
        @($rows).Count | Should -Be 30
        $lines = @($rows | ForEach-Object { Get-RowText $_ })
        $lines[16] | Should -BeLike '*Search apps: git_*'
        $lines[17] | Should -Match '^\+-+\+$'
        $lines[18] | Should -BeLike ('*' + [string]$Heads['Name'] + '*')
        $s.Focus = 'Grid'
        $rows2 = Get-WtStoreTableRows -State $s -Rows $TableRows -Width 120 -Height 30 `
            -Glyphs $Glyphs -Headers $Heads -FooterText 'x'
        (Get-FrameText $rows2) | Should -BeLike '*Search apps: git *'
        (Get-FrameText $rows2) | Should -Not -BeLike '*git_*'
    }

    It 'names the installed tab "Installed Apps", tells the / key on its guide and has a guide for its box, in both languages' {
        foreach ($lang in 'TR', 'EN') {
            $t = $script:Translations[$lang]
            $t['WsFooterInstalled'] | Should -Match '/' -Because $lang
            $t['WsFooterInputInstalled'] | Should -Not -BeNullOrEmpty -Because $lang
            $t['WsFooterInputInstalled'] | Should -Not -Match 'inget' -Because 'Enter on the installed box never asks winget'
        }
        $script:Translations['TR']['WsTabInstalled'] | Should -Be 'Kurulu Uygulamalar'
        $script:Translations['EN']['WsTabInstalled'] | Should -Be 'Installed Apps'
    }

    It 'draws the banner and the repository URL above the box here too' {
        $s = New-WtStoreState; $s.Tab = 'Installed'
        $rows = Get-WtStoreTableRows -State $s -Rows $TableRows -Width 120 -Height 30 `
            -Glyphs $Glyphs -Headers $Heads -FooterText 'x'
        $text = Get-FrameText $rows
        $text | Should -BeLike '*https://github.com/burakarslan0110/WinToolify*'
        $text | Should -BeLike '*Created by Burak Arslan*'
    }

    It 'holds Count == Height and a closed box on both table pages, at every width' {
        foreach ($pair in @(@(120, 40), @(100, 30), @(80, 24), @(70, 24), @(120, 12))) {
            $w = $pair[0]
            $h = $pair[1]
            foreach ($mode in 'Catalog', 'Results') {
                $s = New-WtStoreState
                if ($mode -eq 'Results') { $s.Mode = 'Results'; $s.Query = 'vlc' } else { $s.Tab = 'Installed' }
                $bodies = New-Object 'object[]' 2
                $bodies[0] = $TableRows
                $bodies[1] = @()
                foreach ($body in $bodies) {
                    $rows = Get-WtStoreTableRows -State $s -Rows $body -Width $w -Height $h `
                        -Glyphs $Glyphs -Headers $Heads -FooterText 'x' -EmptyText 'yok'
                    @($rows).Count | Should -Be $h -Because "$mode width $w height $h"
                    foreach ($row in $rows) {
                        (Get-RowText $row).Length | Should -BeLessOrEqual ($w - 1) -Because "$mode width $w height $h"
                    }
                    $last = Get-RowText ($rows | Select-Object -Last 1)
                    $last.Substring(0, 1) | Should -Be $Glyphs.BL -Because "$mode width $w height $h"
                    $last.Substring($last.Length - 1, 1) | Should -Be $Glyphs.BR -Because "$mode width $w height $h"
                }
            }
        }
    }

    It 'closes the box - the last row is the bottom border, not an open frame' {
        $s = New-WtStoreState; $s.Tab = 'Installed'
        $rows = Get-WtStoreTableRows -State $s -Rows $TableRows -Width 100 -Height 20 `
            -Glyphs $Glyphs -Headers $Heads -FooterText 'x'
        $last = Get-RowText ($rows | Select-Object -Last 1)
        $last.Substring(0, 1) | Should -Be $Glyphs.BL
        $last.Substring($last.Length - 1, 1) | Should -Be $Glyphs.BR
        $middle = $last.Substring(1, $last.Length - 2)
        $middle | Should -Be ($Glyphs.H * $middle.Length)
    }

    It 'puts the cursor on the row Get-WtStoreListRows would point the reducer at' {
        $s = New-WtStoreState; $s.Tab = 'Installed'
        $s.Cursor = @{ Row = 1; Col = 0 }
        $nav = Get-WtStoreListRows -Rows $TableRows
        (Get-WtStoreCursorCell -State $s -Rows $nav).Id | Should -Be 'Mozilla.Firefox'
        $rows = Get-WtStoreTableRows -State $s -Rows $TableRows -Width 120 -Height 30 `
            -Glyphs $Glyphs -Headers $Heads -FooterText 'x'
        $hit = @($rows | ForEach-Object { @($_) } | Where-Object { $_.B -eq 'DarkCyan' })
        ($hit | ForEach-Object { [string]$_.T }) -join '' | Should -BeLike '*Mozilla.Firefox*'
    }
}

Describe 'Store frame mark counter' {
    BeforeAll {
        $script:CounterRows = Get-WtStoreGridRows `
            -Apps @([PSCustomObject]@{ Id = 'M.F'; Name = 'Firefox'; Category = 'Browsers' }) `
            -CategoryKeys @('Browsers', 'Dev', 'Media', 'Comms', 'Utilities') -CellsPerRow 5
    }

    It 'draws the counter the caller supplies, not a bare number' {
        $s = New-WtStoreState
        foreach ($id in 'a', 'b') { $null = $s.Marks.Add($id) }
        $rows = Get-WtStoreFrameRows -State $s -Rows $CounterRows -Width 120 -Height 40 `
            -Glyphs $Glyphs -FooterText 'x' -CounterText '2 isaretli'
        $title = @($rows | ForEach-Object { Get-RowText $_ } | Where-Object { $_ -like '*isaretli*' })
        $title.Count | Should -Be 1
        $title[0].TrimEnd().TrimEnd($Glyphs.V).TrimEnd() | Should -BeLike '*2 isaretli'
    }

    It 'draws the same counter on the table tabs' {
        $s = New-WtStoreState
        $s.Tab = 'Installed'
        $null = $s.Marks.Add('a')
        $rows = Get-WtStoreTableRows -State $s -Rows @() -Width 120 -Height 30 `
            -Glyphs $Glyphs -FooterText 'x' -CounterText '1 isaretli' -EmptyText 'yok'
        (Get-FrameText $rows) | Should -BeLike '*1 isaretli*'
    }

    It 'has a WsMarked key with one placeholder in both languages' {
        foreach ($lang in 'EN', 'TR') {
            $script:Translations[$lang]['WsMarked'] | Should -Not -BeNullOrEmpty
            $script:Translations[$lang]['WsMarked'] | Should -BeLike '*{0}*'
        }
        ($script:Translations['TR']['WsMarked'] -f 8) | Should -Be '8 isaretli'
    }
}

Describe 'Store frame breadcrumb' {
    BeforeAll {
        $script:BreadCrumbLabels = @{ Store = 'Magaza'; Installed = 'Kurulu' }
    }

    It 'draws the breadcrumb left of the tab bar, with the active tab marked' {
        $rows = Get-WtStoreFrameRows -State (New-WtStoreState) -Rows $GridRows `
            -Width 120 -Height 40 -Glyphs $Glyphs -FooterText 'x' `
            -Breadcrumb 'Main Menu > Winget Store' -TabLabels $BreadCrumbLabels
        $bar = @($rows | ForEach-Object { Get-RowText $_ } | Where-Object { $_ -like '*Main Menu > Winget Store*' })
        $bar.Count | Should -Be 1
        $bar[0] | Should -BeLike '*[Magaza]*'
        $bar[0] | Should -BeLike '*Kurulu*'
        $bar[0].IndexOf('Main Menu') | Should -BeLessThan $bar[0].IndexOf('[Magaza]')
    }

    It 'draws the same breadcrumb row on the table composer' {
        $s = New-WtStoreState; $s.Tab = 'Installed'
        $rows = Get-WtStoreTableRows -State $s -Rows @() -Width 120 -Height 30 `
            -Glyphs $Glyphs -FooterText 'x' -Breadcrumb 'Main Menu > Winget Store' -TabLabels $BreadCrumbLabels -EmptyText 'yok'
        $bar = @($rows | ForEach-Object { Get-RowText $_ } | Where-Object { $_ -like '*Main Menu > Winget Store*' })
        $bar.Count | Should -Be 1
        $bar[0] | Should -BeLike '*[Kurulu]*'
    }

    It 'truncates the breadcrumb, never the tabs, on a console too narrow for both' {
        $longCrumb = 'Main Menu > Winget Store Screen With An Extremely Long Breadcrumb Trail That Cannot Possibly Fit'
        $rows = Get-WtStoreFrameRows -State (New-WtStoreState) -Rows $GridRows `
            -Width 40 -Height 24 -Glyphs $Glyphs -FooterText 'x' `
            -Breadcrumb $longCrumb -TabLabels $BreadCrumbLabels
        $bar = @($rows | ForEach-Object { Get-RowText $_ } | Where-Object { $_ -like '*Kurulu*' })
        $bar.Count | Should -Be 1
        $bar[0] | Should -BeLike '*[Magaza]*' -Because 'both tabs must survive untouched'
        $bar[0] | Should -BeLike '*Kurulu*' -Because 'both tabs must survive untouched'
        $bar[0] | Should -Not -BeLike "*$longCrumb*" -Because 'the full breadcrumb cannot fit'
        $bar[0] | Should -BeLike '*~*' -Because 'the breadcrumb, not the tabs, gives way and gets cut'
        $bar[0].Length | Should -BeLessOrEqual 39
    }

    It 'puts the captioned tab switch right after the breadcrumb, the mark counter alone on the right' {
        $rows = Get-WtStoreFrameRows -State (New-WtStoreState) -Rows $GridRows `
            -Width 160 -Height 40 -Glyphs $Glyphs -FooterText 'x' -CounterText '234 isaretli' `
            -Breadcrumb 'Main Menu > Winget Store' -TabLabels $BreadCrumbLabels -TabCaption 'Sekme'
        $bar = @($rows | ForEach-Object { Get-RowText $_ } | Where-Object { $_ -like '*Main Menu > Winget Store*' })
        $bar.Count | Should -Be 1
        $bar[0].Contains('Main Menu > Winget Store   Sekme: [Magaza]  Kurulu ') | Should -BeTrue -Because $bar[0]
        $bar[0].TrimEnd().TrimEnd($Glyphs.V).TrimEnd() | Should -BeLike '*234 isaretli'
        $bar[0].IndexOf('234 isaretli') - $bar[0].IndexOf('Kurulu') | Should -BeGreaterThan 20
    }

    It 'colours the active tab white and the caption and the idle tab dark, on both composers' {
        $grid = Get-WtStoreFrameRows -State (New-WtStoreState) -Rows $GridRows `
            -Width 120 -Height 40 -Glyphs $Glyphs -FooterText 'x' -Breadcrumb 'B' -TabLabels $BreadCrumbLabels -TabCaption 'Sekme'
        $row = @($grid | Where-Object { (Get-RowText $_).Contains('[Magaza]') })[0]
        (@($row) | Where-Object { $_.T -eq '[Magaza]' }).F | Should -Be 'White'
        (@($row) | Where-Object { $_.T -like '*Kurulu*' }).F | Should -Be 'DarkGray'
        (@($row) | Where-Object { $_.T -like '*Sekme:*' }).F | Should -Be 'DarkGray'
        $s = New-WtStoreState; $s.Tab = 'Installed'
        $table = Get-WtStoreTableRows -State $s -Rows @() -Width 120 -Height 30 `
            -Glyphs $Glyphs -FooterText 'x' -Breadcrumb 'B' -TabLabels $BreadCrumbLabels -TabCaption 'Sekme' -EmptyText 'yok'
        $row2 = @($table | Where-Object { (Get-RowText $_).Contains('[Kurulu]') })[0]
        (@($row2) | Where-Object { $_.T -eq '[Kurulu]' }).F | Should -Be 'White'
        (Get-RowText $row2).Contains('B   Sekme:  Magaza  [Kurulu]') | Should -BeTrue -Because (Get-RowText $row2)
    }

    It 'takes the caption from the translations when the caller passes none' {
        $rows = Get-WtStoreFrameRows -State (New-WtStoreState) -Rows $GridRows `
            -Width 120 -Height 40 -Glyphs $Glyphs -FooterText 'x' -Breadcrumb 'B' -TabLabels $BreadCrumbLabels
        (Get-FrameText $rows).Contains((Get-Translation 'WsTabCaption') + ': [Magaza]') | Should -BeTrue
        foreach ($lang in 'TR', 'EN') { $script:Translations[$lang]['WsTabCaption'] | Should -Not -BeNullOrEmpty }
    }

    It 'the row is still exactly the box width, and a console too narrow for tabs plus counter trims the counter, never the tabs' {
        $rows = Get-WtStoreFrameRows -State (New-WtStoreState) -Rows $GridRows `
            -Width 40 -Height 24 -Glyphs $Glyphs -FooterText 'x' -CounterText '234 isaretli' `
            -Breadcrumb 'Main Menu > Winget Store' -TabLabels $BreadCrumbLabels -TabCaption 'Sekme'
        $bar = @($rows | ForEach-Object { Get-RowText $_ } | Where-Object { $_ -like '*Kurulu*' })
        $bar.Count | Should -Be 1
        $bar[0].Length | Should -Be 39
        $bar[0] | Should -BeLike '*[Magaza]*'
        foreach ($r in $rows) { (Get-RowText $r).Length | Should -Be 39 }
    }
}

Describe 'Store frame search label' {
    It 'shows the translated label, and the caret only while the search box has focus' {
        $blur = New-WtStoreState
        $focus = New-WtStoreState
        $focus.Focus = 'Input'; $focus.Query = 'obs'
        $blurRows = Get-WtStoreFrameRows -State $blur -Rows $GridRows -Width 120 -Height 40 -Glyphs $Glyphs -FooterText 'x'
        $focusRows = Get-WtStoreFrameRows -State $focus -Rows $GridRows -Width 120 -Height 40 -Glyphs $Glyphs -FooterText 'x'
        $blurRow = @($blurRows | ForEach-Object { Get-RowText $_ } | Where-Object { $_ -like '*Search apps:*' })
        $focusRow = @($focusRows | ForEach-Object { Get-RowText $_ } | Where-Object { $_ -like '*Search apps:*' })
        $blurRow.Count | Should -Be 1
        $focusRow.Count | Should -Be 1
        $blurRow[0] | Should -Not -BeLike '*_*' -Because 'the box does not have focus'
        $focusRow[0] | Should -BeLike '*obs_*' -Because 'the caret is the only thing that marks focus'
    }

    It 'keeps the right-aligned count exactly as before, next to the labeled row' {
        $s = New-WtStoreState
        $s.Query = 'fir'
        $rows = Get-WtStoreFrameRows -State $s -Rows $GridRows -Width 120 -Height 40 -Glyphs $Glyphs -FooterText 'x' `
            -SearchCountText '252 uygulama - 3 sonuc'
        $row = @($rows | ForEach-Object { Get-RowText $_ } | Where-Object { $_ -like '*Search apps: fir*' })
        $row.Count | Should -Be 1
        $row[0].TrimEnd().TrimEnd($Glyphs.V).TrimEnd() | Should -BeLike '*252 uygulama - 3 sonuc'
    }

    It 'resolves the label through the translation table in both languages, not a hardcoded literal' {
        foreach ($lang in 'EN', 'TR') {
            $script:Translations[$lang]['WsSearchLabel'] | Should -Not -BeNullOrEmpty
        }
        $script:Translations['EN']['WsSearchLabel'] | Should -Be 'Search apps'
        $script:Translations['TR']['WsSearchLabel'] | Should -Be 'Uygulama ara'
        $priorLanguage = $script:Language
        try {
            $script:Language = 'TR'
            $rows = Get-WtStoreFrameRows -State (New-WtStoreState) -Rows $GridRows -Width 120 -Height 40 -Glyphs $Glyphs -FooterText 'x'
            (Get-FrameText $rows) | Should -BeLike '*Uygulama ara:*'
            $script:Language = 'EN'
            $rows = Get-WtStoreFrameRows -State (New-WtStoreState) -Rows $GridRows -Width 120 -Height 40 -Glyphs $Glyphs -FooterText 'x'
            (Get-FrameText $rows) | Should -BeLike '*Search apps:*'
        }
        finally { $script:Language = $priorLanguage }
    }
}

Describe 'Store frame on a narrow console' {
    It 'names the heading in the active language and never shows the raw key' {
        $labels = @{ Browsers = 'Tarayicilar'; Dev = 'Gelistirme'; Media = 'Medya'; Comms = 'Iletisim'; Utilities = 'Yardimci' }
        $geo = Get-WtGridGeometry -Inner ([Math]::Max(20, 70 - 1) - 4)
        $geo.ColumnCount | Should -Be 1 -Because 'width 70 must flow one cell per row'
        $flowed = Get-WtStoreGridRows -Apps @([PSCustomObject]@{ Id = 'M.F'; Name = 'Firefox'; Category = 'Browsers' }) `
            -CategoryKeys @('Browsers', 'Dev', 'Media', 'Comms', 'Utilities') -CellsPerRow $geo.ColumnCount `
            -CategoryLabels $labels
        $rows = Get-WtStoreFrameRows -State (New-WtStoreState) -Rows $flowed -Width 70 -Height 24 `
            -Glyphs $Glyphs -FooterText 'x'
        $text = Get-FrameText $rows
        $text | Should -BeLike '*Tarayicilar*'
        $text | Should -Not -BeLike '*Browsers*'
        $text | Should -Not -BeLike '*Utilities*'
        @($rows | Where-Object { (Get-RowText $_) -like '*Tarayicilar*' }).Count | Should -Be 1
        @($rows).Count | Should -Be 24
        foreach ($row in $rows) { (Get-RowText $row).Length | Should -BeLessOrEqual 69 }
    }
}
