# Glyph sets, VT escape map, row/segment text helpers, key and line tokens.
# Covered by: tests/Tui.Tests.ps1

function Test-WtUnicodeGlyphSupport {
    <#
    .SYNOPSIS
        Whether the host can be trusted to render Unicode box-drawing
        glyphs: Windows Terminal always (WT_SESSION set), PowerShell 7+
        otherwise; legacy 5.1 conhost may run raster fonts / OEM
        codepages, so it gets the ASCII set.
    #>
    param(
        [AllowNull()][AllowEmptyString()]
        [string]$WtSession = $env:WT_SESSION,

        [int]$PSMajorVersion = $PSVersionTable.PSVersion.Major
    )

    if (-not [string]::IsNullOrEmpty($WtSession)) { return $true }
    return ($PSMajorVersion -ge 7)
}

function Get-WtGlyphSet {
    <#
    .SYNOPSIS
        The drawing vocabulary for every screen. Unicode characters are
        produced via [char] casts so WinToolify.ps1 itself stays pure
        ASCII (the file has no BOM and must parse identically under any
        ANSI codepage).
    #>
    param(
        [Parameter(Mandatory)]
        [bool]$Unicode
    )

    if ($Unicode) {
        return [PSCustomObject]@{
            H        = [string][char]0x2500
            V        = [string][char]0x2502
            TL       = [string][char]0x250C
            TR       = [string][char]0x2510
            BL       = [string][char]0x2514
            BR       = [string][char]0x2518
            LT       = [string][char]0x251C
            RT       = [string][char]0x2524
            Cursor   = ([string][char]0x25B6) + ' '
            CheckOn  = '[x]'
            CheckOff = '[ ]'
            RadioOn  = '(*)'
            RadioOff = '( )'
            Bullet   = [string][char]0x25CF
            Branch   = [string][char]0x23BF
            Dot      = [string][char]0xB7
            Spinner  = -join @([char]0x280B, [char]0x2819, [char]0x2839, [char]0x2838, [char]0x283C, [char]0x2834, [char]0x2826, [char]0x2827, [char]0x2807, [char]0x280F)
            ListBullet = [string][char]0x2022
            Rule       = [string][char]0x2500
        }
    }

    return [PSCustomObject]@{
        H        = '-'
        V        = '|'
        TL       = '+'
        TR       = '+'
        BL       = '+'
        BR       = '+'
        LT       = '+'
        RT       = '+'
        Cursor   = '> '
        CheckOn  = '[x]'
        CheckOff = '[ ]'
        RadioOn  = '(*)'
        RadioOff = '( )'
        Bullet   = '*'
        Branch   = '\'
        Dot      = '-'
        Spinner  = '|/-\'
        ListBullet = '-'
        Rule       = '-'
    }
}

$script:WtGlyphs = Get-WtGlyphSet -Unicode $false

$script:WtEsc = [string][char]27
$script:WtSgrMap = @{
    Black = 30; DarkRed = 31; DarkGreen = 32; DarkYellow = 33; DarkBlue = 34; DarkMagenta = 35; DarkCyan = 36; Gray = 37
    DarkGray = 90; Red = 91; Green = 92; Yellow = 93; Blue = 94; Magenta = 95; Cyan = 96; White = 97
}

$script:WtSgrPrefixCache = @{}

function Get-WtSgrPrefix {
    <#
    .SYNOPSIS
        The SGR prefix for one colour pair, from the cache after the first
        time. An unknown or empty foreground is 37 (Gray), as before; an
        unknown background adds nothing.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Fg,
        [AllowNull()][AllowEmptyString()][string]$Bg
    )
    $key = [string]$Fg + '|' + [string]$Bg
    $hit = $script:WtSgrPrefixCache[$key]
    if ($null -ne $hit) { return $hit }
    $codes = '37'
    if ($Fg -and $script:WtSgrMap.ContainsKey($Fg)) { $codes = [string]$script:WtSgrMap[$Fg] }
    if ($Bg -and $script:WtSgrMap.ContainsKey($Bg)) { $codes += ';' + ([int]$script:WtSgrMap[$Bg] + 10) }
    $prefix = $script:WtEsc + '[' + $codes + 'm'
    $script:WtSgrPrefixCache[$key] = $prefix
    return $prefix
}

function ConvertTo-WtVtText {
    <#
    .SYNOPSIS
        One colored run as a VT string: ESC[<fg>[;<bg>]m + text + ESC[0m.
        Empty text yields an empty string so padding math stays exact.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string]$Fg = 'White',
        [AllowNull()][AllowEmptyString()][string]$Bg = ''
    )
    if ($Text.Length -eq 0) { return '' }
    return ((Get-WtSgrPrefix -Fg $Fg -Bg $Bg) + $Text + $script:WtEsc + '[0m')
}

function ConvertTo-WtRowString {
    <#
    .SYNOPSIS
        Renders one segment-line into a string that occupies EXACTLY Width
        visible columns: segments are concatenated (styled when Vt),
        truncated at Width, and space-padded (unstyled) to Width. Every
        frame row goes through here, so no stale characters can survive
        a redraw and the right border always lands in the same column.
        Styling goes through the SGR prefix cache rather than calling
        ConvertTo-WtVtText per segment: at 17 segments a store row that
        cost 70-280 ms a frame, the lag behind every cursor move.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Segments,
        [Parameter(Mandatory)][int]$Width,
        [bool]$Vt = $false
    )
    $sb = New-Object System.Text.StringBuilder
    $used = 0
    $cache = $script:WtSgrPrefixCache
    $reset = $script:WtEsc + '[0m'
    foreach ($seg in $Segments) {
        if ($used -ge $Width) { break }
        $text = [string]$seg.T
        if (($used + $text.Length) -gt $Width) { $text = $text.Substring(0, $Width - $used) }
        if ($text.Length -eq 0) { continue }
        if ($Vt) {
            $prefix = $cache[[string]$seg.F + '|' + [string]$seg.B]
            if ($null -eq $prefix) { $prefix = Get-WtSgrPrefix -Fg ([string]$seg.F) -Bg ([string]$seg.B) }
            [void]$sb.Append($prefix).Append($text).Append($reset)
        }
        else { [void]$sb.Append($text) }
        $used += $text.Length
    }
    if ($used -lt $Width) { [void]$sb.Append(' ' * ($Width - $used)) }
    return $sb.ToString()
}

function Get-WtVisibleLength {
    <#
    .SYNOPSIS
        Length of a string once every CSI sequence (ESC [ ... letter) is
        removed - what the console will actually occupy.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if (-not $Text) { return 0 }
    $pattern = [regex]::Escape($script:WtEsc) + '\[[0-9;?]*[A-Za-z]'
    return ([regex]::Replace($Text, $pattern, '')).Length
}

function ConvertTo-WtKeyToken {
    <#
    .SYNOPSIS
        Normalizes one ConsoleKeyInfo (passed as its Key name string +
        KeyChar string so tests never need a real console) into the
        screen-reducer token vocabulary. Unknown keys become 'None' and
        are ignored by the reducer.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Key,

        [AllowNull()][AllowEmptyString()]
        [string]$KeyChar = ''
    )

    switch ($Key) {
        'UpArrow'   { return 'Up' }
        'DownArrow' { return 'Down' }
        'PageUp'    { return 'PageUp' }
        'PageDown'  { return 'PageDown' }
        'Home'      { return 'Home' }
        'End'       { return 'End' }
        'Spacebar'  { return 'Space' }
        'Enter'     { return 'Enter' }
        'LeftArrow' { return 'Back' }
        'Escape'    { return 'Back' }
        'Backspace' { return 'Back' }
    }

    if ($KeyChar -match '^[0-9]$') { return "Digit:$KeyChar" }
    if ($KeyChar -match '^[A-Za-z]$') { return ('Char:' + $KeyChar.ToLowerInvariant()) }
    if ($KeyChar -eq '/') { return 'Char:/' }
    return 'None'
}

function ConvertTo-WtLineToken {
    <#
    .SYNOPSIS
        The line-input fallback (hosts without ReadKey: ISE, redirected
        stdin) speaks the same token vocabulary: empty line = Enter,
        digits = jump, n/p = paging, b = back, any other word = its
        first letter as a Char token.
    #>
    param(
        [AllowNull()][AllowEmptyString()]
        [string]$Line
    )

    $t = ([string]$Line).Trim()
    if ($t -eq '') { return 'Enter' }
    if ($t -match '^[0-9]+$') { return "Digit:$t" }
    if ($t -match '^[Nn]$') { return 'PageDown' }
    if ($t -match '^[Pp]$') { return 'PageUp' }
    if ($t -match '^[Bb]$') { return 'Back' }
    return ('Char:' + $t.Substring(0, 1).ToLowerInvariant())
}
