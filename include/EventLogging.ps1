<#
.SYNOPSIS
    Windows Application event log helpers: a check that the script's own event source is
    registered, and a sanitized event writer.
.DESCRIPTION
    Test-EventLogSource checks whether an event source is registered under the
    Application log by reading its registry key, which a standard user can normally do.
    It never registers a source, never falls back to another source, and writes nothing
    itself. It returns SourceName, Registered and Warning. When the source is absent, or
    the check throws (a hardened host can restrict those keys), Registered is $false and
    Warning names the source and the setup helper, Register-EventLogSource.ps1. The
    caller then turns its own event logging off for the rest of the run and logs the
    warning in its own log. A caller that also declined CSV logging has no durable
    record left, and should stop at startup instead. Only the caller knows that, so the
    decision is the caller's.

    Write-AppEvent writes one Application log entry under the caller's source, only when
    the caller's -EnableEventLogging flag is $true. The message passes through
    ConvertTo-SafeLogValue (Sanitization.ps1) first. A write failure never aborts the
    caller. It becomes a Write-Warning, so it is never swallowed silently. The entry
    type list includes SuccessAudit and FailureAudit as well as Information, Warning
    and Error.

    Registering a source is the job of Register-EventLogSource.ps1, run once, elevated,
    per machine. Nothing in this file registers one.
.EXAMPLE
    $enableEventLogging = $true
    $eventLogSourceName = 'Get-AdminAudit'
    $sourceCheck = Test-EventLogSource -SourceName $eventLogSourceName
    if (-not $sourceCheck.Registered) {
        $enableEventLogging = $false
        Write-Log $sourceCheck.Warning -Level WARN
    }
    Write-AppEvent -EnableEventLogging $enableEventLogging -SourceName $eventLogSourceName `
        -EntryType Information -EventId 1000 -Message 'Get-AdminAudit started.'
.NOTES
    Version:          2.0.1
    Author:           Daniel Owen
    Release Date:     2026-11-19
    SPDX-License-Identifier: MIT
    Requirements:     Windows PowerShell 5.1. Dot-source Sanitization.ps1 first (hard
                      dependency: Write-AppEvent calls ConvertTo-SafeLogValue).
                      Write-AppEvent uses Write-EventLog, which exists in Windows
                      PowerShell 5.1 only. The *-EventLog cmdlets were removed in
                      PowerShell 7, where the equivalent is
                      [System.Diagnostics.EventLog]::WriteEntry(). Never New-WinEvent,
                      which needs a compiled, registered instrumentation manifest.
    Target Set Source: N/A
    Event Log Source: Named by the consuming script, and checked with
                      Test-EventLogSource.
    Setup:            Register-EventLogSource.ps1 -SourceName <name>, run once,
                      elevated, on each machine that runs the consuming script.
.LINK
    https://github.com/0x44616e69656c/
#>

#region Functions

function Test-EventLogSource {
    # Checks whether an event source is registered under the Application log, by reading
    # its registry key. Registers nothing and writes nothing. Returns SourceName,
    # Registered ($true only when the key exists) and Warning ($null, or the text for the
    # caller to log when Registered is $false). A check that throws counts as "can't be
    # checked", never as "absent".
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidatePattern('\A[A-Za-z0-9][A-Za-z0-9 ._-]*\z')]
        [string]$SourceName
    )
    $sourcePath = "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\$SourceName"
    $result = [pscustomobject]@{ SourceName = $SourceName; Registered = $false; Warning = $null }
    $setupText = "Run Register-EventLogSource.ps1 -SourceName '$SourceName' once, elevated, to register it."
    try {
        $result.Registered = [bool](Test-Path -LiteralPath $sourcePath)
        if (-not $result.Registered) {
            $result.Warning = "Event log source '$SourceName' isn't registered under the Application log, so this run writes no events. $setupText"
        }
    } catch {
        $result.Registered = $false
        $result.Warning = "Event log source '$SourceName' couldn't be checked ($($_.Exception.GetType().FullName) reading its registry key), so this run writes no events. If it isn't registered yet, run Register-EventLogSource.ps1 -SourceName '$SourceName' once, elevated."
    }
    return $result
}

function Write-AppEvent {
    # Writes one Application log entry under the caller's source, only when the caller's
    # -EnableEventLogging flag is $true. A write failure never aborts the caller. It
    # becomes a warning, so it is never swallowed silently. Windows PowerShell 5.1 only,
    # because Write-EventLog doesn't exist in PowerShell 7.
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [bool]$EnableEventLogging,

        [Parameter(Mandatory)]
        [string]$SourceName,

        [Parameter(Mandatory)]
        [ValidateSet('Information', 'Warning', 'Error', 'SuccessAudit', 'FailureAudit')]
        [string]$EntryType,

        [Parameter(Mandatory)]
        [int]$EventId,

        [Parameter(Mandatory)]
        [string]$Message
    )
    if (-not $EnableEventLogging) { return }
    try {
        Write-EventLog -LogName 'Application' -Source $SourceName -EntryType $EntryType `
            -EventId $EventId -Message (ConvertTo-SafeLogValue -Value $Message) -ErrorAction Stop
    }
    catch {
        Write-Warning "Write-AppEvent: failed to write event (source '$SourceName', id $EventId): $($_.Exception.Message)"
    }
}

#endregion Functions
