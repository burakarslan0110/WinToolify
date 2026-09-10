# TUI defaults that are safe at dot-source time. Must precede glyphs-vt.ps1 (it sets WtGlyphs to $null before the real set is chosen).
# Covered by: tests/Tui.Tests.ps1

$script:WtInputMode = 'Line'
$script:WtGlyphs = $null
$script:WtVt = $false
$script:WtPrevRows = @()
$script:WtPrevWidth = 0
$script:WtPrevHeight = 0

$script:WtAssistantChat = $null
$script:WtAssistantPrivacyEndpoint = ''
$script:WtWingetStoreInitialQuery = ''

# The assistant's tool index, built once per process (~1.5 s) and cached here
# with its section enum and IDF table; Reset-WtAssistantIndexCache clears all three.
$script:WtAssistantIndexCache = $null
$script:WtAssistantSectionEnumCache = $null
$script:WtAssistantIdfCache = $null

$script:WtAssistantRowLines = @()

$script:WtReplMode = $false
$script:WtReplSaved = $null
$script:WtReplStream = $null
$script:WtTuiSavedCtrlC = $null
$script:WtTuiCtrlCOwned = $false
$script:WtCtrlGuard = $false
$script:WtWindowLock = $null
$script:WtInputExhausted = $false
$script:WtReplMargin = 2

$script:WtReplLive = @{ Rows = 0; CaretRow = 0 }
$script:WtReplLiveEnabled = $false

$script:WtReplSpinner = $null
$script:WtReplConsoleModeSaved = $null
