# Yes/no letters, typed-word gates, Confirm-WtDestructiveAction.
# Covered by: tests/ApplyFlow.Tests.ps1

function Get-WtAnswerLetter {
    <#
    .SYNOPSIS
        The single upper-case letter the active language expects for
        "yes" / "no" - Y/N in English, E/H (Evet/Hayir) in Turkish. Falls
        back to the English letters if a language ever ships without the
        keys, so a prompt can never end up with no accepted answer.
    #>
    param([Parameter(Mandatory)][ValidateSet('Yes', 'No')][string]$Kind)
    $letter = [string](Get-Translation ($Kind + 'Letter'))
    if (-not $letter) { $letter = if ($Kind -eq 'Yes') { 'Y' } else { 'N' } }
    return $letter.Substring(0, 1).ToUpperInvariant()
}

function Test-WtAffirmativeAnswer {
    <#
    .SYNOPSIS
        True when a typed answer starts with the active language's "yes"
        letter (Y in English, E in Turkish). Every yes/no prompt in the
        script defaults to no, so this one predicate answers all of them:
        blank input, the "no" letter and any typo all mean no.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Answer)
    $text = ([string]$Answer).Trim()
    if (-not $text) { return $false }
    return ($text.Substring(0, 1).ToUpperInvariant() -eq (Get-WtAnswerLetter -Kind 'Yes'))
}

function Format-WtYesNoHint {
    <#
    .SYNOPSIS
        The tail of a yes-no prompt, written the way the navigation guide
        writes everything else: "E: Evet - H: Hayir" in Turkish,
        "Y: Yes - N: No" in English. Prompt strings never carry this
        themselves, so no translation can drift away from the letters the
        code actually accepts.
    #>
    return '{0}: {1} - {2}: {3}' -f (Get-WtAnswerLetter -Kind 'Yes'), (Get-Translation 'AnswerYes'),
                                    (Get-WtAnswerLetter -Kind 'No'), (Get-Translation 'AnswerNo')
}

function Get-WtYesNoPrompt {
    <#
    .SYNOPSIS
        A prompt sentence plus its localized yes-no hint.
    #>
    param(
        [Parameter(Mandatory)][string]$Text
    )
    return ($Text.TrimEnd() + ' ' + (Format-WtYesNoHint))
}

function Get-WtTypedWord {
    <#
    .SYNOPSIS
        The word a destructive gate asks the user to type out in full -
        YES / CONFIRM in English, EVET / ONAYLA in Turkish. Upper-case in
        the prompt; what the user types is matched case-insensitively
        (see Test-WtTypedConfirmation).
    #>
    param([Parameter(Mandatory)][ValidateSet('Yes', 'Confirm')][string]$Kind)
    $word = [string](Get-Translation ('Typed' + $Kind + 'Word'))
    if (-not $word) { $word = if ($Kind -eq 'Yes') { 'YES' } else { 'CONFIRM' } }
    return $word
}

function Get-WtAcceptedTypedWords {
    <#
    .SYNOPSIS
        Every spelling a gate accepts: this gate's word in EVERY language
        the build ships, plus the English fallback. A user who switched
        the UI to English but still thinks in Turkish types ONAYLA and it
        works - refusing that only costs them their selection.
    #>
    param([Parameter(Mandatory)][ValidateSet('Yes', 'Confirm')][string]$Kind)
    $key = 'Typed' + $Kind + 'Word'
    $words = New-Object System.Collections.Generic.List[string]
    $words.Add($(if ($Kind -eq 'Yes') { 'YES' } else { 'CONFIRM' }))
    foreach ($lang in @($script:Translations.Keys)) {
        $word = [string]$script:Translations[$lang][$key]
        if ($word -and -not ($words -contains $word)) { $words.Add($word) }
    }
    return [string[]]$words.ToArray()
}

function Get-WtGateWordHint {
    <#
    .SYNOPSIS
        The line a gate panel shows above its prompt (and a refusal
        repeats): which word to type, case-insensitive. Names the
        English word too unless the screen is already in English.
    #>
    param([Parameter(Mandatory)][ValidateSet('Yes', 'Confirm')][string]$Kind)
    $local = Get-WtTypedWord -Kind $Kind
    $english = $(if ($Kind -eq 'Yes') { 'YES' } else { 'CONFIRM' })
    if ([string]::Equals($local, $english, [System.StringComparison]::OrdinalIgnoreCase)) { return ((Get-Translation 'GateWordHintOne') -f $local) }
    return ((Get-Translation 'GateWordHint') -f $local, $english)
}

function Get-WtGateRefusalLines {
    <#
    .SYNOPSIS
        PURE: what a gate dropped, said plainly. "Nothing left to apply"
        on its own tells the user nothing - this names the word they did
        not type, lists the rows it cost them, and repeats that case does
        not matter so they know the retry will work.
    #>
    param([AllowEmptyCollection()][array]$Dropped = @())
    $lines = New-Object System.Collections.Generic.List[string]
    $real = @($Dropped | Where-Object { $_ -and @($_.Labels).Count -gt 0 })
    foreach ($d in $real) {
        $kind = [string]$d.Kind
        $lines.Add($(if ($kind -eq 'Mechanism') { Get-Translation 'GateRefusedMechanism' }
                     else { (Get-Translation 'GateRefusedTyped') -f (Get-WtTypedWord -Kind $kind) }))
        foreach ($label in @($d.Labels)) { $lines.Add('  - ' + [string]$label) }
    }
    foreach ($kind in @($real | ForEach-Object { [string]$_.Kind } | Where-Object { $_ -ne 'Mechanism' } | Select-Object -Unique)) {
        $lines.Add('')
        $lines.Add((Get-WtGateWordHint -Kind $kind))
    }
    return [string[]]$lines.ToArray()
}

function Test-WtTypedConfirmation {
    <#
    .SYNOPSIS
        True when the user typed the gate word, in any shipped language,
        matched Ordinal-IgnoreCase rather than ToUpper/-eq because tr-TR
        maps i to I-with-dot and would otherwise miss the match.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Answer,
        [Parameter(Mandatory)][ValidateSet('Yes', 'Confirm')][string]$Kind
    )
    $text = ([string]$Answer).Trim()
    if (-not $text) { return $false }
    foreach ($word in (Get-WtAcceptedTypedWords -Kind $Kind)) {
        if ([string]::Equals($text, $word, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}


function Confirm-WtDestructiveAction {
    <#
    .SYNOPSIS
        Typed-confirmation gate rendered in the panel: the consequence
        (red) plus optional detail lines, then the prompt on the footer
        row. The word the user must type is the localized one (YES in
        English, EVET in Turkish) and the match is case-sensitive.
    #>
    param(
        [Parameter(Mandatory)][string]$Consequence,
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [string]$Breadcrumb = '',
        [scriptblock]$ReadAnswer = { param($Lines, $Prompt) Read-WtPanelAnswer -Breadcrumb $(if ($Breadcrumb) { $Breadcrumb } else { $script:WtPanelBreadcrumb }) -Lines $Lines -Prompt $Prompt -Risk 'ADVANCED' }
    )
    $all = @($Consequence) + @($Lines)
    $typed = & $ReadAnswer $all ((Get-Translation 'TypeYesToConfirm') -f (Get-WtTypedWord -Kind 'Yes'))
    return (Test-WtTypedConfirmation -Answer $typed -Kind 'Yes')
}
