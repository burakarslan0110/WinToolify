# Keyless web research for the assistant: Microsoft Learn search, the
# DuckDuckGo HTML endpoint and a page-text stripper.
# Covered by: tests/AssistantWeb.Tests.ps1

function ConvertTo-WtWebSnippet {
    <#
    .SYNOPSIS
        PURE: a search-result snippet as one line of at most -Max
        characters (whitespace collapsed, cut with a '~' marker).
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text, [int]$Max = 160)
    $clean = ([regex]::Replace([string]$Text, '\s+', ' ', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)).Trim()
    if ($Max -gt 1 -and $clean.Length -gt $Max) { $clean = $clean.Substring(0, $Max - 1) + '~' }
    return $clean
}

function ConvertTo-WtWebSearchRows {
    <#
    .SYNOPSIS
        PURE: the TSV rows web_search returns. The snippet column exists
        only when at least one row carries a snippet - the serializer
        writes every header column for every row, so an all-empty column
        would cost a trailing ' | ' per row for nothing.
    #>
    param([AllowEmptyCollection()][array]$Rows = @())
    $anySnippet = $false
    foreach ($row in @($Rows)) { if ([string]$row.snippet) { $anySnippet = $true; break } }
    return @(foreach ($row in @($Rows)) {
        if ($anySnippet) { [PSCustomObject]@{ title = [string]$row.title; url = [string]$row.url; snippet = [string]$row.snippet } }
        else { [PSCustomObject]@{ title = [string]$row.title; url = [string]$row.url } }
    })
}

function Search-WtLearnDocs {
    <#
    .SYNOPSIS
        The keyless learn.microsoft.com search API - the most accurate
        source for bugchecks, event ids and KBs. -Status, when given,
        gets 'failed' set only when the endpoint is dead or the JSON is
        broken; a real, empty answer is not a failure.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Query,
        [scriptblock]$Fetch = { param($Uri)
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            (Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop).Content
        },
        [AllowNull()][hashtable]$Status = $null
    )
    if (-not ([string]$Query).Trim()) { return @() }
    $uri = 'https://learn.microsoft.com/api/search?search=' + [uri]::EscapeDataString($Query) + '&locale=en-us&$top=5'
    $raw = ''
    try { $raw = [string](& $Fetch $uri) } catch { if ($null -ne $Status) { $Status['failed'] = $true }; return @() }
    $parsed = $null
    try { $parsed = $raw | ConvertFrom-Json } catch { if ($null -ne $Status) { $Status['failed'] = $true }; return @() }
    if ($null -eq $parsed -or -not ($parsed.PSObject.Properties.Name -contains 'results')) { return @() }
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($parsed.results)) {
        if ($null -eq $item) { continue }
        if ($results.Count -ge 5) { break }
        $snippet = ''
        if ($item.PSObject.Properties.Name -contains 'description' -and $item.description) { $snippet = ConvertTo-WtWebSnippet -Text ([string]$item.description) }
        $results.Add([PSCustomObject]@{ title = [string]$item.title; url = [string]$item.url; snippet = $snippet })
    }
    return @($results.ToArray())
}

function Search-WtDuckDuckGo {
    <#
    .SYNOPSIS
        The keyless html.duckduckgo.com endpoint: result anchors carry
        the real url inside the uddg= redirect parameter, titles come
        from the anchor body with tags stripped, and the snippet is read
        from the separate result__snippet element following each anchor.
        A markup change degrades to an empty list (Learn keeps working);
        -Status gets 'failed' only when the endpoint itself is dead.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Query,
        [scriptblock]$Fetch = { param($Uri)
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            (Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop `
                -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }).Content
        },
        [AllowNull()][hashtable]$Status = $null
    )
    if (-not ([string]$Query).Trim()) { return @() }
    $uri = 'https://html.duckduckgo.com/html/?q=' + [uri]::EscapeDataString($Query)
    $html = ''
    try { $html = [string](& $Fetch $uri) } catch { if ($null -ne $Status) { $Status['failed'] = $true }; return @() }
    $options = [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant, Singleline'
    $anchorPattern = 'class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>'
    $snippetPattern = 'class="result__snippet"[^>]*>(.*?)</(?:a|td|div)>'
    $anchors = @([regex]::Matches($html, $anchorPattern, $options))
    $snippets = @([regex]::Matches($html, $snippetPattern, $options))
    $results = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $anchors.Count; $i++) {
        if ($results.Count -ge 5) { break }
        $match = $anchors[$i]
        $href = [string]$match.Groups[1].Value
        $url = ''
        $uddg = [regex]::Match($href, 'uddg=([^&"]+)', $options)
        if ($uddg.Success) { $url = [uri]::UnescapeDataString([string]$uddg.Groups[1].Value) }
        if (-not $url) { continue }
        $title = [regex]::Replace([string]$match.Groups[2].Value, '<[^>]+>', '', $options)
        $title = [System.Net.WebUtility]::HtmlDecode($title).Trim()
        $nextStart = $(if ($i + 1 -lt $anchors.Count) { $anchors[$i + 1].Index } else { $html.Length })
        $snippet = ''
        foreach ($s in $snippets) {
            if ($s.Index -gt $match.Index -and $s.Index -lt $nextStart) {
                $snippet = [System.Net.WebUtility]::HtmlDecode([regex]::Replace([string]$s.Groups[1].Value, '<[^>]+>', '', $options))
                break
            }
        }
        $results.Add([PSCustomObject]@{ title = $title; url = $url; snippet = (ConvertTo-WtWebSnippet -Text $snippet) })
    }
    return @($results.ToArray())
}

function Get-WtAssistantWebSearch {
    <#
    .SYNOPSIS
        web_search: Learn first, DuckDuckGo only when Learn came back
        empty. Rows are title | url | snippet (<= 5); 'results: none'
        when both engines answered with nothing; 'error: search failed'
        only when both threw, so the model answers from what it knows
        instead of retrying blindly.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Query,
        [scriptblock]$FetchLearn = $null,
        [scriptblock]$FetchDdg = $null
    )
    $learnStatus = @{}
    $learnArgs = @{ Query = $Query; Status = $learnStatus }
    if ($FetchLearn) { $learnArgs['Fetch'] = $FetchLearn }
    $rows = @(Search-WtLearnDocs @learnArgs)
    $ddgStatus = @{}
    if ($rows.Count -eq 0) {
        $ddgArgs = @{ Query = $Query; Status = $ddgStatus }
        if ($FetchDdg) { $ddgArgs['Fetch'] = $FetchDdg }
        $rows = @(Search-WtDuckDuckGo @ddgArgs)
    }
    if ($rows.Count -eq 0) {
        if ($learnStatus.ContainsKey('failed') -and $ddgStatus.ContainsKey('failed')) {
            return [ordered]@{ error = 'search failed'; hint = 'answer from what you know or try different words' }
        }
        return [ordered]@{ results = 'none' }
    }
    return [ordered]@{ results = @(ConvertTo-WtWebSearchRows -Rows $rows) }
}

function Select-WtHtmlMainBlock {
    <#
    .SYNOPSIS
        PURE: the inner HTML of the first <main> (else <article>) element,
        '' when the page has neither or the element never closes. Ordinal
        IndexOf only - no regex, so a pathological page cannot stall here.
        A match followed immediately by another letter, digit or hyphen
        ('<mainframe', '<main-content') is rejected, not treated as <main>.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Html)
    $text = [string]$Html
    if (-not $text) { return '' }
    foreach ($tagName in 'main', 'article') {
        $open = 0
        while ($true) {
            $open = $text.IndexOf('<' + $tagName, $open, [System.StringComparison]::OrdinalIgnoreCase)
            if ($open -lt 0) { break }
            $after = $open + $tagName.Length + 1
            if ($after -lt $text.Length -and ([char]::IsLetterOrDigit($text[$after]) -or [int]$text[$after] -eq 45)) { $open = $after; continue }
            $close = $text.IndexOf('>', $after, [System.StringComparison]::Ordinal)
            if ($close -lt 0) { break }
            $end = $text.IndexOf('</' + $tagName + '>', $close + 1, [System.StringComparison]::OrdinalIgnoreCase)
            if ($end -lt 0) { break }
            return $text.Substring($close + 1, $end - $close - 1)
        }
    }
    return ''
}

function Remove-WtWebPageLeadingNav {
    <#
    .SYNOPSIS
        PURE: drops the leading run of short lines (<= 3 words) a page
        without <main> starts with - menus, breadcrumbs, cookie buttons -
        but only when that run is at least two lines long AND a real
        sentence (>= 4 words) follows it. A short page, or a title
        followed by prose, comes back whole.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)
    $page = [string]$Text
    if (-not $page) { return '' }
    $lines = @($page -csplit "\r?\n")
    $firstLong = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (@(([string]$lines[$i]).Split(' ') | Where-Object { $_ }).Count -ge 4) { $firstLong = $i; break }
    }
    if ($firstLong -lt 2) { return $page }
    return (@($lines | Select-Object -Skip $firstLong) -join "`n")
}

function ConvertTo-WtWebPageText {
    <#
    .SYNOPSIS
        HTML to readable text: the <main>/<article> element alone when the
        page has one that carries real text (an empty shell, from a
        script-rendered app, falls back to the whole document), then the
        leading navigation run is dropped. Tag removal, entities and
        whitespace live in ConvertTo-WtWebPageTextCore.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Html,
        [int]$MaxInputChars = 2000000,
        [double]$RegexTimeoutSeconds = 2.0
    )
    $text = [string]$Html
    if (-not $text) { return '' }
    if ($text.Length -gt $MaxInputChars) { $text = $text.Substring(0, $MaxInputChars) }
    $block = Select-WtHtmlMainBlock -Html $text
    $result = ''
    if ($block) { $result = ConvertTo-WtWebPageTextCore -Html $block -MaxInputChars $MaxInputChars -RegexTimeoutSeconds $RegexTimeoutSeconds }
    if ($result.Length -lt 40) { $result = ConvertTo-WtWebPageTextCore -Html $text -MaxInputChars $MaxInputChars -RegexTimeoutSeconds $RegexTimeoutSeconds }
    return (Remove-WtWebPageLeadingNav -Text $result)
}

function ConvertTo-WtWebPageTextCore {
    <#
    .SYNOPSIS
        Core of ConvertTo-WtWebPageText: strips script/style/head/nav/footer
        (header stays - an article's own <header> can carry its title),
        turns block tags into line breaks, strips tags, decodes entities,
        collapses whitespace per line, folds blank runs.

        Unbounded lazy patterns are a real hazard here: an unclosed tag
        could make a naive '.*?</tag>' scan run to end-of-string (quadratic
        time). -MaxInputChars caps the raw HTML, every structural regex is
        bounded to a fixed max span, and -RegexTimeoutSeconds falls back to
        ConvertTo-WtWebPageTextCrude (non-regex, O(n)) if still slow.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Html,
        [int]$MaxInputChars = 2000000,
        [double]$RegexTimeoutSeconds = 2.0
    )
    $text = [string]$Html
    if (-not $text) { return '' }
    if ($text.Length -gt $MaxInputChars) { $text = $text.Substring(0, $MaxInputChars) }
    $options = [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant, Singleline'
    $timeout = [timespan]::FromSeconds($RegexTimeoutSeconds)
    try {
        foreach ($tagName in 'script', 'style', 'head', 'nav', 'footer') {
            $text = Remove-WtHtmlBlockTag -Text $text -TagName $tagName -Options $options -Timeout $timeout
        }
        $closeRegex = [regex]::new('<(/p|/div|/h[1-6]|/li|/tr|/nav|/header|/footer|/section|/article|/main|/table|/blockquote|br)\b[^>]{0,200}>', $options, $timeout)
        $text = $closeRegex.Replace($text, "`n")
        $tagRegex = [regex]::new('<[^>]{1,2000}>', $options, $timeout)
        $text = $tagRegex.Replace($text, ' ')
    }
    catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
        return (ConvertTo-WtWebPageTextCrude -Html $text)
    }
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    $lines = New-Object System.Collections.Generic.List[string]
    $blank = $true
    foreach ($line in @($text -csplit "\r?\n")) {
        $clean = ([regex]::Replace([string]$line, '\s+', ' ', $options)).Trim()
        if ($clean -eq '') {
            if (-not $blank) { $lines.Add(''); $blank = $true }
            continue
        }
        $lines.Add($clean)
        $blank = $false
    }
    return (($lines.ToArray()) -join "`n").Trim()
}

function Remove-WtHtmlBlockTag {
    <#
    .SYNOPSIS
        Strips every <$TagName ...>...</$TagName> block for one tag name,
        deciding per occurrence whether a real closer exists ahead of it.

        Uses two bulk passes (an IndexOf sweep for closers, one Matches()
        call for openers) merged by two forward-only indices, rather than
        a loop of one Regex.Match(text, cursor) per occurrence: the latter
        measured genuinely quadratic on PowerShell 7's regex engine while
        the identical loop stayed linear on PS 5.1 - a runtime-specific
        cost in that overload's repeated-call behaviour. A found closer
        consumes through it; none leaves the bare opening tag for the
        generic tag stripper that runs afterwards.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$TagName,
        [Parameter(Mandatory)]$Options,
        [Parameter(Mandatory)][timespan]$Timeout
    )
    if (-not $Text) { return $Text }
    $closerLiteral = '</' + $TagName + '>'
    $closerPositions = New-Object System.Collections.Generic.List[int]
    $scanFrom = 0
    while ($true) {
        $pos = $Text.IndexOf($closerLiteral, $scanFrom, [System.StringComparison]::OrdinalIgnoreCase)
        if ($pos -lt 0) { break }
        $closerPositions.Add($pos)
        $scanFrom = $pos + $closerLiteral.Length
    }
    if ($closerPositions.Count -eq 0) {
        return $Text
    }
    $openRegex = [regex]::new('<' + $TagName + '\b[^>]{0,2000}>', $Options, $Timeout)
    $openMatches = $openRegex.Matches($Text)
    $builder = New-Object System.Text.StringBuilder
    $cursor = 0
    $closerIndex = 0
    foreach ($openMatch in $openMatches) {
        if ($openMatch.Index -lt $cursor) { continue }
        [void]$builder.Append($Text.Substring($cursor, $openMatch.Index - $cursor))
        $contentStart = $openMatch.Index + $openMatch.Length
        while ($closerIndex -lt $closerPositions.Count -and $closerPositions[$closerIndex] -lt $contentStart) { $closerIndex++ }
        if ($closerIndex -lt $closerPositions.Count) {
            [void]$builder.Append(' ')
            $cursor = $closerPositions[$closerIndex] + $closerLiteral.Length
            $closerIndex++
        }
        else {
            [void]$builder.Append(' ')
            $cursor = $contentStart
        }
    }
    [void]$builder.Append($Text.Substring($cursor))
    return $builder.ToString()
}

function ConvertTo-WtWebPageTextCrude {
    <#
    .SYNOPSIS
        ConvertTo-WtWebPageText's regex-timeout fallback: a plain,
        no-regex character scan, guaranteed O(n) with no backtracking
        risk, reached only when the bounded, timeout-guarded regexes
        there still somehow time out. Cruder than that path - an
        unmatched '<' here still swallows forward to the next '>',
        however far away, since a linear scan has no lookahead bound to
        fall back on - but hanging is the one failure mode this must
        never have.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Html)
    $text = [string]$Html
    if (-not $text) { return '' }
    $builder = New-Object System.Text.StringBuilder
    $inTag = $false
    foreach ($ch in $text.ToCharArray()) {
        if ($ch -eq '<') { $inTag = $true; continue }
        if ($ch -eq '>') { $inTag = $false; continue }
        if (-not $inTag) { [void]$builder.Append($ch) }
    }
    return ([System.Net.WebUtility]::HtmlDecode($builder.ToString())).Trim()
}

function Read-WtBoundedText {
    <#
    .SYNOPSIS
        Reads a TextReader up to a hard character cap and a wall-clock
        deadline, then stops - the rest of the stream is discarded unread,
        never accumulated. Replaces ReadToEnd(), which builds the whole
        body into one string before anything downstream can cap it, and
        would let a huge or endlessly-streaming response (the url is
        model-chosen) freeze the UI thread and grow the heap without
        limit. -MaxChars alone is not enough: HttpWebRequest's
        ReadWriteTimeout bounds only ONE read call, so a server that
        keeps dribbling data forever never trips it - the deadline here
        is checked after every buffer instead, so the total read time is
        bounded even when each individual read is prompt. Read exceptions
        are deliberately not caught here: the caller's own try/catch
        already turns them into the fetch_page error shape.
    #>
    param(
        [Parameter(Mandatory)]$Reader,
        [int]$MaxChars = 4000000,
        [int]$TimeoutMs = 20000,
        [scriptblock]$Clock = $null
    )
    if ($MaxChars -le 0) { return '' }
    $builder = New-Object System.Text.StringBuilder
    $buffer = New-Object char[] 8192
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($builder.Length -lt $MaxChars) {
        $want = [Math]::Min($buffer.Length, $MaxChars - $builder.Length)
        $read = [int]$Reader.Read($buffer, 0, $want)
        if ($read -le 0) { break }
        [void]$builder.Append($buffer, 0, $read)
        if ($TimeoutMs -gt 0) {
            $elapsed = $(if ($null -eq $Clock) { [long]$watch.ElapsedMilliseconds } else { [long](& $Clock) })
            if ($elapsed -ge $TimeoutMs) { break }
        }
    }
    return $builder.ToString()
}

function Test-WtPrivateWebHost {
    <#
    .SYNOPSIS
        Whether a fetch_page host is a literal loopback, RFC1918/link-local/
        unique-local, CGNAT, zero/unspecified, or localhost - refused before
        any request, since the user agreed to send data TO the endpoint, not
        let it browse their own LAN.

        Literal address only: a hostname that RESOLVES into one of these
        ranges (DNS rebinding) still gets through, since a check-then-fetch
        race would give false comfort. Obfuscated IPv4 literals refused in
        Get-WtAssistantFetchPage instead: [uri] canonicalises them to
        127.0.0.1 first, so this check catches them too.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$HostName)
    $candidate = ([string]$HostName).Trim().Trim('[', ']').TrimEnd('.')
    if (-not $candidate) { return $false }
    if ([string]::Equals($candidate, 'localhost', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($candidate.EndsWith('.localhost', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($candidate, [ref]$ip)) { return $false }
    if ($ip.IsIPv4MappedToIPv6) { $ip = $ip.MapToIPv4() }
    if ([System.Net.IPAddress]::IsLoopback($ip)) { return $true }
    if ($ip.Equals([System.Net.IPAddress]::Any) -or $ip.Equals([System.Net.IPAddress]::IPv6Any)) { return $true }
    $bytes = $ip.GetAddressBytes()
    if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and $bytes.Length -eq 4) {
        $a = [int]$bytes[0]
        $b = [int]$bytes[1]
        if ($a -eq 10) { return $true }
        if ($a -eq 172 -and $b -ge 16 -and $b -le 31) { return $true }
        if ($a -eq 192 -and $b -eq 168) { return $true }
        if ($a -eq 169 -and $b -eq 254) { return $true }
        if ($a -eq 100 -and $b -ge 64 -and $b -le 127) { return $true }
    }
    elseif ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6 -and $bytes.Length -eq 16) {
        if ($bytes[0] -eq 0xFE -and ($bytes[1] -band 0xC0) -eq 0x80) { return $true }
        if (($bytes[0] -band 0xFE) -eq 0xFC) { return $true }
    }
    return $false
}

function Get-WtAssistantFetchPage {
    <#
    .SYNOPSIS
        fetch_page: http/https only, refuses a private-network destination
        on every hop of a redirect chain, returns stripped text as an offset
        window: [ordered]@{ url; text = string[] [; omitted] }, or on refusal
        @{ url; text=''; error } with its own reason.

        Redirects are walked here, not via Invoke-WebRequest (its
        -MaximumRedirection 0 differs PS 5.1 vs PS7 on a 3xx and skips the
        host check after hop 1); a hop's Location needs direct dot-access
        since Hashtable's .PSObject.Properties never reflects its entries.
        Body reads via Read-WtBoundedText, not the unbounded ReadToEnd().
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Url,
        [int]$Offset = 0,
        [scriptblock]$FetchHop = { param($Uri)
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $request = [System.Net.HttpWebRequest]::Create($Uri)
            $request.AllowAutoRedirect = $false
            $request.Timeout = 20000
            $request.ReadWriteTimeout = $request.Timeout
            $request.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
            $response = $null
            try {
                $response = $request.GetResponse()
            }
            catch [System.Net.WebException] {
                if ($_.Exception.Response) { $_.Exception.Response.Dispose() }
                throw
            }
            try {
                $statusCode = [int]$response.StatusCode
                $location = [string]$response.Headers['Location']
                $content = ''
                if ($statusCode -lt 300 -or $statusCode -gt 399) {
                    $stream = $response.GetResponseStream()
                    $encoding = [System.Text.Encoding]::UTF8
                    if ([string]$response.CharacterSet) {
                        try { $encoding = [System.Text.Encoding]::GetEncoding([string]$response.CharacterSet) } catch { $encoding = [System.Text.Encoding]::UTF8 }
                    }
                    $reader = New-Object System.IO.StreamReader($stream, $encoding)
                    $content = Read-WtBoundedText -Reader $reader -MaxChars 4000000 -TimeoutMs ([int]$request.Timeout)
                    $reader.Dispose()
                }
                return @{ StatusCode = $statusCode; Location = $location; Content = $content }
            }
            finally { $response.Dispose() }
        },
        [int]$MaxChars = 3000,
        [int]$MaxUrlChars = 500,
        [int]$MaxRedirects = 5
    )
    $echoUrl = [string]$Url
    if ($echoUrl.Length -gt $MaxUrlChars) { $echoUrl = $echoUrl.Substring(0, $MaxUrlChars) + '~' }
    $refuse = { param($Reason) return [ordered]@{ url = $echoUrl; text = ''; error = [string]$Reason } }

    $currentUrl = [string]$Url
    $html = $null
    for ($hop = 0; $hop -le $MaxRedirects; $hop++) {
        $parsed = $null
        try { $parsed = [uri]$currentUrl } catch { $parsed = $null }
        if ($null -eq $parsed -or -not $parsed.IsAbsoluteUri -or (@('http', 'https') -notcontains $parsed.Scheme.ToLowerInvariant())) {
            return (& $refuse 'unsupported scheme')
        }
        if (Test-WtPrivateWebHost -HostName $parsed.DnsSafeHost) {
            return (& $refuse 'blocked destination')
        }
        $hopResult = $null
        try { $hopResult = & $FetchHop $currentUrl } catch { return (& $refuse 'fetch failed') }
        if ($null -eq $hopResult) { return (& $refuse 'fetch failed') }
        $status = 0
        try { $status = [int]$hopResult.StatusCode } catch { $status = 0 }
        $location = [string]$hopResult.Location
        if ($status -ge 300 -and $status -le 399 -and $location) {
            $nextUri = $null
            try { $nextUri = [uri]::new($parsed, $location) } catch { return (& $refuse 'fetch failed') }
            $currentUrl = $nextUri.AbsoluteUri
            continue
        }
        $html = [string]$hopResult.Content
        break
    }
    if ($null -eq $html) { return (& $refuse 'too many redirects') }
    $full = ConvertTo-WtWebPageText -Html $html
    $start = [Math]::Max(0, [Math]::Min([int]$Offset, $full.Length))
    $window = $full.Substring($start, [Math]::Min([Math]::Max(0, $MaxChars), $full.Length - $start))
    $lines = @($window -csplit "\r?\n" | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    $result = [ordered]@{ url = $echoUrl; text = @($lines) }
    $rest = $full.Length - $start - $window.Length
    if ($rest -gt 0) { $result['omitted'] = ('{0} chars (use offset={1})' -f $rest, ($start + $window.Length)) }
    return $result
}
