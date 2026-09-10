# Unblock-WtSelf - drops the Mark of the Web from WinToolify's own file.
# Covered by: tests/UnblockSelf.Tests.ps1

function Unblock-WtSelf {
    <#
    .SYNOPSIS
        Removes the Zone.Identifier stream from the running script, so a
        copy downloaded from the releases page stops being refused by
        RemoteSigned the next time someone launches it. A no-op without a
        script path: the irm | iex launch has no file to unmark. NEVER
        throws - it runs in the entry point ahead of everything, and a
        machine that refuses the write is not a reason to fail to start.
        Returns $true only when a marker was actually removed.
    #>
    param(
        [AllowEmptyString()][string]$Path = $PSCommandPath,
        [scriptblock]$TestBlockedAction = { param($P) $null -ne (Get-Content -LiteralPath $P -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue) },
        [scriptblock]$UnblockAction = { param($P) Unblock-File -LiteralPath $P -ErrorAction Stop }
    )

    if (-not $Path) { return $false }
    try {
        if (-not [bool](& $TestBlockedAction $Path)) { return $false }
        $null = & $UnblockAction $Path
        return $true
    }
    catch { return $false }
}
