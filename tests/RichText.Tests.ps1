#Requires -Modules Pester

<#
.SYNOPSIS
    The pure rich-text layer: the block classifier, the inline mark
    splitter, the word wrapper and the block renderer. No console.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
    $script:Fence = ([string][char]96) * 3
}

Describe 'Get-WtRichWrapWidth' {
    It 'is Width-1, uncapped, floored at 10, so a full-screen window is used' {
        Get-WtRichWrapWidth -Width 80 | Should -Be 79
        Get-WtRichWrapWidth -Width 200 | Should -Be 199
        Get-WtRichWrapWidth -Width 4 | Should -Be 10
    }
}

Describe 'Get-WtRichBlock' {
    It 'classifies headings and strips the hashes' {
        $b = Get-WtRichBlock -Line '## Baslangic programlari' -State @{ InFence = $false }
        $b.Kind | Should -Be 'Heading'
        $b.Level | Should -Be 2
        $b.Text | Should -Be 'Baslangic programlari'
    }

    It 'needs a space after the hashes and stops at six' {
        (Get-WtRichBlock -Line '#hashtag' -State @{ InFence = $false }).Kind | Should -Be 'Paragraph'
        (Get-WtRichBlock -Line '####### yedi' -State @{ InFence = $false }).Kind | Should -Be 'Paragraph'
    }

    It 'classifies bullets, numbers and quotes and strips their markers' {
        $b = Get-WtRichBlock -Line '- Spotify' -State @{ InFence = $false }
        $b.Kind | Should -Be 'Bullet'
        $b.Text | Should -Be 'Spotify'
        $n = Get-WtRichBlock -Line '12) Discord' -State @{ InFence = $false }
        $n.Kind | Should -Be 'Numbered'
        $n.Marker | Should -Be '12)'
        $n.Text | Should -Be 'Discord'
        $q = Get-WtRichBlock -Line '> alinti' -State @{ InFence = $false }
        $q.Kind | Should -Be 'Quote'
        $q.Text | Should -Be 'alinti'
    }

    It 'classifies rules, tables and blanks' {
        (Get-WtRichBlock -Line '---' -State @{ InFence = $false }).Kind | Should -Be 'Rule'
        (Get-WtRichBlock -Line '***' -State @{ InFence = $false }).Kind | Should -Be 'Rule'
        (Get-WtRichBlock -Line '| a | b |' -State @{ InFence = $false }).Kind | Should -Be 'Table'
        (Get-WtRichBlock -Line '   ' -State @{ InFence = $false }).Kind | Should -Be 'Blank'
    }

    It 'toggles the fence and swallows everything inside it' {
        $open = Get-WtRichBlock -Line ($Fence + 'powershell') -State @{ InFence = $false }
        $open.Kind | Should -Be 'Fence'
        $open.State.InFence | Should -BeTrue
        $inside = Get-WtRichBlock -Line '# bu bir yorum, baslik degil' -State $open.State
        $inside.Kind | Should -Be 'Code'
        $inside.Text | Should -Be '# bu bir yorum, baslik degil'
        $close = Get-WtRichBlock -Line $Fence -State $inside.State
        $close.Kind | Should -Be 'Fence'
        $close.State.InFence | Should -BeFalse
    }

    It 'keeps the dotted and dotless I intact under tr-TR' {
        $dotted = [string][char]0x0130
        $dotless = [string][char]0x0131
        $sCedil = [string][char]0x015F
        $gBreve = [string][char]0x011F
        $text = $dotted + 'slemci ve ' + $dotted + 'Z' + $dotless + 'N ' + $gBreve + 'e' + $sCedil + 'it'
        $old = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            $b = Get-WtRichBlock -Line ('- ' + $text) -State @{ InFence = $false }
            $b.Kind | Should -Be 'Bullet'
            $b.Text | Should -Be $text
            $p = @(Split-WtRichInline -Text ('**' + $text + '**'))
            $p.Count | Should -Be 1
            $p[0].Style | Should -Be 'Strong'
            $p[0].Text | Should -Be $text
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $old }
    }
}
Describe 'Split-WtRichInline' {
    It 'splits bold, code and links into styled parts' {
        $p = (Split-WtRichInline -Text 'Once **OneDrive** kapandi.')
        $p.Count | Should -Be 3
        $p[0].Text | Should -Be 'Once '
        $p[0].Style | Should -Be 'Normal'
        $p[1].Text | Should -Be 'OneDrive'
        $p[1].Style | Should -Be 'Strong'
        $p[2].Text | Should -Be ' kapandi.'

        $c = (Split-WtRichInline -Text 'calistir: `services.msc`')
        $c[1].Text | Should -Be 'services.msc'
        $c[1].Style | Should -Be 'Code'

        $l = (Split-WtRichInline -Text 'bak [MS Learn](https://learn.microsoft.com) sayfasina')
        $l[1].Text | Should -Be 'MS Learn'
        $l[1].Style | Should -Be 'Link'
        $l[2].Text | Should -Be ' (https://learn.microsoft.com)'
        $l[2].Style | Should -Be 'Url'
    }

    It 'accepts __bold__ as well as **bold**' {
        ((Split-WtRichInline -Text 'bu __kalin__ olsun')[1]).Style | Should -Be 'Strong'
    }

    It 'leaves an unclosed mark as literal text' {
        $p = (Split-WtRichInline -Text 'yarim **kalin ve devami yok')
        $p.Count | Should -Be 1
        $p[0].Text | Should -Be 'yarim **kalin ve devami yok'
        $p[0].Style | Should -Be 'Normal'
    }

    It 'lets code swallow the marks inside it' {
        $p = (Split-WtRichInline -Text 'kod: `a ** b` son')
        $p[1].Style | Should -Be 'Code'
        $p[1].Text | Should -Be 'a ** b'
        $p[2].Text | Should -Be ' son'
    }

    It 'returns an empty array for empty text' {
        (Split-WtRichInline -Text '').Count | Should -Be 0
    }
}

Describe 'Split-WtWrappedSegments' {
    BeforeAll {
        $script:RowText = { param($Row) (@($Row) | ForEach-Object { [string]$_.T }) -join '' }
    }

    It 'breaks at spaces and never exceeds the wrap width' {
        $parts = Split-WtRichInline -Text ('bir iki uc dort bes alti yedi sekiz dokuz on onbir oniki onuc')
        $rows = (Split-WtWrappedSegments -Parts $parts -Width 30)
        $rows.Count | Should -BeGreaterThan 1
        foreach ($r in $rows) { (& $RowText $r).Length | Should -BeLessOrEqual 29 }
        (($rows | ForEach-Object { & $RowText $_ }) -join ' ') | Should -Be 'bir iki uc dort bes alti yedi sekiz dokuz on onbir oniki onuc'
    }

    It 'puts the prefix on the first row and the hanging indent on the rest' {
        $parts = Split-WtRichInline -Text 'aaaa bbbb cccc dddd eeee ffff'
        $rows = (Split-WtWrappedSegments -Parts $parts -Width 22 -Indent 2 -Hanging 2 -Prefix '* ' -PrefixFg 'Yellow')
        (& $RowText $rows[0]) | Should -BeLike '  * aaaa*'
        (& $RowText $rows[1]) | Should -BeLike '    *'
        $rows[0][0].F | Should -Be 'Yellow'
    }

    It 'hard-breaks a word longer than the line' {
        $parts = Split-WtRichInline -Text ('x' * 40)
        $rows = (Split-WtWrappedSegments -Parts $parts -Width 20)
        $rows.Count | Should -Be 3
        (& $RowText $rows[0]) | Should -Be ('x' * 19)
        (($rows | ForEach-Object { & $RowText $_ }) -join '') | Should -Be ('x' * 40)
    }

    It 'carries the style colours and merges neighbours of one colour' {
        $parts = Split-WtRichInline -Text 'once **OneDrive** sonra'
        $rows = (Split-WtWrappedSegments -Parts $parts -Width 80)
        $rows.Count | Should -Be 1
        @($rows[0]).Count | Should -Be 3
        $rows[0][0].F | Should -Be 'Gray'
        $rows[0][1].T | Should -Be 'OneDrive'
        $rows[0][1].F | Should -Be 'White'
    }

    It 'still terminates when the indent is as wide as the row' {
        $parts = Split-WtRichInline -Text ('y' * 12)
        $rows = (Split-WtWrappedSegments -Parts $parts -Width 20 -Indent 18 -Hanging 4)
        @($rows).Count | Should -Be 12
        foreach ($r in $rows) { (& $RowText $r).Length | Should -BeLessOrEqual 19 }
        ((@($rows) | ForEach-Object { (& $RowText $_).Trim() }) -join '') | Should -Be ('y' * 12)
    }

    It 'returns no rows for no parts and no prefix' {
        (Split-WtWrappedSegments -Parts @() -Width 80).Count | Should -Be 0
    }
}

Describe 'Get-WtRichLines' {
    BeforeAll {
        $script:G = Get-WtGlyphSet -Unicode $false
        $script:RowText2 = { param($Row) (@($Row) | ForEach-Object { [string]$_.T }) -join '' }
    }

    It 'renders a heading in cyan with a blank row above it' {
        $rows = (Get-WtRichLines -Text "girdi var`n## Baslangic`nson" -Width 80 -Glyphs $G)
        (& $RowText2 $rows[1]) | Should -Be ''
        (& $RowText2 $rows[2]) | Should -Be 'Baslangic'
        $rows[2][0].F | Should -Be 'Cyan'
    }

    It 'renders bullets with the list glyph, two in and four hanging' {
        $rows = (Get-WtRichLines -Text '- Spotify' -Width 80 -Glyphs $G)
        (& $RowText2 $rows[0]) | Should -Be '  - Spotify'
    }

    It 'renders a numbered item keeping its marker' {
        $rows = (Get-WtRichLines -Text '2. Discord' -Width 80 -Glyphs $G)
        (& $RowText2 $rows[0]) | Should -Be '  2. Discord'
    }

    It 'prints a code block dark cyan, indented, unwrapped and clipped' {
        $fence = ([string][char]96) * 3
        $long = 'Get-Service | Where-Object { $_.Status -eq ' + [char]39 + 'Running' + [char]39 + ' } | Select-Object -First 5 -Property Name'
        $rows = (Get-WtRichLines -Text ($fence + "`n" + $long + "`n" + $fence) -Width 40 -Glyphs $G)
        $rows.Count | Should -Be 1
        (& $RowText2 $rows[0]).Length | Should -BeLessOrEqual 39
        $rows[0][0].F | Should -Be 'DarkCyan'
    }

    It 'draws a rule across the wrap width' {
        $rows = (Get-WtRichLines -Text '---' -Width 30 -Glyphs $G)
        (& $RowText2 $rows[0]) | Should -Be ('-' * 29)
        $rows[0][0].F | Should -Be 'DarkGray'
    }

    It 'passes a table row through unwrapped and clipped' {
        $rows = (Get-WtRichLines -Text ('| ad | deger | aciklama uzun uzun uzun uzun |') -Width 30 -Glyphs $G)
        $rows.Count | Should -Be 1
        (& $RowText2 $rows[0]).Length | Should -BeLessOrEqual 29
    }

    It 'never emits a row wider than Width-1 for a long mixed answer' {
        $text = "## Ozet`nBu **cok uzun** bir cevap ve icinde https://example.com/cok/uzun/bir/adres/parcasi/daha var.`n- madde bir`n- madde iki"
        foreach ($w in @(40, 60, 80, 120, 200)) {
            foreach ($r in (Get-WtRichLines -Text $text -Width $w -Glyphs $G)) {
                (& $RowText2 $r).Length | Should -BeLessOrEqual (Get-WtRichWrapWidth -Width $w)
            }
        }
    }

    It 'honours the base indent for every block kind' {
        (& $RowText2 (Get-WtRichLines -Text 'duz satir' -Width 80 -Indent 2 -Glyphs $G)[0]) | Should -Be '  duz satir'
        (& $RowText2 (Get-WtRichLines -Text '- madde' -Width 80 -Indent 2 -Glyphs $G)[0]) | Should -Be '    - madde'
        (& $RowText2 (Get-WtRichLines -Text '> alinti' -Width 80 -Indent 2 -Glyphs $G)[0]) | Should -Be '    alinti'
        $h = (Get-WtRichLines -Text '## Baslik' -Width 80 -Indent 2 -Glyphs $G)
        (& $RowText2 $h[1]) | Should -Be '  Baslik'
    }

    It 'keeps a rule inside the width even at a deep indent' {
        $rows = (Get-WtRichLines -Text '---' -Width 30 -Indent 40 -Glyphs $G)
        (& $RowText2 $rows[0]).Length | Should -Be 29
    }
}
