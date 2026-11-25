<#
.SYNOPSIS
    Registers a Windows event log source under the Application log, once per machine.
.DESCRIPTION
    The setup helper for scripts that write Windows events through EventLogging.ps1.
    Those scripts never register their own source. They check for it with
    Test-EventLogSource and write no events while it is missing. Run this once, elevated,
    on each machine that runs such a script, with the source name the script uses.

    It looks for the source's key under the Application log, the same registry path
    Test-EventLogSource reads. When the key is there, it says so and changes nothing, so
    running it twice is safe. When the source is registered under some other log, it
    stops and says which, because the scripts' check would never find it there.
    Otherwise it registers the source under the Application log with New-EventLog, then
    reads the key again to confirm.

    It writes to the console only. It keeps no CSV log and writes no event.
.PARAMETER SourceName
    The event source to register, as the consuming script names it, such as build-lab.
    Letters, digits, spaces, dots, underscores and hyphens, starting with a letter or
    digit.
.EXAMPLE
    .\Register-EventLogSource.ps1 -SourceName 'build-lab'
    Registers the build-lab source under the Application log, from an elevated prompt.
.EXAMPLE
    .\Register-EventLogSource.ps1 -SourceName 'build-lab' -WhatIf
    Says what it would do and changes nothing.
.OUTPUTS
    One line of text per step, to the console. It stops with an error when it can't
    register the source.
.NOTES
    Version:          1.0.1
    Author:           Daniel Owen
    Release Date:     2026-11-19
    SPDX-License-Identifier: MIT
    Requirements:     Windows PowerShell 5.1, run as Administrator. Registering a source
                      writes under HKLM, which needs local administrator rights.
    Target Set Source: N/A
    Event Log Source: N/A
    Setup:            N/A
.LINK
    https://github.com/0x44616e69656c/
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory)]
    [ValidatePattern('\A[A-Za-z0-9][A-Za-z0-9 ._-]*\z')]
    [string]$SourceName
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

#region Variables
# The path Test-EventLogSource in EventLogging.ps1 reads. The two must stay the same.
$sourcePath = "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\$SourceName"
#endregion

#region Main
if (Test-Path -LiteralPath $sourcePath) {
    Write-Output "Event log source '$SourceName' is already registered under the Application log. Nothing changed."
    exit 0
}

# This script runs elevated, so a lookup across every log is reliable here.
$otherLogName = [System.Diagnostics.EventLog]::LogNameFromSourceName($SourceName, '.')
if (-not [string]::IsNullOrEmpty($otherLogName)) {
    throw "Event log source '$SourceName' is registered under the '$otherLogName' log, not the Application log, so the scripts that use it would never find it. Remove it with Remove-EventLog -Source '$SourceName', then run this script again."
}

if ($PSCmdlet.ShouldProcess("the Application event log on $env:COMPUTERNAME", "Register the event source '$SourceName'")) {
    New-EventLog -LogName 'Application' -Source $SourceName
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "New-EventLog reported no error, but '$sourcePath' still isn't there. Check the Application log's registry key, then run this script again."
    }
    Write-Output "Event log source '$SourceName' is registered under the Application log."
}
#endregion
