<#
.SYNOPSIS
    Neutralizes attacker-influenceable strings before they are written to CSV files or
    log/event messages.
.DESCRIPTION
    Provides ConvertTo-SafeLogValue, a superset of get-RogueAdmins' ConvertTo-SafeLogValue
    and get-AdminAudit's ConvertTo-CsvSafeValue.

    Default behavior (log-friendly):
      - $null returns $null unchanged; empty string returns empty string.
      - Non-string input is cast to [string].
      - CR, LF, and TAB are replaced with a single space (log-injection guard: a crafted
        value cannot forge an extra CSV row or split a line-oriented SIEM message).
      - If the resulting value starts with =, +, -, or @ (a spreadsheet formula trigger),
        a single quote is prefixed so the value cannot execute as a formula when the CSV
        is opened in Excel/LibreOffice (CSV/DDE injection).

    -PreserveLineBreaks (CSV-data-cell behavior):
      - CR/LF/TAB are NOT stripped (Export-Csv quoting makes embedded newlines legal and
        content fidelity matters for data cells).
      - The formula-guard trigger set widens to =, +, -, @, TAB, and CR as the first
        character (exact ConvertTo-CsvSafeValue behavior).

    The default (stripping) form is the recommended call for log/event messages
    everywhere. -PreserveLineBreaks exists so CSV data-cell call sites can keep
    byte-identical output where content fidelity matters.
.EXAMPLE
    ConvertTo-SafeLogValue -Value "=cmd|' /c calc'!A0"
    Returns "'=cmd|' /c calc'!A0" -- formula-guard prefix added.
.EXAMPLE
    ConvertTo-SafeLogValue -Value "line1`r`nline2"
    Returns "line1 line2" -- CR/LF flattened to spaces (log-injection guard).
.EXAMPLE
    ConvertTo-SafeLogValue -Value "line1`r`nline2" -PreserveLineBreaks
    Returns "line1`r`nline2" unchanged -- CRLF preserved for a CSV data cell.
.NOTES
    Version:          1.0.0
    Author:           Daniel Owen
    Release Date:     2026-06-11
    Requirements:     Windows PowerShell 5.1.
    Event Log Source: N/A
#>

#region Functions

function ConvertTo-SafeLogValue {
    param (
        [Parameter()]
        [AllowNull()]
        [object]$Value,
        [switch]$PreserveLineBreaks
    )
    if ($null -eq $Value) { return $Value }
    $stringValue = [string]$Value
    if ($stringValue.Length -eq 0) { return $stringValue }

    if ($PreserveLineBreaks) {
        $firstChar = $stringValue[0]
        if ($firstChar -in @('=', '+', '-', '@', "`t", "`r")) {
            return "'$stringValue"
        }
        return $stringValue
    }

    $cleanValue = $stringValue -replace '[\r\n\t]', ' '
    if ($cleanValue -match '^[=+\-@]') { $cleanValue = "'" + $cleanValue }
    return $cleanValue
}

#endregion Functions
