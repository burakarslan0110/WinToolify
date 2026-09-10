# Test-WtIsMainInvocation - the dot-source guard predicate used by the elevation and main blocks.
# Covered by: tests/Guard.Tests.ps1

function Test-WtIsMainInvocation {
    <#
    .SYNOPSIS
        True when the script is being run as the main program (iex, the call
        operator, or -File); false when it is dot-sourced to load functions
        only (e.g. for Pester tests). Dot-sourcing sets InvocationName to
        '.'; iex, &, and -File all leave it something else - verified across
        all four invocation modes.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$InvocationName
    )
    return ($InvocationName -ne '.')
}
