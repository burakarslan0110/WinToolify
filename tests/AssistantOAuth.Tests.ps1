#Requires -Modules Pester

<#
.SYNOPSIS
    ChatGPT OAuth: the auth mode setting, the token store, PKCE, the
    authorize URI, id_token reading, callback parsing, expiry and the
    token exchange. Every network call goes through an injected seam -
    no network anywhere in this file.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:TargetPath = Join-Path $RepoRoot 'dist/WinToolify.ps1'
    . $TargetPath
}

Describe 'auth mode setting' {
    It 'round-trips AssistantAuthMode through settings.json' {
        $root = Join-Path $TestDrive 'mode-roundtrip'
        Save-WtSettings -Settings ([PSCustomObject]@{ AssistantAuthMode = 'ChatGPT' }) -TestRootOverride $root
        (Read-WtSettings -TestRootOverride $root).AssistantAuthMode | Should -Be 'ChatGPT'
    }

    It 'reads an absent AssistantAuthMode as empty, never null' {
        $root = Join-Path $TestDrive 'mode-absent'
        (Read-WtSettings -TestRootOverride $root).AssistantAuthMode | Should -Be ''
    }

    It 'keeps other assistant fields when only the auth mode is saved' {
        $root = Join-Path $TestDrive 'mode-merge'
        Save-WtSettings -Settings ([PSCustomObject]@{ AssistantModel = 'm1' }) -TestRootOverride $root
        Save-WtSettings -Settings ([PSCustomObject]@{ AssistantAuthMode = 'ChatGPT' }) -TestRootOverride $root
        $settings = Read-WtSettings -TestRootOverride $root
        $settings.AssistantModel | Should -Be 'm1'
        $settings.AssistantAuthMode | Should -Be 'ChatGPT'
    }
}

Describe 'the ChatGPT token store' {
    It 'round-trips tokens and never writes them in plain text' {
        $root = Join-Path $TestDrive 'store-roundtrip'
        Save-WtChatGptAuth -TestRootOverride $root -Auth @{
            AccessToken = 'access-secret-value'; RefreshToken = 'refresh-secret-value'
            ExpiresAt   = '2030-01-01T00:00:00Z'; AccountId = 'acct-1'; Email = 'a@b.c'; PlanType = 'plus'
        }
        $onDisk = Get-Content -LiteralPath (Get-WtChatGptAuthPath -TestRootOverride $root) -Raw
        $onDisk | Should -Not -Match 'access-secret-value'
        $onDisk | Should -Not -Match 'refresh-secret-value'
        $read = Read-WtChatGptAuth -TestRootOverride $root
        $read.AccessToken | Should -Be 'access-secret-value'
        $read.RefreshToken | Should -Be 'refresh-secret-value'
        $read.AccountId | Should -Be 'acct-1'
        $read.Email | Should -Be 'a@b.c'
        $read.PlanType | Should -Be 'plus'
    }

    It 'merges a partial save instead of erasing the fields it omits' {
        $root = Join-Path $TestDrive 'store-merge'
        Save-WtChatGptAuth -TestRootOverride $root -Auth @{
            AccessToken = 'old'; RefreshToken = 'rt-1'; AccountId = 'acct-1'; Email = 'a@b.c'
        }
        Save-WtChatGptAuth -TestRootOverride $root -Auth @{ AccessToken = 'new' }
        $read = Read-WtChatGptAuth -TestRootOverride $root
        $read.AccessToken | Should -Be 'new'
        $read.RefreshToken | Should -Be 'rt-1'
        $read.AccountId | Should -Be 'acct-1'
        $read.Email | Should -Be 'a@b.c'
    }

    It 'reads a missing or corrupt store as an empty session and never throws' {
        $root = Join-Path $TestDrive 'store-corrupt'
        (Read-WtChatGptAuth -TestRootOverride $root).AccessToken | Should -Be ''
        $path = Get-WtChatGptAuthPath -TestRootOverride $root
        Set-Content -LiteralPath $path -Value '{ not json' -Encoding UTF8
        { Read-WtChatGptAuth -TestRootOverride $root } | Should -Not -Throw
        (Read-WtChatGptAuth -TestRootOverride $root).RefreshToken | Should -Be ''
    }

    It 'clears the store and the auth mode together' {
        $root = Join-Path $TestDrive 'store-clear'
        Save-WtSettings -Settings ([PSCustomObject]@{ AssistantAuthMode = 'ChatGPT' }) -TestRootOverride $root
        Save-WtChatGptAuth -TestRootOverride $root -Auth @{ AccessToken = 'a'; RefreshToken = 'r' }
        Clear-WtChatGptAuth -TestRootOverride $root
        Test-Path -LiteralPath (Get-WtChatGptAuthPath -TestRootOverride $root) | Should -BeFalse
        (Read-WtSettings -TestRootOverride $root).AssistantAuthMode | Should -Be ''
    }

    It 'reads ExpiresAt back as the ISO text it was written as' {
        $root = Join-Path $TestDrive 'store-expiry'
        $iso = ([datetime]::UtcNow.AddHours(2)).ToString('o')
        Save-WtChatGptAuth -TestRootOverride $root -Auth @{ AccessToken = 'a'; RefreshToken = 'r'; ExpiresAt = $iso }
        (Read-WtChatGptAuth -TestRootOverride $root).ExpiresAt | Should -Be $iso
        Test-WtChatGptTokenExpiring -ExpiresAt (Read-WtChatGptAuth -TestRootOverride $root).ExpiresAt | Should -BeFalse
    }
}

Describe 'base64url' {
    It 'encodes without padding and with the url alphabet' {
        ConvertTo-WtBase64Url -Bytes ([byte[]]@(251, 255, 190)) | Should -Be '-_--'
        ConvertTo-WtBase64Url -Bytes ([byte[]]@(1)) | Should -Be 'AQ'
    }

    It 'decodes back, restoring the padding it needs' {
        [System.Text.Encoding]::UTF8.GetString((ConvertFrom-WtBase64Url -Text 'eyJhIjoxfQ')) | Should -Be '{"a":1}'
        (ConvertFrom-WtBase64Url -Text '').Length | Should -Be 0
        (ConvertFrom-WtBase64Url -Text 'A').Length | Should -Be 0
        (ConvertFrom-WtBase64Url -Text '!!!!').Length | Should -Be 0
    }
}

Describe 'PKCE' {
    It 'derives the challenge as base64url(SHA256(verifier))' {
        $pair = New-WtPkcePair -GetBytes { param($Count) return , ([byte[]](1..$Count)) }
        $expectedVerifier = ConvertTo-WtBase64Url -Bytes ([byte[]](1..64))
        $pair.Verifier | Should -Be $expectedVerifier
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $hash = $sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($expectedVerifier)) } finally { $sha.Dispose() }
        $pair.Challenge | Should -Be (ConvertTo-WtBase64Url -Bytes $hash)
    }

    It 'produces a verifier with no padding and no reserved characters' {
        $pair = New-WtPkcePair
        $pair.Verifier | Should -Not -Match '='
        $pair.Verifier | Should -Not -Match '\+'
        $pair.Verifier | Should -Not -Match '/'
        $pair.Verifier.Length | Should -BeGreaterThan 42
    }

    It 'gives a different state every call' {
        (New-WtOAuthState) | Should -Not -Be (New-WtOAuthState)
    }
}

Describe 'the authorize URI' {
    It 'carries every parameter the Codex flow requires' {
        $uri = Get-WtChatGptAuthorizeUri -Challenge 'chal+lenge' -State 'st/ate'
        $config = Get-WtChatGptOAuthConfig
        $uri | Should -BeLike ($config.AuthorizeUri + '?*')
        $uri | Should -Match 'response_type=code'
        $uri | Should -Match ('client_id=' + [regex]::Escape($config.ClientId))
        $uri | Should -Match 'code_challenge_method=S256'
        $uri | Should -Match 'id_token_add_organizations=true'
        $uri | Should -Match 'codex_cli_simplified_flow=true'
    }

    It 'url-encodes the challenge, state, scope and redirect' {
        $uri = Get-WtChatGptAuthorizeUri -Challenge 'chal+lenge' -State 'st/ate'
        $uri | Should -Match 'code_challenge=chal%2Blenge'
        $uri | Should -Match 'state=st%2Fate'
        $uri | Should -Match 'scope=openid%20profile%20email%20offline_access'
        $uri | Should -Match 'redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback'
    }
}

Describe 'the id_token payload' {
    It 'reads the email, account id and plan out of the auth claim' {
        $payload = @{
            email                         = 'a@b.c'
            'https://api.openai.com/auth' = @{ chatgpt_account_id = 'acct-9'; chatgpt_plan_type = 'pro' }
        } | ConvertTo-Json -Depth 5 -Compress
        $encoded = ConvertTo-WtBase64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes($payload))
        $read = ConvertFrom-WtJwtPayload -Token ('header.' + $encoded + '.signature')
        $read.Email | Should -Be 'a@b.c'
        $read.AccountId | Should -Be 'acct-9'
        $read.PlanType | Should -Be 'pro'
    }

    It 'returns the empty shape for anything unreadable' {
        foreach ($bad in @('', 'nodots', 'a.!!!!.c', 'a.eyJub3RqcyI.c')) {
            $read = ConvertFrom-WtJwtPayload -Token $bad
            $read.Email | Should -Be ''
            $read.AccountId | Should -Be ''
        }
    }
}

Describe 'the callback request' {
    It 'reads the code and state out of the GET line' {
        $parsed = ConvertFrom-WtOAuthCallbackRequest -RequestLine 'GET /auth/callback?code=abc%2F1&state=xyz HTTP/1.1'
        $parsed.Path | Should -Be '/auth/callback'
        $parsed.Code | Should -Be 'abc/1'
        $parsed.State | Should -Be 'xyz'
        $parsed.ErrorCode | Should -Be ''
    }

    It 'reports a denial as an error code, not a code' {
        $parsed = ConvertFrom-WtOAuthCallbackRequest -RequestLine 'GET /auth/callback?error=access_denied&state=xyz HTTP/1.1'
        $parsed.ErrorCode | Should -Be 'access_denied'
        $parsed.Code | Should -Be ''
    }

    It 'returns null for anything that is not a GET with a query' {
        ConvertFrom-WtOAuthCallbackRequest -RequestLine 'POST /auth/callback?code=a HTTP/1.1' | Should -BeNullOrEmpty
        ConvertFrom-WtOAuthCallbackRequest -RequestLine 'GET /favicon.ico HTTP/1.1' | Should -BeNullOrEmpty
        ConvertFrom-WtOAuthCallbackRequest -RequestLine '' | Should -BeNullOrEmpty
    }
}

Describe 'state matching and expiry' {
    It 'matches only an identical non-empty state' {
        Test-WtOAuthStateMatch -Expected 'abc' -Actual 'abc' | Should -BeTrue
        Test-WtOAuthStateMatch -Expected 'abc' -Actual 'abd' | Should -BeFalse
        Test-WtOAuthStateMatch -Expected 'abc' -Actual 'ab' | Should -BeFalse
        Test-WtOAuthStateMatch -Expected '' -Actual '' | Should -BeFalse
    }

    It 'calls a token expiring inside the five minute skew' {
        $now = [datetime]::SpecifyKind([datetime]'2026-09-07T12:00:00', [System.DateTimeKind]::Utc)
        Test-WtChatGptTokenExpiring -ExpiresAt '2026-09-07T12:04:00Z' -Now $now | Should -BeTrue
        Test-WtChatGptTokenExpiring -ExpiresAt '2026-09-07T12:06:00Z' -Now $now | Should -BeFalse
        Test-WtChatGptTokenExpiring -ExpiresAt '2026-09-07T11:00:00Z' -Now $now | Should -BeTrue
    }

    It 'treats a missing or unreadable expiry as expiring' {
        Test-WtChatGptTokenExpiring -ExpiresAt '' | Should -BeTrue
        Test-WtChatGptTokenExpiring -ExpiresAt 'not a date' | Should -BeTrue
    }
}

Describe 'the token endpoint' {
    BeforeAll {
        $script:MakeIdToken = {
            $payload = @{
                email                         = 'burak@example.com'
                'https://api.openai.com/auth' = @{ chatgpt_account_id = 'acct-7'; chatgpt_plan_type = 'plus' }
            } | ConvertTo-Json -Depth 5 -Compress
            return ('h.' + (ConvertTo-WtBase64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes($payload))) + '.s')
        }
        $script:OkBody = {
            return (@{
                    access_token = 'at-1'; refresh_token = 'rt-1'; expires_in = 3600; id_token = (& $script:MakeIdToken)
                } | ConvertTo-Json -Depth 5 -Compress)
        }
    }

    It 'encodes a form body with escaped values' {
        $body = ConvertTo-WtOAuthFormBody -Fields ([ordered]@{ grant_type = 'authorization_code'; code = 'a/b c' })
        $body | Should -Be 'grant_type=authorization_code&code=a%2Fb%20c'
    }

    It 'turns a token response into a session with an absolute expiry' {
        $now = [datetime]::SpecifyKind([datetime]'2026-09-07T12:00:00', [System.DateTimeKind]::Utc)
        $parsed = ConvertFrom-WtChatGptTokenResponse -Json (& $script:OkBody) -Now $now
        $parsed.Ok | Should -BeTrue
        $parsed.AccessToken | Should -Be 'at-1'
        $parsed.RefreshToken | Should -Be 'rt-1'
        $parsed.Email | Should -Be 'burak@example.com'
        $parsed.AccountId | Should -Be 'acct-7'
        $parsed.PlanType | Should -Be 'plus'
        ([datetime]::Parse($parsed.ExpiresAt, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime() | Should -Be $now.AddSeconds(3600)
    }

    It 'reports a body with no access token as not ok' {
        (ConvertFrom-WtChatGptTokenResponse -Json '{"error":"invalid_grant"}').Ok | Should -BeFalse
        (ConvertFrom-WtChatGptTokenResponse -Json 'not json').Ok | Should -BeFalse
    }

    It 'posts JSON first and retries the same fields form-encoded on a 400' {
        $seen = New-Object System.Collections.Generic.List[object]
        $ok = & $script:OkBody
        $transport = {
            param($Request)
            $seen.Add($Request)
            if ($seen.Count -eq 1) { return @{ Ok = $false; StatusCode = 400; Body = 'unsupported content type'; Cancelled = $false; Failure = '' } }
            return @{ Ok = $true; StatusCode = 200; Body = $ok; Cancelled = $false; Failure = '' }
        }.GetNewClosure()
        $r = Invoke-WtChatGptTokenExchange -Code 'the-code' -Verifier 'the-verifier' -Transport $transport
        $r.Ok | Should -BeTrue
        $seen.Count | Should -Be 2
        $seen[0].Body | Should -Match '"code":"the-code"'
        $seen[0].ContainsKey('ContentType') | Should -BeFalse
        $seen[1].Body | Should -Match 'code=the-code'
        $seen[1].Body | Should -Match 'code_verifier=the-verifier'
        $seen[1].ContentType | Should -Be 'application/x-www-form-urlencoded'
    }

    It 'maps a failing exchange onto the shared error kinds' {
        $r = Invoke-WtChatGptTokenExchange -Code 'c' -Verifier 'v' -Transport {
            param($Request) return @{ Ok = $false; StatusCode = 401; Body = 'nope'; Cancelled = $false; Failure = '' }
        }
        $r.Ok | Should -BeFalse
        $r.ErrorKind | Should -Be 'Auth'
        $r.ErrorText | Should -Not -BeNullOrEmpty
    }

    It 'sends the refresh grant with the stored refresh token' {
        $seen = New-Object System.Collections.Generic.List[object]
        $ok = & $script:OkBody
        $transport = {
            param($Request)
            $seen.Add($Request)
            return @{ Ok = $true; StatusCode = 200; Body = $ok; Cancelled = $false; Failure = '' }
        }.GetNewClosure()
        (Invoke-WtChatGptTokenRefresh -RefreshToken 'rt-old' -Transport $transport).Ok | Should -BeTrue
        $seen[0].Body | Should -Match '"grant_type":"refresh_token"'
        $seen[0].Body | Should -Match '"refresh_token":"rt-old"'
    }
}

Describe 'getting a usable access token' {
    It 'returns the stored token untouched while it is still fresh' {
        $root = Join-Path $TestDrive 'token-fresh'
        Save-WtChatGptAuth -TestRootOverride $root -Auth @{
            AccessToken = 'still-good'; RefreshToken = 'rt'; AccountId = 'acct-1'
            ExpiresAt   = ([datetime]::UtcNow.AddHours(2).ToString('o'))
        }
        $calls = New-Object System.Collections.Generic.List[object]
        $transport = {
            param($Request)
            $calls.Add($Request)
            return @{ Ok = $false; StatusCode = 500; Body = ''; Cancelled = $false; Failure = '' }
        }.GetNewClosure()
        $r = Get-WtChatGptAccessToken -TestRootOverride $root -Transport $transport
        $r.Ok | Should -BeTrue
        $r.AccessToken | Should -Be 'still-good'
        $r.AccountId | Should -Be 'acct-1'
        $calls.Count | Should -Be 0
    }

    It 'refreshes an expiring token and stores the new one' {
        $root = Join-Path $TestDrive 'token-refresh'
        Save-WtChatGptAuth -TestRootOverride $root -Auth @{
            AccessToken = 'old'; RefreshToken = 'rt-old'; AccountId = 'acct-1'
            ExpiresAt   = ([datetime]::UtcNow.AddMinutes(1).ToString('o'))
        }
        $body = @{ access_token = 'fresh'; refresh_token = 'rt-new'; expires_in = 3600 } | ConvertTo-Json -Compress
        $transport = {
            param($Request) return @{ Ok = $true; StatusCode = 200; Body = $body; Cancelled = $false; Failure = '' }
        }.GetNewClosure()
        $r = Get-WtChatGptAccessToken -TestRootOverride $root -Transport $transport
        $r.Ok | Should -BeTrue
        $r.AccessToken | Should -Be 'fresh'
        $stored = Read-WtChatGptAuth -TestRootOverride $root
        $stored.AccessToken | Should -Be 'fresh'
        $stored.RefreshToken | Should -Be 'rt-new'
        $stored.AccountId | Should -Be 'acct-1'
    }

    It 'reports Auth and keeps the session when the refresh fails' {
        $root = Join-Path $TestDrive 'token-refresh-fail'
        Save-WtChatGptAuth -TestRootOverride $root -Auth @{
            AccessToken = 'old'; RefreshToken = 'rt-old'; ExpiresAt = ([datetime]::UtcNow.AddMinutes(1).ToString('o'))
        }
        $r = Get-WtChatGptAccessToken -TestRootOverride $root -Transport {
            param($Request) return @{ Ok = $false; StatusCode = 400; Body = 'bad refresh'; Cancelled = $false; Failure = '' }
        }
        $r.Ok | Should -BeFalse
        $r.ErrorKind | Should -Be 'Auth'
        (Read-WtChatGptAuth -TestRootOverride $root).RefreshToken | Should -Be 'rt-old'
    }

    It 'reports Auth without any network when there is no session at all' {
        $root = Join-Path $TestDrive 'token-none'
        $calls = New-Object System.Collections.Generic.List[object]
        $transport = {
            param($Request)
            $calls.Add($Request)
            return @{ Ok = $true; StatusCode = 200; Body = '{}'; Cancelled = $false; Failure = '' }
        }.GetNewClosure()
        $r = Get-WtChatGptAccessToken -TestRootOverride $root -Transport $transport
        $r.Ok | Should -BeFalse
        $r.ErrorKind | Should -Be 'Auth'
        $calls.Count | Should -Be 0
    }
}

Describe 'the callback response page' {
    It 'counts Content-Length in bytes and closes the connection' {
        $text = Get-WtOAuthCallbackResponseText -Ok $true
        $text | Should -Match '^HTTP/1\.1 200 OK'
        $text | Should -Match 'Connection: close'
        $split = $text -split "`r`n`r`n", 2
        $declared = 0
        [void][int]::TryParse(([regex]::Match($split[0], 'Content-Length: (\d+)')).Groups[1].Value, [ref]$declared)
        $declared | Should -Be ([System.Text.Encoding]::ASCII.GetByteCount($split[1]))
    }

    It 'says something different when the sign-in failed' {
        (Get-WtOAuthCallbackResponseText -Ok $false) | Should -Not -Be (Get-WtOAuthCallbackResponseText -Ok $true)
    }

    It 'declares a length the UTF-8 writer will actually send' {
        foreach ($ok in @($true, $false)) {
            $split = (Get-WtOAuthCallbackResponseText -Ok $ok) -split "`r`n`r`n", 2
            $declared = 0
            [void][int]::TryParse(([regex]::Match($split[0], 'Content-Length: (\d+)')).Groups[1].Value, [ref]$declared)
            $declared | Should -Be ([System.Text.Encoding]::UTF8.GetByteCount($split[1]))
        }
    }

    It 'carries its whole design inline, since the listener serves one request' {
        $html = Get-WtOAuthCallbackPageHtml -Ok $true
        $html | Should -Match '(?i)^<!doctype html>'
        $html | Should -Match '(?i)<style>'
        $html | Should -Match '#0e1014'
        $html | Should -Not -Match '(?i)<(link|script)\b'
        $html | Should -Not -Match '(?i)https?://'
        ([regex]::Matches($html, '(?i)\ssrc\s*=\s*"([^"]*)"') | ForEach-Object { $_.Groups[1].Value }) |
            ForEach-Object { $_ | Should -Match '^data:image/png;base64,' }
    }

    It 'embeds the logo the site ships, byte for byte' {
        $shipped = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $RepoRoot 'site/assets/logo-160.png')))
        (Get-WtWinToolifyLogoDataUri) | Should -Be ('data:image/png;base64,' + $shipped)
        (Get-WtOAuthCallbackPageHtml -Ok $true) | Should -Match ([regex]::Escape('data:image/png;base64,'))
    }

    It 'warns about the account risk on the page that says the sign-in worked' {
        $saved = $script:Language
        try {
            foreach ($lang in @('EN', 'TR')) {
                $script:Language = $lang
                $risk = [string](Get-Translation 'AsChatGptPageOkRisk')
                $risk | Should -Not -BeNullOrEmpty
                (Get-WtOAuthCallbackPageHtml -Ok $true) | Should -Match ([regex]::Escape($risk))
                (Get-WtOAuthCallbackPageHtml -Ok $false) | Should -Not -Match ([regex]::Escape($risk))
            }
        }
        finally { $script:Language = $saved }
    }

    It 'writes the Turkish letters as entities, so an ASCII file still renders them' {
        $saved = $script:Language
        try {
            $script:Language = 'TR'
            (Get-WtOAuthCallbackPageHtml -Ok $true) | Should -Match '&#\d+;'
        }
        finally { $script:Language = $saved }
    }

    It 'stays ASCII in both languages, whatever the outcome' {
        $saved = $script:Language
        try {
            foreach ($lang in @('EN', 'TR')) {
                $script:Language = $lang
                foreach ($ok in @($true, $false)) {
                    $page = Get-WtOAuthCallbackPageHtml -Ok $ok
                    [System.Text.Encoding]::UTF8.GetByteCount($page) | Should -Be $page.Length -Because "$lang page $ok must survive a byte count"
                }
            }
        }
        finally { $script:Language = $saved }
    }

    It 'shows the failure in the failure colour and the localized heading' {
        $saved = $script:Language
        try {
            $script:Language = 'EN'
            (Get-WtOAuthCallbackPageHtml -Ok $true) | Should -Match ([regex]::Escape((Get-Translation 'AsChatGptPageOkTitle')))
            (Get-WtOAuthCallbackPageHtml -Ok $false) | Should -Match ([regex]::Escape((Get-Translation 'AsChatGptPageFailTitle')))
            (Get-WtOAuthCallbackPageHtml -Ok $false) | Should -Match '#e74856'
            (Get-WtOAuthCallbackPageHtml -Ok $true) | Should -Match '#16c60c'
            $script:Language = 'TR'
            (Get-WtOAuthCallbackPageHtml -Ok $true) | Should -Match 'lang="tr"'
        }
        finally { $script:Language = $saved }
    }
}

Describe 'waiting for the callback' {
    BeforeAll {
        $script:FakeListener = @{ Ok = $true; Listener = $null; Pending = @{ Client = $null } }
    }

    It 'accepts the matching callback and returns the code' {
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('')
        $lines.Add('GET /favicon.ico HTTP/1.1')
        $lines.Add('GET /auth/callback?code=the-code&state=st HTTP/1.1')
        $cursor = @{ Index = 0 }
        $answered = New-Object System.Collections.Generic.List[bool]
        $poll = {
            param($L)
            $line = [string]$lines[$cursor.Index]
            $cursor.Index++
            return $line
        }.GetNewClosure()
        $respond = { param($L, $Ok) $answered.Add([bool]$Ok) }.GetNewClosure()
        $r = Wait-WtOAuthCallback -State 'st' -Listener $script:FakeListener -Idle {} -GetNow { [datetime]::UtcNow } -Poll $poll -Respond $respond
        $r.Ok | Should -BeTrue
        $r.Code | Should -Be 'the-code'
        $r.ReasonKey | Should -Be ''
        $answered.Count | Should -Be 1
        $answered[0] | Should -BeTrue
    }

    It 'rejects a callback whose state does not match, and keeps no code' {
        $r = Wait-WtOAuthCallback -State 'st' -Listener $script:FakeListener -Idle {} -GetNow { [datetime]::UtcNow } `
            -Poll { param($L) return 'GET /auth/callback?code=the-code&state=WRONG HTTP/1.1' } `
            -Respond { param($L, $Ok) }
        $r.Ok | Should -BeFalse
        $r.Code | Should -Be ''
        $r.ReasonKey | Should -Be 'AsChatGptCancelled'
    }

    It 'reports a denial as cancelled' {
        $r = Wait-WtOAuthCallback -State 'st' -Listener $script:FakeListener -Idle {} -GetNow { [datetime]::UtcNow } `
            -Poll { param($L) return 'GET /auth/callback?error=access_denied&state=st HTTP/1.1' } `
            -Respond { param($L, $Ok) }
        $r.Ok | Should -BeFalse
        $r.ReasonKey | Should -Be 'AsChatGptCancelled'
    }

    It 'stops on Esc without waiting for the browser' {
        $r = Wait-WtOAuthCallback -State 'st' -Listener $script:FakeListener -Idle {} -GetNow { [datetime]::UtcNow } `
            -ShouldCancel { $true } -Poll { param($L) return '' } -Respond { param($L, $Ok) }
        $r.Ok | Should -BeFalse
        $r.ReasonKey | Should -Be 'AsChatGptCancelled'
    }

    It 'gives up when the deadline passes' {
        $start = [datetime]::SpecifyKind([datetime]'2026-09-07T12:00:00', [System.DateTimeKind]::Utc)
        $ticks = @{ Count = 0 }
        $getNow = {
            $ticks.Count++
            if ($ticks.Count -le 1) { return $start }
            return $start.AddSeconds(181)
        }.GetNewClosure()
        $r = Wait-WtOAuthCallback -State 'st' -Listener $script:FakeListener -TimeoutSeconds 180 -Idle {} `
            -GetNow $getNow -Poll { param($L) return '' } -Respond { param($L, $Ok) }
        $r.Ok | Should -BeFalse
        $r.ReasonKey | Should -Be 'AsChatGptTimeout'
    }
}

Describe 'the sign-in flow' {
    BeforeAll {
        $script:OpenListener = { return @{ Ok = $true; Listener = $null; Pending = @{ Client = $null } } }
        $script:GoodExchange = {
            param($Code, $Verifier)
            return @{ Ok = $true; ErrorKind = ''; ErrorText = ''; Auth = @{
                    AccessToken = 'at'; RefreshToken = 'rt'; ExpiresAt = ([datetime]::UtcNow.AddHours(1).ToString('o'))
                    AccountId   = 'acct-1'; Email = 'burak@example.com'; PlanType = 'plus'
                }
            }
        }
    }

    It 'stores the session and reports the account on success' {
        $root = Join-Path $TestDrive 'signin-ok'
        $opened = New-Object System.Collections.Generic.List[string]
        $openBrowser = { param($Uri) $opened.Add([string]$Uri); return $true }.GetNewClosure()
        $r = Invoke-WtChatGptSignIn -TestRootOverride $root -Listen $script:OpenListener -OpenBrowser $openBrowser `
            -Wait { param($State, $Listener) return @{ Ok = $true; Code = 'the-code'; ReasonKey = '' } } `
            -Exchange $script:GoodExchange
        $r.Ok | Should -BeTrue
        $r.Email | Should -Be 'burak@example.com'
        $r.PlanType | Should -Be 'plus'
        $opened[0] | Should -Match 'code_challenge_method=S256'
        (Read-WtChatGptAuth -TestRootOverride $root).AccessToken | Should -Be 'at'
        (Read-WtSettings -TestRootOverride $root).AssistantAuthMode | Should -Be 'ChatGPT'
    }

    It 'stops before the browser when port 1455 cannot be bound' {
        $root = Join-Path $TestDrive 'signin-port'
        $opened = New-Object System.Collections.Generic.List[string]
        $openBrowser = { param($Uri) $opened.Add([string]$Uri); return $true }.GetNewClosure()
        $r = Invoke-WtChatGptSignIn -TestRootOverride $root -OpenBrowser $openBrowser `
            -Listen { return @{ Ok = $false; Listener = $null; Pending = @{ Client = $null } } } `
            -Wait { param($State, $Listener) return @{ Ok = $true; Code = 'c'; ReasonKey = '' } } `
            -Exchange $script:GoodExchange
        $r.Ok | Should -BeFalse
        $r.ReasonKey | Should -Be 'AsChatGptPortBusy'
        $opened.Count | Should -Be 0
        (Read-WtSettings -TestRootOverride $root).AssistantAuthMode | Should -Be ''
    }

    It 'keeps waiting when the browser could not be launched, and hands back the address' {
        $root = Join-Path $TestDrive 'signin-nobrowser'
        $waits = New-Object System.Collections.Generic.List[string]
        $wait = { param($State, $Listener) $waits.Add([string]$State); return @{ Ok = $false; Code = ''; ReasonKey = 'AsChatGptTimeout' } }.GetNewClosure()
        $r = Invoke-WtChatGptSignIn -TestRootOverride $root -Listen $script:OpenListener `
            -OpenBrowser { param($Uri) return $false } -Wait $wait -Exchange $script:GoodExchange
        $waits.Count | Should -Be 1
        $r.Ok | Should -BeFalse
        $r.BrowserFailed | Should -BeTrue
        $r.AuthorizeUri | Should -Match 'client_id='
    }

    It 'writes nothing when the exchange fails' {
        $root = Join-Path $TestDrive 'signin-exchange-fail'
        $r = Invoke-WtChatGptSignIn -TestRootOverride $root -Listen $script:OpenListener `
            -OpenBrowser { param($Uri) return $true } `
            -Wait { param($State, $Listener) return @{ Ok = $true; Code = 'c'; ReasonKey = '' } } `
            -Exchange { param($Code, $Verifier) return @{ Ok = $false; ErrorKind = 'Auth'; ErrorText = 'nope'; Auth = $null } }
        $r.Ok | Should -BeFalse
        $r.ErrorText | Should -Be 'nope'
        Test-Path -LiteralPath (Get-WtChatGptAuthPath -TestRootOverride $root) | Should -BeFalse
        (Read-WtSettings -TestRootOverride $root).AssistantAuthMode | Should -Be ''
    }

    It 'closes the listener on the success path and on the give-up path' {
        $closed = New-Object System.Collections.Generic.List[object]
        $close = { param($Listener) $closed.Add($Listener) }.GetNewClosure()
        $waits = @(
            { param($State, $Listener) return @{ Ok = $true; Code = 'c'; ReasonKey = '' } },
            { param($State, $Listener) return @{ Ok = $false; Code = ''; ReasonKey = 'AsChatGptCancelled' } }
        )
        for ($i = 0; $i -lt $waits.Count; $i++) {
            $null = Invoke-WtChatGptSignIn -TestRootOverride (Join-Path $TestDrive ('signin-close-' + $i)) `
                -Listen $script:OpenListener -OpenBrowser { param($Uri) return $true } -Wait $waits[$i] -CloseListener $close `
                -Exchange { param($Code, $Verifier) return @{ Ok = $false; ErrorKind = 'Auth'; ErrorText = 'x'; Auth = $null } }
        }
        $closed.Count | Should -Be 2
    }

    It 'passes a fresh state and a matching verifier to the wait and the exchange' {
        $seen = @{ State = ''; Verifier = ''; Uri = '' }
        $openBrowser = { param($Uri) $seen.Uri = [string]$Uri; return $true }.GetNewClosure()
        $wait = { param($State, $Listener) $seen.State = [string]$State; return @{ Ok = $true; Code = 'c'; ReasonKey = '' } }.GetNewClosure()
        $exchange = {
            param($Code, $Verifier)
            $seen.Verifier = [string]$Verifier
            return @{ Ok = $false; ErrorKind = 'Auth'; ErrorText = 'x'; Auth = $null }
        }.GetNewClosure()
        $null = Invoke-WtChatGptSignIn -TestRootOverride (Join-Path $TestDrive 'signin-state') -Listen $script:OpenListener `
            -OpenBrowser $openBrowser -Wait $wait -Exchange $exchange
        $seen.State | Should -Not -BeNullOrEmpty
        $seen.Uri | Should -Match ('state=' + [regex]::Escape([uri]::EscapeDataString($seen.State)))
        $challenge = (ConvertTo-WtBase64Url -Bytes ([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::ASCII.GetBytes($seen.Verifier))))
        $seen.Uri | Should -Match ('code_challenge=' + [regex]::Escape([uri]::EscapeDataString($challenge)))
    }
}
