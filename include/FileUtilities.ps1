<#
.SYNOPSIS
    Generic file and directory utility helpers.
.DESCRIPTION
    Two dependency-free utilities moved from get-AdminAudit\AdminAudit.Common.ps1:
      - Initialize-OutputDirectory: creates a directory if it does not already exist
        (verbatim).
      - Import-JsonListFile: parses a JSON list file into an array, returning @() with
        a warning on a missing path or a parse failure (verbatim behavior; renamed from
        Import-AuditListFile as a generic utility -- approved verb kept).
.EXAMPLE
    Initialize-OutputDirectory -DirectoryPath 'C:\Reports\AdminAudit'
.EXAMPLE
    $allowlist = Import-JsonListFile -FilePath '.\allowlist.json' -ListType 'Allowlist'
.NOTES
    Version:          1.0.0
    Author:           Daniel Owen
    Release Date:     2026-06-11
    Requirements:     Windows PowerShell 5.1.
    Event Log Source: N/A
#>

#region Functions

function Initialize-OutputDirectory {
    param (
        [Parameter(Mandatory)]
        [string]$DirectoryPath
    )
    if (-not (Test-Path -Path $DirectoryPath)) {
        $null = New-Item -ItemType Directory -Path $DirectoryPath -Force
    }
}

function Import-JsonListFile {
    param (
        [Parameter()]
        [string]$FilePath,
        [Parameter(Mandatory)]
        [string]$ListType
    )
    if ([string]::IsNullOrEmpty($FilePath)) { return @() }
    if (-not (Test-Path -Path $FilePath)) {
        Write-Warning "[$ListType] file not found: $FilePath. Proceeding with empty $ListType."
        return @()
    }
    try {
        $rawContent = Get-Content -Path $FilePath -Raw -ErrorAction Stop
        $parsedContent = $rawContent | ConvertFrom-Json -ErrorAction Stop
        return @($parsedContent)
    }
    catch {
        Write-Warning "[$ListType] failed to parse '$FilePath': $($_.Exception.Message). Proceeding with empty $ListType."
        return @()
    }
}

#endregion Functions
