#Requires -Modules Pester

<#
.SYNOPSIS
    Keyless web research: the Learn search API parser, the DuckDuckGo
    HTML parser (uddg redirect decoding), the auto source router and the
    page-text stripper. Fixtures only - no network.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
    $script:FixtureDir = Join-Path $PSScriptRoot 'fixtures'
    $script:LearnJson = Get-Content -LiteralPath (Join-Path $FixtureDir 'learn-search.json') -Raw -Encoding UTF8
    $script:DdgHtml = Get-Content -LiteralPath (Join-Path $FixtureDir 'ddg-results.html') -Raw -Encoding UTF8
}

Describe 'Search-WtLearnDocs' {
    It 'parses titles, urls and snippets, and url-encodes the query' {
        $script:Requested = ''
        $results = @(Search-WtLearnDocs -Query 'bugcheck 0x133 nedir?' -Fetch { param($Uri) $script:Requested = $Uri; $script:LearnJson })
        $script:Requested | Should -Match ([regex]::Escape('learn.microsoft.com/api/search'))
        $script:Requested | Should -Match 'bugcheck%200x133'
        @($results).Count | Should -Be 2
        $results[0].url | Should -Match 'bug-check-0x133'
        $results[0].snippet | Should -Match 'DPC watchdog'
    }

    It 'a dead endpoint is an empty list, never a crash' {
        @(Search-WtLearnDocs -Query 'x' -Fetch { param($Uri) throw 'offline' }).Count | Should -Be 0
    }

    It 'reports a dead endpoint or broken JSON through -Status and still returns the empty list; a real empty answer is not a failure' {
        $dead = @{}
        @(Search-WtLearnDocs -Query 'q' -Fetch { throw 'offline' } -Status $dead).Count | Should -Be 0
        $dead['failed'] | Should -BeTrue
        $broken = @{}
        @(Search-WtLearnDocs -Query 'q' -Fetch { param($Uri) '<html>oops' } -Status $broken).Count | Should -Be 0
        $broken['failed'] | Should -BeTrue
        $none = @{}
        @(Search-WtLearnDocs -Query 'q' -Fetch { param($Uri) '{"results":[]}' } -Status $none).Count | Should -Be 0
        $none.ContainsKey('failed') | Should -BeFalse
    }

    It 'caps the rows at five and the snippet at 160 characters with a ~ marker' {
        $long = 'w' * 300
        $json = '{"results":[' + (@(1..7 | ForEach-Object { '{"title":"t' + $_ + '","url":"https://learn.microsoft.com/' + $_ + '","description":"' + $long + '"}' }) -join ',') + ']}'
        $rows = @(Search-WtLearnDocs -Query 'q' -Fetch { param($Uri) $json })
        $rows.Count | Should -Be 5
        $rows[0].snippet.Length | Should -Be 160
        $rows[0].snippet | Should -Match '~$'
        (ConvertTo-WtWebSnippet -Text "  two   lines`nhere  ") | Should -Be 'two lines here'
    }
}

Describe 'Search-WtDuckDuckGo' {
    It 'extracts real urls from the uddg redirect and strips tags from titles' {
        $results = @(Search-WtDuckDuckGo -Query 'dpc watchdog' -Fetch { param($Uri) $script:DdgHtml })
        @($results).Count | Should -Be 2
        $results[0].url | Should -Be 'https://www.howtogeek.com/742322/how-to-fix/dpc-watchdog-violation/'
        $results[0].title | Should -Be 'How to Fix a DPC Watchdog Violation in Windows 10'
        $results[1].title | Should -Match 'Q&A'
    }

    It 'unknown markup is an empty list' {
        @(Search-WtDuckDuckGo -Query 'x' -Fetch { param($Uri) '<html><body>captcha</body></html>' }).Count | Should -Be 0
    }

    It 'reads the snippet element that follows a result anchor and leaves it empty when there is none' {
        $results = @(Search-WtDuckDuckGo -Query 'q' -Fetch { param($Uri) $script:DdgHtml })
        $results[0].snippet | Should -Match 'driver'
        $results[1].snippet | Should -Be ''
    }

    It 'a dead endpoint sets Status failed; unknown markup does not' {
        $dead = @{}
        @(Search-WtDuckDuckGo -Query 'q' -Fetch { throw 'offline' } -Status $dead).Count | Should -Be 0
        $dead['failed'] | Should -BeTrue
        $captcha = @{}
        @(Search-WtDuckDuckGo -Query 'q' -Fetch { param($Uri) '<html><body>captcha</body></html>' } -Status $captcha).Count | Should -Be 0
        $captcha.ContainsKey('failed') | Should -BeFalse
    }
}

Describe 'Get-WtAssistantWebSearch' {
    It 'asks Learn first and falls to DuckDuckGo only when Learn is empty; rows are title, url, snippet' {
        $r = Get-WtAssistantWebSearch -Query 'q' -FetchLearn { param($Uri) $script:LearnJson } -FetchDdg { param($Uri) throw 'must not be called' }
        @($r['results']).Count | Should -Be 2
        @($r['results'])[0].url | Should -Match 'bug-check-0x133'
        @($r['results'])[0].snippet | Should -Match 'DPC watchdog'
        $r.Contains('error') | Should -BeFalse
        $empty = '{"results":[]}'
        $r2 = Get-WtAssistantWebSearch -Query 'q' -FetchLearn { param($Uri) $empty } -FetchDdg { param($Uri) $script:DdgHtml }
        @($r2['results']).Count | Should -Be 2
        @($r2['results'])[0].url | Should -Be 'https://www.howtogeek.com/742322/how-to-fix/dpc-watchdog-violation/'
        (Get-Command Get-WtAssistantWebSearch).Parameters.ContainsKey('Source') | Should -BeFalse
    }

    It 'both engines empty is results: none; both engines dead is error: search failed with a hint; one dead and one empty is still none' {
        $none = Get-WtAssistantWebSearch -Query 'q' -FetchLearn { param($Uri) '{"results":[]}' } -FetchDdg { param($Uri) '<html><body>captcha</body></html>' }
        $none['results'] | Should -Be 'none'
        $none.Contains('error') | Should -BeFalse
        (ConvertTo-WtAssistantToolText -Value $none) | Should -Be 'results: none'
        $dead = Get-WtAssistantWebSearch -Query 'q' -FetchLearn { param($Uri) throw 'offline' } -FetchDdg { param($Uri) throw 'offline' }
        $dead['error'] | Should -Be 'search failed'
        $dead['hint'] | Should -Be 'answer from what you know or try different words'
        $dead.Contains('results') | Should -BeFalse
        $half = Get-WtAssistantWebSearch -Query 'q' -FetchLearn { param($Uri) throw 'offline' } -FetchDdg { param($Uri) '<html><body>captcha</body></html>' }
        $half['results'] | Should -Be 'none'
    }

    It 'serializes as one header and TSV rows, and drops the snippet column when no row has one' {
        $r = Get-WtAssistantWebSearch -Query 'q' -FetchLearn { param($Uri) $script:LearnJson } -FetchDdg { param($Uri) throw 'no' }
        $lines = @((ConvertTo-WtAssistantToolText -Value $r) -split "`n")
        $lines[0] | Should -Be 'results:'
        $lines[1] | Should -Be '  title | url | snippet'
        $lines.Count | Should -Be 4
        $bare = Get-WtAssistantWebSearch -Query 'q' -FetchLearn { param($Uri) '{"results":[{"title":"a","url":"https://x/a"},{"title":"b","url":"https://x/b"}]}' } -FetchDdg { param($Uri) throw 'no' }
        @((ConvertTo-WtAssistantToolText -Value $bare) -split "`n")[1] | Should -Be '  title | url'
        (ConvertTo-WtAssistantToolText -Value $r).Length | Should -BeLessOrEqual 1500
    }
}

Describe 'page fetching' {
    It 'strips scripts, styles and tags, decodes entities and keeps paragraph breaks' {
        $html = '<html><head><style>.x{}</style><script>var a=1;</script></head><body><h1>Baslik</h1><p>Ilk &amp; paragraf</p><p>Ikinci</p></body></html>'
        $text = ConvertTo-WtWebPageText -Html $html
        $text | Should -Not -Match 'var a'
        $text | Should -Not -Match '\.x\{\}'
        $text | Should -Match 'Baslik'
        $text | Should -Match 'Ilk & paragraf'
        ($text -csplit "\r?\n").Count | Should -BeGreaterThan 1
    }

    It 'prefers the <main> or <article> element and drops nav and footer text; a page without them is read whole' {
        $html = '<html><head><title>Site</title></head><body><nav><a>Home</a> <a>Docs</a> <a>Blog</a></nav><div>Sidebar links and promotions fill this column</div><main><h1>Real title</h1><p>Paragraph one is long enough to count as the real content of the page.</p></main><footer>Copyright 2026 Example</footer></body></html>'
        $text = ConvertTo-WtWebPageText -Html $html
        $text | Should -Match 'Real title'
        $text | Should -Match 'Paragraph one'
        $text | Should -Not -Match 'Sidebar'
        $text | Should -Not -Match 'Home'
        $text | Should -Not -Match 'Copyright'
        $article = ConvertTo-WtWebPageText -Html '<body><div>Menu</div><article><p>Article body text with more than four words.</p></article><div>Comments section text goes here now</div></body>'
        $article | Should -Match 'Article body'
        $article | Should -Not -Match 'Comments'
        $shell = ConvertTo-WtWebPageText -Html '<body><main></main><p>Fallback prose is here for the whole document path.</p></body>'
        $shell | Should -Match 'Fallback prose'
        (ConvertTo-WtWebPageText -Html '<body><mainframe>x</mainframe><nav>Home</nav><p>ok</p><footer>c</footer></body>') | Should -Be 'x ok'
        (Select-WtHtmlMainBlock -Html '<body><main class="a">inner <b>x</b></main></body>') | Should -Be 'inner <b>x</b>'
        (Select-WtHtmlMainBlock -Html '<body><main>never closed') | Should -Be ''
    }

    It 'drops a leading run of short navigation lines only when real prose follows; short pages and a lone title stay whole' {
        $lines = ConvertTo-WtWebPageText -Html '<body><div>Home</div><div>Docs</div><div>Sign in</div><h1>Bug Check 0x133</h1><p>This bug check indicates that the DPC watchdog executed.</p></body>'
        $lines | Should -Not -Match 'Sign in'
        $lines | Should -Match 'DPC watchdog'
        (ConvertTo-WtWebPageText -Html '<body><h1>Title</h1><p>Only three words</p></body>') | Should -Be "Title`nOnly three words"
        (ConvertTo-WtWebPageText -Html '<body><h1>Short title</h1><p>Then a real paragraph with several words in it.</p></body>') | Should -Match '^Short title'
        (Remove-WtWebPageLeadingNav -Text "a`nb`nc d e f g`nh") | Should -Be "c d e f g`nh"
        (Remove-WtWebPageLeadingNav -Text "a`nc d e f g") | Should -Be "a`nc d e f g"
    }

    It 'returns a 3000-character window, continues with offset and names the rest as omitted' {
        $body = '<p>' + ((1..400 | ForEach-Object { 'word' + $_ }) -join ' ') + '</p>'
        $hop = { param($Uri) @{ StatusCode = 200; Location = ''; Content = $body } }
        $r = Get-WtAssistantFetchPage -Url 'https://x.example/a' -FetchHop $hop
        ($r['text'] -join "`n").Length | Should -BeLessOrEqual 3000
        ($r['text'] -join "`n").Length | Should -BeGreaterThan 2990
        $r['omitted'] | Should -Match '^\d+ chars \(use offset=3000\)$'
        $rest = Get-WtAssistantFetchPage -Url 'https://x.example/a' -Offset 3000 -FetchHop $hop
        $rest.Contains('omitted') | Should -BeFalse
        ($rest['text'] -join ' ') | Should -Match 'word400$'
        $past = Get-WtAssistantFetchPage -Url 'https://x.example/a' -Offset 99999 -FetchHop $hop
        @($past['text']).Count | Should -Be 0
        $past.Contains('error') | Should -BeFalse
        $small = Get-WtAssistantFetchPage -Url 'https://x.example/a' -FetchHop { param($Uri) @{ StatusCode = 200; Location = ''; Content = '<p>' + ('z' * 20000) + '</p>' } } -MaxChars 500
        ($small['text'] -join '').Length | Should -Be 500
        $small['omitted'] | Should -Be '19500 chars (use offset=500)'
        (Get-WtAssistantFetchPage -Url 'file:///C:/secret.txt' -FetchHop { param($Uri) @{ StatusCode = 200; Location = ''; Content = 'x' } }).text | Should -Be ''
        $text = ConvertTo-WtAssistantToolText -Value $r -MaxChars ((Get-WtAssistantToolRecord -Name 'fetch_page').MaxChars)
        $text | Should -Not -Match '(?m)^omitted: \d+ lines$'
        $text | Should -Match '(?m)^omitted: \d+ chars \(use offset=3000\)$'
        $text | Should -Match '(?m)^url: https://x\.example/a$'
    }

    It 'paragraphs reach the model as separate text lines' {
        $r = Get-WtAssistantFetchPage -Url 'https://x.example/p' -FetchHop { param($Uri) @{ StatusCode = 200; Location = ''; Content = '<main><p>First paragraph has more than twenty four characters.</p><p>Second paragraph also has more than twenty four characters.</p></main>' } }
        @($r['text']).Count | Should -Be 2
        $lines = @((ConvertTo-WtAssistantToolText -Value $r) -split "`n")
        $lines[1] | Should -Be 'text:'
        $lines[2] | Should -Match '^  First paragraph'
        $lines[3] | Should -Match '^  Second paragraph'
    }
}

Describe 'ConvertTo-WtWebPageText: pathological HTML (fix round)' {
    It 'an unclosed script, style or head tag no longer causes quadratic-time blowup' {
        $sb = New-Object System.Text.StringBuilder
        for ($i = 0; $i -lt 4000; $i++) { [void]$sb.Append('<script>var x' + $i + ' = 1; if (x' + $i + '<1) y' + $i + '++;') }
        $html = '<html><body>' + $sb.ToString() + '<p>end marker</p></body></html>'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $text = ConvertTo-WtWebPageText -Html $html
        $sw.Stop()
        $sw.ElapsedMilliseconds | Should -BeLessThan 3000
        $text | Should -Match 'end marker'
    }

    It 'real prose after an unclosed tag survives instead of silently vanishing' {
        $filler = 'REALCONTENT ' * 500
        $html = '<html><body><script>var a = 1; if (a<1) { return; }' + $filler + '<p>Ikinci paragraf</p></body></html>'
        $text = ConvertTo-WtWebPageText -Html $html
        $text | Should -Match 'REALCONTENT'
        $text | Should -Match 'Ikinci paragraf'
    }

    It 'a legitimate closed pair FIRST, then many unclosed lookalikes, does not reopen the hang' {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('<script>var legit=1;</script>')
        for ($i = 0; $i -lt 2000; $i++) { [void]$sb.Append('<script>var x' + $i + '=1; if (x' + $i + '<1) y' + $i + '++;') }
        $html = '<html><body>' + $sb.ToString() + '<p>end marker</p></body></html>'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $text = ConvertTo-WtWebPageText -Html $html -RegexTimeoutSeconds 30
        $sw.Stop()
        $sw.ElapsedMilliseconds | Should -BeLessThan 3000
        $text | Should -Match 'end marker'
    }

    It 'a legitimate closed pair in the MIDDLE of many unclosed lookalikes does not reopen the hang' {
        $sb = New-Object System.Text.StringBuilder
        for ($i = 0; $i -lt 500; $i++) { [void]$sb.Append('<script>var p' + $i + '=1; if (p' + $i + '<1) q' + $i + '++;') }
        [void]$sb.Append('<script>var legit=1;</script>')
        for ($i = 0; $i -lt 2000; $i++) { [void]$sb.Append('<script>var x' + $i + '=1; if (x' + $i + '<1) y' + $i + '++;') }
        $html = '<html><body>' + $sb.ToString() + '<p>end marker</p></body></html>'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $text = ConvertTo-WtWebPageText -Html $html -RegexTimeoutSeconds 30
        $sw.Stop()
        $sw.ElapsedMilliseconds | Should -BeLessThan 3000
        $text | Should -Match 'end marker'
    }

    It 'a legitimate closed pair LAST, after many unclosed lookalikes, still does not hang' {
        $sb = New-Object System.Text.StringBuilder
        for ($i = 0; $i -lt 2000; $i++) { [void]$sb.Append('<script>var x' + $i + '=1; if (x' + $i + '<1) y' + $i + '++;') }
        [void]$sb.Append('<script>var legit=1;</script>')
        $html = '<html><body>' + $sb.ToString() + '<p>end marker</p></body></html>'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $text = ConvertTo-WtWebPageText -Html $html -RegexTimeoutSeconds 30
        $sw.Stop()
        $sw.ElapsedMilliseconds | Should -BeLessThan 3000
        $text | Should -Match 'end marker'
    }

    It 'closed and unclosed occurrences interleaved throughout do not hang' {
        $sb = New-Object System.Text.StringBuilder
        for ($i = 0; $i -lt 2000; $i++) {
            [void]$sb.Append('<script>var u' + $i + '=1; if (u' + $i + '<1) z' + $i + '++;')
            [void]$sb.Append('<script>var c' + $i + '=1;</script>')
        }
        $html = '<html><body>' + $sb.ToString() + '<p>end marker</p></body></html>'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $text = ConvertTo-WtWebPageText -Html $html -RegexTimeoutSeconds 30
        $sw.Stop()
        $sw.ElapsedMilliseconds | Should -BeLessThan 3000
        $text | Should -Match 'end marker'
    }

    It 'a regex timeout degrades to a usable result instead of throwing' {
        $sb = New-Object System.Text.StringBuilder
        for ($i = 0; $i -lt 500; $i++) { [void]$sb.Append('<script>var x' + $i + ' = 1;') }
        $html = '<html><body>' + $sb.ToString() + '<p>end marker</p></body></html>'
        { ConvertTo-WtWebPageText -Html $html -RegexTimeoutSeconds 0.001 } | Should -Not -Throw
        (ConvertTo-WtWebPageText -Html $html -RegexTimeoutSeconds 0.001) | Should -Match 'end marker'
    }

    It 'caps a pathologically large body before any regex runs' {
        $huge = '<html><body><p>' + ('a' * 5000000) + '</p></body></html>'
        (ConvertTo-WtWebPageText -Html $huge -MaxInputChars 1000).Length | Should -BeLessOrEqual 1000
    }

    It 'a large PROPERLY CLOSED script does not leak as noise and the real prose after it survives' {
        $hydration = '{"items":[' + ((1..300 | ForEach-Object { '{"id":' + $_ + ',"name":"item ' + $_ + '"}' }) -join ',') + ']}'
        $script = '<script id="data" type="application/json">' + $hydration + '</script>'
        $script.Length | Should -BeGreaterThan 4000
        $html = '<html><body>' + $script + '<p>REALPROSE the content the model actually needs</p></body></html>'
        $text = ConvertTo-WtWebPageText -Html $html
        $text | Should -Match 'REALPROSE'
        $text | Should -Not -Match '"items"'
    }
}

Describe 'Get-WtAssistantFetchPage: destination and url-field guards (fix round)' {
    It 'refuses loopback, RFC1918, link-local and localhost destinations without ever fetching' {
        $cases = 'http://127.0.0.1/', 'http://127.5.5.5/', 'http://[::1]/',
            'http://10.0.0.5/', 'http://172.16.0.1/', 'http://192.168.1.1/',
            'http://169.254.169.254/', 'http://[fe80::1]/',
            'http://localhost/', 'http://LOCALHOST/', 'http://foo.localhost/',
            'http://[::ffff:192.168.1.1]/', 'http://[::ffff:169.254.169.254]/', 'http://[::ffff:127.0.0.1]/',
            'http://localhost./', 'http://0.0.0.0/', 'http://[::]/',
            'http://[fd00::1]/', 'http://[fc00::1]/', 'http://[fdff:ffff::1]/',
            'http://100.64.0.1/', 'http://100.100.5.5/', 'http://100.127.255.254/',
            'http://2130706433/', 'http://0177.0.0.1/', 'http://127.1/', 'http://0x7f000001/'
        foreach ($url in $cases) {
            $script:called = $false
            $r = Get-WtAssistantFetchPage -Url $url -FetchHop { param($Uri) $script:called = $true; @{ StatusCode = 200; Location = ''; Content = 'x' } }
            $script:called | Should -BeFalse -Because $url
            $r.text | Should -Be ''
        }
    }

    It 'still fetches a normal public destination' {
        (Get-WtAssistantFetchPage -Url 'http://example.com/ok' -FetchHop { param($Uri) @{ StatusCode = 200; Location = ''; Content = '<p>ok</p>' } }).text | Should -Be 'ok'
    }

    It 'the new ranges stop exactly at their edges - public neighbours still fetch' {
        foreach ($url in 'http://100.63.255.255/', 'http://100.128.0.1/', 'http://[2001:db8::1]/', 'http://[2606:4700::1]/') {
            (Get-WtAssistantFetchPage -Url $url -FetchHop { param($Uri) @{ StatusCode = 200; Location = ''; Content = '<p>ok</p>' } }).text |
                Should -Be 'ok' -Because $url
        }
    }

    It 'caps the echoed url field but still fetches with the full original url' {
        $longUrl = 'https://example.com/path?q=' + ('a' * 5000)
        $script:SeenUri = ''
        $r = Get-WtAssistantFetchPage -Url $longUrl -FetchHop { param($Uri) $script:SeenUri = $Uri; @{ StatusCode = 200; Location = ''; Content = '<p>ok</p>' } } -MaxUrlChars 500
        $r.url.Length | Should -BeLessOrEqual 501
        $script:SeenUri | Should -Be $longUrl
    }

    It 'follows a redirect chain across public hosts and returns the final content' {
        $r = Get-WtAssistantFetchPage -Url 'https://shortener.example/a' -FetchHop {
            param($Uri)
            if ($Uri -eq 'https://shortener.example/a') { return @{ StatusCode = 301; Location = 'https://real.example/b'; Content = '' } }
            if ($Uri -eq 'https://real.example/b') { return @{ StatusCode = 200; Location = ''; Content = '<p>final</p>' } }
            throw ('unexpected hop: ' + $Uri)
        }
        $r.text | Should -Be 'final'
    }

    It 'a redirect chain whose second hop resolves to a blocked host is refused, without that hop ever reaching the seam' {
        $script:hopsSeen = New-Object System.Collections.Generic.List[string]
        $r = Get-WtAssistantFetchPage -Url 'https://shortener.example/a' -FetchHop {
            param($Uri)
            $script:hopsSeen.Add($Uri)
            if ($Uri -eq 'https://shortener.example/a') { return @{ StatusCode = 302; Location = 'http://169.254.169.254/secret'; Content = '' } }
            throw 'must not reach the blocked hop'
        }
        @($script:hopsSeen.ToArray()) | Should -Be @('https://shortener.example/a')
        $r.text | Should -Be ''
    }

    It 'gives up safely after too many redirect hops rather than looping forever' {
        $script:redirectCalls = 0
        $r = Get-WtAssistantFetchPage -Url 'https://a.example/1' -MaxRedirects 3 -FetchHop {
            param($Uri)
            $script:redirectCalls++
            @{ StatusCode = 302; Location = 'https://a.example/next'; Content = '' }
        }
        $r.text | Should -Be ''
        $script:redirectCalls | Should -BeLessOrEqual 4
    }
}

Describe 'Read-WtBoundedText: the body read is bounded in size AND in time' {
    BeforeAll {
        function New-WtEndlessReaderStub {
            $stub = New-Object PSObject
            $stub | Add-Member -MemberType NoteProperty -Name Calls -Value 0
            $stub | Add-Member -MemberType ScriptMethod -Name Read -Value {
                param($Buffer, $Index, $Count)
                $this.Calls++
                for ($i = 0; $i -lt $Count; $i++) { $Buffer[$Index + $i] = 'x' }
                return $Count
            }
            return $stub
        }
    }

    It 'returns exactly the cap from an ENDLESS stream instead of hanging' {
        $reader = New-WtEndlessReaderStub
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $text = Read-WtBoundedText -Reader $reader -MaxChars 100000
        $watch.Stop()
        $text.Length | Should -Be 100000
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 10
    }

    It 'never overshoots the cap even when the cap is not a multiple of the buffer' {
        (Read-WtBoundedText -Reader (New-WtEndlessReaderStub) -MaxChars 1).Length | Should -Be 1
        (Read-WtBoundedText -Reader (New-WtEndlessReaderStub) -MaxChars 8193).Length | Should -Be 8193
        (Read-WtBoundedText -Reader (New-WtEndlessReaderStub) -MaxChars 0).Length | Should -Be 0
    }

    It 'discards the rest of the stream rather than draining it' {
        $reader = New-Object System.IO.StringReader (New-Object string ('a', 50000))
        $text = Read-WtBoundedText -Reader $reader -MaxChars 1000
        $text.Length | Should -Be 1000
        $reader.Peek() | Should -BeGreaterOrEqual 0
    }

    It 'a short stream still comes back whole' {
        $reader = New-Object System.IO.StringReader '<p>hello</p>'
        Read-WtBoundedText -Reader $reader -MaxChars 4000000 | Should -Be '<p>hello</p>'
    }

    It 'the wall-clock deadline stops an endless stream that never trips the per-read timeout' {
        $reader = New-WtEndlessReaderStub
        $text = Read-WtBoundedText -Reader $reader -MaxChars 100000000 -TimeoutMs 500 -Clock { 900 }
        $text.Length | Should -Be 8192
        $reader.Calls | Should -Be 1
    }

    It 'TimeoutMs 0 disables the deadline but the character cap still stops it' {
        (Read-WtBoundedText -Reader (New-WtEndlessReaderStub) -MaxChars 20000 -TimeoutMs 0 -Clock { 999999 }).Length | Should -Be 20000
    }

    It 'a read failure still propagates, so the caller keeps turning it into the fetch_page error shape' {
        $stub = New-Object PSObject
        $stub | Add-Member -MemberType ScriptMethod -Name Read -Value { param($Buffer, $Index, $Count) throw 'connection reset' }
        { Read-WtBoundedText -Reader $stub -MaxChars 100 } | Should -Throw
    }

    It 'the default FetchHop sets ReadWriteTimeout and reads through the bounded reader, never ReadToEnd' {
        $default = ''
        foreach ($p in (Get-Command Get-WtAssistantFetchPage).ScriptBlock.Ast.Body.ParamBlock.Parameters) {
            if ([string]$p.Name.VariablePath.UserPath -eq 'FetchHop') { $default = [string]$p.DefaultValue.Extent.Text }
        }
        $default | Should -Not -BeNullOrEmpty
        $default.IndexOf('ReadWriteTimeout', [System.StringComparison]::Ordinal) | Should -BeGreaterThan -1
        $default.IndexOf('Read-WtBoundedText', [System.StringComparison]::Ordinal) | Should -BeGreaterThan -1
        $default.IndexOf('ReadToEnd', [System.StringComparison]::Ordinal) | Should -Be -1
    }
}

Describe 'Get-WtAssistantFetchPage: a refusal is distinguishable from an empty page' {
    It 'names the reason on every failure path, and keeps the rest of the shape' {
        $ok = { param($Uri) @{ StatusCode = 200; Location = ''; Content = '<p>x</p>' } }
        $cases = @(
            @{ Url = 'ftp://example.com/x'; Hop = $ok; Reason = 'unsupported scheme' }
            @{ Url = 'not a url at all'; Hop = $ok; Reason = 'unsupported scheme' }
            @{ Url = 'http://127.0.0.1/x'; Hop = $ok; Reason = 'blocked destination' }
            @{ Url = 'http://example.com/x'; Hop = { param($Uri) throw 'dns died' }; Reason = 'fetch failed' }
            @{ Url = 'http://example.com/x'; Hop = { param($Uri) $null }; Reason = 'fetch failed' }
            @{ Url = 'http://example.com/x'; Hop = { param($Uri) @{ StatusCode = 302; Location = 'http:// bad target'; Content = '' } }; Reason = 'fetch failed' }
            @{ Url = 'http://example.com/x'; Hop = { param($Uri) @{ StatusCode = 302; Location = 'http://example.com/next'; Content = '' } }; Reason = 'too many redirects' }
        )
        foreach ($case in $cases) {
            $r = Get-WtAssistantFetchPage -Url ([string]$case.Url) -FetchHop ([scriptblock]$case.Hop) -MaxRedirects 2
            [string]$r.error | Should -Be ([string]$case.Reason) -Because ([string]$case.Url + ' / ' + [string]$case.Reason)
            [string]$r.text | Should -Be ''
            $r.Contains('omitted') | Should -BeFalse
            [string]$r.url | Should -Be ([string]$case.Url)
        }
    }

    It 'a genuinely EMPTY page carries no error key, so the model can tell the two apart' {
        $empty = Get-WtAssistantFetchPage -Url 'http://example.com/blank' -FetchHop { param($Uri) @{ StatusCode = 200; Location = ''; Content = '<html><body></body></html>' } }
        @($empty['text']).Count | Should -Be 0
        $empty.Contains('error') | Should -BeFalse
        $refused = Get-WtAssistantFetchPage -Url 'http://10.0.0.5/secret' -FetchHop { param($Uri) @{ StatusCode = 200; Location = ''; Content = 'x' } }
        $refused.Contains('error') | Should -BeTrue
    }

    It 'a successful page keeps its shape: url and text, plus omitted only when a rest exists' {
        $r = Get-WtAssistantFetchPage -Url 'http://example.com/ok' -FetchHop { param($Uri) @{ StatusCode = 200; Location = ''; Content = '<p>ok</p>' } }
        @($r.Keys | Sort-Object) | Should -Be @('text', 'url')
        $long = Get-WtAssistantFetchPage -Url 'http://example.com/long' -FetchHop { param($Uri) @{ StatusCode = 200; Location = ''; Content = '<p>' + ('q' * 5000) + '</p>' } }
        @($long.Keys | Sort-Object) | Should -Be @('omitted', 'text', 'url')
    }
}
