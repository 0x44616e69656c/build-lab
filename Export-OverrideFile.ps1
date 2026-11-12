<#
.SYNOPSIS
    Writes an override file from the settings you changed in an older copy of
    build-lab, so an upgrade keeps them.
.DESCRIPTION
    Reads the old copy's build-lab.ps1 by parsing it, never running it,
    and compares each setting with the value that release shipped with, taken from
    include\release-values.psd1 beside this script. Every setting you changed goes into
    a new overrides\overrides.psd1 in this script's folder, which every later release
    reads and no upgrade touches. OVERRIDE.md lists the settings.

    In order:
      1. The old script's header Version names the release it came from. Where the
         header matches no release, or more than one, every candidate release is used,
         and a value equal to the shipped value of any of them counts as unchanged.
         -ReferencePath replaces the table with a clean copy of the old release.
      2. For each setting: a value equal to the shipped one is left out. A changed
         value is written. A value the old script computes at run time can't be read,
         and is reported for you to set by hand. A shipped default that changed since
         your release, which you never edited, is reported and written only with
         -KeepPreviousDefaults.
      3. Each value is checked as the new release will check it. A value it would
         refuse is written commented out, with the reason, so the next run doesn't
         stop on it.
      4. Nothing that exists is overwritten. When overrides\overrides.psd1 already
         exists, the new file goes to overrides\migrated-<yyyyMMdd-HHmmss>\ instead,
         which no script reads, for you to merge by hand.
      5. The written file is read back with the reader the script uses, and the run
         ends with what was written and what to do next.
    build-lab's settings hold no secret. A relative VmBuilderScriptPath or
    AdDomainSourcePath default is carried over with a WARN, because the override file
    resolves it from build-lab's folder.

    Intake answers for this script:
      - CSV run log: on, every level, one file per run in -LogPath, never pruned. One
        row per setting is the report, so no separate results file is written
      - Windows event logging: none
      - Strict mode: on
      - Write mode and scope cap: no directory writes. It writes one file in this
        script's overrides folder, behind -WhatIf and -Confirm
      - Retry: none, it calls no service
      - Shared code: include\OverrideFile.ps1, include\Logging.ps1 and
        include\Sanitization.ps1, copies of the shared modules
      - Credentials: none
      - Log retention: forever
.PARAMETER SourcePath
    The folder of the older copy, for example ..\build-lab-old. It is read
    only. It may be this folder, when you edited the script of this release.
.PARAMETER ReferencePath
    Optional. The folder of an unedited copy of the same older release. Its values are
    used as the shipped ones in place of include\release-values.psd1.
.PARAMETER KeepPreviousDefaults
    Also write the settings whose shipped default changed since your release and which
    you never edited, so the next build matches the old one.
.PARAMETER LogPath
    The folder for the run log. Defaults to the logs folder beside this script.
.EXAMPLE
    .\Export-OverrideFile.ps1 -SourcePath ..\build-lab-old -WhatIf
.EXAMPLE
    .\Export-OverrideFile.ps1 -SourcePath ..\build-lab-old
.EXAMPLE
    .\Export-OverrideFile.ps1 -SourcePath ..\build-lab-old -ReferencePath ..\build-lab-2.1.0-clean
.OUTPUTS
    None on the pipeline. Console lines, the CSV run log
    Export-OverrideFile_<yyyyMMdd-HHmmss>.csv in -LogPath, and the override file. Exit
    code 0 on success or after -WhatIf, 1 on any failure.
.NOTES
    Version: 2.2.0
    Author: Daniel Owen
    Release Date: 2026-11-12
    Requirements: Windows PowerShell 5.1. include\OverrideFile.ps1, include\Logging.ps1,
        include\Sanitization.ps1, include\override-catalog.psd1 and
        include\release-values.psd1, and this release's build-lab.ps1,
        all beside this script. Run logs are kept forever, never pruned.
    Target Set Source: the older copy's build-lab.ps1, given by -SourcePath
    Event Log Source: N/A
    Setup: N/A
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourcePath,

    [string]$ReferencePath,

    [switch]$KeepPreviousDefaults,

    [string]$LogPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

#region Include
# Sanitization.ps1 loads before Logging.ps1, which calls ConvertTo-SafeLogValue for
# every CSV row.
foreach ($includeFileName in @('Sanitization.ps1', 'Logging.ps1', 'OverrideFile.ps1')) {
    $includeFilePath = Join-Path -Path $PSScriptRoot -ChildPath "include\$includeFileName"
    if (-not (Test-Path -LiteralPath $includeFilePath -PathType Leaf)) {
        throw ('Required include file not found: {0}. Put it back from this release of build-lab.' -f $includeFilePath)
    }
    . $includeFilePath
}
#endregion Include

#region Functions

function Initialize-ExportLogContext {
    # Builds the log context. The log is the run's report, so -WhatIf and -Confirm never
    # hold it back.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [Parameter(Mandatory = $true)][string]$CsvLogPath
    )
    $WhatIfPreference = $false
    $ConfirmPreference = 'None'
    return (New-LogContext -ScriptName $ScriptName -CsvLogPath $CsvLogPath -CsvLevels @('INFO', 'WARN', 'ERROR', 'SUCCESS', 'DEBUG', 'FATAL'))
}

function Write-ExportLog {
    # One log row, written in a preview run too.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'FATAL')][string]$Level,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message
    )
    $WhatIfPreference = $false
    $ConfirmPreference = 'None'
    Write-Log -Message $Message -Level $Level -Context $Context
}

function Find-BuildLabScript {
    # build-lab.ps1 in a project folder, found ignoring case as the folder lookup does.
    # $null when absent.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$FolderPath
    )
    $buildLabFile = @(Get-ChildItem -LiteralPath $FolderPath -Filter 'build-lab.ps1' -File -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($null -eq $buildLabFile) { return $null }
    return $buildLabFile.FullName
}

function Get-OldSetting {
    # One catalog key's value in a parsed script: a Parameter key from the parameter's
    # default, a Constant key from its last top-level assignment. State is Value,
    # Dynamic, NoDefault or NotFound.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][object]$ScriptSetting,
        [Parameter(Mandatory = $true)][object]$CatalogEntry
    )
    $notFound = [pscustomobject]@{ State = 'NotFound'; Value = $null; SourceText = $null; Line = $null }
    if ($CatalogEntry.Target -ceq 'Parameter') {
        $parameterSetting = @($ScriptSetting.Parameters) | Where-Object { [string]::Equals($_.Name, $CatalogEntry.Name, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        if ($null -eq $parameterSetting) { return $notFound }
        return [pscustomobject]@{ State = $parameterSetting.State; Value = $parameterSetting.Value; SourceText = $parameterSetting.SourceText; Line = $parameterSetting.Line }
    }
    $assignmentSetting = @(@($ScriptSetting.Assignments) | Where-Object { $null -ne $_ -and [string]::Equals($_.Name, $CatalogEntry.Name, [System.StringComparison]::OrdinalIgnoreCase) }) | Select-Object -Last 1
    if ($null -eq $assignmentSetting) { return $notFound }
    return [pscustomobject]@{ State = $assignmentSetting.State; Value = $assignmentSetting.Value; SourceText = $null; Line = $assignmentSetting.Line }
}

function Get-TextSha256 {
    # The SHA-256 of a text's UTF-8 bytes, as 64 lower-case hex digits, the form the
    # release table stores a secret's shipped value in.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
    $hashAlgorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $hashAlgorithm.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
    }
    finally {
        $hashAlgorithm.Dispose()
    }
    return ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
}

function ConvertTo-DataFileLiteral {
    # A value as the override file writes it: a string in single quotes, a whole number,
    # $true, $false, or a list of those. $null for anything else.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][object]$Value
    )
    if ($null -eq $Value -or $Value -is [System.Collections.IDictionary]) { return $null }
    if ($Value -is [System.Management.Automation.SwitchParameter]) { $Value = $Value.IsPresent }
    if ($Value -is [bool]) {
        if ($Value) { return '$true' }
        return '$false'
    }
    if ($Value -is [string]) { return "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Value) + "'" }
    if ($Value -is [System.Array]) {
        $itemTexts = foreach ($item in $Value) {
            if ($item -is [System.Array]) { return $null }
            $itemText = ConvertTo-DataFileLiteral -Value $item
            if ($null -eq $itemText) { return $null }
            $itemText
        }
        return '@(' + (@($itemTexts) -join ', ') + ')'
    }
    foreach ($integerType in @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])) {
        if ($Value -is $integerType) { return [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture) }
    }
    return $null
}

function Get-ShippedCandidate {
    # The shipped value of one key in each candidate release, from the release table's
    # entries or a parsed clean copy. Kind is Constant, Expression, NoDefault or Sha256.
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)][object[]]$Candidate,
        [Parameter(Mandatory = $true)][string]$Key
    )
    $shippedValues = foreach ($candidateRelease in $Candidate) {
        $settingTable = $candidateRelease.Settings
        if (-not $settingTable.ContainsKey($Key)) { continue }
        $settingValue = $settingTable[$Key]
        foreach ($kind in @('Constant', 'Expression', 'NoDefault', 'Sha256')) {
            if ($settingValue.ContainsKey($kind)) {
                [pscustomobject]@{ Release = $candidateRelease.Name; Kind = $kind; Value = $settingValue[$kind] }
            }
        }
    }
    return , [object[]]@($shippedValues)
}

function Test-ShippedMatch {
    # Whether an old setting equals any of the shipped candidates.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][object]$OldSetting,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Shipped
    )
    foreach ($shippedValue in $Shipped) {
        switch ($OldSetting.State) {
            'Dynamic' {
                if ($shippedValue.Kind -ceq 'Expression' -and $null -ne $OldSetting.SourceText -and [string]::Equals([string]$shippedValue.Value, [string]$OldSetting.SourceText, [System.StringComparison]::Ordinal)) { return $true }
            }
            'NoDefault' {
                if ($shippedValue.Kind -ceq 'NoDefault') { return $true }
            }
            'Value' {
                if ($shippedValue.Kind -ceq 'Constant' -and (Test-OverrideValueEqual -First $OldSetting.Value -Second $shippedValue.Value)) { return $true }
                if ($shippedValue.Kind -ceq 'Sha256' -and (Get-TextSha256 -Text ([System.Convert]::ToString($OldSetting.Value, [System.Globalization.CultureInfo]::InvariantCulture))) -ceq [string]$shippedValue.Value) { return $true }
            }
        }
    }
    return $false
}

function Get-ShippedDisplayText {
    # The shipped candidates as a log shows them. A secret is <set>, and an expression
    # is named, never quoted.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Shipped,
        [switch]$Secret
    )
    if ($Shipped.Count -eq 0) { return 'none' }
    $texts = foreach ($shippedValue in $Shipped) {
        switch ($shippedValue.Kind) {
            'Constant' { ConvertTo-OverrideDisplayText -Value $shippedValue.Value -Secret:$Secret }
            'Sha256' { '<set>' }
            'NoDefault' { 'no default' }
            'Expression' { 'an expression' }
        }
    }
    return (@($texts | Sort-Object -Unique -CaseSensitive) -join ' or ')
}

#endregion Functions

#region Variables

$scriptName = 'Export-OverrideFile.ps1'
$scriptVersion = '2.2.0'
$runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $LogPath) { $LogPath = Join-Path -Path $PSScriptRoot -ChildPath 'logs' }
$LogPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogPath)
$logFilePath = Join-Path -Path $LogPath -ChildPath ('Export-OverrideFile_{0}.csv' -f $runStamp)
$catalogPath = Join-Path -Path $PSScriptRoot -ChildPath 'include\override-catalog.psd1'
$tablePath = Join-Path -Path $PSScriptRoot -ChildPath 'include\release-values.psd1'
$shippingScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'build-lab.ps1'
$overridesFolderPath = Join-Path -Path $PSScriptRoot -ChildPath 'overrides'
$activeOverridePath = Join-Path -Path $overridesFolderPath -ChildPath 'overrides.psd1'
$relativePathKeys = @('VmBuilderScriptPath', 'AdDomainSourcePath')
$runOutcome = 'failed'
$exitCode = 1

#endregion Variables

#region Main

if (Test-Path -LiteralPath $logFilePath) {
    throw ('The run log {0} already exists, because another run started in the same second. Start this run again.' -f $logFilePath)
}
$logContext = Initialize-ExportLogContext -ScriptName $scriptName -CsvLogPath $logFilePath

try {
    Write-ExportLog -Context $logContext -Level INFO -Message ('Run start | {0} {1} | source {2}, reference {3}, KeepPreviousDefaults {4}, WhatIf {5}' -f $scriptName, $scriptVersion, $SourcePath, $(if ($ReferencePath) { $ReferencePath } else { 'none' }), [bool]$KeepPreviousDefaults, [bool]$WhatIfPreference)

    #region Read the old script, the catalog and the shipped values
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
        throw ('-SourcePath {0} is not a folder. Pass the folder of your older copy of build-lab.' -f $SourcePath)
    }
    $oldScriptPath = Find-BuildLabScript -FolderPath $SourcePath
    if ($null -eq $oldScriptPath) {
        throw ('-SourcePath {0} holds no build-lab.ps1. Pass the folder of your older copy of build-lab.' -f $SourcePath)
    }
    foreach ($requiredPath in @($catalogPath, $shippingScriptPath)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw ('{0} is missing. Put it back from this release of build-lab.' -f $requiredPath) }
    }
    $catalog = Read-OverrideCatalog -CatalogPath $catalogPath
    if ($catalog.Error) { throw ('The catalog {0} failed its check: {1}' -f $catalogPath, ($catalog.Error -replace '\r?\n', ' ')) }

    $oldSettings = Read-ScriptSetting -Path $oldScriptPath
    if ($oldSettings.Error) { throw ('{0} Nothing was written.' -f $oldSettings.Error) }
    foreach ($readWarning in @($oldSettings.Warnings)) { Write-ExportLog -Context $logContext -Level WARN -Message $readWarning }
    $oldFileName = Split-Path -Path $oldScriptPath -Leaf
    $oldHeaderVersion = if ($oldSettings.Version) { [string]$oldSettings.Version } else { 'none' }

    $candidates = [System.Collections.Generic.List[object]]::new()
    if ($ReferencePath) {
        if (-not (Test-Path -LiteralPath $ReferencePath -PathType Container)) { throw ('-ReferencePath {0} is not a folder.' -f $ReferencePath) }
        $referenceScriptPath = Find-BuildLabScript -FolderPath $ReferencePath
        if ($null -eq $referenceScriptPath) { throw ('-ReferencePath {0} holds no build-lab.ps1.' -f $ReferencePath) }
        $referenceSettings = Read-ScriptSetting -Path $referenceScriptPath
        if ($referenceSettings.Error) { throw ('{0} Nothing was written.' -f $referenceSettings.Error) }
        $referenceTable = @{}
        foreach ($catalogKey in @($catalog.Settings.get_Keys())) {
            $referenceSetting = Get-OldSetting -ScriptSetting $referenceSettings -CatalogEntry $catalog.Settings[$catalogKey]
            switch ($referenceSetting.State) {
                'Value' {
                    if ($catalog.Settings[$catalogKey].Secret) { $referenceTable[$catalogKey] = @{ Sha256 = (Get-TextSha256 -Text ([System.Convert]::ToString($referenceSetting.Value, [System.Globalization.CultureInfo]::InvariantCulture))) } }
                    else { $referenceTable[$catalogKey] = @{ Constant = $referenceSetting.Value } }
                }
                'NoDefault' { $referenceTable[$catalogKey] = @{ NoDefault = $true } }
                'Dynamic' { if ($null -ne $referenceSetting.SourceText) { $referenceTable[$catalogKey] = @{ Expression = $referenceSetting.SourceText } } }
            }
        }
        $candidates.Add([pscustomobject]@{ Name = ('the clean copy in {0}' -f $ReferencePath); Settings = $referenceTable })
        Write-ExportLog -Context $logContext -Level INFO -Message ('Shipped values | read from the clean copy {0}, header {1}' -f $referenceScriptPath, $(if ($referenceSettings.Version) { $referenceSettings.Version } else { 'none' }))
    }
    else {
        if (-not (Test-Path -LiteralPath $tablePath -PathType Leaf)) { throw ('{0} is missing, so the shipped values are unknown. Put it back from this release, or pass -ReferencePath with an unedited copy of your old release.' -f $tablePath) }
        $releaseTable = Import-PowerShellDataFile -LiteralPath $tablePath
        $releaseEntries = $releaseTable['Releases']
        $allNames = @($releaseEntries.get_Keys() | Sort-Object { [version]$_ })
        $matchingNames = @($allNames | Where-Object { [string]$releaseEntries[$_]['HeaderVersion'] -ceq $oldHeaderVersion })
        if ($matchingNames.Count -eq 0) {
            $matchingNames = $allNames
            Write-ExportLog -Context $logContext -Level INFO -Message ('Release | the old header version {0} matches no release in the table, so each of {1} is a candidate, and a value equal to any of their shipped values counts as unchanged' -f $oldHeaderVersion, ($allNames -join ', '))
        }
        elseif ($matchingNames.Count -gt 1) {
            Write-ExportLog -Context $logContext -Level INFO -Message ('Release | the old header version {0} is shared by releases {1}, so a value equal to any of their shipped values counts as unchanged' -f $oldHeaderVersion, ($matchingNames -join ', '))
        }
        else {
            Write-ExportLog -Context $logContext -Level INFO -Message ('Release | the old header version {0} is release {1}' -f $oldHeaderVersion, $matchingNames[0])
        }
        foreach ($matchingName in $matchingNames) { $candidates.Add([pscustomobject]@{ Name = [string]$matchingName; Settings = $releaseEntries[$matchingName]['Settings'] }) }
    }
    $candidateNames = (@($candidates | ForEach-Object { $_.Name }) -join ', ')
    #endregion

    #region Compare each setting
    $writtenLines = [System.Collections.Generic.List[string]]::new()
    $summary = @{ Written = [System.Collections.Generic.List[string]]::new(); CommentedOut = [System.Collections.Generic.List[string]]::new(); Unchanged = [System.Collections.Generic.List[string]]::new(); ChangedDefault = [System.Collections.Generic.List[string]]::new(); ByHand = [System.Collections.Generic.List[string]]::new() }
    $keyNames = [string[]]@($catalog.Settings.get_Keys())
    [System.Array]::Sort($keyNames, [System.StringComparer]::Ordinal)
    foreach ($keyName in $keyNames) {
        $entry = $catalog.Settings[$keyName]
        $oldSetting = Get-OldSetting -ScriptSetting $oldSettings -CatalogEntry $entry
        $oldText = if ($oldSetting.State -eq 'Value') { ConvertTo-OverrideDisplayText -Value $oldSetting.Value -Secret:$entry.Secret } else { $oldSetting.State }
        $shipped = Get-ShippedCandidate -Candidate $candidates.ToArray() -Key $keyName
        $comparedWith = $candidateNames
        if ($oldSetting.State -eq 'NotFound') {
            Write-ExportLog -Context $logContext -Level INFO -Message ('Setting {0} | old none | shipped {1} | not written | the old script does not have this setting' -f $keyName, (Get-ShippedDisplayText -Shipped $shipped -Secret:$entry.Secret))
            continue
        }
        if ($oldSetting.State -eq 'NoDefault') {
            $summary.Unchanged.Add($keyName)
            Write-ExportLog -Context $logContext -Level INFO -Message ('Setting {0} | old NoDefault | shipped {1} | not written | the old script gives no default, so there is nothing to carry over' -f $keyName, (Get-ShippedDisplayText -Shipped $shipped -Secret:$entry.Secret))
            continue
        }
        $shippedText = Get-ShippedDisplayText -Shipped $shipped -Secret:$entry.Secret
        $rowStart = 'Setting {0} | old {1} | shipped {2}' -f $keyName, $oldText, $shippedText

        if ($shipped.Count -eq 0) {
            $summary.ByHand.Add($keyName)
            Write-ExportLog -Context $logContext -Level WARN -Message ('{0} | not written | no shipped value is known for it, so whether it was changed can''t be told. Set it by hand if you changed it' -f $rowStart)
            continue
        }
        $isUnchanged = Test-ShippedMatch -OldSetting $oldSetting -Shipped $shipped
        if ($oldSetting.State -eq 'Dynamic') {
            if ($isUnchanged) {
                $summary.Unchanged.Add($keyName)
                Write-ExportLog -Context $logContext -Level INFO -Message ('{0} | not written | unchanged from {1}' -f $rowStart, $comparedWith)
            }
            else {
                $summary.ByHand.Add($keyName)
                Write-ExportLog -Context $logContext -Level WARN -Message ('{0} | not written | {1} line {2} computes the value at run time, which can''t be read without running it. Set it by hand' -f $rowStart, $oldFileName, $oldSetting.Line)
            }
            continue
        }

        $writeReason = $null
        if ($isUnchanged) {
            $isChangedDefault = $entry.HasShipped -and -not $entry.Secret -and -not (Test-OverrideValueEqual -First $oldSetting.Value -Second $entry.Shipped)
            if (-not $isChangedDefault) {
                $summary.Unchanged.Add($keyName)
                Write-ExportLog -Context $logContext -Level INFO -Message ('{0} | not written | unchanged from {1}' -f $rowStart, $comparedWith)
                continue
            }
            $changedText = '{0} (yours {1}, now {2})' -f $keyName, $oldText, (ConvertTo-OverrideDisplayText -Value $entry.Shipped)
            if (-not $KeepPreviousDefaults) {
                $summary.ChangedDefault.Add($changedText)
                Write-ExportLog -Context $logContext -Level INFO -Message ('{0} | not written | the shipped default changed since your release, and you never edited it. -KeepPreviousDefaults keeps the old one' -f $rowStart)
                continue
            }
            $writeReason = 'the previous default, kept with -KeepPreviousDefaults'
        }
        else {
            $writeReason = 'changed from the shipped value'
        }

        # Check the value as the new release will.
        $refusal = $null
        $valueToWrite = $oldSetting.Value
        if ($null -ne $entry.Rule) {
            $ruleResult = Test-OverrideRuleValue -Rule $entry.Rule -Value $oldSetting.Value
            if ($ruleResult.Valid) { $valueToWrite = $ruleResult.Value }
            else { $refusal = 'it must be {0}' -f (Get-OverrideRuleText -Rule $entry.Rule).TrimEnd('.') }
        }
        if (-not $refusal -and $entry.Target -ceq 'Parameter') {
            $parameterCheck = Test-ParameterValueByAst -ScriptPath $shippingScriptPath -ParameterName $entry.Name -Value $valueToWrite
            if ($parameterCheck.State -eq 'Refused') { $refusal = 'this release refuses it, {0}' -f $parameterCheck.Reason.TrimEnd('.') }
            elseif ($parameterCheck.State -ne 'Valid') { $refusal = 'it can''t be checked, {0}' -f $parameterCheck.Reason.TrimEnd('.') }
        }
        $literalText = ConvertTo-DataFileLiteral -Value $valueToWrite
        if (-not $refusal -and $null -eq $literalText) { $refusal = 'the value isn''t a string, a number, $true, $false or a list of those' }

        $sourceComment = '    # From {0} line {1}, compared with {2}: {3}.' -f $oldFileName, $oldSetting.Line, $comparedWith, $writeReason
        if ($refusal) {
            $summary.CommentedOut.Add($keyName)
            $writtenLines.Add($sourceComment)
            $writtenLines.Add(('    # Not active, because {0}. Correct it, then remove the # below.' -f $refusal))
            if ($null -ne $literalText -and $literalText -notmatch '[\r\n]') { $writtenLines.Add(('    # {0} = {1}' -f $keyName, $literalText)) }
            else { $writtenLines.Add(('    # {0} = (the value spans lines or can''t be written, so it isn''t shown)' -f $keyName)) }
            Write-ExportLog -Context $logContext -Level WARN -Message ('{0} | written commented out | {1}' -f $rowStart, $refusal)
            continue
        }
        $summary.Written.Add($keyName)
        $writtenLines.Add($sourceComment)
        $writtenLines.Add(('    {0} = {1}' -f $keyName, $literalText))
        Write-ExportLog -Context $logContext -Level INFO -Message ('{0} | written | {1}' -f $rowStart, $writeReason)
        if ($relativePathKeys -ccontains $keyName -and $valueToWrite -is [string]) {
            $pathIsRooted = $true
            try { $pathIsRooted = [System.IO.Path]::IsPathRooted($valueToWrite) } catch { $pathIsRooted = $true }
            if (-not $pathIsRooted) {
                Write-ExportLog -Context $logContext -Level WARN -Message ('Setting {0} | the old relative path resolved from the folder build-lab was started in. In the override file it resolves from build-lab''s folder. Check it' -f $keyName)
            }
        }
    }
    #endregion

    #region Write the override file
    $targetPath = $null
    if ($writtenLines.Count -eq 0) {
        Write-ExportLog -Context $logContext -Level INFO -Message 'Override file | nothing to write, because every setting the old script holds is unchanged or can''t be carried over'
    }
    else {
        $fileLines = [System.Collections.Generic.List[string]]::new()
        $fileLines.Add(('# Override file for build-lab, written by {0} {1}.' -f $scriptName, $scriptVersion))
        $fileLines.Add(('# From {0}, header version {1}. OVERRIDE.md lists every key.' -f $oldScriptPath, $oldHeaderVersion))
        $fileLines.Add('@{')
        foreach ($writtenLine in $writtenLines) { $fileLines.Add($writtenLine) }
        $fileLines.Add('}')
        $fileText = ($fileLines -join "`r`n") + "`r`n"

        $targetPath = $activeOverridePath
        if (Test-Path -LiteralPath $activeOverridePath) {
            $targetPath = Join-Path -Path $overridesFolderPath -ChildPath ('migrated-{0}\overrides.psd1' -f $runStamp)
            Write-ExportLog -Context $logContext -Level WARN -Message ('Override file | {0} already exists and is left as it is. The new file goes to {1}, which no script reads. Merge the two by hand' -f $activeOverridePath, $targetPath)
        }
        if ($PSCmdlet.ShouldProcess($targetPath, 'Write the migrated override file')) {
            $null = New-Item -ItemType Directory -Path (Split-Path -Path $targetPath -Parent) -Force
            [System.IO.File]::WriteAllText($targetPath, $fileText, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true))
            Write-ExportLog -Context $logContext -Level SUCCESS -Message ('Override file | written to {0}, UTF-8 with a BOM' -f $targetPath)

            # Read it back with the reader the script uses. A failure is this script's
            # own defect.
            $readBack = Get-OverrideFile -Path $targetPath -CatalogPath $catalogPath
            if ($readBack.Error) { throw ('The written file {0} fails the reader''s check, which is a defect in this script. Report it. The reader says: {1}' -f $targetPath, ($readBack.Error -replace '\r?\n', ' ')) }
            foreach ($readBackKey in @($readBack.Values.get_Keys())) {
                $readBackEntry = $catalog.Settings[$readBackKey]
                if ($readBackEntry.Target -ceq 'Parameter') {
                    $readBackCheck = Test-ParameterValueByAst -ScriptPath $shippingScriptPath -ParameterName $readBackEntry.Name -Value $readBack.Values[$readBackKey]
                    if ($readBackCheck.State -ne 'Valid') { throw ('The written file {0} holds a {1} the script would refuse, which is a defect in this script. Report it.' -f $targetPath, $readBackKey) }
                }
            }
            Write-ExportLog -Context $logContext -Level SUCCESS -Message ('Override file | read back with the reader, {0} settings' -f $readBack.Values.get_Count())
        }
        else {
            Write-ExportLog -Context $logContext -Level INFO -Message ('Override file | not written, because of -WhatIf or -Confirm. It would go to {0}' -f $targetPath)
            $targetPath = $null
        }
    }
    #endregion

    #region Summary
    $listText = { param ($Items) if ($Items.Count -eq 0) { 'none' } else { $Items -join ', ' } }
    Write-ExportLog -Context $logContext -Level INFO -Message ('Summary | written: {0}' -f (& $listText $summary.Written))
    Write-ExportLog -Context $logContext -Level INFO -Message ('Summary | written commented out, to correct by hand: {0}' -f (& $listText $summary.CommentedOut))
    Write-ExportLog -Context $logContext -Level INFO -Message ('Summary | unchanged: {0} settings' -f $summary.Unchanged.Count)
    Write-ExportLog -Context $logContext -Level INFO -Message ('Summary | changed defaults not written (-KeepPreviousDefaults writes them): {0}' -f (& $listText $summary.ChangedDefault))
    Write-ExportLog -Context $logContext -Level INFO -Message ('Summary | not written, set by hand if you changed them: {0}' -f (& $listText $summary.ByHand))
    if ($null -ne $targetPath) {
        Write-ExportLog -Context $logContext -Level INFO -Message ('Summary | the file is {0}' -f $targetPath)
    }
    Write-ExportLog -Context $logContext -Level INFO -Message ('Next | if you edited the script in {0}, put back the shipped one: git checkout -- {1} in a clone, or a fresh copy of this release' -f $SourcePath, $oldFileName)
    #endregion

    $runOutcome = 'done'
    $exitCode = 0
}
catch {
    Write-ExportLog -Context $logContext -Level FATAL -Message ('Run stopped | {0}' -f $_.Exception.Message)
}
finally {
    Write-ExportLog -Context $logContext -Level INFO -Message ('Run end | {0}; log {1}' -f $runOutcome, $logFilePath)
}
exit $exitCode

#endregion Main
