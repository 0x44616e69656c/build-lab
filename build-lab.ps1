<#
.SYNOPSIS
    Builds a lab Active Directory domain controller end to end: creates a Windows
    Server 2025 VM, deploys the new-AdDomain project into it, and runs forest promotion.
.DESCRIPTION
    Orchestrates three pieces into one lab build:
      1. Calls New-VMwareWorkstationVM.ps1 (sibling project) to create and start a
         Windows Server 2025 VM. -StaticIpAddress is mandatory here (it is optional in
         the child script) because without it the child returns immediately after
         starting the VM with no wait, leaving no guest network for the steps below.
      2. Copies the new-AdDomain project into the guest at C:\temp\new-AdDomain via
         vmrun VIX guest operations (zip on host, copyFileFromHostToGuest, expand
         in-guest).
      3. Runs New-ADForestDeployment.ps1 -CreateScheduledTask inside the guest.

    New-ADForestDeployment.ps1's exit status from the in-guest run is meaningless: on
    success it logs "...complete. Rebooting now." and calls Restart-Computer -Force,
    which tears down the vmrun guest-operations channel mid-call; on failure it exits
    cleanly without rebooting. This script therefore verifies promotion by artifact
    (C:\Windows\NTDS\ntds.dit existing in the guest) rather than by the in-guest run's
    exit status, and retrieves the guest's own deployment logs to the host afterwards.

    Directory population (Initialize-ADDirectory.ps1) is outside this script's scope
    and does NOT run automatically. New-ADForestDeployment.ps1 registers it as a
    scheduled task triggered at the next Administrator logon, so an operator MUST log
    into the guest console as Administrator after the build to start it. This script
    prints a red reminder banner on completion. (To make it run without a logon, the
    task in New-ADForestDeployment.ps1 would have to run as the domain Administrator
    with a stored password under an -AtStartup trigger -- a separate, credential-storing
    change in the new-AdDomain project, not done here.)

    Use -SkipVmBuild to re-run the guest phases (steps 2-3) against an existing VM,
    for fast iteration without paying for a full VM build.
.EXAMPLE
    # -NetworkType defaults to 'nat', which puts the adapter on VMnet8. Workstation always
    # allocates a NAT network as a Class C and reserves fixed roles inside it:
    #   net.1            host virtual network adapter (reserved)
    #   net.2            NAT device -- the default gateway AND the DNS server
    #   net.3 - net.127  free for static IP addresses
    #   net.128 - net.254  virtual DHCP server's dynamic pool
    # So -StaticIpAddress must be net.3-net.127 and -DefaultGateway must be net.2. An address
    # in the DHCP pool risks a conflict; an address outside the subnet entirely leaves the
    # guest unreachable and the build times out polling it. The subnet itself is assigned when
    # Workstation is installed and differs per host -- look yours up in
    # Edit > Virtual Network Editor > VMnet8. 192.168.220.0/24 below is illustrative only.
    $pw = ConvertTo-SecureString 'P@ssw0rd!' -AsPlainText -Force
    .\build-lab.ps1 -IsoPath 'C:\ISOs\WS2025.iso' -AdminPassword $pw `
        -VmStoragePath 'C:\VMs' -StaticIpAddress '192.168.220.50' -DefaultGateway '192.168.220.2'
.EXAMPLE
    $pw = ConvertTo-SecureString 'P@ssw0rd!' -AsPlainText -Force
    .\build-lab.ps1 -SkipVmBuild -AdminPassword $pw -VmStoragePath 'C:\VMs' -VmName 'LabServer01'
.NOTES
    Version:      1.0.0
    Author:       Daniel Owen
    Release Date: 2026-07-18
    Requirements: VMware Workstation 17+ (vmrun.exe), Windows PowerShell 5.1+, local
                  Administrator on the host for Application event log source
                  registration only (vmrun guest operations authenticate against the
                  guest, not the host, and an unelevated run falls back to the built-in
                  'Application' source). Windows Server 2025 ISO. Sibling
                  projects New-VMwareWorkstationVM and new-AdDomain present relative to
                  this script (override with -VmBuilderScriptPath / -AdDomainSourcePath
                  if relocated). Guest credentials are Administrator / -AdminPassword;
                  the plaintext password unavoidably appears in vmrun's -gp argument
                  (visible in the host process list) -- accepted for lab use. Passwords
                  containing a double-quote character are rejected because they break
                  vmrun argument quoting.
                  WARNING: Write-EventLog is deprecated in PowerShell 7+. This script
                  targets Windows PowerShell 5.1, where Write-EventLog is the correct
                  API. For a PowerShell 7+ port, replace it with New-WinEvent against a
                  registered ETW manifest.
    Event Log Source: build-lab (registration requires local administrator rights on
                  the host; registration failure falls back to the built-in
                  'Application' source automatically).
#>

[CmdletBinding(DefaultParameterSetName = 'Build')]
param (
    # --- Passed through to New-VMwareWorkstationVM.ps1 ---
    [Parameter(Mandatory, ParameterSetName = 'Build')]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$IsoPath,

    [Parameter(Mandatory)]
    [SecureString]$AdminPassword,

    [Parameter(Mandatory)]
    [string]$VmStoragePath,

    [Parameter(Mandatory, ParameterSetName = 'Build')]
    [ValidatePattern('^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$')]
    [string]$StaticIpAddress,

    [ValidatePattern('^[^\\/:*?"<>|]{1,64}$')]
    [string]$VmName = 'WS2025-Server',

    [ValidatePattern('^(?!-)(?!.*-$)[A-Za-z0-9-]{1,15}$')]
    [string]$ComputerName = 'WIN2025',

    [ValidateRange(512, 65536)]
    [int]$RamMB = 4096,

    [ValidateRange(1, 64)]
    [int]$CpuCount = 2,

    [ValidateRange(20, 2048)]
    [int]$DiskGB = 60,

    [ValidateSet('nat', 'bridged', 'hostonly')]
    [string]$NetworkType = 'nat',

    [ValidatePattern('^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$')]
    [string]$SubnetMask = '255.255.255.0',

    [ValidatePattern('^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$')]
    [string]$DefaultGateway,

    [ValidatePattern('^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$')]
    [string]$DnsServer = '8.8.8.8',

    [ValidateRange(1, 1440)]
    [int]$TimeoutMinutes = 90,

    # --- Orchestrator-own ---
    # Defaults resolved in the Variables region from $PSScriptRoot (sibling layout):
    #   VmBuilderScriptPath -> $PSScriptRoot\..\New-VMwareWorkstationVM\New-VMwareWorkstationVM.ps1
    #   AdDomainSourcePath  -> $PSScriptRoot\..\new-AdDomain
    [string]$VmBuilderScriptPath,
    [string]$AdDomainSourcePath,

    [ValidateRange(1, 120)]
    [int]$GuestReadyTimeoutMinutes = 20,

    # Upper bound on how long to poll for the promotion artifact (ntds.dit) after launching
    # New-ADForestDeployment.ps1 fire-and-forget. Covers AD DS install + forest promotion.
    [ValidateRange(1, 240)]
    [int]$DeploymentTimeoutMinutes = 30,

    [Parameter(ParameterSetName = 'GuestOnly')]
    [switch]$SkipVmBuild
)

#region Include
$includeRootPath = Join-Path -Path $PSScriptRoot -ChildPath 'include'
foreach ($includeFileName in @('Sanitization.ps1', 'Logging.ps1', 'EventLogging.ps1', 'Retry.ps1', 'FileUtilities.ps1')) {
    $includeFilePath = Join-Path -Path $includeRootPath -ChildPath $includeFileName
    if (-not (Test-Path -Path $includeFilePath -PathType Leaf)) {
        throw "Required include file not found: $includeFilePath"
    }
    . $includeFilePath
}
#endregion Include

#region Functions

function ConvertTo-PlainTextCredentialValue {
    param (
        [Parameter(Mandatory)]
        [SecureString]$SecureValue
    )
    $bstrPointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstrPointer)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrPointer)
    }
}

function ConvertTo-PrefixLength {
    # Converts a dotted-decimal subnet mask (e.g. 255.255.255.0) to a CIDR prefix length
    # (e.g. 24) for passing to the guest's New-NetIPAddress -PrefixLength.
    param (
        [Parameter(Mandatory)]
        [string]$SubnetMask
    )
    $maskBinaryString = ($SubnetMask.Split('.') | ForEach-Object {
        [Convert]::ToString([int]$_, 2).PadLeft(8, '0')
    }) -join ''
    if ($maskBinaryString -notmatch '^1*0*$') {
        throw "Invalid subnet mask '$SubnetMask' -- bits are not contiguous."
    }
    return ($maskBinaryString.ToCharArray() | Where-Object { $_ -eq '1' }).Count
}

function Find-VmrunExecutable {
    param ()
    $candidatePaths = @(
        "${env:ProgramFiles(x86)}\VMware\VMware Workstation\vmrun.exe",
        "$env:ProgramFiles\VMware\VMware Workstation\vmrun.exe"
    )
    foreach ($candidatePath in $candidatePaths) {
        if (Test-Path -Path $candidatePath -PathType Leaf) {
            return $candidatePath
        }
    }
    throw "vmrun.exe not found under VMware Workstation Program Files directories. Ensure VMware Workstation 17+ is installed."
}

function Invoke-VmrunCommand {
    param (
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [string[]]$ArgumentList,
        [Parameter(Mandatory)]
        [string]$OperationName,
        [string[]]$RedactedTokens = @()
    )
    $commandOutput = & $VmrunPath @ArgumentList 2>&1
    $exitCode = $LASTEXITCODE

    foreach ($redactedToken in $RedactedTokens) {
        if ($redactedToken) {
            $commandOutput = $commandOutput | ForEach-Object { $_ -replace [regex]::Escape($redactedToken), '***' }
        }
    }

    if ($exitCode -ne 0 -or ($commandOutput -match 'Error')) {
        throw "vmrun operation '$OperationName' failed (exit code $exitCode): $($commandOutput -join ' ')"
    }
    return $commandOutput
}

function Test-GuestPathExists {
    # vmrun's fileExistsInGuest / directoryExistsInGuest exit with code 0 when the path
    # exists and a non-zero code (without an "Error" message) when it does not -- this is
    # a normal query result, not a failure, so it is checked directly rather than through
    # Invoke-VmrunCommand (which throws on any non-zero exit code).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = "'Exists' names the boolean test (mirrors vmrun's fileExistsInGuest / directoryExistsInGuest), not a plural noun.")]
    param (
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [string]$VmxFilePath,
        [Parameter(Mandatory)]
        [PSCredential]$GuestCredential,
        [Parameter(Mandatory)]
        [ValidateSet('File', 'Directory')]
        [string]$PathType,
        [Parameter(Mandatory)]
        [string]$GuestPath
    )
    $guestUserName          = $GuestCredential.UserName
    $guestPasswordPlainText = $GuestCredential.GetNetworkCredential().Password

    $existCommand = if ($PathType -eq 'File') { 'fileExistsInGuest' } else { 'directoryExistsInGuest' }
    $commandOutput = & $VmrunPath -T ws -gu $guestUserName -gp $guestPasswordPlainText $existCommand $VmxFilePath $GuestPath 2>&1
    $exitCode = $LASTEXITCODE
    $commandOutput = $commandOutput | ForEach-Object { $_ -replace [regex]::Escape($guestPasswordPlainText), '***' }

    if ($commandOutput -match 'Error') {
        throw "vmrun $existCommand failed for '$GuestPath' (exit code $exitCode): $($commandOutput -join ' ')"
    }
    return ($exitCode -eq 0)
}

function Wait-GuestOperationsReady {
    param (
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [string]$VmxFilePath,
        [Parameter(Mandatory)]
        [PSCredential]$GuestCredential,
        [Parameter(Mandatory)]
        [int]$TimeoutMinutes,
        [int]$PollIntervalSeconds = 15
    )
    $guestUserName          = $GuestCredential.UserName
    $guestPasswordPlainText = $GuestCredential.GetNetworkCredential().Password
    $logCommand    = Get-Command -Name Write-Log -CommandType Function -ErrorAction SilentlyContinue
    $readyDeadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $notReadyReason = 'not yet probed'

    while ((Get-Date) -lt $readyDeadline) {
        $isGuestReady   = $false
        $notReadyReason = $null
        try {
            $toolsStateOutput = Invoke-VmrunCommand -VmrunPath $VmrunPath `
                -ArgumentList @('-T', 'ws', 'checkToolsState', $VmxFilePath) `
                -OperationName 'checkToolsState' `
                -RedactedTokens @($guestPasswordPlainText)
            $toolsState = ($toolsStateOutput -join '').Trim()

            if ($toolsState -eq 'running') {
                # VMware Tools is up. The guest-exec probe is the real gate: it confirms VIX
                # can run a program with the Administrator credential. Isolate its failure so
                # a credential/OOBE problem is not misreported as "Tools not ready".
                try {
                    $null = Invoke-VmrunCommand -VmrunPath $VmrunPath `
                        -ArgumentList @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText,
                            'runProgramInGuest', $VmxFilePath, 'C:\Windows\System32\whoami.exe') `
                        -OperationName 'guest readiness probe' `
                        -RedactedTokens @($guestPasswordPlainText)
                    $isGuestReady = $true
                }
                catch {
                    $notReadyReason = "VMware Tools is 'running' but the guest-exec probe (whoami) failed -- commonly the Administrator credential is not yet accepted while the guest finishes OOBE/specialize, or the -AdminPassword is wrong: $($_.Exception.Message)"
                }
            }
            else {
                $notReadyReason = "VMware Tools not ready yet (checkToolsState = '$toolsState')."
            }
        }
        catch {
            $notReadyReason = "checkToolsState call failed (guest likely still booting): $($_.Exception.Message)"
        }

        if ($isGuestReady) { return }

        $minutesRemaining = [math]::Round(($readyDeadline - (Get-Date)).TotalMinutes, 1)
        if ($logCommand) {
            Write-Log "Guest not ready yet -- $notReadyReason ($minutesRemaining minute(s) remaining before timeout)." -Level INFO
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }

    throw "Guest operations did not become ready within $TimeoutMinutes minute(s). Last probe reason: $notReadyReason Check the VM console for setup progress, verify VMware Tools is installed, and confirm the Administrator credentials."
}

function New-AdDomainPayloadArchive {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal build step that stages a host-side copy of new-AdDomain into a disposable temp folder and zips it; -WhatIf support would not meaningfully apply.')]
    param (
        [Parameter(Mandatory)]
        [string]$SourcePath,
        [Parameter(Mandatory)]
        [string]$StagingRootPath,
        [string[]]$ExcludedDirectoryNames = @('.git', '.claude', 'junk', 'logs')
    )
    $stagingPayloadPath = Join-Path -Path $StagingRootPath -ChildPath 'new-AdDomain'
    $null = New-Item -ItemType Directory -Path $StagingRootPath -Force

    $robocopyArgumentList = @($SourcePath, $stagingPayloadPath, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/XD') + $ExcludedDirectoryNames
    $null = & robocopy @robocopyArgumentList
    # robocopy uses exit codes 0-7 for success (including "files copied" and "extra
    # files/dirs"); only 8+ indicates a real failure.
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed copying '$SourcePath' to '$stagingPayloadPath' (exit code $LASTEXITCODE)."
    }

    $payloadZipFilePath = Join-Path -Path $StagingRootPath -ChildPath 'new-AdDomain.zip'
    if (Test-Path -Path $payloadZipFilePath) {
        Remove-Item -Path $payloadZipFilePath -Force
    }
    Compress-Archive -Path $stagingPayloadPath -DestinationPath $payloadZipFilePath -Force

    return $payloadZipFilePath
}

function Copy-PayloadToGuest {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'PayloadZipFilePath',
        Justification = 'Used inside a scriptblock passed to Invoke-CommandWithRetry; PSScriptAnalyzer does not trace parameter usage inside scriptblock closures.')]
    param (
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [string]$VmxFilePath,
        [Parameter(Mandatory)]
        [PSCredential]$GuestCredential,
        [Parameter(Mandatory)]
        [string]$PayloadZipFilePath
    )
    $guestUserName          = $GuestCredential.UserName
    $guestPasswordPlainText = $GuestCredential.GetNetworkCredential().Password
    $redactedTokens     = @($guestPasswordPlainText)
    $guestPowerShellExe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $guestTempPath      = 'C:\temp'
    $guestZipFilePath   = 'C:\temp\new-AdDomain.zip'
    $guestPayloadPath   = 'C:\temp\new-AdDomain'

    # Capture Invoke-VmrunCommand as a scriptblock *value* so it can be invoked by
    # reference (& $invokeVmrunCommand) inside the .GetNewClosure() blocks below.
    # .GetNewClosure() reliably carries captured *variables* into the closure's session
    # state, but in some environments it does NOT carry sibling script-scope *function
    # names* -- calling Invoke-VmrunCommand by name inside those closures fails with
    # "term ... is not recognized" (see gotchas.md). Resolving the function to a variable
    # here (where it is in scope) sidesteps the name lookup entirely.
    $invokeVmrunCommand = ${function:Invoke-VmrunCommand}

    $guestPathExistsParameters = @{
        VmrunPath       = $VmrunPath
        VmxFilePath     = $VmxFilePath
        GuestCredential = $GuestCredential
    }

    if (-not (Test-GuestPathExists @guestPathExistsParameters -PathType Directory -GuestPath $guestTempPath)) {
        $null = Invoke-CommandWithRetry -OperationName "createDirectoryInGuest $guestTempPath" -ThrowOnFailure -ScriptBlock {
            $null = & $invokeVmrunCommand -VmrunPath $VmrunPath -RedactedTokens $redactedTokens -OperationName "createDirectoryInGuest $guestTempPath" `
                -ArgumentList @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText, 'createDirectoryInGuest', $VmxFilePath, $guestTempPath)
        }.GetNewClosure()
    }

    if (Test-GuestPathExists @guestPathExistsParameters -PathType Directory -GuestPath $guestPayloadPath) {
        $null = Invoke-CommandWithRetry -OperationName "remove existing $guestPayloadPath in guest" -ThrowOnFailure -ScriptBlock {
            $null = & $invokeVmrunCommand -VmrunPath $VmrunPath -RedactedTokens $redactedTokens -OperationName "remove existing $guestPayloadPath" `
                -ArgumentList @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText, 'runProgramInGuest', $VmxFilePath, $guestPowerShellExe,
                    '-NoProfile', '-Command', "Remove-Item -LiteralPath '$guestPayloadPath' -Recurse -Force")
        }.GetNewClosure()
    }

    $null = Invoke-CommandWithRetry -OperationName 'copyFileFromHostToGuest new-AdDomain.zip' -ThrowOnFailure -ScriptBlock {
        $null = & $invokeVmrunCommand -VmrunPath $VmrunPath -RedactedTokens $redactedTokens -OperationName 'copyFileFromHostToGuest new-AdDomain.zip' `
            -ArgumentList @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText, 'copyFileFromHostToGuest', $VmxFilePath, $PayloadZipFilePath, $guestZipFilePath)
    }.GetNewClosure()

    $null = Invoke-CommandWithRetry -OperationName 'Expand-Archive new-AdDomain.zip in guest' -ThrowOnFailure -ScriptBlock {
        $null = & $invokeVmrunCommand -VmrunPath $VmrunPath -RedactedTokens $redactedTokens -OperationName 'Expand-Archive new-AdDomain.zip' `
            -ArgumentList @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText, 'runProgramInGuest', $VmxFilePath, $guestPowerShellExe,
                '-NoProfile', '-Command', "Expand-Archive -LiteralPath '$guestZipFilePath' -DestinationPath '$guestTempPath' -Force")
    }.GetNewClosure()

    $verificationGuestPaths = @(
        (Join-Path -Path $guestPayloadPath -ChildPath 'New-ADForestDeployment.ps1'),
        (Join-Path -Path $guestPayloadPath -ChildPath 'include\global-config.ps1')
    )
    foreach ($verificationGuestPath in $verificationGuestPaths) {
        if (-not (Test-GuestPathExists @guestPathExistsParameters -PathType File -GuestPath $verificationGuestPath)) {
            throw "Payload verification failed: '$verificationGuestPath' not found in guest after expanding new-AdDomain.zip."
        }
    }

    $null = Invoke-CommandWithRetry -OperationName 'deleteFileInGuest new-AdDomain.zip' -ThrowOnFailure -ScriptBlock {
        $null = & $invokeVmrunCommand -VmrunPath $VmrunPath -RedactedTokens $redactedTokens -OperationName 'deleteFileInGuest new-AdDomain.zip' `
            -ArgumentList @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText, 'deleteFileInGuest', $VmxFilePath, $guestZipFilePath)
    }.GetNewClosure()
}

function Invoke-GuestAdForestDeployment {
    # Launches New-ADForestDeployment.ps1 FIRE-AND-FORGET via vmrun 'runProgramInGuest
    # -noWait', which returns as soon as the guest process starts rather than blocking until
    # it exits. This is deliberate: the guest script promotes the forest and then reboots
    # (Restart-Computer -Force). A blocking (no -noWait) call held one VIX guest-operations
    # channel open across that reboot, and on some hosts vmrun never returns from it -- the
    # channel is torn down mid-call and vmrun waits forever for exit status it can no longer
    # obtain, hanging the whole orchestration (confirmed in the field 2026-07-11). With
    # -noWait there is nothing to block on; Test-GuestDomainPromotion verifies completion by
    # polling for the ntds.dit artifact.
    #
    # -NonInteractive plus the static network values are passed so the guest script never
    # blocks on a Read-Host prompt (a console-less vmrun run cannot answer one) and can
    # repair a DHCP fallback from the unattended specialize pass in place.
    param (
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [string]$VmxFilePath,
        [Parameter(Mandatory)]
        [PSCredential]$GuestCredential,
        [string]$StaticIpAddress,
        [int]$PrefixLength,
        [string]$DefaultGateway
    )
    $guestUserName          = $GuestCredential.UserName
    $guestPasswordPlainText = $GuestCredential.GetNetworkCredential().Password
    $logCommand         = Get-Command -Name Write-Log -CommandType Function -ErrorAction SilentlyContinue
    $guestPowerShellExe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $guestScriptPath    = 'C:\temp\new-AdDomain\New-ADForestDeployment.ps1'

    $guestScriptArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $guestScriptPath,
        '-CreateScheduledTask', '-NonInteractive')
    if ($StaticIpAddress) {
        $guestScriptArguments += @('-StaticIpAddress', $StaticIpAddress, '-PrefixLength', $PrefixLength)
        if ($DefaultGateway) {
            $guestScriptArguments += @('-DefaultGateway', $DefaultGateway)
        }
    }

    $vmrunArgumentList = @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText,
        'runProgramInGuest', $VmxFilePath, '-noWait', $guestPowerShellExe) + $guestScriptArguments

    if ($logCommand) {
        Write-Log "Launching New-ADForestDeployment.ps1 -CreateScheduledTask in guest (fire-and-forget via vmrun -noWait). It installs AD DS, promotes the forest, and reboots on success; completion is verified by polling for ntds.dit -- expect 5-15 minutes." -Level INFO
    }

    try {
        $null = Invoke-VmrunCommand -VmrunPath $VmrunPath -RedactedTokens @($guestPasswordPlainText) `
            -OperationName 'New-ADForestDeployment.ps1 (-noWait)' -ArgumentList $vmrunArgumentList
        if ($logCommand) {
            Write-Log "New-ADForestDeployment.ps1 launched in guest. Polling for promotion artifact." -Level INFO
        }
    }
    catch {
        # -noWait only reports a launch failure (e.g. bad path/credentials). Log and continue;
        # if the launch truly failed, ntds.dit never appears and Test-GuestDomainPromotion
        # fails with a clear timeout rather than a silent hang.
        if ($logCommand) {
            Write-Log "vmrun reported an error launching New-ADForestDeployment.ps1: $($_.Exception.Message) Continuing to artifact verification." -Level WARN
        }
    }
}

function Test-GuestDomainPromotion {
    param (
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [string]$VmxFilePath,
        [Parameter(Mandatory)]
        [PSCredential]$GuestCredential,
        [Parameter(Mandatory)]
        [int]$GuestReadyTimeoutMinutes,
        [Parameter(Mandatory)]
        [int]$DeploymentTimeoutMinutes,
        [Parameter(Mandatory)]
        [string]$HostLogsRootPath
    )
    $logCommand                     = Get-Command -Name Write-Log -CommandType Function -ErrorAction SilentlyContinue
    $artifactPollIntervalSeconds    = 30
    $postArtifactRebootGraceSeconds = 90
    $ntdsFilePath                   = 'C:\Windows\NTDS\ntds.dit'

    $guestPathExistsParameters = @{
        VmrunPath       = $VmrunPath
        VmxFilePath     = $VmxFilePath
        GuestCredential = $GuestCredential
    }

    # Phase 1: the guest was launched fire-and-forget, so it is still installing AD DS and
    # promoting (guest up, pre-reboot). Poll for the ntds.dit artifact over the full
    # deployment window. Guest-operations errors here are transient (the guest may be
    # specializing, or has just begun its promotion reboot), so keep polling rather than
    # aborting. ntds.dit is created near the end of promotion, only seconds before the
    # script's reboot, so its presence means promotion reached the database stage.
    if ($logCommand) {
        Write-Log "Polling for '$ntdsFilePath' in guest (deployment timeout: $DeploymentTimeoutMinutes minute(s))..." -Level INFO
    }
    $deploymentDeadline    = (Get-Date).AddMinutes($DeploymentTimeoutMinutes)
    $promotionArtifactSeen = $false
    while ((Get-Date) -lt $deploymentDeadline) {
        try {
            if (Test-GuestPathExists @guestPathExistsParameters -PathType File -GuestPath $ntdsFilePath) {
                $promotionArtifactSeen = $true
                break
            }
        }
        catch {
            if ($logCommand) {
                Write-Log "Artifact poll for '$ntdsFilePath' not ready yet (transient while the guest promotes/reboots): $($_.Exception.Message)" -Level DEBUG
            }
        }
        $minutesRemaining = [math]::Round(($deploymentDeadline - (Get-Date)).TotalMinutes, 1)
        if ($logCommand) {
            Write-Log "Promotion artifact not present yet. $minutesRemaining minute(s) remaining before deployment timeout." -Level INFO
        }
        Start-Sleep -Seconds $artifactPollIntervalSeconds
    }

    if (-not $promotionArtifactSeen) {
        $hostLogsDestinationPath = Copy-GuestLogsToHost -VmrunPath $VmrunPath -VmxFilePath $VmxFilePath -GuestCredential $GuestCredential -HostLogsRootPath $HostLogsRootPath
        $fatalLogLine = $null
        if ($hostLogsDestinationPath) {
            $latestDeploymentLogFile = Get-ChildItem -Path $hostLogsDestinationPath -Filter 'New-ADForestDeployment-*.log' -Recurse |
                Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
            if ($latestDeploymentLogFile) {
                $fatalLogLine = Get-Content -Path $latestDeploymentLogFile.FullName |
                    Select-String -Pattern 'terminated with fatal error' | Select-Object -Last 1
            }
        }
        $fatalLogDetail = if ($fatalLogLine) { " Guest log: $fatalLogLine" } else { '' }
        throw "AD forest promotion did not complete within $DeploymentTimeoutMinutes minute(s): '$ntdsFilePath' not found in guest. The guest deployment may have failed (check the retrieved log) or is still installing -- raise -DeploymentTimeoutMinutes if the guest is legitimately slow.$fatalLogDetail"
    }

    # Phase 2: the artifact exists, so the success-path reboot is imminent. Give it time to
    # begin (the guest goes down), then confirm the guest comes back online after the reboot.
    if ($logCommand) {
        Write-Log "'$ntdsFilePath' present -- promotion reached the database stage. Allowing $postArtifactRebootGraceSeconds second(s) for the success-path reboot to begin." -Level INFO
    }
    Start-Sleep -Seconds $postArtifactRebootGraceSeconds

    $guestReadyTimedOut = $false
    try {
        Wait-GuestOperationsReady -VmrunPath $VmrunPath -VmxFilePath $VmxFilePath -GuestCredential $GuestCredential -TimeoutMinutes $GuestReadyTimeoutMinutes
    }
    catch {
        $guestReadyTimedOut = $true
        if ($logCommand) {
            Write-Log "Guest operations did not become ready within $GuestReadyTimeoutMinutes minute(s) after the promotion reboot: $($_.Exception.Message) Proceeding to log retrieval; the guest may still be rebooting." -Level WARN
        }
    }

    # Phase 3: retrieve guest deployment logs (best-effort) and finalize.
    $hostLogsDestinationPath = Copy-GuestLogsToHost -VmrunPath $VmrunPath -VmxFilePath $VmxFilePath -GuestCredential $GuestCredential -HostLogsRootPath $HostLogsRootPath

    if ($guestReadyTimedOut -and $logCommand) {
        Write-Log "'$ntdsFilePath' is present but the guest did not report ready within $GuestReadyTimeoutMinutes minute(s) after the reboot. Promotion likely succeeded; confirm the guest is online, or re-run with -SkipVmBuild to re-check." -Level WARN
    }

    if ($logCommand) {
        Write-Log "AD forest promotion verified: '$ntdsFilePath' exists in guest." -Level SUCCESS
    }
    return $hostLogsDestinationPath
}

function Copy-GuestLogsToHost {
    param (
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [string]$VmxFilePath,
        [Parameter(Mandatory)]
        [PSCredential]$GuestCredential,
        [Parameter(Mandatory)]
        [string]$HostLogsRootPath
    )
    $guestUserName          = $GuestCredential.UserName
    $guestPasswordPlainText = $GuestCredential.GetNetworkCredential().Password
    $logCommand          = Get-Command -Name Write-Log -CommandType Function -ErrorAction SilentlyContinue
    $redactedTokens      = @($guestPasswordPlainText)
    $guestPowerShellExe  = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $guestLogsSourcePath = 'C:\temp\new-AdDomain\logs'
    $guestLogsZipPath    = 'C:\temp\adDeploymentLogs.zip'
    $hostLogsZipPath     = Join-Path -Path $HostLogsRootPath -ChildPath 'adDeploymentLogs.zip'
    $hostDestinationPath = Join-Path -Path $HostLogsRootPath -ChildPath "guest-$(Get-Date -Format 'yyyyMMdd_HHmmss')"

    try {
        $null = Invoke-VmrunCommand -VmrunPath $VmrunPath -RedactedTokens $redactedTokens -OperationName 'Compress-Archive guest deployment logs' `
            -ArgumentList @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText, 'runProgramInGuest', $VmxFilePath, $guestPowerShellExe,
                '-NoProfile', '-Command', "Compress-Archive -LiteralPath '$guestLogsSourcePath' -DestinationPath '$guestLogsZipPath' -Force")

        $null = Invoke-VmrunCommand -VmrunPath $VmrunPath -RedactedTokens $redactedTokens -OperationName 'copyFileFromGuestToHost deployment logs' `
            -ArgumentList @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText, 'copyFileFromGuestToHost', $VmxFilePath, $guestLogsZipPath, $hostLogsZipPath)

        Expand-Archive -LiteralPath $hostLogsZipPath -DestinationPath $hostDestinationPath -Force
        Remove-Item -Path $hostLogsZipPath -Force

        return $hostDestinationPath
    }
    catch {
        if ($logCommand) {
            Write-Log "Could not retrieve guest deployment logs: $($_.Exception.Message)" -Level WARN
        }
        return $null
    }
}

function Show-PostBuildManualStepNotice {
    # Prints an unmissable red console banner reminding the operator that directory
    # population has NOT run yet and requires a manual Administrator logon to start.
    # Console-only by design (a visual prompt); the caller also writes the same
    # instruction through Write-Log so the text log/transcript records it.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Deliberate red console banner so the operator cannot miss the required manual logon step; the same instruction is also persisted via Write-Log by the caller.')]
    param ()
    $bannerLines = @(
        '',
        '================================================================================',
        ' ACTION REQUIRED: DIRECTORY POPULATION HAS NOT RUN YET',
        '',
        ' AD forest promotion succeeded, but Initialize-ADDirectory.ps1 (OUs, users,',
        ' groups, Enterprise CA, GPOs, etc.) runs via a scheduled task that triggers',
        ' ONLY at the next Administrator logon.',
        '',
        ' Log into the guest console as Administrator to start directory population.',
        ' It removes its own scheduled task and reboots when finished.',
        '================================================================================',
        ''
    )
    foreach ($bannerLine in $bannerLines) {
        Write-Host $bannerLine -ForegroundColor Red
    }
}

#endregion Functions

#region Variables
$enableEventLogging = $true
$eventLogSourceName = 'build-lab'
$guestUserName      = 'Administrator'
$runTimestamp       = Get-Date -Format 'yyyyMMdd_HHmmss'

if (-not $VmBuilderScriptPath) {
    $VmBuilderScriptPath = Join-Path -Path $PSScriptRoot -ChildPath '..\New-VMwareWorkstationVM\New-VMwareWorkstationVM.ps1'
}
if (-not $AdDomainSourcePath) {
    $AdDomainSourcePath = Join-Path -Path $PSScriptRoot -ChildPath '..\new-AdDomain'
}

$logDirectoryPath = Join-Path -Path $PSScriptRoot -ChildPath 'logs'
$csvLogFilePath   = Join-Path -Path $logDirectoryPath -ChildPath "build-lab-errors_$runTimestamp.csv"
$textLogFilePath  = Join-Path -Path $logDirectoryPath -ChildPath "build-lab_$runTimestamp.log"

$vmDirectoryPath = Join-Path -Path $VmStoragePath -ChildPath $VmName
$vmxFilePath     = Join-Path -Path $vmDirectoryPath -ChildPath "$VmName.vmx"

$stagingRootPath = Join-Path -Path $env:TEMP -ChildPath "BuildLab-$runTimestamp"

# CIDR prefix length derived from the subnet mask, passed to the guest deployment so it can
# repair a DHCP fallback non-interactively (see Invoke-GuestAdForestDeployment).
$staticIpPrefixLength = ConvertTo-PrefixLength -SubnetMask $SubnetMask
#endregion Variables

#region Main

Initialize-Logging -ScriptName 'build-lab.ps1' -CsvLogPath $csvLogFilePath -TextLogPath $textLogFilePath
$eventLogSourceName = Initialize-EventLogSource -SourceName $eventLogSourceName

$guestPasswordPlainText = $null

try {
    Write-Log "=== build-lab.ps1 starting ===" -Level INFO
    Write-AppEvent -Enabled $enableEventLogging -SourceName $eventLogSourceName -EntryType Information -EventId 1000 -Message 'build-lab.ps1 started.'

    if (-not (Test-Path -Path $VmBuilderScriptPath -PathType Leaf)) {
        throw "VM builder script not found: '$VmBuilderScriptPath'. Pass -VmBuilderScriptPath if New-VMwareWorkstationVM is not a sibling of this project."
    }
    $adForestDeploymentScriptPath = Join-Path -Path $AdDomainSourcePath -ChildPath 'New-ADForestDeployment.ps1'
    if (-not (Test-Path -Path $adForestDeploymentScriptPath -PathType Leaf)) {
        throw "New-ADForestDeployment.ps1 not found at '$adForestDeploymentScriptPath'. Pass -AdDomainSourcePath if new-AdDomain is not a sibling of this project."
    }

    $vmrunPath = Find-VmrunExecutable

    if ($SkipVmBuild) {
        if (-not (Test-Path -Path $vmxFilePath -PathType Leaf)) {
            throw "-SkipVmBuild was specified but no VMX exists at '$vmxFilePath'. The path is composed as <VmStoragePath>\<VmName>\<VmName>.vmx, so pass the SAME -VmStoragePath and -VmName you built the VM with (do not include the VM's own folder in -VmStoragePath). For example, a VM at 'D:\VMWare\DC01\DC01.vmx' needs -VmStoragePath 'D:\VMWare' -VmName 'DC01'. Build the VM first if it does not exist."
        }
    }
    elseif (Test-Path -Path $vmxFilePath -PathType Leaf) {
        throw "VMX already exists at '$vmxFilePath'. Remove the existing VM, choose a different -VmName, or pass -SkipVmBuild to reuse it."
    }

    $guestPasswordPlainText = ConvertTo-PlainTextCredentialValue -SecureValue $AdminPassword
    if ($guestPasswordPlainText.Contains('"')) {
        throw "-AdminPassword cannot contain a double-quote character; it breaks vmrun argument quoting."
    }
    $guestCredential = [PSCredential]::new($guestUserName, $AdminPassword)

    if ($SkipVmBuild) {
        Write-Log "-SkipVmBuild specified; reusing existing VM at '$vmxFilePath'." -Level INFO
    }
    else {
        Write-Log "Building VM '$VmName' via New-VMwareWorkstationVM.ps1. This usually takes 10-20 minutes, longer on slower storage..." -Level INFO
        $vmBuildParameters = @{
            IsoPath         = $IsoPath
            AdminPassword   = $AdminPassword
            VmName          = $VmName
            VmStoragePath   = $VmStoragePath
            RamMB           = $RamMB
            CpuCount        = $CpuCount
            DiskGB          = $DiskGB
            ComputerName    = $ComputerName
            NetworkType     = $NetworkType
            StaticIpAddress = $StaticIpAddress
            SubnetMask      = $SubnetMask
            DnsServer       = $DnsServer
            TimeoutMinutes  = $TimeoutMinutes
            LogPath         = $logDirectoryPath
        }
        if ($DefaultGateway) {
            $vmBuildParameters['DefaultGateway'] = $DefaultGateway
        }
        & $VmBuilderScriptPath @vmBuildParameters
        Write-Log "VM build complete." -Level SUCCESS
        Write-AppEvent -Enabled $enableEventLogging -SourceName $eventLogSourceName -EntryType Information -EventId 1100 -Message "VM '$VmName' build complete."
    }

    Write-Log "Waiting for guest operations to become ready (timeout: $GuestReadyTimeoutMinutes minute(s))..." -Level INFO
    Wait-GuestOperationsReady -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential -TimeoutMinutes $GuestReadyTimeoutMinutes
    Write-Log "Guest operations ready." -Level SUCCESS

    Write-Log "Staging and copying new-AdDomain payload to guest..." -Level INFO
    $payloadZipFilePath = New-AdDomainPayloadArchive -SourcePath $AdDomainSourcePath -StagingRootPath $stagingRootPath
    Copy-PayloadToGuest -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential -PayloadZipFilePath $payloadZipFilePath
    Write-Log "Payload deployed to C:\temp\new-AdDomain in guest." -Level SUCCESS
    Write-AppEvent -Enabled $enableEventLogging -SourceName $eventLogSourceName -EntryType Information -EventId 1200 -Message 'new-AdDomain payload deployed to guest.'

    Invoke-GuestAdForestDeployment -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential `
        -StaticIpAddress $StaticIpAddress -PrefixLength $staticIpPrefixLength -DefaultGateway $DefaultGateway
    Write-AppEvent -Enabled $enableEventLogging -SourceName $eventLogSourceName -EntryType Information -EventId 1300 -Message 'New-ADForestDeployment.ps1 -CreateScheduledTask launched in guest.'

    $guestLogsDestinationPath = Test-GuestDomainPromotion -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential `
        -GuestReadyTimeoutMinutes $GuestReadyTimeoutMinutes -DeploymentTimeoutMinutes $DeploymentTimeoutMinutes -HostLogsRootPath $logDirectoryPath
    Write-AppEvent -Enabled $enableEventLogging -SourceName $eventLogSourceName -EntryType Information -EventId 1400 -Message 'AD forest promotion verified (ntds.dit present in guest).'

    if ($guestLogsDestinationPath) {
        Write-Log "Guest deployment logs retrieved to '$guestLogsDestinationPath'." -Level INFO
    }

    Write-Log "=== build-lab.ps1 complete ===" -Level SUCCESS

    Write-Log "Directory population has NOT run yet. Log into the guest console as Administrator to trigger Initialize-ADDirectory.ps1 (registered as a logon-triggered scheduled task)." -Level INFO
    Show-PostBuildManualStepNotice
}
catch {
    Write-Log "build-lab.ps1 failed: $($_.Exception.Message)" -Level FATAL
    Write-AppEvent -Enabled $enableEventLogging -SourceName $eventLogSourceName -EntryType Error -EventId 9999 -Message "build-lab.ps1 failed: $($_.Exception.Message)"
    throw
}
finally {
    $guestPasswordPlainText = $null
    $guestCredential        = $null
    if (Test-Path -Path $stagingRootPath) {
        Remove-Item -Path $stagingRootPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-AppEvent -Enabled $enableEventLogging -SourceName $eventLogSourceName -EntryType Information -EventId 1001 -Message 'build-lab.ps1 finished.'
}

#endregion Main
