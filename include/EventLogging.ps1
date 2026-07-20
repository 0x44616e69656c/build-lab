<#
.SYNOPSIS
    Windows Application event log helpers: source registration and a sanitized event writer.
.DESCRIPTION
    Initialize-EventLogSource is get-AdminAudit's robust variant (formerly
    Initialize-AuditEventSource), kept verbatim as the superset implementation: it checks
    [System.Diagnostics.EventLog]::SourceExists (treating a thrown check as "not
    registered"), attempts New-EventLog, and on any failure logs a warning and falls back
    to the built-in 'Application' source. Returns the effective source name.

    Write-AppEvent (formerly Write-AuditEvent / Write-RemediationEvent, merged) writes a
    single event-log entry gated by an -Enabled flag, with the message passed through
    ConvertTo-SafeLogValue (Sanitization.ps1) before being written. A write failure never
    aborts the caller -- it degrades to Write-Warning. ValidateSet includes SuccessAudit
    and FailureAudit (used by get-RogueAdmins' remediation-event entry types) in addition
    to Information/Warning/Error.
.EXAMPLE
    $sourceName = Initialize-EventLogSource -SourceName 'Get-AdminAudit'
    Write-AppEvent -Enabled $enableEventLogging -SourceName $sourceName `
        -EntryType Information -EventId 1000 -Message 'Get-AdminAudit started.'
.NOTES
    Version:          1.0.0
    Author:           Daniel Owen
    Release Date:     2026-06-11
    Requirements:     Windows PowerShell 5.1. Dot-source Sanitization.ps1 first (hard
                      dependency: Write-AppEvent calls ConvertTo-SafeLogValue).
                      WARNING: Write-EventLog is deprecated in PowerShell 7+. This library
                      targets Windows PowerShell 5.1, where Write-EventLog is the correct
                      API. For a PowerShell 7+ port, replace Write-EventLog with
                      New-WinEvent against a registered ETW manifest.
    Event Log Source: Source registration is performed by the consuming script via
                      Initialize-EventLogSource and requires local administrator rights on
                      the target machine. Registration failure falls back to the built-in
                      'Application' source automatically.
#>

#region Functions

function Initialize-EventLogSource {
    # Ensures the Windows event-log source is registered so the consuming script can write
    # to the Application log for SIEM ingestion (rule 25). Returns the effective source name:
    # the requested source if it exists or can be registered, otherwise the built-in
    # 'Application' source. New-EventLog source registration requires LOCAL ADMINISTRATOR
    # rights (rule 26); a non-admin run falls back to 'Application' instead of failing.
    param (
        [Parameter(Mandatory)]
        [string]$SourceName,
        [string]$LogName = 'Application'
    )
    try {
        if ([System.Diagnostics.EventLog]::SourceExists($SourceName)) { return $SourceName }
    }
    catch {
        # SourceExists can throw on restricted logs; treat as "not registered" and try to create.
        Write-Verbose "SourceExists check failed for '$SourceName'; will attempt registration: $($_.Exception.Message)"
    }
    try {
        New-EventLog -LogName $LogName -Source $SourceName -ErrorAction Stop
        return $SourceName
    }
    catch {
        Write-Warning "Event source '$SourceName' could not be registered (this requires local administrator rights). Falling back to the built-in 'Application' source. $($_.Exception.Message)"
        return 'Application'
    }
}

function Write-AppEvent {
    # Writes a single Windows event-log entry, gated by the caller's -Enabled flag.
    # WARNING (rule 26): Write-EventLog is deprecated in PowerShell 7+. This targets Windows
    # PowerShell 5.1; for a PS7 target, replace with New-WinEvent against a registered manifest.
    # A write failure never aborts the caller - it degrades to a warning (rule 66, no silent swallow).
    param (
        [bool]$Enabled = $true,
        [Parameter(Mandatory)]
        [string]$SourceName,
        [string]$LogName = 'Application',
        [Parameter(Mandatory)]
        [ValidateSet('Information', 'Warning', 'Error', 'SuccessAudit', 'FailureAudit')]
        [string]$EntryType,
        [Parameter(Mandatory)]
        [int]$EventId,
        [Parameter(Mandatory)]
        [string]$Message
    )
    if (-not $Enabled) { return }
    try {
        Write-EventLog -LogName $LogName -Source $SourceName -EntryType $EntryType `
            -EventId $EventId -Message (ConvertTo-SafeLogValue -Value $Message) -ErrorAction Stop
    }
    catch {
        Write-Warning "Write-AppEvent: failed to write event (source '$SourceName', id $EventId): $($_.Exception.Message)"
    }
}

#endregion Functions
