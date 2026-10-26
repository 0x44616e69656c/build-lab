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

    New-ADForestDeployment.ps1 is launched fire-and-forget (vmrun runProgramInGuest
    -noWait), so its exit status is never seen. On success it calls Restart-Computer
    -Force, and a blocking vmrun call held open across that reboot can hang
    indefinitely. This script therefore verifies promotion by what it can observe:
    C:\Windows\NTDS\ntds.dit appears in the guest, the DC then reboots (a volatile
    registry marker set just before the launch is gone, which only a restart does), and
    after the reboot it reports a domain controller role in the expected domain. It then
    retrieves the guest's deployment logs to the host and checks them for a fatal line. An
    unverified promotion fails the run. Every vmrun call is bounded on the host: the
    process by a timeout (it is killed when the timeout passes) and the reading of its
    output by a separate limit, so a stuck vmrun call cannot hold the run indefinitely.

    Before any static address is given to a new VM (the DC or a member), the address is
    pinged, and the run refuses it if anything answers. Silence is not proof the address
    is free, because a host can block ping.

    Directory population (Initialize-ADDirectory.ps1) is outside this script's scope
    and does NOT run automatically. New-ADForestDeployment.ps1 registers it as a
    scheduled task triggered at the next Administrator logon, so an operator MUST log
    into the guest console as Administrator after the build to start it. This script
    prints a red reminder banner on completion. (To make it run without a logon, the
    task in New-ADForestDeployment.ps1 would have to run as the domain Administrator
    with a stored password under an -AtStartup trigger -- a separate, credential-storing
    change in the new-AdDomain project, not done here.)

    Use -SkipVmBuild to re-run the guest phases (steps 2-3) against an existing VM,
    for fast iteration without paying for a full VM build. A retry works only if the
    earlier attempt failed before AD DS was installed. Once AD-Domain-Services is
    installed, the deployment's pre-flight refuses to run, so revert the VM to a
    pre-deployment snapshot first. It is not a way to touch a working DC: it deletes
    C:\temp\new-AdDomain in the guest (including the deployment and directory population
    logs under its logs folder), copies a fresh payload, and relaunches
    New-ADForestDeployment.ps1. It cannot pass network values to the deployment, so the
    guest's DHCP-fallback repair is not available on this path. To add member servers to
    an existing DC, use -AddMemberServers instead.

    -MemberServerCount (default 0) adds member servers once the DC promotion is verified
    (above). Members are built one at a time with the same New-VMwareWorkstationVM.ps1,
    are NOT promoted, and are joined to the domain named in new-AdDomain's
    global-config.ps1:
      - Names are SRVR-NN (VM name and computer name are the same), using the lowest free
        numbers, gaps first. A number is taken if its folder exists under -VmStoragePath,
        if it is the DC's -VmName or -ComputerName, or (with -AddMemberServers) if AD
        already holds a computer object of that name. Taken numbers are never reused.
      - Each member's address follows its number: DC address + 10 + (number - 1), so
        SRVR-03 is always DC + 12. Every address is validated and pinged before anything
        is built, and pinged again just before that member's build.
      - DNS is the DC's address. Members get the same -SubnetMask, -NetworkType and
        -DefaultGateway (if given) that this run was passed.
      - After the build, the member must answer ping on its address.
      - The join runs Add-Computer in the guest synchronously without a reboot, then
        reboots fire-and-forget and polls until the guest has rebooted and reports
        PartOfDomain for the expected domain.
      - Members land in the default CN=Computers container. OU=Servers does not exist
        until directory population runs, so moving them there is a separate later step
        (-MoveMemberServers, below).
    A member that fails is logged and the rest continue. The run then prints a summary
    and throws: exit code 1 under powershell.exe -File, or a terminating error raised to
    the caller when invoked in a session. The cap on -MemberServerCount is
    $maxMemberServerCount in the Variables region.

    -AddMemberServers builds and joins members against an EXISTING DC without touching
    it: no payload copy, no deployment relaunch. It checks that the DC answers guest
    operations, that ntds.dit is present, and that the DC's own domain role, domain,
    address and prefix length match global-config.ps1 and the values passed to this run.
    The gateway is checked only when -DefaultGateway is given; without it, the gateway is
    not checked and members get none. These checks run before the member plan, so a wrong
    -StaticIpAddress is reported as such. -IsoPath, the DC's -StaticIpAddress and
    -MemberServerCount are required.

    -MoveMemberServers is the later OU=Servers step mentioned above, run on its own after
    an Administrator has logged into the DC and directory population has finished.
    Against the existing DC it moves every SRVR-NN computer object from the domain's
    default computers container to OU=Servers (both read from the DC and
    global-config.ps1), then re-queries to confirm none are left behind. It first checks
    that the VM is a DC in global-config.ps1's domain. It fails with a clear message if
    OU=Servers does not exist yet, and moves nothing if more objects match than
    $maxMemberServerCount. Re-running it is harmless: objects already in OU=Servers are
    reported and left alone.
.PARAMETER IsoPath
    Windows Server 2025 installation ISO. Required for a full build and for
    -AddMemberServers (members are built from it).
.PARAMETER AdminPassword
    Password for the built-in Administrator of every VM built, and the credential vmrun
    uses for guest operations. After promotion it is also the domain Administrator's
    password, which joins the members. Must not be empty, contain a double quote, or
    contain whitespace and end with a backslash.
.PARAMETER VmStoragePath
    Folder that holds one subfolder per VM (<VmStoragePath>\<VmName>\<VmName>.vmx).
    Member folders (SRVR-NN) are created here too.
.PARAMETER StaticIpAddress
    The DC's IPv4 address. Required for a full build and for -AddMemberServers (where it is
    the existing DC's address, checked against the DC). It is the base for member
    addresses and the members' DNS server. On NAT it must end in .3 to .127. Not accepted
    with -SkipVmBuild or -MoveMemberServers.
.PARAMETER VmName
    The DC's VM name (folder and .vmx name). Default 'WS2025-Server'.
.PARAMETER ComputerName
    The DC's Windows computer name. Default 'WIN2025'.
.PARAMETER RamMB
    DC memory in MB. Default 4096.
.PARAMETER CpuCount
    DC virtual CPUs. Default 2.
.PARAMETER DiskGB
    DC disk size in GB. Default 60.
.PARAMETER NetworkType
    VMware network for every VM built: 'nat' (default, VMnet8), 'bridged' or 'hostonly'.
.PARAMETER SubnetMask
    Subnet mask for every VM built. Default 255.255.255.0. 0.0.0.0 is refused.
.PARAMETER DefaultGateway
    Gateway for every VM built. Optional, but must be inside the DC's subnet when given (on
    VMware NAT, net.2). The deployment's DHCP-fallback repair needs it.
.PARAMETER DnsServer
    The DC's DNS server during its build. Default 8.8.8.8. Members always use the DC's
    address instead.
.PARAMETER TimeoutMinutes
    Passed to New-VMwareWorkstationVM.ps1 for each VM build. Default 90.
.PARAMETER VmBuilderScriptPath
    Path to New-VMwareWorkstationVM.ps1. Default: the sibling project folder.
.PARAMETER AdDomainSourcePath
    Path to the new-AdDomain project. Default: the sibling project folder.
.PARAMETER GuestReadyTimeoutMinutes
    How long to wait for a guest to answer guest operations, and how long to wait for the
    DC's promotion reboot after ntds.dit appears. Default 20. Checked between polls, so
    the last poll can finish a few minutes after it.
.PARAMETER DeploymentTimeoutMinutes
    How long to poll for ntds.dit after launching the forest deployment. Default 30.
.PARAMETER MemberServerCount
    Number of member servers to build and join. Default 0. Capped by
    $maxMemberServerCount in the Variables region.
.PARAMETER MemberRamMB
    Member memory in MB. Default 2048.
.PARAMETER MemberCpuCount
    Member virtual CPUs. Default 1.
.PARAMETER MemberDiskGB
    Member disk size in GB. Default 60.
.PARAMETER DomainJoinTimeoutMinutes
    Per member, how long to wait for the post-join reboot and domain membership. Default 20.
    Checked between polls, so the last poll can finish a few minutes after it.
.PARAMETER SkipVmBuild
    Re-run the DC guest phases against an existing, not yet promoted VM. Refused on a
    promoted DC. Cannot be combined with member servers.
.PARAMETER MoveMemberServers
    Separate later step: move SRVR-NN computer objects to OU=Servers on the existing DC.
.PARAMETER AddMemberServers
    Build and join -MemberServerCount members against an existing DC without touching it.
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
    $pw = Read-Host -Prompt 'Guest Administrator password' -AsSecureString
    .\build-lab.ps1 -IsoPath 'C:\ISOs\WS2025.iso' -AdminPassword $pw `
        -VmStoragePath 'C:\VMs' -StaticIpAddress '192.168.220.50' -DefaultGateway '192.168.220.2'
.EXAMPLE
    $pw = Read-Host -Prompt 'Guest Administrator password' -AsSecureString
    .\build-lab.ps1 -SkipVmBuild -AdminPassword $pw -VmStoragePath 'C:\VMs' -VmName 'LabServer01'
.EXAMPLE
    # DC at 192.168.220.50 plus three member servers SRVR-01..SRVR-03 at
    # 192.168.220.60-62, each using DNS 192.168.220.50. On NAT the last member must still
    # fall in net.3-net.127 (see the first example).
    $pw = Read-Host -Prompt 'Guest Administrator password' -AsSecureString
    .\build-lab.ps1 -IsoPath 'C:\ISOs\WS2025.iso' -AdminPassword $pw `
        -VmStoragePath 'C:\VMs' -StaticIpAddress '192.168.220.50' -DefaultGateway '192.168.220.2' `
        -MemberServerCount 3
.EXAMPLE
    # Add member servers to an existing DC without touching the DC. -IsoPath and the DC's
    # -StaticIpAddress are required because the members are still built from the ISO and
    # numbered from the DC's address.
    $pw = Read-Host -Prompt 'Guest Administrator password' -AsSecureString
    .\build-lab.ps1 -AddMemberServers -AdminPassword $pw -VmStoragePath 'C:\VMs' -VmName 'LabServer01' `
        -IsoPath 'C:\ISOs\WS2025.iso' -StaticIpAddress '192.168.220.50' -DefaultGateway '192.168.220.2' `
        -MemberServerCount 2
.EXAMPLE
    # Later step, after logging into the DC and letting directory population finish: move
    # the joined SRVR-NN member servers from CN=Computers to OU=Servers.
    $pw = Read-Host -Prompt 'Guest Administrator password' -AsSecureString
    .\build-lab.ps1 -MoveMemberServers -AdminPassword $pw -VmStoragePath 'C:\VMs' -VmName 'LabServer01'
.OUTPUTS
    None to the pipeline. Progress goes to the console and to logs\build-lab_<timestamp>.log;
    WARN, ERROR and FATAL rows also go to logs\build-lab-errors_<timestamp>.csv; key events go
    to the Application event log. The VM builder writes its own VMDeploy_* log and
    transcript to the same logs folder, and guest deployment logs are retrieved into
    logs\guest-<timestamp>\. A failure ends in a terminating error (exit code 1 under
    powershell.exe -File).
.NOTES
    Version:      2.0.0
    Author:       Daniel Owen
    Release Date: 2026-10-26
    Requirements: VMware Workstation 17+ (vmrun.exe), Windows PowerShell 5.1 (Desktop
                  edition, enforced by #Requires), local
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

#Requires -Version 5.1
#Requires -PSEdition Desktop

[CmdletBinding(DefaultParameterSetName = 'Build')]
param (
    # --- Passed through to New-VMwareWorkstationVM.ps1 ---
    # -IsoPath and -StaticIpAddress are also required by -AddMemberServers: members are
    # built from the ISO and numbered from the DC's address.
    [Parameter(Mandatory, ParameterSetName = 'Build')]
    [Parameter(Mandatory, ParameterSetName = 'AddMembers')]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$IsoPath,

    [Parameter(Mandatory)]
    [SecureString]$AdminPassword,

    [Parameter(Mandatory)]
    [string]$VmStoragePath,

    [Parameter(Mandatory, ParameterSetName = 'Build')]
    [Parameter(Mandatory, ParameterSetName = 'AddMembers')]
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

    # --- Member servers ---
    # Upper bound here only keeps the SRVR-NN two-digit naming valid. The working cap is
    # $maxMemberServerCount in the Variables region, checked before anything is built.
    [ValidateRange(0, 99)]
    [int]$MemberServerCount = 0,

    [ValidateRange(512, 65536)]
    [int]$MemberRamMB = 2048,

    [ValidateRange(1, 64)]
    [int]$MemberCpuCount = 1,

    [ValidateRange(20, 2048)]
    [int]$MemberDiskGB = 60,

    # Upper bound on how long to poll, per member, for the post-join reboot to finish and the
    # guest to report domain membership.
    [ValidateRange(1, 120)]
    [int]$DomainJoinTimeoutMinutes = 20,

    [Parameter(ParameterSetName = 'GuestOnly')]
    [switch]$SkipVmBuild,

    # Separate later step, run on its own against the existing DC once directory population
    # has created OU=Servers: moves joined member servers out of the default computers
    # container. Builds nothing.
    [Parameter(Mandatory, ParameterSetName = 'MoveMembers')]
    [switch]$MoveMemberServers,

    # Builds and joins -MemberServerCount members against an EXISTING DC without touching
    # the DC (no payload copy, no deployment relaunch, unlike -SkipVmBuild).
    [Parameter(Mandatory, ParameterSetName = 'AddMembers')]
    [switch]$AddMemberServers
)

#region Include
$includeRootPath = Join-Path -Path $PSScriptRoot -ChildPath 'include'
foreach ($includeFileName in @('Sanitization.ps1', 'Logging.ps1', 'EventLogging.ps1', 'Retry.ps1', 'FileUtilities.ps1')) {
    $includeFilePath = Join-Path -Path $includeRootPath -ChildPath $includeFileName
    if (-not (Test-Path -LiteralPath $includeFilePath -PathType Leaf)) {
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
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            return $candidatePath
        }
    }
    throw "vmrun.exe not found under VMware Workstation Program Files directories. Ensure VMware Workstation 17+ is installed."
}

function Invoke-VmrunCommand {
    # Runs vmrun.exe with two host-side bounds. vmrun has no timeout of its own, so a call
    # that never returns (the field-confirmed case is one held open across a guest reboot)
    # would otherwise hang the whole run. -TimeoutSeconds bounds the process: on timeout it
    # is killed and the call throws. -OutputDrainTimeoutSeconds bounds reading its output
    # after it exits, because the output pipes stay open while any process it started still
    # holds them. Killing vmrun ends only the host-side call. A guest program it started
    # keeps running (seen 2026-10-25, when a runProgramInGuest killed after 10 s still
    # completed its 60 s guest command).
    #
    # vmrun writes its output as UTF-8 (a guest file name with an accented character came
    # back as C3 A9 on 2026-10-25). Both streams are decoded as UTF-8 explicitly, because
    # without that .NET Framework decodes with the console's code page and garbles
    # non-ASCII text under the common default 437.
    #
    # The child runs in PowerShell's current filesystem location, as a native '&' call
    # would, so relative paths in the arguments resolve the same way as in the rest of the
    # script. ProcessStartInfo would otherwise use the process directory, which PowerShell
    # does not change on Set-Location.
    #
    # The process is started through System.Diagnostics.Process, so the command line is
    # built here, quoting each argument by the Windows (CommandLineToArgvW / MSVC runtime)
    # rules. Checked with an argv-echo program on 2026-10-24: every argument shape this
    # script passes arrives exactly as with PowerShell 5.1's own native passing, and two
    # shapes that 5.1's passing mangles arrive intact (an empty argument, and one that
    # contains a space and ends in a backslash).
    #
    # This function is invoked by reference inside .GetNewClosure() retry blocks, which do
    # not reliably resolve other script functions by name (see Copy-PayloadToGuest). It
    # therefore calls no other script function; the quoting helper is a local scriptblock.
    #
    # -AllowNonZeroExit returns { ExitCode; Output } instead of throwing on a non-zero exit
    # code, for vmrun queries that report their answer that way (fileExistsInGuest,
    # directoryExistsInGuest). Output containing "Error" still throws.
    param (
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]]$ArgumentList,
        [Parameter(Mandatory)]
        [string]$OperationName,
        [string[]]$RedactedTokens = @(),
        [ValidateRange(1, 86400)]
        [int]$TimeoutSeconds = 600,
        [ValidateRange(1, 3600)]
        [int]$OutputDrainTimeoutSeconds = 30,
        [switch]$AllowNonZeroExit
    )
    $quoteArgument = {
        param ([AllowEmptyString()][string]$Argument)
        if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') { return $Argument }
        $quotedArgument     = New-Object -TypeName System.Text.StringBuilder
        $null               = $quotedArgument.Append('"')
        $pendingBackslashes = 0
        foreach ($argumentCharacter in $Argument.ToCharArray()) {
            if ($argumentCharacter -eq '\') {
                $pendingBackslashes++
                continue
            }
            if ($argumentCharacter -eq '"') {
                # Backslashes before a quote are doubled, then the quote itself is escaped.
                $null = $quotedArgument.Append('\' * (2 * $pendingBackslashes + 1)).Append('"')
            }
            else {
                $null = $quotedArgument.Append('\' * $pendingBackslashes).Append($argumentCharacter)
            }
            $pendingBackslashes = 0
        }
        # Trailing backslashes are doubled so they cannot escape the closing quote.
        $null = $quotedArgument.Append('\' * (2 * $pendingBackslashes)).Append('"')
        return $quotedArgument.ToString()
    }

    $processStartInfo = New-Object -TypeName System.Diagnostics.ProcessStartInfo
    $processStartInfo.FileName               = $VmrunPath
    $processStartInfo.Arguments              = (@($ArgumentList | ForEach-Object { & $quoteArgument $_ })) -join ' '
    $processStartInfo.UseShellExecute        = $false
    $processStartInfo.RedirectStandardOutput = $true
    $processStartInfo.RedirectStandardError  = $true
    $processStartInfo.StandardOutputEncoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    $processStartInfo.StandardErrorEncoding  = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    $processStartInfo.CreateNoWindow         = $true
    $processStartInfo.WorkingDirectory       = (Get-Location -PSProvider FileSystem).ProviderPath

    $vmrunProcess = [System.Diagnostics.Process]::Start($processStartInfo)
    try {
        # Both streams are read asynchronously so a full pipe buffer on one cannot stall the
        # process while this waits on the other.
        $standardOutputTask = $vmrunProcess.StandardOutput.ReadToEndAsync()
        $standardErrorTask  = $vmrunProcess.StandardError.ReadToEndAsync()
        if (-not $vmrunProcess.WaitForExit($TimeoutSeconds * 1000)) {
            $exitedBeforeKill = $false
            try {
                $vmrunProcess.Kill()
            }
            catch [System.InvalidOperationException] {
                # vmrun exited between the timeout and the kill, so it finished after all:
                # fall through and use its result like any other completed call.
                $exitedBeforeKill = $true
            }
            if (-not $exitedBeforeKill) {
                $null = $vmrunProcess.WaitForExit(5000)
                throw "vmrun operation '$OperationName' timed out after $TimeoutSeconds second(s) and was stopped. Anything it started in the guest may still be running."
            }
        }
        # The reads finish at EOF, which can come later than the exit when a process vmrun
        # started still holds the pipes, so the wait for them is bounded too.
        $outputReadTasks = [System.Threading.Tasks.Task[]]@($standardOutputTask, $standardErrorTask)
        if (-not [System.Threading.Tasks.Task]::WaitAll($outputReadTasks, $OutputDrainTimeoutSeconds * 1000)) {
            throw "vmrun operation '$OperationName' exited (exit code $($vmrunProcess.ExitCode)), but its output did not finish within $OutputDrainTimeoutSeconds second(s). A process it started may still hold its output pipes."
        }
        $exitCode      = $vmrunProcess.ExitCode
        $commandOutput = @(($standardOutputTask.Result + "`n" + $standardErrorTask.Result) -split "`r?`n" | Where-Object { $_ -ne '' })
    }
    finally {
        # Process.Dispose does not close the redirected readers on .NET Framework, so they are
        # disposed here. Disposing them with a read still pending (the drain-timeout case) is
        # safe: the pending read faults and is discarded (checked 2026-10-24).
        $vmrunProcess.StandardOutput.Dispose()
        $vmrunProcess.StandardError.Dispose()
        $vmrunProcess.Dispose()
    }

    foreach ($redactedToken in $RedactedTokens) {
        if ($redactedToken) {
            $commandOutput = @($commandOutput | ForEach-Object { $_ -replace [regex]::Escape($redactedToken), '***' })
        }
    }

    if ($AllowNonZeroExit) {
        if ($commandOutput -match 'Error') {
            throw "vmrun operation '$OperationName' failed (exit code $exitCode): $($commandOutput -join ' ')"
        }
        return [pscustomobject]@{
            ExitCode = $exitCode
            Output   = $commandOutput
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
    # a normal query result, not a failure, so the exit code is read rather than thrown on.
    # A short timeout suits a query: it should answer in seconds.
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
        [string]$GuestPath,
        [int]$TimeoutSeconds = 120
    )
    $guestUserName          = $GuestCredential.UserName
    $guestPasswordPlainText = $GuestCredential.GetNetworkCredential().Password

    $existCommand = if ($PathType -eq 'File') { 'fileExistsInGuest' } else { 'directoryExistsInGuest' }
    $queryResult  = Invoke-VmrunCommand -VmrunPath $VmrunPath -OperationName "$existCommand $GuestPath" -RedactedTokens @($guestPasswordPlainText) `
        -TimeoutSeconds $TimeoutSeconds -AllowNonZeroExit `
        -ArgumentList @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText, $existCommand, $VmxFilePath, $GuestPath)
    return ($queryResult.ExitCode -eq 0)
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
        [int]$PollIntervalSeconds = 15,
        # Per-probe vmrun timeout. Both probes answer in seconds on a healthy guest; the
        # bound keeps one stuck probe from outliving -TimeoutMinutes by more than this.
        [int]$ProbeTimeoutSeconds = 120
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
                -RedactedTokens @($guestPasswordPlainText) -TimeoutSeconds $ProbeTimeoutSeconds
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
                        -RedactedTokens @($guestPasswordPlainText) -TimeoutSeconds $ProbeTimeoutSeconds
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
        # Folders and files the guest never needs: build output, logs, and the author's
        # working notes. A public clone of new-AdDomain does not contain the notes, so
        # excluding them there is harmless. robocopy matches these names at any depth.
        [string[]]$ExcludedDirectoryNames = @('.git', '.claude', 'junk', 'logs', 'artifacts'),
        [string[]]$ExcludedFileNames = @('.gitignore-publish', 'journal.md', 'gotchas.md', 'updates.md', 'changes.md',
            'AD_Deployment_Consolidated_Plan.md', 'todo.md')
    )
    $stagingPayloadPath = Join-Path -Path $StagingRootPath -ChildPath 'new-AdDomain'
    $null = New-Item -ItemType Directory -Path $StagingRootPath -Force

    $robocopyArgumentList = @($SourcePath, $stagingPayloadPath, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/XD') + $ExcludedDirectoryNames + @('/XF') + $ExcludedFileNames
    # Output is kept so a failure can show robocopy's own error text, not just the code.
    $robocopyOutput = & robocopy @robocopyArgumentList
    $robocopyExitCode = $LASTEXITCODE
    # robocopy uses exit codes 0-7 for success (including "files copied" and "extra
    # files/dirs"); only 8+ indicates a real failure.
    if ($robocopyExitCode -ge 8) {
        $robocopyErrorText = (@($robocopyOutput) | Where-Object { $_ } | Select-Object -Last 10) -join ' '
        throw "robocopy failed copying '$SourcePath' to '$stagingPayloadPath' (exit code $robocopyExitCode). robocopy output: $robocopyErrorText"
    }

    $payloadZipFilePath = Join-Path -Path $StagingRootPath -ChildPath 'new-AdDomain.zip'
    if (Test-Path -LiteralPath $payloadZipFilePath) {
        Remove-Item -LiteralPath $payloadZipFilePath -Force
    }
    Compress-Archive -Path $stagingPayloadPath -DestinationPath $payloadZipFilePath -Force

    return $payloadZipFilePath
}

function Initialize-GuestTempDirectory {
    # Ensures the guest staging folder (C:\temp) exists. Every guest-side file this script
    # writes lives there: the new-AdDomain payload on the DC and the result files of
    # Invoke-GuestPowerShellCommand on every guest. A freshly built member server does not
    # have it, so this runs as soon as each guest answers guest operations.
    #
    # createDirectoryInGuest fails when the directory already exists, so existence is
    # checked first, and checked again inside the retry: if a create succeeded but its
    # response was lost, the repeat attempt finds the folder and does not try again.
    param (
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [string]$VmxFilePath,
        [Parameter(Mandatory)]
        [PSCredential]$GuestCredential,
        [string]$GuestTempPath = 'C:\temp'
    )
    $guestUserName          = $GuestCredential.UserName
    $guestPasswordPlainText = $GuestCredential.GetNetworkCredential().Password
    $redactedTokens         = @($guestPasswordPlainText)

    if (Test-GuestPathExists -VmrunPath $VmrunPath -VmxFilePath $VmxFilePath -GuestCredential $GuestCredential -PathType Directory -GuestPath $GuestTempPath) {
        return
    }

    # Resolved to a scriptblock value for the closure below (see Copy-PayloadToGuest). The
    # re-check inside the closure calls vmrun's directoryExistsInGuest through it directly,
    # rather than Test-GuestPathExists, because a captured function that itself calls
    # another script function by name (Test-GuestPathExists calls Invoke-VmrunCommand) is
    # not reliably resolvable inside the closure.
    $invokeVmrunCommand = ${function:Invoke-VmrunCommand}

    $null = Invoke-CommandWithRetry -OperationName "createDirectoryInGuest $GuestTempPath" -ThrowOnFailure -ScriptBlock {
        $existsResult = & $invokeVmrunCommand -VmrunPath $VmrunPath -RedactedTokens $redactedTokens -OperationName "directoryExistsInGuest $GuestTempPath" `
            -TimeoutSeconds 120 -AllowNonZeroExit `
            -ArgumentList @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText, 'directoryExistsInGuest', $VmxFilePath, $GuestTempPath)
        if ($existsResult.ExitCode -ne 0) {
            $null = & $invokeVmrunCommand -VmrunPath $VmrunPath -RedactedTokens $redactedTokens -OperationName "createDirectoryInGuest $GuestTempPath" `
                -ArgumentList @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText, 'createDirectoryInGuest', $VmxFilePath, $GuestTempPath)
        }
    }.GetNewClosure()
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
    # "term ... is not recognized". Resolving the function to a variable
    # here (where it is in scope) sidesteps the name lookup entirely.
    $invokeVmrunCommand = ${function:Invoke-VmrunCommand}

    $guestPathExistsParameters = @{
        VmrunPath       = $VmrunPath
        VmxFilePath     = $VmxFilePath
        GuestCredential = $GuestCredential
    }

    Initialize-GuestTempDirectory @guestPathExistsParameters -GuestTempPath $guestTempPath

    # Both guest cleanups (this one and the zip deletion below) re-check inside the guest
    # command before removing, so a retry after a removal whose response was lost succeeds
    # instead of failing on the now-missing path.
    if (Test-GuestPathExists @guestPathExistsParameters -PathType Directory -GuestPath $guestPayloadPath) {
        $null = Invoke-CommandWithRetry -OperationName "remove existing $guestPayloadPath in guest" -ThrowOnFailure -ScriptBlock {
            $null = & $invokeVmrunCommand -VmrunPath $VmrunPath -RedactedTokens $redactedTokens -OperationName "remove existing $guestPayloadPath" `
                -ArgumentList @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText, 'runProgramInGuest', $VmxFilePath, $guestPowerShellExe,
                    '-NoProfile', '-Command', "if (Test-Path -LiteralPath '$guestPayloadPath') { Remove-Item -LiteralPath '$guestPayloadPath' -Recurse -Force }")
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

    $null = Invoke-CommandWithRetry -OperationName 'remove new-AdDomain.zip in guest' -ThrowOnFailure -ScriptBlock {
        $null = & $invokeVmrunCommand -VmrunPath $VmrunPath -RedactedTokens $redactedTokens -OperationName 'remove new-AdDomain.zip in guest' `
            -ArgumentList @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText, 'runProgramInGuest', $VmxFilePath, $guestPowerShellExe,
                '-NoProfile', '-Command', "if (Test-Path -LiteralPath '$guestZipFilePath') { Remove-Item -LiteralPath '$guestZipFilePath' -Force }")
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
    # repair a DHCP fallback from the unattended specialize pass in place. Two limits: the
    # repair also needs -DefaultGateway (without one the guest script throws under
    # -NonInteractive when the adapter is on DHCP), and a -SkipVmBuild run passes no
    # network values at all, so no repair is possible on that path.
    #
    # Returns the launch error message if vmrun reported one, otherwise $null, so the
    # promotion timeout message can name the launch failure as the likely cause.
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
        return $null
    }
    catch {
        # -noWait only reports a launch failure (e.g. bad path/credentials). Log and continue;
        # if the launch truly failed, ntds.dit never appears and Test-GuestDomainPromotion
        # fails with a timeout that names this launch error rather than a silent hang.
        $launchErrorMessage = $_.Exception.Message
        if ($logCommand) {
            Write-Log "vmrun reported an error launching New-ADForestDeployment.ps1: $launchErrorMessage Continuing to artifact verification." -Level WARN
        }
        return $launchErrorMessage
    }
}

function Get-DeploymentLogFatalLine {
    # Returns the last "terminated with fatal error" line from the newest
    # New-ADForestDeployment log under a retrieved guest log folder, or $null when there is
    # no folder, no log, or no such line.
    param (
        [string]$HostLogsDestinationPath
    )
    if (-not $HostLogsDestinationPath) { return $null }
    $latestDeploymentLogFile = Get-ChildItem -LiteralPath $HostLogsDestinationPath -Filter 'New-ADForestDeployment-*.log' -Recurse |
        Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
    if (-not $latestDeploymentLogFile) { return $null }
    $fatalLogMatch = Get-Content -LiteralPath $latestDeploymentLogFile.FullName |
        Select-String -Pattern 'terminated with fatal error' | Select-Object -Last 1
    if ($fatalLogMatch) { return $fatalLogMatch.Line }
    return $null
}

function Test-GuestDomainPromotion {
    # Verifies the forest promotion launched fire-and-forget by Invoke-GuestAdForestDeployment.
    #   Phase 1: poll for ntds.dit, which means promotion reached the database stage.
    #   Phase 2: poll until the DC has rebooted since the launch, shown by the volatile boot
    #            marker (Set-GuestBootMarker, set by the caller just before the launch) being
    #            gone. New-ADForestDeployment.ps1 reboots only on success. A reboot alone is
    #            not enough, though: the guest must then report a domain controller role
    #            (DomainRole 4 or 5) in -ExpectedDomainName, so an unrelated reboot of a
    #            failed promotion is not mistaken for success.
    #   Phase 3: retrieve the guest logs and look for a fatal line. The deployment can log one
    #            AFTER promotion (for example while registering the population task) and
    #            still reboot.
    # Every poll uses a short per-call vmrun timeout, so a call that the reboot interrupts
    # cannot hold the run open (the 2026-07-11 hang pattern). -GuestReadyTimeoutMinutes is
    # checked between polls, so the last poll can finish a little after it.
    #
    # Returns { HostLogsPath; PromotionVerified; NotVerifiedReason; FatalLogLine }. Throws
    # if ntds.dit never appears. An unverified promotion is reported, not thrown, so the
    # guest logs are retrieved first; the caller fails the run.
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
        [string]$HostLogsRootPath,
        [Parameter(Mandatory)]
        [string]$HostStagingPath,
        [Parameter(Mandatory)]
        [string]$ExpectedDomainName,
        # The launch error from Invoke-GuestAdForestDeployment, if any. Used only to explain
        # a timeout.
        [string]$LaunchErrorMessage,
        [int]$PollIntervalSeconds = 30,
        [int]$ProbeTimeoutSeconds = 120
    )
    $logCommand   = Get-Command -Name Write-Log -CommandType Function -ErrorAction SilentlyContinue
    $ntdsFilePath = 'C:\Windows\NTDS\ntds.dit'

    # Phase 1: the guest was launched fire-and-forget, so it is still installing AD DS and
    # promoting. Poll for the ntds.dit artifact over the full deployment window.
    # Guest-operations errors here are transient (the guest may be busy, or has begun its
    # promotion reboot), so keep polling rather than aborting. How long promotion keeps
    # running after ntds.dit appears, before the script's reboot, has not been measured.
    if ($logCommand) {
        Write-Log "Polling for '$ntdsFilePath' in guest (deployment timeout: $DeploymentTimeoutMinutes minute(s))..." -Level INFO
    }
    $deploymentDeadline    = (Get-Date).AddMinutes($DeploymentTimeoutMinutes)
    $promotionArtifactSeen = $false
    while ((Get-Date) -lt $deploymentDeadline) {
        try {
            if (Test-GuestPathExists -VmrunPath $VmrunPath -VmxFilePath $VmxFilePath -GuestCredential $GuestCredential -PathType File `
                -GuestPath $ntdsFilePath -TimeoutSeconds $ProbeTimeoutSeconds) {
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
        Start-Sleep -Seconds $PollIntervalSeconds
    }

    if (-not $promotionArtifactSeen) {
        $hostLogsDestinationPath = Copy-GuestLogsToHost -VmrunPath $VmrunPath -VmxFilePath $VmxFilePath -GuestCredential $GuestCredential -HostLogsRootPath $HostLogsRootPath
        $fatalLogLine = Get-DeploymentLogFatalLine -HostLogsDestinationPath $hostLogsDestinationPath
        # Point at the most likely cause first. Raising the timeout only helps when nothing
        # says the deployment failed.
        $timeoutMessage = "AD forest promotion did not complete within $DeploymentTimeoutMinutes minute(s): '$ntdsFilePath' not found in guest."
        if ($LaunchErrorMessage) {
            $timeoutMessage += " The deployment launch reported an error, so it most likely never started: $LaunchErrorMessage"
        }
        if ($fatalLogLine) {
            $timeoutMessage += " The guest deployment failed. Guest log: $fatalLogLine"
        }
        if (-not $LaunchErrorMessage -and -not $fatalLogLine) {
            $timeoutMessage += " The guest deployment may have failed or is still installing. Raise -DeploymentTimeoutMinutes if the guest is legitimately slow."
        }
        $timeoutMessage += if ($hostLogsDestinationPath) { " Retrieved guest logs: '$hostLogsDestinationPath'." } else { " Guest logs could not be retrieved; they are in C:\temp\new-AdDomain\logs in the guest." }
        throw $timeoutMessage
    }

    # Phase 2: wait for the success-path reboot, then check what the rebooted guest is.
    if ($logCommand) {
        Write-Log "'$ntdsFilePath' present -- promotion reached the database stage. Waiting up to $GuestReadyTimeoutMinutes minute(s) for the promotion reboot..." -Level INFO
    }
    $rebootDeadline    = (Get-Date).AddMinutes($GuestReadyTimeoutMinutes)
    $rebootObserved    = $false
    $guestState        = $null
    $lastObservedState = 'not yet observed'
    while ((Get-Date) -lt $rebootDeadline) {
        Start-Sleep -Seconds $PollIntervalSeconds
        try {
            $guestState = Get-GuestDomainState -VmrunPath $VmrunPath -VmxFilePath $VmxFilePath -GuestCredential $GuestCredential `
                -HostStagingPath $HostStagingPath -VmrunTimeoutSeconds $ProbeTimeoutSeconds
            $lastObservedState = "boot marker present=$($guestState.BootMarkerPresent), DomainRole $($guestState.DomainRole), Domain '$($guestState.Domain)', uptime $($guestState.UptimeSeconds) s"
            if (-not $guestState.BootMarkerPresent) {
                $rebootObserved = $true
                break
            }
        }
        catch {
            if ($logCommand) {
                Write-Log "DC state query not answered yet (expected while it reboots): $($_.Exception.Message)" -Level DEBUG
            }
        }
        $minutesRemaining = [math]::Round(($rebootDeadline - (Get-Date)).TotalMinutes, 1)
        if ($logCommand) {
            Write-Log "Promotion reboot not observed yet (last state: $lastObservedState). $minutesRemaining minute(s) remaining." -Level INFO
        }
    }

    $promotionVerified = $false
    $notVerifiedReason = $null
    if (-not $rebootObserved) {
        $notVerifiedReason = "no reboot was observed within $GuestReadyTimeoutMinutes minute(s) (last state: $lastObservedState)"
    }
    elseif (@(4, 5) -notcontains [int]$guestState.DomainRole -or $guestState.Domain -ne $ExpectedDomainName) {
        $notVerifiedReason = "the guest rebooted but is not a domain controller in '$ExpectedDomainName' ($lastObservedState)"
    }
    else {
        $promotionVerified = $true
    }

    # Phase 3: retrieve guest deployment logs (best-effort) and check them for a fatal line.
    $hostLogsDestinationPath = Copy-GuestLogsToHost -VmrunPath $VmrunPath -VmxFilePath $VmxFilePath -GuestCredential $GuestCredential -HostLogsRootPath $HostLogsRootPath
    $fatalLogLine = Get-DeploymentLogFatalLine -HostLogsDestinationPath $hostLogsDestinationPath

    if ($promotionVerified) {
        if ($fatalLogLine -and $logCommand) {
            Write-Log "The DC rebooted after promotion, but its deployment log records a fatal error: $fatalLogLine Directory population's logon-triggered scheduled task may not have been registered; check Task Scheduler on the DC before relying on it." -Level WARN
        }
        if ($logCommand) {
            Write-Log "AD forest promotion verified: '$ntdsFilePath' present, the DC rebooted, and it reports DomainRole $($guestState.DomainRole) in '$ExpectedDomainName'." -Level SUCCESS
        }
    }
    elseif ($logCommand) {
        $fatalLogDetail = if ($fatalLogLine) { " Guest log: $fatalLogLine" } else { '' }
        # -SkipVmBuild is deliberately not suggested: with ntds.dit present it refuses this VM.
        Write-Log "AD forest promotion NOT verified: '$ntdsFilePath' is present, but $notVerifiedReason. The deployment reboots only on success, so it may have failed after creating the database or may still be running. Check the DC console and the guest logs. If the DC finishes promoting, add members with -AddMemberServers, which checks the DC role first. If it did not promote, revert the VM to a pre-deployment snapshot, or delete it and run a full build again.$fatalLogDetail" -Level WARN
    }

    return [pscustomobject]@{
        HostLogsPath      = $hostLogsDestinationPath
        PromotionVerified = $promotionVerified
        NotVerifiedReason = $notVerifiedReason
        FatalLogLine      = $fatalLogLine
    }
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

        # The guest zip is only a transfer copy. Removing it is best effort: the logs are
        # already on the host, so a failure here is not a retrieval failure.
        try {
            $null = Invoke-VmrunCommand -VmrunPath $VmrunPath -RedactedTokens $redactedTokens -OperationName 'remove guest deployment log zip' `
                -ArgumentList @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText, 'runProgramInGuest', $VmxFilePath, $guestPowerShellExe,
                    '-NoProfile', '-Command', "if (Test-Path -LiteralPath '$guestLogsZipPath') { Remove-Item -LiteralPath '$guestLogsZipPath' -Force }")
        }
        catch {
            if ($logCommand) {
                Write-Log "Could not remove '$guestLogsZipPath' in the guest (harmless; overwritten by the next retrieval): $($_.Exception.Message)" -Level DEBUG
            }
        }

        return $hostDestinationPath
    }
    catch {
        if ($logCommand) {
            Write-Log "Could not retrieve guest deployment logs: $($_.Exception.Message)" -Level WARN
        }
        return $null
    }
    finally {
        # Covers both paths: after a successful expand, and after a failed expand that
        # would otherwise leave a fixed-name zip in the host logs folder for the next run.
        Remove-Item -LiteralPath $hostLogsZipPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-VmBuilderArgumentTable {
    # Builds the splat for New-VMwareWorkstationVM.ps1. Shared by the DC build and every
    # member server build so both hand the child script the same set of arguments.
    # -TempPath gives each build its own working folder for the child's answer file and
    # answer ISO. The child's default (%TEMP%\VMDeploy) is shared, so two build-lab runs at
    # once overwrote each other's answer ISO while a VM was still installing from it
    # (observed on the first live run, 2026-10-25).
    param (
        [Parameter(Mandatory)]
        [string]$IsoPath,
        [Parameter(Mandatory)]
        [SecureString]$AdminPassword,
        [Parameter(Mandatory)]
        [string]$VmName,
        [Parameter(Mandatory)]
        [string]$VmStoragePath,
        [Parameter(Mandatory)]
        [int]$RamMB,
        [Parameter(Mandatory)]
        [int]$CpuCount,
        [Parameter(Mandatory)]
        [int]$DiskGB,
        [Parameter(Mandatory)]
        [string]$ComputerName,
        [Parameter(Mandatory)]
        [string]$NetworkType,
        [Parameter(Mandatory)]
        [string]$StaticIpAddress,
        [Parameter(Mandatory)]
        [string]$SubnetMask,
        [string]$DefaultGateway,
        [Parameter(Mandatory)]
        [string]$DnsServer,
        [Parameter(Mandatory)]
        [int]$TimeoutMinutes,
        [Parameter(Mandatory)]
        [string]$LogPath,
        [Parameter(Mandatory)]
        [string]$TempPath
    )
    $vmBuildParameters = @{
        TempPath        = $TempPath
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
        LogPath         = $LogPath
    }
    if ($DefaultGateway) {
        $vmBuildParameters['DefaultGateway'] = $DefaultGateway
    }
    return $vmBuildParameters
}

function Get-AdDomainIdentity {
    # Reads the domain identity from new-AdDomain's global-config.ps1, the same file the
    # forest promotion itself reads. Within one full build the join target therefore matches
    # the forest just built. A later -AddMemberServers or -MoveMemberServers run reads the
    # file again, so if it was edited in between, the values no longer match the existing
    # DC. Those two modes therefore cross-check the domain against the DC itself
    # (Compare-DomainControllerIdentity) before acting on it.
    #
    # The file is a .ps1, so reading it means dot-sourcing (executing) it. That happens
    # inside this function so the config's variables land in function scope and are
    # discarded on return, rather than overwriting same-named variables in this script
    # (global-config.ps1 defines $logPath, for one).
    param (
        [Parameter(Mandatory)]
        [string]$GlobalConfigPath
    )
    if (-not (Test-Path -LiteralPath $GlobalConfigPath -PathType Leaf)) {
        throw "Domain configuration not found at '$GlobalConfigPath'. Member servers take the domain name from new-AdDomain\include\global-config.ps1. Pass -AdDomainSourcePath if new-AdDomain is not a sibling of this project."
    }
    $domainName  = $null
    $netBIOSName = $null
    $domainDN    = $null
    $serversOU   = $null
    . $GlobalConfigPath

    if (-not $domainName -or -not $netBIOSName -or -not $domainDN -or -not $serversOU) {
        throw "'$GlobalConfigPath' did not define all of `$domainName, `$netBIOSName, `$domainDN and `$serversOU. Check the Domain Identity and OU Structure regions of that file."
    }
    return [pscustomobject]@{
        DomainName  = $domainName
        NetBIOSName = $netBIOSName
        DomainDN    = $domainDN
        ServersOU   = $serversOU
    }
}

function ConvertTo-IpAddressNumber {
    # Converts a dotted-decimal IPv4 address to its 32-bit value (held in a [long] so the
    # top bit does not turn it negative) for address arithmetic.
    param (
        [Parameter(Mandatory)]
        [string]$IpAddress
    )
    $addressBytes = [System.Net.IPAddress]::Parse($IpAddress).GetAddressBytes()
    return ([long]$addressBytes[0] * 16777216) + ([long]$addressBytes[1] * 65536) + ([long]$addressBytes[2] * 256) + [long]$addressBytes[3]
}

function ConvertFrom-IpAddressNumber {
    param (
        [Parameter(Mandatory)]
        [long]$IpAddressNumber
    )
    return (@(24, 16, 8, 0) | ForEach-Object { ($IpAddressNumber -shr $_) -band 255 }) -join '.'
}

function Confirm-DomainControllerAddress {
    # Validates the DC's own address and the gateway before anything is built. Member
    # addresses are checked separately by Get-MemberServerIpAddressList. Throws with a
    # descriptive message on the first problem found.
    param (
        [Parameter(Mandatory)]
        [string]$IpAddress,
        [Parameter(Mandatory)]
        [string]$SubnetMask,
        [Parameter(Mandatory)]
        [string]$NetworkType,
        [string]$DefaultGateway
    )
    $addressNumber          = ConvertTo-IpAddressNumber -IpAddress $IpAddress
    $subnetMaskNumber       = ConvertTo-IpAddressNumber -IpAddress $SubnetMask
    $networkAddressNumber   = $addressNumber -band $subnetMaskNumber
    $broadcastAddressNumber = $networkAddressNumber + ([long]4294967295 - $subnetMaskNumber)

    if ($addressNumber -eq $networkAddressNumber -or $addressNumber -eq $broadcastAddressNumber) {
        throw "-StaticIpAddress $IpAddress is the network or broadcast address of its subnet ($SubnetMask). Choose a host address inside the subnet."
    }
    if ($NetworkType -eq 'nat') {
        # VMware NAT networks are always Class C with net.3-net.127 free for static
        # addresses (Broadcom TechDocs, "Understanding DHCP in a NAT Configuration").
        $hostOctet = $addressNumber -band 255
        if ($hostOctet -lt 3 -or $hostOctet -gt 127) {
            throw "-StaticIpAddress $IpAddress is outside net.3-net.127, the static range of a VMware NAT network (net.1 is the host adapter, net.2 the NAT gateway, net.128-net.254 the NAT DHCP pool). Choose an address ending in .3 to .127."
        }
    }
    if ($DefaultGateway) {
        $gatewayNumber = ConvertTo-IpAddressNumber -IpAddress $DefaultGateway
        if (($gatewayNumber -band $subnetMaskNumber) -ne $networkAddressNumber) {
            throw "-DefaultGateway $DefaultGateway is outside the DC's subnet ($IpAddress / $SubnetMask), so the guest could never reach it. Pass the gateway of that subnet (on VMware NAT, net.2)."
        }
        if ($gatewayNumber -eq $addressNumber) {
            throw "-DefaultGateway $DefaultGateway is the same as -StaticIpAddress. Pass the network's gateway (on VMware NAT, net.2)."
        }
        if ($gatewayNumber -eq $networkAddressNumber -or $gatewayNumber -eq $broadcastAddressNumber) {
            throw "-DefaultGateway $DefaultGateway is the network or broadcast address of the subnet. Pass the network's gateway (on VMware NAT, net.2)."
        }
    }
}

function Get-FreeMemberServerNumber {
    # Returns the lowest -Count member numbers (1-99) that are free: no VM folder under
    # -VmStoragePath and no name in -ReservedNames. Gaps are filled first. Existing folders
    # and reserved names are never reused. -ReservedNames carries the DC's own names and,
    # with -AddMemberServers, every matching computer object already in AD, so a stale AD
    # account (its VM folder deleted) is not silently taken over by a new member.
    param (
        [Parameter(Mandatory)]
        [string]$VmStoragePath,
        [Parameter(Mandatory)]
        [string]$NamePrefix,
        [Parameter(Mandatory)]
        [int]$Count,
        [string[]]$ReservedNames = @(),
        [int]$MaxNumber = 99
    )
    $freeNumbers = @()
    for ($candidateNumber = 1; $candidateNumber -le $MaxNumber -and $freeNumbers.Count -lt $Count; $candidateNumber++) {
        $candidateName       = '{0}{1:D2}' -f $NamePrefix, $candidateNumber
        $candidateFolderPath = Join-Path -Path $VmStoragePath -ChildPath $candidateName
        if (-not (Test-Path -LiteralPath $candidateFolderPath) -and $ReservedNames -notcontains $candidateName) {
            $freeNumbers += $candidateNumber
        }
    }
    if ($freeNumbers.Count -lt $Count) {
        throw "Only $($freeNumbers.Count) free member number(s) remain (${NamePrefix}01-${NamePrefix}$MaxNumber, skipping existing folders under '$VmStoragePath' and names already in use), but $Count were requested. Remove unused $NamePrefix folders or AD computer objects, or lower -MemberServerCount."
    }
    return $freeNumbers
}

function Get-MemberServerIpAddressList {
    # Returns one address per member number: DC address + -Offset + (number - 1), so each
    # member's address follows its number (SRVR-03 is always DC + Offset + 2) whichever run
    # builds it. Validates every address before anything is built, so a bad one fails the
    # run up front rather than after the DC and earlier members already exist.
    param (
        [Parameter(Mandatory)]
        [string]$DomainControllerIpAddress,
        [Parameter(Mandatory)]
        [int]$Offset,
        [Parameter(Mandatory)]
        [int[]]$MemberNumbers,
        [Parameter(Mandatory)]
        [string]$SubnetMask,
        [Parameter(Mandatory)]
        [string]$NetworkType,
        [string]$DefaultGateway
    )
    $domainControllerAddressNumber = ConvertTo-IpAddressNumber -IpAddress $DomainControllerIpAddress
    $subnetMaskNumber              = ConvertTo-IpAddressNumber -IpAddress $SubnetMask
    $networkAddressNumber          = $domainControllerAddressNumber -band $subnetMaskNumber
    $broadcastAddressNumber        = $networkAddressNumber + ([long]4294967295 - $subnetMaskNumber)
    $defaultGatewayNumber          = if ($DefaultGateway) { ConvertTo-IpAddressNumber -IpAddress $DefaultGateway } else { -1 }
    $highestMemberNumber           = ($MemberNumbers | Measure-Object -Maximum).Maximum

    $memberIpAddresses = @()
    foreach ($memberNumber in $MemberNumbers) {
        $memberAddressNumber = $domainControllerAddressNumber + $Offset + ($memberNumber - 1)
        $memberLabel         = "Member number $memberNumber (DC address $DomainControllerIpAddress + $($Offset + $memberNumber - 1))"

        if ($memberAddressNumber -ge $broadcastAddressNumber) {
            throw "$memberLabel falls outside the DC's subnet ($DomainControllerIpAddress / $SubnetMask). Lower -StaticIpAddress, lower -MemberServerCount, or remove unused member folders so lower numbers are free."
        }
        $memberIpAddress = ConvertFrom-IpAddressNumber -IpAddressNumber $memberAddressNumber
        if ($memberAddressNumber -eq $defaultGatewayNumber) {
            throw "$memberLabel would be $memberIpAddress, which is the -DefaultGateway. Choose a -StaticIpAddress for the DC whose member range does not cover the gateway."
        }
        if ($NetworkType -eq 'nat') {
            # VMware NAT networks are always Class C with net.3-net.127 free for static
            # addresses and net.128-net.254 used by the NAT DHCP pool (Broadcom TechDocs,
            # "Understanding DHCP in a NAT Configuration").
            $hostOctet = $memberAddressNumber -band 255
            if ($hostOctet -lt 3 -or $hostOctet -gt 127) {
                $highestDomainControllerOctet = 127 - $Offset - ($highestMemberNumber - 1)
                throw "$memberLabel would be $memberIpAddress, outside net.3-net.127, the static range of a VMware NAT network (net.128-net.254 is the NAT DHCP pool). With member numbers up to $highestMemberNumber the DC address must end in .$highestDomainControllerOctet or lower. Lower -StaticIpAddress or -MemberServerCount."
            }
        }
        $memberIpAddresses += $memberIpAddress
    }
    return $memberIpAddresses
}

function Test-IpAddressResponds {
    # Returns $true if anything answers ICMP echo at the address. Used before an address is
    # assigned to a new VM, to refuse one that is already in use. A reply proves the address
    # is taken; silence does not prove it is free, because a host can block ping.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = "'Responds' is a verb describing the test result, not a plural noun.")]
    param (
        [Parameter(Mandatory)]
        [string]$IpAddress,
        [int]$Attempts = 2,
        [int]$TimeoutMilliseconds = 1000
    )
    $pingSender = New-Object -TypeName System.Net.NetworkInformation.Ping
    try {
        for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
            try {
                $pingReply = $pingSender.Send($IpAddress, $TimeoutMilliseconds)
            }
            catch [System.Net.NetworkInformation.PingException] {
                # A probe that could not be sent says nothing about the address, so it must
                # not be read as "free".
                $sendFailure = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
                throw "Could not send a ping to $IpAddress ($sendFailure), so the address cannot be confirmed free. Check that this host has a route to that network."
            }
            if ($pingReply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                return $true
            }
        }
        return $false
    }
    finally {
        $pingSender.Dispose()
    }
}

function Wait-IpAddressResponds {
    # Waits up to -TimeoutSeconds for the address to answer ping, probing every
    # -IntervalSeconds. Used after a VM build to confirm the VM came online on its address.
    # The deadline is elapsed time, so fast negative replies cannot use up the window. A
    # probe that cannot be sent (PingException) counts as "no answer yet", because the
    # network may still be coming up.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = "'Responds' is a verb describing the awaited result, not a plural noun.")]
    param (
        [Parameter(Mandatory)]
        [string]$IpAddress,
        [int]$TimeoutSeconds = 120,
        [int]$IntervalSeconds = 5,
        [int]$ReplyTimeoutMilliseconds = 1000
    )
    $responseDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $pingSender       = New-Object -TypeName System.Net.NetworkInformation.Ping
    try {
        do {
            try {
                if ($pingSender.Send($IpAddress, $ReplyTimeoutMilliseconds).Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    return $true
                }
            }
            catch [System.Net.NetworkInformation.PingException] {
                Write-Verbose "Ping to $IpAddress could not be sent yet: $($_.Exception.Message)"
            }
            Start-Sleep -Seconds $IntervalSeconds
        } while ((Get-Date) -lt $responseDeadline)
        return $false
    }
    finally {
        $pingSender.Dispose()
    }
}

function Get-GuestDomainControllerIdentity {
    # Reads, from the DC itself, what -AddMemberServers and -MoveMemberServers otherwise
    # take on trust from the command line and global-config.ps1: its computer name, its
    # domain, its domain role, its IPv4 addresses with prefix lengths, and its default
    # gateways.
    param (
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [string]$VmxFilePath,
        [Parameter(Mandatory)]
        [PSCredential]$GuestCredential,
        [Parameter(Mandatory)]
        [string]$HostStagingPath
    )
    $guestCommand = '$computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem; ' +
        '$ipv4Addresses = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne ''127.0.0.1'' -and $_.PrefixOrigin -ne ''WellKnown'' } | ForEach-Object { ''{0}/{1}'' -f $_.IPAddress, $_.PrefixLength }); ' +
        '$defaultGateways = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix ''0.0.0.0/0'' -ErrorAction SilentlyContinue | ForEach-Object { $_.NextHop }); ' +
        '[pscustomobject]@{ Name = $computerSystem.Name; Domain = $computerSystem.Domain; DomainRole = $computerSystem.DomainRole; Ipv4Addresses = $ipv4Addresses; DefaultGateways = $defaultGateways }'

    return Invoke-GuestPowerShellCommand -VmrunPath $VmrunPath -VmxFilePath $VmxFilePath -GuestCredential $GuestCredential `
        -OperationName 'query DC identity' -GuestCommand $guestCommand -HostStagingPath $HostStagingPath -Retry
}

function Get-GuestDomainComputerName {
    # Returns, from the DC, the names of every computer object in the domain that matches
    # -NamePattern, wherever it is in the directory. Used to reserve member numbers that AD
    # already knows, so a new member never silently reuses a stale account. It is a read,
    # so it is retried.
    param (
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [string]$VmxFilePath,
        [Parameter(Mandatory)]
        [PSCredential]$GuestCredential,
        [Parameter(Mandatory)]
        [string]$NamePattern,
        [Parameter(Mandatory)]
        [string]$HostStagingPath
    )
    $namePatternEscaped = ConvertTo-GuestSingleQuotedValue -Value $NamePattern
    # Wrapped in an object so a single name (or none) still comes back as an array.
    $guestCommand = "Import-Module -Name ActiveDirectory -ErrorAction Stop; `$namePattern = '$namePatternEscaped'; " +
        '[pscustomobject]@{ Names = @(Get-ADComputer -Filter * | Where-Object { $_.Name -match $namePattern } | ForEach-Object { $_.Name }) }'

    $queryResult = Invoke-GuestPowerShellCommand -VmrunPath $VmrunPath -VmxFilePath $VmxFilePath -GuestCredential $GuestCredential `
        -OperationName 'query existing member computer objects' -GuestCommand $guestCommand -HostStagingPath $HostStagingPath -Retry
    return @($queryResult.Names)
}

function Compare-DomainControllerIdentity {
    # Compares what the DC reports (Get-GuestDomainControllerIdentity) with what this run
    # was told. Returns one message per mismatch; an empty result means everything matches.
    # Expected values that are not supplied are not checked.
    param (
        [Parameter(Mandatory)]
        [object]$Identity,
        [Parameter(Mandatory)]
        [string]$ExpectedDomainName,
        [string]$ExpectedIpAddress,
        [int]$ExpectedPrefixLength,
        [string]$ExpectedDefaultGateway
    )
    $mismatches = @()
    # Win32_ComputerSystem.DomainRole: 4 = backup DC, 5 = primary DC.
    if (@(4, 5) -notcontains [int]$Identity.DomainRole) {
        $mismatches += "it is not a domain controller (Win32_ComputerSystem.DomainRole = $($Identity.DomainRole))"
    }
    if ($Identity.Domain -ne $ExpectedDomainName) {
        $mismatches += "it is in domain '$($Identity.Domain)', but global-config.ps1 names '$ExpectedDomainName'"
    }
    if ($ExpectedIpAddress) {
        $reportedAddresses = @($Identity.Ipv4Addresses)
        $matchingAddress   = @($reportedAddresses | Where-Object { ($_ -split '/')[0] -eq $ExpectedIpAddress }) | Select-Object -First 1
        if (-not $matchingAddress) {
            $mismatches += "it does not have address $ExpectedIpAddress (it reports: $(if ($reportedAddresses.Count) { $reportedAddresses -join ', ' } else { 'none' }))"
        }
        elseif ($ExpectedPrefixLength -and [int](($matchingAddress -split '/')[1]) -ne $ExpectedPrefixLength) {
            $mismatches += "its address is $matchingAddress, but -SubnetMask gives prefix length /$ExpectedPrefixLength"
        }
    }
    if ($ExpectedDefaultGateway -and @($Identity.DefaultGateways) -notcontains $ExpectedDefaultGateway) {
        $mismatches += "its default gateway is $(if (@($Identity.DefaultGateways).Count) { @($Identity.DefaultGateways) -join ', ' } else { 'not set' }), not $ExpectedDefaultGateway"
    }
    return $mismatches
}

function ConvertTo-GuestSingleQuotedValue {
    # Escapes a value for use inside a single-quoted guest PowerShell string literal.
    # PowerShell treats the ASCII apostrophe AND the curly single quotes U+2018, U+2019,
    # U+201A and U+201B as single-quote delimiters, and escapes each one by doubling it.
    # Doubling only the ASCII apostrophe would let a curly quote in a password end the
    # literal early. The characters are written as regex \u escapes so this file stays ASCII.
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )
    return [regex]::Replace($Value, "['\u2018\u2019\u201A\u201B]", '$0$0')
}

function Get-GuestTextFileContent {
    # Copies a text file from the guest to the host staging folder, returns its content,
    # and removes the host copy. -Retry repeats a failed copy; copying is a read, so a
    # repeat has no second effect.
    param (
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [string]$VmxFilePath,
        [Parameter(Mandatory)]
        [PSCredential]$GuestCredential,
        [Parameter(Mandatory)]
        [string]$GuestFilePath,
        [Parameter(Mandatory)]
        [string]$HostStagingPath,
        [switch]$Retry,
        [int]$VmrunTimeoutSeconds = 600
    )
    $guestUserName          = $GuestCredential.UserName
    $guestPasswordPlainText = $GuestCredential.GetNetworkCredential().Password
    $redactedTokens         = @($guestPasswordPlainText)

    if (-not (Test-Path -LiteralPath $HostStagingPath)) {
        $null = New-Item -ItemType Directory -Path $HostStagingPath -Force
    }
    $hostFilePath = Join-Path -Path $HostStagingPath -ChildPath (Split-Path -Path $GuestFilePath -Leaf)
    $copyArgumentList = @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText, 'copyFileFromGuestToHost', $VmxFilePath, $GuestFilePath, $hostFilePath)
    $copyOperationName = "copyFileFromGuestToHost $GuestFilePath"

    if ($Retry) {
        # Resolved to a scriptblock value for the closure below (see Copy-PayloadToGuest).
        $invokeVmrunCommand = ${function:Invoke-VmrunCommand}
        $null = Invoke-CommandWithRetry -OperationName $copyOperationName -ThrowOnFailure -ScriptBlock {
            $null = & $invokeVmrunCommand -VmrunPath $VmrunPath -RedactedTokens $redactedTokens -OperationName $copyOperationName -ArgumentList $copyArgumentList `
                -TimeoutSeconds $VmrunTimeoutSeconds
        }.GetNewClosure()
    }
    else {
        $null = Invoke-VmrunCommand -VmrunPath $VmrunPath -RedactedTokens $redactedTokens -OperationName $copyOperationName -ArgumentList $copyArgumentList `
            -TimeoutSeconds $VmrunTimeoutSeconds
    }
    try {
        return Get-Content -LiteralPath $hostFilePath -Raw -Encoding UTF8
    }
    finally {
        Remove-Item -LiteralPath $hostFilePath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-GuestPowerShellCommand {
    # Runs a PowerShell command in the guest and returns its result object to the host.
    # runProgramInGuest does not return the guest program's output, so the command is wrapped
    # in an envelope that writes { Succeeded, Result, Error } as JSON to a uniquely named file
    # in C:\temp, which is then copied back. C:\temp must already exist in the guest:
    # Initialize-GuestTempDirectory creates it when each guest first becomes ready.
    #
    # -GuestCommand runs inside a scriptblock in the guest with $ErrorActionPreference set to
    # 'Stop' (guest side only), so a non-terminating error also fails the command instead of
    # quietly producing an empty or partial result. Everything it writes to the success
    # stream becomes the result (several objects come back as an array), so each command
    # here emits exactly one object. It must not call exit (that would end the guest
    # process before the envelope is written), and it signals failure by throwing. The
    # guest process exits 1 when the command throws, so -Retry repeats guest-side failures
    # as well as vmrun transport failures. Only pass -Retry for a command that cannot have
    # a second effect when repeated.
    #
    # Every attempt writes its own result file. If vmrun gives up on an attempt whose guest
    # process is still running, a retry can overlap it, and separate files mean the two can
    # never overwrite or half-write each other's result.
    param (
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [string]$VmxFilePath,
        [Parameter(Mandatory)]
        [PSCredential]$GuestCredential,
        [Parameter(Mandatory)]
        [string]$OperationName,
        [Parameter(Mandatory)]
        [string]$GuestCommand,
        [Parameter(Mandatory)]
        [string]$HostStagingPath,
        [string[]]$RedactedTokens = @(),
        [switch]$Retry,
        # Per-call vmrun timeout for the run, the read-back and the cleanup. Pollers pass a
        # short value so a call interrupted by a guest reboot cannot hold the poll open.
        [int]$VmrunTimeoutSeconds = 600
    )
    $guestUserName          = $GuestCredential.UserName
    $guestPasswordPlainText = $GuestCredential.GetNetworkCredential().Password
    $allRedactedTokens      = @($guestPasswordPlainText) + $RedactedTokens
    $logCommand             = Get-Command -Name Write-Log -CommandType Function -ErrorAction SilentlyContinue
    $guestPowerShellExe     = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $resultFilePlaceholder  = '{{BUILD_LAB_RESULT_FILE}}'
    # A List is a reference type, so the closure below adds to this same instance.
    $guestResultFilePaths   = New-Object -TypeName 'System.Collections.Generic.List[string]'

    $envelopeCommandTemplate = "try { `$envelopeResult = & { `$ErrorActionPreference = 'Stop'; $GuestCommand }; " +
        "`$envelope = [pscustomobject]@{ Succeeded = `$true; Result = `$envelopeResult; Error = '' }; `$envelopeExitCode = 0 } " +
        "catch { `$envelope = [pscustomobject]@{ Succeeded = `$false; Result = `$null; Error = `$_.Exception.Message }; `$envelopeExitCode = 1 }; " +
        "`$envelope | ConvertTo-Json -Compress -Depth 5 | Set-Content -LiteralPath '$resultFilePlaceholder' -Encoding UTF8; exit `$envelopeExitCode"

    $vmrunArgumentPrefix = @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText, 'runProgramInGuest', $VmxFilePath, $guestPowerShellExe,
        '-NoProfile', '-Command')

    # Resolved to a scriptblock value for the closure below (see Copy-PayloadToGuest). The
    # closure calls no script function by name; [guid] and string methods are .NET calls.
    $invokeVmrunCommand = ${function:Invoke-VmrunCommand}

    $runAttempt = {
        $attemptResultFilePath = 'C:\temp\build-lab-' + [guid]::NewGuid().ToString('N') + '.json'
        $guestResultFilePaths.Add($attemptResultFilePath)
        $attemptArgumentList = $vmrunArgumentPrefix + @($envelopeCommandTemplate.Replace($resultFilePlaceholder, $attemptResultFilePath))
        $null = & $invokeVmrunCommand -VmrunPath $VmrunPath -RedactedTokens $allRedactedTokens -OperationName $OperationName `
            -ArgumentList $attemptArgumentList -TimeoutSeconds $VmrunTimeoutSeconds
    }.GetNewClosure()

    $runFailureMessage = $null
    try {
        if ($Retry) {
            $null = Invoke-CommandWithRetry -OperationName $OperationName -ThrowOnFailure -ScriptBlock $runAttempt
        }
        else {
            & $runAttempt
        }
    }
    catch {
        $runFailureMessage = $_.Exception.Message
    }

    $newestFirstResultFilePaths = $guestResultFilePaths.ToArray()
    [array]::Reverse($newestFirstResultFilePaths)

    $envelope = $null
    if (-not $runFailureMessage) {
        # The run succeeded, so the last attempt's file exists and the guest is up. With
        # -Retry the read-back is retried too, so a transient copy failure cannot turn a
        # completed command (a finished join, a finished move) into a reported failure.
        # Without -Retry (the pollers) it is tried once: the poll loop is the retry, and a
        # nested retry would let one poll iteration run far past the poll's deadline.
        try {
            $envelope = Get-GuestTextFileContent -VmrunPath $VmrunPath -VmxFilePath $VmxFilePath -GuestCredential $GuestCredential `
                -GuestFilePath $newestFirstResultFilePaths[0] -HostStagingPath $HostStagingPath -Retry:$Retry -VmrunTimeoutSeconds $VmrunTimeoutSeconds | ConvertFrom-Json
        }
        catch {
            throw "Guest command '$OperationName' ran, but its result file '$($newestFirstResultFilePaths[0])' could not be read back: $($_.Exception.Message)"
        }
    }
    else {
        # The run failed, and the guest may be down. Try each attempt's file once, newest
        # first, for the guest's own error text. An earlier attempt's envelope from this same
        # call is a valid fallback. A missing file fails fast, so polls are not slowed.
        foreach ($candidateResultFilePath in $newestFirstResultFilePaths) {
            try {
                $envelope = Get-GuestTextFileContent -VmrunPath $VmrunPath -VmxFilePath $VmxFilePath -GuestCredential $GuestCredential `
                    -GuestFilePath $candidateResultFilePath -HostStagingPath $HostStagingPath -VmrunTimeoutSeconds $VmrunTimeoutSeconds | ConvertFrom-Json
                break
            }
            catch {
                if ($logCommand) {
                    Write-Log "No readable result at '$candidateResultFilePath' after the failed run of '$OperationName': $($_.Exception.Message)" -Level DEBUG
                }
            }
        }
    }

    if ($envelope) {
        foreach ($guestResultFilePath in $newestFirstResultFilePaths) {
            try {
                $null = Invoke-VmrunCommand -VmrunPath $VmrunPath -RedactedTokens $allRedactedTokens -OperationName "deleteFileInGuest $guestResultFilePath" `
                    -ArgumentList @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText, 'deleteFileInGuest', $VmxFilePath, $guestResultFilePath) `
                    -TimeoutSeconds $VmrunTimeoutSeconds
            }
            catch {
                if ($logCommand) {
                    Write-Log "Could not delete guest result file '$guestResultFilePath' (harmless; absent if that attempt never wrote it): $($_.Exception.Message)" -Level DEBUG
                }
            }
        }

        if (-not $envelope.Succeeded) {
            # The guest's own error text has not passed through Invoke-VmrunCommand's
            # redaction, so apply the same tokens before it reaches a log or exception.
            $guestErrorText = [string]$envelope.Error
            foreach ($redactedToken in $allRedactedTokens) {
                if ($redactedToken) {
                    $guestErrorText = $guestErrorText -replace [regex]::Escape($redactedToken), '***'
                }
            }
            throw "Guest command '$OperationName' failed in the guest: $guestErrorText"
        }
        if ($runFailureMessage -and $logCommand) {
            Write-Log "vmrun reported an error for '$OperationName' ($runFailureMessage), but the guest recorded success. Using the guest's result." -Level WARN
        }
        return $envelope.Result
    }
    throw "Guest command '$OperationName' failed: $runFailureMessage"
}

function Get-GuestDomainState {
    # Reads the guest's domain membership and role, whether the boot marker set by
    # Set-GuestBootMarker is still present, and (for the log only) its uptime and last
    # boot time. BootMarkerPresent = $false after Set-GuestBootMarker means the guest has
    # restarted since. -Retry is for one-off reads where a transient failure must not fail
    # the step; the pollers leave it off because the poll loop is itself the retry, and
    # pass a short -VmrunTimeoutSeconds because the guest may reboot under them.
    param (
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [string]$VmxFilePath,
        [Parameter(Mandatory)]
        [PSCredential]$GuestCredential,
        [Parameter(Mandatory)]
        [string]$HostStagingPath,
        [switch]$Retry,
        [int]$VmrunTimeoutSeconds = 600
    )
    $guestCommand = '$computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem; ' +
        '$operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem; ' +
        '$bootMarker = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(''SOFTWARE\BuildLabBootMarker''); ' +
        '$bootMarkerPresent = $null -ne $bootMarker; if ($bootMarker) { $bootMarker.Dispose() }; ' +
        '[pscustomobject]@{ PartOfDomain = $computerSystem.PartOfDomain; Domain = $computerSystem.Domain; DomainRole = $computerSystem.DomainRole; ' +
        'BootMarkerPresent = $bootMarkerPresent; UptimeSeconds = [math]::Round((([long][Environment]::TickCount) -band 4294967295) / 1000); ' +
        'LastBootUpTimeUtc = $operatingSystem.LastBootUpTime.ToUniversalTime().ToString(''o'') }'

    return Invoke-GuestPowerShellCommand -VmrunPath $VmrunPath -VmxFilePath $VmxFilePath -GuestCredential $GuestCredential `
        -OperationName 'query guest domain state' -GuestCommand $guestCommand -HostStagingPath $HostStagingPath -Retry:$Retry `
        -VmrunTimeoutSeconds $VmrunTimeoutSeconds
}

function Set-GuestBootMarker {
    # Creates HKLM\SOFTWARE\BuildLabBootMarker in the guest as a VOLATILE registry key.
    # Windows keeps volatile keys in memory only and never writes them to disk, so the key
    # cannot survive a restart: once it is gone, the guest has rebooted. Called right before
    # a reboot is expected (the forest deployment launch, a member's join restart), and read
    # back through Get-GuestDomainState.BootMarkerPresent. Unlike a clock or uptime
    # comparison it does not depend on how long the guest has been up, on clock
    # corrections, or on the VM being paused.
    #
    # Throws unless the marker reads back as present, because without it no reboot can be
    # confirmed. Creating an existing key just opens it, so a retry has no second effect.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal build step that writes one in-memory registry key in a lab guest this script built; -WhatIf support would not meaningfully apply.')]
    param (
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [string]$VmxFilePath,
        [Parameter(Mandatory)]
        [PSCredential]$GuestCredential,
        [Parameter(Mandatory)]
        [string]$HostStagingPath
    )
    $guestCommand = '$bootMarker = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey(''SOFTWARE\BuildLabBootMarker'', ' +
        '[Microsoft.Win32.RegistryKeyPermissionCheck]::Default, [Microsoft.Win32.RegistryOptions]::Volatile); ' +
        '$bootMarker.Dispose(); ' +
        '$bootMarkerCheck = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(''SOFTWARE\BuildLabBootMarker''); ' +
        '$bootMarkerPresent = $null -ne $bootMarkerCheck; if ($bootMarkerCheck) { $bootMarkerCheck.Dispose() }; ' +
        '[pscustomobject]@{ BootMarkerPresent = $bootMarkerPresent }'

    $markerResult = Invoke-GuestPowerShellCommand -VmrunPath $VmrunPath -VmxFilePath $VmxFilePath -GuestCredential $GuestCredential `
        -OperationName 'set boot marker' -GuestCommand $guestCommand -HostStagingPath $HostStagingPath -Retry
    if (-not $markerResult.BootMarkerPresent) {
        throw "The boot marker HKLM\SOFTWARE\BuildLabBootMarker could not be created in the guest, so the coming reboot cannot be confirmed."
    }
}

function Invoke-GuestDomainJoin {
    # Joins the guest to the domain WITHOUT rebooting. Add-Computer runs synchronously, so a
    # failed join fails this call with the guest's own error text, instead of the failure
    # surfacing only as a membership-poll timeout. The reboot that completes the join is
    # launched separately by Restart-GuestComputer, so no blocking call is held open across
    # it (a blocking vmrun call held open across a guest reboot can hang indefinitely).
    #
    # On retry, each attempt re-checks membership first and returns without calling
    # Add-Computer once an earlier attempt has completed the join. If vmrun gave up on an
    # attempt whose guest process is still running, the next attempt can overlap it. A
    # computer can only be in one domain, so the overlap cannot produce a second membership.
    # At worst the overlapping Add-Computer fails, is retried, and the re-check then finds
    # the completed join. That re-check relies on Win32_ComputerSystem reporting
    # PartOfDomain and the new Domain BEFORE the reboot that completes the join, which it
    # does. In the 2026-10-25 live runs, members reported PartOfDomain=True for the new
    # domain while they had not yet rebooted.
    #
    # The join password is embedded in the guest -Command string, so it is visible in the
    # host process list (vmrun arguments) and the guest process list. Depending on the
    # guest's audit and PowerShell logging settings (process command-line auditing, script
    # block logging, transcription), it may also persist in guest event logs or transcript
    # files after the run. Accepted for lab use, the same exposure as vmrun's -gp argument.
    param (
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [string]$VmxFilePath,
        [Parameter(Mandatory)]
        [PSCredential]$GuestCredential,
        [Parameter(Mandatory)]
        [string]$DomainName,
        [Parameter(Mandatory)]
        [PSCredential]$DomainJoinCredential,
        [Parameter(Mandatory)]
        [string]$HostStagingPath
    )
    $joinUserName          = $DomainJoinCredential.UserName
    $joinPasswordPlainText = $DomainJoinCredential.GetNetworkCredential().Password
    $joinPasswordEscaped   = ConvertTo-GuestSingleQuotedValue -Value $joinPasswordPlainText
    $joinUserNameEscaped   = ConvertTo-GuestSingleQuotedValue -Value $joinUserName
    $domainNameEscaped     = ConvertTo-GuestSingleQuotedValue -Value $DomainName
    $logCommand            = Get-Command -Name Write-Log -CommandType Function -ErrorAction SilentlyContinue

    $guestCommand = '$computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem; ' +
        "if (`$computerSystem.PartOfDomain -and `$computerSystem.Domain -eq '$domainNameEscaped') { return 'AlreadyJoined' }; " +
        "`$joinPassword = ConvertTo-SecureString -String '$joinPasswordEscaped' -AsPlainText -Force; " +
        "`$joinCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList '$joinUserNameEscaped', `$joinPassword; " +
        "Add-Computer -DomainName '$domainNameEscaped' -Credential `$joinCredential -Force -ErrorAction Stop; 'Joined'"

    if ($logCommand) {
        Write-Log "Joining guest to '$DomainName' as '$joinUserName' (Add-Computer, no reboot)..." -Level INFO
    }
    try {
        $joinResult = Invoke-GuestPowerShellCommand -VmrunPath $VmrunPath -VmxFilePath $VmxFilePath -GuestCredential $GuestCredential `
            -OperationName "Add-Computer $DomainName" -GuestCommand $guestCommand -HostStagingPath $HostStagingPath `
            -RedactedTokens @($joinPasswordPlainText, $joinPasswordEscaped) -Retry
    }
    catch {
        throw "Domain join to '$DomainName' failed: $($_.Exception.Message)"
    }
    if ($logCommand) {
        Write-Log "Add-Computer result: $joinResult." -Level INFO
    }
}

function Get-GuestMemberServerOuState {
    # Reports, from the DC, where the member server computer objects are: which are still
    # in the domain's default computers container and which are already in OU=Servers, and
    # whether OU=Servers exists yet (it is created by directory population). The default
    # container is read from Get-ADDomain rather than assumed to be CN=Computers, in case it
    # has been redirected. Only a missing-OU error counts as "OU does not exist"; any other
    # AD error fails the call so an unreachable directory is not misreported as a missing OU.
    # It is a read, so it is retried.
    param (
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [string]$VmxFilePath,
        [Parameter(Mandatory)]
        [PSCredential]$GuestCredential,
        [Parameter(Mandatory)]
        [string]$ServersOu,
        [Parameter(Mandatory)]
        [string]$MemberServerNamePattern,
        [Parameter(Mandatory)]
        [string]$HostStagingPath
    )
    $serversOuEscaped   = ConvertTo-GuestSingleQuotedValue -Value $ServersOu
    $namePatternEscaped = ConvertTo-GuestSingleQuotedValue -Value $MemberServerNamePattern

    $guestCommand = "Import-Module -Name ActiveDirectory -ErrorAction Stop; `$namePattern = '$namePatternEscaped'; `$serversOu = '$serversOuEscaped'; " +
        '$serversOuExists = $true; ' +
        'try { $null = Get-ADOrganizationalUnit -Identity $serversOu -ErrorAction Stop } ' +
        'catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] { $serversOuExists = $false }; ' +
        '$computersContainer = (Get-ADDomain).ComputersContainer; ' +
        '$inComputersContainer = @(Get-ADComputer -SearchBase $computersContainer -SearchScope OneLevel -Filter * | Where-Object { $_.Name -match $namePattern } | ForEach-Object { $_.Name }); ' +
        '$inServersOu = @(); ' +
        'if ($serversOuExists) { $inServersOu = @(Get-ADComputer -SearchBase $serversOu -SearchScope OneLevel -Filter * | Where-Object { $_.Name -match $namePattern } | ForEach-Object { $_.Name }) }; ' +
        '[pscustomobject]@{ ServersOuExists = $serversOuExists; ComputersContainer = $computersContainer; InComputersContainer = $inComputersContainer; InServersOu = $inServersOu }'

    return Invoke-GuestPowerShellCommand -VmrunPath $VmrunPath -VmxFilePath $VmxFilePath -GuestCredential $GuestCredential `
        -OperationName 'query member server OU placement' -GuestCommand $guestCommand -HostStagingPath $HostStagingPath -Retry
}

function Move-GuestMemberServerToServersOu {
    # Moves member server computer objects from the default computers container to
    # OU=Servers, on the DC. Retry cannot move anything twice: each attempt re-queries the
    # container, so objects moved by an earlier attempt are no longer candidates. The guest
    # re-checks the cap itself and moves nothing if more objects match than -MaxObjectCount.
    param (
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [string]$VmxFilePath,
        [Parameter(Mandatory)]
        [PSCredential]$GuestCredential,
        [Parameter(Mandatory)]
        [string]$ServersOu,
        [Parameter(Mandatory)]
        [string]$MemberServerNamePattern,
        [Parameter(Mandatory)]
        [int]$MaxObjectCount,
        [Parameter(Mandatory)]
        [string]$HostStagingPath
    )
    $serversOuEscaped   = ConvertTo-GuestSingleQuotedValue -Value $ServersOu
    $namePatternEscaped = ConvertTo-GuestSingleQuotedValue -Value $MemberServerNamePattern

    $guestCommand = "Import-Module -Name ActiveDirectory -ErrorAction Stop; `$namePattern = '$namePatternEscaped'; `$serversOu = '$serversOuEscaped'; `$maxObjectCount = $MaxObjectCount; " +
        '$computersContainer = (Get-ADDomain).ComputersContainer; ' +
        '$computersToMove = @(Get-ADComputer -SearchBase $computersContainer -SearchScope OneLevel -Filter * | Where-Object { $_.Name -match $namePattern }); ' +
        'if ($computersToMove.Count -gt $maxObjectCount) { throw (''Matched {0} member server computer objects, more than the cap of {1}. Nothing was moved.'' -f $computersToMove.Count, $maxObjectCount) }; ' +
        '$movedNames = @(); ' +
        'foreach ($computerToMove in $computersToMove) { Move-ADObject -Identity $computerToMove.DistinguishedName -TargetPath $serversOu -ErrorAction Stop; $movedNames += $computerToMove.Name }; ' +
        '[pscustomobject]@{ Moved = $movedNames }'

    return Invoke-GuestPowerShellCommand -VmrunPath $VmrunPath -VmxFilePath $VmxFilePath -GuestCredential $GuestCredential `
        -OperationName "Move-ADObject member servers to $ServersOu" -GuestCommand $guestCommand -HostStagingPath $HostStagingPath -Retry
}

function Restart-GuestComputer {
    # Reboots the guest FIRE-AND-FORGET via runProgramInGuest -noWait, for the same reason
    # as Invoke-GuestAdForestDeployment: a blocking call held across a guest reboot can hang
    # vmrun indefinitely. shutdown.exe's 10 second delay lets the vmrun call return before
    # the guest goes down. A launch failure is logged, not thrown: the guest then never
    # reboots and Test-GuestDomainMembership fails with a clear timeout.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal build step that reboots a lab guest this script just built; -WhatIf support would not meaningfully apply.')]
    param (
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [string]$VmxFilePath,
        [Parameter(Mandatory)]
        [PSCredential]$GuestCredential
    )
    $guestUserName          = $GuestCredential.UserName
    $guestPasswordPlainText = $GuestCredential.GetNetworkCredential().Password
    $logCommand             = Get-Command -Name Write-Log -CommandType Function -ErrorAction SilentlyContinue

    try {
        $null = Invoke-VmrunCommand -VmrunPath $VmrunPath -RedactedTokens @($guestPasswordPlainText) -OperationName 'shutdown.exe /r (-noWait)' `
            -ArgumentList @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText, 'runProgramInGuest', $VmxFilePath, '-noWait',
                'C:\Windows\System32\shutdown.exe', '/r', '/t', '10')
        if ($logCommand) {
            Write-Log "Guest reboot launched to complete the domain join." -Level INFO
        }
    }
    catch {
        if ($logCommand) {
            Write-Log "vmrun reported an error launching the guest reboot: $($_.Exception.Message) Continuing to membership verification." -Level WARN
        }
    }
}

function Test-GuestDomainMembership {
    # Confirms the join completed. The guest must have rebooted since the caller set the
    # volatile boot marker just before the restart (Set-GuestBootMarker; the marker is gone
    # after any reboot) AND report PartOfDomain for the expected domain. The reboot check
    # matters because Win32_ComputerSystem already reports the new domain before the reboot
    # that completes the join (observed on the first live run, 2026-10-24). Query failures
    # while the guest is down are expected and keep the poll going. -TimeoutMinutes is
    # checked between polls, so the last poll can finish a little after it.
    param (
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [string]$VmxFilePath,
        [Parameter(Mandatory)]
        [PSCredential]$GuestCredential,
        [Parameter(Mandatory)]
        [string]$DomainName,
        [Parameter(Mandatory)]
        [int]$TimeoutMinutes,
        [Parameter(Mandatory)]
        [string]$HostStagingPath,
        [int]$PollIntervalSeconds = 30
    )
    $logCommand            = Get-Command -Name Write-Log -CommandType Function -ErrorAction SilentlyContinue
    $membershipDeadline    = (Get-Date).AddMinutes($TimeoutMinutes)
    $lastObservedState     = 'not yet queried'
    $rebootedOutsideDomain = $false

    while ((Get-Date) -lt $membershipDeadline) {
        # Sleep first: the reboot was launched with a delay, so an immediate query would
        # only see the pre-reboot guest.
        Start-Sleep -Seconds $PollIntervalSeconds
        try {
            $domainState = Get-GuestDomainState -VmrunPath $VmrunPath -VmxFilePath $VmxFilePath -GuestCredential $GuestCredential -HostStagingPath $HostStagingPath `
                -VmrunTimeoutSeconds 120
            $hasRebooted = -not $domainState.BootMarkerPresent
            $lastObservedState = "rebooted=$hasRebooted (boot marker present=$($domainState.BootMarkerPresent), uptime $($domainState.UptimeSeconds) s), PartOfDomain=$($domainState.PartOfDomain), Domain='$($domainState.Domain)'"

            if ($hasRebooted -and $domainState.PartOfDomain -and $domainState.Domain -eq $DomainName) {
                if ($logCommand) {
                    Write-Log "Domain membership verified: guest rebooted and reports PartOfDomain for '$DomainName'." -Level SUCCESS
                }
                return
            }
            if ($hasRebooted) {
                $rebootedOutsideDomain = $true
                break
            }
        }
        catch {
            $lastObservedState = "guest query failed (expected while the guest reboots): $($_.Exception.Message)"
            if ($logCommand) {
                Write-Log "Domain state query not answered yet: $($_.Exception.Message)" -Level DEBUG
            }
        }
        $minutesRemaining = [math]::Round(($membershipDeadline - (Get-Date)).TotalMinutes, 1)
        if ($logCommand) {
            Write-Log "Domain membership not confirmed yet ($lastObservedState). $minutesRemaining minute(s) remaining before timeout." -Level INFO
        }
    }

    if ($rebootedOutsideDomain) {
        throw "Guest rebooted after the domain join but is not a member of '$DomainName' ($lastObservedState). Check the guest's System event log for NETLOGON / join errors."
    }
    throw "Domain membership not confirmed within $TimeoutMinutes minute(s). Last observed state: $lastObservedState. Check the VM console; raise -DomainJoinTimeoutMinutes if the guest is legitimately slow to reboot."
}

function Show-PostBuildManualStepNotice {
    # Prints an unmissable red console banner for the manual steps left after the run:
    # directory population (not yet run after a DC build, starts only at a manual
    # Administrator logon) and moving joined member servers to OU=Servers.
    # -OmitPopulationNotice drops the population part for runs against an existing DC
    # (-AddMemberServers), whose population state this script does not know. Prints nothing
    # when there is nothing to say. Console-only by design (a visual prompt); the caller also
    # writes the same instructions through Write-Log so the text log records them.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Deliberate red console banner so the operator cannot miss the required manual logon step; the same instruction is also persisted via Write-Log by the caller.')]
    param (
        [string[]]$JoinedMemberServerNames = @(),
        [switch]$OmitPopulationNotice
    )
    $bannerBodyLines = @()
    if (-not $OmitPopulationNotice) {
        $bannerBodyLines += @(
            ' ACTION REQUIRED: DIRECTORY POPULATION HAS NOT RUN YET',
            '',
            ' AD forest promotion succeeded, but Initialize-ADDirectory.ps1 (OUs, users,',
            ' groups, Enterprise CA, GPOs, etc.) runs via a scheduled task that triggers',
            ' ONLY at the next Administrator logon.',
            '',
            ' Log into the guest console as Administrator to start directory population.',
            ' It removes its own scheduled task when finished.'
        )
    }
    if ($JoinedMemberServerNames.Count -gt 0) {
        $bannerBodyLines += if ($bannerBodyLines.Count -gt 0) { @('') } else { @(' ACTION REQUIRED: MOVE MEMBER SERVERS TO OU=Servers', '') }
        $bannerBodyLines += @(
            " Member servers joined: $($JoinedMemberServerNames -join ', ')",
            ' They are in the default CN=Computers container. Once directory population',
            ' has finished, re-run build-lab.ps1 with -MoveMemberServers to move them',
            ' to OU=Servers.'
        )
    }
    if ($bannerBodyLines.Count -eq 0) { return }

    $bannerRule  = '================================================================================'
    $bannerLines = @('', $bannerRule) + $bannerBodyLines + @($bannerRule, '')
    foreach ($bannerLine in $bannerLines) {
        Write-Host $bannerLine -ForegroundColor Red
    }
}

#endregion Functions

#region Variables
# Printed in the starting log line so every log shows which version ran. Keep it in step
# with Version in .NOTES.
$scriptVersion      = '2.0.0'
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
$adDomainGlobalConfigPath = Join-Path -Path $AdDomainSourcePath -ChildPath 'include\global-config.ps1'

# Member servers. The cap is a scope limit on -MemberServerCount, changed by editing it
# here rather than per run.
$maxMemberServerCount   = 5
$memberServerNamePrefix = 'SRVR-'
$memberServerIpOffset   = 10
# Matches exactly the names this script gives members (SRVR-01..SRVR-99), so
# -MoveMemberServers cannot pick up population's SRV-<seed>-<n> objects or anything else.
$memberServerNamePattern = '^' + [regex]::Escape($memberServerNamePrefix) + '\d{2}$'

$logDirectoryPath = Join-Path -Path $PSScriptRoot -ChildPath 'logs'
$csvLogFilePath   = Join-Path -Path $logDirectoryPath -ChildPath "build-lab-errors_$runTimestamp.csv"
$textLogFilePath  = Join-Path -Path $logDirectoryPath -ChildPath "build-lab_$runTimestamp.log"

$vmDirectoryPath = Join-Path -Path $VmStoragePath -ChildPath $VmName
$vmxFilePath     = Join-Path -Path $vmDirectoryPath -ChildPath "$VmName.vmx"

# The process ID keeps two runs started in the same second apart: each build's VM builder
# temp folder lives under this folder, member names (SRVR-NN) repeat across labs, and each
# run deletes its own staging folder at the end.
$stagingRootPath = Join-Path -Path $env:TEMP -ChildPath "BuildLab-$runTimestamp-$PID"
#endregion Variables

#region Main

Initialize-Logging -ScriptName 'build-lab.ps1' -CsvLogPath $csvLogFilePath -TextLogPath $textLogFilePath
$eventLogSourceName = Initialize-EventLogSource -SourceName $eventLogSourceName

$guestPasswordPlainText = $null

try {
    Write-Log "=== build-lab.ps1 $scriptVersion starting ===" -Level INFO
    Write-AppEvent -Enabled $enableEventLogging -SourceName $eventLogSourceName -EntryType Information -EventId 1000 -Message 'build-lab.ps1 started.'

    # CIDR prefix length derived from the subnet mask, passed to the guest deployment so it
    # can repair a DHCP fallback non-interactively (see Invoke-GuestAdForestDeployment).
    # Derived inside the try so an invalid mask is logged like any other failure. 0.0.0.0
    # passes the parameter pattern but gives prefix 0, which the guest deployment rejects
    # only after the full deployment timeout, so it is refused here instead.
    $staticIpPrefixLength = ConvertTo-PrefixLength -SubnetMask $SubnetMask
    if ($staticIpPrefixLength -lt 1) {
        throw "-SubnetMask '$SubnetMask' gives a prefix length of 0, which cannot describe a host network. Pass the network's real mask, such as 255.255.255.0."
    }

    # A mode switch passed as -Switch:$false still selects that switch's parameter set.
    # -SkipVmBuild:$false and -MoveMemberServers:$false select sets that do not require the
    # Build set's -IsoPath and -StaticIpAddress, so the run would take the full build path
    # and fail late with a binding error. -AddMemberServers:$false (with its required
    # -IsoPath and -StaticIpAddress) would silently run a full DC build instead of adding
    # members. Reject all of these here.
    $modeSwitchByParameterSet = @{ GuestOnly = 'SkipVmBuild'; MoveMembers = 'MoveMemberServers'; AddMembers = 'AddMemberServers' }
    $activeParameterSet       = $PSCmdlet.ParameterSetName
    if ($modeSwitchByParameterSet.ContainsKey($activeParameterSet) -and -not $PSBoundParameters[$modeSwitchByParameterSet[$activeParameterSet]]) {
        throw "Parameter set '$activeParameterSet' was selected but -$($modeSwitchByParameterSet[$activeParameterSet]) is not set (passed as -$($modeSwitchByParameterSet[$activeParameterSet]):`$false?). For a full build omit the switch and pass -IsoPath and -StaticIpAddress; to use the mode, pass the switch without a value."
    }

    # -MoveMemberServers builds nothing, so it does not need the VM builder.
    if (-not $MoveMemberServers -and -not (Test-Path -LiteralPath $VmBuilderScriptPath -PathType Leaf)) {
        throw "VM builder script not found: '$VmBuilderScriptPath'. Pass -VmBuilderScriptPath if New-VMwareWorkstationVM is not a sibling of this project."
    }
    $adForestDeploymentScriptPath = Join-Path -Path $AdDomainSourcePath -ChildPath 'New-ADForestDeployment.ps1'
    if (-not (Test-Path -LiteralPath $adForestDeploymentScriptPath -PathType Leaf)) {
        throw "New-ADForestDeployment.ps1 not found at '$adForestDeploymentScriptPath'. Pass -AdDomainSourcePath if new-AdDomain is not a sibling of this project."
    }

    # -SkipVmBuild re-runs the DC guest phase. Combined with members it would do that to a
    # working DC, wiping its payload folder and logs and relaunching the forest deployment.
    if ($SkipVmBuild -and $MemberServerCount -gt 0) {
        throw "-SkipVmBuild cannot be combined with -MemberServerCount. -SkipVmBuild re-runs the DC guest phase: it deletes C:\temp\new-AdDomain in the guest (including the deployment and directory population logs) and relaunches New-ADForestDeployment.ps1. To add member servers to an existing DC without touching it, use -AddMemberServers with -IsoPath, the DC's -StaticIpAddress and -MemberServerCount."
    }
    if ($AddMemberServers -and $MemberServerCount -lt 1) {
        throw "-AddMemberServers needs -MemberServerCount of 1 or more."
    }

    $vmrunPath = Find-VmrunExecutable

    if ($SkipVmBuild -or $MoveMemberServers -or $AddMemberServers) {
        $existingVmSwitchName = if ($MoveMemberServers) { '-MoveMemberServers' } elseif ($AddMemberServers) { '-AddMemberServers' } else { '-SkipVmBuild' }
        if (-not (Test-Path -LiteralPath $vmxFilePath -PathType Leaf)) {
            throw "$existingVmSwitchName was specified but no VMX exists at '$vmxFilePath'. The path is composed as <VmStoragePath>\<VmName>\<VmName>.vmx, so pass the SAME -VmStoragePath and -VmName you built the VM with (do not include the VM's own folder in -VmStoragePath). For example, a VM at 'D:\VMWare\DC01\DC01.vmx' needs -VmStoragePath 'D:\VMWare' -VmName 'DC01'. Build the VM first if it does not exist."
        }
    }
    elseif (Test-Path -LiteralPath $vmxFilePath -PathType Leaf) {
        throw "VMX already exists at '$vmxFilePath'. Remove the existing VM, choose a different -VmName, or pass -SkipVmBuild to reuse it."
    }

    $guestPasswordPlainText = ConvertTo-PlainTextCredentialValue -SecureValue $AdminPassword
    if (-not $guestPasswordPlainText) {
        throw "-AdminPassword is empty. Windows setup does not accept a blank Administrator password, and vmrun guest operations cannot authenticate with one."
    }
    if ($guestPasswordPlainText.Contains('"')) {
        throw "-AdminPassword cannot contain a double-quote character; it breaks vmrun argument quoting."
    }
    if ($guestPasswordPlainText -match '\s' -and $guestPasswordPlainText.EndsWith('\')) {
        throw "-AdminPassword contains whitespace and ends with a backslash. Windows command-line quoting makes that combination fragile when the password is passed to vmrun, so it is refused. Change the password's last character."
    }
    $guestCredential = [PSCredential]::new($guestUserName, $AdminPassword)

    # The DC's own address and the gateway: the address the DC is about to get (full build)
    # or already has (-AddMemberServers). Not supplied for -SkipVmBuild / -MoveMemberServers.
    if ($StaticIpAddress) {
        Confirm-DomainControllerAddress -IpAddress $StaticIpAddress -SubnetMask $SubnetMask -NetworkType $NetworkType -DefaultGateway $DefaultGateway
    }
    # Before a static address is given to a new VM, make sure nothing already answers at it.
    # Only a full build assigns the DC an address; -AddMemberServers expects the DC to answer.
    if (-not ($SkipVmBuild -or $MoveMemberServers -or $AddMemberServers)) {
        if (Test-IpAddressResponds -IpAddress $StaticIpAddress) {
            throw "-StaticIpAddress $StaticIpAddress already answers ping, so another machine is using it. Nothing was built. Choose a free address; a second machine on the same address would leave both unreliable."
        }
        Write-Log "-StaticIpAddress $StaticIpAddress does not answer ping, so it is treated as free. (A host that blocks ping would not show up.)" -Level INFO
    }

    # Domain identity from new-AdDomain's global-config.ps1. Every mode needs it: the move
    # and the add check the existing DC against it, members join it, and a full build
    # verifies its promotion against it. Reading it here fails a broken config before
    # anything is built.
    $domainIdentity = Get-AdDomainIdentity -GlobalConfigPath $adDomainGlobalConfigPath

    if ($MoveMemberServers) {
        # Separate later step: move joined member servers to OU=Servers on the existing DC.
        if ($MemberServerCount -gt 0) {
            throw "-MoveMemberServers runs on its own and builds nothing. Run the member server build (-MemberServerCount) and the move as separate invocations."
        }
        $memberServerOuParameters = @{
            VmrunPath               = $vmrunPath
            VmxFilePath             = $vmxFilePath
            GuestCredential         = $guestCredential
            ServersOu               = $domainIdentity.ServersOU
            MemberServerNamePattern = $memberServerNamePattern
            HostStagingPath         = $stagingRootPath
        }

        Write-Log "Waiting for the DC to answer guest operations (timeout: $GuestReadyTimeoutMinutes minute(s))..." -Level INFO
        Wait-GuestOperationsReady -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential -TimeoutMinutes $GuestReadyTimeoutMinutes
        Initialize-GuestTempDirectory -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential

        # global-config.ps1 is read again on this run, so confirm it still describes this DC.
        $domainControllerIdentity = Get-GuestDomainControllerIdentity -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential `
            -HostStagingPath $stagingRootPath
        $identityMismatches = @(Compare-DomainControllerIdentity -Identity $domainControllerIdentity -ExpectedDomainName $domainIdentity.DomainName)
        if ($identityMismatches.Count -gt 0) {
            throw "Nothing was moved: the VM at '$vmxFilePath' does not match this run: $($identityMismatches -join '; '). Check -VmStoragePath and -VmName, and new-AdDomain's global-config.ps1."
        }

        $memberServerOuState = Get-GuestMemberServerOuState @memberServerOuParameters
        if (-not $memberServerOuState.ServersOuExists) {
            throw "'$($domainIdentity.ServersOU)' does not exist yet, so directory population has not run or has not finished. Log into the DC console as Administrator, wait for Initialize-ADDirectory.ps1 to finish (its scheduled task disappears when it is done), then re-run with -MoveMemberServers."
        }
        $memberServersToMove = @($memberServerOuState.InComputersContainer)
        $memberServersInOu   = @($memberServerOuState.InServersOu)
        Write-Log "Member servers in '$($memberServerOuState.ComputersContainer)': $(if ($memberServersToMove.Count) { $memberServersToMove -join ', ' } else { 'none' }). Already in '$($domainIdentity.ServersOU)': $(if ($memberServersInOu.Count) { $memberServersInOu -join ', ' } else { 'none' })." -Level INFO

        if ($memberServersToMove.Count -eq 0) {
            Write-Log "No member server computer objects to move." -Level WARN
        }
        else {
            if ($memberServersToMove.Count -gt $maxMemberServerCount) {
                throw "$($memberServersToMove.Count) member server computer objects match '$memberServerNamePattern', more than the cap of $maxMemberServerCount. Nothing was moved. Check the computers container for unexpected objects, or raise `$maxMemberServerCount in the Variables region of build-lab.ps1."
            }
            $moveResult = Move-GuestMemberServerToServersOu @memberServerOuParameters -MaxObjectCount $maxMemberServerCount
            Write-Log "Moved to '$($domainIdentity.ServersOU)': $(@($moveResult.Moved) -join ', ')." -Level INFO

            # Verify by re-query rather than trusting the move's own report, which only covers
            # the final attempt when a retry happened.
            $memberServerOuState = Get-GuestMemberServerOuState @memberServerOuParameters
            $memberServersLeftBehind = @($memberServerOuState.InComputersContainer)
            if ($memberServersLeftBehind.Count -gt 0) {
                throw "Member servers still in '$($memberServerOuState.ComputersContainer)' after the move: $($memberServersLeftBehind -join ', ')."
            }
            Write-Log "Member servers verified in '$($domainIdentity.ServersOU)': $(@($memberServerOuState.InServersOu) -join ', ')." -Level SUCCESS
            Write-AppEvent -Enabled $enableEventLogging -SourceName $eventLogSourceName -EntryType Information -EventId 1700 -Message "Member servers moved to '$($domainIdentity.ServersOU)': $(@($memberServerOuState.InServersOu) -join ', ')."
        }
        Write-Log "=== build-lab.ps1 -MoveMemberServers complete ===" -Level SUCCESS
        return
    }

    # Names the member numbering must skip: the DC's own names, and with -AddMemberServers
    # every SRVR-NN computer object AD already holds (filled in below).
    $reservedMemberNames = @($VmName, $ComputerName)

    if ($AddMemberServers) {
        # Existing DC, left untouched: no payload copy, no deployment relaunch. It is checked
        # BEFORE the member plan, so a wrong -StaticIpAddress is reported as a wrong DC
        # address rather than as a member address that happens to answer ping (the DC's).
        Write-Log "-AddMemberServers: using the existing DC at '$vmxFilePath' without changing it. Waiting for guest operations (timeout: $GuestReadyTimeoutMinutes minute(s))..." -Level INFO
        Wait-GuestOperationsReady -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential -TimeoutMinutes $GuestReadyTimeoutMinutes
        $ntdsFilePath = 'C:\Windows\NTDS\ntds.dit'
        if (-not (Test-GuestPathExists -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential -PathType File -GuestPath $ntdsFilePath)) {
            throw "The VM at '$vmxFilePath' is not a promoted domain controller ('$ntdsFilePath' not found). Check -VmStoragePath and -VmName, or build the DC first with a full run."
        }
        Initialize-GuestTempDirectory -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential
        # Members use -StaticIpAddress as their DNS server and join global-config.ps1's
        # domain, so both have to match the real DC before any member is planned or built.
        $domainControllerIdentity = Get-GuestDomainControllerIdentity -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential `
            -HostStagingPath $stagingRootPath
        $identityMismatches = @(Compare-DomainControllerIdentity -Identity $domainControllerIdentity -ExpectedDomainName $domainIdentity.DomainName `
            -ExpectedIpAddress $StaticIpAddress -ExpectedPrefixLength $staticIpPrefixLength -ExpectedDefaultGateway $DefaultGateway)
        if ($identityMismatches.Count -gt 0) {
            throw "No member servers were built: the DC at '$vmxFilePath' does not match this run: $($identityMismatches -join '; '). Pass the DC's real -StaticIpAddress, -SubnetMask and -DefaultGateway, and check new-AdDomain's global-config.ps1."
        }
        $gatewayCheckDetail = if ($DefaultGateway) { "gateway $DefaultGateway matches" } else { 'gateway not checked and not set on the members, because -DefaultGateway was not given' }
        Write-Log "Existing DC verified ('$ntdsFilePath' present; domain and address match; $gatewayCheckDetail)." -Level SUCCESS

        # A computer object without a VM folder (the folder was deleted or moved) must not be
        # taken over silently by a new member, so AD's names are reserved as well.
        $existingMemberComputerNames = @(Get-GuestDomainComputerName -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential `
            -NamePattern $memberServerNamePattern -HostStagingPath $stagingRootPath)
        $reservedMemberNames += @($domainControllerIdentity.Name) + $existingMemberComputerNames
        if ($existingMemberComputerNames.Count -gt 0) {
            Write-Log "Member names already in AD, skipped by numbering: $($existingMemberComputerNames -join ', ')." -Level INFO
        }
    }

    # Member server plan: everything that can fail before a build (cap, member numbers, the
    # whole address range, addresses already in use) is checked here, before the DC or any
    # member is built. -IsoPath and -StaticIpAddress are guaranteed by the parameter sets:
    # mandatory in Build and AddMembers, and members are rejected with -SkipVmBuild and
    # -MoveMemberServers above.
    $memberServerPlan = @()
    if ($MemberServerCount -gt 0) {
        if ($MemberServerCount -gt $maxMemberServerCount) {
            throw "-MemberServerCount $MemberServerCount exceeds the cap of $maxMemberServerCount. Lower -MemberServerCount, or raise `$maxMemberServerCount in the Variables region of build-lab.ps1."
        }

        # The lowest free numbers, gaps first. Existing SRVR-NN folders and reserved names are
        # never reused (a leftover folder from a failed build would make the VM builder refuse
        # partway through the run), and each member's address follows its number.
        $memberNumbers     = @(Get-FreeMemberServerNumber -VmStoragePath $VmStoragePath -NamePrefix $memberServerNamePrefix -Count $MemberServerCount `
            -ReservedNames $reservedMemberNames)
        $memberIpAddresses = @(Get-MemberServerIpAddressList -DomainControllerIpAddress $StaticIpAddress -Offset $memberServerIpOffset `
            -MemberNumbers $memberNumbers -SubnetMask $SubnetMask -NetworkType $NetworkType -DefaultGateway $DefaultGateway)

        for ($memberIndex = 0; $memberIndex -lt $memberNumbers.Count; $memberIndex++) {
            $memberServerName = '{0}{1:D2}' -f $memberServerNamePrefix, $memberNumbers[$memberIndex]
            if (Test-IpAddressResponds -IpAddress $memberIpAddresses[$memberIndex]) {
                throw "Member server $memberServerName would get $($memberIpAddresses[$memberIndex]), which already answers ping, so another machine is using it. Nothing was built. Each member's address is the DC address + $memberServerIpOffset + (its number - 1); free that address or choose a different -StaticIpAddress for the DC."
            }
            $memberVmDirectoryPath = Join-Path -Path $VmStoragePath -ChildPath $memberServerName
            $memberServerPlan += [pscustomobject]@{
                Name        = $memberServerName
                IpAddress   = $memberIpAddresses[$memberIndex]
                VmxFilePath = Join-Path -Path $memberVmDirectoryPath -ChildPath "$memberServerName.vmx"
            }
        }
        Write-Log "Member server plan ($MemberServerCount, joining '$($domainIdentity.DomainName)' after the DC is verified; none of the addresses answers ping): $(($memberServerPlan | ForEach-Object { "$($_.Name)=$($_.IpAddress)" }) -join ', ')." -Level INFO
    }

    if (-not $AddMemberServers) {
        if ($SkipVmBuild) {
            Write-Log "-SkipVmBuild specified; reusing existing VM at '$vmxFilePath'." -Level INFO
        }
        else {
            Write-Log "Building VM '$VmName' via New-VMwareWorkstationVM.ps1. This usually takes 10-20 minutes, longer on slower storage..." -Level INFO
            $vmBuildParameters = Get-VmBuilderArgumentTable -IsoPath $IsoPath -AdminPassword $AdminPassword -VmName $VmName -VmStoragePath $VmStoragePath `
                -RamMB $RamMB -CpuCount $CpuCount -DiskGB $DiskGB -ComputerName $ComputerName -NetworkType $NetworkType `
                -StaticIpAddress $StaticIpAddress -SubnetMask $SubnetMask -DefaultGateway $DefaultGateway -DnsServer $DnsServer `
                -TimeoutMinutes $TimeoutMinutes -LogPath $logDirectoryPath -TempPath (Join-Path -Path $stagingRootPath -ChildPath "VMDeploy-$VmName")
            $null = & $VmBuilderScriptPath @vmBuildParameters
            # The VM builder only warns when the VM never answers on its address, so confirm it.
            if (-not (Wait-IpAddressResponds -IpAddress $StaticIpAddress)) {
                throw "VM '$VmName' was built but did not answer ping at $StaticIpAddress within 2 minutes, so the build is treated as failed. Check the VM console, and that $StaticIpAddress is in the right subnet for -NetworkType $NetworkType."
            }
            Write-Log "VM build complete; '$VmName' answers at $StaticIpAddress." -Level SUCCESS
            Write-AppEvent -Enabled $enableEventLogging -SourceName $eventLogSourceName -EntryType Information -EventId 1100 -Message "VM '$VmName' build complete."
        }

        Write-Log "Waiting for guest operations to become ready (timeout: $GuestReadyTimeoutMinutes minute(s))..." -Level INFO
        Wait-GuestOperationsReady -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential -TimeoutMinutes $GuestReadyTimeoutMinutes
        Write-Log "Guest operations ready." -Level SUCCESS

        if ($SkipVmBuild) {
            # On a promoted DC the re-run would only do damage: the payload refresh deletes the
            # deployment and population logs, and the deployment's pre-flight then refuses.
            $ntdsFilePath = 'C:\Windows\NTDS\ntds.dit'
            if (Test-GuestPathExists -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential -PathType File -GuestPath $ntdsFilePath) {
                throw "The VM at '$vmxFilePath' is already a promoted domain controller ('$ntdsFilePath' present), so -SkipVmBuild stopped before changing it. A re-run would delete C:\temp\new-AdDomain (the deployment and population logs) and the deployment would then refuse to run. Use -AddMemberServers or -MoveMemberServers against this DC, or revert the VM to a pre-deployment snapshot to retry the deployment."
            }
        }

        Write-Log "Staging and copying new-AdDomain payload to guest..." -Level INFO
        $payloadZipFilePath = New-AdDomainPayloadArchive -SourcePath $AdDomainSourcePath -StagingRootPath $stagingRootPath
        Copy-PayloadToGuest -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential -PayloadZipFilePath $payloadZipFilePath
        Write-Log "Payload deployed to C:\temp\new-AdDomain in guest." -Level SUCCESS
        Write-AppEvent -Enabled $enableEventLogging -SourceName $eventLogSourceName -EntryType Information -EventId 1200 -Message 'new-AdDomain payload deployed to guest.'

        # The volatile boot marker, set just before the launch. Promotion is confirmed by it
        # being gone (a reboot since this point) plus the DC role (Test-GuestDomainPromotion).
        Set-GuestBootMarker -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential -HostStagingPath $stagingRootPath

        $deploymentLaunchError = Invoke-GuestAdForestDeployment -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential `
            -StaticIpAddress $StaticIpAddress -PrefixLength $staticIpPrefixLength -DefaultGateway $DefaultGateway
        Write-AppEvent -Enabled $enableEventLogging -SourceName $eventLogSourceName -EntryType Information -EventId 1300 -Message 'New-ADForestDeployment.ps1 -CreateScheduledTask launched in guest.'

        $promotionResult = Test-GuestDomainPromotion -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential `
            -GuestReadyTimeoutMinutes $GuestReadyTimeoutMinutes -DeploymentTimeoutMinutes $DeploymentTimeoutMinutes -HostLogsRootPath $logDirectoryPath `
            -HostStagingPath $stagingRootPath -ExpectedDomainName $domainIdentity.DomainName -LaunchErrorMessage $deploymentLaunchError
        if ($promotionResult.HostLogsPath) {
            Write-Log "Guest deployment logs retrieved to '$($promotionResult.HostLogsPath)'." -Level INFO
        }
        # An unverified promotion fails the run whether or not members were requested, so it
        # can never end in the success footer and the "promotion succeeded" banner.
        if (-not $promotionResult.PromotionVerified) {
            $logsDetail = if ($promotionResult.HostLogsPath) { " Retrieved guest logs: '$($promotionResult.HostLogsPath)'." } else { '' }
            throw "AD forest promotion was not verified: $($promotionResult.NotVerifiedReason). No member servers were built. See the warnings above.$logsDetail"
        }
        Write-AppEvent -Enabled $enableEventLogging -SourceName $eventLogSourceName -EntryType Information -EventId 1400 -Message "AD forest promotion verified (ntds.dit present, the DC rebooted, and it is a DC in '$($domainIdentity.DomainName)')."
    }

    $memberServerResults = @()
    if ($memberServerPlan.Count -gt 0) {
        if (-not $AddMemberServers) {
            # Members also need the DC to answer guest operations after the promotion reboot.
            # (-AddMemberServers already confirmed this against the existing DC above.)
            Write-Log "Confirming the DC answers guest operations after promotion before building member servers..." -Level INFO
            try {
                Wait-GuestOperationsReady -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential -TimeoutMinutes $GuestReadyTimeoutMinutes
            }
            catch {
                throw "No member servers were built: the DC did not answer guest operations after promotion, so it is not known to be up. Confirm the DC is online, then add the members with -AddMemberServers (not -SkipVmBuild, which would re-run the DC deployment). $($_.Exception.Message)"
            }
        }

        $domainJoinCredential = [PSCredential]::new("$($domainIdentity.NetBIOSName)\Administrator", $AdminPassword)
        $memberServerNumber   = 0
        foreach ($memberServer in $memberServerPlan) {
            $memberServerNumber++
            Write-Log "--- Member server $($memberServer.Name) ($memberServerNumber of $($memberServerPlan.Count)), $($memberServer.IpAddress) ---" -Level INFO
            try {
                # Checked again just before this build: the plan was checked up front, but a
                # full build can run for an hour before this member's turn.
                if (Test-IpAddressResponds -IpAddress $memberServer.IpAddress) {
                    throw "$($memberServer.IpAddress) now answers ping, so another machine took it after the plan was checked. This member was not built."
                }
                Write-Log "Building VM '$($memberServer.Name)' via New-VMwareWorkstationVM.ps1. This usually takes 10-20 minutes, longer on slower storage..." -Level INFO
                $memberBuildParameters = Get-VmBuilderArgumentTable -IsoPath $IsoPath -AdminPassword $AdminPassword -VmName $memberServer.Name `
                    -VmStoragePath $VmStoragePath -RamMB $MemberRamMB -CpuCount $MemberCpuCount -DiskGB $MemberDiskGB `
                    -ComputerName $memberServer.Name -NetworkType $NetworkType -StaticIpAddress $memberServer.IpAddress -SubnetMask $SubnetMask `
                    -DefaultGateway $DefaultGateway -DnsServer $StaticIpAddress -TimeoutMinutes $TimeoutMinutes -LogPath $logDirectoryPath `
                    -TempPath (Join-Path -Path $stagingRootPath -ChildPath "VMDeploy-$($memberServer.Name)")
                $null = & $VmBuilderScriptPath @memberBuildParameters
                # The VM builder only warns when the VM never answers on its address, so confirm it.
                if (-not (Wait-IpAddressResponds -IpAddress $memberServer.IpAddress)) {
                    throw "VM '$($memberServer.Name)' was built but did not answer ping at $($memberServer.IpAddress) within 2 minutes, so the build is treated as failed. Check the VM console."
                }
                Write-Log "VM '$($memberServer.Name)' build complete; it answers at $($memberServer.IpAddress)." -Level SUCCESS
                Write-AppEvent -Enabled $enableEventLogging -SourceName $eventLogSourceName -EntryType Information -EventId 1500 -Message "Member server VM '$($memberServer.Name)' build complete."

                Wait-GuestOperationsReady -VmrunPath $vmrunPath -VmxFilePath $memberServer.VmxFilePath -GuestCredential $guestCredential -TimeoutMinutes $GuestReadyTimeoutMinutes
                Initialize-GuestTempDirectory -VmrunPath $vmrunPath -VmxFilePath $memberServer.VmxFilePath -GuestCredential $guestCredential

                Invoke-GuestDomainJoin -VmrunPath $vmrunPath -VmxFilePath $memberServer.VmxFilePath -GuestCredential $guestCredential `
                    -DomainName $domainIdentity.DomainName -DomainJoinCredential $domainJoinCredential -HostStagingPath $stagingRootPath
                # The volatile boot marker, set after the join and just before the restart; the
                # join is complete once it is gone and the guest reports the domain. Retried
                # inside, because the join has already happened and a transient failure here
                # must not leave the member joined but never rebooted.
                Set-GuestBootMarker -VmrunPath $vmrunPath -VmxFilePath $memberServer.VmxFilePath -GuestCredential $guestCredential -HostStagingPath $stagingRootPath
                Restart-GuestComputer -VmrunPath $vmrunPath -VmxFilePath $memberServer.VmxFilePath -GuestCredential $guestCredential
                Test-GuestDomainMembership -VmrunPath $vmrunPath -VmxFilePath $memberServer.VmxFilePath -GuestCredential $guestCredential `
                    -DomainName $domainIdentity.DomainName -TimeoutMinutes $DomainJoinTimeoutMinutes -HostStagingPath $stagingRootPath

                Write-AppEvent -Enabled $enableEventLogging -SourceName $eventLogSourceName -EntryType Information -EventId 1600 -Message "Member server '$($memberServer.Name)' joined to '$($domainIdentity.DomainName)'."
                $memberServerResults += [pscustomobject]@{ Name = $memberServer.Name; IpAddress = $memberServer.IpAddress; Status = 'Joined'; Detail = '' }
            }
            catch {
                $memberFailureMessage = $_.Exception.Message
                Write-Log "Member server '$($memberServer.Name)' failed: $memberFailureMessage Continuing with the remaining member servers." -Level ERROR
                Write-AppEvent -Enabled $enableEventLogging -SourceName $eventLogSourceName -EntryType Error -EventId 1650 -Message "Member server '$($memberServer.Name)' failed: $memberFailureMessage"
                $memberServerResults += [pscustomobject]@{ Name = $memberServer.Name; IpAddress = $memberServer.IpAddress; Status = 'Failed'; Detail = $memberFailureMessage }
            }
        }

        Write-Log "Member server summary:" -Level INFO
        foreach ($memberServerResult in $memberServerResults) {
            $summaryLevel  = if ($memberServerResult.Status -eq 'Joined') { 'SUCCESS' } else { 'ERROR' }
            $summaryDetail = if ($memberServerResult.Detail) { " -- $($memberServerResult.Detail)" } else { '' }
            Write-Log "  $($memberServerResult.Name) ($($memberServerResult.IpAddress)): $($memberServerResult.Status)$summaryDetail" -Level $summaryLevel
        }
    }
    $joinedMemberServerNames = @($memberServerResults | Where-Object { $_.Status -eq 'Joined' } | ForEach-Object { $_.Name })
    $failedMemberServerNames = @($memberServerResults | Where-Object { $_.Status -ne 'Joined' } | ForEach-Object { $_.Name })

    if ($failedMemberServerNames.Count -gt 0) {
        Write-Log "=== build-lab.ps1 finished with member server failures ===" -Level ERROR
    }
    else {
        Write-Log "=== build-lab.ps1 complete ===" -Level SUCCESS
    }

    # -AddMemberServers ran against an existing DC whose population state is unknown, so the
    # "population has not run" notice would be wrong there.
    if (-not $AddMemberServers) {
        Write-Log "Directory population has NOT run yet. Log into the guest console as Administrator to trigger Initialize-ADDirectory.ps1 (registered as a logon-triggered scheduled task)." -Level INFO
    }
    if ($joinedMemberServerNames.Count -gt 0) {
        Write-Log "Member servers $($joinedMemberServerNames -join ', ') are in the default CN=Computers container. Once directory population has finished, re-run with -MoveMemberServers to move them to OU=Servers." -Level INFO
    }
    Show-PostBuildManualStepNotice -JoinedMemberServerNames $joinedMemberServerNames -OmitPopulationNotice:$AddMemberServers

    if ($failedMemberServerNames.Count -gt 0) {
        throw "$($failedMemberServerNames.Count) of $($memberServerPlan.Count) member server(s) failed: $($failedMemberServerNames -join ', '). The DC is verified; see the member server summary above for each failure."
    }
}
catch {
    Write-Log "build-lab.ps1 failed: $($_.Exception.Message)" -Level FATAL
    Write-AppEvent -Enabled $enableEventLogging -SourceName $eventLogSourceName -EntryType Error -EventId 9999 -Message "build-lab.ps1 failed: $($_.Exception.Message)"
    throw
}
finally {
    $guestPasswordPlainText = $null
    $guestCredential        = $null
    $domainJoinCredential   = $null
    if (Test-Path -LiteralPath $stagingRootPath) {
        Remove-Item -LiteralPath $stagingRootPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-AppEvent -Enabled $enableEventLogging -SourceName $eventLogSourceName -EntryType Information -EventId 1001 -Message 'build-lab.ps1 finished.'
}

#endregion Main
