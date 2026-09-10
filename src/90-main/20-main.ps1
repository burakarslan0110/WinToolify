# Main program (guarded by Test-WtIsMainInvocation).
# The Ctrl+C / Ctrl+Break guard goes up as the first statement of the try,
# before anything can block or spawn, and comes down last in the finally.
if (Test-WtIsMainInvocation -InvocationName $MyInvocation.InvocationName) {
try {
    $null = Enable-WtCtrlGuard
    $null = Unblock-WtSelf
    $settings = Read-WtSettings
    if (@('EN', 'TR') -contains $settings.Language) { $script:Language = $settings.Language }
    Set-WindowSize | Out-Null
    $null = Lock-WtWindow
    $null = Set-WtWindowIcon
    Initialize-WtTui
    if (@('EN', 'TR') -notcontains $settings.Language) { Invoke-WtFirstRunLanguage }
    Invoke-WtMainLoop -InitialScreens $(if ($Assistant) { @('Main', 'Assistant') } else { @('Main') })
}
catch {
    Show-WtFatalError -ErrorRecord $_
}
finally {
    Restore-WtTui
    Unlock-WtWindow
    Restore-WtWindowIcon
    Disable-WtCtrlGuard
    if ($Host.Name -eq 'ConsoleHost' -and $env:WINTOOLIFY_SPAWNED -eq '1') {
        Stop-Process -Id $PID
    }
}
}
