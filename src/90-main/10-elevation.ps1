# Relaunch elevated when not an administrator (guarded by Test-WtIsMainInvocation).
# The child is handed the script TEXT, never the path: "& 'file.ps1'" is a script
# load, so it inherits every block a load can hit - a policy pinned by group
# policy (which -ExecutionPolicy Bypass cannot override), a drive the elevated
# account cannot see, a Mark of the Web. Any of those kills the new window
# before the fatal-error screen exists, which reads as "it opened and closed
# instantly". [scriptblock]::Create is not a load, so it survives all three and
# both branches end up the same shape. Constrained Language mode blocks it too;
# nothing here can help there.
# The Mark of the Web comes off first, while the non-elevated process still holds
# the path the user owns - the elevated child runs from text and has no
# $PSCommandPath of its own to unmark.

if (Test-WtIsMainInvocation -InvocationName $MyInvocation.InvocationName) {
    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        $assistantArg = $(if ($Assistant) { ' -Assistant' } else { '' })
        if ($PSCommandPath) {
            $null = Unblock-WtSelf
            $spawnPath = $PSCommandPath.Replace("'", "''")
            $spawnHome = ([string](Split-Path -Parent $PSCommandPath)).Replace("'", "''")
            Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"`$env:WINTOOLIFY_SPAWNED='1'; `$env:WINTOOLIFY_HOME='$spawnHome'; & ([scriptblock]::Create((Get-Content -Raw -LiteralPath '$spawnPath')))$assistantArg`"" -Verb RunAs -WindowStyle Maximized
        }
        else {
            Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"`$env:WINTOOLIFY_SPAWNED='1'; & ([scriptblock]::Create((irm 'https://github.com/burakarslan0110/WinToolify/releases/latest/download/WinToolify.ps1')))$assistantArg`"" -Verb RunAs -WindowStyle Maximized
        }
        exit
    }
}
