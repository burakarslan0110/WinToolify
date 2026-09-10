# Local data root, JSON read/write, settings file.
# Covered by: tests/Storage.Tests.ps1, tests/Settings.Tests.ps1

function Get-WtDataPath {
    <#
    .SYNOPSIS
        Resolves WinToolify's local data root and creates it (and any
        -SubPath beneath it) on demand. -Scope is mandatory, not defaulted:
        an elevated Start-Process -Verb RunAs runs under the admin profile,
        so a wrong scope would hide machine state from the original user.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Machine', 'User')]
        [string]$Scope,

        [string]$SubPath,

        [string]$TestRootOverride
    )

    if ($TestRootOverride) {
        $root = Join-Path $TestRootOverride $Scope
    }
    elseif ($Scope -eq 'Machine') {
        $root = Join-Path $env:ProgramData 'WinToolify'
    }
    else {
        $root = Join-Path $env:LOCALAPPDATA 'WinToolify'
    }

    $target = if ($SubPath) { Join-Path $root $SubPath } else { $root }

    if (-not (Test-Path -LiteralPath $target)) {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
    }

    return $target
}

function Write-WtJson {
    <#
    .SYNOPSIS
        Serializes an object to a JSON file with the project's fixed depth
        and encoding rules, so no caller has to remember them.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [object]$InputObject
    )

    $json = $InputObject | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Read-WtJson {
    <#
    .SYNOPSIS
        Reads and deserializes a JSON file written by Write-WtJson.
        Returns $null (and warns) for a missing or corrupt file rather than
        throwing - a malformed undo log must not prevent the tool starting.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        return $raw | ConvertFrom-Json
    }
    catch {
        Write-Warning "Read-WtJson: failed to parse '$Path' - $($_.Exception.Message)"
        return $null
    }
}

function ConvertTo-WtIsoText {
    <#
    .SYNOPSIS
        PURE: one timestamp as canonical round-trip ISO 8601 text ('o'),
        whatever shape it arrives in. PowerShell 7's ConvertFrom-Json turns an
        ISO string back into a [datetime], so a bare [string] cast renders it
        in the current culture ("09/01/2026 11:00:00") and no longer matches
        what was written, while Windows PowerShell 5.1 leaves the same value a
        string; every timestamp that comes out of Read-WtJson and is then
        compared, persisted or shown must pass through here so both hosts
        agree. Strings are canonicalized too, since the writers use several
        precisions ('o' for notes, whole seconds for the boot time) and a
        second-precision string must compare equal to the same instant read
        back as a [datetime]. Only the ISO shapes below are recognized, so a
        JSON blob, an id or free text is returned unchanged.
    #>
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    $iso = 'o'
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Value -is [datetime]) { return ([datetime]$Value).ToString($iso, $invariant) }
    $text = [string]$Value
    if (-not $text) { return '' }
    $parsed = [datetime]::MinValue
    $formats = [string[]]@($iso, 'yyyy-MM-ddTHH:mm:ss', 'yyyy-MM-ddTHH:mm:ss.fff', 'yyyy-MM-ddTHH:mm:ssK', 'yyyy-MM-ddTHH:mm:ss.fffffffK')
    if ([datetime]::TryParseExact($text, $formats, $invariant, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        return $parsed.ToString($iso, $invariant)
    }
    return $text
}

function Get-WtSettingsFilePath {
    <#
    .SYNOPSIS
        <User data root>\settings.json - the per-user preferences file
        (language choice). User scope on purpose: the language is a
        personal preference, not machine state.
    #>
    param([string]$TestRootOverride)
    $dataPathArgs = @{ Scope = 'User' }
    if ($TestRootOverride) { $dataPathArgs['TestRootOverride'] = $TestRootOverride }
    return Join-Path (Get-WtDataPath @dataPathArgs) 'settings.json'
}

function Read-WtSettings {
    <#
    .SYNOPSIS
        Loads settings.json; never throws. A missing or corrupt file, or an
        unknown Language value, yields Language = $null so the caller falls
        back to the first-run language screen (Read-WtProfile idiom).
    #>
    param([string]$TestRootOverride)
    $raw = Read-WtJson -Path (Get-WtSettingsFilePath -TestRootOverride $TestRootOverride)
    $language = $null
    $endpoint = ''
    $model = ''
    $apiKey = ''
    $temperature = ''
    $maxTokens = ''
    $numCtx = ''
    $authMode = ''
    if ($null -ne $raw -and ($raw -is [PSCustomObject])) {
        $props = $raw.PSObject.Properties.Name
        if (($props -contains 'Language') -and (@('EN', 'TR') -contains [string]$raw.Language)) { $language = [string]$raw.Language }
        if ($props -contains 'AssistantEndpoint') { $endpoint = [string]$raw.AssistantEndpoint }
        if ($props -contains 'AssistantModel') { $model = [string]$raw.AssistantModel }
        if ($props -contains 'AssistantApiKey') { $apiKey = [string]$raw.AssistantApiKey }
        if ($props -contains 'AssistantTemperature') { $temperature = [string]$raw.AssistantTemperature }
        if ($props -contains 'AssistantMaxTokens') { $maxTokens = [string]$raw.AssistantMaxTokens }
        if ($props -contains 'AssistantNumCtx') { $numCtx = [string]$raw.AssistantNumCtx }
        if ($props -contains 'AssistantAuthMode') { $authMode = [string]$raw.AssistantAuthMode }
    }
    return [PSCustomObject]@{
        Language              = $language; AssistantEndpoint = $endpoint; AssistantModel = $model; AssistantApiKey = $apiKey
        AssistantTemperature  = $temperature; AssistantMaxTokens = $maxTokens; AssistantNumCtx = $numCtx
        AssistantAuthMode     = $authMode
    }
}

function Save-WtSettings {
    <#
    .SYNOPSIS
        Writes settings.json, merging into any existing content rather than
        overwriting it, because other builds/versions keep their own keys in
        this file (seen in the wild: Borders/HistoryPanel/RestorePointMode).
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Settings,
        [string]$TestRootOverride
    )
    $file = Get-WtSettingsFilePath -TestRootOverride $TestRootOverride
    $existing = Read-WtJson -Path $file
    $merged = if ($null -ne $existing -and ($existing -is [PSCustomObject])) { $existing } else { [PSCustomObject]@{} }
    $merged | Add-Member -NotePropertyName 'SchemaVersion' -NotePropertyValue 1 -Force
    foreach ($field in @('Language', 'AssistantEndpoint', 'AssistantModel', 'AssistantApiKey', 'AssistantTemperature', 'AssistantMaxTokens', 'AssistantNumCtx', 'AssistantAuthMode')) {
        if ($Settings.PSObject.Properties.Name -contains $field) {
            $merged | Add-Member -NotePropertyName $field -NotePropertyValue ([string]$Settings.$field) -Force
        }
    }
    Write-WtJson -Path $file -InputObject $merged
}

function Protect-WtAssistantSecret {
    <#
    .SYNOPSIS
        DPAPI-protects the assistant API key for settings.json. Empty in,
        empty out - a local server needs no key and stores none.
    #>
    param([AllowNull()][AllowEmptyString()][string]$PlainText)
    if (-not $PlainText) { return '' }
    $secure = ConvertTo-SecureString -String $PlainText -AsPlainText -Force
    return [string](ConvertFrom-SecureString -SecureString $secure)
}

function Unprotect-WtAssistantSecret {
    <#
    .SYNOPSIS
        The inverse of Protect-WtAssistantSecret. A corrupt blob, or one
        written under another user's DPAPI key (the elevation caveat the
        spec accepts), reads back as '' - "unset", never a crash.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Blob)
    if (-not $Blob) { return '' }
    try {
        $secure = ConvertTo-SecureString -String $Blob -ErrorAction Stop
        $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    }
    catch { return '' }
}

function Get-WtChatGptAuthPath {
    <#
    .SYNOPSIS
        <User data root>\chatgpt-auth.json - the ChatGPT OAuth session.
        A file of its own rather than settings.json: these values are
        rewritten every time a token is refreshed, while settings.json
        holds durable user preferences.
    #>
    param([string]$TestRootOverride)
    $dataPathArgs = @{ Scope = 'User' }
    if ($TestRootOverride) { $dataPathArgs['TestRootOverride'] = $TestRootOverride }
    return Join-Path (Get-WtDataPath @dataPathArgs) 'chatgpt-auth.json'
}

function Read-WtChatGptAuth {
    <#
    .SYNOPSIS
        The stored ChatGPT session with both tokens decrypted; never
        throws. A missing file, corrupt JSON, or a blob written under
        another user's DPAPI key all read back as an empty session -
        "signed out", never a crash. ExpiresAt goes through
        ConvertTo-WtIsoText: ConvertFrom-Json hands the timestamp back as
        a [datetime], and a bare cast would render it in the current
        culture without its UTC marker, so the expiry check would read a
        fresh token as local time and refresh a token that is still good.
    #>
    param([string]$TestRootOverride)
    $empty = @{ AccessToken = ''; RefreshToken = ''; ExpiresAt = ''; AccountId = ''; Email = ''; PlanType = '' }
    $raw = Read-WtJson -Path (Get-WtChatGptAuthPath -TestRootOverride $TestRootOverride)
    if ($null -eq $raw -or -not ($raw -is [PSCustomObject])) { return $empty }
    $props = @($raw.PSObject.Properties.Name)
    $plain = { param([string]$Name)
        if ($props -contains $Name) { return [string]$raw.$Name }
        return ''
    }
    $secret = { param([string]$Name)
        if ($props -contains $Name) { return [string](Unprotect-WtAssistantSecret -Blob ([string]$raw.$Name)) }
        return ''
    }
    $stamp = { param([string]$Name)
        if ($props -contains $Name) { return [string](ConvertTo-WtIsoText -Value $raw.$Name) }
        return ''
    }
    return @{
        AccessToken  = [string](& $secret 'AccessToken')
        RefreshToken = [string](& $secret 'RefreshToken')
        ExpiresAt    = [string](& $stamp 'ExpiresAt')
        AccountId    = [string](& $plain 'AccountId')
        Email        = [string](& $plain 'Email')
        PlanType     = [string](& $plain 'PlanType')
    }
}

function Save-WtChatGptAuth {
    <#
    .SYNOPSIS
        Writes the ChatGPT session, DPAPI-protecting both tokens. Merges
        into the existing file so a refresh that returns no new refresh
        token does not erase the one already stored, and the account id
        read once at sign-in survives every later refresh.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Auth,
        [string]$TestRootOverride
    )
    $current = Read-WtChatGptAuth -TestRootOverride $TestRootOverride
    foreach ($field in @('AccessToken', 'RefreshToken', 'ExpiresAt', 'AccountId', 'Email', 'PlanType')) {
        if ($Auth.ContainsKey($field) -and [string]$Auth[$field]) { $current[$field] = [string]$Auth[$field] }
    }
    $out = [PSCustomObject]@{
        SchemaVersion = 1
        AccessToken   = [string](Protect-WtAssistantSecret -PlainText ([string]$current.AccessToken))
        RefreshToken  = [string](Protect-WtAssistantSecret -PlainText ([string]$current.RefreshToken))
        ExpiresAt     = [string]$current.ExpiresAt
        AccountId     = [string]$current.AccountId
        Email         = [string]$current.Email
        PlanType      = [string]$current.PlanType
    }
    Write-WtJson -Path (Get-WtChatGptAuthPath -TestRootOverride $TestRootOverride) -InputObject $out
}

function Clear-WtChatGptAuth {
    <#
    .SYNOPSIS
        Signs out: deletes the session file and empties AssistantAuthMode,
        so a half-cleared state - mode on, no tokens - can never be read
        back.
    #>
    param([string]$TestRootOverride)
    $path = Get-WtChatGptAuthPath -TestRootOverride $TestRootOverride
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    Save-WtSettings -Settings ([PSCustomObject]@{ AssistantAuthMode = '' }) -TestRootOverride $TestRootOverride
}
