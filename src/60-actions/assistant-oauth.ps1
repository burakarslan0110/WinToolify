# ChatGPT (OpenAI) OAuth: the constants, PKCE, the authorize URI, the
# id_token payload, callback parsing and token lifetime.
# Covered by: tests/AssistantOAuth.Tests.ps1

function Get-WtChatGptOAuthConfig {
    <#
    .SYNOPSIS
        Every OpenAI OAuth constant in one place, so a value OpenAI
        changes is a one-function edit. The redirect port is fixed at
        1455 because that is the callback URL registered for this
        client - a random free port would be rejected.
    #>
    return @{
        ClientId     = 'app_EMoamEEZ73f0CkXaXp7hrann'
        AuthorizeUri = 'https://auth.openai.com/oauth/authorize'
        TokenUri     = 'https://auth.openai.com/oauth/token'
        RedirectUri  = 'http://localhost:1455/auth/callback'
        RedirectPort = 1455
        Scope        = 'openid profile email offline_access'
        ApiBase      = 'https://chatgpt.com/backend-api/codex'
        Originator   = 'wintoolify'
    }
}

function ConvertTo-WtBase64Url {
    <#
    .SYNOPSIS
        PURE: bytes as unpadded base64url. String.Replace is ordinal, so
        the tr-TR casing rules that break -replace cannot reach it.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    return ([Convert]::ToBase64String($Bytes)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-WtBase64Url {
    <#
    .SYNOPSIS
        PURE: the inverse, restoring the padding base64url dropped. A
        length that leaves remainder 1 is impossible in base64, so it -
        like any unparseable input - returns no bytes rather than throwing.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)
    $text = ([string]$Text).Replace('-', '+').Replace('_', '/')
    if (-not $text) { return [byte[]]@() }
    $remainder = $text.Length % 4
    if ($remainder -eq 1) { return [byte[]]@() }
    if ($remainder -eq 2) { $text = $text + '==' }
    elseif ($remainder -eq 3) { $text = $text + '=' }
    try { return [byte[]][Convert]::FromBase64String($text) } catch { return [byte[]]@() }
}

function New-WtPkcePair {
    <#
    .SYNOPSIS
        A PKCE verifier and its S256 challenge. The verifier is hashed as
        ASCII, not UTF-8 - RFC 7636 defines the challenge over the ASCII
        text of the verifier, and base64url output is ASCII anyway. The
        randomness is a seam so the derivation can be tested for real
        rather than only for shape.
    #>
    param(
        [scriptblock]$GetBytes = { param([int]$Count)
            $buffer = New-Object byte[] $Count
            $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
            try { $rng.GetBytes($buffer) } finally { $rng.Dispose() }
            return , $buffer
        }
    )
    $verifier = ConvertTo-WtBase64Url -Bytes ([byte[]](& $GetBytes 64))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($verifier)) }
    finally { $sha.Dispose() }
    return @{ Verifier = $verifier; Challenge = (ConvertTo-WtBase64Url -Bytes $hash) }
}

function New-WtOAuthState {
    <#
    .SYNOPSIS
        A fresh anti-forgery state value for one sign-in attempt.
    #>
    param(
        [scriptblock]$GetBytes = { param([int]$Count)
            $buffer = New-Object byte[] $Count
            $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
            try { $rng.GetBytes($buffer) } finally { $rng.Dispose() }
            return , $buffer
        }
    )
    return (ConvertTo-WtBase64Url -Bytes ([byte[]](& $GetBytes 32)))
}

function Get-WtChatGptAuthorizeUri {
    <#
    .SYNOPSIS
        The browser URL for one sign-in attempt. Every value is escaped
        with EscapeDataString - the scope's spaces and the challenge's
        base64url text would otherwise break the query.
    #>
    param(
        [Parameter(Mandatory)][string]$Challenge,
        [Parameter(Mandatory)][string]$State
    )
    $config = Get-WtChatGptOAuthConfig
    $pairs = @(
        'response_type=code'
        'client_id=' + [uri]::EscapeDataString([string]$config.ClientId)
        'redirect_uri=' + [uri]::EscapeDataString([string]$config.RedirectUri)
        'scope=' + [uri]::EscapeDataString([string]$config.Scope)
        'code_challenge=' + [uri]::EscapeDataString([string]$Challenge)
        'code_challenge_method=S256'
        'state=' + [uri]::EscapeDataString([string]$State)
        'id_token_add_organizations=true'
        'codex_cli_simplified_flow=true'
    )
    return ([string]$config.AuthorizeUri + '?' + ($pairs -join '&'))
}

function ConvertFrom-WtJwtPayload {
    <#
    .SYNOPSIS
        PURE: the display fields out of an id_token - email, account id,
        plan. The signature is NOT verified and must not be: the token
        arrived over our own TLS connection to the token endpoint, and
        nothing here is an authorization decision. The account claim is
        matched by its '/auth' suffix so the issuer host can change.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Token)
    $empty = @{ Email = ''; AccountId = ''; PlanType = '' }
    $parts = ([string]$Token).Split('.')
    if (@($parts).Count -lt 2) { return $empty }
    $bytes = ConvertFrom-WtBase64Url -Text ([string]$parts[1])
    if ($bytes.Length -eq 0) { return $empty }
    $payload = $null
    try { $payload = [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json } catch { return $empty }
    if ($null -eq $payload) { return $empty }
    $names = @($payload.PSObject.Properties.Name)
    $email = ''
    if ($names -contains 'email') { $email = [string]$payload.email }
    $auth = $null
    foreach ($name in $names) {
        if (([string]$name).EndsWith('/auth', [System.StringComparison]::Ordinal)) { $auth = $payload.$name; break }
    }
    $accountId = ''
    $plan = ''
    if ($null -ne $auth) {
        $authNames = @($auth.PSObject.Properties.Name)
        if ($authNames -contains 'chatgpt_account_id') { $accountId = [string]$auth.chatgpt_account_id }
        if ($authNames -contains 'chatgpt_plan_type') { $plan = [string]$auth.chatgpt_plan_type }
    }
    return @{ Email = $email; AccountId = $accountId; PlanType = $plan }
}

function ConvertFrom-WtOAuthCallbackRequest {
    <#
    .SYNOPSIS
        PURE: the code and state out of the browser's GET line. Anything
        else the browser asks for on the way - a favicon, a preconnect
        probe - is not a callback and returns $null so the listener keeps
        waiting instead of failing the sign-in.
    #>
    param([AllowNull()][AllowEmptyString()][string]$RequestLine)
    $parts = ([string]$RequestLine).Split(' ')
    if (@($parts).Count -lt 2) { return $null }
    if (-not [string]::Equals([string]$parts[0], 'GET', [System.StringComparison]::Ordinal)) { return $null }
    $target = [string]$parts[1]
    $mark = $target.IndexOf('?')
    if ($mark -lt 0) { return $null }
    $result = @{ Path = $target.Substring(0, $mark); Code = ''; State = ''; ErrorCode = '' }
    foreach ($pair in $target.Substring($mark + 1).Split('&')) {
        $equals = ([string]$pair).IndexOf('=')
        if ($equals -lt 1) { continue }
        $name = ([string]$pair).Substring(0, $equals)
        $value = ''
        try { $value = [uri]::UnescapeDataString(([string]$pair).Substring($equals + 1)) } catch { $value = '' }
        if ([string]::Equals($name, 'code', [System.StringComparison]::Ordinal)) { $result.Code = $value }
        elseif ([string]::Equals($name, 'state', [System.StringComparison]::Ordinal)) { $result.State = $value }
        elseif ([string]::Equals($name, 'error', [System.StringComparison]::Ordinal)) { $result.ErrorCode = $value }
    }
    return $result
}

function Test-WtOAuthStateMatch {
    <#
    .SYNOPSIS
        PURE: constant-time state comparison. An empty expected state
        never matches, so a flow that failed to generate one cannot be
        satisfied by a callback that also omits it.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Expected,
        [AllowNull()][AllowEmptyString()][string]$Actual
    )
    $left = [System.Text.Encoding]::UTF8.GetBytes([string]$Expected)
    $right = [System.Text.Encoding]::UTF8.GetBytes([string]$Actual)
    if ($left.Length -eq 0 -or $left.Length -ne $right.Length) { return $false }
    $difference = 0
    for ($i = 0; $i -lt $left.Length; $i++) { $difference = $difference -bor ($left[$i] -bxor $right[$i]) }
    return ($difference -eq 0)
}

function Test-WtChatGptTokenExpiring {
    <#
    .SYNOPSIS
        PURE: whether the access token is inside the five minute refresh
        skew. Unreadable or missing means "refresh" - a needless refresh
        is cheap, a request with a dead token is a failed turn.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$ExpiresAt,
        [datetime]$Now = ([datetime]::UtcNow)
    )
    if (-not $ExpiresAt) { return $true }
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$ExpiresAt, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        return $true
    }
    return ($parsed.ToUniversalTime() -le $Now.ToUniversalTime().AddMinutes(5))
}

function ConvertTo-WtOAuthFormBody {
    <#
    .SYNOPSIS
        PURE: an ordered field table as application/x-www-form-urlencoded,
        every value escaped. Used only for the retry the token endpoint
        asks for when it refuses a JSON body.
    #>
    param([Parameter(Mandatory)]$Fields)
    $pairs = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($Fields.Keys)) {
        $pairs.Add([uri]::EscapeDataString([string]$name) + '=' + [uri]::EscapeDataString([string]$Fields[$name]))
    }
    return ($pairs.ToArray() -join '&')
}

function ConvertFrom-WtChatGptTokenResponse {
    <#
    .SYNOPSIS
        PURE: a token endpoint body as a session. expires_in is turned
        into an ABSOLUTE round-trip timestamp here, at the moment of the
        answer, because the value is stored and read back much later. A
        body with no access_token is not ok, whatever else it says.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Json,
        [datetime]$Now = ([datetime]::UtcNow)
    )
    $empty = @{ Ok = $false; AccessToken = ''; RefreshToken = ''; ExpiresAt = ''; AccountId = ''; Email = ''; PlanType = '' }
    $obj = $null
    try { $obj = ([string]$Json) | ConvertFrom-Json } catch { return $empty }
    if ($null -eq $obj) { return $empty }
    $names = @($obj.PSObject.Properties.Name)
    if (-not ($names -contains 'access_token') -or -not $obj.access_token) { return $empty }
    $seconds = 3600
    if ($names -contains 'expires_in') {
        $parsed = 0
        if ([int]::TryParse([string]$obj.expires_in, [System.Globalization.NumberStyles]::Integer,
                [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and $parsed -gt 0) {
            $seconds = $parsed
        }
    }
    $identity = @{ Email = ''; AccountId = ''; PlanType = '' }
    if ($names -contains 'id_token') { $identity = ConvertFrom-WtJwtPayload -Token ([string]$obj.id_token) }
    $refresh = ''
    if ($names -contains 'refresh_token') { $refresh = [string]$obj.refresh_token }
    return @{
        Ok           = $true
        AccessToken  = [string]$obj.access_token
        RefreshToken = $refresh
        ExpiresAt    = $Now.ToUniversalTime().AddSeconds($seconds).ToString('o')
        AccountId    = [string]$identity.AccountId
        Email        = [string]$identity.Email
        PlanType     = [string]$identity.PlanType
    }
}

function Invoke-WtChatGptTokenRequest {
    <#
    .SYNOPSIS
        One POST to the token endpoint: JSON first, and - only on a 4xx -
        the SAME fields once more form-encoded, because which of the two
        the endpoint accepts is not contractual. Errors go through the
        client's shared kind/text mapping so a login failure reads like
        every other failure in the app.
    #>
    param(
        [Parameter(Mandatory)]$Fields,
        [datetime]$Now = ([datetime]::UtcNow),
        [scriptblock]$Transport = { param($Request) Invoke-WtLlmHttpTransport -Request $Request }
    )
    $config = Get-WtChatGptOAuthConfig
    $response = & $Transport @{
        Uri = [string]$config.TokenUri; Method = 'POST'; Body = ($Fields | ConvertTo-Json -Depth 8 -Compress)
        Stream = $false; TimeoutSec = 30
    }
    if (-not $response.Ok -and [int]$response.StatusCode -ge 400 -and [int]$response.StatusCode -lt 500) {
        $response = & $Transport @{
            Uri = [string]$config.TokenUri; Method = 'POST'; Body = (ConvertTo-WtOAuthFormBody -Fields $Fields)
            ContentType = 'application/x-www-form-urlencoded'; Stream = $false; TimeoutSec = 30
        }
    }
    if (-not $response.Ok) {
        $kind = Get-WtLlmErrorKind -StatusCode ([int]$response.StatusCode) -Body ([string]$response.Body) -FailureKind ([string]$response.Failure)
        return @{ Ok = $false; Auth = $null; ErrorKind = $kind; ErrorText = (Get-WtLlmErrorText -Kind $kind -Detail ([string]$response.Body)) }
    }
    $parsed = ConvertFrom-WtChatGptTokenResponse -Json ([string]$response.Body) -Now $Now
    if (-not $parsed.Ok) {
        return @{ Ok = $false; Auth = $null; ErrorKind = 'Auth'; ErrorText = (Get-WtLlmErrorText -Kind 'Auth' -Detail ([string]$response.Body)) }
    }
    return @{ Ok = $true; Auth = $parsed; ErrorKind = ''; ErrorText = '' }
}

function Invoke-WtChatGptTokenExchange {
    <#
    .SYNOPSIS
        The authorization code -> tokens step of the sign-in.
    #>
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Verifier,
        [datetime]$Now = ([datetime]::UtcNow),
        [scriptblock]$Transport = { param($Request) Invoke-WtLlmHttpTransport -Request $Request }
    )
    $config = Get-WtChatGptOAuthConfig
    return (Invoke-WtChatGptTokenRequest -Now $Now -Transport $Transport -Fields ([ordered]@{
                grant_type    = 'authorization_code'
                code          = [string]$Code
                redirect_uri  = [string]$config.RedirectUri
                client_id     = [string]$config.ClientId
                code_verifier = [string]$Verifier
            }))
}

function Invoke-WtChatGptTokenRefresh {
    <#
    .SYNOPSIS
        Trades the stored refresh token for a fresh access token.
    #>
    param(
        [Parameter(Mandatory)][string]$RefreshToken,
        [datetime]$Now = ([datetime]::UtcNow),
        [scriptblock]$Transport = { param($Request) Invoke-WtLlmHttpTransport -Request $Request }
    )
    $config = Get-WtChatGptOAuthConfig
    return (Invoke-WtChatGptTokenRequest -Now $Now -Transport $Transport -Fields ([ordered]@{
                grant_type    = 'refresh_token'
                refresh_token = [string]$RefreshToken
                client_id     = [string]$config.ClientId
                scope         = 'openid profile email'
            }))
}

function Get-WtChatGptAccessToken {
    <#
    .SYNOPSIS
        The one call every request makes first: a usable access token,
        refreshed when it is inside the skew. A failed refresh does NOT
        clear the session - a flaky network must not sign the user out -
        it reports Auth and leaves the refresh token in place.
        Save-WtChatGptAuth merges, so a refresh that returns no new
        refresh token keeps the old one and the account id survives.
    #>
    param(
        [string]$TestRootOverride,
        [datetime]$Now = ([datetime]::UtcNow),
        [scriptblock]$Transport = { param($Request) Invoke-WtLlmHttpTransport -Request $Request }
    )
    $signedOut = @{ Ok = $false; AccessToken = ''; AccountId = ''; ErrorKind = 'Auth'; ErrorText = [string](Get-Translation 'AsChatGptReauth') }
    $stored = Read-WtChatGptAuth -TestRootOverride $TestRootOverride
    if (-not [string]$stored.AccessToken -and -not [string]$stored.RefreshToken) { return $signedOut }
    if (-not (Test-WtChatGptTokenExpiring -ExpiresAt ([string]$stored.ExpiresAt) -Now $Now)) {
        return @{ Ok = $true; AccessToken = [string]$stored.AccessToken; AccountId = [string]$stored.AccountId; ErrorKind = ''; ErrorText = '' }
    }
    if (-not [string]$stored.RefreshToken) { return $signedOut }
    $refreshed = Invoke-WtChatGptTokenRefresh -RefreshToken ([string]$stored.RefreshToken) -Now $Now -Transport $Transport
    if (-not $refreshed.Ok) { return $signedOut }
    Save-WtChatGptAuth -Auth $refreshed.Auth -TestRootOverride $TestRootOverride
    $current = Read-WtChatGptAuth -TestRootOverride $TestRootOverride
    return @{ Ok = $true; AccessToken = [string]$current.AccessToken; AccountId = [string]$current.AccountId; ErrorKind = ''; ErrorText = '' }
}

function Get-WtWinToolifyLogoDataUri {
    <#
    .SYNOPSIS
        The embedded logo as a data URI. Embedded rather than linked
        because the callback listener answers one request and hangs up:
        an <img src> pointing anywhere would load nothing. The bytes
        themselves live in Get-WtWinToolifyLogoBase64, one layer down,
        because the console window icon reads them too.
    #>
    return 'data:image/png;base64,' + (Get-WtWinToolifyLogoBase64)
}

function Get-WtOAuthCallbackPageHtml {
    <#
    .SYNOPSIS
        PURE: the page the browser lands on, drawn as the terminal window
        the project site uses - the Campbell palette the console writes
        in, Windows chrome with the controls on the right - so the tab
        that opens looks like the tool that opened it. Everything is
        inline because the listener answers this one request and hangs
        up: a stylesheet, font or image the page asked for afterwards
        would never be served. The file stays ASCII, so the Turkish text
        arrives as numeric entities and the browser renders the letters.
    #>
    param([bool]$Ok = $true)
    $lang = $(if ([string]$script:Language -eq 'TR') { 'tr' } else { 'en' })
    $head = [string](Get-Translation $(if ($Ok) { 'AsChatGptPageOkTitle' } else { 'AsChatGptPageFailTitle' }))
    $text = [string](Get-Translation $(if ($Ok) { 'AsChatGptPageOkBody' } else { 'AsChatGptPageFailBody' }))
    $risk = $(if ($Ok) { '<p class="risk">' + [string](Get-Translation 'AsChatGptPageOkRisk') + '</p>' } else { '' })
    $stroke = $(if ($Ok) { '#16c60c' } else { '#e74856' })
    $glyph = $(if ($Ok) { 'M13.4 22.6l6 6 12.2-12.4' } else { 'M15.8 15.8l12.4 12.4M28.2 15.8L15.8 28.2' })
    return @"
<!doctype html><html lang="$lang"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>WinToolify - $head</title>
<style>
:root{color-scheme:dark}
*,*::before,*::after{box-sizing:border-box}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px;
background:#0e1014;color:#f2f4f7;letter-spacing:-.011em;-webkit-font-smoothing:antialiased;
font:400 17px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI Variable Display","Segoe UI",Inter,Roboto,Arial,sans-serif}
.term{width:100%;max-width:560px;overflow:hidden;border:1px solid rgb(255 255 255/14%);border-radius:12px;
background:#0c0c0c;box-shadow:0 24px 60px rgb(0 0 0/45%)}
.bar{display:flex;align-items:stretch;min-height:34px;background:#16181d;color:#838c95;font-size:12px;
border-bottom:1px solid rgb(255 255 255/7%)}
.bar b{display:flex;align-items:center;padding-left:14px;font-weight:400;letter-spacing:.01em;
font-family:"Cascadia Mono","Cascadia Code",Consolas,ui-monospace,SFMono-Regular,Menlo,monospace}
.ctl{display:flex;margin-left:auto}
.ctl i{position:relative;width:40px}
.ctl i::before,.ctl i::after{content:"";position:absolute;top:50%;left:50%;background:#98a1ab}
.ctl .mn::before{width:10px;height:1px;margin:0 0 0 -5px}
.ctl .mx::before{width:9px;height:9px;margin:-5px 0 0 -5px;background:none;border:1px solid #98a1ab;border-radius:1px}
.ctl .cl::before,.ctl .cl::after{width:11px;height:1px;margin:0 0 0 -5.5px}
.ctl .cl::before{transform:rotate(45deg)}
.ctl .cl::after{transform:rotate(-45deg)}
.pad{padding:38px 34px 34px;text-align:center}
.logo{display:block;width:60px;height:60px;margin:0 auto;border-radius:13px}
.brand{margin-top:12px;font-size:15px;letter-spacing:.02em}
h1{display:flex;align-items:center;justify-content:center;gap:11px;margin:26px 0 10px;font-size:26px;
line-height:1.25;font-weight:600;letter-spacing:-.02em}
h1 svg{flex:none;width:24px;height:24px}
p{margin:0;color:#a5aeb8}
.risk{margin-top:28px;padding:15px 17px;text-align:left;border:1px solid rgb(255 255 255/9%);
border-radius:9px;background:#141720;color:#9aa4ae;font-size:14.5px;line-height:1.55}
@media (max-width:520px){.pad{padding:24px 22px}h1{font-size:22px}}
</style></head>
<body><main class="term">
<div class="bar"><b>WinToolify</b><span class="ctl"><i class="mn"></i><i class="mx"></i><i class="cl"></i></span></div>
<div class="pad">
<img class="logo" src="$(Get-WtWinToolifyLogoDataUri)" alt="" width="60" height="60">
<p class="brand">WinToolify</p>
<h1><svg viewBox="0 0 44 44" fill="none" stroke="$stroke" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
<circle cx="22" cy="22" r="19" stroke-opacity=".33"></circle><path d="$glyph"></path></svg>$head</h1>
<p>$text</p>
$risk
</div></main></body></html>
"@
}

function Get-WtOAuthCallbackResponseText {
    <#
    .SYNOPSIS
        The one response the loopback listener writes. Content-Length
        counts BYTES, not characters, or a browser waits forever for a
        body that never arrives; the count and the write share UTF-8 so
        the header cannot drift from what goes down the socket.
    #>
    param([bool]$Ok = $true)
    $body = [string](Get-WtOAuthCallbackPageHtml -Ok $Ok)
    $length = [System.Text.Encoding]::UTF8.GetByteCount($body)
    return ("HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: " +
        [string]$length + "`r`nConnection: close`r`n`r`n" + $body)
}

function New-WtOAuthLoopbackListener {
    <#
    .SYNOPSIS
        The callback socket. A raw TcpListener rather than HttpListener:
        HttpListener needs a urlacl reservation for its prefix, while a
        TcpListener on the loopback address needs nothing. The port is
        fixed - it is the registered redirect URI - so a bind failure is
        reported rather than worked around with another port. The accepted
        client rides in a shared Pending table instead of a closure,
        because a closure built here would be re-created every build and
        the single-file script is RUN, not dot-sourced.
    #>
    param([int]$Port = 0)
    if ($Port -le 0) { $Port = [int](Get-WtChatGptOAuthConfig).RedirectPort }
    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), $Port
        $listener.Start()
    }
    catch {
        if ($null -ne $listener) { try { $listener.Stop() } catch { $null = $_ } }
        return @{ Ok = $false; Listener = $null; Pending = @{ Client = $null } }
    }
    return @{ Ok = $true; Listener = $listener; Pending = @{ Client = $null } }
}

function Read-WtOAuthListenerRequest {
    <#
    .SYNOPSIS
        The next pending browser request line, or '' when nothing is
        waiting - never blocking, so the caller stays cancellable.
    #>
    param([Parameter(Mandatory)][hashtable]$Listener)
    if ($null -eq $Listener.Listener) { return '' }
    if (-not $Listener.Listener.Pending()) { return '' }
    $client = $Listener.Listener.AcceptTcpClient()
    $Listener.Pending.Client = $client
    try {
        $reader = New-Object System.IO.StreamReader($client.GetStream(), [System.Text.Encoding]::ASCII)
        return [string]$reader.ReadLine()
    }
    catch { return '' }
}

function Write-WtOAuthListenerResponse {
    <#
    .SYNOPSIS
        Answers the request Read-WtOAuthListenerRequest accepted and hangs
        up. A write that fails is swallowed: the browser tab's fate must
        never decide whether the sign-in succeeded.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Listener,
        [bool]$Ok = $true
    )
    $client = $Listener.Pending.Client
    if ($null -eq $client) { return }
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes((Get-WtOAuthCallbackResponseText -Ok $Ok))
        $stream = $client.GetStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    }
    catch { $null = $_ }
    finally {
        try { $client.Close() } catch { $null = $_ }
        $Listener.Pending.Client = $null
    }
}

function Close-WtOAuthListener {
    <#
    .SYNOPSIS
        Releases the socket and any half-served client. Safe to call on a
        listener that never opened.
    #>
    param([Parameter(Mandatory)][hashtable]$Listener)
    if ($null -ne $Listener.Pending.Client) { try { $Listener.Pending.Client.Close() } catch { $null = $_ } }
    if ($null -ne $Listener.Listener) { try { $Listener.Listener.Stop() } catch { $null = $_ } }
}

function Wait-WtOAuthCallback {
    <#
    .SYNOPSIS
        Polls the loopback listener until the callback arrives, the user
        presses Esc, or the deadline passes. Everything the browser asks
        for that is not the callback - a favicon, a preconnect probe - is
        ignored and the wait continues. A state mismatch is refused
        SILENTLY: the caller learns "cancelled", never that a code was
        seen, so a forged callback cannot be told apart from the user
        giving up. Poll and Respond take the listener as an argument
        rather than capturing it, so no closure is needed.
    #>
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][hashtable]$Listener,
        [int]$TimeoutSeconds = 180,
        [scriptblock]$ShouldCancel = { $false },
        [scriptblock]$Poll = { param($L) Read-WtOAuthListenerRequest -Listener $L },
        [scriptblock]$Respond = { param($L, $Ok) Write-WtOAuthListenerResponse -Listener $L -Ok $Ok },
        [scriptblock]$GetNow = { [datetime]::UtcNow },
        [scriptblock]$Idle = { Start-Sleep -Milliseconds 100 }
    )
    $deadline = (& $GetNow).AddSeconds([int]$TimeoutSeconds)
    while ($true) {
        if (& $ShouldCancel) { return @{ Ok = $false; Code = ''; ReasonKey = 'AsChatGptCancelled' } }
        if ((& $GetNow) -gt $deadline) { return @{ Ok = $false; Code = ''; ReasonKey = 'AsChatGptTimeout' } }
        $line = [string](& $Poll $Listener)
        if (-not $line) { & $Idle; continue }
        $parsed = ConvertFrom-WtOAuthCallbackRequest -RequestLine $line
        if ($null -eq $parsed) { continue }
        if ([string]$parsed.ErrorCode) {
            & $Respond $Listener $false
            return @{ Ok = $false; Code = ''; ReasonKey = 'AsChatGptCancelled' }
        }
        if (-not (Test-WtOAuthStateMatch -Expected $State -Actual ([string]$parsed.State))) {
            & $Respond $Listener $false
            return @{ Ok = $false; Code = ''; ReasonKey = 'AsChatGptCancelled' }
        }
        if (-not [string]$parsed.Code) { continue }
        & $Respond $Listener $true
        return @{ Ok = $true; Code = [string]$parsed.Code; ReasonKey = '' }
    }
}

function Open-WtChatGptSignInBrowser {
    <#
    .SYNOPSIS
        Opens the authorize URL in the SIGNED-IN USER's browser, not this
        elevated process's. WinToolify runs as administrator, so a plain
        Start-Process would hand the user an elevated browser window; the
        scheduled-task de-elevation used for winget is the way back down.
        rundll32's FileProtocolHandler follows the user's default browser.
    #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [scriptblock]$Run = { param($FilePath, $Arguments) Invoke-WtProcessAsInteractiveUser -FilePath $FilePath -Arguments $Arguments }
    )
    $result = $null
    try { $result = & $Run 'rundll32.exe' ([string[]]@('url.dll,FileProtocolHandler', [string]$Uri)) }
    catch { return $false }
    if ($null -eq $result) { return $false }
    if ($result -is [hashtable] -and $result.ContainsKey('Ok')) { return [bool]$result.Ok }
    return $true
}

function Test-WtOAuthCancelKey {
    <#
    .SYNOPSIS
        True when Esc is waiting in the input queue - the non-blocking
        poll the sign-in wait uses to stay cancellable. Every pending key
        is drained, not just the first, so a stray keypress cannot queue
        up behind the panel that follows. A console that cannot be read
        (a redirected host) is "no cancel", never a crash.
    #>
    param(
        [scriptblock]$KeyAvailable = { [Console]::KeyAvailable },
        [scriptblock]$ReadKey = { [Console]::ReadKey($true) }
    )
    $cancelled = $false
    try {
        while ([bool](& $KeyAvailable)) {
            $key = & $ReadKey
            if ($null -ne $key -and [int]$key.Key -eq [int][ConsoleKey]::Escape) { $cancelled = $true }
        }
    }
    catch { return $false }
    return $cancelled
}

function Invoke-WtChatGptSignIn {
    <#
    .SYNOPSIS
        The whole sign-in: listener up, browser out, callback in, tokens
        stored. The listener opens BEFORE the browser so a very fast
        redirect cannot arrive at a closed port, and it is closed on every
        exit path. Nothing is written until the exchange succeeds, so a
        failed attempt leaves the previous state exactly as it was.
        BrowserFailed and AuthorizeUri come back so the caller can show
        the address for the user to paste by hand.
    #>
    param(
        [string]$TestRootOverride,
        [scriptblock]$Listen = { New-WtOAuthLoopbackListener },
        [scriptblock]$CloseListener = { param($Listener) Close-WtOAuthListener -Listener $Listener },
        [scriptblock]$OpenBrowser = { param($Uri) Open-WtChatGptSignInBrowser -Uri $Uri },
        [scriptblock]$ShouldCancel = { $false },
        [AllowNull()][scriptblock]$Wait = $null,
        [AllowNull()][scriptblock]$Exchange = $null,
        [scriptblock]$Transport = { param($Request) Invoke-WtLlmHttpTransport -Request $Request }
    )
    $pkce = New-WtPkcePair
    $state = New-WtOAuthState
    $authorizeUri = Get-WtChatGptAuthorizeUri -Challenge ([string]$pkce.Challenge) -State $state
    $failed = { param($Key, $Text, $BrowserFailed)
        return @{
            Ok = $false; Email = ''; PlanType = ''; ReasonKey = [string]$Key; ErrorText = [string]$Text
            BrowserFailed = [bool]$BrowserFailed; AuthorizeUri = $authorizeUri
        }
    }
    $listener = & $Listen
    if (-not $listener.Ok) { return (& $failed 'AsChatGptPortBusy' '' $false) }
    try {
        $browserOk = [bool](& $OpenBrowser $authorizeUri)
        $waited = $null
        if ($null -ne $Wait) { $waited = & $Wait $state $listener }
        else { $waited = Wait-WtOAuthCallback -State $state -Listener $listener -ShouldCancel $ShouldCancel }
        if (-not $waited.Ok) { return (& $failed ([string]$waited.ReasonKey) '' (-not $browserOk)) }
        $exchanged = $null
        if ($null -ne $Exchange) { $exchanged = & $Exchange ([string]$waited.Code) ([string]$pkce.Verifier) }
        else { $exchanged = Invoke-WtChatGptTokenExchange -Code ([string]$waited.Code) -Verifier ([string]$pkce.Verifier) -Transport $Transport }
        if (-not $exchanged.Ok) { return (& $failed 'AsChatGptReauth' ([string]$exchanged.ErrorText) (-not $browserOk)) }
        Save-WtChatGptAuth -Auth $exchanged.Auth -TestRootOverride $TestRootOverride
        Save-WtSettings -Settings ([PSCustomObject]@{ AssistantAuthMode = 'ChatGPT' }) -TestRootOverride $TestRootOverride
        return @{
            Ok = $true; Email = [string]$exchanged.Auth.Email; PlanType = [string]$exchanged.Auth.PlanType
            ReasonKey = ''; ErrorText = ''; BrowserFailed = (-not $browserOk); AuthorizeUri = $authorizeUri
        }
    }
    finally { & $CloseListener $listener }
}
