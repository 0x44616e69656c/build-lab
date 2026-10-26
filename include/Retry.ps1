<#
.SYNOPSIS
    Retries a script block with backoff, returning a boolean by default.
.DESCRIPTION
    Reconciles new-AdDomain's Invoke-ADWriteWithRetry (throws on exhaustion, returns
    nothing) with get-RogueAdmins' Invoke-ADWriteWithRetry (returns $true/$false, logs to
    a CSV path). Invoke-CommandWithRetry returns $true on success and, by default,
    $false on exhaustion; pass -ThrowOnFailure to re-throw the last error instead
    (matching new-AdDomain's previous behavior).

    Behavior:
      - Runs -ScriptBlock up to -RetryCount times (default 12), discarding its output so
        this function always returns a clean [bool] (or throws/nothing with
        -ThrowOnFailure).
      - On each failed attempt, logs "Attempt N of RetryCount failed for [OperationName]:
        <error>" at WARN, then sleeps -RetryDelaySeconds (default 10) unless it was the
        final attempt.
      - On exhaustion, logs "All RetryCount attempts exhausted for [OperationName]. Last
        error: <error>" at ERROR, then either throws the last error (-ThrowOnFailure) or
        returns $false.

    Logging soft-dependency: -LogAction (signature: param([string]$Message,
    [string]$Level)) is tried first. If not supplied, and a Write-Log function
    (Logging.ps1) is present in the session, it is used automatically. Otherwise falls
    back to Write-Warning. This module has no hard dependency on Logging.ps1 -- it works
    standalone, -LogAction always wins, and call sites inside rule-8 pure functions need
    no logging plumbing while still getting CSV persistence when Logging.ps1 is loaded.

    CALL-SITE HAZARD: unlike new-AdDomain's previous throwing wrapper (which returned
    nothing), this returns $true on success. In -ThrowOnFailure call sites the result
    MUST be discarded ($null = Invoke-CommandWithRetry ...) or a stray $true pollutes the
    enclosing function's pipeline output.
.EXAMPLE
    $success = Invoke-CommandWithRetry -ScriptBlock { Remove-ADGroupMember -Identity $groupName -Members $sid -Confirm:$false }.GetNewClosure() `
        -OperationName "Remove $samAccountName from $groupName"
.EXAMPLE
    $null = Invoke-CommandWithRetry -ScriptBlock { New-ADOrganizationalUnit -Name $localOUName -Path $domainDN }.GetNewClosure() `
        -OperationName "New-ADOU $localOUName" -ThrowOnFailure
.NOTES
    Version:          1.0.1
    Author:           Daniel Owen
    Release Date:     2026-10-26
    Requirements:     Windows PowerShell 5.1. Soft dependency on Logging.ps1 (Write-Log
                      auto-detected via Get-Command if -LogAction is not supplied; see
                      DESCRIPTION).
    Event Log Source: N/A
#>

#region Functions

function Invoke-CommandWithRetry {
    param (
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        [Parameter(Mandatory)]
        [string]$OperationName,
        [int]$RetryCount = 12,
        [int]$RetryDelaySeconds = 10,
        [switch]$ThrowOnFailure,
        [scriptblock]$LogAction
    )

    # Local helper scriptblock: -LogAction wins if supplied; else auto-detect Write-Log
    # (Logging.ps1) in the session; else Write-Warning. Takes its inputs as parameters
    # only, so it carries no dependency on outer-scope variables.
    $writeRetryLog = {
        param ([string]$LogMessage, [string]$LogLevel, [scriptblock]$LogActionParam)
        if ($LogActionParam) {
            & $LogActionParam $LogMessage $LogLevel
        }
        elseif (Get-Command -Name Write-Log -CommandType Function -ErrorAction SilentlyContinue) {
            Write-Log $LogMessage -Level $LogLevel
        }
        else {
            Write-Warning $LogMessage
        }
    }

    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            $null = & $ScriptBlock
            return $true
        }
        catch {
            $lastError = $_
            & $writeRetryLog "Attempt $attempt of $RetryCount failed for [$OperationName]: $_" 'WARN' $LogAction
            if ($attempt -lt $RetryCount) {
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }
    }

    & $writeRetryLog "All $RetryCount attempts exhausted for [$OperationName]. Last error: $lastError" 'ERROR' $LogAction
    if ($ThrowOnFailure) { throw $lastError }
    return $false
}

#endregion Functions
