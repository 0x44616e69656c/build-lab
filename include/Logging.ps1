<#
.SYNOPSIS
    Unified logging API: console, text-log, and CSV-log output via a shared or explicit context.
.DESCRIPTION
    Replaces three separate logging implementations (new-AdDomain's
    Write-LogInfo/Warn/Error/Success/Debug, get-RogueAdmins' Write-CsvLogEntry, and
    get-AdminAudit's Write-RunLog) with one API and one log-row shape.

    Three public functions, hybrid context model:
      - New-LogContext:    builds a context hashtable @{ ScriptName; CsvLogPath;
                            TextLogPath; CsvLevels }. Creates the parent directory of
                            CsvLogPath/TextLogPath when provided. Touches no module state
                            -- used directly for multi-log scenarios and tests.
      - Initialize-Logging: builds a context via New-LogContext, optionally creates an
                            extra -LogDirectory (e.g. a transcript directory), and stores
                            the context as the ambient default in $script:sharedLogContext.
                            Returns the context only with -PassThru.
      - Write-Log:         writes one log line. Always writes to the console
                            (color-coded by level). If the effective context (explicit
                            -Context, else the ambient $script:sharedLogContext) has a
                            TextLogPath, appends the line there. If it has a CsvLogPath
                            and $Level is in CsvLevels (default WARN/ERROR/FATAL), appends
                            a sanitized CSV row. With no context at all (neither -Context
                            nor an ambient default), Write-Log is console-only.

    Hybrid design rationale: pure context-passing would force a -LogContext parameter
    onto roughly 50 domain functions across the consumer scripts (over a hundred call
    sites) -- enormous churn and brittle signatures. Pure module state would break
    get-AdminAudit's deliberate stateless design. The hybrid keeps the only state inside
    this subsystem: $script:sharedLogContext is written by Initialize-Logging and read
    only by Write-Log. Because $script: resolves to the *consuming script's* scope when
    this file is dot-sourced, two different scripts in one session cannot collide.
    Explicit -Context is preferred for new code; the ambient default is the
    migration-friendly form for call sites that cannot easily thread a parameter.

    Timestamps use ISO 8601 'yyyy-MM-ddTHH:mm:ss' (T-form), unifying new-AdDomain's
    space-form and get-RogueAdmins/get-AdminAudit's T-form. CSV rows are sanitized via
    ConvertTo-SafeLogValue (Sanitization.ps1) -- new for new-AdDomain's CSV output, a
    harmless superset behavior. FATAL is in the default CsvLevels because get-RogueAdmins
    logs FATAL rows. Console output uses Write-Host (transcript-friendly) for every level,
    including WARN/ERROR -- this replaces get-AdminAudit's Write-Warning/Write-Error
    mirroring; Write-Log calls no longer emit error-stream records.
.EXAMPLE
    $logContext = Initialize-Logging -ScriptName 'Get-AdminAudit.ps1' -TextLogPath $runLogPath -PassThru
    Write-Log "Starting audit" -Context $logContext
    Write-Log "Group not found" -Level WARN -Context $logContext
.EXAMPLE
    Initialize-Logging -ScriptName 'New-ADForestDeployment.ps1' -CsvLogPath $csvErrorLogPath -LogDirectory $logPath
    Write-Log "Deployment started"
    Write-Log "Failed to create OU" -Level ERROR
.NOTES
    Version:          1.0.0
    Author:           Daniel Owen
    Release Date:     2026-06-11
    Requirements:     Windows PowerShell 5.1. Dot-source Sanitization.ps1 first (hard
                      dependency: Write-Log calls ConvertTo-SafeLogValue for CSV rows).
    Event Log Source: N/A
#>

#region Module-Level State
# Set by Initialize-Logging; read only by Write-Log. Resolves to the consuming script's
# scope when this file is dot-sourced, so two scripts in one session cannot collide.
$script:sharedLogContext = $null
#endregion

#region Functions

function New-LogContext {
    param (
        [Parameter(Mandatory)]
        [string]$ScriptName,
        [string]$CsvLogPath,
        [string]$TextLogPath,
        [string[]]$CsvLevels = @('WARN', 'ERROR', 'FATAL')
    )
    if ($CsvLogPath) {
        $csvLogDirectory = Split-Path -Path $CsvLogPath -Parent
        if ($csvLogDirectory -and -not (Test-Path -Path $csvLogDirectory)) {
            $null = New-Item -ItemType Directory -Path $csvLogDirectory -Force
        }
    }
    if ($TextLogPath) {
        $textLogDirectory = Split-Path -Path $TextLogPath -Parent
        if ($textLogDirectory -and -not (Test-Path -Path $textLogDirectory)) {
            $null = New-Item -ItemType Directory -Path $textLogDirectory -Force
        }
    }
    return @{
        ScriptName  = $ScriptName
        CsvLogPath  = $CsvLogPath
        TextLogPath = $TextLogPath
        CsvLevels   = $CsvLevels
    }
}

function Initialize-Logging {
    param (
        [Parameter(Mandatory)]
        [string]$ScriptName,
        [string]$CsvLogPath,
        [string]$TextLogPath,
        [string]$LogDirectory,
        [string[]]$CsvLevels = @('WARN', 'ERROR', 'FATAL'),
        [switch]$PassThru
    )
    $context = New-LogContext -ScriptName $ScriptName -CsvLogPath $CsvLogPath `
        -TextLogPath $TextLogPath -CsvLevels $CsvLevels
    if ($LogDirectory -and -not (Test-Path -Path $LogDirectory)) {
        $null = New-Item -ItemType Directory -Path $LogDirectory -Force
    }
    $script:sharedLogContext = $context
    if ($PassThru) { return $context }
}

function Write-Log {
    param (
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'DEBUG', 'FATAL')]
        [string]$Level = 'INFO',
        [hashtable]$Context
    )
    $effectiveContext = $Context
    if ($null -eq $effectiveContext) { $effectiveContext = $script:sharedLogContext }

    $timestamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
    $line = "$timestamp [$Level]   $Message"

    switch ($Level) {
        'WARN'    { Write-Host $line -ForegroundColor Yellow }
        'ERROR'   { Write-Host $line -ForegroundColor Red }
        'FATAL'   { Write-Host $line -ForegroundColor Red }
        'SUCCESS' { Write-Host $line -ForegroundColor Green }
        'DEBUG'   { Write-Host $line -ForegroundColor Cyan }
        default   { Write-Host $line }
    }

    if ($null -eq $effectiveContext) { return }

    if ($effectiveContext.TextLogPath) {
        try {
            Add-Content -Path $effectiveContext.TextLogPath -Value $line -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            Write-Warning "Write-Log: failed to write to text log '$($effectiveContext.TextLogPath)': $_"
        }
    }

    if ($effectiveContext.CsvLogPath -and $effectiveContext.CsvLevels -contains $Level) {
        try {
            [pscustomobject]@{
                Timestamp = $timestamp
                Level     = $Level
                Script    = $effectiveContext.ScriptName
                Message   = (ConvertTo-SafeLogValue -Value $Message)
            } | Export-Csv -Path $effectiveContext.CsvLogPath -Append -NoTypeInformation -Encoding UTF8
        }
        catch {
            Write-Warning "Write-Log: failed to write to CSV log '$($effectiveContext.CsvLogPath)': $_"
        }
    }
}

#endregion Functions
