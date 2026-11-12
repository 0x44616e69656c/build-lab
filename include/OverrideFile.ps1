<#
.SYNOPSIS
    Reads a project's override file against its catalog, parses scripts without
    running them, and generates the project's OVERRIDE.md from the catalog.
.DESCRIPTION
    Dot-sourced by each project that supports an override file,
    overrides\overrides.psd1. It only defines functions. Loading it writes nothing to the
    output, the console or the disk.

    Public functions:
      - Get-OverrideFile                 : reads and checks the override file against
                                           the project's catalog
      - Get-OverrideParameterAssignment  : lists the parameter assignments a script
                                           should make, and assigns nothing
      - Get-OverrideChangedDefault       : one INFO line per setting whose shipped
                                           default changed since the last release
      - Read-ScriptSetting               : parses a script, never runs it, and returns
                                           its constant settings
      - Get-ParameterRule                : reads each parameter's type and validation
                                           attributes from a script's syntax tree
      - Test-ParameterValueByAst         : checks a value against a parameter's
                                           declared type and validation attributes,
                                           read through Get-ParameterRule
      - Get-OverrideDocumentationField   : the catalog fields that feed OVERRIDE.md
                                           and nothing that runs
      - Get-OverrideProfileKeyName       : reads the build profile's key names from a
                                           script's syntax tree, for the generator
      - ConvertTo-OverrideDocument       : returns the whole text of OVERRIDE.md,
                                           generated from the catalog
      - ConvertTo-ReleaseValueEntry      : returns one release's entry in
                                           include\release-values.psd1, and the whole
                                           file with that entry in place
      - Get-OverrideCsvHash              : the SHA-256 of a CSV's text, after the line
                                           ending differences a clone can bring
    No deploying run calls the last five. They serve the offline tests, the migration
    and the writing of OVERRIDE.md and the release table during development.

    This file is before 1.0. Its functions and the catalog's layout may still change
    between minor versions, and it reaches 1.0.0 once it has been proven in use.

    No public function throws. Each sets its error preference locally and reports a
    problem in its returned object. The file is dot-sourced, so it sets no strict mode
    or error preference of its own, which would change its caller's.

    No returned line ever holds an exception message, a parse error message or the
    override file's source text, because those can quote a secret value. A key name
    may appear in a line. A value appears only in the summary, in a refusal by a
    catalog rule and in a command-line INFO line, and a secret value is always
    written <set>.

    The catalog is a PowerShell data file, include\override-catalog.psd1, holding one
    hashtable:

      @{
          Project  = 'new-AdDomain'
          Settings = @{                           # one entry per key
              WorkstationPrefix = @{
                  Target  = 'Variable'            # Variable, Parameter or Constant
                  Name    = 'workstationPrefix'   # the variable or parameter, no $
                  Shipped = 'WK'                  # optional; not read by the reader
                  Secret  = $false                # optional; $true masks the value
                  Rule    = @{ Type = 'String'; Pattern = '\A[A-Za-z0-9]{1,6}\z'
                               Description = '1 to 6 letters or digits' }
                  Summary       = 'The prefix of workstation computer names'
                  ShippedReason = 'Short enough to leave room for the number'
              }
          }
          Retired  = @{                           # optional
              OldName = @{ Version = '2.2.0'; RenamedTo = 'NewName' }
              Gone    = @{ Version = '2.2.0' }    # no RenamedTo: removed
          }
          Siblings = @{                           # optional
              'New-VMwareWorkstationVM' = @('Edition', 'TimeZone')
          }
          Document = @{                           # optional for the reader
              NotCovered      = @( @{ Name = 'deployRoot'; Reason = '...' } )
              CsvReplacements = @( @{ File = 'first.csv'; Holds = '...'; Headers = @('FirstName') } )
              Security        = @('...')
              BuildProfile    = @{ Script = 'include\BuildProfile.ps1' }
          }
      }

    The documentation-only fields, which Get-OverrideDocumentationField lists, feed
    OVERRIDE.md and nothing that runs: Summary, ShippedText (the default in words, and
    the only default shown for a secret key), ShippedReason, OverrideNote and
    ValuesNote on a key, and Document at the top. The reader checks only that each is
    a string, or for Document a table of its four fields, and never requires one.
    ConvertTo-OverrideDocument requires what OVERRIDE.md needs, as its help says.

    A Variable or Constant key needs a Rule. A Parameter key may have one, and without
    one the parameter's own attributes check the value when the script assigns it. Rule
    types and their optional fields:
      - String   : MinLength, MaxLength, Pattern (case-sensitive), Allowed (matched
                   ignoring case, returned as the catalog spells them)
      - Integer  : Minimum, Maximum, Allowed. A whole number or a string of digits
      - Boolean  : $true or $false only
      - List     : ItemRule (a String or Integer rule), MinCount (default 1),
                   MaxCount. A single value counts as a list of one
      - External : not checked here, because the reading script checks it
    Every rule may carry a Description, the words used in a refusal. A field this file
    doesn't know makes the catalog invalid, so a misspelled Secret can't hide a secret.
.EXAMPLE
    . "$PSScriptRoot\include\OverrideFile.ps1"
    $overrideFile = Get-OverrideFile -Path "$PSScriptRoot\overrides\overrides.psd1" `
        -CatalogPath "$PSScriptRoot\include\override-catalog.psd1"
.EXAMPLE
    $assignmentResult = Get-OverrideParameterAssignment -OverrideFile $overrideFile `
        -CatalogPath $catalogPath -BoundParameters $PSBoundParameters
    foreach ($assignment in $assignmentResult.Assignments) {
        try { Set-Variable -Name $assignment.ParameterName -Value $assignment.Value -ErrorAction Stop }
        catch { $refusedKeys.Add($assignment.Key) }
    }
.OUTPUTS
    None when dot-sourced. Each public function returns one PSCustomObject, described in
    its own help.
.NOTES
    Version:           0.3.2
    Author:            Daniel Owen
    Release Date:      2026-11-06
    Requirements:      Windows PowerShell 5.1. No other sharedModules file.
    Target Set Source: N/A
    Event Log Source:  N/A
    Setup:             N/A
#>


#region Value Helpers
function Test-OverrideEmptyValue {
    # Empty means $null, a string of only whitespace, or an empty list or table.
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [AllowNull()]
        [object]$Value
    )
    if ($null -eq $Value) { return $true }
    if ($Value -is [string]) { return [string]::IsNullOrWhiteSpace($Value) }
    if ($Value -is [System.Collections.IDictionary]) { return ($Value.get_Count() -eq 0) }
    if ($Value -is [System.Array]) { return ($Value.Count -eq 0) }
    return $false
}

function ConvertTo-OverrideDisplayText {
    # The text a value takes in a line. A secret is <set>. A list is @(a, b), a table is
    # @{...} with its contents left out, and CR, LF and TAB become spaces so a value
    # can't split a log line.
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [AllowNull()]
        [object]$Value,

        [switch]$Secret
    )
    if ($Secret) { return '<set>' }
    if ($null -eq $Value) { return '$null' }
    if ($Value -is [securestring]) { return '<set>' }
    if ($Value -is [System.Management.Automation.SwitchParameter]) { $Value = $Value.IsPresent }
    if ($Value -is [bool]) {
        if ($Value) { return '$true' }
        return '$false'
    }
    if ($Value -is [System.Collections.IDictionary]) { return '@{...}' }
    if ($Value -is [System.Array]) {
        $itemTexts = foreach ($item in $Value) { ConvertTo-OverrideDisplayText -Value $item }
        return '@(' + (@($itemTexts) -join ', ') + ')'
    }
    $text = [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture)
    return ($text -replace '[\r\n\t]', ' ')
}

function ConvertTo-OverrideInteger {
    # A whole number in Int32 range, from an integer type or a string of digits, read
    # with [int]::TryParse and the invariant culture. Returns Valid and Value.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [AllowNull()]
        [object]$Value
    )
    $result = [pscustomobject]@{ Valid = $false; Value = $null }
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [System.Array] -or $Value -is [System.Collections.IDictionary]) {
        return $result
    }
    $isIntegerType = $false
    foreach ($integerType in @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])) {
        if ($Value -is $integerType) { $isIntegerType = $true }
    }
    if (-not $isIntegerType -and -not ($Value -is [string])) { return $result }
    $text   = [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture)
    $number = 0
    if ([int]::TryParse($text, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        $result.Valid = $true
        $result.Value = $number
    }
    return $result
}

function Find-OverrideDictionaryKey {
    # The key a dictionary holds for a name, an exact match first and then one that
    # differs only in case, or $null. It works on any IDictionary a caller passes: a
    # hashtable, an ordered dictionary, a generic Dictionary, or $PSBoundParameters.
    # Their Contains and ContainsKey methods differ by type, so it uses only get_Keys(),
    # which all of them have. Index the dictionary with the key it returns.
    [CmdletBinding()]
    [OutputType([object])]
    param (
        [AllowNull()]
        [System.Collections.IDictionary]$Dictionary,

        [AllowNull()]
        [object]$Key
    )
    if ($null -eq $Dictionary -or $null -eq $Key) { return $null }
    $caseMatch = $null
    foreach ($storedKey in @($Dictionary.get_Keys())) {
        if ($storedKey -ceq $Key) { return $storedKey }
        if ($null -eq $caseMatch -and $storedKey -eq $Key) { $caseMatch = $storedKey }
    }
    return $caseMatch
}

function Test-OverrideValueEqual {
    # Compares two values item by item. Scalars compare by their invariant text,
    # ordinally, so 5 and '5' are equal and 'LAB' and 'lab' are not.
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [AllowNull()]
        [object]$First,

        [AllowNull()]
        [object]$Second
    )
    if ($First -is [System.Management.Automation.SwitchParameter]) { $First = $First.IsPresent }
    if ($Second -is [System.Management.Automation.SwitchParameter]) { $Second = $Second.IsPresent }
    if ($null -eq $First -or $null -eq $Second) { return ($null -eq $First -and $null -eq $Second) }
    $firstIsList  = $First -is [System.Array]
    $secondIsList = $Second -is [System.Array]
    if ($firstIsList -or $secondIsList) {
        if (-not ($firstIsList -and $secondIsList)) { return $false }
        if ($First.Count -ne $Second.Count) { return $false }
        for ($itemIndex = 0; $itemIndex -lt $First.Count; $itemIndex++) {
            if (-not (Test-OverrideValueEqual -First $First[$itemIndex] -Second $Second[$itemIndex])) { return $false }
        }
        return $true
    }
    $firstIsTable  = $First -is [System.Collections.IDictionary]
    $secondIsTable = $Second -is [System.Collections.IDictionary]
    if ($firstIsTable -or $secondIsTable) {
        if (-not ($firstIsTable -and $secondIsTable)) { return $false }
        if ($First.get_Count() -ne $Second.get_Count()) { return $false }
        foreach ($tableKey in @($First.get_Keys())) {
            $secondKey = Find-OverrideDictionaryKey -Dictionary $Second -Key $tableKey
            if ($null -eq $secondKey) { return $false }
            if (-not (Test-OverrideValueEqual -First $First[$tableKey] -Second $Second[$secondKey])) { return $false }
        }
        return $true
    }
    $invariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
    return [string]::Equals([System.Convert]::ToString($First, $invariantCulture), [System.Convert]::ToString($Second, $invariantCulture), [System.StringComparison]::Ordinal)
}
#endregion

#region Catalog Rules
function Get-OverrideRuleText {
    # The words after "It must be" in a refusal: the rule's Description when it has one.
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [hashtable]$Rule
    )
    if ($Rule.ContainsKey('Description') -and -not [string]::IsNullOrWhiteSpace([string]$Rule['Description'])) {
        return [string]$Rule['Description']
    }
    switch ([string]$Rule['Type']) {
        'Boolean' { return '$true or $false' }
        'Integer' {
            if ($Rule.ContainsKey('Allowed')) { return 'one of ' + (@($Rule['Allowed']) -join ', ') }
            $hasMinimum = $Rule.ContainsKey('Minimum')
            $hasMaximum = $Rule.ContainsKey('Maximum')
            if ($hasMinimum -and $hasMaximum) { return "a whole number from $($Rule['Minimum']) to $($Rule['Maximum'])" }
            if ($hasMinimum) { return "a whole number of $($Rule['Minimum']) or more" }
            if ($hasMaximum) { return "a whole number of $($Rule['Maximum']) or less" }
            return 'a whole number'
        }
        'String' {
            if ($Rule.ContainsKey('Allowed')) { return 'one of ' + (@($Rule['Allowed']) -join ', ') }
            $ruleText    = 'text'
            $hasMinimum  = $Rule.ContainsKey('MinLength')
            $hasMaximum  = $Rule.ContainsKey('MaxLength')
            if ($hasMinimum -and $hasMaximum) { $ruleText += " of $($Rule['MinLength']) to $($Rule['MaxLength']) characters" }
            elseif ($hasMinimum) { $ruleText += " of at least $($Rule['MinLength']) characters" }
            elseif ($hasMaximum) { $ruleText += " of at most $($Rule['MaxLength']) characters" }
            if ($Rule.ContainsKey('Pattern')) { $ruleText += " matching the pattern '$($Rule['Pattern'])'" }
            return $ruleText
        }
        'List' {
            $minimumCount = 1
            if ($Rule.ContainsKey('MinCount')) { $minimumCount = [int]$Rule['MinCount'] }
            $itemText = Get-OverrideRuleText -Rule $Rule['ItemRule']
            if ($Rule.ContainsKey('MaxCount')) { return "a list of $minimumCount to $($Rule['MaxCount']) items, each $itemText" }
            return "a list of $minimumCount or more items, each $itemText"
        }
        default { return 'a value the reading script accepts' }
    }
}

function Test-OverrideRuleValue {
    # Checks one non-empty value against a catalog rule. Returns Valid and Value, the
    # value in canonical form.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [hashtable]$Rule,

        [AllowNull()]
        [object]$Value
    )
    $result   = [pscustomobject]@{ Valid = $false; Value = $null }
    $isSingle = -not ($Value -is [System.Array] -or $Value -is [System.Collections.IDictionary] -or $null -eq $Value)

    switch ([string]$Rule['Type']) {
        'External' {
            $result.Valid = $true
            $result.Value = $Value
        }
        'Boolean' {
            if ($Value -is [bool]) {
                $result.Valid = $true
                $result.Value = $Value
            }
        }
        'Integer' {
            $integerResult = ConvertTo-OverrideInteger -Value $Value
            if (-not $integerResult.Valid) { break }
            $number = $integerResult.Value
            if ($Rule.ContainsKey('Minimum') -and $number -lt [int]$Rule['Minimum']) { break }
            if ($Rule.ContainsKey('Maximum') -and $number -gt [int]$Rule['Maximum']) { break }
            if ($Rule.ContainsKey('Allowed') -and -not (@($Rule['Allowed']) | Where-Object { [int]$_ -eq $number })) { break }
            $result.Valid = $true
            $result.Value = $number
        }
        'String' {
            if (-not ($isSingle -and $Value -is [string])) { break }
            $text = [string]$Value
            if ($Rule.ContainsKey('MinLength') -and $text.Length -lt [int]$Rule['MinLength']) { break }
            if ($Rule.ContainsKey('MaxLength') -and $text.Length -gt [int]$Rule['MaxLength']) { break }
            if ($Rule.ContainsKey('Pattern') -and -not [regex]::IsMatch($text, [string]$Rule['Pattern'])) { break }
            if ($Rule.ContainsKey('Allowed')) {
                $canonicalText = @($Rule['Allowed']) | Where-Object { [string]::Equals([string]$_, $text, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
                if ($null -eq $canonicalText) { break }
                $text = [string]$canonicalText
            }
            $result.Valid = $true
            $result.Value = $text
        }
        'List' {
            if ($Value -is [System.Collections.IDictionary]) { break }
            $items        = @($Value)
            $minimumCount = 1
            if ($Rule.ContainsKey('MinCount')) { $minimumCount = [int]$Rule['MinCount'] }
            if ($items.Count -lt $minimumCount) { break }
            if ($Rule.ContainsKey('MaxCount') -and $items.Count -gt [int]$Rule['MaxCount']) { break }
            $canonicalItems = [System.Collections.Generic.List[object]]::new()
            $allItemsValid  = $true
            foreach ($item in $items) {
                $itemResult = Test-OverrideRuleValue -Rule $Rule['ItemRule'] -Value $item
                if (-not $itemResult.Valid) { $allItemsValid = $false; break }
                $canonicalItems.Add($itemResult.Value)
            }
            if (-not $allItemsValid) { break }
            $result.Valid = $true
            $result.Value = [object[]]$canonicalItems.ToArray()
        }
    }
    return $result
}

function Test-OverrideCatalogRule {
    # Returns $null when a catalog rule is well formed, otherwise the problem.
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [AllowNull()]
        [object]$Rule,

        [Parameter(Mandatory)]
        [string]$Label,

        [switch]$IsListItem
    )
    if (-not ($Rule -is [hashtable])) { return "$Label isn't a table." }
    $ruleType = $Rule['Type']
    $allowedFields = @{
        String   = @('Type', 'Description', 'MinLength', 'MaxLength', 'Pattern', 'Allowed')
        Integer  = @('Type', 'Description', 'Minimum', 'Maximum', 'Allowed')
        Boolean  = @('Type', 'Description')
        List     = @('Type', 'Description', 'ItemRule', 'MinCount', 'MaxCount')
        External = @('Type', 'Description')
    }
    if (-not ($ruleType -is [string]) -or -not $allowedFields.ContainsKey($ruleType) -or -not ($allowedFields.get_Keys() -ccontains $ruleType)) {
        return "$Label has no Type of String, Integer, Boolean, List or External."
    }
    if ($IsListItem -and $ruleType -notin @('String', 'Integer')) { return "$Label must be a String or Integer rule." }
    foreach ($fieldName in @($Rule.get_Keys())) {
        if ($allowedFields[$ruleType] -cnotcontains $fieldName) { return "$Label has a field the $ruleType rule doesn't take, '$fieldName'." }
    }
    foreach ($numberField in @('MinLength', 'MaxLength', 'Minimum', 'Maximum', 'MinCount', 'MaxCount')) {
        if ($Rule.ContainsKey($numberField) -and -not (ConvertTo-OverrideInteger -Value $Rule[$numberField]).Valid) {
            return "$Label $numberField isn't a whole number."
        }
    }
    if ($Rule.ContainsKey('Description') -and -not ($Rule['Description'] -is [string])) { return "$Label Description isn't a string." }
    if ($Rule.ContainsKey('Pattern')) {
        if (-not ($Rule['Pattern'] -is [string])) { return "$Label Pattern isn't a string." }
        try { $null = [regex]::new([string]$Rule['Pattern']) } catch { return "$Label Pattern isn't a valid regular expression." }
    }
    if ($Rule.ContainsKey('Allowed')) {
        $ruleValues = @($Rule['Allowed'])
        if ($ruleValues.Count -eq 0) { return "$Label Allowed is empty." }
        foreach ($ruleValue in $ruleValues) {
            if ($ruleType -eq 'Integer' -and -not (ConvertTo-OverrideInteger -Value $ruleValue).Valid) { return "$Label Allowed holds something that isn't a whole number." }
            if ($ruleType -eq 'String' -and -not ($ruleValue -is [string])) { return "$Label Allowed holds something that isn't a string." }
        }
    }
    if ($ruleType -eq 'List') {
        if (-not $Rule.ContainsKey('ItemRule')) { return "$Label has no ItemRule." }
        return (Test-OverrideCatalogRule -Rule $Rule['ItemRule'] -Label "$Label ItemRule" -IsListItem)
    }
    return $null
}

function Get-OverrideDocumentationField {
    <#
    .SYNOPSIS
        Returns the catalog fields that feed OVERRIDE.md and nothing that runs.
    .DESCRIPTION
        The one definition of the documentation-only fields: Key holds the key-level
        names and TopLevel the top-level ones. The reader accepts them and never
        requires them, and the generator uses them. A release whose catalog changes are
        confined to these fields changes no run. Shipped and Rule, a rule's Description
        included, are not on the list, because a run reads them. Keep both lists as
        literal string arrays, because a release check reads them from this file's
        syntax tree.
    .OUTPUTS
        PSCustomObject with Key and TopLevel, string arrays.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param ()
    return [pscustomobject]@{
        Key      = [string[]]@('Summary', 'ShippedText', 'ShippedReason', 'OverrideNote', 'ValuesNote')
        TopLevel = [string[]]@('Document')
    }
}

function ConvertFrom-OverrideCatalogData {
    # Checks catalog data already read from its file. Returns Settings (canonical key to
    # entry), Retired (old name to entry), SiblingProjects (key to the projects whose
    # catalogs hold it), Project, Document and Error ($null, or one problem per line).
    # The documentation-only fields are checked for their kind only, and never required.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [AllowNull()]
        [object]$CatalogData,

        [Parameter(Mandatory)]
        [string]$Prefix
    )
    $ErrorActionPreference = 'Stop'
    $problems          = [System.Collections.Generic.List[string]]::new()
    $catalogKeys       = @{}
    $retiredKeys       = @{}
    $siblingProjects   = @{}
    $projectName       = $null
    $documentData      = $null
    $keyNamePattern    = '\A[A-Za-z][A-Za-z0-9]*\z'
    $documentationList = Get-OverrideDocumentationField
    $topFields         = @('Project', 'Settings', 'Retired', 'Siblings') + @($documentationList.TopLevel)
    $entryFields       = @('Target', 'Name', 'Secret', 'Shipped', 'Rule') + @($documentationList.Key)
    $documentFields    = @('NotCovered', 'CsvReplacements', 'Security', 'BuildProfile')

    try {
        if (-not ($CatalogData -is [hashtable])) {
            $problems.Add("$Prefix it isn't one hashtable.")
        } else {
            foreach ($topField in @($CatalogData.get_Keys())) {
                if ($topFields -cnotcontains $topField) {
                    $problems.Add("$Prefix unknown field '$topField'. The fields are $(($topFields[0..($topFields.Count - 2)]) -join ', ') and $($topFields[-1]).")
                }
            }
            if ($CatalogData.ContainsKey('Project')) {
                if ($CatalogData['Project'] -is [string]) { $projectName = [string]$CatalogData['Project'] }
                else { $problems.Add("$Prefix Project isn't a string.") }
            }
            if ($CatalogData.ContainsKey('Document')) {
                $documentData = $CatalogData['Document']
                if (-not ($documentData -is [hashtable])) {
                    $problems.Add("$Prefix Document isn't a table.")
                    $documentData = $null
                } else {
                    foreach ($documentField in @($documentData.get_Keys())) {
                        if ($documentFields -cnotcontains $documentField) {
                            $problems.Add("$Prefix Document has a field it doesn't take, '$documentField'. The fields are NotCovered, CsvReplacements, Security and BuildProfile.")
                        }
                    }
                }
            }
            if (-not ($CatalogData['Settings'] -is [hashtable])) {
                $problems.Add("$Prefix Settings is missing or isn't a table.")
            } else {
                foreach ($keyName in @($CatalogData['Settings'].get_Keys() | Sort-Object)) {
                    $entry = $CatalogData['Settings'][$keyName]
                    if ($keyName -cnotmatch $keyNamePattern) { $problems.Add("$Prefix key '$keyName' isn't letters and digits starting with a letter."); continue }
                    if (-not ($entry -is [hashtable])) { $problems.Add("$Prefix key $keyName isn't a table."); continue }
                    $entryProblem = $null
                    foreach ($fieldName in @($entry.get_Keys())) {
                        if ($entryFields -cnotcontains $fieldName) { $entryProblem = "key $keyName has a field it doesn't take, '$fieldName'. The fields are $(($entryFields[0..($entryFields.Count - 2)]) -join ', ') and $($entryFields[-1])." }
                    }
                    if (-not $entryProblem -and @('Variable', 'Parameter', 'Constant') -cnotcontains [string]$entry['Target']) {
                        $entryProblem = "key $keyName has no Target of Variable, Parameter or Constant."
                    }
                    if (-not $entryProblem -and -not ($entry['Name'] -is [string] -and $entry['Name'] -match '\A[A-Za-z_][A-Za-z0-9_]*\z')) {
                        $entryProblem = "key $keyName has no Name, the variable or parameter it sets, without the dollar sign."
                    }
                    if (-not $entryProblem -and $entry.ContainsKey('Secret') -and -not ($entry['Secret'] -is [bool])) {
                        $entryProblem = "key $keyName has a Secret that isn't `$true or `$false."
                    }
                    if (-not $entryProblem) {
                        foreach ($documentationName in @($documentationList.Key)) {
                            if ($entry.ContainsKey($documentationName) -and -not ($entry[$documentationName] -is [string])) {
                                $entryProblem = "key $keyName has a $documentationName that isn't a string."
                            }
                        }
                    }
                    if (-not $entryProblem) {
                        if ($entry.ContainsKey('Rule')) {
                            $ruleProblem = Test-OverrideCatalogRule -Rule $entry['Rule'] -Label "key $keyName Rule"
                            if ($ruleProblem) { $entryProblem = $ruleProblem.TrimEnd('.') }
                        } elseif ($entry['Target'] -ne 'Parameter') {
                            $entryProblem = "key $keyName has no Rule, which a $($entry['Target']) key needs"
                        }
                    }
                    if ($entryProblem) { $problems.Add("$Prefix $($entryProblem.TrimEnd('.')).") ; continue }
                    $catalogKeys[$keyName] = [pscustomobject]@{
                        Key           = [string]$keyName
                        Target        = [string]$entry['Target']
                        Name          = [string]$entry['Name']
                        Secret        = ($entry.ContainsKey('Secret') -and $entry['Secret'])
                        Rule          = $null
                        HasShipped    = ($entry.ContainsKey('Shipped') -and $null -ne $entry['Shipped'])
                        Shipped       = $null
                        Summary       = $(if ($entry.ContainsKey('Summary')) { [string]$entry['Summary'] } else { $null })
                        ShippedText   = $(if ($entry.ContainsKey('ShippedText')) { [string]$entry['ShippedText'] } else { $null })
                        ShippedReason = $(if ($entry.ContainsKey('ShippedReason')) { [string]$entry['ShippedReason'] } else { $null })
                        OverrideNote  = $(if ($entry.ContainsKey('OverrideNote')) { [string]$entry['OverrideNote'] } else { $null })
                        ValuesNote    = $(if ($entry.ContainsKey('ValuesNote')) { [string]$entry['ValuesNote'] } else { $null })
                    }
                    # Rule and Shipped are set by plain assignment, never through a $( )
                    # subexpression, which would unroll a one-item list to its item and an
                    # empty list to $null. Shipped keeps exactly the type it was imported with.
                    if ($entry.ContainsKey('Rule')) { $catalogKeys[$keyName].Rule = $entry['Rule'] }
                    if ($entry.ContainsKey('Shipped')) { $catalogKeys[$keyName].Shipped = $entry['Shipped'] }
                }
            }

            if ($CatalogData.ContainsKey('Retired')) {
                if (-not ($CatalogData['Retired'] -is [hashtable])) {
                    $problems.Add("$Prefix Retired isn't a table.")
                } else {
                    foreach ($retiredName in @($CatalogData['Retired'].get_Keys() | Sort-Object)) {
                        $retiredEntry = $CatalogData['Retired'][$retiredName]
                        $retiredProblem = $null
                        if ($retiredName -cnotmatch $keyNamePattern) { $retiredProblem = "retired key '$retiredName' isn't letters and digits starting with a letter" }
                        elseif ($catalogKeys.ContainsKey($retiredName)) { $retiredProblem = "retired key $retiredName is also a current key" }
                        elseif (-not ($retiredEntry -is [hashtable])) { $retiredProblem = "retired key $retiredName isn't a table" }
                        else {
                            foreach ($fieldName in @($retiredEntry.get_Keys())) {
                                if (@('Version', 'RenamedTo') -cnotcontains $fieldName) { $retiredProblem = "retired key $retiredName has a field it doesn't take, '$fieldName'. The fields are Version and RenamedTo" }
                            }
                            if (-not $retiredProblem -and -not ($retiredEntry['Version'] -is [string] -and -not [string]::IsNullOrWhiteSpace($retiredEntry['Version']))) {
                                $retiredProblem = "retired key $retiredName has no Version, the release that retired it"
                            }
                            if (-not $retiredProblem -and $retiredEntry.ContainsKey('RenamedTo')) {
                                $renamedTo = $retiredEntry['RenamedTo']
                                if (-not ($renamedTo -is [string]) -or -not ($catalogKeys.get_Keys() -ccontains $renamedTo)) {
                                    $retiredProblem = "retired key $retiredName has a RenamedTo that isn't a current key, spelled as Settings spells it"
                                }
                            }
                        }
                        if ($retiredProblem) { $problems.Add("$Prefix $retiredProblem."); continue }
                        $retiredKeys[$retiredName] = [pscustomobject]@{
                            Key       = [string]$retiredName
                            Version   = [string]$retiredEntry['Version']
                            RenamedTo = $(if ($retiredEntry.ContainsKey('RenamedTo')) { [string]$retiredEntry['RenamedTo'] } else { $null })
                        }
                    }
                }
            }

            if ($CatalogData.ContainsKey('Siblings')) {
                if (-not ($CatalogData['Siblings'] -is [hashtable])) {
                    $problems.Add("$Prefix Siblings isn't a table.")
                } else {
                    foreach ($siblingName in @($CatalogData['Siblings'].get_Keys() | Sort-Object)) {
                        foreach ($siblingKey in @($CatalogData['Siblings'][$siblingName])) {
                            if (-not ($siblingKey -is [string]) -or $siblingKey -cnotmatch $keyNamePattern) {
                                $problems.Add("$Prefix Siblings for $siblingName holds something that isn't a key name.")
                                continue
                            }
                            if (-not $siblingProjects.ContainsKey($siblingKey)) { $siblingProjects[$siblingKey] = [System.Collections.Generic.List[string]]::new() }
                            if ($siblingProjects[$siblingKey] -cnotcontains $siblingName) { $siblingProjects[$siblingKey].Add([string]$siblingName) }
                        }
                    }
                }
            }
        }
    } catch {
        $problems.Add("$Prefix the catalog check failed unexpectedly ($($_.Exception.GetType().FullName) at OverrideFile.ps1 line $($_.InvocationInfo.ScriptLineNumber)).")
    }

    $errorText = $null
    if ($problems.Count -gt 0) { $errorText = $problems -join [Environment]::NewLine }
    return [pscustomobject]@{
        Settings        = $catalogKeys
        Retired         = $retiredKeys
        SiblingProjects = $siblingProjects
        Project         = $projectName
        Document        = $documentData
        Error           = $errorText
    }
}

function Read-OverrideCatalog {
    # Reads a catalog file and checks it. Returns what ConvertFrom-OverrideCatalogData
    # returns.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [AllowNull()]
        [string]$CatalogPath
    )
    $ErrorActionPreference = 'Stop'
    $prefix = "Override catalog '$CatalogPath':"
    $readProblem = $null
    $catalogData = $null
    try {
        if ([string]::IsNullOrWhiteSpace($CatalogPath)) {
            $readProblem = 'Override catalog: no path was given.'
        } elseif (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) {
            $readProblem = "$prefix the file does not exist."
        } else {
            try {
                $catalogData = Import-PowerShellDataFile -LiteralPath $CatalogPath -ErrorAction Stop
            } catch {
                $readProblem = "$prefix can't be read as a PowerShell data file. It must hold one hashtable of constant values."
            }
        }
    } catch {
        $readProblem = "$prefix the catalog check failed unexpectedly ($($_.Exception.GetType().FullName) at OverrideFile.ps1 line $($_.InvocationInfo.ScriptLineNumber))."
    }
    if ($readProblem) {
        return [pscustomobject]@{ Settings = @{}; Retired = @{}; SiblingProjects = @{}; Project = $null; Document = $null; Error = $readProblem }
    }
    return (ConvertFrom-OverrideCatalogData -CatalogData $catalogData -Prefix $prefix)
}
#endregion

#region Get-OverrideFile
function Get-OverrideFile {
    <#
    .SYNOPSIS
        Reads a project's override file and checks it against the project's catalog.
    .DESCRIPTION
        Never throws, and writes nothing. A missing file is one INFO line and nothing
        else, and the catalog isn't read. A present file is parsed with
        Parser.ParseFile, each value is tested with SafeGetValue(), and only then is the
        file read with Import-PowerShellDataFile. A parse error, a file that isn't one
        hashtable, or a value that isn't a constant is a stop with a fixed text and a
        line number. A file with no statements at all is a WARN, and the shipped
        settings apply.

        Each key is matched to the catalog ignoring case and classed Missing, Empty
        ($null, '', whitespace, @() or @{}, one WARN each) or Value. An unknown key
        stops, with a hint when a sibling project's catalog holds it. A retired key that
        was removed WARNs and is ignored. A renamed one WARNs and is applied under its
        new name, and an old name and its new name set to different values stop.
        Values for keys with a catalog rule are checked by it. A file with non-ASCII
        bytes and no byte order mark WARNs. Every line starts with its source.
    .PARAMETER Path
        The override file, normally overrides\overrides.psd1 in the project folder.
    .PARAMETER CatalogPath
        The project's catalog, normally include\override-catalog.psd1.
    .OUTPUTS
        PSCustomObject with Path, Found (bool), Sha256 ($null when not found), Values (a
        hashtable of canonical key to value, for keys in state Value), Empty (the keys
        present and empty), Info and Warnings (string arrays) and Error ($null, or one
        stop per line). Values and Empty are empty when Error is set.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [AllowNull()]
        [string]$Path,

        [AllowNull()]
        [string]$CatalogPath
    )
    $ErrorActionPreference = 'Stop'

    $infoLines    = [System.Collections.Generic.List[string]]::new()
    $warningLines = [System.Collections.Generic.List[string]]::new()
    $errorLines   = [System.Collections.Generic.List[string]]::new()
    $values       = @{}
    $emptyKeys    = [System.Collections.Generic.List[string]]::new()
    $found        = $false
    $sha256Text   = $null
    $prefix       = "Override file '$Path':"
    $readText     = "$prefix can't be read as a PowerShell data file. It must hold one hashtable of constant values."

    try {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            $errorLines.Add('Override file: no path was given.')
        } elseif (-not (Test-Path -LiteralPath $Path)) {
            $infoLines.Add("No override file at '$Path'; the shipped settings apply.")
        } else {
            $found = $true
            $fileBytes = $null
            $fullPath  = $null
            if (Test-Path -LiteralPath $Path -PathType Leaf) {
                try {
                    $fullPath  = Convert-Path -LiteralPath $Path
                    $fileBytes = [System.IO.File]::ReadAllBytes($fullPath)
                } catch {
                    $fileBytes = $null
                }
            }

            if ($null -eq $fileBytes) {
                $errorLines.Add($readText)
            } else {
                $hashAlgorithm = [System.Security.Cryptography.SHA256]::Create()
                try {
                    $sha256Text = ([System.BitConverter]::ToString($hashAlgorithm.ComputeHash($fileBytes))) -replace '-', ''
                } finally {
                    $hashAlgorithm.Dispose()
                }

                $hasByteOrderMark = ($fileBytes.Length -ge 3 -and $fileBytes[0] -eq 0xEF -and $fileBytes[1] -eq 0xBB -and $fileBytes[2] -eq 0xBF) -or
                                    ($fileBytes.Length -ge 2 -and (($fileBytes[0] -eq 0xFF -and $fileBytes[1] -eq 0xFE) -or ($fileBytes[0] -eq 0xFE -and $fileBytes[1] -eq 0xFF)))
                $hasNonAsciiByte = $false
                foreach ($fileByte in $fileBytes) {
                    if ($fileByte -gt 0x7F) { $hasNonAsciiByte = $true; break }
                }
                if ($hasNonAsciiByte -and -not $hasByteOrderMark) {
                    $warningLines.Add("$prefix the file has non-ASCII characters and no byte order mark, so Windows PowerShell reads it as ANSI and those characters may be wrong. Save it as UTF-8 with a BOM.")
                }

                #region Parse, then test each value, before any import
                $parseTokens = $null
                $parseErrors = $null
                $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($fullPath, [ref]$parseTokens, [ref]$parseErrors)
                $hashtableAst = $null
                $fileIsBlank  = $false
                if (@($parseErrors).Count -gt 0) {
                    $errorLines.Add("$prefix can't be read as a PowerShell data file (line $($parseErrors[0].Extent.StartLineNumber)). It must hold one hashtable of constant values.")
                } else {
                    $otherBlock = @($fileAst.ParamBlock, $fileAst.BeginBlock, $fileAst.ProcessBlock, $fileAst.DynamicParamBlock) | Where-Object { $null -ne $_ } | Select-Object -First 1
                    $statements = @()
                    if ($null -ne $fileAst.EndBlock) { $statements = @($fileAst.EndBlock.Statements) }
                    $shapeLine = $null
                    if ($null -ne $otherBlock) {
                        $shapeLine = $otherBlock.Extent.StartLineNumber
                    } elseif ($statements.Count -eq 0) {
                        $fileIsBlank = $true
                    } elseif ($statements.Count -gt 1) {
                        $shapeLine = $statements[1].Extent.StartLineNumber
                    } else {
                        $onlyStatement = $statements[0]
                        $isHashtable = ($onlyStatement -is [System.Management.Automation.Language.PipelineAst]) -and
                                       (@($onlyStatement.PipelineElements).Count -eq 1) -and
                                       ($onlyStatement.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) -and
                                       (@($onlyStatement.PipelineElements[0].Redirections).Count -eq 0) -and
                                       ($onlyStatement.PipelineElements[0].Expression -is [System.Management.Automation.Language.HashtableAst])
                        if ($isHashtable) {
                            $hashtableAst = $onlyStatement.PipelineElements[0].Expression
                        } else {
                            $shapeLine = $onlyStatement.Extent.StartLineNumber
                        }
                    }
                    if ($null -ne $shapeLine) {
                        $errorLines.Add("$prefix can't be read as a PowerShell data file (line $shapeLine). It must hold one hashtable of constant values.")
                    }
                }

                if ($null -ne $hashtableAst) {
                    foreach ($keyValuePair in $hashtableAst.KeyValuePairs) {
                        $keyAst = $keyValuePair.Item1
                        if (-not ($keyAst -is [System.Management.Automation.Language.ConstantExpressionAst])) {
                            $errorLines.Add("$prefix can't be read as a PowerShell data file (line $($keyAst.Extent.StartLineNumber)). It must hold one hashtable of constant values.")
                            continue
                        }
                        try {
                            $null = $keyValuePair.Item2.SafeGetValue()
                        } catch {
                            $keyText = ConvertTo-OverrideDisplayText -Value $keyAst.Value
                            $errorLines.Add("$prefix the value of $keyText on line $($keyValuePair.Item2.Extent.StartLineNumber) isn't a constant. Use a quoted string, a number, `$true, `$false or a list of those.")
                        }
                    }
                }
                #endregion

                if ($fileIsBlank) {
                    $warningLines.Add("$prefix the file holds no settings; the shipped settings apply.")
                } elseif ($errorLines.Count -eq 0) {
                    $fileData = $null
                    try {
                        $fileData = Import-PowerShellDataFile -LiteralPath $fullPath -ErrorAction Stop
                    } catch {
                        $fileData = $null
                    }
                    if (-not ($fileData -is [hashtable])) {
                        $errorLines.Add($readText)
                    } else {
                        $catalog = Read-OverrideCatalog -CatalogPath $CatalogPath
                        if ($catalog.Error) {
                            foreach ($catalogLine in ($catalog.Error -split [Environment]::NewLine)) { $errorLines.Add($catalogLine) }
                        } else {
                            #region Classify each key
                            # Canonical key to the names present for it: its own and any retired names.
                            $presentByKey = [ordered]@{}
                            foreach ($writtenKey in @($fileData.get_Keys() | Sort-Object { [string]$_ } -CaseSensitive)) {
                                $writtenText  = [string]$writtenKey
                                $writtenValue = $fileData[$writtenKey]
                                $currentKey   = @($catalog.Settings.get_Keys()) | Where-Object { [string]::Equals($_, $writtenText, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
                                $retiredKey   = @($catalog.Retired.get_Keys()) | Where-Object { [string]::Equals($_, $writtenText, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
                                if ($currentKey) {
                                    if (-not $presentByKey.Contains($currentKey)) { $presentByKey[$currentKey] = [System.Collections.Generic.List[object]]::new() }
                                    $presentByKey[$currentKey].Add([pscustomobject]@{ Name = $currentKey; Retired = $null; Value = $writtenValue })
                                } elseif ($retiredKey) {
                                    $retiredEntry = $catalog.Retired[$retiredKey]
                                    if ($null -eq $retiredEntry.RenamedTo) {
                                        $warningLines.Add("$prefix $retiredKey was removed in $($retiredEntry.Version) and is ignored.")
                                    } else {
                                        $newKey = $retiredEntry.RenamedTo
                                        if (-not $presentByKey.Contains($newKey)) { $presentByKey[$newKey] = [System.Collections.Generic.List[object]]::new() }
                                        $presentByKey[$newKey].Add([pscustomobject]@{ Name = $retiredKey; Retired = $retiredEntry; Value = $writtenValue })
                                    }
                                } else {
                                    $unknownText = ConvertTo-OverrideDisplayText -Value $writtenText
                                    $unknownLine = "$prefix unknown key '$unknownText'. The keys are listed in OVERRIDE.md."
                                    $siblingKey  = @($catalog.SiblingProjects.get_Keys()) | Where-Object { [string]::Equals($_, $writtenText, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
                                    if ($siblingKey) {
                                        $projectNames = @($catalog.SiblingProjects[$siblingKey] | Sort-Object) | ForEach-Object { "$_'s" }
                                        $unknownLine += " It belongs in $(@($projectNames) -join ' or ') overrides\overrides.psd1."
                                    }
                                    $errorLines.Add($unknownLine)
                                }
                            }

                            foreach ($canonicalKey in @($presentByKey.get_Keys())) {
                                $entry          = $catalog.Settings[$canonicalKey]
                                $presentNames   = @($presentByKey[$canonicalKey])
                                $setNames       = @($presentNames | Where-Object { -not (Test-OverrideEmptyValue -Value $_.Value) })
                                $retiredPresent = @($presentNames | Where-Object { $null -ne $_.Retired })

                                $valuesDiffer = $false
                                for ($setIndex = 1; $setIndex -lt $setNames.Count; $setIndex++) {
                                    if (-not (Test-OverrideValueEqual -First $setNames[0].Value -Second $setNames[$setIndex].Value)) { $valuesDiffer = $true }
                                }
                                if ($valuesDiffer) {
                                    $nameTexts = @($setNames | ForEach-Object { $_.Name })
                                    $nameList  = (@($nameTexts[0..($nameTexts.Count - 2)]) -join ', ') + ' and ' + $nameTexts[-1]
                                    $verb      = if ($nameTexts.Count -eq 2) { 'both' } else { 'all' }
                                    $renameTexts = @($retiredPresent | ForEach-Object { "$($_.Name) was renamed $canonicalKey in $($_.Retired.Version)" })
                                    $errorLines.Add("$prefix $nameList are $verb set, to different values. $(@($renameTexts) -join '; '); keep only $canonicalKey.")
                                    continue
                                }

                                foreach ($retiredName in $retiredPresent) {
                                    $warningLines.Add("$prefix $($retiredName.Name) was renamed $canonicalKey in $($retiredName.Retired.Version); applied as $canonicalKey.")
                                }
                                if ($setNames.Count -eq 0) {
                                    $emptyKeys.Add($canonicalKey)
                                    $warningLines.Add("$prefix $canonicalKey is empty; the shipped value applies.")
                                    continue
                                }

                                $rawValue = $setNames[0].Value
                                if ($null -eq $entry.Rule) {
                                    $values[$canonicalKey] = $rawValue
                                    continue
                                }
                                $ruleResult = Test-OverrideRuleValue -Rule $entry.Rule -Value $rawValue
                                if ($ruleResult.Valid) {
                                    $values[$canonicalKey] = $ruleResult.Value
                                } else {
                                    $shownValue = ConvertTo-OverrideDisplayText -Value $rawValue -Secret:$entry.Secret
                                    if (-not $entry.Secret) { $shownValue = "'$shownValue'" }
                                    $errorLines.Add("$prefix $canonicalKey $shownValue isn't valid. It must be $((Get-OverrideRuleText -Rule $entry.Rule).TrimEnd('.')).")
                                }
                            }
                            #endregion

                            if ($errorLines.Count -eq 0) {
                                $settingPairs = foreach ($valueKey in @($values.get_Keys() | Sort-Object -CaseSensitive)) {
                                    "$valueKey=$(ConvertTo-OverrideDisplayText -Value $values[$valueKey] -Secret:$catalog.Settings[$valueKey].Secret)"
                                }
                                $settingPairs = @($settingPairs)
                                $settingWord  = if ($settingPairs.Count -eq 1) { 'setting' } else { 'settings' }
                                $summaryLine  = "Override file '$Path' (SHA-256 $sha256Text): $($settingPairs.Count) $settingWord"
                                if ($settingPairs.Count -gt 0) { $summaryLine += ': ' + ($settingPairs -join ', ') }
                                $infoLines.Add($summaryLine)
                            }
                        }
                    }
                }

                if ($fileIsBlank -and $errorLines.Count -eq 0) {
                    $infoLines.Add("Override file '$Path' (SHA-256 $sha256Text): 0 settings")
                }
            }
        }
    } catch {
        $errorLines.Add("$prefix the reader failed unexpectedly ($($_.Exception.GetType().FullName) at OverrideFile.ps1 line $($_.InvocationInfo.ScriptLineNumber)), so no override was applied.")
    }

    $errorText = $null
    if ($errorLines.Count -gt 0) {
        $errorText = $errorLines -join [Environment]::NewLine
        $values    = @{}
        $emptyKeys.Clear()
    }
    return [pscustomobject]@{
        Path     = $Path
        Found    = $found
        Sha256   = $sha256Text
        Values   = $values
        Empty    = [string[]]$emptyKeys.ToArray()
        Info     = [string[]]$infoLines.ToArray()
        Warnings = [string[]]$warningLines.ToArray()
        Error    = $errorText
    }
}
#endregion

#region Get-OverrideParameterAssignment
function Get-OverrideParameterAssignment {
    <#
    .SYNOPSIS
        Returns the parameter assignments a script should make from its override file.
        Assigns nothing.
    .DESCRIPTION
        For each Parameter key in the override file's values, the assignment to make
        when the command line didn't bind that parameter. A bound parameter whose value
        differs from the override gets one INFO line, and the command line wins. The
        caller applies each assignment at script level, in its own body, with
        Set-Variable inside a try, so the parameter's own attributes check the value. A
        function or a scriptblock run with & would set a local copy and change nothing.
        Never throws.
    .PARAMETER OverrideFile
        The object Get-OverrideFile returned.
    .PARAMETER CatalogPath
        The project's catalog.
    .PARAMETER BoundParameters
        The script's $PSBoundParameters, or any dictionary of parameter name to value.
    .OUTPUTS
        PSCustomObject with Assignments (Key, ParameterName, Value, one per unbound
        parameter key, in key order), Shadowed (Key, ParameterName, OverrideValue,
        BoundValue, one per bound parameter key, equal or not), Info and Warnings (string
        arrays) and Error ($null, or one problem per line). Nothing is returned for a
        result that has no file or holds an error.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [AllowNull()]
        [object]$OverrideFile,

        [AllowNull()]
        [string]$CatalogPath,

        [AllowNull()]
        [System.Collections.IDictionary]$BoundParameters
    )
    $ErrorActionPreference = 'Stop'

    $assignments  = [System.Collections.Generic.List[object]]::new()
    $shadowed     = [System.Collections.Generic.List[object]]::new()
    $infoLines    = [System.Collections.Generic.List[string]]::new()
    $warningLines = [System.Collections.Generic.List[string]]::new()
    $errorLines   = [System.Collections.Generic.List[string]]::new()

    try {
        $resultProperties = @()
        if ($null -ne $OverrideFile) { $resultProperties = @($OverrideFile.PSObject.Properties.Name) }
        $isOverrideResult = @(@('Path', 'Found', 'Values', 'Error') | Where-Object { $resultProperties -notcontains $_ }).Count -eq 0
        if (-not $isOverrideResult -or -not ($OverrideFile.Values -is [System.Collections.IDictionary])) {
            $errorLines.Add('Get-OverrideParameterAssignment: OverrideFile must be the object Get-OverrideFile returned.')
        } elseif ($OverrideFile.Found -and -not $OverrideFile.Error -and $OverrideFile.Values.get_Count() -gt 0) {
            $prefix  = "Override file '$($OverrideFile.Path)':"
            $catalog = Read-OverrideCatalog -CatalogPath $CatalogPath
            if ($catalog.Error) {
                foreach ($catalogLine in ($catalog.Error -split [Environment]::NewLine)) { $errorLines.Add($catalogLine) }
            } else {
                foreach ($valueKey in @($OverrideFile.Values.get_Keys() | Sort-Object -CaseSensitive)) {
                    if (-not $catalog.Settings.ContainsKey($valueKey)) {
                        $errorLines.Add("$prefix $valueKey isn't in the catalog '$CatalogPath'. Read the file and the catalog together.")
                        continue
                    }
                    $entry = $catalog.Settings[$valueKey]
                    if ($entry.Target -ne 'Parameter') { continue }
                    $overrideValue = $OverrideFile.Values[$valueKey]
                    $boundKey = Find-OverrideDictionaryKey -Dictionary $BoundParameters -Key $entry.Name
                    if ($null -ne $boundKey) {
                        $boundValue = $BoundParameters[$boundKey]
                        $shadowed.Add([pscustomobject]@{ Key = $valueKey; ParameterName = $entry.Name; OverrideValue = $overrideValue; BoundValue = $boundValue })
                        if (-not (Test-OverrideValueEqual -First $overrideValue -Second $boundValue)) {
                            $overrideText = ConvertTo-OverrideDisplayText -Value $overrideValue -Secret:$entry.Secret
                            $boundText    = ConvertTo-OverrideDisplayText -Value $boundValue -Secret:$entry.Secret
                            $infoLines.Add("$prefix $valueKey=$overrideText not used; the command line gave $boundText.")
                        }
                    } else {
                        $assignments.Add([pscustomobject]@{ Key = $valueKey; ParameterName = $entry.Name; Value = $overrideValue })
                    }
                }
            }
        }
    } catch {
        $errorLines.Add("Get-OverrideParameterAssignment failed unexpectedly ($($_.Exception.GetType().FullName) at OverrideFile.ps1 line $($_.InvocationInfo.ScriptLineNumber)), so no override was applied.")
        $assignments.Clear()
    }

    $errorText = $null
    if ($errorLines.Count -gt 0) {
        $errorText = $errorLines -join [Environment]::NewLine
        $assignments.Clear()
    }
    return [pscustomobject]@{
        Assignments = [object[]]$assignments.ToArray()
        Shadowed    = [object[]]$shadowed.ToArray()
        Info        = [string[]]$infoLines.ToArray()
        Warnings    = [string[]]$warningLines.ToArray()
        Error       = $errorText
    }
}
#endregion

#region Read-ScriptSetting
function Get-OverrideImageNameSetting {
    # Reads the builder's "$imageName = switch ($Edition) { ... }" structurally. Returns
    # the two settings, or $null when the assignment isn't in exactly the known shape.
    [CmdletBinding()]
    [OutputType([object[]])]
    param (
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.AssignmentStatementAst]$Assignment
    )
    $switchAst = $Assignment.Right
    if (-not ($switchAst -is [System.Management.Automation.Language.SwitchStatementAst])) { return $null }
    if ($switchAst.Flags -ne [System.Management.Automation.Language.SwitchFlags]::None -or $null -ne $switchAst.Default) { return $null }
    $condition = $switchAst.Condition
    $conditionIsEdition = ($condition -is [System.Management.Automation.Language.PipelineAst]) -and
                          (@($condition.PipelineElements).Count -eq 1) -and
                          ($condition.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) -and
                          ($condition.PipelineElements[0].Expression -is [System.Management.Automation.Language.VariableExpressionAst]) -and
                          ($condition.PipelineElements[0].Expression.VariablePath.UserPath -eq 'Edition')
    if (-not $conditionIsEdition -or @($switchAst.Clauses).Count -ne 2) { return $null }

    $settingNameOf = @{ Standard = 'ImageNameStandard'; Datacenter = 'ImageNameDatacenter' }
    $settings = @{}
    foreach ($clause in $switchAst.Clauses) {
        $label = $clause.Item1
        if (-not ($label -is [System.Management.Automation.Language.StringConstantExpressionAst])) { return $null }
        $edition = @($settingNameOf.get_Keys()) | Where-Object { $_ -eq $label.Value } | Select-Object -First 1
        if (-not $edition -or $settings.ContainsKey($edition)) { return $null }
        $bodyStatements = @($clause.Item2.Statements)
        if ($bodyStatements.Count -ne 1) { return $null }
        $bodyStatement = $bodyStatements[0]
        $bodyIsString = ($bodyStatement -is [System.Management.Automation.Language.PipelineAst]) -and
                        (@($bodyStatement.PipelineElements).Count -eq 1) -and
                        ($bodyStatement.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) -and
                        (@($bodyStatement.PipelineElements[0].Redirections).Count -eq 0) -and
                        ($bodyStatement.PipelineElements[0].Expression -is [System.Management.Automation.Language.StringConstantExpressionAst])
        if (-not $bodyIsString) { return $null }
        $settings[$edition] = [pscustomobject]@{
            Name  = $settingNameOf[$edition]
            Line  = $bodyStatement.Extent.StartLineNumber
            State = 'Value'
            Value = [string]$bodyStatement.PipelineElements[0].Expression.Value
        }
    }
    return @($settings['Standard'], $settings['Datacenter'])
}

function ConvertFrom-OverrideXmlText {
    # Decodes XML element text once: the five predefined entities and numeric character
    # references to characters XML allows. Returns Valid and Value. Text holding a raw
    # '<', a '&' that starts no reference, an unknown entity, a reference to a character
    # XML forbids, or ']]>' isn't element text, and comes back not Valid, never guessed.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )
    $result = [pscustomobject]@{ Valid = $false; Value = $null }
    if ($null -eq $Text) { $Text = '' }
    if ($Text.Contains('<') -or $Text.Contains(']]>')) { return $result }
    $namedEntities = @{ amp = '&'; lt = '<'; gt = '>'; quot = '"'; apos = "'" }
    $decoded = [System.Text.StringBuilder]::new()
    $position = 0
    while ($position -lt $Text.Length) {
        $ampersandIndex = $Text.IndexOf('&', $position)
        if ($ampersandIndex -lt 0) {
            $null = $decoded.Append($Text.Substring($position))
            break
        }
        $null = $decoded.Append($Text.Substring($position, $ampersandIndex - $position))
        $referenceMatch = [regex]::Match($Text.Substring($ampersandIndex), '\A&(?:(amp|lt|gt|quot|apos)|#([0-9]{1,7})|#x([0-9A-Fa-f]{1,6}));')
        if (-not $referenceMatch.Success) { return $result }
        if ($referenceMatch.Groups[1].Success) {
            $null = $decoded.Append($namedEntities[$referenceMatch.Groups[1].Value])
        } else {
            $codePoint = if ($referenceMatch.Groups[2].Success) { [int]$referenceMatch.Groups[2].Value } else { [Convert]::ToInt32($referenceMatch.Groups[3].Value, 16) }
            $isXmlCharacter = ($codePoint -eq 0x9) -or ($codePoint -eq 0xA) -or ($codePoint -eq 0xD) -or
                              ($codePoint -ge 0x20 -and $codePoint -le 0xD7FF) -or ($codePoint -ge 0xE000 -and $codePoint -le 0xFFFD) -or
                              ($codePoint -ge 0x10000 -and $codePoint -le 0x10FFFF)
            if (-not $isXmlCharacter) { return $result }
            $null = $decoded.Append([char]::ConvertFromUtf32($codePoint))
        }
        $position = $ampersandIndex + $referenceMatch.Length
    }
    $result.Valid = $true
    $result.Value = $decoded.ToString()
    return $result
}

function Read-ScriptSetting {
    <#
    .SYNOPSIS
        Parses a script, never running it, and returns its constant settings.
    .DESCRIPTION
        Parser.ParseFile, then the script block's own top-level assignment statements
        (an assignment inside an if, a loop or a function is skipped) and the parameter
        defaults, each evaluated with SafeGetValue(). A refused value comes back as
        Dynamic with its name and line. A refused parameter default also carries its
        source text, for comparison only. Never log it. A parameter with no default comes
        back as NoDefault.

        Also returns the header's Version: text from the first comment block, and the
        matches of the caller's named patterns inside the script's here-strings. A top-
        level "$imageName = switch ($Edition)" with exactly the clauses 'Standard' and
        'Datacenter', each one constant string, gives ImageNameStandard and
        ImageNameDatacenter. Any other shape gives both as Dynamic, with a WARN.
        Never throws, and returns no exception or parse-error text.
    .PARAMETER Path
        The script to read.
    .PARAMETER TextPattern
        Optional. Name to pattern, for values held in here-strings. A pattern is a
        regular expression with one capture group, given in one of two ways:
          - a string, such as 'guestOS = "([^"]*)"'. The capture is returned as written
          - a table, @{ Pattern = '<Organization>([^<]*)</Organization>'; Xml = $true },
            for a capture that is XML element text. The capture is decoded once (&amp;,
            &lt;, &gt;, &quot;, &apos; and numeric references such as &#38; or &#x26;)
            before it is returned. Text that isn't valid element text, such as a lone &
            or a raw <, comes back Dynamic with a Reason, never guessed at. Xml = $false,
            or a table with only Pattern, works as a string does
        A table with any other field, or a pattern without a capture group, is
        BadPattern.
    .OUTPUTS
        PSCustomObject with Path, Error ($null, or why the script couldn't be read, with
        a line number), Version ($null when the header has none), Assignments (Name,
        Line, State Value or Dynamic, Value, in file order, so the last one for a name is
        the one a run uses), Parameters (Name, Line, State Value, Dynamic or NoDefault,
        Value, SourceText), ImageNames (Name, Line, State, Value; empty when the script
        has no $imageName assignment), TextMatches (Name, Line, State Value, Dynamic,
        Ambiguous, NotFound or BadPattern, Value, SourceText, and Reason, which says why
        a match isn't a Value and never holds the text) and Warnings.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [AllowNull()]
        [string]$Path,

        [AllowNull()]
        [hashtable]$TextPattern
    )
    $ErrorActionPreference = 'Stop'

    $assignments  = [System.Collections.Generic.List[object]]::new()
    $parameters   = [System.Collections.Generic.List[object]]::new()
    $imageNames   = [System.Collections.Generic.List[object]]::new()
    $textMatches  = [System.Collections.Generic.List[object]]::new()
    $warningLines = [System.Collections.Generic.List[string]]::new()
    $errorText    = $null
    $versionText  = $null
    $prefix       = "Script '$Path':"

    try {
        if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            $errorText = "$prefix the file does not exist."
        } else {
            $fullPath    = Convert-Path -LiteralPath $Path
            $parseTokens = $null
            $parseErrors = $null
            $scriptAst   = [System.Management.Automation.Language.Parser]::ParseFile($fullPath, [ref]$parseTokens, [ref]$parseErrors)
            if (@($parseErrors).Count -gt 0) {
                $errorText = "$prefix can't be parsed (line $($parseErrors[0].Extent.StartLineNumber)), so no setting was read from it."
            } else {
                #region Header version
                $helpToken = @($parseTokens) | Where-Object { $_.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment -and $_.Text.StartsWith('<#') } | Select-Object -First 1
                if ($null -ne $helpToken) {
                    $versionMatch = [regex]::Match($helpToken.Text, '(?im)^\s*Version\s*:\s*(\S+)')
                    if ($versionMatch.Success) { $versionText = $versionMatch.Groups[1].Value }
                }
                #endregion

                #region Top-level assignments
                $imageNameAssignments = [System.Collections.Generic.List[object]]::new()
                $topStatements = @()
                if ($null -ne $scriptAst.EndBlock) { $topStatements = @($scriptAst.EndBlock.Statements) }
                foreach ($statement in $topStatements) {
                    if (-not ($statement -is [System.Management.Automation.Language.AssignmentStatementAst])) { continue }
                    if ($statement.Operator -ne [System.Management.Automation.Language.TokenKind]::Equals) { continue }
                    $target = $statement.Left
                    if ($target -is [System.Management.Automation.Language.ConvertExpressionAst]) { $target = $target.Child }
                    if (-not ($target -is [System.Management.Automation.Language.VariableExpressionAst])) { continue }
                    $variableName = $target.VariablePath.UserPath
                    $entry = [pscustomobject]@{ Name = $variableName; Line = $statement.Extent.StartLineNumber; State = 'Value'; Value = $null }
                    # The right side of "$x = 'a'" is a CommandExpressionAst, which SafeGetValue()
                    # refuses as a whole, so its expression is evaluated instead.
                    $valueAst = $statement.Right
                    if ($valueAst -is [System.Management.Automation.Language.CommandExpressionAst] -and @($valueAst.Redirections).Count -eq 0) { $valueAst = $valueAst.Expression }
                    try {
                        if (-not ($valueAst -is [System.Management.Automation.Language.ExpressionAst])) { throw 'not an expression' }
                        $entry.Value = $valueAst.SafeGetValue()
                    } catch {
                        $entry.State = 'Dynamic'
                        $entry.Value = $null
                    }
                    $assignments.Add($entry)
                    if ($variableName -eq 'imageName') { $imageNameAssignments.Add($statement) }
                }
                #endregion

                #region Image names
                if ($imageNameAssignments.Count -gt 0) {
                    $imageNameSettings = $null
                    if ($imageNameAssignments.Count -eq 1) { $imageNameSettings = Get-OverrideImageNameSetting -Assignment $imageNameAssignments[0] }
                    if ($null -ne $imageNameSettings) {
                        foreach ($imageNameSetting in $imageNameSettings) { $imageNames.Add($imageNameSetting) }
                    } else {
                        $firstLine = $imageNameAssignments[0].Extent.StartLineNumber
                        foreach ($settingName in @('ImageNameStandard', 'ImageNameDatacenter')) {
                            $imageNames.Add([pscustomobject]@{ Name = $settingName; Line = $firstLine; State = 'Dynamic'; Value = $null })
                        }
                        $warningLines.Add("$prefix the image name assignment on line $firstLine isn't in the shape this reader knows, so ImageNameStandard and ImageNameDatacenter weren't read. Set them by hand.")
                    }
                }
                #endregion

                #region Parameter defaults
                if ($null -ne $scriptAst.ParamBlock) {
                    foreach ($parameterAst in $scriptAst.ParamBlock.Parameters) {
                        $entry = [pscustomobject]@{
                            Name       = $parameterAst.Name.VariablePath.UserPath
                            Line       = $parameterAst.Extent.StartLineNumber
                            State      = 'NoDefault'
                            Value      = $null
                            SourceText = $null
                        }
                        if ($null -ne $parameterAst.DefaultValue) {
                            try {
                                $entry.Value = $parameterAst.DefaultValue.SafeGetValue()
                                $entry.State = 'Value'
                            } catch {
                                $entry.State      = 'Dynamic'
                                $entry.Value      = $null
                                $entry.SourceText = $parameterAst.DefaultValue.Extent.Text
                            }
                        }
                        $parameters.Add($entry)
                    }
                }
                #endregion

                #region Here-string matches
                if ($null -ne $TextPattern) {
                    $hereStrings = @($parseTokens) | Where-Object {
                        $_.Kind -eq [System.Management.Automation.Language.TokenKind]::HereStringExpandable -or
                        $_.Kind -eq [System.Management.Automation.Language.TokenKind]::HereStringLiteral
                    }
                    foreach ($patternName in @($TextPattern.get_Keys() | Sort-Object)) {
                        $matchEntry = [pscustomobject]@{ Name = [string]$patternName; Line = $null; State = 'NotFound'; Value = $null; SourceText = $null; Reason = 'the pattern matched no here-string.' }

                        # A pattern is a string, or a table with Pattern and an optional Xml.
                        $patternSpec = $TextPattern[$patternName]
                        $patternText = $null
                        $isXmlText   = $false
                        if ($patternSpec -is [string]) {
                            $patternText = $patternSpec
                        } elseif ($patternSpec -is [System.Collections.IDictionary]) {
                            $specKeys = @($patternSpec.get_Keys())
                            $patternKey = Find-OverrideDictionaryKey -Dictionary $patternSpec -Key 'Pattern'
                            $xmlKey     = Find-OverrideDictionaryKey -Dictionary $patternSpec -Key 'Xml'
                            $knownKeyCount = @($patternKey, $xmlKey | Where-Object { $null -ne $_ }).Count
                            $xmlIsKnown = ($null -eq $xmlKey) -or ($patternSpec[$xmlKey] -is [bool])
                            if ($null -ne $patternKey -and $patternSpec[$patternKey] -is [string] -and $specKeys.Count -eq $knownKeyCount -and $xmlIsKnown) {
                                $patternText = $patternSpec[$patternKey]
                                if ($null -ne $xmlKey) { $isXmlText = [bool]$patternSpec[$xmlKey] }
                            }
                        }
                        $patternRegex = $null
                        if ($null -ne $patternText) {
                            try { $patternRegex = [regex]::new($patternText) } catch { $patternRegex = $null }
                        }
                        if ($null -eq $patternRegex -or $patternRegex.GetGroupNumbers().Count -lt 2) {
                            $matchEntry.State  = 'BadPattern'
                            $matchEntry.Reason = 'the pattern is not a regular expression with a capture group, as a string or as @{ Pattern = ...; Xml = $true }.'
                            $warningLines.Add("$prefix the pattern for $patternName isn't a regular expression with a capture group, given as a string or as @{ Pattern = ...; Xml = `$true }.")
                            $textMatches.Add($matchEntry)
                            continue
                        }
                        $foundTexts = [System.Collections.Generic.List[object]]::new()
                        foreach ($hereString in $hereStrings) {
                            $isExpandable = $hereString.Kind -eq [System.Management.Automation.Language.TokenKind]::HereStringExpandable
                            foreach ($textMatch in $patternRegex.Matches($hereString.Value)) {
                                $capturedText = $textMatch.Groups[1].Value
                                $lineOffset   = ([regex]::Matches($hereString.Value.Substring(0, $textMatch.Index), "`n")).Count
                                $foundEntry = [pscustomobject]@{
                                    Line    = $hereString.Extent.StartLineNumber + 1 + $lineOffset
                                    Text    = $capturedText
                                    Value   = $capturedText
                                    Dynamic = ($isExpandable -and $capturedText -match '[$`]')
                                    Reason  = $null
                                }
                                if ($foundEntry.Dynamic) {
                                    $foundEntry.Reason = 'the text holds a variable or an escape in an expandable here-string.'
                                } elseif ($isXmlText) {
                                    $xmlResult = ConvertFrom-OverrideXmlText -Text $capturedText
                                    if ($xmlResult.Valid) {
                                        $foundEntry.Value = $xmlResult.Value
                                    } else {
                                        $foundEntry.Dynamic = $true
                                        $foundEntry.Reason  = "the text isn't valid XML element text, such as a lone & or a raw <, so it wasn't decoded."
                                    }
                                }
                                $foundTexts.Add($foundEntry)
                            }
                        }
                        if ($foundTexts.Count -gt 0) {
                            $dynamicText = @($foundTexts | Where-Object { $_.Dynamic }) | Select-Object -First 1
                            $distinctValues = @($foundTexts | ForEach-Object { $_.Value } | Sort-Object -Unique -CaseSensitive)
                            $matchEntry.Line = $foundTexts[0].Line
                            if ($null -ne $dynamicText) {
                                $matchEntry.State      = 'Dynamic'
                                $matchEntry.Line       = $dynamicText.Line
                                $matchEntry.SourceText = $dynamicText.Text
                                $matchEntry.Reason     = $dynamicText.Reason
                            } elseif ($distinctValues.Count -gt 1) {
                                $matchEntry.State  = 'Ambiguous'
                                $matchEntry.Reason = 'the here-strings hold different values.'
                            } else {
                                $matchEntry.State  = 'Value'
                                $matchEntry.Value  = $foundTexts[0].Value
                                $matchEntry.Reason = $null
                            }
                        }
                        $textMatches.Add($matchEntry)
                    }
                }
                #endregion
            }
        }
    } catch {
        $errorText = "$prefix the read failed unexpectedly ($($_.Exception.GetType().FullName) at OverrideFile.ps1 line $($_.InvocationInfo.ScriptLineNumber)), so no setting was read from it."
    }

    if ($errorText) {
        $assignments.Clear(); $parameters.Clear(); $imageNames.Clear(); $textMatches.Clear()
        $versionText = $null
    }
    return [pscustomobject]@{
        Path        = $Path
        Error       = $errorText
        Version     = $versionText
        Assignments = [object[]]$assignments.ToArray()
        Parameters  = [object[]]$parameters.ToArray()
        ImageNames  = [object[]]$imageNames.ToArray()
        TextMatches = [object[]]$textMatches.ToArray()
        Warnings    = [string[]]$warningLines.ToArray()
    }
}
#endregion

#region Get-ParameterRule and Test-ParameterValueByAst
function Get-ParameterRule {
    <#
    .SYNOPSIS
        Reads each parameter's type and validation attributes from a script's syntax
        tree, without running anything.
    .DESCRIPTION
        Parser.ParseFile, then for each parameter of the script's param() block: its
        type constraint (Int, String, Switch, Object when it has none, or Unknown), its
        attributes in the order written, each with its arguments evaluated by
        SafeGetValue() when they are constants, and whether it is mandatory. Parameter,
        Alias, AllowNull, AllowEmptyString and AllowEmptyCollection are Ignored, as they
        check no value. ValidateRange, ValidateSet and ValidatePattern are Validation.
        Any other attribute is Unknown, and its arguments aren't evaluated.
        Test-ParameterValueByAst and ConvertTo-OverrideDocument both read parameters
        through this function. Never throws.
    .PARAMETER Path
        The script to read.
    .OUTPUTS
        PSCustomObject with Path, Error ($null, or why the script couldn't be read),
        ParseErrorLine ($null, or the first parse error's line) and Parameters (Name,
        Line, TypeName, TypeKind, Mandatory, and Attributes: Name, Kind, Constant,
        Positional and Named, in the order written).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [AllowNull()]
        [string]$Path
    )
    $ErrorActionPreference = 'Stop'
    $parameters     = [System.Collections.Generic.List[object]]::new()
    $errorText      = $null
    $parseErrorLine = $null
    $prefix         = "Script '$Path':"

    try {
        if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            $errorText = "$prefix the file does not exist."
        } else {
            $parseTokens = $null
            $parseErrors = $null
            $scriptAst   = [System.Management.Automation.Language.Parser]::ParseFile((Convert-Path -LiteralPath $Path), [ref]$parseTokens, [ref]$parseErrors)
            if (@($parseErrors).Count -gt 0) {
                $parseErrorLine = $parseErrors[0].Extent.StartLineNumber
                $errorText      = "$prefix can't be parsed (line $parseErrorLine)."
            } elseif ($null -ne $scriptAst.ParamBlock) {
                foreach ($parameterAst in $scriptAst.ParamBlock.Parameters) {
                    $typeConstraints = @($parameterAst.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.TypeConstraintAst] })
                    $typeKind = 'Object'
                    $typeName = $null
                    if ($typeConstraints.Count -gt 1) {
                        $typeKind = 'Unknown'
                    } elseif ($typeConstraints.Count -eq 1) {
                        $typeName = $typeConstraints[0].TypeName.FullName
                        switch -Regex ($typeName) {
                            '\A(int|int32|System\.Int32)\z'                                                { $typeKind = 'Int'; break }
                            '\A(string|System\.String)\z'                                                  { $typeKind = 'String'; break }
                            '\A(switch|SwitchParameter|System\.Management\.Automation\.SwitchParameter)\z' { $typeKind = 'Switch'; break }
                            default                                                                        { $typeKind = 'Unknown' }
                        }
                    }

                    $attributes  = [System.Collections.Generic.List[object]]::new()
                    $isMandatory = $false
                    foreach ($attributeAst in @($parameterAst.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.AttributeAst] })) {
                        $attributeName = $attributeAst.TypeName.FullName -replace '\ASystem\.Management\.Automation\.', '' -replace 'Attribute\z', ''
                        $attributeKind = 'Unknown'
                        if ($attributeName -in @('Parameter', 'Alias', 'AllowNull', 'AllowEmptyString', 'AllowEmptyCollection')) { $attributeKind = 'Ignored' }
                        elseif ($attributeName -in @('ValidateRange', 'ValidateSet', 'ValidatePattern')) { $attributeKind = 'Validation' }

                        $positionalValues     = [System.Collections.Generic.List[object]]::new()
                        $namedValues          = @{}
                        $argumentsAreConstant = $null
                        if ($attributeKind -ne 'Unknown') {
                            $argumentsAreConstant = $true
                            foreach ($positionalArgument in $attributeAst.PositionalArguments) {
                                try { $positionalValues.Add($positionalArgument.SafeGetValue()) } catch { $argumentsAreConstant = $false }
                            }
                            foreach ($namedArgument in $attributeAst.NamedArguments) {
                                if ($namedArgument.ExpressionOmitted) { $namedValues[$namedArgument.ArgumentName] = $true; continue }
                                try {
                                    $namedValues[$namedArgument.ArgumentName] = $namedArgument.Argument.SafeGetValue()
                                } catch {
                                    $argumentsAreConstant = $false
                                    # A Mandatory that isn't a constant counts as mandatory.
                                    if ($namedArgument.ArgumentName -eq 'Mandatory') { $namedValues['Mandatory'] = $true }
                                }
                            }
                        }
                        if ($attributeName -eq 'Parameter' -and $namedValues.ContainsKey('Mandatory') -and [bool]$namedValues['Mandatory']) { $isMandatory = $true }
                        $attributes.Add([pscustomobject]@{
                            Name       = $attributeName
                            Kind       = $attributeKind
                            Constant   = $argumentsAreConstant
                            Positional = [object[]]$positionalValues.ToArray()
                            Named      = $namedValues
                        })
                    }

                    $parameters.Add([pscustomobject]@{
                        Name       = $parameterAst.Name.VariablePath.UserPath
                        Line       = $parameterAst.Extent.StartLineNumber
                        TypeName   = $typeName
                        TypeKind   = $typeKind
                        Mandatory  = $isMandatory
                        Attributes = [object[]]$attributes.ToArray()
                    })
                }
            }
        }
    } catch {
        $errorText = "$prefix the read failed unexpectedly ($($_.Exception.GetType().FullName) at OverrideFile.ps1 line $($_.InvocationInfo.ScriptLineNumber))."
    }

    if ($errorText) { $parameters.Clear() }
    return [pscustomobject]@{
        Path           = $Path
        Error          = $errorText
        ParseErrorLine = $parseErrorLine
        Parameters     = [object[]]$parameters.ToArray()
    }
}

function Test-ParameterValueByAst {
    <#
    .SYNOPSIS
        Checks a value against a script parameter's type and validation attributes,
        read from the script's syntax tree, without running anything.
    .DESCRIPTION
        Reads the parameter with Get-ParameterRule and checks the value against its type
        constraint ([int] by [int]::TryParse with the invariant culture, [string] as any
        single value, [switch] as $true or $false, none as any value) and against
        ValidateRange (constant minimum and maximum, on an [int]), ValidateSet (constant
        values, ignoring case unless IgnoreCase = $false) and ValidatePattern (a constant
        pattern, with the attribute's default options, IgnoreCase, unless Options is
        given). Parameter, Alias, AllowNull, AllowEmptyString and AllowEmptyCollection
        check nothing and are passed over. Any other attribute, another type or an
        argument that isn't a constant makes the value Uncheckable, unless a check it
        does know refuses the value.

        [int]::TryParse is stricter than parameter binding, which also takes text such
        as '0x2000' or '8192.0'. Such a value is Refused here, which is the safe side.
        Never throws. The reason never holds the value.
    .PARAMETER ScriptPath
        The script that declares the parameter.
    .PARAMETER ParameterName
        The parameter, without the dollar sign.
    .PARAMETER Value
        The value to check.
    .OUTPUTS
        PSCustomObject with State (Valid, Refused or Uncheckable), Attribute (for
        Refused, what refused it: Type, ValidateRange, ValidateSet or ValidatePattern;
        for Uncheckable, the attribute or part it couldn't check) and Reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [AllowNull()]
        [string]$ScriptPath,

        [AllowNull()]
        [string]$ParameterName,

        [AllowNull()]
        [object]$Value
    )
    $ErrorActionPreference = 'Stop'
    $result = [pscustomobject]@{ State = 'Uncheckable'; Attribute = $null; Reason = $null }
    $invariantCulture = [System.Globalization.CultureInfo]::InvariantCulture

    try {
        if ([string]::IsNullOrWhiteSpace($ScriptPath) -or -not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
            $result.Attribute = 'Script'
            $result.Reason    = 'the script does not exist.'
            return $result
        }
        $parameterRules = Get-ParameterRule -Path $ScriptPath
        if ($null -ne $parameterRules.ParseErrorLine) {
            $result.Attribute = 'Script'
            $result.Reason    = "the script can't be parsed (line $($parameterRules.ParseErrorLine))."
            return $result
        }
        if ($parameterRules.Error) {
            $result.Attribute = 'Check'
            $result.Reason    = 'the script could not be read.'
            return $result
        }
        $parameterRule = @($parameterRules.Parameters) | Where-Object { $_.Name -eq $ParameterName } | Select-Object -First 1
        if ($null -eq $parameterRule) {
            $result.Attribute = 'Script'
            $result.Reason    = "the script has no parameter named $ParameterName."
            return $result
        }

        $refusedBy      = $null
        $refusedReason  = $null
        $uncheckableBy  = $null
        $uncheckableWhy = $null
        $isSingle       = -not ($null -eq $Value -or $Value -is [System.Array] -or $Value -is [System.Collections.IDictionary])
        $typeKind       = $parameterRule.TypeKind

        #region Type
        $convertedValue = $Value
        switch ($typeKind) {
            'Int' {
                $number = 0
                $parsed = $isSingle -and -not ($Value -is [bool]) -and [int]::TryParse([System.Convert]::ToString($Value, $invariantCulture), [System.Globalization.NumberStyles]::Integer, $invariantCulture, [ref]$number)
                if ($parsed) { $convertedValue = $number } else { $refusedBy = 'Type'; $refusedReason = "the value isn't a whole number for the parameter's [int] type." }
            }
            'String' {
                if ($isSingle) { $convertedValue = [System.Convert]::ToString($Value, $invariantCulture) } else { $refusedBy = 'Type'; $refusedReason = "the value isn't a single value for the parameter's [string] type." }
            }
            'Switch' {
                if ($Value -is [System.Management.Automation.SwitchParameter]) { $convertedValue = $Value.IsPresent }
                elseif ($Value -is [bool]) { $convertedValue = $Value }
                else { $refusedBy = 'Type'; $refusedReason = "the value isn't `$true or `$false for the parameter's [switch] type." }
            }
            'Unknown' { $uncheckableBy = 'Type'; $uncheckableWhy = "the parameter's type isn't one this check knows." }
        }
        #endregion

        #region Attributes
        if (-not $refusedBy) {
            foreach ($attribute in @($parameterRule.Attributes)) {
                $attributeName = $attribute.Name
                if ($attribute.Kind -eq 'Ignored') { continue }
                if ($attribute.Kind -eq 'Unknown') {
                    if (-not $uncheckableBy) { $uncheckableBy = $attributeName; $uncheckableWhy = "the parameter has an attribute this check doesn't know, $attributeName." }
                    continue
                }
                if ($null -ne $uncheckableBy -and $uncheckableBy -eq 'Type') { continue }
                if (-not $attribute.Constant) {
                    if (-not $uncheckableBy) { $uncheckableBy = $attributeName; $uncheckableWhy = "an argument of the parameter's $attributeName isn't a constant." }
                    continue
                }
                $positionalValues = @($attribute.Positional)
                $namedValues      = $attribute.Named

                switch ($attributeName) {
                    'ValidateRange' {
                        # Plain assignment, so an argument that is a list stays a list.
                        $minimumArgument = $null
                        $maximumArgument = $null
                        if ($positionalValues.Count -ge 1) { $minimumArgument = $positionalValues[0] }
                        if ($positionalValues.Count -ge 2) { $maximumArgument = $positionalValues[1] }
                        $minimum = ConvertTo-OverrideInteger -Value $minimumArgument
                        $maximum = ConvertTo-OverrideInteger -Value $maximumArgument
                        if ($typeKind -ne 'Int' -or $positionalValues.Count -ne 2 -or $namedValues.get_Count() -gt 0 -or -not $minimum.Valid -or -not $maximum.Valid) {
                            if (-not $uncheckableBy) { $uncheckableBy = 'ValidateRange'; $uncheckableWhy = "the parameter's ValidateRange isn't a whole-number range on an [int]." }
                        } elseif ($convertedValue -lt $minimum.Value -or $convertedValue -gt $maximum.Value) {
                            $refusedBy = 'ValidateRange'; $refusedReason = "the value is outside the parameter's ValidateRange."
                        }
                    }
                    'ValidateSet' {
                        $ignoreCase = $true
                        $setIsKnown = $positionalValues.Count -gt 0
                        foreach ($namedKey in @($namedValues.get_Keys())) {
                            if ($namedKey -eq 'IgnoreCase' -and $namedValues[$namedKey] -is [bool]) { $ignoreCase = $namedValues[$namedKey] } else { $setIsKnown = $false }
                        }
                        if (-not $setIsKnown -or $typeKind -eq 'Switch' -or -not $isSingle) {
                            if (-not $uncheckableBy) { $uncheckableBy = 'ValidateSet'; $uncheckableWhy = "the parameter's ValidateSet takes a form this check doesn't know." }
                        } else {
                            $comparison = if ($ignoreCase) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
                            $valueText  = [System.Convert]::ToString($convertedValue, $invariantCulture)
                            $inSet = @($positionalValues | Where-Object { [string]::Equals([System.Convert]::ToString($_, $invariantCulture), $valueText, $comparison) }).Count -gt 0
                            if (-not $inSet) { $refusedBy = 'ValidateSet'; $refusedReason = "the value isn't in the parameter's ValidateSet." }
                        }
                    }
                    'ValidatePattern' {
                        $patternRegex = Get-OverridePatternRegex -Attribute $attribute
                        if ($null -eq $patternRegex -or $typeKind -eq 'Switch' -or -not $isSingle) {
                            if (-not $uncheckableBy) { $uncheckableBy = 'ValidatePattern'; $uncheckableWhy = "the parameter's ValidatePattern takes a form this check doesn't know." }
                        } elseif (-not $patternRegex.IsMatch([System.Convert]::ToString($convertedValue, $invariantCulture))) {
                            $refusedBy = 'ValidatePattern'; $refusedReason = "the value doesn't match the parameter's ValidatePattern."
                        }
                    }
                }
                if ($refusedBy) { break }
            }
        }
        #endregion

        if ($refusedBy) {
            $result.State = 'Refused'; $result.Attribute = $refusedBy; $result.Reason = $refusedReason
        } elseif ($uncheckableBy) {
            $result.State = 'Uncheckable'; $result.Attribute = $uncheckableBy; $result.Reason = $uncheckableWhy
        } else {
            $result.State = 'Valid'
        }
    } catch {
        $result.State     = 'Uncheckable'
        $result.Attribute = 'Check'
        $result.Reason    = "the check failed unexpectedly ($($_.Exception.GetType().FullName) at OverrideFile.ps1 line $($_.InvocationInfo.ScriptLineNumber))."
    }
    return $result
}

function Get-OverridePatternRegex {
    # The regular expression a ValidatePattern attribute from Get-ParameterRule applies:
    # its pattern with the attribute's default options, IgnoreCase, unless Options is
    # given. $null when the attribute takes a form this file doesn't know.
    [CmdletBinding()]
    [OutputType([regex])]
    param (
        [Parameter(Mandatory)]
        [object]$Attribute
    )
    $positionalValues = @($Attribute.Positional)
    $regexOptions     = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    $patternIsKnown   = [bool]$Attribute.Constant -and ($positionalValues.Count -eq 1) -and ($positionalValues[0] -is [string])
    foreach ($namedKey in @($Attribute.Named.get_Keys())) {
        $parsedOptions = $null
        if ($namedKey -eq 'Options') { $parsedOptions = $Attribute.Named[$namedKey] -as [System.Text.RegularExpressions.RegexOptions] }
        if ($null -eq $parsedOptions) { $patternIsKnown = $false } else { $regexOptions = $parsedOptions }
    }
    if (-not $patternIsKnown) { return $null }
    try { return [regex]::new([string]$positionalValues[0], $regexOptions) } catch { return $null }
}
#endregion

#region OVERRIDE.md generator
function Get-OverrideProfileKeyName {
    <#
    .SYNOPSIS
        Reads the build profile's key names and refused keys from a script's syntax tree,
        for ConvertTo-OverrideDocument. Runs nothing.
    .DESCRIPTION
        Finds exactly one assignment to $keyNames, a constant list of key names, and
        exactly one to $laterItemKeys, a hashtable literal (with or without [ordered])
        whose keys are constant names, anywhere in the script. Any other shape is an
        error, so the build-profile part of OVERRIDE.md is never generated from a guess.
        Never throws.
    .PARAMETER Path
        The script that holds both literals, such as include\BuildProfile.ps1.
    .OUTPUTS
        PSCustomObject with Path, Error ($null, or one problem per line), KeyNames and
        LaterItemKeys (string arrays, in the order written).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [AllowNull()]
        [string]$Path
    )
    $ErrorActionPreference = 'Stop'
    $problems       = [System.Collections.Generic.List[string]]::new()
    $keyNames       = [System.Collections.Generic.List[string]]::new()
    $laterItemKeys  = [System.Collections.Generic.List[string]]::new()
    $prefix         = "Script '$Path':"
    $keyNamePattern = '\A[A-Za-z][A-Za-z0-9]*\z'

    try {
        if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            $problems.Add("$prefix the file does not exist.")
        } else {
            $parseTokens = $null
            $parseErrors = $null
            $scriptAst   = [System.Management.Automation.Language.Parser]::ParseFile((Convert-Path -LiteralPath $Path), [ref]$parseTokens, [ref]$parseErrors)
            if (@($parseErrors).Count -gt 0) {
                $problems.Add("$prefix can't be parsed (line $($parseErrors[0].Extent.StartLineNumber)).")
            } else {
                $allAssignments = @($scriptAst.FindAll({
                    param ($candidateAst)
                    $candidateAst -is [System.Management.Automation.Language.AssignmentStatementAst]
                }, $true))
                $findAssignment = {
                    param ([string]$VariableName)
                    foreach ($assignmentAst in $allAssignments) {
                        if ($assignmentAst.Operator -eq [System.Management.Automation.Language.TokenKind]::Equals -and
                            $assignmentAst.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                            $assignmentAst.Left.VariablePath.UserPath -eq $VariableName) {
                            $assignmentAst
                        }
                    }
                }
                $expressionOf = {
                    param ($statementAst)
                    if ($statementAst -is [System.Management.Automation.Language.PipelineAst] -and @($statementAst.PipelineElements).Count -eq 1) { $statementAst = $statementAst.PipelineElements[0] }
                    if ($statementAst -is [System.Management.Automation.Language.CommandExpressionAst] -and @($statementAst.Redirections).Count -eq 0) { return $statementAst.Expression }
                    return $null
                }

                $keyNameAssignments = @(& $findAssignment 'keyNames')
                $keyNamesFound = $false
                if ($keyNameAssignments.Count -eq 1) {
                    $listAst = & $expressionOf $keyNameAssignments[0].Right
                    $listValue = $null
                    if ($null -ne $listAst) { try { $listValue = $listAst.SafeGetValue() } catch { $listValue = $null } }
                    $listItems = @($listValue)
                    if ($null -ne $listValue -and $listItems.Count -gt 0 -and @($listItems | Where-Object { -not ($_ -is [string]) -or $_ -cnotmatch $keyNamePattern }).Count -eq 0) {
                        foreach ($listItem in $listItems) { $keyNames.Add([string]$listItem) }
                        $keyNamesFound = $true
                    }
                }
                if (-not $keyNamesFound) {
                    $problems.Add("$prefix `$keyNames isn't in the shape the generator reads, one assignment of a constant list of key names.")
                }

                $laterAssignments = @(& $findAssignment 'laterItemKeys')
                $laterFound = $false
                if ($laterAssignments.Count -eq 1) {
                    $tableAst = & $expressionOf $laterAssignments[0].Right
                    if ($tableAst -is [System.Management.Automation.Language.ConvertExpressionAst] -and $tableAst.Type.TypeName.FullName -eq 'ordered') { $tableAst = $tableAst.Child }
                    if ($tableAst -is [System.Management.Automation.Language.HashtableAst]) {
                        $laterFound = $true
                        foreach ($keyValuePair in $tableAst.KeyValuePairs) {
                            if ($keyValuePair.Item1 -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $keyValuePair.Item1.Value -cmatch $keyNamePattern) {
                                $laterItemKeys.Add([string]$keyValuePair.Item1.Value)
                            } else {
                                $laterFound = $false
                            }
                        }
                    }
                }
                if (-not $laterFound) {
                    $problems.Add("$prefix `$laterItemKeys isn't in the shape the generator reads, one assignment of a hashtable literal keyed by constant names.")
                }
            }
        }
    } catch {
        $problems.Add("$prefix the read failed unexpectedly ($($_.Exception.GetType().FullName) at OverrideFile.ps1 line $($_.InvocationInfo.ScriptLineNumber)).")
    }

    $errorText = $null
    if ($problems.Count -gt 0) {
        $errorText = $problems -join [Environment]::NewLine
        $keyNames.Clear(); $laterItemKeys.Clear()
    }
    return [pscustomobject]@{
        Path          = $Path
        Error         = $errorText
        KeyNames      = [string[]]$keyNames.ToArray()
        LaterItemKeys = [string[]]$laterItemKeys.ToArray()
    }
}

function Get-OverrideOrdinalSorted {
    # The strings sorted ordinally, never in a culture's or a hashtable's order. The array
    # is returned whole, as one object.
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param (
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Text
    )
    $sortedText = [string[]]@($Text | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    [System.Array]::Sort($sortedText, [System.StringComparer]::Ordinal)
    return , $sortedText
}

function Test-OverrideDocumentText {
    # Returns $null when a catalog text can go in OVERRIDE.md, otherwise the problem: it
    # must be one line of printable ASCII and cite nothing shaped like a rule or decision
    # identifier, since the catalog and OVERRIDE.md both ship.
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [AllowNull()]
        [object]$Text,

        [Parameter(Mandatory)]
        [string]$Label
    )
    if (-not ($Text -is [string])) { return "$Label isn't a string." }
    if ([string]::IsNullOrWhiteSpace($Text)) { return "$Label is empty." }
    if ($Text -cmatch '[^\x20-\x7E]') { return "$Label isn't one line of printable ASCII." }
    if ($Text -cmatch '\b[A-Z]{3}-[0-9]{2}[a-z]?\b' -or $Text -cmatch '\bD-[0-9]{4}\b' -or $Text -cmatch '\bD-[A-Z]{4}-[A-Z][0-9]+\b') {
        return "$Label cites what looks like a rule or decision identifier."
    }
    return $null
}

function ConvertTo-OverrideSentence {
    # A text as a sentence: a full stop added when it ends without one. -Capitalize also
    # upper-cases the first letter, for the generator's own phrases only, since a catalog
    # text may start with a name such as build-lab.
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [string]$Text,

        [switch]$Capitalize
    )
    $sentence = $Text.Trim()
    if ($Capitalize -and $sentence.Length -gt 0) { $sentence = $sentence.Substring(0, 1).ToUpperInvariant() + $sentence.Substring(1) }
    if ($sentence -notmatch '[.!?]\z') { $sentence += '.' }
    return $sentence
}

function ConvertTo-OverrideDocumentValue {
    # A shipped value as OVERRIDE.md shows it: a string in backticks, a number, $true or
    # $false in backticks, a list joined with ", ". $null for a value it can't show.
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [AllowNull()]
        [object]$Value,

        [switch]$AsDataFileLiteral
    )
    $invariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
    if ($null -eq $Value -or $Value -is [System.Collections.IDictionary]) { return $null }
    if ($Value -is [bool]) {
        $boolText = if ($Value) { '$true' } else { '$false' }
        if ($AsDataFileLiteral) { return $boolText }
        return "``$boolText``"
    }
    if ($Value -is [string]) {
        if ($Value -cmatch '[^\x20-\x7E]') { return $null }
        if ($AsDataFileLiteral) { return "'" + $Value.Replace("'", "''") + "'" }
        if ($Value.Length -eq 0) { return 'an empty string' }
        if ($Value.Contains('`')) { return "'$Value'" }
        return "``$Value``"
    }
    if ($Value -is [System.Array]) {
        $itemTexts = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $Value) {
            if ($item -is [System.Array]) { return $null }
            $itemText = ConvertTo-OverrideDocumentValue -Value $item -AsDataFileLiteral:$AsDataFileLiteral
            if ($null -eq $itemText) { return $null }
            $itemTexts.Add($itemText)
        }
        if ($AsDataFileLiteral) { return '@(' + ($itemTexts -join ', ') + ')' }
        if ($itemTexts.Count -eq 0) { return 'an empty list' }
        return ($itemTexts -join ', ')
    }
    foreach ($numberType in @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64], [double], [decimal])) {
        if ($Value -is $numberType) { return [System.Convert]::ToString($Value, $invariantCulture) }
    }
    return $null
}

function Get-OverrideParameterRuleText {
    # The permitted values of a parameter from Get-ParameterRule, in words. Returns Text
    # and Problem; Text is $null when an attribute or type can't be put in words.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [object]$Parameter
    )
    $result = [pscustomobject]@{ Text = $null; Problem = $null }
    $baseText = switch ($Parameter.TypeKind) {
        'Int'    { 'a whole number' }
        'String' { 'text' }
        'Switch' { '$true or $false' }
        'Object' { 'any value' }
        default  { $null }
    }
    if ($null -eq $baseText) { $result.Problem = "its type isn't one the generator knows."; return $result }
    $rangeText   = $null
    $setText     = $null
    $patternText = $null
    foreach ($attribute in @($Parameter.Attributes)) {
        if ($attribute.Kind -eq 'Ignored') { continue }
        if ($attribute.Kind -eq 'Unknown') { $result.Problem = "it has an attribute the generator doesn't know, $($attribute.Name)."; return $result }
        if (-not $attribute.Constant) { $result.Problem = "an argument of its $($attribute.Name) isn't a constant."; return $result }
        $positionalValues = @($attribute.Positional)
        switch ($attribute.Name) {
            'ValidateRange' {
                # Plain assignment, so an argument that is a list stays a list.
                $minimumArgument = $null
                $maximumArgument = $null
                if ($positionalValues.Count -ge 1) { $minimumArgument = $positionalValues[0] }
                if ($positionalValues.Count -ge 2) { $maximumArgument = $positionalValues[1] }
                $minimum = ConvertTo-OverrideInteger -Value $minimumArgument
                $maximum = ConvertTo-OverrideInteger -Value $maximumArgument
                if ($Parameter.TypeKind -ne 'Int' -or $positionalValues.Count -ne 2 -or -not $minimum.Valid -or -not $maximum.Valid) {
                    $result.Problem = "its ValidateRange isn't a whole-number range on an [int]."; return $result
                }
                $rangeText = "from $($minimum.Value) to $($maximum.Value)"
            }
            'ValidateSet' {
                if ($positionalValues.Count -eq 0) { $result.Problem = 'its ValidateSet has no values.'; return $result }
                $setText = 'one of ' + (@($positionalValues | ForEach-Object { [System.Convert]::ToString($_, [System.Globalization.CultureInfo]::InvariantCulture) }) -join ', ')
                if ($attribute.Named.ContainsKey('IgnoreCase') -and $attribute.Named['IgnoreCase'] -eq $false) { $setText += ', matched with case' }
            }
            'ValidatePattern' {
                $patternRegex = Get-OverridePatternRegex -Attribute $attribute
                if ($null -eq $patternRegex) { $result.Problem = "its ValidatePattern takes a form the generator doesn't know."; return $result }
                $patternSource = $patternRegex.ToString()
                $quotedPattern = if ($patternSource.Contains('`')) { "'$patternSource'" } else { "``$patternSource``" }
                $patternText = "matching the pattern $quotedPattern"
                if (($patternRegex.Options -band [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) -ne 0) { $patternText += ', ignoring case' }
            }
        }
    }
    if ($setText) {
        $ruleText = $setText
        if ($rangeText) { $ruleText += ", $rangeText" }
        if ($patternText) { $ruleText += ", $patternText" }
    } else {
        $ruleText = $baseText
        if ($rangeText) { $ruleText += " $rangeText" }
        if ($patternText) { $ruleText += " $patternText" }
        if ($ruleText -ceq 'text') { $ruleText = 'any text' }
    }
    $result.Text = $ruleText
    return $result
}

function Get-OverrideTablePairCount {
    # The problem when any hashtable inside the value holds 500 pairs or more, else $null.
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Label
    )
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.get_Count() -ge 500) { return "$Label holds $($Value.get_Count()) pairs. A table in the catalog must hold fewer than 500." }
        foreach ($tableKey in @($Value.get_Keys())) {
            $problem = Get-OverrideTablePairCount -Value $Value[$tableKey] -Label "$Label.$tableKey"
            if ($problem) { return $problem }
        }
    } elseif ($Value -is [System.Array]) {
        foreach ($item in $Value) {
            $problem = Get-OverrideTablePairCount -Value $item -Label $Label
            if ($problem) { return $problem }
        }
    }
    return $null
}

function Test-OverrideDocumentProse {
    # Returns one problem per prose line of a Markdown text that holds a semicolon, or a
    # colon anywhere but as the line's last character. Code fences, inline code spans,
    # link targets, bare URLs, table rows and headings aren't prose and are skipped. A
    # colon at a line's end introduces the list or code block below it, which is allowed.
    [CmdletBinding()]
    [OutputType([string[]])]
    param (
        [AllowNull()]
        [string]$Text
    )
    $problems    = [System.Collections.Generic.List[string]]::new()
    $fenceMarker = $null
    $lineNumber  = 0
    foreach ($line in @(([string]$Text) -split "`n")) {
        $lineNumber++
        $fenceMatch = [regex]::Match($line, '\A {0,3}(`{3,}|~{3,})')
        if ($null -ne $fenceMarker) {
            if ($fenceMatch.Success -and $fenceMatch.Groups[1].Value[0] -eq $fenceMarker[0] -and $fenceMatch.Groups[1].Value.Length -ge $fenceMarker.Length) { $fenceMarker = $null }
            continue
        }
        if ($fenceMatch.Success) { $fenceMarker = $fenceMatch.Groups[1].Value; continue }
        if ($line -match '\A {0,3}#' -or $line -match '\A\s*\|') { continue }
        $proseText = $line -replace '`[^`]*`', '' -replace '\]\([^)]*\)', ']' -replace 'https?://\S+', ''
        $proseText = $proseText.TrimEnd()
        if ($proseText.Contains(';')) {
            $problems.Add("the generated text has a semicolon in prose on line $lineNumber.")
        }
        $colonIndex = $proseText.IndexOf(':')
        if ($colonIndex -ge 0 -and $colonIndex -lt $proseText.Length - 1) {
            $problems.Add("the generated text has a colon inside a sentence on line $lineNumber. End the sentence instead.")
        }
    }
    return [string[]]$problems.ToArray()
}

function ConvertTo-OverrideDocument {
    <#
    .SYNOPSIS
        Returns the whole text of a project's OVERRIDE.md, generated from its catalog.
    .DESCRIPTION
        Reads no file, clock or environment, so the same inputs always give the same
        text: ASCII, LF line endings, no BOM, one blank line between blocks, one final
        LF, keys and every list sorted ordinally, numbers in the invariant culture, and a
        pipe inside a table cell written \|. The parts, in order: the title and the
        generated-file line, where the file goes (with an example from the first two
        non-secret keys that have a shipped value), precedence, what a run logs, the
        Settings table, the build profile (when the catalog's Document names one), the
        retired keys, the CSV replacements (when present), what isn't covered, security,
        and links to the other projects in Siblings.

        The catalog is checked as the reader checks it, and then as the generator needs:
        Project, Document and Document.NotCovered present; every key with Shipped or
        ShippedText and with ShippedReason; a secret key with ShippedText, never shown
        from Shipped; a Variable or Constant key with Summary, and a Parameter key
        without one; an External rule with a Description; a Parameter key with no Rule
        found in ParameterRule with attributes the generator can put in words; every
        text one line of printable ASCII citing nothing shaped like a rule or decision
        identifier; and no table of 500 pairs or more. Any problem returns Error and no
        text. Never throws.
    .PARAMETER Catalog
        The catalog's data, as Import-PowerShellDataFile returns it.
    .PARAMETER ParameterRule
        Get-ParameterRule's result for each script whose parameters the catalog's
        Parameter keys set.
    .PARAMETER BuildProfileKey
        Get-OverrideProfileKeyName's result for the script the catalog's
        Document.BuildProfile.Script names. Pass it only for a catalog with a build
        profile.
    .OUTPUTS
        PSCustomObject with Text ($null when Error is set) and Error ($null, or one
        problem per line).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [AllowNull()]
        [object]$Catalog,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$ParameterRule,

        [AllowNull()]
        [object]$BuildProfileKey
    )
    $ErrorActionPreference = 'Stop'
    $problems = [System.Collections.Generic.List[string]]::new()
    $prefix   = 'Override document:'
    $lines    = [System.Collections.Generic.List[string]]::new()

    try {
        $catalogResult = ConvertFrom-OverrideCatalogData -CatalogData $Catalog -Prefix 'Override catalog:'
        if ($catalogResult.Error) {
            foreach ($catalogLine in ($catalogResult.Error -split [Environment]::NewLine)) { $problems.Add($catalogLine) }
        } else {
            #region Check what the generator needs
            $sizeProblem = Get-OverrideTablePairCount -Value $Catalog -Label 'the catalog'
            if ($sizeProblem) { $problems.Add("$prefix $sizeProblem") }

            $projectProblem = Test-OverrideDocumentText -Text $catalogResult.Project -Label 'Project'
            if ($null -eq $catalogResult.Project) { $problems.Add("$prefix the catalog has no Project.") }
            elseif ($projectProblem) { $problems.Add("$prefix $projectProblem") }

            $documentData = $catalogResult.Document
            $notCoveredRows = @()
            $csvRows        = @()
            $securityLines  = @()
            $hasBuildProfile = $false
            if ($null -eq $documentData) {
                $problems.Add("$prefix the catalog has no Document.")
            } else {
                if (-not $documentData.ContainsKey('NotCovered')) {
                    $problems.Add("$prefix Document has no NotCovered. Use @() when nothing is left out.")
                } else {
                    $notCoveredRows = @($documentData['NotCovered'])
                    foreach ($notCoveredRow in $notCoveredRows) {
                        if (-not ($notCoveredRow -is [hashtable]) -or $notCoveredRow.get_Count() -ne 2 -or -not $notCoveredRow.ContainsKey('Name') -or -not $notCoveredRow.ContainsKey('Reason')) {
                            $problems.Add("$prefix Document.NotCovered holds a row that isn't @{ Name = '...'; Reason = '...' }.")
                            continue
                        }
                        foreach ($fieldName in @('Name', 'Reason')) {
                            $textProblem = Test-OverrideDocumentText -Text $notCoveredRow[$fieldName] -Label "Document.NotCovered $fieldName"
                            if ($textProblem) { $problems.Add("$prefix $textProblem") }
                        }
                    }
                }
                if ($documentData.ContainsKey('CsvReplacements')) {
                    $csvRows = @($documentData['CsvReplacements'])
                    foreach ($csvRow in $csvRows) {
                        if (-not ($csvRow -is [hashtable]) -or $csvRow.get_Count() -ne 3 -or -not $csvRow.ContainsKey('File') -or -not $csvRow.ContainsKey('Holds') -or -not $csvRow.ContainsKey('Headers')) {
                            $problems.Add("$prefix Document.CsvReplacements holds a row that isn't @{ File = '...'; Holds = '...'; Headers = @('...') }.")
                            continue
                        }
                        foreach ($fieldName in @('File', 'Holds')) {
                            $textProblem = Test-OverrideDocumentText -Text $csvRow[$fieldName] -Label "Document.CsvReplacements $fieldName"
                            if ($textProblem) { $problems.Add("$prefix $textProblem") }
                        }
                        foreach ($headerName in @($csvRow['Headers'])) {
                            $textProblem = Test-OverrideDocumentText -Text $headerName -Label 'Document.CsvReplacements Headers'
                            if ($textProblem) { $problems.Add("$prefix $textProblem") }
                        }
                    }
                }
                if ($documentData.ContainsKey('Security')) {
                    $securityLines = @($documentData['Security'])
                    foreach ($securityLine in $securityLines) {
                        $textProblem = Test-OverrideDocumentText -Text $securityLine -Label 'Document.Security'
                        if ($textProblem) { $problems.Add("$prefix $textProblem") }
                    }
                }
                if ($documentData.ContainsKey('BuildProfile')) {
                    $hasBuildProfile = $true
                    $buildProfileData = $documentData['BuildProfile']
                    if (-not ($buildProfileData -is [hashtable]) -or $buildProfileData.get_Count() -ne 1 -or -not ($buildProfileData['Script'] -is [string])) {
                        $problems.Add("$prefix Document.BuildProfile isn't @{ Script = '<path of the script that holds the profile keys>' }.")
                    }
                }
            }

            $profileKeyNames = @()
            $laterItemNames  = @()
            if ($hasBuildProfile) {
                if ($null -eq $BuildProfileKey) {
                    $problems.Add("$prefix the catalog's Document names a build profile, and no BuildProfileKey was given.")
                } elseif ($BuildProfileKey.Error) {
                    foreach ($profileLine in ($BuildProfileKey.Error -split [Environment]::NewLine)) { $problems.Add("$prefix $profileLine") }
                } else {
                    $profileKeyNames = @($BuildProfileKey.KeyNames)
                    $laterItemNames  = @($BuildProfileKey.LaterItemKeys)
                    foreach ($profileKeyName in $profileKeyNames) {
                        if (-not ($catalogResult.Settings.get_Keys() -ccontains $profileKeyName) -or $catalogResult.Settings[$profileKeyName].Target -ne 'Variable') {
                            $problems.Add("$prefix the build profile key $profileKeyName isn't a Variable key in the catalog.")
                        }
                    }
                }
            } elseif ($null -ne $BuildProfileKey) {
                $problems.Add("$prefix a BuildProfileKey was given, and the catalog's Document names no build profile.")
            }

            $parameterEntries = [System.Collections.Generic.List[object]]::new()
            foreach ($scriptRule in @($ParameterRule | Where-Object { $null -ne $_ })) {
                if ($scriptRule.Error) { $problems.Add("$prefix $($scriptRule.Error)"); continue }
                foreach ($parameterEntry in @($scriptRule.Parameters)) { $parameterEntries.Add($parameterEntry) }
            }

            $keyNames = Get-OverrideOrdinalSorted -Text @($catalogResult.Settings.get_Keys())
            $permittedTextOf = @{}
            foreach ($keyName in $keyNames) {
                $entry = $catalogResult.Settings[$keyName]
                $label = "key $keyName"
                if (-not $entry.HasShipped -and $null -eq $entry.ShippedText) { $problems.Add("$prefix $label has neither Shipped nor ShippedText.") }
                if ($entry.Secret -and $null -eq $entry.ShippedText) { $problems.Add("$prefix $label is secret and has no ShippedText. A secret default is never shown from Shipped.") }
                if ($null -eq $entry.ShippedReason) { $problems.Add("$prefix $label has no ShippedReason.") }
                if ($entry.Target -eq 'Parameter' -and $null -ne $entry.Summary) { $problems.Add("$prefix $label is a Parameter key and has a Summary. Its row points at the parameter instead.") }
                if ($entry.Target -ne 'Parameter' -and $null -eq $entry.Summary) { $problems.Add("$prefix $label is a $($entry.Target) key and has no Summary.") }
                foreach ($textField in @('Summary', 'ShippedText', 'ShippedReason', 'OverrideNote', 'ValuesNote')) {
                    if ($null -ne $entry.$textField) {
                        $textProblem = Test-OverrideDocumentText -Text $entry.$textField -Label "$label $textField"
                        if ($textProblem) { $problems.Add("$prefix $textProblem") }
                    }
                }
                if (-not $entry.Secret -and $entry.HasShipped -and $null -eq $entry.ShippedText -and $null -eq (ConvertTo-OverrideDocumentValue -Value $entry.Shipped)) {
                    $problems.Add("$prefix $label has a Shipped value OVERRIDE.md can't show. Use a string, a number, `$true, `$false or a list of those, or give ShippedText.")
                }

                if ($null -ne $entry.Rule) {
                    foreach ($ruleToCheck in @($entry.Rule, $(if ($entry.Rule['Type'] -eq 'List') { $entry.Rule['ItemRule'] }))) {
                        if ($null -eq $ruleToCheck) { continue }
                        if ($ruleToCheck['Type'] -eq 'External' -and -not $ruleToCheck.ContainsKey('Description')) {
                            $problems.Add("$prefix $label has an External rule with no Description.")
                        }
                        if ($ruleToCheck.ContainsKey('Description')) {
                            $textProblem = Test-OverrideDocumentText -Text $ruleToCheck['Description'] -Label "$label Rule Description"
                            if ($textProblem) { $problems.Add("$prefix $textProblem") }
                        }
                    }
                    $permittedTextOf[$keyName] = Get-OverrideRuleText -Rule $entry.Rule
                } else {
                    $matchingParameters = @($parameterEntries | Where-Object { $_.Name -eq $entry.Name })
                    if ($matchingParameters.Count -eq 0) {
                        $problems.Add("$prefix $label sets the parameter -$($entry.Name), which no script in ParameterRule declares.")
                    } else {
                        $parameterTexts = @($matchingParameters | ForEach-Object { Get-OverrideParameterRuleText -Parameter $_ })
                        $parameterProblem = @($parameterTexts | Where-Object { $_.Problem }) | Select-Object -First 1
                        $distinctTexts = @($parameterTexts | ForEach-Object { $_.Text } | Sort-Object -Unique -CaseSensitive)
                        if ($null -ne $parameterProblem) {
                            $problems.Add("$prefix $label sets the parameter -$($entry.Name), and $($parameterProblem.Problem) Give the key a Rule.")
                        } elseif ($distinctTexts.Count -ne 1) {
                            $problems.Add("$prefix $label sets the parameter -$($entry.Name), which two scripts declare with different checks. Give the key a Rule.")
                        } else {
                            $permittedTextOf[$keyName] = $distinctTexts[0]
                        }
                    }
                }
            }

            $siblingNames = @()
            if ($Catalog.ContainsKey('Siblings')) {
                $siblingNames = Get-OverrideOrdinalSorted -Text @($Catalog['Siblings'].get_Keys())
                foreach ($siblingName in $siblingNames) {
                    if ($siblingName -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._-]*\z') { $problems.Add("$prefix the sibling project name '$siblingName' can't go in a link.") }
                }
            }
            foreach ($retiredName in @($catalogResult.Retired.get_Keys())) {
                $textProblem = Test-OverrideDocumentText -Text $catalogResult.Retired[$retiredName].Version -Label "retired key $retiredName Version"
                if ($textProblem) { $problems.Add("$prefix $textProblem") }
            }
            #endregion

            if ($problems.Count -eq 0) {
                $cell = { param ([string]$CellText) $CellText.Replace('|', '\|') }

                #region Fixed parts
                $lines.Add('# Overrides')
                $lines.Add('')
                $lines.Add('This file is generated from `include\override-catalog.psd1`. Don''t edit it. A change goes in the catalog, and this file is generated again.')
                $lines.Add('')
                $lines.Add('## Where the file goes')
                $lines.Add('')
                $lines.Add('Put your settings in `overrides\overrides.psd1` in the project folder. Git ignores that folder, so an upgrade never touches it. The file is a PowerShell data file holding one hashtable of constant values. Each value is a quoted string, a number, `$true`, `$false` or a list of those. Save it as UTF-8 with a BOM when it holds non-ASCII text. A key you leave out takes its shipped value.')
                $exampleLines = [System.Collections.Generic.List[string]]::new()
                foreach ($keyName in $keyNames) {
                    if ($exampleLines.Count -ge 2) { break }
                    $entry = $catalogResult.Settings[$keyName]
                    if ($entry.Secret -or -not $entry.HasShipped) { continue }
                    $literalText = ConvertTo-OverrideDocumentValue -Value $entry.Shipped -AsDataFileLiteral
                    if ($null -ne $literalText) { $exampleLines.Add("    $keyName = $literalText") }
                }
                if ($exampleLines.Count -gt 0) {
                    $lines.Add('')
                    $lines.Add('For example, with settings at their shipped values:')
                    $lines.Add('')
                    $lines.Add('```powershell')
                    $lines.Add('@{')
                    foreach ($exampleLine in $exampleLines) { $lines.Add($exampleLine) }
                    $lines.Add('}')
                    $lines.Add('```')
                }
                $lines.Add('')
                $lines.Add('To make the file from an older copy of the project, see [UPGRADE.md](UPGRADE.md).')
                $lines.Add('')
                $lines.Add('## Precedence')
                $lines.Add('')
                $lines.Add('A value given on the command line wins. Without one, a build profile''s value applies, for the keys whose row says a profile sets them. Without that, the override file''s value applies, and without that, the shipped value. A command-line value that differs from the override file''s is logged as INFO.')
                $lines.Add('')
                $lines.Add('## What a run logs')
                $lines.Add('')
                $lines.Add('With no override file, a run logs one INFO line saying so, and the shipped settings apply. With one, it logs one INFO line naming the file, its SHA-256 and each setting it applied, with secret values shown as `<set>`. A key left empty gives a WARN, and its shipped value applies. A run stops when the file can''t be read, holds a value that isn''t a constant, holds an unknown key, or holds a value outside a key''s permitted values.')
                #endregion

                #region Settings
                $lines.Add('')
                $lines.Add('## Settings')
                $lines.Add('')
                $lines.Add('| Key | What it changes | How to override | Default | Permitted values | Why this default | Secret |')
                $lines.Add('|---|---|---|---|---|---|---|')
                foreach ($keyName in $keyNames) {
                    $entry = $catalogResult.Settings[$keyName]
                    if ($entry.Target -eq 'Parameter') {
                        $changesText = "The default of ``-$($entry.Name)``, described in the README and the script's help."
                    } else {
                        $changesText = ConvertTo-OverrideSentence -Text $entry.Summary
                    }
                    $howText = "``overrides\overrides.psd1``, key ``$keyName``."
                    if ($null -ne $entry.OverrideNote) { $howText += ' ' + (ConvertTo-OverrideSentence -Text $entry.OverrideNote) }
                    if ($profileKeyNames -ccontains $keyName) { $howText += ' A build profile also sets it, and the profile wins.' }
                    if ($entry.Target -eq 'Parameter') { $howText += " ``-$($entry.Name)`` on the command line also sets it, and the command line wins." }
                    if ($null -ne $entry.ShippedText) {
                        $defaultText = $entry.ShippedText
                    } else {
                        $defaultText = ConvertTo-OverrideDocumentValue -Value $entry.Shipped
                    }
                    $permittedText = ConvertTo-OverrideSentence -Text $permittedTextOf[$keyName] -Capitalize
                    if ($null -ne $entry.ValuesNote) { $permittedText += ' ' + (ConvertTo-OverrideSentence -Text $entry.ValuesNote) }
                    $reasonText = ConvertTo-OverrideSentence -Text $entry.ShippedReason
                    $secretText = if ($entry.Secret) { 'yes' } else { 'no' }
                    $rowCells = @("``$keyName``", $changesText, $howText, $defaultText, $permittedText, $reasonText, $secretText) | ForEach-Object { & $cell $_ }
                    $lines.Add('| ' + (@($rowCells) -join ' | ') + ' |')
                }
                #endregion

                #region Build profile
                if ($hasBuildProfile) {
                    $lines.Add('')
                    $lines.Add('## Build profile')
                    $lines.Add('')
                    $lines.Add('A build profile, `include\build-profile.psd1`, sets the keys below for one build, and wins over the override file. How to use one is in the README. A key the profile leaves out takes the override file''s value, then the shipped value, with one INFO line. An empty key falls back the same way, with a WARN.')
                    $lines.Add('')
                    $lines.Add('The keys a build profile takes, each with its permitted values under [Settings](#settings):')
                    $lines.Add('')
                    foreach ($profileKeyName in (Get-OverrideOrdinalSorted -Text $profileKeyNames)) { $lines.Add("- [``$profileKeyName``](#settings)") }
                    if ($laterItemNames.Count -gt 0) {
                        $lines.Add('')
                        $lines.Add('A build profile refuses these keys until their feature exists, so that a profile never looks as if it did something the build didn''t:')
                        $lines.Add('')
                        foreach ($laterItemName in (Get-OverrideOrdinalSorted -Text $laterItemNames)) { $lines.Add("- ``$laterItemName``") }
                    }
                }
                #endregion

                #region Retired keys, CSV replacements, not covered, security, other projects
                $lines.Add('')
                $lines.Add('## Retired keys')
                $lines.Add('')
                $retiredNames = Get-OverrideOrdinalSorted -Text @($catalogResult.Retired.get_Keys())
                if ($retiredNames.Count -eq 0) {
                    $lines.Add('None.')
                } else {
                    $lines.Add('| Key | Retired in | What happens |')
                    $lines.Add('|---|---|---|')
                    foreach ($retiredName in $retiredNames) {
                        $retiredEntry = $catalogResult.Retired[$retiredName]
                        $whatHappens = if ($null -eq $retiredEntry.RenamedTo) { 'Removed. The key is ignored, with a WARN.' } else { "Renamed ``$($retiredEntry.RenamedTo)``. Its value is applied as ``$($retiredEntry.RenamedTo)``, with a WARN." }
                        $rowCells = @("``$retiredName``", $retiredEntry.Version, $whatHappens) | ForEach-Object { & $cell $_ }
                        $lines.Add('| ' + (@($rowCells) -join ' | ') + ' |')
                    }
                }

                if ($null -ne $documentData -and $documentData.ContainsKey('CsvReplacements')) {
                    $lines.Add('')
                    $lines.Add('## CSV replacements')
                    $lines.Add('')
                    $lines.Add('A file at `overrides\config\<name>.csv` replaces `config\<name>.csv` whole, for every script that reads it. A replaced file no longer receives later shipped changes to that file.')
                    $lines.Add('')
                    $lines.Add('| File | What it holds | Required headers |')
                    $lines.Add('|---|---|---|')
                    $csvByFile = @{}
                    foreach ($csvRow in $csvRows) { $csvByFile[[string]$csvRow['File']] = $csvRow }
                    foreach ($csvFile in (Get-OverrideOrdinalSorted -Text @($csvByFile.get_Keys()))) {
                        $csvRow = $csvByFile[$csvFile]
                        $headerText = (@($csvRow['Headers']) | ForEach-Object { "``$_``" }) -join ', '
                        $rowCells = @("``$csvFile``", (ConvertTo-OverrideSentence -Text $csvRow['Holds']), $headerText) | ForEach-Object { & $cell $_ }
                        $lines.Add('| ' + (@($rowCells) -join ' | ') + ' |')
                    }
                }

                $lines.Add('')
                $lines.Add('## Not covered')
                $lines.Add('')
                if ($notCoveredRows.Count -eq 0) {
                    $lines.Add('None.')
                } else {
                    $lines.Add('These can''t be set in the override file.')
                    $lines.Add('')
                    $lines.Add('| Setting | Why it isn''t covered |')
                    $lines.Add('|---|---|')
                    $notCoveredByName = @{}
                    foreach ($notCoveredRow in $notCoveredRows) { $notCoveredByName[[string]$notCoveredRow['Name']] = $notCoveredRow }
                    foreach ($notCoveredName in (Get-OverrideOrdinalSorted -Text @($notCoveredByName.get_Keys()))) {
                        $rowCells = @("``$notCoveredName``", (ConvertTo-OverrideSentence -Text $notCoveredByName[$notCoveredName]['Reason'])) | ForEach-Object { & $cell $_ }
                        $lines.Add('| ' + (@($rowCells) -join ' | ') + ' |')
                    }
                }

                $lines.Add('')
                $lines.Add('## Security')
                $lines.Add('')
                $securityText = 'Secret values sit in plain text in `overrides\overrides.psd1` on disk, and are masked only in logs.'
                foreach ($securityLine in $securityLines) { $securityText += ' ' + (ConvertTo-OverrideSentence -Text $securityLine) }
                $lines.Add($securityText)

                if ($siblingNames.Count -gt 0) {
                    $lines.Add('')
                    $lines.Add('## Other projects')
                    $lines.Add('')
                    $lines.Add('Each lab project documents its own overrides:')
                    $lines.Add('')
                    foreach ($siblingName in $siblingNames) { $lines.Add("- [$siblingName](https://github.com/0x44616e69656c/$siblingName/blob/main/OVERRIDE.md)") }
                }
                #endregion
            }
        }
    } catch {
        $problems.Add("$prefix the generator failed unexpectedly ($($_.Exception.GetType().FullName) at OverrideFile.ps1 line $($_.InvocationInfo.ScriptLineNumber)).")
    }

    $documentText = $null
    if ($problems.Count -eq 0) {
        $documentText = ($lines -join "`n") + "`n"
        if ($documentText -cmatch '[^\x0A\x20-\x7E]') {
            $problems.Add("$prefix the generated text holds a character that isn't printable ASCII.")
            $documentText = $null
        } else {
            $proseProblems = @(Test-OverrideDocumentProse -Text $documentText)
            if ($proseProblems.Count -gt 0) {
                foreach ($proseProblem in $proseProblems) { $problems.Add("$prefix $proseProblem") }
                $documentText = $null
            }
        }
    }
    $errorText = $null
    if ($problems.Count -gt 0) { $errorText = $problems -join [Environment]::NewLine }
    return [pscustomobject]@{
        Text  = $documentText
        Error = $errorText
    }
}
#endregion

#region Release table writer
function Get-OverrideCsvHash {
    <#
    .SYNOPSIS
        Returns the SHA-256 of a CSV file's text, the same for every line-ending form a
        clone or an editor can give it.
    .DESCRIPTION
        Decodes the bytes as UTF-8, refusing bytes that aren't UTF-8 text, drops a
        leading byte order mark, turns CRLF into LF, and cuts the trailing line feeds
        to exactly one, adding one when there is none. The SHA-256 of that text's UTF-8
        bytes is returned as 64 lower-case hex digits. An empty file hashes as a single
        line feed. The release table, the migration and the drift test all compare CSV
        files through this one function, so they can't disagree. Never throws.
    .PARAMETER Bytes
        The file's bytes, as [System.IO.File]::ReadAllBytes or git returns them.
    .OUTPUTS
        PSCustomObject with Sha256 ($null when Error is set) and Error ($null, or why the
        bytes couldn't be hashed).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [AllowNull()]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )
    $ErrorActionPreference = 'Stop'
    $result = [pscustomobject]@{ Sha256 = $null; Error = $null }
    try {
        if ($null -eq $Bytes) { $Bytes = [byte[]]@() }
        $strictEncoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false, $true
        $csvText = $null
        try { $csvText = $strictEncoding.GetString($Bytes) } catch { $csvText = $null }
        if ($null -eq $csvText) {
            $result.Error = "CSV hash: the bytes aren't UTF-8 text."
            return $result
        }
        if ($csvText.Length -gt 0 -and [int]$csvText[0] -eq 0xFEFF) { $csvText = $csvText.Substring(1) }
        $csvText = $csvText.Replace("`r`n", "`n").TrimEnd([char]"`n") + "`n"
        $hashAlgorithm = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $hashAlgorithm.ComputeHash($strictEncoding.GetBytes($csvText))
        } finally {
            $hashAlgorithm.Dispose()
        }
        $result.Sha256 = ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
    } catch {
        $result.Error = "CSV hash: the hash failed unexpectedly ($($_.Exception.GetType().FullName) at OverrideFile.ps1 line $($_.InvocationInfo.ScriptLineNumber))."
    }
    return $result
}

function Get-OverrideChangedDefault {
    <#
    .SYNOPSIS
        Returns one INFO line for each setting whose shipped default changed since the
        previous release, when this run left it at the shipped default.
    .DESCRIPTION
        Compares each key's current shipped value, the catalog's Shipped, with its
        Constant in the release table's newest entry below CurrentVersion, compared as
        [version]. The table also holds the running release's own entry, which is why
        the comparison stops below CurrentVersion. A run between releases, whose version
        has no entry yet, compares with the newest entry. Because each release adds its
        own entry, a changed default is reported for one release only.

        Left out, with no line: a secret key, which is never compared and of which
        nothing is printed; a key in SetKey, whose value this run took from the command
        line, a build profile or the override file; a key with no Shipped value; a key
        the older entry doesn't hold; and an older value stored as Expression, NoDefault
        or Sha256 rather than Constant. Lists compare item by item in order, and strings
        ordinally. A missing or empty release table, or one with no entry below
        CurrentVersion, gives nothing and no error. Reads no file and never throws.
    .PARAMETER Catalog
        The catalog's data, as Import-PowerShellDataFile returns it.
    .PARAMETER ReleaseTable
        The data of include\release-values.psd1, as Import-PowerShellDataFile returns
        it, or $null when the file is missing.
    .PARAMETER CurrentVersion
        The version of the running release, such as its scripts' header version.
    .PARAMETER SetKey
        The catalog keys whose value this run didn't take from the shipped default.
    .OUTPUTS
        PSCustomObject with Info (one line per changed key, in key order), Changed (Key,
        OldValue, NewValue, Release), Warnings and Error ($null, or one problem per
        line).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [AllowNull()]
        [object]$Catalog,

        [AllowNull()]
        [object]$ReleaseTable,

        [AllowNull()]
        [string]$CurrentVersion,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$SetKey
    )
    $ErrorActionPreference = 'Stop'
    $infoLines    = [System.Collections.Generic.List[string]]::new()
    $warningLines = [System.Collections.Generic.List[string]]::new()
    $problems     = [System.Collections.Generic.List[string]]::new()
    $changedKeys  = [System.Collections.Generic.List[object]]::new()
    $prefix       = 'Changed default:'
    $versionPattern = '\A[0-9]+\.[0-9]+(\.[0-9]+){0,2}\z'

    try {
        $catalogResult = ConvertFrom-OverrideCatalogData -CatalogData $Catalog -Prefix 'Override catalog:'
        if ($catalogResult.Error) {
            foreach ($catalogLine in ($catalogResult.Error -split [Environment]::NewLine)) { $problems.Add($catalogLine) }
        } elseif ([string]::IsNullOrWhiteSpace($CurrentVersion) -or $CurrentVersion -cnotmatch $versionPattern) {
            $problems.Add("$prefix CurrentVersion isn't a version such as 2.1.0.")
        } elseif ($null -ne $ReleaseTable -and -not ($ReleaseTable -is [System.Collections.IDictionary])) {
            $problems.Add("$prefix the release table isn't one hashtable.")
        } elseif ($null -ne $ReleaseTable) {
            $releasesKey = Find-OverrideDictionaryKey -Dictionary $ReleaseTable -Key 'Releases'
            $releases = $null
            if ($null -ne $releasesKey) { $releases = $ReleaseTable[$releasesKey] }
            if ($null -ne $releases -and -not ($releases -is [System.Collections.IDictionary])) {
                $problems.Add("$prefix the release table's Releases isn't a table.")
            } elseif ($null -ne $releases) {
                #region The newest entry below the running release
                $currentVersionValue = [version]$CurrentVersion
                $olderVersion = $null
                $olderKey     = $null
                foreach ($releaseKey in @($releases.get_Keys())) {
                    if (-not ($releaseKey -is [string]) -or $releaseKey -cnotmatch $versionPattern) {
                        $problems.Add("$prefix the release table has a release key that isn't a version.")
                        continue
                    }
                    $releaseVersion = [version]$releaseKey
                    if ($releaseVersion -ge $currentVersionValue) { continue }
                    if ($null -eq $olderVersion -or $releaseVersion -gt $olderVersion) {
                        $olderVersion = $releaseVersion
                        $olderKey     = $releaseKey
                    }
                }
                #endregion

                if ($problems.Count -eq 0 -and $null -ne $olderKey) {
                    $olderEntry = $releases[$olderKey]
                    $olderSettings = $null
                    if ($olderEntry -is [System.Collections.IDictionary]) {
                        $settingsKey = Find-OverrideDictionaryKey -Dictionary $olderEntry -Key 'Settings'
                        if ($null -ne $settingsKey) { $olderSettings = $olderEntry[$settingsKey] }
                    }
                    if (-not ($olderSettings -is [System.Collections.IDictionary])) {
                        $problems.Add("$prefix the release table's entry $olderKey has no Settings table.")
                    } else {
                        $setNames = @($SetKey | Where-Object { $null -ne $_ })
                        foreach ($keyName in (Get-OverrideOrdinalSorted -Text @($catalogResult.Settings.get_Keys()))) {
                            $entry = $catalogResult.Settings[$keyName]
                            if ($entry.Secret) { continue }
                            if (@($setNames | Where-Object { $_ -eq $keyName }).Count -gt 0) { continue }
                            if (-not $entry.HasShipped) { continue }
                            $olderKeyName = Find-OverrideDictionaryKey -Dictionary $olderSettings -Key $keyName
                            if ($null -eq $olderKeyName) { continue }
                            $olderSetting = $olderSettings[$olderKeyName]
                            if (-not ($olderSetting -is [System.Collections.IDictionary]) -or $olderSetting.get_Count() -ne 1) { continue }
                            $constantKey = Find-OverrideDictionaryKey -Dictionary $olderSetting -Key 'Constant'
                            if ($null -eq $constantKey) { continue }
                            $olderValue = $olderSetting[$constantKey]
                            if (Test-OverrideValueEqual -First $olderValue -Second $entry.Shipped) { continue }

                            $olderText   = ConvertTo-OverrideDisplayText -Value $olderValue
                            $currentText = ConvertTo-OverrideDisplayText -Value $entry.Shipped
                            $olderLiteral = ConvertTo-OverrideDocumentValue -Value $olderValue -AsDataFileLiteral
                            $keepText = if ($null -ne $olderLiteral) { "$keyName = $olderLiteral" } else { $keyName }
                            $infoLines.Add("$prefix $keyName is $currentText in this release, and was $olderText in $olderKey. To keep $olderText, set $keepText in overrides\overrides.psd1.")
                            $changedKeys.Add([pscustomobject]@{ Key = $keyName; OldValue = $olderValue; NewValue = $entry.Shipped; Release = [string]$olderKey })
                        }
                    }
                }
            }
        }
    } catch {
        $problems.Add("$prefix the comparison failed unexpectedly ($($_.Exception.GetType().FullName) at OverrideFile.ps1 line $($_.InvocationInfo.ScriptLineNumber)).")
    }

    $errorText = $null
    if ($problems.Count -gt 0) {
        $errorText = $problems -join [Environment]::NewLine
        $infoLines.Clear()
        $changedKeys.Clear()
    }
    return [pscustomobject]@{
        Info     = [string[]]$infoLines.ToArray()
        Changed  = [object[]]$changedKeys.ToArray()
        Warnings = [string[]]$warningLines.ToArray()
        Error    = $errorText
    }
}

function ConvertTo-ReleaseConstantText {
    # A constant as the release table writes it: a string in single quotes with ' doubled,
    # a whole number in digits, $true, $false, or a one-line list of those. $null for a
    # value the layout doesn't take.
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [AllowNull()]
        [object]$Value,

        [switch]$IsListItem
    )
    if ($null -eq $Value -or $Value -is [System.Collections.IDictionary]) { return $null }
    if ($Value -is [bool]) {
        if ($Value) { return '$true' }
        return '$false'
    }
    if ($Value -is [string]) {
        if ($Value -cmatch '[^\x20-\x7E]') { return $null }
        return "'" + $Value.Replace("'", "''") + "'"
    }
    if ($Value -is [System.Array]) {
        if ($IsListItem) { return $null }
        $itemTexts = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $Value) {
            $itemText = ConvertTo-ReleaseConstantText -Value $item -IsListItem
            if ($null -eq $itemText) { return $null }
            $itemTexts.Add($itemText)
        }
        return '@(' + ($itemTexts -join ', ') + ')'
    }
    foreach ($integerType in @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])) {
        if ($Value -is $integerType) { return [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture) }
    }
    return $null
}

function ConvertTo-ReleaseValueEntry {
    <#
    .SYNOPSIS
        Returns the text of one release's entry in include\release-values.psd1, and the
        whole file with that entry in place.
    .DESCRIPTION
        Takes one release's values as Read-ScriptSetting gives them (an object with
        State Value, Dynamic or NoDefault, Value, and for a parameter default
        SourceText) and the CSV hashes, and writes them in the release table's exact
        layout. ASCII, LF line endings, no BOM, no comments, no blank lines, four
        spaces a level, one key-value pair a line except that a setting's value table
        sits on its key's line.

        Each setting becomes exactly one of:
          - @{ Constant = <value> }, a string in single quotes with ' doubled, a whole
            number, $true, $false, or a one-line list of those
          - @{ Expression = '<source text>' }, a default that isn't a constant, by its
            source text with ' doubled
          - @{ NoDefault = $true }, a parameter with no default
          - @{ Sha256 = '<64 lower-case hex digits>' }, for a secret key, the SHA-256 of
            its value's UTF-8 text, so the table never holds a secret
        A Dynamic setting whose source text is missing or spans lines, and a secret one
        whose default isn't a constant, is left out with a warning, so the migration
        treats it as it treats any dynamic value. Settings and Csv lines are in ordinal
        key order.

        With ExistingText, the entry replaces that file's entry for the same version,
        or is added, and the entries are put in ascending order compared as [version].
        The other entries are copied line for line, so removing this entry's lines gives
        the file it was added to. Reads no file and never throws.
    .PARAMETER Project
        The project's name, as its catalog's Project holds it.
    .PARAMETER Version
        The release's tag without its leading v: 1.0 for the old two-part tags, three
        parts from then on.
    .PARAMETER HeaderVersion
        What that release's script headers say, which for some old releases isn't the
        tag's version.
    .PARAMETER Setting
        Catalog key to that release's value, as Read-ScriptSetting returns it. Leave out
        a key the release didn't have.
    .PARAMETER SecretKey
        The catalog's secret keys.
    .PARAMETER Csv
        New-AdDomain only. CSV file name to the SHA-256 of its normalized text.
    .PARAMETER ExistingText
        The current text of include\release-values.psd1. Omit it for a new file.
    .OUTPUTS
        PSCustomObject with Entry (the entry's lines, ending in LF), Text (the whole
        file), Warnings (string array) and Error ($null, or one problem per line).
        Entry and Text are $null when Error is set.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [AllowNull()]
        [string]$Project,

        [AllowNull()]
        [string]$Version,

        [AllowNull()]
        [string]$HeaderVersion,

        [AllowNull()]
        [System.Collections.IDictionary]$Setting,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$SecretKey,

        [AllowNull()]
        [System.Collections.IDictionary]$Csv,

        [AllowNull()]
        [string]$ExistingText
    )
    $ErrorActionPreference = 'Stop'
    $problems     = [System.Collections.Generic.List[string]]::new()
    $warningLines = [System.Collections.Generic.List[string]]::new()
    $prefix       = 'Release table:'
    $entryText    = $null
    $fileText     = $null
    $keyNamePattern = '\A[A-Za-z][A-Za-z0-9]*\z'
    $versionPattern = '\A[0-9]+\.[0-9]+(\.[0-9]+)?\z'

    try {
        if ([string]::IsNullOrWhiteSpace($Project) -or $Project -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._-]*\z') { $problems.Add("$prefix Project isn't a project name.") }
        if ($Version -cnotmatch $versionPattern) { $problems.Add("$prefix Version isn't a release version such as 1.0 or 2.1.0.") }
        if ($HeaderVersion -cnotmatch '\A[0-9]+(\.[0-9]+){1,3}\z') { $problems.Add("$prefix HeaderVersion isn't a version such as 1.0.0.") }
        if ($null -eq $Setting) { $problems.Add("$prefix no Setting table was given.") }
        elseif ($Setting.get_Count() -ge 500) { $problems.Add("$prefix Setting holds $($Setting.get_Count()) keys. A table must hold fewer than 500.") }
        $secretNames = @($SecretKey | Where-Object { $null -ne $_ })

        #region Settings lines
        $settingLines = [System.Collections.Generic.List[string]]::new()
        if ($null -ne $Setting) {
            foreach ($keyName in (Get-OverrideOrdinalSorted -Text @($Setting.get_Keys()))) {
                if ($keyName -cnotmatch $keyNamePattern) { $problems.Add("$prefix the setting key '$keyName' isn't letters and digits starting with a letter."); continue }
                $settingValue = $Setting[$keyName]
                $propertyNames = @()
                if ($null -ne $settingValue) { $propertyNames = @($settingValue.PSObject.Properties.Name) }
                if ($propertyNames -notcontains 'State') { $problems.Add("$prefix the setting $keyName has no State, as Read-ScriptSetting gives it."); continue }
                $isSecret = $secretNames -ccontains $keyName
                $valueText = $null
                switch ([string]$settingValue.State) {
                    'Value' {
                        $settingConstant = $null
                        if ($propertyNames -contains 'Value') { $settingConstant = $settingValue.Value }
                        if ($isSecret) {
                            $secretText = [System.Convert]::ToString($settingConstant, [System.Globalization.CultureInfo]::InvariantCulture)
                            $hashAlgorithm = [System.Security.Cryptography.SHA256]::Create()
                            try {
                                $hashText = ([System.BitConverter]::ToString($hashAlgorithm.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$secretText))) -replace '-', '').ToLowerInvariant()
                            } finally {
                                $hashAlgorithm.Dispose()
                            }
                            $valueText = "@{ Sha256 = '$hashText' }"
                        } else {
                            $constantText = ConvertTo-ReleaseConstantText -Value $settingConstant
                            if ($null -eq $constantText) {
                                $problems.Add("$prefix the setting $keyName holds a constant the table can't store. It takes a string, a whole number, `$true, `$false or a list of those.")
                            } else {
                                $valueText = "@{ Constant = $constantText }"
                            }
                        }
                    }
                    'NoDefault' { $valueText = '@{ NoDefault = $true }' }
                    'Dynamic' {
                        $sourceText = $null
                        if ($propertyNames -contains 'SourceText') { $sourceText = $settingValue.SourceText }
                        if ($isSecret) {
                            $warningLines.Add("$prefix $keyName was left out, because it is secret and its default isn't a constant.")
                        } elseif ([string]::IsNullOrEmpty($sourceText) -or $sourceText -cmatch '[\r\n]') {
                            $warningLines.Add("$prefix $keyName was left out, because its default isn't a constant and its source text is missing or spans lines.")
                        } elseif ($sourceText -cmatch '[^\x20-\x7E]') {
                            $warningLines.Add("$prefix $keyName was left out, because its default's source text isn't ASCII.")
                        } else {
                            $valueText = "@{ Expression = '" + $sourceText.Replace("'", "''") + "' }"
                        }
                    }
                    default { $problems.Add("$prefix the setting $keyName has a State other than Value, Dynamic or NoDefault.") }
                }
                if ($null -ne $valueText) { $settingLines.Add("                $keyName = $valueText") }
            }
        }
        #endregion

        #region Csv lines
        $csvLines = $null
        if ($null -ne $Csv) {
            $csvLines = [System.Collections.Generic.List[string]]::new()
            foreach ($csvName in (Get-OverrideOrdinalSorted -Text @($Csv.get_Keys()))) {
                $csvHash = [string]$Csv[$csvName]
                if ($csvName -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._-]*\.csv\z') { $problems.Add("$prefix the CSV name '$csvName' isn't a .csv file name."); continue }
                if ($csvHash -notmatch '\A[0-9A-Fa-f]{64}\z') { $problems.Add("$prefix the hash for $csvName isn't 64 hex digits."); continue }
                $csvLines.Add("                '$csvName' = '$($csvHash.ToLowerInvariant())'")
            }
        }
        #endregion

        if ($problems.Count -eq 0) {
            $entryLines = [System.Collections.Generic.List[string]]::new()
            $entryLines.Add("        '$Version' = @{")
            $entryLines.Add("            Tag = 'v$Version'")
            $entryLines.Add("            HeaderVersion = '$HeaderVersion'")
            $entryLines.Add('            Settings = @{')
            foreach ($settingLine in $settingLines) { $entryLines.Add($settingLine) }
            $entryLines.Add('            }')
            if ($null -ne $csvLines) {
                $entryLines.Add('            Csv = @{')
                foreach ($csvLine in $csvLines) { $entryLines.Add($csvLine) }
                $entryLines.Add('            }')
            }
            $entryLines.Add('        }')

            #region Place the entry among the existing ones
            $entriesByVersion = @{}
            $entriesByVersion[$Version] = [string[]]$entryLines.ToArray()
            if (-not [string]::IsNullOrEmpty($ExistingText)) {
                $existingLines = @(($ExistingText -replace "`r`n", "`n").TrimEnd("`n") -split "`n")
                $parseErrors = $null
                $existingAst = [System.Management.Automation.Language.Parser]::ParseInput(($existingLines -join "`n"), [ref]$null, [ref]$parseErrors)
                $existingTable = $null
                if (@($parseErrors).Count -eq 0 -and @($existingAst.EndBlock.Statements).Count -eq 1) {
                    $onlyStatement = $existingAst.EndBlock.Statements[0]
                    if ($onlyStatement -is [System.Management.Automation.Language.PipelineAst] -and $onlyStatement.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
                        $existingTable = $onlyStatement.PipelineElements[0].Expression
                    }
                }
                if (-not ($existingTable -is [System.Management.Automation.Language.HashtableAst])) {
                    $problems.Add("$prefix ExistingText isn't one hashtable that parses.")
                } else {
                    $topPairs = @{}
                    foreach ($topPair in $existingTable.KeyValuePairs) {
                        if ($topPair.Item1 -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $topPairs[[string]$topPair.Item1.Value] = $topPair.Item2 }
                    }
                    $topValue = {
                        param ([string]$TopName)
                        if (-not $topPairs.ContainsKey($TopName)) { return $null }
                        try { return $topPairs[$TopName].SafeGetValue() } catch { return $null }
                    }
                    $releasesAst = $null
                    if ($topPairs.ContainsKey('Releases') -and $topPairs['Releases'] -is [System.Management.Automation.Language.PipelineAst]) {
                        $releasesExpression = $topPairs['Releases'].PipelineElements[0]
                        if ($releasesExpression -is [System.Management.Automation.Language.CommandExpressionAst]) { $releasesAst = $releasesExpression.Expression }
                    }
                    if ($topPairs.get_Count() -ne 3 -or (& $topValue 'FormatVersion') -ne 1 -or -not ($releasesAst -is [System.Management.Automation.Language.HashtableAst])) {
                        $problems.Add("$prefix ExistingText isn't in the release table's layout, FormatVersion 1, Project and Releases.")
                    } elseif ((& $topValue 'Project') -cne $Project) {
                        $problems.Add("$prefix ExistingText is for another project.")
                    } else {
                        foreach ($releasePair in $releasesAst.KeyValuePairs) {
                            $releaseKey = $releasePair.Item1
                            if (-not ($releaseKey -is [System.Management.Automation.Language.StringConstantExpressionAst]) -or $releaseKey.Value -cnotmatch $versionPattern) {
                                $problems.Add("$prefix ExistingText has a release key on line $($releaseKey.Extent.StartLineNumber) that isn't a version in quotes.")
                                continue
                            }
                            $startLine = $releaseKey.Extent.StartLineNumber
                            $endLine   = $releasePair.Item2.Extent.EndLineNumber
                            $keyLineBefore = $existingLines[$startLine - 1].Substring(0, $releaseKey.Extent.StartColumnNumber - 1)
                            $valueLineAfter = $existingLines[$endLine - 1].Substring($releasePair.Item2.Extent.EndColumnNumber - 1)
                            if ($keyLineBefore.Trim().Length -gt 0 -or $valueLineAfter.Trim().Length -gt 0) {
                                $problems.Add("$prefix ExistingText's entry $($releaseKey.Value) doesn't sit on lines of its own.")
                                continue
                            }
                            if ($releaseKey.Value -cne $Version) {
                                $entriesByVersion[[string]$releaseKey.Value] = [string[]]$existingLines[($startLine - 1)..($endLine - 1)]
                            }
                        }
                    }
                }
            }
            #endregion

            if ($problems.Count -eq 0) {
                $orderedVersions = @($entriesByVersion.get_Keys() | Sort-Object { [version]$_ })
                $fileLines = [System.Collections.Generic.List[string]]::new()
                $fileLines.Add('@{')
                $fileLines.Add('    FormatVersion = 1')
                $fileLines.Add("    Project = '$Project'")
                $fileLines.Add('    Releases = @{')
                foreach ($orderedVersion in $orderedVersions) { foreach ($entryLine in $entriesByVersion[$orderedVersion]) { $fileLines.Add($entryLine) } }
                $fileLines.Add('    }')
                $fileLines.Add('}')
                $entryText = ($entryLines -join "`n") + "`n"
                $fileText  = ($fileLines -join "`n") + "`n"
                if ($fileText -cmatch '[^\x0A\x20-\x7E]') {
                    $problems.Add("$prefix the text holds a character that isn't printable ASCII.")
                }
            }
        }
    } catch {
        $problems.Add("$prefix the writer failed unexpectedly ($($_.Exception.GetType().FullName) at OverrideFile.ps1 line $($_.InvocationInfo.ScriptLineNumber)).")
    }

    $errorText = $null
    if ($problems.Count -gt 0) {
        $errorText = $problems -join [Environment]::NewLine
        $entryText = $null
        $fileText  = $null
    }
    return [pscustomobject]@{
        Entry    = $entryText
        Text     = $fileText
        Warnings = [string[]]$warningLines.ToArray()
        Error    = $errorText
    }
}
#endregion
