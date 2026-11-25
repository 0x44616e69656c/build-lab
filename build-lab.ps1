<#
.SYNOPSIS
    Builds a lab Active Directory domain controller end to end: creates a Windows
    Server 2025 VM, deploys the new-AdDomain project into it, runs forest promotion, and
    populates the directory.
.DESCRIPTION
    Orchestrates three pieces into one lab build:
      1. Calls New-VMwareWorkstationVM.ps1 (sibling project) to create and start a
         Windows Server 2025 VM. -StaticIpAddress is mandatory here (it is optional in
         the child script) because without it the child returns immediately after
         starting the VM with no wait, leaving no guest network for the steps below.
      2. Copies the new-AdDomain project into the guest at C:\temp\new-AdDomain via
         vmrun VIX guest operations (zip on host, copyFileFromHostToGuest, expand
         in-guest).
      3. Runs New-ADForestDeployment.ps1 inside the guest to promote the forest.
      4. Starts directory population (Initialize-ADDirectory.ps1) in the guest and waits for
         it to finish, unless -DeferPopulation is given.

    Before any of that, in every mode, new-AdDomain is copied once into a per-run staging
    folder on the host, with the build profile in place (see -ProfilePath), and the
    staged copy is read and checked: the domain identity, the build profile and the
    service account SPN placeholders. The guest gets exactly the files checked there. A
    problem in them stops the run before any VM is built or changed.

    Which build profile a run uses:
      - -ProfilePath given: that file. If the source new-AdDomain also holds a different
        include\build-profile.psd1, a WARN says it was replaced.
      - -ProfilePath not given, and the source holds include\build-profile.psd1: that
        file, with a WARN naming its path and SHA-256, because a file nobody named on the
        command line then decides which forest is built.
      - Neither: no build profile. The global-config.ps1 values apply.
    The log names the profile's path and the SHA-256 of the copy the guest gets.

    In a full build, when the effective PrimarySubnet is an explicit subnet rather than
    Auto, the DC's -StaticIpAddress is checked against it early. A miss is a WARN. The
    guest then uses Auto, and its "Requested subnet" test row fails.

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

    Which network the VMs join (-NetworkType): nat, bridged, hostonly, or a custom VMnet
    such as VMnet2, which must already exist in Workstation. The value comes from the
    command line, then the build profile's NetworkType, then the override file, then the
    default, nat. VMnet0, VMnet1 and VMnet8 are taken as bridged, hostonly and nat. The log
    names the network used and where it came from. Every check that a VM is up is a ping
    from this host, so in a full build and -AddMemberServers, for every network but
    bridged, the network check runs before anything is pinged or built. It looks for the
    network's host adapter ('VMware Network Adapter VMnet<N>'), for every host adapter that
    holds the DC's subnet, and for the adapter this host's route to the DC leaves by. It
    stops when that adapter holds another subnet, when the route leaves by another
    adapter, or when no host adapter is on the DC's subnet at all, because the VMs could
    not be reached. Other doubts are WARNs. When no -SubnetMask was given, on the command
    line or in the override file, the VMs take the prefix of the network's host adapter.
    A custom VMnet is also checked against the VM builder's own -NetworkType, read without
    running it, and a builder that would refuse it stops the run. build-lab never creates
    or changes a VMnet or any host networking.

    Directory population (Initialize-ADDirectory.ps1) runs without a console logon. Once
    promotion is verified, build-lab waits for the directory to answer Get-ADDomain,
    starts population fire-and-forget over vmrun with a launch ID, and polls the guest's
    completion marker (C:\temp\new-AdDomain\artifacts\population-result.json) until it
    reports Succeeded or Failed for that launch. Nothing is stored in the guest for this,
    no password and no task. The guest's logs, the marker and the files it lists are
    retrieved into a second logs\guest-<timestamp>\ folder whatever the outcome. The
    guest's users export, which holds every generated password, never is. A population
    that fails, never starts or runs past -PopulationTimeoutMinutes fails the run before
    any member server is built. The staged new-AdDomain must be one that reports
    population back (its Initialize-ADDirectory.ps1 takes -LaunchId), or the run stops
    before any VM is built or changed.

    -DeferPopulation keeps the earlier flow. New-ADForestDeployment.ps1 registers a
    scheduled task triggered at the next Administrator logon, build-lab doesn't start
    population, and a red banner at the end says to log into the guest console as
    Administrator to start it.

    Every run that starts logging, in every mode and whatever its outcome, writes a build
    manifest beside its log, logs\build-lab-manifest_<timestamp>.csv, one fact per row with
    the columns Section, Item, Field, Value and Note. It records the three projects'
    versions and git commits, each script's version, each override file's SHA-256, the
    install ISO's and the VMware Tools ISO's SHA-256 (never the answer ISO, which holds the
    Administrator password), the build profile, the domain, network and population values
    with their sources, each VM's name, role, status, OS build and address, and when the
    run started and ended, with its outcome. It is saved as the run goes, so a run that
    stops still leaves one. ISO hashes are kept in logs\iso-sha256-cache.csv, so an ISO is
    hashed once per host. Delete the cache to hash every ISO again. The manifest never
    stops a build, and a step of it that fails is a WARN.

    Use -SkipVmBuild to re-run the guest phases (steps 2-4) against an existing VM,
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
    global-config.ps1, or in the build profile when the run uses one:
      - Names are SRVR-NN (VM name and computer name are the same), using the lowest free
        numbers, gaps first. A number is taken if its folder exists under -VmStoragePath,
        if it is the DC's -VmName or -ComputerName, or (with -AddMemberServers) if AD
        already holds a computer object of that name. Taken numbers are never reused.
      - Each member's address follows its number: DC address + 10 + (number - 1), so
        SRVR-03 is always DC + 12. Every address is validated and pinged before anything
        is built, and pinged again just before that member's build.
      - DNS is the DC's address. Members get this run's network and mask and its
        -DefaultGateway. Without -DefaultGateway they get the VM builder's own
        DefaultGateway when its override file sets one (logged with a WARN and checked
        against the DC's subnet), and none otherwise. With -AddMemberServers the network
        is the one in the DC's VMX, with a WARN when this run asked for another, so the
        members can reach the DC.
      - After the build, the member must answer ping on its address.
      - The join runs Add-Computer in the guest synchronously without a reboot, then
        reboots fire-and-forget and polls until the guest has rebooted and reports
        PartOfDomain for the expected domain.
      - Members are built after directory population and land in the default
        CN=Computers container, so moving them to OU=Servers is a separate later step
        (-MoveMemberServers, below).
    A member that fails is logged and the rest continue. The run then prints a summary
    and throws: exit code 1 under powershell.exe -File, or a terminating error raised to
    the caller when invoked in a session. The cap on -MemberServerCount is the
    MaxMemberServerCount setting, 5 unless the override file changes it.

    -AddMemberServers builds and joins members against an EXISTING DC without touching
    it: no payload copy, no deployment relaunch. It checks that the DC answers guest
    operations, that ntds.dit is present, and that the DC's own domain role, domain,
    address and prefix length match the effective configuration (global-config.ps1, with
    the build profile over it) and the values passed to this run.
    The gateway is checked only when -DefaultGateway is given; without it, the DC's gateway
    is not checked, and the members get the VM builder's own DefaultGateway when its
    override file sets one, or none. These checks run before the member plan, so a wrong
    -StaticIpAddress is reported as such. -IsoPath, the DC's -StaticIpAddress and
    -MemberServerCount are required.

    -MoveMemberServers is the later OU=Servers step mentioned above, run on its own once
    directory population has finished, after the build or, with -DeferPopulation, after
    the Administrator logon on the DC.
    Against the existing DC it moves every SRVR-NN computer object from the domain's
    default computers container to OU=Servers (both read from the DC and the effective
    configuration), then re-queries to confirm none are left behind. It first checks
    that the VM is a DC in the configured domain. -AddMemberServers and -MoveMemberServers
    need the build profile the DC was built with, chosen by the same rule as a build, or
    the domain check refuses the DC. It fails with a clear message if
    OU=Servers does not exist yet, and moves nothing if more objects match than
    MaxMemberServerCount. Re-running it is harmless: objects already in OU=Servers are
    reported and left alone.

    Settings you keep from run to run go in overrides\overrides.psd1 in this script's
    folder, which git ignores and no upgrade touches. It can change the default of every
    parameter OVERRIDE.md lists, and the MaxMemberServerCount and EnableEventLogging
    settings. A value on the command line wins over the file. With no file, one INFO
    line says so and the shipped values apply. The file is read before anything else,
    and a problem in it stops the run, logged, before any VM is built or changed.

    The two sibling projects are checked before anything is built. new-AdDomain's
    New-ADForestDeployment.ps1 and New-VMwareWorkstationVM.ps1 are read for their header
    Version by parsing, never by running them. An older new-AdDomain stops the run. An
    older New-VMwareWorkstationVM is a WARN, and stops the run only when it has an
    override file it would ignore. A custom VMnet also stops the run when the builder's
    -NetworkType would refuse it. The staged new-AdDomain's global-config.ps1 must be at
    least the version its scripts need, which catches an older copy put back over a newer
    one.

    -AddMemberServers and -MoveMemberServers against a DC in another domain stop, unless
    nothing named a domain at all: no build profile, no new-AdDomain override file and
    an unedited global-config.ps1. Then the DC's own domain is used, read from the DC
    with Get-ADDomain, with a WARN.
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
    VMware network for every VM built: 'nat' (default, VMnet8), 'bridged', 'hostonly'
    (VMnet1), or a custom VMnet from VMnet0 to VMnet99 with no leading zero, such as
    'VMnet2', in any case. VMnet0, VMnet1 and VMnet8 are taken as bridged, hostonly and
    nat. A custom VMnet must already exist, and needs New-VMwareWorkstationVM 1.2 or
    later. A build profile's NetworkType gives it too, and the command line wins over the
    profile with a WARN when they differ. The network check, described above, runs before
    anything is built. -AddMemberServers uses the DC's own network, from its VMX.
.PARAMETER SubnetMask
    Subnet mask for every VM built. Default 255.255.255.0. 0.0.0.0 is refused, except by
    -MoveMemberServers, which doesn't use the mask. When it is
    given neither here nor in the override file, a full build or an -AddMemberServers run
    takes the prefix of the host adapter that holds the DC's subnet, and logs it, so a
    custom VMnet with a /16 gets 255.255.0.0. A given mask that differs from that adapter's
    prefix is used, with a WARN.
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
    Path to the new-AdDomain project. Default: the sibling project folder. It must be a
    new-AdDomain with build profile support (include\BuildProfile.ps1).
.PARAMETER ProfilePath
    A build profile (.psd1) for this run, accepted in all four modes. It is copied over
    include\build-profile.psd1 in the staged copy of new-AdDomain, so the guest builds
    from it. Without it, a build-profile.psd1 in the source new-AdDomain is used if there
    is one (with a WARN), otherwise none. Must name an existing .psd1 file.
.PARAMETER GuestReadyTimeoutMinutes
    The longest wait for a guest to answer guest operations, and for the DC's promotion
    reboot after ntds.dit appears. Default 20. Checked between polls, so the last poll
    can finish a few minutes after it.
.PARAMETER DeploymentTimeoutMinutes
    The longest wait for ntds.dit after launching the forest deployment. Default 30.
.PARAMETER MemberServerCount
    Number of member servers to build and join. Default 0. Capped by the
    MaxMemberServerCount setting (OVERRIDE.md).
.PARAMETER MemberRamMB
    Member memory in MB. Default 2048.
.PARAMETER MemberCpuCount
    Member virtual CPUs. Default 1.
.PARAMETER MemberDiskGB
    Member disk size in GB. Default 60.
.PARAMETER DomainJoinTimeoutMinutes
    Per member, the longest wait for the post-join reboot and domain membership. Default 20.
    Checked between polls, so the last poll can finish a few minutes after it.
.PARAMETER DeferPopulation
    Leave directory population to the logon task. The deployment registers the task,
    build-lab doesn't start population, and the closing banner says to log into the DC
    console as Administrator. Without it, build-lab starts population itself once
    promotion is verified, waits for it to finish, and builds any member servers after it.
    Full build and -SkipVmBuild only.
.PARAMETER PopulationTimeoutMinutes
    The longest wait for directory population to finish once build-lab has started it.
    Default 240, the logon task's own four-hour limit. Ignored with -DeferPopulation.
    Checked between polls, so the last poll can finish a few minutes after it. Full build
    and -SkipVmBuild only.
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
    # Later step, once directory population has finished. Move the joined SRVR-NN member
    # servers from CN=Computers to OU=Servers.
    $pw = Read-Host -Prompt 'Guest Administrator password' -AsSecureString
    .\build-lab.ps1 -MoveMemberServers -AdminPassword $pw -VmStoragePath 'C:\VMs' -VmName 'LabServer01'
.EXAMPLE
    # A full build of a different forest from a build profile kept outside both
    # repositories, for example C:\LabProfiles\corp.psd1 holding
    #   @{ DomainName = 'corp.example.test'; NetBIOSName = 'CORP'; PrimarySiteName = 'Corp-HQ' }
    # Later -AddMemberServers and -MoveMemberServers runs against this DC pass the same file.
    $pw = Read-Host -Prompt 'Guest Administrator password' -AsSecureString
    .\build-lab.ps1 -IsoPath 'C:\ISOs\WS2025.iso' -AdminPassword $pw -VmStoragePath 'C:\VMs' `
        -VmName 'CORPDC01' -ComputerName 'CORPDC01' -StaticIpAddress '192.168.220.50' `
        -DefaultGateway '192.168.220.2' -ProfilePath 'C:\LabProfiles\corp.psd1'
.EXAMPLE
    # Two labs at once, each on its own host-only VMnet with no NAT, made beforehand in
    # Workstation's Virtual Network Editor with its own subnet and a host virtual adapter
    # (here VMnet2 on 10.20.0.0/24 and VMnet3 on 10.30.0.0/24). Each gets its own
    # -VmStoragePath, so the member names (SRVR-NN) don't collide, and no -DefaultGateway.
    # The two forests can have the same name. Neither can reach the internet, so the DNS
    # forwarders and time sync have nothing to talk to.
    $pw = Read-Host -Prompt 'Guest Administrator password' -AsSecureString
    .\build-lab.ps1 -IsoPath 'C:\ISOs\WS2025.iso' -AdminPassword $pw -VmStoragePath 'C:\VMs\LabA' `
        -NetworkType 'VMnet2' -StaticIpAddress '10.20.0.50' -MemberServerCount 1
    # In a second PowerShell window, after its own Read-Host for $pw:
    .\build-lab.ps1 -IsoPath 'C:\ISOs\WS2025.iso' -AdminPassword $pw -VmStoragePath 'C:\VMs\LabB' `
        -NetworkType 'VMnet3' -StaticIpAddress '10.30.0.50' -MemberServerCount 1
.OUTPUTS
    None to the pipeline. Progress goes to the console and to logs\build-lab_<timestamp>.log;
    WARN, ERROR and FATAL rows also go to logs\build-lab-errors_<timestamp>.csv; key events go
    to the Application event log once the build-lab source is registered (see Setup below).
    The VM builder writes its own VMDeploy_* log and
    transcript to the same logs folder, and guest deployment logs are retrieved into
    logs\guest-<timestamp>\. The build manifest, logs\build-lab-manifest_<timestamp>.csv,
    and the ISO hash cache, logs\iso-sha256-cache.csv, go to the same folder. A failure
    ends in a terminating error (exit code 1 under powershell.exe -File).
.NOTES
    Version:      2.3.0
    Author:       Daniel Owen
    Release Date: 2026-11-25
    SPDX-License-Identifier: MIT
    Requirements: VMware Workstation 17+ (vmrun.exe), Windows PowerShell 5.1 (Desktop
                  edition, enforced by #Requires). It needs no elevation. vmrun guest
                  operations authenticate against the guest, not the host, and this script
                  never registers an event source. Windows Server 2025 ISO. Sibling
                  projects new-AdDomain 2.2.0 or later and New-VMwareWorkstationVM
                  1.2.0 or later present relative to this script (override with
                  -VmBuilderScriptPath / -AdDomainSourcePath if relocated). Shared
                  copies in include\, OverrideFile.ps1 among them, and
                  include\override-catalog.psd1. Guest credentials are Administrator / -AdminPassword;
                  the plaintext password unavoidably appears in vmrun's -gp argument
                  (visible in the host process list) -- accepted for lab use. Passwords
                  containing a double-quote character are rejected because they break
                  vmrun argument quoting. Events are written with Write-EventLog, which
                  exists in Windows PowerShell 5.1 only.
    Target Set Source: N/A
    Event Log Source: build-lab, under the Application log. Checked at the start of each
                  run. When it isn't registered the run writes no events, logs one WARN
                  and carries on with its text and CSV logs.
    Setup:        Register-EventLogSource.ps1 -SourceName 'build-lab', beside this
                  script, run once, elevated, on each host that runs build-lab.
.LINK
    https://github.com/0x44616e69656c/build-lab
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

    # nat, bridged, hostonly, or a custom VMnet0 to VMnet99, in any case. Anchored with \A
    # and \z, because $ would let a trailing newline through. No ArgumentCompleter: the
    # OVERRIDE.md generator refuses an attribute it doesn't know.
    [ValidatePattern('\A(nat|bridged|hostonly|VMnet(0|[1-9][0-9]?))\z')]
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

    # A build profile (.psd1), in every parameter set. Checked in the body after logging
    # starts (Confirm-BuildProfilePath), so a bad path is logged like any other stop.
    [string]$ProfilePath,

    [ValidateRange(1, 120)]
    [int]$GuestReadyTimeoutMinutes = 20,

    # Upper bound on how long to poll for the promotion artifact (ntds.dit) after launching
    # New-ADForestDeployment.ps1 fire-and-forget. Covers AD DS install + forest promotion.
    [ValidateRange(1, 240)]
    [int]$DeploymentTimeoutMinutes = 30,

    # --- Member servers ---
    # Upper bound here only keeps the SRVR-NN two-digit naming valid. The working cap is
    # $maxMemberServerCount (the MaxMemberServerCount setting), checked before anything
    # is built.
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

    # --- Directory population ---
    # Only a full build and -SkipVmBuild deploy the DC, so only they run population.
    [Parameter(ParameterSetName = 'Build')]
    [Parameter(ParameterSetName = 'GuestOnly')]
    [switch]$DeferPopulation,

    # How long to poll for population's final marker. The logon task's own limit is four hours.
    [Parameter(ParameterSetName = 'Build')]
    [Parameter(ParameterSetName = 'GuestOnly')]
    [ValidateRange(1, 1440)]
    [int]$PopulationTimeoutMinutes = 240,

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
foreach ($includeFileName in @('Sanitization.ps1', 'Logging.ps1', 'EventLogging.ps1', 'Retry.ps1', 'FileUtilities.ps1', 'OverrideFile.ps1')) {
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

function ConvertFrom-PrefixLength {
    # Converts a CIDR prefix length (e.g. 16) to a dotted-decimal subnet mask (e.g.
    # 255.255.0.0), for the mask the network check takes from a host adapter when no mask
    # was given.
    param (
        [Parameter(Mandatory)]
        [ValidateRange(0, 32)]
        [int]$PrefixLength
    )
    $maskNumber = if ($PrefixLength -eq 0) { [long]0 } else { ([long]4294967295 -shl (32 - $PrefixLength)) -band [long]4294967295 }
    return (@(24, 16, 8, 0) | ForEach-Object { ($maskNumber -shr $_) -band 255 }) -join '.'
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

function Invoke-NativeCommand {
    # Runs a native program, vmrun.exe or git.exe, with two host-side bounds. vmrun has no
    # timeout of its own, so a call that never returns (the field-confirmed case is one held
    # open across a guest reboot) would otherwise hang the whole run. -TimeoutSeconds bounds
    # the process: on timeout it is killed and the call throws. -OutputDrainTimeoutSeconds
    # bounds reading its output after it exits, because the output pipes stay open while any
    # process it started still holds them. Killing vmrun ends only the host-side call. A
    # guest program it started keeps running (seen 2026-10-25, when a runProgramInGuest
    # killed after 10 s still completed its 60 s guest command).
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
    # Each error text names the program by its file name without .exe, so a vmrun call
    # still reads "vmrun operation '...'" and a git call "git operation '...'".
    #
    # -AllowNonZeroExit returns { ExitCode; Output } instead of throwing on a non-zero exit
    # code, for vmrun queries that report their answer that way (fileExistsInGuest,
    # directoryExistsInGuest), and for git. Output containing "Error" still throws, unless
    # -IgnoreOutputErrorText is given: -match ignores case, so git's own "error:" lines
    # would trip the rule that exists for vmrun.
    param (
        [Parameter(Mandatory)]
        [string]$FilePath,
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
        [switch]$AllowNonZeroExit,
        [switch]$IgnoreOutputErrorText
    )
    $programName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
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
    $processStartInfo.FileName               = $FilePath
    $processStartInfo.Arguments              = (@($ArgumentList | ForEach-Object { & $quoteArgument $_ })) -join ' '
    $processStartInfo.UseShellExecute        = $false
    $processStartInfo.RedirectStandardOutput = $true
    $processStartInfo.RedirectStandardError  = $true
    $processStartInfo.StandardOutputEncoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    $processStartInfo.StandardErrorEncoding  = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    $processStartInfo.CreateNoWindow         = $true
    $processStartInfo.WorkingDirectory       = (Get-Location -PSProvider FileSystem).ProviderPath

    $nativeProcess = [System.Diagnostics.Process]::Start($processStartInfo)
    try {
        # Both streams are read asynchronously so a full pipe buffer on one cannot stall the
        # process while this waits on the other.
        $standardOutputTask = $nativeProcess.StandardOutput.ReadToEndAsync()
        $standardErrorTask  = $nativeProcess.StandardError.ReadToEndAsync()
        if (-not $nativeProcess.WaitForExit($TimeoutSeconds * 1000)) {
            $exitedBeforeKill = $false
            try {
                $nativeProcess.Kill()
            }
            catch [System.InvalidOperationException] {
                # The program exited between the timeout and the kill, so it finished after all:
                # fall through and use its result like any other completed call.
                $exitedBeforeKill = $true
            }
            if (-not $exitedBeforeKill) {
                $null = $nativeProcess.WaitForExit(5000)
                throw "$programName operation '$OperationName' timed out after $TimeoutSeconds second(s) and was stopped.$(if ($programName -eq 'vmrun') { ' Anything it started in the guest may still be running.' })"
            }
        }
        # The reads finish at EOF, which can come later than the exit when a process the
        # program started still holds the pipes, so the wait for them is bounded too.
        $outputReadTasks = [System.Threading.Tasks.Task[]]@($standardOutputTask, $standardErrorTask)
        if (-not [System.Threading.Tasks.Task]::WaitAll($outputReadTasks, $OutputDrainTimeoutSeconds * 1000)) {
            throw "$programName operation '$OperationName' exited (exit code $($nativeProcess.ExitCode)), but its output did not finish within $OutputDrainTimeoutSeconds second(s). A process it started may still hold its output pipes."
        }
        $exitCode      = $nativeProcess.ExitCode
        $commandOutput = @(($standardOutputTask.Result + "`n" + $standardErrorTask.Result) -split "`r?`n" | Where-Object { $_ -ne '' })
    }
    finally {
        # Process.Dispose does not close the redirected readers on .NET Framework, so they are
        # disposed here. Disposing them with a read still pending (the drain-timeout case) is
        # safe: the pending read faults and is discarded (checked 2026-10-24).
        $nativeProcess.StandardOutput.Dispose()
        $nativeProcess.StandardError.Dispose()
        $nativeProcess.Dispose()
    }

    foreach ($redactedToken in $RedactedTokens) {
        if ($redactedToken) {
            $commandOutput = @($commandOutput | ForEach-Object { $_ -replace [regex]::Escape($redactedToken), '***' })
        }
    }

    $outputHasErrorText = (-not $IgnoreOutputErrorText) -and ($commandOutput -match 'Error')
    if ($AllowNonZeroExit) {
        if ($outputHasErrorText) {
            throw "$programName operation '$OperationName' failed (exit code $exitCode): $($commandOutput -join ' ')"
        }
        return [pscustomobject]@{
            ExitCode = $exitCode
            Output   = $commandOutput
        }
    }
    if ($exitCode -ne 0 -or $outputHasErrorText) {
        throw "$programName operation '$OperationName' failed (exit code $exitCode): $($commandOutput -join ' ')"
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
    $queryResult  = Invoke-NativeCommand -FilePath $VmrunPath -OperationName "$existCommand $GuestPath" -RedactedTokens @($guestPasswordPlainText) `
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
            $toolsStateOutput = Invoke-NativeCommand -FilePath $VmrunPath `
                -ArgumentList @('-T', 'ws', 'checkToolsState', $VmxFilePath) `
                -OperationName 'checkToolsState' `
                -RedactedTokens @($guestPasswordPlainText) -TimeoutSeconds $ProbeTimeoutSeconds
            $toolsState = ($toolsStateOutput -join '').Trim()

            if ($toolsState -in @('running', 'installed')) {
                # The guest-exec probe is the real gate: it confirms VIX can run a program
                # with the Administrator credential. It runs on 'installed' too, because
                # Workstation can go on reporting 'installed' long after Tools works in the
                # guest, and a state that never changes would hold the wait to its timeout.
                # Isolate its failure so a credential/OOBE problem is not misreported as
                # "Tools not ready".
                try {
                    $null = Invoke-NativeCommand -FilePath $VmrunPath `
                        -ArgumentList @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText,
                            'runProgramInGuest', $VmxFilePath, 'C:\Windows\System32\whoami.exe') `
                        -OperationName 'guest readiness probe' `
                        -RedactedTokens @($guestPasswordPlainText) -TimeoutSeconds $ProbeTimeoutSeconds
                    $isGuestReady = $true
                }
                catch {
                    if ($toolsState -eq 'running') {
                        $notReadyReason = "VMware Tools is 'running' but the guest-exec probe (whoami) failed -- commonly the Administrator credential is not yet accepted while the guest finishes OOBE/specialize, or the -AdminPassword is wrong: $($_.Exception.Message)"
                    }
                    else {
                        $notReadyReason = "VMware Tools not ready yet (checkToolsState = 'installed'), and the guest-exec probe (whoami) failed: $($_.Exception.Message)"
                    }
                }
            }
            else {
                $notReadyReason = "VMware Tools not ready yet (checkToolsState = '$toolsState')."
            }
        }
        catch {
            $notReadyReason = "checkToolsState call failed (guest likely still booting): $($_.Exception.Message)"
        }

        if ($isGuestReady) {
            if ($toolsState -eq 'installed' -and $logCommand) {
                Write-Log "VMware Tools still reports 'installed', but the guest-exec probe (whoami) passed, so guest operations are ready." -Level INFO
            }
            return
        }

        $minutesRemaining = [math]::Round(($readyDeadline - (Get-Date)).TotalMinutes, 1)
        if ($logCommand) {
            Write-Log "Guest not ready yet -- $notReadyReason ($minutesRemaining minute(s) remaining before timeout)." -Level INFO
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }

    throw "Guest operations did not become ready within $TimeoutMinutes minute(s). Last probe reason: $notReadyReason Check the VM console for setup progress, verify VMware Tools is installed, and confirm the Administrator credentials."
}

function Copy-AdDomainPayloadToStaging {
    # Copies new-AdDomain once into <StagingRootPath>\new-AdDomain and returns that path.
    # Every later step works on this staged copy: the build profile is placed in it, it is
    # read and checked on the host, and the DC payload zip is made from it, so the guest
    # gets exactly the files that were checked. A source build-profile.psd1 comes along,
    # because the exclusions below do not name it.
    #
    # robocopy's own defaults retry a file it can't copy a million times, 30 seconds apart,
    # so one locked or unreachable file could hold the run for months. /R:2 /W:5 gives up on
    # such a file after about ten seconds, and the whole copy is bounded by -TimeoutSeconds:
    # it runs through Invoke-NativeCommand, which stops robocopy when that time passes.
    # Exit codes 0 to 7 are robocopy's successes, and 8 or more a failure.
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
            'AD_Deployment_Consolidated_Plan.md', 'todo.md'),
        [ValidateRange(1, 86400)]
        [int]$TimeoutSeconds = 600
    )
    $stagingPayloadPath = Join-Path -Path $StagingRootPath -ChildPath 'new-AdDomain'
    $null = New-Item -ItemType Directory -Path $StagingRootPath -Force

    $robocopyArgumentList = @($SourcePath, $stagingPayloadPath, '/E', '/R:2', '/W:5', '/NFL', '/NDL', '/NJH', '/NJS', '/XD') + $ExcludedDirectoryNames + @('/XF') + $ExcludedFileNames
    $robocopyPath = Join-Path -Path $env:SystemRoot -ChildPath 'System32\robocopy.exe'
    try {
        # Output is kept so a failure can show robocopy's own error text, not just the code.
        $robocopyResult = Invoke-NativeCommand -FilePath $robocopyPath -ArgumentList $robocopyArgumentList -OperationName 'stage new-AdDomain' `
            -AllowNonZeroExit -IgnoreOutputErrorText -TimeoutSeconds $TimeoutSeconds
    }
    catch {
        throw "Staging new-AdDomain from '$SourcePath' to '$stagingPayloadPath' failed: $($_.Exception.Message) Check that the folder is reachable and that nothing holds its files open, then run again."
    }
    if ($robocopyResult.ExitCode -ge 8) {
        $robocopyErrorText = (@($robocopyResult.Output) | Where-Object { $_ } | Select-Object -Last 10) -join ' '
        throw "robocopy failed copying '$SourcePath' to '$stagingPayloadPath' (exit code $($robocopyResult.ExitCode)). robocopy output: $robocopyErrorText"
    }
    return $stagingPayloadPath
}

function Test-PayloadHiddenItem {
    # Compress-Archive leaves hidden files and folders out of the payload zip, while robocopy
    # stages them with their Hidden attribute and the host reads and checks them. What that
    # costs depends on the file. A hidden file the guest uses (a .ps1, .psd1, .csv or .json,
    # such as the override file, a replacement CSV or the build profile), or one inside a
    # hidden folder, would be checked here and missing in the guest, and no value would be
    # safe in its place, so the run stops, naming each such file. Anything else hidden, such
    # as desktop.ini or Thumbs.db, gets one WARN naming it, a hidden folder once, and is left
    # out, since the guest has no use for it. Each item is named where the user can fix it:
    # under -SourcePath, or for the staged build profile, -ProfileOriginPath.
    # Returns { Stop; Warning }, each $null or the text.
    param (
        [Parameter(Mandatory)]
        [string]$StagedPayloadPath,
        [Parameter(Mandatory)]
        [string]$SourcePath,
        [string]$ProfileOriginPath,
        [string[]]$GuestFileExtensions = @('.ps1', '.psd1', '.csv', '.json')
    )
    $stagedRoot = (Get-Item -LiteralPath $StagedPayloadPath -Force -ErrorAction Stop).FullName.TrimEnd('\')
    $nameFor = {
        param ([string]$RelativePath)
        if ($ProfileOriginPath -and $RelativePath -eq 'include\build-profile.psd1') { "'$ProfileOriginPath'" }
        else { "'$(Join-Path -Path $SourcePath -ChildPath $RelativePath)'" }
    }
    $hiddenFolders   = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $stopNames       = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $warningNames    = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $stagedItems = @(Get-ChildItem -LiteralPath $stagedRoot -Recurse -Force -ErrorAction Stop | Sort-Object -Property FullName)
    foreach ($stagedItem in $stagedItems) {
        $relativePath = $stagedItem.FullName.Substring($stagedRoot.Length).TrimStart('\')
        $isHidden = [bool]($stagedItem.Attributes -band [System.IO.FileAttributes]::Hidden)
        $inHiddenFolder = @($hiddenFolders | Where-Object { $relativePath.StartsWith("$_\", [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        if ($stagedItem.PSIsContainer) {
            if ($isHidden -and -not $inHiddenFolder) {
                $hiddenFolders.Add($relativePath)
                $warningNames.Add((& $nameFor $relativePath))
            }
            continue
        }
        if (-not ($isHidden -or $inHiddenFolder)) { continue }
        if ($GuestFileExtensions -contains [System.IO.Path]::GetExtension($stagedItem.Name).ToLowerInvariant()) {
            $stopNames.Add((& $nameFor $relativePath))
        }
        elseif (-not $inHiddenFolder) {
            $warningNames.Add((& $nameFor $relativePath))
        }
    }
    $result = [pscustomobject]@{ Stop = $null; Warning = $null }
    if ($stopNames.Count -gt 0) {
        $result.Stop = "new-AdDomain holds hidden files the guest uses, which the payload zip would leave out, so the guest wouldn't get what was checked here: $($stopNames -join ', '). build-lab stopped before any VM was built or changed. Clear the Hidden attribute (attrib -h <path>) on each file, and on any hidden folder that holds one, then run again."
    }
    if ($warningNames.Count -gt 0) {
        $result.Warning = "new-AdDomain holds hidden items the guest doesn't use, which the payload zip leaves out: $($warningNames -join ', '). The build goes on without them."
    }
    return $result
}

function ConvertTo-FullFileSystemPath {
    # Returns -Path as a full file system path with any '..' segments removed. A relative
    # path resolves against PowerShell's current location, as a native command would see
    # it, not the process directory. The path does not have to exist.
    param (
        [Parameter(Mandatory)]
        [string]$Path
    )
    return [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
}

function Confirm-BuildProfilePath {
    # Checks -ProfilePath and returns it as a full path. Throws with a descriptive message
    # when it names no file, names a folder, or is not a .psd1 (in any case).
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ProfilePath
    )
    if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
        throw "-ProfilePath '$ProfilePath' names no file. Pass the full path of an existing build profile (.psd1), or leave -ProfilePath out."
    }
    $fullProfilePath = ConvertTo-FullFileSystemPath -Path $ProfilePath
    if (-not (Test-Path -LiteralPath $fullProfilePath)) {
        throw "-ProfilePath '$fullProfilePath' names no file. Pass the full path of an existing build profile (.psd1), or leave -ProfilePath out."
    }
    if (Test-Path -LiteralPath $fullProfilePath -PathType Container) {
        throw "-ProfilePath '$fullProfilePath' names a folder, not a file. Pass the full path of a build profile (.psd1)."
    }
    if ([System.IO.Path]::GetExtension($fullProfilePath) -ne '.psd1') {
        throw "-ProfilePath '$fullProfilePath' is not a .psd1 file. A build profile is a PowerShell data file (.psd1), which build-lab and new-AdDomain read without running it."
    }
    return $fullProfilePath
}

function Set-StagedBuildProfile {
    # Decides which build profile the run uses and puts it in place in the staged copy:
    #   1. no -ProfilePath, no source profile:  no profile (INFO)
    #   2. no -ProfilePath, source profile:     the source profile (WARN, path and SHA-256),
    #                                           because a file nobody named on the command
    #                                           line then decides which forest is built
    #   3. -ProfilePath, no source profile, or -ProfilePath IS the source profile:
    #                                           -ProfilePath (INFO, path and SHA-256)
    #   4. -ProfilePath, a different source profile: -ProfilePath (WARN that the source
    #                                           profile was replaced, then the row 3 INFO)
    # Whether the source has a profile is read from the staged copy, which robocopy filled
    # from the source a moment earlier, so the decision and the staged file always agree.
    # The SHA-256 is the staged file's, the file the guest gets. Only the staged copy is
    # written; the source profile and -ProfilePath are never changed.
    #
    # The -ProfilePath copy goes to a temporary file beside the staged profile and replaces
    # it only when complete, and every file step stops on failure whatever the caller's
    # error preference. The staged file's SHA-256 must then equal the requested file's,
    # or the run stops. Only after that are the replaced and selected lines made, so a
    # copy that failed can never be reported as the profile in use.
    #
    # Returns { Row; ProfileInUse; OriginPath; StagedProfilePath; Sha256; LogEntries },
    # where LogEntries is the ordered list of { Level; Message } lines for the caller to log.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes only into the disposable per-run staging folder; -WhatIf support would not meaningfully apply.')]
    param (
        [Parameter(Mandatory)]
        [string]$StagedPayloadPath,
        # The source new-AdDomain's include\build-profile.psd1, as a full path. Used to name
        # it in the log and to recognize -ProfilePath pointing at it.
        [Parameter(Mandatory)]
        [string]$SourceProfilePath,
        # Full path, already checked by Confirm-BuildProfilePath.
        [string]$ProfilePath
    )
    $stagedProfilePath   = Join-Path -Path $StagedPayloadPath -ChildPath 'include\build-profile.psd1'
    $sourceProfileStaged = Test-Path -LiteralPath $stagedProfilePath -PathType Leaf
    $logEntries          = @()

    if (-not $ProfilePath) {
        if (-not $sourceProfileStaged) {
            $logEntries += [pscustomobject]@{ Level = 'INFO'; Message = "No build profile. -ProfilePath was not given and '$SourceProfilePath' does not exist, so the build uses the global-config.ps1 values." }
            return [pscustomobject]@{ Row = 1; ProfileInUse = $false; OriginPath = $null; StagedProfilePath = $null; Sha256 = $null; LogEntries = $logEntries }
        }
        $stagedProfileHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $stagedProfilePath -ErrorAction Stop).Hash
        $logEntries += [pscustomobject]@{ Level = 'WARN'; Message = "Source build profile used: '$SourceProfilePath' (SHA-256 $stagedProfileHash), staged for the guest as '$stagedProfilePath'. It was not named with -ProfilePath, yet it decides which forest is built. Pass a profile with -ProfilePath to choose one on purpose, or remove that file to build without one." }
        return [pscustomobject]@{ Row = 2; ProfileInUse = $true; OriginPath = $SourceProfilePath; StagedProfilePath = $stagedProfilePath; Sha256 = $stagedProfileHash; LogEntries = $logEntries }
    }

    # -eq on strings ignores case, as Windows paths do.
    $profilePathIsSourceProfile = $sourceProfileStaged -and ($ProfilePath -eq $SourceProfilePath)
    $row = if ($sourceProfileStaged -and -not $profilePathIsSourceProfile) { 4 } else { 3 }
    $temporaryProfilePath = "$stagedProfilePath.$PID.tmp"
    try {
        $requestedProfileHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ProfilePath -ErrorAction Stop).Hash
        Copy-Item -LiteralPath $ProfilePath -Destination $temporaryProfilePath -Force -ErrorAction Stop
        Move-Item -LiteralPath $temporaryProfilePath -Destination $stagedProfilePath -Force -ErrorAction Stop
        $stagedProfileHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $stagedProfilePath -ErrorAction Stop).Hash
    }
    catch {
        Remove-Item -LiteralPath $temporaryProfilePath -Force -ErrorAction SilentlyContinue
        throw "The build profile '$ProfilePath' could not be staged for the guest ($($_.Exception.Message)), so build-lab stopped before any VM was built or changed. Check that the file is still there and readable, and that nothing holds '$stagedProfilePath' open."
    }
    if ($stagedProfileHash -ne $requestedProfileHash) {
        throw "The build profile staged as '$stagedProfilePath' (SHA-256 $stagedProfileHash) is not the file -ProfilePath names, '$ProfilePath' (SHA-256 $requestedProfileHash). It changed while it was being copied, so build-lab stopped before any VM was built or changed. Run again once nothing is writing to it."
    }
    if ($row -eq 4) {
        $logEntries += [pscustomobject]@{ Level = 'WARN'; Message = "Source build profile replaced: '$SourceProfilePath' was overwritten in the staged payload by -ProfilePath. The guest gets the -ProfilePath file. Remove the source profile to stop this warning." }
    }
    $logEntries += [pscustomobject]@{ Level = 'INFO'; Message = "Build profile from -ProfilePath: '$ProfilePath' (SHA-256 $stagedProfileHash), staged for the guest as '$stagedProfilePath'." }
    return [pscustomobject]@{ Row = $row; ProfileInUse = $true; OriginPath = $ProfilePath; StagedProfilePath = $stagedProfilePath; Sha256 = $stagedProfileHash; LogEntries = $logEntries }
}

function ConvertTo-OriginProfilePathText {
    # new-AdDomain's validator names the profile by the path it read, which on the host is
    # the staged copy in a temp folder this run deletes. This puts the file the operator
    # passed (or the source profile) in its place, so each line names the file to edit.
    # The match is literal and ignores case. Without a staged path the text is unchanged.
    param (
        [AllowEmptyCollection()]
        [string[]]$Text = @(),
        [string]$StagedProfilePath,
        [string]$OriginPath
    )
    if (-not $StagedProfilePath -or -not $OriginPath) { return $Text }
    $stagedPathPattern = [regex]::Escape($StagedProfilePath)
    # In a replacement string '$' is special, so a '$' in the path is doubled.
    $originReplacement = $OriginPath.Replace('$', '$$')
    return @($Text | Where-Object { $null -ne $_ } | ForEach-Object { [regex]::Replace($_, $stagedPathPattern, $originReplacement, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) })
}

function New-AdDomainPayloadArchive {
    # Zips the staged new-AdDomain folder (Copy-AdDomainPayloadToStaging) for the DC. The
    # zip keeps the new-AdDomain root folder, which the guest expands into C:\temp.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal build step that zips the staged copy of new-AdDomain inside a disposable temp folder; -WhatIf support would not meaningfully apply.')]
    param (
        [Parameter(Mandatory)]
        [string]$StagedPayloadPath,
        [Parameter(Mandatory)]
        [string]$StagingRootPath
    )
    $payloadZipFilePath = Join-Path -Path $StagingRootPath -ChildPath 'new-AdDomain.zip'
    if (Test-Path -LiteralPath $payloadZipFilePath) {
        Remove-Item -LiteralPath $payloadZipFilePath -Force
    }
    Compress-Archive -Path $StagedPayloadPath -DestinationPath $payloadZipFilePath -Force

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
    # another script function by name (Test-GuestPathExists calls Invoke-NativeCommand) is
    # not reliably resolvable inside the closure.
    $invokeNativeCommand = ${function:Invoke-NativeCommand}

    $null = Invoke-CommandWithRetry -OperationName "createDirectoryInGuest $GuestTempPath" -ThrowOnFailure -ScriptBlock {
        $existsResult = & $invokeNativeCommand -FilePath $VmrunPath -RedactedTokens $redactedTokens -OperationName "directoryExistsInGuest $GuestTempPath" `
            -TimeoutSeconds 120 -AllowNonZeroExit `
            -ArgumentList @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText, 'directoryExistsInGuest', $VmxFilePath, $GuestTempPath)
        if ($existsResult.ExitCode -ne 0) {
            $null = & $invokeNativeCommand -FilePath $VmrunPath -RedactedTokens $redactedTokens -OperationName "createDirectoryInGuest $GuestTempPath" `
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

    # Capture Invoke-NativeCommand as a scriptblock *value* so it can be invoked by
    # reference (& $invokeNativeCommand) inside the .GetNewClosure() blocks below.
    # .GetNewClosure() reliably carries captured *variables* into the closure's session
    # state, but in some environments it does NOT carry sibling script-scope *function
    # names* -- calling Invoke-NativeCommand by name inside those closures fails with
    # "term ... is not recognized". Resolving the function to a variable
    # here (where it is in scope) sidesteps the name lookup entirely.
    $invokeNativeCommand = ${function:Invoke-NativeCommand}

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
            $null = & $invokeNativeCommand -FilePath $VmrunPath -RedactedTokens $redactedTokens -OperationName "remove existing $guestPayloadPath" `
                -ArgumentList @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText, 'runProgramInGuest', $VmxFilePath, $guestPowerShellExe,
                    '-NoProfile', '-Command', "if (Test-Path -LiteralPath '$guestPayloadPath') { Remove-Item -LiteralPath '$guestPayloadPath' -Recurse -Force }")
        }.GetNewClosure()
    }

    $null = Invoke-CommandWithRetry -OperationName 'copyFileFromHostToGuest new-AdDomain.zip' -ThrowOnFailure -ScriptBlock {
        $null = & $invokeNativeCommand -FilePath $VmrunPath -RedactedTokens $redactedTokens -OperationName 'copyFileFromHostToGuest new-AdDomain.zip' `
            -ArgumentList @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText, 'copyFileFromHostToGuest', $VmxFilePath, $PayloadZipFilePath, $guestZipFilePath)
    }.GetNewClosure()

    $null = Invoke-CommandWithRetry -OperationName 'Expand-Archive new-AdDomain.zip in guest' -ThrowOnFailure -ScriptBlock {
        $null = & $invokeNativeCommand -FilePath $VmrunPath -RedactedTokens $redactedTokens -OperationName 'Expand-Archive new-AdDomain.zip' `
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
        $null = & $invokeNativeCommand -FilePath $VmrunPath -RedactedTokens $redactedTokens -OperationName 'remove new-AdDomain.zip in guest' `
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
    # -CreateScheduledTask is passed only with build-lab's -DeferPopulation: the deployment then
    # registers the logon task that starts directory population. Without it, build-lab
    # starts population itself once promotion is verified (Invoke-GuestDirectoryPopulation).
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
        [string]$DefaultGateway,
        [switch]$CreateScheduledTask
    )
    $guestUserName          = $GuestCredential.UserName
    $guestPasswordPlainText = $GuestCredential.GetNetworkCredential().Password
    $logCommand         = Get-Command -Name Write-Log -CommandType Function -ErrorAction SilentlyContinue
    $guestPowerShellExe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $guestScriptPath    = 'C:\temp\new-AdDomain\New-ADForestDeployment.ps1'

    $guestScriptArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $guestScriptPath)
    if ($CreateScheduledTask) {
        $guestScriptArguments += @('-CreateScheduledTask')
    }
    $guestScriptArguments += @('-NonInteractive')
    if ($StaticIpAddress) {
        $guestScriptArguments += @('-StaticIpAddress', $StaticIpAddress, '-PrefixLength', $PrefixLength)
        if ($DefaultGateway) {
            $guestScriptArguments += @('-DefaultGateway', $DefaultGateway)
        }
    }

    $vmrunArgumentList = @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText,
        'runProgramInGuest', $VmxFilePath, '-noWait', $guestPowerShellExe) + $guestScriptArguments

    if ($logCommand) {
        $scheduledTaskText = if ($CreateScheduledTask) { 'with -CreateScheduledTask, so directory population waits for an Administrator logon' } else { 'without -CreateScheduledTask, so build-lab starts directory population itself after promotion' }
        Write-Log "Launching New-ADForestDeployment.ps1 in guest $scheduledTaskText (fire-and-forget via vmrun -noWait). It installs AD DS, promotes the forest, and reboots on success; completion is verified by polling for ntds.dit -- expect 5-15 minutes." -Level INFO
    }

    try {
        $null = Invoke-NativeCommand -FilePath $VmrunPath -RedactedTokens @($guestPasswordPlainText) `
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
        # The deployment was asked to register directory population's logon task
        # (-DeferPopulation), so a fatal line after promotion may mean the task is missing.
        [switch]$ScheduledTaskRequested,
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
            $scheduledTaskText = if ($ScheduledTaskRequested) { " Directory population's logon-triggered scheduled task may not have been registered; check Task Scheduler on the DC before relying on it." } else { '' }
            Write-Log "The DC rebooted after promotion, but its deployment log records a fatal error: $fatalLogLine$scheduledTaskText" -Level WARN
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

function New-GuestLogFolder {
    # Creates a new logs\guest-<timestamp>\ folder for one retrieval and returns its path. A
    # name already taken, by this run or another one in the same second, gets -2, -3 and so
    # on. New-Item without -Force refuses a folder that exists, so a name is never shared.
    param (
        [Parameter(Mandatory)]
        [string]$HostLogsRootPath
    )
    $folderTimestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    for ($folderSuffix = 1; $folderSuffix -le 100; $folderSuffix++) {
        $folderName = if ($folderSuffix -eq 1) { "guest-$folderTimestamp" } else { "guest-$folderTimestamp-$folderSuffix" }
        $folderPath = Join-Path -Path $HostLogsRootPath -ChildPath $folderName
        if (Test-Path -LiteralPath $folderPath) { continue }
        try {
            $null = New-Item -ItemType Directory -Path $folderPath -ErrorAction Stop
            return $folderPath
        }
        catch {
            # Another call took the name between the test and the create. Try the next one.
            if (-not (Test-Path -LiteralPath $folderPath)) { throw }
        }
    }
    throw "Could not create a new guest log folder under '$HostLogsRootPath': guest-$folderTimestamp and its next 99 names are all taken."
}

function Copy-GuestLogsToHost {
    # Retrieves the guest's C:\temp\new-AdDomain\logs into a host folder: zipped in the guest,
    # copied to a transfer zip in the host logs folder, expanded, and both zips removed. The
    # host transfer zip has a name of its own for every call, so two runs sharing the logs
    # folder can never expand or delete each other's, and the default destination is a new
    # folder (New-GuestLogFolder). Best effort: a failure is one WARN and $null.
    param (
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [string]$VmxFilePath,
        [Parameter(Mandatory)]
        [PSCredential]$GuestCredential,
        [Parameter(Mandatory)]
        [string]$HostLogsRootPath,
        # The folder to expand the logs into. Default: a new logs\guest-<timestamp>\. Directory
        # population's retrieval passes its own, so its logs and results share one folder.
        [string]$HostDestinationPath
    )
    $guestUserName          = $GuestCredential.UserName
    $guestPasswordPlainText = $GuestCredential.GetNetworkCredential().Password
    $logCommand          = Get-Command -Name Write-Log -CommandType Function -ErrorAction SilentlyContinue
    $redactedTokens      = @($guestPasswordPlainText)
    $guestPowerShellExe  = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $guestLogsSourcePath = 'C:\temp\new-AdDomain\logs'
    $guestLogsZipPath    = 'C:\temp\adDeploymentLogs.zip'
    $hostLogsZipPath     = Join-Path -Path $HostLogsRootPath -ChildPath ('adDeploymentLogs-' + [guid]::NewGuid().ToString('N') + '.zip')
    $hostDestinationPath = $HostDestinationPath

    try {
        if (-not $hostDestinationPath) {
            $hostDestinationPath = New-GuestLogFolder -HostLogsRootPath $HostLogsRootPath
        }
        $null = Invoke-NativeCommand -FilePath $VmrunPath -RedactedTokens $redactedTokens -OperationName 'Compress-Archive guest deployment logs' `
            -ArgumentList @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText, 'runProgramInGuest', $VmxFilePath, $guestPowerShellExe,
                '-NoProfile', '-Command', "Compress-Archive -LiteralPath '$guestLogsSourcePath' -DestinationPath '$guestLogsZipPath' -Force")

        $null = Invoke-NativeCommand -FilePath $VmrunPath -RedactedTokens $redactedTokens -OperationName 'copyFileFromGuestToHost deployment logs' `
            -ArgumentList @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText, 'copyFileFromGuestToHost', $VmxFilePath, $guestLogsZipPath, $hostLogsZipPath)

        Expand-Archive -LiteralPath $hostLogsZipPath -DestinationPath $hostDestinationPath -Force

        # The guest zip is only a transfer copy. Removing it is best effort: the logs are
        # already on the host, so a failure here is not a retrieval failure.
        try {
            $null = Invoke-NativeCommand -FilePath $VmrunPath -RedactedTokens $redactedTokens -OperationName 'remove guest deployment log zip' `
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
        # Covers both paths: after a successful expand, and after a failed expand that would
        # otherwise leave this call's transfer zip in the host logs folder. Only this call's.
        Remove-Item -LiteralPath $hostLogsZipPath -Force -ErrorAction SilentlyContinue
    }
}

function Wait-GuestDirectoryReady {
    # Polls the DC after promotion until its directory answers Get-ADDomain with the
    # expected domain, so directory population isn't started before AD can serve it. The
    # loop is the retry, as in the promotion poll, so the guest command runs without
    # -Retry and with a short per-call bound. A failed attempt (a transport error, a guest
    # error, or another domain) is logged at DEBUG and the poll goes on. -TimeoutMinutes is
    # checked between attempts, so the last attempt can end up to its bound after it.
    # Throws on the timeout, naming the last problem seen.
    param (
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [string]$VmxFilePath,
        [Parameter(Mandatory)]
        [PSCredential]$GuestCredential,
        [Parameter(Mandatory)]
        [string]$ExpectedDomainName,
        [Parameter(Mandatory)]
        [string]$HostStagingPath,
        [Parameter(Mandatory)]
        [int]$TimeoutMinutes,
        [int]$PollIntervalSeconds = 30,
        [int]$ProbeTimeoutSeconds = 120
    )
    $logCommand     = Get-Command -Name Write-Log -CommandType Function -ErrorAction SilentlyContinue
    $readyDeadline  = (Get-Date).AddMinutes($TimeoutMinutes)
    $lastProblem    = 'not yet probed'
    $directoryQuery = 'Import-Module -Name ActiveDirectory -ErrorAction Stop; [pscustomobject]@{ DNSRoot = [string](Get-ADDomain).DNSRoot }'
    while ($true) {
        try {
            $directoryAnswer = Invoke-GuestPowerShellCommand -VmrunPath $VmrunPath -VmxFilePath $VmxFilePath -GuestCredential $GuestCredential `
                -OperationName 'Get-ADDomain (directory ready)' -GuestCommand $directoryQuery -HostStagingPath $HostStagingPath -VmrunTimeoutSeconds $ProbeTimeoutSeconds
            $answeredDomain = ''
            if ($null -ne $directoryAnswer -and $directoryAnswer.PSObject.Properties.Name -contains 'DNSRoot') { $answeredDomain = [string]$directoryAnswer.DNSRoot }
            # -eq on strings ignores case, as DNS names do.
            if ($answeredDomain -and $answeredDomain -eq $ExpectedDomainName) {
                if ($logCommand) {
                    Write-Log "The DC's directory answers Get-ADDomain for '$ExpectedDomainName'." -Level SUCCESS
                }
                return
            }
            $lastProblem = "Get-ADDomain answered with domain '$answeredDomain', not '$ExpectedDomainName'"
        }
        catch {
            $lastProblem = $_.Exception.Message
        }
        if ($logCommand) {
            Write-Log "Directory not ready yet: $lastProblem" -Level DEBUG
        }
        if ((Get-Date) -ge $readyDeadline) { break }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
    throw "The DC's directory did not answer Get-ADDomain for '$ExpectedDomainName' within $TimeoutMinutes minute(s) of the promotion being verified, so directory population was not started and no member servers were built. Last problem: $lastProblem"
}

function Invoke-GuestDirectoryPopulation {
    # Starts Initialize-ADDirectory.ps1 in the guest FIRE-AND-FORGET (vmrun runProgramInGuest
    # -noWait), as Invoke-GuestAdForestDeployment starts the deployment, with the arguments
    # New-ADForestDeployment.ps1's logon task uses plus -LaunchId. The launch ID is echoed
    # into the guest's completion marker, which Test-GuestDirectoryPopulation polls, so a
    # marker left by another run is never taken for this one. No population setting is passed:
    # the guest reads the staged build profile and override file, the files this run checked.
    # A guest program outlives the vmrun call that started it, so nothing here waits for it.
    #
    # Returns the launch error message if vmrun reported one, otherwise $null.
    param (
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [string]$VmxFilePath,
        [Parameter(Mandatory)]
        [PSCredential]$GuestCredential,
        [Parameter(Mandatory)]
        [string]$LaunchId
    )
    $guestUserName          = $GuestCredential.UserName
    $guestPasswordPlainText = $GuestCredential.GetNetworkCredential().Password
    $logCommand         = Get-Command -Name Write-Log -CommandType Function -ErrorAction SilentlyContinue
    $guestPowerShellExe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $guestScriptPath    = 'C:\temp\new-AdDomain\Initialize-ADDirectory.ps1'

    $guestScriptArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NonInteractive', '-File', $guestScriptPath, '-LaunchId', $LaunchId)
    $vmrunArgumentList = @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText,
        'runProgramInGuest', $VmxFilePath, '-noWait', $guestPowerShellExe) + $guestScriptArguments

    if ($logCommand) {
        Write-Log "Launching Initialize-ADDirectory.ps1 -LaunchId $LaunchId in the guest (fire-and-forget via vmrun -noWait). It creates the OUs, users, groups, CA and GPOs. Completion is read from its marker, C:\temp\new-AdDomain\artifacts\population-result.json." -Level INFO
    }
    try {
        $null = Invoke-NativeCommand -FilePath $VmrunPath -RedactedTokens @($guestPasswordPlainText) `
            -OperationName 'Initialize-ADDirectory.ps1 (-noWait)' -ArgumentList $vmrunArgumentList
        return $null
    }
    catch {
        # -noWait only reports a launch failure. The marker poll then ends as NeverStarted,
        # and its message names this error.
        $launchErrorMessage = $_.Exception.Message
        if ($logCommand) {
            Write-Log "vmrun reported an error launching Initialize-ADDirectory.ps1: $launchErrorMessage Continuing to the completion marker." -Level WARN
        }
        return $launchErrorMessage
    }
}

function Test-GuestDirectoryPopulation {
    # Polls the guest's completion marker, C:\temp\new-AdDomain\artifacts\population-result.json,
    # for the launch Invoke-GuestDirectoryPopulation made. Initialize-ADDirectory.ps1 writes
    # it once when it starts (State Running) and again when it ends (Succeeded or Failed),
    # each time through a temporary file and a rename. A marker that is missing, can't be
    # copied, can't be parsed, or holds another LaunchId counts as not yet written.
    #
    # Two deadlines, both from the launch and both checked between polls, so the last poll
    # can end up to its bounds after them:
    #   - the launch has to be shown to have started within -StartTimeoutMinutes. A marker
    #     for this LaunchId in any state shows it, a terminal one read first included
    #   - it has to reach Succeeded or Failed within -PopulationTimeoutMinutes
    # Every poll uses short per-call bounds and no retry, since the loop is the retry.
    #
    # Returns { Outcome; Marker; LaunchError; Reason } and never throws. Outcome is
    # Succeeded, Failed, NeverStarted or TimedOut. Marker is the terminal marker for this
    # launch, or $null. Reason is the text for NeverStarted and TimedOut, or $null.
    param (
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [string]$VmxFilePath,
        [Parameter(Mandatory)]
        [PSCredential]$GuestCredential,
        [Parameter(Mandatory)]
        [string]$LaunchId,
        [Parameter(Mandatory)]
        [string]$HostStagingPath,
        [Parameter(Mandatory)]
        [int]$StartTimeoutMinutes,
        [Parameter(Mandatory)]
        [int]$PopulationTimeoutMinutes,
        [string]$LaunchErrorMessage,
        [int]$PollIntervalSeconds = 60,
        [int]$ProbeTimeoutSeconds = 120
    )
    $logCommand       = Get-Command -Name Write-Log -CommandType Function -ErrorAction SilentlyContinue
    $markerGuestPath  = 'C:\temp\new-AdDomain\artifacts\population-result.json'
    $launchTime       = Get-Date
    $startDeadline    = $launchTime.AddMinutes($StartTimeoutMinutes)
    $finishDeadline   = $launchTime.AddMinutes($PopulationTimeoutMinutes)
    $launchStarted    = $false
    $lastProblem      = 'no marker read yet'
    $result = [pscustomobject]@{ Outcome = $null; Marker = $null; LaunchError = $(if ($LaunchErrorMessage) { $LaunchErrorMessage } else { $null }); Reason = $null }

    if ($logCommand) {
        Write-Log "Polling for directory population's completion marker for launch '$LaunchId' (start within $StartTimeoutMinutes minute(s), finish within $PopulationTimeoutMinutes minute(s))..." -Level INFO
    }
    while ($true) {
        $marker = $null
        try {
            if (Test-GuestPathExists -VmrunPath $VmrunPath -VmxFilePath $VmxFilePath -GuestCredential $GuestCredential -PathType File `
                    -GuestPath $markerGuestPath -TimeoutSeconds $ProbeTimeoutSeconds) {
                $markerText = Get-GuestTextFileContent -VmrunPath $VmrunPath -VmxFilePath $VmxFilePath -GuestCredential $GuestCredential `
                    -GuestFilePath $markerGuestPath -HostStagingPath $HostStagingPath -VmrunTimeoutSeconds $ProbeTimeoutSeconds
                try {
                    if (-not [string]::IsNullOrWhiteSpace($markerText)) { $marker = $markerText | ConvertFrom-Json -ErrorAction Stop }
                    if ($null -eq $marker) { $lastProblem = 'the marker is empty' }
                }
                catch {
                    $marker = $null
                    $lastProblem = 'the marker could not be parsed'
                }
            }
            else {
                $lastProblem = 'no marker yet'
            }
        }
        catch {
            $lastProblem = "the marker could not be read: $($_.Exception.Message)"
        }

        if ($null -ne $marker) {
            $markerProperties = @($marker.PSObject.Properties.Name)
            $markerLaunchId = if ($markerProperties -contains 'LaunchId') { [string]$marker.LaunchId } else { '' }
            if ($markerLaunchId -cne $LaunchId) {
                $lastProblem = "the marker is for launch '$markerLaunchId', not this one"
                $marker = $null
            }
        }
        if ($null -ne $marker) {
            $launchStarted = $true
            $markerState = if ($markerProperties -contains 'State') { [string]$marker.State } else { '' }
            if ($markerState -ceq 'Succeeded' -or $markerState -ceq 'Failed') {
                $result.Outcome = $markerState
                $result.Marker  = $marker
                return $result
            }
            $lastProblem = "State $markerState"
        }

        $pollTime = Get-Date
        if (-not $launchStarted -and ($pollTime -ge $startDeadline -or $pollTime -ge $finishDeadline)) {
            $result.Outcome = 'NeverStarted'
            $startedWithinMinutes = [math]::Min($StartTimeoutMinutes, $PopulationTimeoutMinutes)
            $result.Reason = "Directory population never started in the guest: no completion marker for launch '$LaunchId' appeared within $startedWithinMinutes minute(s) ($lastProblem)."
            if ($LaunchErrorMessage) { $result.Reason += " The launch reported an error: $LaunchErrorMessage" }
            return $result
        }
        if ($pollTime -ge $finishDeadline) {
            $result.Outcome = 'TimedOut'
            $result.Reason = "Directory population did not finish within $PopulationTimeoutMinutes minute(s) (last marker: $lastProblem). It may still be running in the guest, because ending the wait doesn't stop it. Raise -PopulationTimeoutMinutes if the guest is slow."
            return $result
        }
        if ($logCommand) {
            $minutesRemaining = [math]::Round(($finishDeadline - $pollTime).TotalMinutes, 1)
            Write-Log "Directory population not finished yet ($lastProblem). $minutesRemaining minute(s) remaining." -Level INFO
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

function Copy-GuestPopulationResultToHost {
    # Retrieves directory population's results into one new logs\guest-<timestamp>\ folder:
    # the guest's logs folder (through Copy-GuestLogsToHost), then, under its artifacts
    # subfolder, the completion marker and each file the terminal marker lists in
    # ArtifactFiles. Best effort, for every outcome: a copy that fails is one WARN. The
    # names come from a file the guest wrote, so only a bare file name is copied, and never
    # a users export, which holds every generated password. The marker never lists it, so
    # a users-* name means a marker that can't be trusted, and it is skipped too.
    #
    # Returns { Path; Copied; Skipped }. Path is the folder, or $null if it couldn't be made.
    param (
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [string]$VmxFilePath,
        [Parameter(Mandatory)]
        [PSCredential]$GuestCredential,
        [Parameter(Mandatory)]
        [string]$HostLogsRootPath,
        [AllowNull()]
        [object]$Marker
    )
    $guestUserName          = $GuestCredential.UserName
    $guestPasswordPlainText = $GuestCredential.GetNetworkCredential().Password
    $logCommand        = Get-Command -Name Write-Log -CommandType Function -ErrorAction SilentlyContinue
    $guestArtifactPath = 'C:\temp\new-AdDomain\artifacts'
    $result = [pscustomobject]@{ Path = $null; Copied = @(); Skipped = @() }

    $destinationPath = $null
    $artifactDestinationPath = $null
    try {
        $destinationPath = New-GuestLogFolder -HostLogsRootPath $HostLogsRootPath
        $artifactDestinationPath = Join-Path -Path $destinationPath -ChildPath 'artifacts'
        $null = New-Item -ItemType Directory -Path $artifactDestinationPath -Force -ErrorAction Stop
    }
    catch {
        if ($logCommand) {
            Write-Log "Could not create a folder under '$HostLogsRootPath' for directory population's results: $($_.Exception.Message)" -Level WARN
        }
        return $result
    }
    $result.Path = $destinationPath
    $null = Copy-GuestLogsToHost -VmrunPath $VmrunPath -VmxFilePath $VmxFilePath -GuestCredential $GuestCredential -HostLogsRootPath $HostLogsRootPath `
        -HostDestinationPath $destinationPath

    $artifactNames = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $artifactNames.Add('population-result.json')
    $skippedNames = New-Object -TypeName 'System.Collections.Generic.List[string]'
    if ($null -ne $Marker -and @($Marker.PSObject.Properties.Name) -contains 'ArtifactFiles') {
        foreach ($artifactName in @($Marker.ArtifactFiles | Where-Object { $null -ne $_ })) {
            $artifactNameText = [string]$artifactName
            if ($artifactNameText -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._-]*\z' -or $artifactNameText -like 'users-*') {
                $skippedNames.Add($artifactNameText)
                continue
            }
            if ($artifactNames -notcontains $artifactNameText) { $artifactNames.Add($artifactNameText) }
        }
    }
    if ($skippedNames.Count -gt 0 -and $logCommand) {
        Write-Log "The population marker lists files that aren't copied, because each is not a plain file name or is a users export: $(@($skippedNames | ForEach-Object { "'$_'" }) -join ', ')." -Level WARN
    }

    $copiedNames = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($artifactNameText in $artifactNames) {
        $guestFilePath = "$guestArtifactPath\$artifactNameText"
        $hostFilePath  = Join-Path -Path $artifactDestinationPath -ChildPath $artifactNameText
        try {
            $null = Invoke-NativeCommand -FilePath $VmrunPath -RedactedTokens @($guestPasswordPlainText) -OperationName "copyFileFromGuestToHost $guestFilePath" `
                -ArgumentList @('-T', 'ws', '-gu', $guestUserName, '-gp', $guestPasswordPlainText, 'copyFileFromGuestToHost', $VmxFilePath, $guestFilePath, $hostFilePath)
            $copiedNames.Add($artifactNameText)
        }
        catch {
            if ($logCommand) {
                Write-Log "Could not retrieve '$guestFilePath' from the guest: $($_.Exception.Message)" -Level WARN
            }
        }
    }
    $result.Copied  = $copiedNames.ToArray()
    $result.Skipped = $skippedNames.ToArray()
    return $result
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
    # Reads the domain identity and the build profile results from the STAGED copy of
    # new-AdDomain's global-config.ps1 (Copy-AdDomainPayloadToStaging), the same files the
    # guest gets. global-config.ps1 loads include\BuildProfile.ps1, applies the build
    # profile in its folder over its own values, validates the result, and leaves the
    # effective values plus $buildProfileSummary, $buildProfileInfo, $buildProfileWarnings
    # and $buildProfileError behind. It never throws for a profile problem. A later
    # -AddMemberServers or -MoveMemberServers run reads its own staged copy, so if the
    # configuration changed in between, the values no longer match the existing DC. Those
    # two modes therefore cross-check the domain against the DC itself
    # (Compare-DomainControllerIdentity) before acting on it.
    #
    # The file is a .ps1, so reading it means dot-sourcing (executing) it. That happens
    # inside this function so the config's variables and the functions it loads land in
    # function scope and are discarded on return, rather than overwriting same-named
    # variables in this script (global-config.ps1 defines $logPath, for one). Every variable
    # read below is set to $null first, so a value the file does not set can never be read
    # from a caller's scope. The guest scripts load the same file under
    # $ErrorActionPreference = 'Stop', so this function does too, to make the host's
    # check behave like the guest's. Any output the file writes is discarded, so it cannot
    # turn the return value into an array.
    #
    # Checks, in order: with -RequiredGlobalConfigVersion, the file's $globalConfigVersion
    # (throws, because an older global-config.ps1 explains every check below it), a build
    # profile or override file error (returned for the caller to log, ahead of the check
    # below, which it would otherwise mask, because the derived values are not set after
    # an error), a new-AdDomain without build profile support (throws), the identity
    # values (throws), then the service account SPN checks on the CSV the guest will read:
    # the override file's replacement serviceaccounts.csv when there is one, otherwise
    # config\serviceaccounts.csv.
    #
    # Returns { DomainName; NetBIOSName; DomainDN; ServersOU; PrimarySubnet;
    # DomainNameSource; GlobalConfigVersion; Summary; Info; Warnings; Error; PairWarnings;
    # PairError; ServiceAccountCsvPath; PlaceholderRows; OtherDomainRows; Population;
    # DomainAdminCount; PopulationSeed; PopulationSource; NetworkType }. Info, Warnings,
    # PairWarnings and both row lists are arrays. NetworkType is the build profile's, in its
    # canonical spelling, and $null when the profile leaves it out or empty, when there is
    # no profile, after an error, or from a new-AdDomain that doesn't know the key. Error
    # and PairError are $null or the error text, which may hold several lines.
    # DomainNameSource is new-AdDomain's
    # (Profile, OverrideFile, GlobalConfigEdited or Shipped), returned as data because the
    # BuildProfile.ps1 function that worked it out is gone once this function returns.
    param (
        [Parameter(Mandatory)]
        [string]$GlobalConfigPath,
        # The source new-AdDomain, named when it has no build profile support. Default:
        # the folder two levels above -GlobalConfigPath.
        [string]$AdDomainSourcePath,
        # The oldest $globalConfigVersion new-AdDomain's scripts run with
        # (Get-RequiredGlobalConfigVersion). Not checked when it is not given.
        [string]$RequiredGlobalConfigVersion
    )
    if (-not (Test-Path -LiteralPath $GlobalConfigPath -PathType Leaf)) {
        throw "Domain configuration not found at '$GlobalConfigPath'. Member servers take the domain name from new-AdDomain\include\global-config.ps1. Pass -AdDomainSourcePath if new-AdDomain is not a sibling of this project."
    }
    if (-not $AdDomainSourcePath) {
        $AdDomainSourcePath = Split-Path -Path (Split-Path -Path $GlobalConfigPath -Parent) -Parent
    }

    $ErrorActionPreference = 'Stop'
    $domainName               = $null
    $netBIOSName              = $null
    $domainDN                 = $null
    $serversOU                = $null
    $primarySubnet            = $null
    $csvPath                  = $null
    $globalConfigVersion      = $null
    $buildProfileSummary      = $null
    $buildProfileInfo         = $null
    $buildProfileWarnings     = $null
    $buildProfileError        = $null
    $buildProfileDomainSource = $null
    $overrideFileCsvPaths     = $null
    $overrideFilePairWarnings = $null
    $overrideFilePairError    = $null
    $buildProfilePopulation   = $null
    $buildProfileNetworkType  = $null
    $null = . $GlobalConfigPath

    if ($RequiredGlobalConfigVersion) {
        $globalConfigVersionStop = Test-GlobalConfigVersionRequirement -FoundVersion $globalConfigVersion -RequiredVersion $RequiredGlobalConfigVersion `
            -GlobalConfigPath (Join-Path -Path $AdDomainSourcePath -ChildPath 'include\global-config.ps1')
        if ($globalConfigVersionStop) {
            throw $globalConfigVersionStop
        }
    }

    $domainIdentity = [pscustomobject]@{
        DomainName            = $domainName
        NetBIOSName           = $netBIOSName
        DomainDN              = $domainDN
        ServersOU             = $serversOU
        PrimarySubnet         = $primarySubnet
        DomainNameSource      = $(if ($buildProfileDomainSource) { [string]$buildProfileDomainSource } else { $null })
        GlobalConfigVersion   = $(if ($globalConfigVersion) { [string]$globalConfigVersion } else { $null })
        Summary               = $buildProfileSummary
        Info                  = @($buildProfileInfo | Where-Object { $null -ne $_ })
        Warnings              = @($buildProfileWarnings | Where-Object { $null -ne $_ })
        Error                 = $(if ($buildProfileError) { [string]$buildProfileError } else { $null })
        PairWarnings          = @($overrideFilePairWarnings | Where-Object { $null -ne $_ })
        PairError             = $(if ($overrideFilePairError) { [string]$overrideFilePairError } else { $null })
        ServiceAccountCsvPath = $null
        PlaceholderRows       = @()
        OtherDomainRows       = @()
        Population            = $null
        DomainAdminCount      = $null
        PopulationSeed        = $null
        PopulationSource      = $null
        NetworkType           = $(if ($buildProfileNetworkType -and -not $buildProfileError) { [string]$buildProfileNetworkType } else { $null })
    }
    # The population settings as new-AdDomain merged them (profile, override file, default),
    # $null from a new-AdDomain that has none or on any error.
    if ($null -ne $buildProfilePopulation) {
        foreach ($populationFieldName in @('Population', 'DomainAdminCount', 'PopulationSeed', 'PopulationSource')) {
            if (@($buildProfilePopulation.PSObject.Properties.Name) -contains $populationFieldName) {
                $domainIdentity.$populationFieldName = $buildProfilePopulation.$populationFieldName
            }
        }
    }
    if ($domainIdentity.Error) {
        return $domainIdentity
    }
    if (-not (Get-Command -Name 'Test-ServicePrincipalNamePlaceholder' -CommandType Function -ErrorAction SilentlyContinue)) {
        throw "'$AdDomainSourcePath' is a new-AdDomain without build profile support: include\global-config.ps1 did not load include\BuildProfile.ps1. This version of build-lab needs a new-AdDomain that has it. Update new-AdDomain, or point -AdDomainSourcePath at one that has it."
    }
    if (-not $domainName -or -not $netBIOSName -or -not $domainDN -or -not $serversOU -or -not $csvPath) {
        throw "'$GlobalConfigPath' did not define all of `$domainName, `$netBIOSName, `$domainDN, `$serversOU and `$csvPath. Check the Domain Identity, OU Structure and File Paths regions of that file."
    }
    $serviceAccountCsvPath = Join-Path -Path $csvPath -ChildPath 'serviceaccounts.csv'
    if ($overrideFileCsvPaths -is [System.Collections.IDictionary] -and $overrideFileCsvPaths.Contains('serviceaccounts.csv')) {
        $serviceAccountCsvPath = [string]$overrideFileCsvPaths['serviceaccounts.csv']
    }
    $domainIdentity.ServiceAccountCsvPath = $serviceAccountCsvPath
    $domainIdentity.PlaceholderRows = @(Test-ServicePrincipalNamePlaceholder -CsvPath $serviceAccountCsvPath -DomainName $domainName | Where-Object { $null -ne $_ })
    if (Get-Command -Name 'Test-ServicePrincipalNameDomain' -CommandType Function -ErrorAction SilentlyContinue) {
        $domainIdentity.OtherDomainRows = @(Test-ServicePrincipalNameDomain -CsvPath $serviceAccountCsvPath -DomainName $domainName | Where-Object { $null -ne $_ })
    }
    return $domainIdentity
}

function Test-AdDomainPopulationSupport {
    # Checks, without running it, that the staged Initialize-ADDirectory.ps1 can be started
    # by build-lab and report back: it parses the script and looks for a LaunchId parameter.
    # A new-AdDomain without one can't write the completion marker build-lab waits for.
    # Returns $null when the parameter is there, otherwise the stop text. A script that is
    # missing or doesn't parse counts as one without it, and the text says which.
    param (
        [Parameter(Mandatory)]
        [string]$ScriptPath,
        [Parameter(Mandatory)]
        [string]$SourcePath
    )
    $missingReason = $null
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        $missingReason = 'Initialize-ADDirectory.ps1 is missing'
    }
    else {
        $parseErrors = $null
        $scriptAst   = $null
        try {
            $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$parseErrors)
        }
        catch {
            $missingReason = "Initialize-ADDirectory.ps1 can't be read ($($_.Exception.GetType().FullName))"
        }
        if (-not $missingReason -and @($parseErrors).Count -gt 0) {
            $missingReason = "Initialize-ADDirectory.ps1 doesn't parse (line $(@($parseErrors)[0].Extent.StartLineNumber))"
        }
        elseif (-not $missingReason) {
            $launchIdParameters = @()
            if ($null -ne $scriptAst.ParamBlock) {
                $launchIdParameters = @($scriptAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'LaunchId' })
            }
            if ($launchIdParameters.Count -gt 0) { return $null }
            $missingReason = 'Initialize-ADDirectory.ps1 has no -LaunchId'
        }
    }
    return "'$SourcePath' is a new-AdDomain that can't report directory population back to build-lab ($missingReason). Update new-AdDomain, or pass -DeferPopulation to use the logon task."
}

function ConvertTo-PopulationSettingsText {
    # The host's "Population settings:" line, in the form the guest's own line takes: one
    # source in brackets when every value came from the same place, otherwise each value's
    # source after it. The values and their sources (Profile, OverrideFile or Default per
    # key) are new-AdDomain's merge, read from the staged copy by Get-AdDomainIdentity.
    param (
        [Parameter(Mandatory)]
        [object]$Settings,
        [Parameter(Mandatory)]
        [string]$ProfileText,
        [Parameter(Mandatory)]
        [string]$OverrideText
    )
    $sourceOf = @{}
    foreach ($settingName in @('Population', 'DomainAdminCount', 'PopulationSeed')) {
        $sourceName = 'Default'
        if ($Settings.PopulationSource -is [System.Collections.IDictionary] -and $Settings.PopulationSource.Contains($settingName)) {
            $sourceName = [string]$Settings.PopulationSource[$settingName]
        }
        $sourceOf[$settingName] = $sourceName
    }
    $settingParts = @(
        @('Population', [string]$Settings.Population),
        @('DomainAdminCount', [string]$Settings.DomainAdminCount),
        @('PopulationSeed', [string]$Settings.PopulationSeed))
    $distinctSources = @($sourceOf.Values | Select-Object -Unique)
    if ($distinctSources.Count -eq 1) {
        $commonText = switch ($distinctSources[0]) {
            'Profile'      { "(from $ProfileText)" }
            'OverrideFile' { "(from $OverrideText)" }
            default        { '(Initialize-ADDirectory.ps1 defaults)' }
        }
        return "Population settings: $(@($settingParts | ForEach-Object { "$($_[0])=$($_[1])" }) -join ', ') $commonText"
    }
    $shortSource = @{ Profile = $ProfileText; OverrideFile = $OverrideText; Default = 'default' }
    return "Population settings: $(@($settingParts | ForEach-Object { "$($_[0])=$($_[1]) ($($shortSource[$sourceOf[$_[0]]]))" }) -join ', ')"
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

function Test-IpAddressInSubnet {
    # Returns $true when -IpAddress lies inside -Subnet (IPv4 CIDR, a.b.c.d/n), the same
    # containment rule the guest applies to an explicit PrimarySubnet. Used for the early
    # address check. Throws on a subnet that is not CIDR: new-AdDomain's validator refuses
    # a malformed PrimarySubnet before this runs, so a throw here means that check failed.
    param (
        [Parameter(Mandatory)]
        [string]$IpAddress,
        [Parameter(Mandatory)]
        [string]$Subnet
    )
    $subnetMatch = [regex]::Match($Subnet, '^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})$')
    if (-not $subnetMatch.Success -or [int]$subnetMatch.Groups[2].Value -gt 32) {
        throw "Subnet '$Subnet' is not an IPv4 subnet in CIDR form (a.b.c.d/n)."
    }
    $prefixLength = [int]$subnetMatch.Groups[2].Value
    $maskNumber   = if ($prefixLength -eq 0) { [long]0 } else { ([long]4294967295 -shl (32 - $prefixLength)) -band [long]4294967295 }
    $subnetNumber = ConvertTo-IpAddressNumber -IpAddress $subnetMatch.Groups[1].Value
    $addressNumber = ConvertTo-IpAddressNumber -IpAddress $IpAddress
    return (($addressNumber -band $maskNumber) -eq ($subnetNumber -band $maskNumber))
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

function Get-GatewayProblem {
    # Why a default gateway can't serve the DC's subnet, as a phrase for a stop text, or
    # $null when it can: outside the subnet, the DC's own address, or the subnet's network
    # or broadcast address. The same rules Confirm-DomainControllerAddress applies to
    # -DefaultGateway, for a gateway that came from somewhere else.
    param (
        [Parameter(Mandatory)]
        [string]$IpAddress,
        [Parameter(Mandatory)]
        [string]$SubnetMask,
        [Parameter(Mandatory)]
        [string]$Gateway
    )
    $addressNumber          = ConvertTo-IpAddressNumber -IpAddress $IpAddress
    $subnetMaskNumber       = ConvertTo-IpAddressNumber -IpAddress $SubnetMask
    $networkAddressNumber   = $addressNumber -band $subnetMaskNumber
    $broadcastAddressNumber = $networkAddressNumber + ([long]4294967295 - $subnetMaskNumber)
    $gatewayNumber          = ConvertTo-IpAddressNumber -IpAddress $Gateway
    if (($gatewayNumber -band $subnetMaskNumber) -ne $networkAddressNumber) { return "it is outside the DC's subnet ($IpAddress / $SubnetMask), so no VM could reach it" }
    if ($gatewayNumber -eq $addressNumber) { return "it is the DC's own address, $IpAddress" }
    if ($gatewayNumber -eq $networkAddressNumber -or $gatewayNumber -eq $broadcastAddressNumber) { return "it is the network or broadcast address of the DC's subnet ($IpAddress / $SubnetMask)" }
    return $null
}

function Get-VmBuilderOverrideGateway {
    # The default gateway New-VMwareWorkstationVM gives a VM when build-lab passes it none:
    # the DefaultGateway in the builder's own override file, read the way the builder reads
    # it, through the shared reader and the builder's catalog, with nothing bound. Runs
    # nothing. Returns { Gateway; OverrideFilePath; Problem }: Gateway is $null when the
    # builder has no override file or the file sets no DefaultGateway, and Problem says why
    # the file couldn't be read, when it couldn't.
    param (
        [Parameter(Mandatory)]
        [string]$VmBuilderScriptPath
    )
    $builderFolder = Split-Path -Path $VmBuilderScriptPath -Parent
    $result = [pscustomobject]@{ Gateway = $null; OverrideFilePath = (Join-Path -Path $builderFolder -ChildPath 'overrides\overrides.psd1'); Problem = $null }
    if (-not (Test-Path -LiteralPath $result.OverrideFilePath -PathType Leaf)) {
        return $result
    }
    $builderCatalogPath = Join-Path -Path $builderFolder -ChildPath 'include\override-catalog.psd1'
    if (-not (Test-Path -LiteralPath $builderCatalogPath -PathType Leaf)) {
        $result.Problem = "the VM builder has no catalog at '$builderCatalogPath' to read it with"
        return $result
    }
    $builderOverrideFile = Get-OverrideFile -Path $result.OverrideFilePath -CatalogPath $builderCatalogPath
    if ($builderOverrideFile.Error) {
        $result.Problem = ($builderOverrideFile.Error -split '\r?\n')[0]
        return $result
    }
    $builderAssignments = Get-OverrideParameterAssignment -OverrideFile $builderOverrideFile -CatalogPath $builderCatalogPath -BoundParameters @{}
    if ($builderAssignments.Error) {
        $result.Problem = ($builderAssignments.Error -split '\r?\n')[0]
        return $result
    }
    $gatewayAssignment = @($builderAssignments.Assignments | Where-Object { $_.ParameterName -eq 'DefaultGateway' }) | Select-Object -First 1
    if ($null -ne $gatewayAssignment -and [string]$gatewayAssignment.Value) {
        $result.Gateway = [string]$gatewayAssignment.Value
    }
    return $result
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
            throw "$memberLabel would be $memberIpAddress, which is the VMs' default gateway. Choose a -StaticIpAddress for the DC whose member range does not cover the gateway."
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

function ConvertTo-CanonicalNetworkType {
    # Turns a -NetworkType value into its canonical form: nat, bridged, hostonly, or
    # VMnet<N> (0 to 99, no leading zero), matched without regard to case. VMnet0, VMnet1
    # and VMnet8 are networks the VM builder already names, so they become bridged,
    # hostonly and nat, and the NAT address rules and the builder's tested VMX lines apply
    # however the network is spelled. New-VMwareWorkstationVM keeps the same table, and
    # both projects' tests check it.
    #
    # Returns { Valid; NetworkType (the canonical network, after the mapping); Spelling (the
    # canonical spelling of the value as given, before the mapping); VmnetName (the VMnet
    # whose host adapter the network check looks for: VMnet8 for nat, VMnet1 for hostonly,
    # a VMnet<N> itself, $null for bridged); MappingApplied }. A value outside the four
    # forms, one with a trailing newline included, gives Valid = $false and nothing else.
    param (
        [AllowNull()]
        [AllowEmptyString()]
        [string]$NetworkType
    )
    $result = [pscustomobject]@{ Valid = $false; NetworkType = $null; Spelling = $null; VmnetName = $null; MappingApplied = $false }
    $valueMatch = [regex]::Match([string]$NetworkType, '\A(?:(nat|bridged|hostonly)|vmnet(0|[1-9][0-9]?))\z', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $valueMatch.Success) {
        return $result
    }
    if ($valueMatch.Groups[1].Success) {
        $result.Spelling = $valueMatch.Groups[1].Value.ToLowerInvariant()
    }
    else {
        $result.Spelling = 'VMnet' + $valueMatch.Groups[2].Value
    }
    $mappedName = switch ($result.Spelling) {
        'VMnet0' { 'bridged' }
        'VMnet1' { 'hostonly' }
        'VMnet8' { 'nat' }
        default  { $null }
    }
    $result.Valid          = $true
    $result.MappingApplied = ($null -ne $mappedName)
    $result.NetworkType    = if ($null -ne $mappedName) { $mappedName } else { $result.Spelling }
    $result.VmnetName      = switch ($result.NetworkType) {
        'nat'      { 'VMnet8' }
        'hostonly' { 'VMnet1' }
        'bridged'  { $null }
        default    { $result.NetworkType }
    }
    return $result
}

function Resolve-RunNetworkType {
    # Works out which network this run's VMs join, and where that came from. It never reads
    # $NetworkType to learn the source, because a value from build-lab's override file is
    # set on the parameter without binding it, so only the caller can say which source gave
    # which value. The order is the command line, the build profile, build-lab's override
    # file, then the parameter's default. A command-line value that differs from the
    # profile's, after the canonical spelling and the VMnet0, VMnet1 and VMnet8 mapping, is
    # a WARN naming both, and an equal one is one INFO naming both. A profile value over a
    # different override value is one INFO naming both. A command-line value over an
    # override value adds nothing here, because the override file's reader already logs it.
    # A mapped spelling adds one INFO.
    #
    # In -AddMemberServers the members have to join the DC's network, so the network in the
    # DC's VMX wins: INFO when it agrees with the run, a WARN when it doesn't
    # (DcNetworkDiffers), and the run's own value with a WARN when the VMX couldn't be read
    # (DcVmxUnreadable). -SkipVmBuild and -MoveMemberServers build no VM, so the network
    # isn't used there, and one INFO, and nothing else, names the value that went unused.
    #
    # Returns { NetworkUsed; NetworkType (the canonical network, $null when not used);
    # Source ('command line', 'profile', 'override file', 'default' or "the DC's VMX");
    # SourcePath (the profile's, the override file's or the VMX's path, else $null);
    # MappingApplied; DcVmxNetwork; DcVmxRow ('DcNetworkDiffers', 'DcVmxUnreadable' or
    # $null); LogEntries (each { Level; Message }, in order, for the caller to write) }.
    # Every value is expected to be valid already (the parameter's attribute and the build
    # profile's validator check them), so one that isn't throws.
    param (
        # The bound -NetworkType, or $null when the command line didn't give one.
        [AllowNull()]
        [AllowEmptyString()]
        [string]$CommandLineValue,
        # build-lab's override file's NetworkType assignment, or $null.
        [AllowNull()]
        [AllowEmptyString()]
        [string]$OverrideValue,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$OverridePath,
        # The build profile's NetworkType (Get-AdDomainIdentity), or $null.
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ProfileValue,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ProfilePath,
        # The parameter's own value, used only when no source above gives one.
        [Parameter(Mandatory)]
        [string]$DefaultValue,
        # The parameter set: Build, GuestOnly, MoveMembers or AddMembers.
        [Parameter(Mandatory)]
        [ValidateSet('Build', 'GuestOnly', 'MoveMembers', 'AddMembers')]
        [string]$Mode,
        # -AddMemberServers only: the network Get-VmxNetworkType read from the DC's VMX, or
        # $null when it couldn't, and that VMX's path.
        [AllowNull()]
        [AllowEmptyString()]
        [string]$DcVmxNetwork,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$DcVmxPath
    )
    $logEntries = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $readValue = {
        param ([string]$Value, [string]$SourceText)
        if ([string]::IsNullOrEmpty($Value)) { return $null }
        $canonicalValue = ConvertTo-CanonicalNetworkType -NetworkType $Value
        if (-not $canonicalValue.Valid) {
            throw "Network: $SourceText gives '$Value', which is not nat, bridged, hostonly, or VMnet0 to VMnet99. That value should have been refused before this point."
        }
        return $canonicalValue
    }
    $profileText          = "the build profile '$ProfilePath'"
    $overrideText         = "build-lab's override file '$OverridePath'"
    $commandLineNetwork   = & $readValue $CommandLineValue '-NetworkType'
    $profileNetwork       = & $readValue $ProfileValue $profileText
    $overrideNetwork      = & $readValue $OverrideValue $overrideText
    $defaultNetwork       = & $readValue $DefaultValue 'the -NetworkType default'

    # The run's own value, before the DC's VMX in -AddMemberServers.
    if ($null -ne $commandLineNetwork) {
        $runNetwork = $commandLineNetwork; $runSource = 'command line'; $runSourcePath = $null; $runSourceText = '-NetworkType'
        if ($null -ne $profileNetwork -and $profileNetwork.NetworkType -ne $commandLineNetwork.NetworkType) {
            $runLine = [pscustomobject]@{ Level = 'WARN'; Message = "Network: -NetworkType $($commandLineNetwork.Spelling) is used. The build profile '$ProfilePath' gives $($profileNetwork.Spelling), and the command line wins." }
        }
        elseif ($null -ne $profileNetwork) {
            $runLine = [pscustomobject]@{ Level = 'INFO'; Message = "Network: $($commandLineNetwork.Spelling), from -NetworkType. The build profile '$ProfilePath' gives the same network." }
        }
        else {
            $runLine = [pscustomobject]@{ Level = 'INFO'; Message = "Network: $($commandLineNetwork.Spelling), from -NetworkType." }
        }
    }
    elseif ($null -ne $profileNetwork) {
        $runNetwork = $profileNetwork; $runSource = 'profile'; $runSourcePath = $ProfilePath; $runSourceText = $profileText
        if ($null -ne $overrideNetwork -and $overrideNetwork.NetworkType -ne $profileNetwork.NetworkType) {
            $runLine = [pscustomobject]@{ Level = 'INFO'; Message = "Network: $($profileNetwork.Spelling), from the build profile '$ProfilePath', over NetworkType=$($overrideNetwork.Spelling) in build-lab's override file '$OverridePath'." }
        }
        else {
            $runLine = [pscustomobject]@{ Level = 'INFO'; Message = "Network: $($profileNetwork.Spelling), from the build profile '$ProfilePath'." }
        }
    }
    elseif ($null -ne $overrideNetwork) {
        $runNetwork = $overrideNetwork; $runSource = 'override file'; $runSourcePath = $OverridePath; $runSourceText = $overrideText
        $runLine = [pscustomobject]@{ Level = 'INFO'; Message = "Network: $($overrideNetwork.Spelling), from build-lab's override file '$OverridePath'." }
    }
    else {
        $runNetwork = $defaultNetwork; $runSource = 'default'; $runSourcePath = $null; $runSourceText = 'the -NetworkType default'
        $runLine = [pscustomobject]@{ Level = 'INFO'; Message = "Network: $($defaultNetwork.Spelling) (the -NetworkType default)." }
    }
    $mappingLine = $null
    if ($runNetwork.MappingApplied) {
        $mappingLine = [pscustomobject]@{ Level = 'INFO'; Message = "Network: $($runNetwork.Spelling) is taken as $($runNetwork.NetworkType)." }
    }

    $result = [pscustomobject]@{
        NetworkUsed    = $true
        NetworkType    = $runNetwork.NetworkType
        Source         = $runSource
        SourcePath     = $runSourcePath
        MappingApplied = [bool]$runNetwork.MappingApplied
        DcVmxNetwork   = $null
        DcVmxRow       = $null
        LogEntries     = $null
    }
    switch ($Mode) {
        { $_ -in @('GuestOnly', 'MoveMembers') } {
            $unusedSwitchName = if ($Mode -eq 'MoveMembers') { '-MoveMemberServers' } else { '-SkipVmBuild' }
            $logEntries.Add([pscustomobject]@{ Level = 'INFO'; Message = "Network: not used, because $unusedSwitchName builds no VM. The run's network would be $($runNetwork.Spelling), from $runSourceText." })
            $result.NetworkUsed    = $false
            $result.NetworkType    = $null
            $result.MappingApplied = $null
        }
        'AddMembers' {
            $logEntries.Add($runLine)
            $dcNetwork = & $readValue $DcVmxNetwork "the DC's VMX '$DcVmxPath'"
            if ($null -eq $dcNetwork) {
                if ($null -ne $mappingLine) { $logEntries.Add($mappingLine) }
                $logEntries.Add([pscustomobject]@{ Level = 'WARN'; Message = "Network: the network in the DC's VMX '$DcVmxPath' couldn't be read, so the members use this run's network, $($runNetwork.Spelling), from $runSourceText." })
                $result.DcVmxRow = 'DcVmxUnreadable'
            }
            elseif ($dcNetwork.NetworkType -eq $runNetwork.NetworkType) {
                if ($null -ne $mappingLine) { $logEntries.Add($mappingLine) }
                $logEntries.Add([pscustomobject]@{ Level = 'INFO'; Message = "Network: the DC's VMX '$DcVmxPath' is on $($dcNetwork.NetworkType), the same network as this run, so the members are built there." })
                $result.Source       = "the DC's VMX"
                $result.SourcePath   = $DcVmxPath
                $result.DcVmxNetwork = $dcNetwork.NetworkType
            }
            else {
                $logEntries.Add([pscustomobject]@{ Level = 'WARN'; Message = "Network: the DC's VMX '$DcVmxPath' is on $($dcNetwork.NetworkType), but this run's network is $($runNetwork.Spelling), from $runSourceText. The members are built on $($dcNetwork.NetworkType), the DC's network, or they couldn't reach it." })
                $result.NetworkType    = $dcNetwork.NetworkType
                $result.Source         = "the DC's VMX"
                $result.SourcePath     = $DcVmxPath
                $result.MappingApplied = $false
                $result.DcVmxNetwork   = $dcNetwork.NetworkType
                $result.DcVmxRow       = 'DcNetworkDiffers'
            }
        }
        default {
            $logEntries.Add($runLine)
            if ($null -ne $mappingLine) { $logEntries.Add($mappingLine) }
        }
    }
    $result.LogEntries = $logEntries.ToArray()
    return $result
}

function Get-VmxNetworkType {
    # Reads the network a VM's adapter is on from its VMX file on the host disk (no vmrun),
    # from the keys the VM builder writes: ethernet0.connectionType, and for a custom VMnet
    # ethernet0.vnet. Keys are matched without regard to case, values are in double quotes,
    # and the file may use CRLF or LF. Returns the canonical network
    # (ConvertTo-CanonicalNetworkType), or $null when the file can't be read, either key
    # appears more than once, or the lines aren't a form the builder writes. Used by
    # -AddMemberServers, on the DC's VMX.
    param (
        [Parameter(Mandatory)]
        [string]$VmxPath
    )
    try {
        $vmxText = Get-Content -LiteralPath $VmxPath -Raw -ErrorAction Stop
    }
    catch {
        return $null
    }
    if ($null -eq $vmxText) {
        return $null
    }
    $readKey = {
        param ([string]$KeyName)
        $keyMatches = [regex]::Matches([string]$vmxText, '(?im)^[ \t]*' + [regex]::Escape($KeyName) + '[ \t]*=[ \t]*"([^"\r\n]*)"[ \t]*\r?$')
        if ($keyMatches.Count -ne 1) { return $null }
        return $keyMatches[0].Groups[1].Value
    }
    $connectionType = & $readKey 'ethernet0.connectionType'
    if ($connectionType -in @('nat', 'bridged', 'hostonly')) {
        return (ConvertTo-CanonicalNetworkType -NetworkType $connectionType).NetworkType
    }
    if ($connectionType -ne 'custom') {
        return $null
    }
    $vnetNetwork = ConvertTo-CanonicalNetworkType -NetworkType (& $readKey 'ethernet0.vnet')
    if (-not $vnetNetwork.Valid -or $vnetNetwork.Spelling -notlike 'VMnet*') {
        return $null
    }
    return $vnetNetwork.NetworkType
}

function Test-HostNetworkForAddress {
    # The network check, on host state already read by Get-HostNetworkState, so it makes no
    # call of its own. build-lab confirms every VM by pinging it from this host, so before
    # anything is pinged or built it checks that the host has an adapter on the DC's subnet,
    # and that the host's route to the DC's address leaves by the VMnet's own adapter. That
    # adapter is found by the name Workstation gives it, 'VMware Network Adapter VMnet<N>',
    # which has been seen for VMnet8 on one host only. A host address holds the DC's subnet
    # when the DC's address is inside that address's own prefix, and an adapter holds it
    # when any of its addresses does.
    #
    # The case it found, in Row:
    #   Reachable              pass. The VMnet's adapter holds the subnet, the route leaves by
    #                          it, and no other adapter holds the subnet
    #   VmnetAdapterOffSubnet  stop. The VMnet's adapter is on another subnet
    #   RouteOtherAdapter      stop. The route to the DC's address leaves by another adapter
    #   SubnetShared           WARN. Other adapters hold the subnet too, but the route is the
    #                          VMnet's
    #   NoVmnetAdapter         WARN. No adapter has that name, and another holds the subnet
    #   NoAdapterOnSubnet      stop. No adapter has that name, and none is on the subnet
    #   AddressesUnreadable    WARN. The addresses couldn't be read, so the check is skipped
    #   RouteUnreadable        WARN, logged once whenever the route couldn't be read, while the
    #                          cases that need only the addresses still decide
    #                          (VmnetAdapterOffSubnet and NoAdapterOnSubnet still stop, and
    #                          where only the route could decide, the run goes on)
    #   NotChecked             bridged, which isn't checked
    #
    # The mask, in MaskRow:
    #   MaskFromAdapter         no mask was given (neither -SubnetMask nor build-lab's override
    #                           file), and the VMnet's adapter holds the subnet and is either
    #                           its only holder or the adapter the route leaves by, so the VMs
    #                           get that adapter's prefix, with an INFO
    #   MaskDiffersFromAdapter  a mask was given and its prefix differs, in those same cases,
    #                           so it is kept with a WARN
    #   MaskKept                every other case keeps the given mask or the default
    #
    # Returns { Outcome (Pass, Warn, Stop or NotChecked); Row (one of the cases above);
    # Message (the stop's text, else $null); LogEntries (each { Level; Message }, in order);
    # RouteAdapter; SubnetHolders; SubnetMask; SubnetMaskSource ('command line', 'override
    # file', 'derived' or 'default'); MaskRow (one of the three above); PrefixLength }.
    param (
        # The canonical network (ConvertTo-CanonicalNetworkType) and its VMnet, $null for
        # bridged.
        [Parameter(Mandatory)]
        [string]$NetworkType,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$VmnetName,
        # The DC's -StaticIpAddress.
        [Parameter(Mandatory)]
        [string]$IpAddress,
        # The mask -SubnetMask holds now, and where it came from.
        [Parameter(Mandatory)]
        [string]$SubnetMask,
        [Parameter(Mandatory)]
        [ValidateSet('command line', 'override file', 'default')]
        [string]$SubnetMaskSource,
        # build-lab's override file, named when the mask came from it.
        [AllowNull()]
        [AllowEmptyString()]
        [string]$OverrideFilePath,
        # Get-HostNetworkState's result. Not read for bridged.
        [AllowNull()]
        [object]$HostState
    )
    $logEntries = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $result = [pscustomobject]@{
        Outcome          = 'Pass'
        Row              = $null
        Message          = $null
        LogEntries       = $null
        RouteAdapter     = $null
        SubnetHolders    = @()
        SubnetMask       = $SubnetMask
        SubnetMaskSource = $SubnetMaskSource
        MaskRow          = 'MaskKept'
        PrefixLength     = (ConvertTo-PrefixLength -SubnetMask $SubnetMask)
    }
    $quoteNames = { param ([object[]]$Names) if (@($Names).Count -eq 0) { 'none' } else { (@($Names) | ForEach-Object { "'$_'" }) -join ', ' } }

    if ([string]::IsNullOrEmpty($VmnetName)) {
        $result.Outcome = 'NotChecked'
        $result.Row     = 'NotChecked'
        $logEntries.Add([pscustomobject]@{ Level = 'INFO'; Message = "Network check: not run for $NetworkType." })
        $result.LogEntries = $logEntries.ToArray()
        return $result
    }
    if ($null -eq $HostState -or $HostState.AddressError) {
        $addressError = if ($null -eq $HostState) { 'no host state was read' } else { $HostState.AddressError }
        $result.Outcome = 'Warn'
        $result.Row     = 'AddressesUnreadable'
        $logEntries.Add([pscustomobject]@{ Level = 'WARN'; Message = "Network check: this host's IPv4 addresses could not be read ($addressError), so the check that it can reach $IpAddress on $VmnetName was skipped." })
        $result.LogEntries = $logEntries.ToArray()
        return $result
    }

    $adapterAlias      = "VMware Network Adapter $VmnetName"
    $hostAddresses     = @($HostState.Addresses | Where-Object { $null -ne $_ })
    $holdsSubnet       = { param ($HostAddress) Test-IpAddressInSubnet -IpAddress $IpAddress -Subnet "$($HostAddress.IPAddress)/$($HostAddress.PrefixLength)" }
    $addressText       = { param ($HostAddress) "$($HostAddress.IPAddress)/$($HostAddress.PrefixLength)" }
    $holderAliases     = @($hostAddresses | Where-Object { & $holdsSubnet $_ } | ForEach-Object { [string]$_.InterfaceAlias } | Select-Object -Unique)
    $otherHolderAliases = @($holderAliases | Where-Object { $_ -ne $adapterAlias })
    $vmnetAddresses    = @($hostAddresses | Where-Object { $_.InterfaceAlias -eq $adapterAlias })
    $vmnetHolder       = $vmnetAddresses | Where-Object { & $holdsSubnet $_ } | Select-Object -First 1
    $routeAdapter      = if ($HostState.RouteError) { $null } else { $HostState.RouteAdapter }
    $result.SubnetHolders = $holderAliases
    $result.RouteAdapter  = $routeAdapter
    if (-not $routeAdapter) {
        $routeError = if ($HostState.RouteError) { $HostState.RouteError } else { 'it returned no route' }
        $result.Outcome = 'Warn'
        $result.Row     = 'RouteUnreadable'
        $logEntries.Add([pscustomobject]@{ Level = 'WARN'; Message = "Network check: this host's route to $IpAddress could not be found ($routeError), so the adapter it leaves by was not checked. Adapters holding the subnet: $(& $quoteNames $holderAliases)." })
    }

    $maskRuleApplies = $false
    if ($vmnetAddresses.Count -gt 0) {
        if ($null -eq $vmnetHolder) {
            $firstVmnetAddress = $vmnetAddresses[0]
            $firstPrefixLength = [int]$firstVmnetAddress.PrefixLength
            $firstMaskNumber   = ConvertTo-IpAddressNumber -IpAddress (ConvertFrom-PrefixLength -PrefixLength $firstPrefixLength)
            $firstSubnetText   = (ConvertFrom-IpAddressNumber -IpAddressNumber ((ConvertTo-IpAddressNumber -IpAddress $firstVmnetAddress.IPAddress) -band $firstMaskNumber)) + "/$firstPrefixLength"
            $result.Outcome = 'Stop'
            $result.Row     = 'VmnetAdapterOffSubnet'
            $result.Message = "Network check: -StaticIpAddress $IpAddress is outside $adapterAlias ($(& $addressText $firstVmnetAddress)), the host adapter for $VmnetName. The VM would not answer this host, and build-lab confirms every VM by pinging it from here. Choose an address in $firstSubnetText, or a -NetworkType whose subnet holds $IpAddress. Nothing was built."
        }
        elseif ($routeAdapter -and $routeAdapter -ne $adapterAlias) {
            $result.Outcome = 'Stop'
            $result.Row     = 'RouteOtherAdapter'
            if ($holderAliases -contains $routeAdapter) {
                $result.Message = "Network check: this host's route to $IpAddress leaves by '$routeAdapter', not by '$adapterAlias', the host adapter for $VmnetName, although both hold its subnet. This host's pings would go to the other network, so build-lab can't tell whether $IpAddress is free or whether the VM came up. Give each VMnet its own subnet in the Virtual Network Editor, or choose an address in a subnet only $VmnetName holds. Nothing was built."
            }
            else {
                $result.Message = "Network check: this host routes $IpAddress by '$routeAdapter', not by '$adapterAlias', the host adapter for $VmnetName that holds its subnet. A VPN or a more specific route may be taking it. This host's pings would go elsewhere, so build-lab can't tell whether $IpAddress is free or whether the VM came up. Remove or change the route through '$routeAdapter', or choose another -NetworkType or address. Nothing was built."
            }
        }
        elseif ($routeAdapter) {
            if ($otherHolderAliases.Count -gt 0) {
                $result.Outcome = 'Warn'
                $result.Row     = 'SubnetShared'
                $logEntries.Add([pscustomobject]@{ Level = 'WARN'; Message = "Network check: '$adapterAlias' ($(& $addressText $vmnetHolder)) holds $IpAddress's subnet, and so do $(& $quoteNames $otherHolderAliases). This host's route to $IpAddress leaves by '$adapterAlias', so the build continues. Giving each VMnet its own subnet keeps it that way." })
            }
            else {
                $result.Row = 'Reachable'
                $logEntries.Add([pscustomobject]@{ Level = 'INFO'; Message = "Network check: '$adapterAlias' ($(& $addressText $vmnetHolder)) holds $IpAddress's subnet, and this host's route to $IpAddress leaves by it." })
            }
            $maskRuleApplies = $true
        }
        else {
            # RouteUnreadable, already logged. With the VMnet's adapter the only holder, the
            # route can change nothing, so the mask rule still applies.
            $maskRuleApplies = ($otherHolderAliases.Count -eq 0)
        }
    }
    elseif ($holderAliases.Count -eq 0) {
        $result.Outcome = 'Stop'
        $result.Row     = 'NoAdapterOnSubnet'
        $result.Message = "Network check: no host adapter is on $IpAddress's subnet, and there is no '$adapterAlias'. $VmnetName may not exist, may have no host virtual adapter, or $IpAddress may be in the wrong subnet. build-lab confirms every VM by pinging it from this host, so it can only build on a VMnet this host has an adapter on. Connect a host virtual adapter to $VmnetName in the Virtual Network Editor (build-lab doesn't change host networking), or choose another -NetworkType or address. Nothing was built."
    }
    elseif ($routeAdapter) {
        $routeAddresses   = @($hostAddresses | Where-Object { $_.InterfaceAlias -eq $routeAdapter })
        $routeAddress     = @($routeAddresses | Where-Object { & $holdsSubnet $_ }) + $routeAddresses | Select-Object -First 1
        $routeAddressText = if ($null -ne $routeAddress) { & $addressText $routeAddress } else { 'no IPv4 address' }
        $result.Outcome = 'Warn'
        $result.Row     = 'NoVmnetAdapter'
        $logEntries.Add([pscustomobject]@{ Level = 'WARN'; Message = "Network check: no adapter named '$adapterAlias'; this host's route to $IpAddress leaves by '$routeAdapter' ($routeAddressText). Adapters holding the subnet: $(& $quoteNames $holderAliases). If '$routeAdapter' is not $VmnetName's adapter, the VM will not answer and the build fails after the VM builder's timeout." })
    }

    if ($result.Outcome -ne 'Stop' -and $maskRuleApplies) {
        $adapterPrefixLength = [int]$vmnetHolder.PrefixLength
        if ($SubnetMaskSource -eq 'default') {
            $result.SubnetMask       = ConvertFrom-PrefixLength -PrefixLength $adapterPrefixLength
            $result.SubnetMaskSource = 'derived'
            $result.MaskRow          = 'MaskFromAdapter'
            $result.PrefixLength     = $adapterPrefixLength
            $logEntries.Add([pscustomobject]@{ Level = 'INFO'; Message = "Network check: no subnet mask was given, so the VMs get $($result.SubnetMask) (/$adapterPrefixLength), the prefix of '$adapterAlias'." })
        }
        elseif ($result.PrefixLength -ne $adapterPrefixLength) {
            $givenMaskText = if ($SubnetMaskSource -eq 'command line') { '-SubnetMask' } else { "build-lab's override file '$OverrideFilePath'" }
            $result.MaskRow = 'MaskDiffersFromAdapter'
            if ($result.Outcome -eq 'Pass') { $result.Outcome = 'Warn' }
            $logEntries.Add([pscustomobject]@{ Level = 'WARN'; Message = "Network check: the subnet mask $SubnetMask (/$($result.PrefixLength)) from $givenMaskText differs from '$adapterAlias' ($(& $addressText $vmnetHolder)). The VM may not answer this host. The given mask is used." })
        }
    }
    $result.LogEntries = $logEntries.ToArray()
    return $result
}

function Get-HostNetworkState {
    # The network check's two reads of this host, both read-only: every preferred IPv4
    # address (Get-NetIPAddress), and the route this host would use to reach
    # -RemoteIpAddress (Find-NetRoute). Find-NetRoute returns the local address it would
    # use and the route, and the route is the object with a NextHop property. Its
    # InterfaceIndex names the adapter from the address read, and its own InterfaceAlias is
    # used only when that index isn't there. That is the shape both reads had when run
    # unelevated (an MSFT_NetIPAddress and an MSFT_NetRoute with the same InterfaceIndex).
    # Never throws: a failed read comes back as AddressError or RouteError, which the check
    # turns into AddressesUnreadable or RouteUnreadable. An error text is the exception's
    # message, which holds no secret.
    #
    # Returns { Addresses (each { InterfaceAlias; InterfaceIndex; IPAddress; PrefixLength });
    # AddressError; RouteAdapter; RouteError }.
    param (
        [Parameter(Mandatory)]
        [string]$RemoteIpAddress
    )
    $hostState = [pscustomobject]@{ Addresses = @(); AddressError = $null; RouteAdapter = $null; RouteError = $null }
    $errorText = { param ($ErrorRecord) $messageText = ([string]$ErrorRecord.Exception.Message).Trim().TrimEnd('.'); if ($messageText) { $messageText } else { $ErrorRecord.Exception.GetType().FullName } }
    try {
        $hostState.Addresses = @(Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ InterfaceAlias = [string]$_.InterfaceAlias; InterfaceIndex = [int]$_.InterfaceIndex; IPAddress = [string]$_.IPAddress; PrefixLength = [int]$_.PrefixLength }
            })
    }
    catch {
        $hostState.AddressError = & $errorText $_
        return $hostState
    }
    try {
        $routeObjects = @(Find-NetRoute -RemoteIPAddress $RemoteIpAddress -ErrorAction Stop)
    }
    catch {
        $hostState.RouteError = & $errorText $_
        return $hostState
    }
    $routeObject = $routeObjects | Where-Object { $null -ne $_ -and @($_.PSObject.Properties.Name) -contains 'NextHop' } | Select-Object -First 1
    if ($null -eq $routeObject) {
        $hostState.RouteError = 'it returned no route'
        return $hostState
    }
    $routeAlias = $hostState.Addresses | Where-Object { [string]$_.InterfaceIndex -eq [string]$routeObject.InterfaceIndex } | ForEach-Object { $_.InterfaceAlias } | Select-Object -First 1
    if (-not $routeAlias -and @($routeObject.PSObject.Properties.Name) -contains 'InterfaceAlias') {
        $routeAlias = [string]$routeObject.InterfaceAlias
    }
    if ($routeAlias) {
        $hostState.RouteAdapter = $routeAlias
    }
    else {
        $hostState.RouteError = 'the route names no adapter'
    }
    return $hostState
}

function Test-VmBuilderNetworkType {
    # Asks whether the VM builder would accept -NetworkType <value>, by reading its param()
    # block from the syntax tree (Test-ParameterValueByAst, include\OverrideFile.ps1), never
    # by running it. Main calls it only for a custom VMnet, because every builder takes nat,
    # bridged and hostonly, and whatever the version handshake found.
    #
    # Returns { Outcome; Message }: Valid with no message; Stop when the builder would refuse
    # the value at binding; Warn when its validation couldn't be read, which leaves the
    # value to the builder's own check, as before.
    param (
        [Parameter(Mandatory)]
        [string]$VmBuilderScriptPath,
        [Parameter(Mandatory)]
        [string]$NetworkType
    )
    $builderCheck = Test-ParameterValueByAst -ScriptPath $VmBuilderScriptPath -ParameterName 'NetworkType' -Value $NetworkType
    switch ($builderCheck.State) {
        'Valid' {
            return [pscustomobject]@{ Outcome = 'Valid'; Message = $null }
        }
        'Refused' {
            return [pscustomobject]@{ Outcome = 'Stop'; Message = "Network check: the VM builder at '$VmBuilderScriptPath' does not accept -NetworkType $NetworkType. Custom VMnets need New-VMwareWorkstationVM 1.2 or later. Update it, or pass -VmBuilderScriptPath to one that has it. Nothing was built." }
        }
        default {
            $uncheckableReason = ([string]$builderCheck.Reason).Trim().TrimEnd('.')
            if (-not $uncheckableReason) { $uncheckableReason = 'no reason was given' }
            return [pscustomobject]@{ Outcome = 'Warn'; Message = "Network check: could not read which -NetworkType values the VM builder at '$VmBuilderScriptPath' accepts ($uncheckableReason), so $NetworkType is left to the builder to check." }
        }
    }
}

function New-NetworkHookObject {
    # The network hook: one object, made once the effective network and mask are final and
    # before anything is pinged or built, for the build manifest to record. Its field names
    # are fixed. In -SkipVmBuild and -MoveMemberServers NetworkUsed is $false, and only
    # NetworkSource and NetworkSourcePath are set, naming the value that went unused.
    # HostCheckRow is NotChecked for bridged.
    param (
        # Resolve-RunNetworkType's result.
        [Parameter(Mandatory)]
        [object]$Resolution,
        # Test-HostNetworkForAddress's result, $null when the network isn't used.
        [AllowNull()]
        [object]$HostCheck
    )
    $networkHook = [pscustomobject]@{
        NetworkUsed       = [bool]$Resolution.NetworkUsed
        NetworkType       = $null
        NetworkSource     = $Resolution.Source
        NetworkSourcePath = $Resolution.SourcePath
        MappingApplied    = $null
        DcVmxNetwork      = $null
        DcVmxRow          = $null
        HostCheckRow      = $null
        RouteAdapter      = $null
        SubnetHolders     = $null
        SubnetMask        = $null
        SubnetMaskSource  = $null
        MaskRow           = $null
        PrefixLength      = $null
    }
    if (-not $networkHook.NetworkUsed) {
        return $networkHook
    }
    $networkHook.NetworkType    = $Resolution.NetworkType
    $networkHook.MappingApplied = [bool]$Resolution.MappingApplied
    $networkHook.DcVmxNetwork   = $Resolution.DcVmxNetwork
    $networkHook.DcVmxRow       = $Resolution.DcVmxRow
    if ($null -ne $HostCheck) {
        $networkHook.HostCheckRow     = $HostCheck.Row
        $networkHook.RouteAdapter     = $HostCheck.RouteAdapter
        $networkHook.SubnetHolders    = @($HostCheck.SubnetHolders)
        $networkHook.SubnetMask       = $HostCheck.SubnetMask
        $networkHook.SubnetMaskSource = $HostCheck.SubnetMaskSource
        $networkHook.MaskRow          = $HostCheck.MaskRow
        $networkHook.PrefixLength     = $HostCheck.PrefixLength
    }
    return $networkHook
}

function Get-GuestMachineIdentity {
    # Reads, from a guest, its computer name, domain, domain role, IPv4 addresses with
    # prefix lengths and default gateways, the domain with Get-ADDomain -Current
    # LocalComputer (AdDomainDnsRoot, AdDomainNetBIOSName, AdDomainDistinguishedName), and
    # its OS from Win32_OperatingSystem (BuildNumber, Caption, Version). -AddMemberServers
    # and -MoveMemberServers check the DC with it against what they would otherwise take on
    # trust from the command line and global-config.ps1, Resolve-MemberDomainIdentity uses
    # the AD fields when nothing named a domain, and the build manifest records each VM
    # from it. The AD read and the OS read each run in a guest-side try of their own, so
    # either can fail and leave the rest of the answer unchanged: on a guest that is not a
    # DC the three AD fields are $null, and when the OS query fails the three OS fields are
    # $null and OsError holds the reason. Neither the DC check nor the domain fallback reads
    # the OS fields. It is a read, so it is retried. -NoRetry and a short
    # -VmrunTimeoutSeconds are for the manifest's own reads, which must never hold a build up.
    param (
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [string]$VmxFilePath,
        [Parameter(Mandatory)]
        [PSCredential]$GuestCredential,
        [Parameter(Mandatory)]
        [string]$HostStagingPath,
        [switch]$NoRetry,
        [int]$VmrunTimeoutSeconds = 600
    )
    $guestCommand = '$computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem; ' +
        '$ipv4Addresses = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne ''127.0.0.1'' -and $_.PrefixOrigin -ne ''WellKnown'' } | ForEach-Object { ''{0}/{1}'' -f $_.IPAddress, $_.PrefixLength }); ' +
        '$defaultGateways = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix ''0.0.0.0/0'' -ErrorAction SilentlyContinue | ForEach-Object { $_.NextHop }); ' +
        '$adDomain = $null; try { Import-Module -Name ActiveDirectory -ErrorAction Stop; $adDomain = Get-ADDomain -Current LocalComputer -ErrorAction Stop } catch { $adDomain = $null }; ' +
        '$osBuildNumber = $null; $osCaption = $null; $osVersion = $null; $osError = $null; ' +
        'try { $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop; $osBuildNumber = [string]$operatingSystem.BuildNumber; $osCaption = [string]$operatingSystem.Caption; $osVersion = [string]$operatingSystem.Version } catch { $osError = $_.Exception.Message }; ' +
        '[pscustomobject]@{ Name = $computerSystem.Name; Domain = $computerSystem.Domain; DomainRole = $computerSystem.DomainRole; Ipv4Addresses = $ipv4Addresses; DefaultGateways = $defaultGateways; ' +
        'AdDomainDnsRoot = $(if ($adDomain) { [string]$adDomain.DNSRoot } else { $null }); AdDomainNetBIOSName = $(if ($adDomain) { [string]$adDomain.NetBIOSName } else { $null }); ' +
        'AdDomainDistinguishedName = $(if ($adDomain) { [string]$adDomain.DistinguishedName } else { $null }); ' +
        'BuildNumber = $osBuildNumber; Caption = $osCaption; Version = $osVersion; OsError = $osError }'

    return Invoke-GuestPowerShellCommand -VmrunPath $VmrunPath -VmxFilePath $VmxFilePath -GuestCredential $GuestCredential `
        -OperationName 'query machine identity' -GuestCommand $guestCommand -HostStagingPath $HostStagingPath -Retry:(-not $NoRetry) `
        -VmrunTimeoutSeconds $VmrunTimeoutSeconds
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
    # Compares what the DC reports (Get-GuestMachineIdentity) with what this run
    # was told. Returns one message per mismatch; an empty result means everything matches.
    # Expected values that are not supplied are not checked. -ExpectedDomainSource names
    # where the expected domain came from in the mismatch message: global-config.ps1, or
    # the build profile when the run uses one.
    param (
        [Parameter(Mandatory)]
        [object]$Identity,
        [Parameter(Mandatory)]
        [string]$ExpectedDomainName,
        [string]$ExpectedDomainSource = 'global-config.ps1',
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
        $mismatches += "it is in domain '$($Identity.Domain)', but $ExpectedDomainSource names '$ExpectedDomainName'"
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
        $invokeNativeCommand = ${function:Invoke-NativeCommand}
        $null = Invoke-CommandWithRetry -OperationName $copyOperationName -ThrowOnFailure -ScriptBlock {
            $null = & $invokeNativeCommand -FilePath $VmrunPath -RedactedTokens $redactedTokens -OperationName $copyOperationName -ArgumentList $copyArgumentList `
                -TimeoutSeconds $VmrunTimeoutSeconds
        }.GetNewClosure()
    }
    else {
        $null = Invoke-NativeCommand -FilePath $VmrunPath -RedactedTokens $redactedTokens -OperationName $copyOperationName -ArgumentList $copyArgumentList `
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
    $invokeNativeCommand = ${function:Invoke-NativeCommand}

    $runAttempt = {
        $attemptResultFilePath = 'C:\temp\build-lab-' + [guid]::NewGuid().ToString('N') + '.json'
        $guestResultFilePaths.Add($attemptResultFilePath)
        $attemptArgumentList = $vmrunArgumentPrefix + @($envelopeCommandTemplate.Replace($resultFilePlaceholder, $attemptResultFilePath))
        $null = & $invokeNativeCommand -FilePath $VmrunPath -RedactedTokens $allRedactedTokens -OperationName $OperationName `
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
                $null = Invoke-NativeCommand -FilePath $VmrunPath -RedactedTokens $allRedactedTokens -OperationName "deleteFileInGuest $guestResultFilePath" `
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
            # The guest's own error text has not passed through Invoke-NativeCommand's
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
        $null = Invoke-NativeCommand -FilePath $VmrunPath -RedactedTokens @($guestPasswordPlainText) -OperationName 'shutdown.exe /r (-noWait)' `
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
        [switch]$OmitPopulationNotice,
        # Directory population finished in this run, so OU=Servers already exists.
        [switch]$PopulationFinished
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
        $bannerBodyLines += " Member servers joined: $($JoinedMemberServerNames -join ', ')"
        if ($PopulationFinished) {
            $bannerBodyLines += @(
                ' They are in the default CN=Computers container. Re-run build-lab.ps1 with',
                ' -MoveMemberServers to move them to OU=Servers.'
            )
        }
        else {
            $bannerBodyLines += @(
                ' They are in the default CN=Computers container. Once directory population',
                ' has finished, re-run build-lab.ps1 with -MoveMemberServers to move them',
                ' to OU=Servers.'
            )
        }
    }
    if ($bannerBodyLines.Count -eq 0) { return }

    $bannerRule  = '================================================================================'
    $bannerLines = @('', $bannerRule) + $bannerBodyLines + @($bannerRule, '')
    foreach ($bannerLine in $bannerLines) {
        Write-Host $bannerLine -ForegroundColor Red
    }
}

function Get-ScriptHeaderVersion {
    # Returns the Version line of a script's comment-based header, as written, read by
    # parsing the script (Read-ScriptSetting, include\OverrideFile.ps1), never by running
    # it. $null when the script is missing, can't be parsed or has no Version line.
    param (
        [Parameter(Mandatory)]
        [string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $scriptSetting = Read-ScriptSetting -Path $Path
    if ($scriptSetting.Error) {
        return $null
    }
    return $scriptSetting.Version
}

function Test-SiblingVersion {
    # Compares a sibling script's header version with the oldest one this build-lab works
    # with, as [version], so a newer version (an unreleased master included) passes.
    # Returns { Status; FoundVersion; Message }, where Status is Ok, Below or Unreadable.
    param (
        [Parameter(Mandatory)]
        [string]$ProjectName,
        [Parameter(Mandatory)]
        [string]$ScriptPath,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$FoundVersion,
        [Parameter(Mandatory)]
        [string]$MinimumVersion
    )
    $parsedVersion = $null
    if ($FoundVersion) {
        $parsedVersion = $FoundVersion -as [version]
    }
    if ($null -eq $parsedVersion) {
        return [pscustomobject]@{ Status = 'Unreadable'; FoundVersion = $FoundVersion
            Message = "$ProjectName's version can't be read from the header of '$ScriptPath', so build-lab can't tell whether it is $MinimumVersion or later, as this build-lab needs." }
    }
    if ($parsedVersion -lt [version]$MinimumVersion) {
        return [pscustomobject]@{ Status = 'Below'; FoundVersion = $FoundVersion
            Message = "$ProjectName at '$ScriptPath' is version $FoundVersion, and this build-lab needs $MinimumVersion or later." }
    }
    return [pscustomobject]@{ Status = 'Ok'; FoundVersion = $FoundVersion
        Message = "$ProjectName at '$ScriptPath' is version $FoundVersion. This build-lab needs $MinimumVersion or later." }
}

function Get-SiblingVersionOutcome {
    # What the version handshake does with a sibling's header version. Returns
    # { Status; FoundVersion; Level; Message }: Status as Test-SiblingVersion gives it, and
    # Level INFO, WARN or Stop. The caller logs Message at Level, or throws it on Stop.
    # Below the minimum, new-AdDomain stops. Below OverrideFileVersion the reason is the
    # override file it can't apply, and from there up to the minimum it is the parts this
    # build-lab relies on. The VM builder below the minimum WARNs, and stops only when it is
    # below OverrideFileVersion and OverrideFilePath exists, since it would ignore that file.
    param (
        [Parameter(Mandatory)]
        [ValidateSet('new-AdDomain', 'New-VMwareWorkstationVM')]
        [string]$ProjectName,
        [Parameter(Mandatory)]
        [string]$ScriptPath,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$FoundVersion,
        [Parameter(Mandatory)]
        [string]$MinimumVersion,
        [Parameter(Mandatory)]
        [string]$OverrideFileVersion,
        # The VM builder's override file. Not used for new-AdDomain.
        [AllowNull()]
        [AllowEmptyString()]
        [string]$OverrideFilePath
    )
    $versionCheck = Test-SiblingVersion -ProjectName $ProjectName -ScriptPath $ScriptPath -FoundVersion $FoundVersion -MinimumVersion $MinimumVersion
    $outcomeLevel   = 'INFO'
    $outcomeMessage = $versionCheck.Message
    switch ($versionCheck.Status) {
        'Unreadable' { $outcomeLevel = 'WARN' }
        'Below' {
            # Below means the version parsed, so the cast is safe.
            $readsOverrideFile = ([version]$FoundVersion) -ge [version]$OverrideFileVersion
            if ($ProjectName -eq 'new-AdDomain') {
                $outcomeLevel = 'Stop'
                $belowReason  = if ($readsOverrideFile) { "A new-AdDomain older than $MinimumVersion lacks parts this build-lab relies on" } else { "A new-AdDomain older than $OverrideFileVersion can't apply its override file" }
                $outcomeMessage = "$($versionCheck.Message) $belowReason, so build-lab stopped before any VM was built or changed. Update new-AdDomain, or point -AdDomainSourcePath at a copy that is $MinimumVersion or later."
            }
            elseif ($readsOverrideFile) {
                $outcomeLevel   = 'WARN'
                $outcomeMessage = "$($versionCheck.Message) It can read an override file, so build-lab goes on with it, but it may lack fixes made for this build-lab. Update New-VMwareWorkstationVM when you can."
            }
            elseif ($OverrideFilePath -and (Test-Path -LiteralPath $OverrideFilePath)) {
                $outcomeLevel   = 'Stop'
                $outcomeMessage = "$($versionCheck.Message) That version doesn't read an override file, and '$OverrideFilePath' exists, so its settings would be ignored. build-lab stopped before any VM was built or changed. Update New-VMwareWorkstationVM, or move its override file out of the overrides folder."
            }
            else {
                $outcomeLevel   = 'WARN'
                $outcomeMessage = "$($versionCheck.Message) It doesn't read an override file, and it has none, so build-lab goes on with it as it is."
            }
        }
    }
    return [pscustomobject]@{ Status = $versionCheck.Status; FoundVersion = $versionCheck.FoundVersion; Level = $outcomeLevel; Message = $outcomeMessage }
}

function Get-RequiredGlobalConfigVersion {
    # The oldest include\global-config.ps1 the given new-AdDomain scripts run with: the
    # highest of their $requiredGlobalConfigVersion constants, read by parsing each script
    # (Read-ScriptSetting), never by running it. Returns { Version; Problems }. Version is
    # $null when no script states one, and Problems names each script that doesn't.
    param (
        [Parameter(Mandatory)]
        [string[]]$ScriptPath
    )
    $highestVersion     = $null
    $highestVersionText = $null
    $problems           = @()
    foreach ($onePath in $ScriptPath) {
        $scriptSetting = Read-ScriptSetting -Path $onePath
        if ($scriptSetting.Error) {
            $problems += $scriptSetting.Error
            continue
        }
        $requiredAssignment = @($scriptSetting.Assignments | Where-Object { $_.Name -eq 'requiredGlobalConfigVersion' }) | Select-Object -Last 1
        $requiredVersion = $null
        if ($null -ne $requiredAssignment -and $requiredAssignment.State -eq 'Value') {
            $requiredVersion = [string]$requiredAssignment.Value -as [version]
        }
        if ($null -eq $requiredVersion) {
            $problems += "'$onePath' has no constant `$requiredGlobalConfigVersion."
            continue
        }
        if ($null -eq $highestVersion -or $requiredVersion -gt $highestVersion) {
            $highestVersion     = $requiredVersion
            $highestVersionText = [string]$requiredAssignment.Value
        }
    }
    return [pscustomobject]@{ Version = $highestVersionText; Problems = $problems }
}

function Test-GlobalConfigVersionRequirement {
    # Returns $null when global-config.ps1's $globalConfigVersion is at least the version
    # new-AdDomain's scripts need, compared as [version], and otherwise the stop text,
    # which names both versions and an older global-config.ps1 as the likely cause. A
    # global-config.ps1 from before override files has no $globalConfigVersion at all.
    param (
        [AllowNull()]
        [AllowEmptyString()]
        [string]$FoundVersion,
        [Parameter(Mandatory)]
        [string]$RequiredVersion,
        [Parameter(Mandatory)]
        [string]$GlobalConfigPath
    )
    $parsedVersion = $null
    if ($FoundVersion) {
        $parsedVersion = $FoundVersion -as [version]
    }
    if ($null -ne $parsedVersion -and $parsedVersion -ge [version]$RequiredVersion) {
        return $null
    }
    $foundText = if (-not $FoundVersion) { 'has no version, so it comes from an older release' }
        elseif ($null -eq $parsedVersion) { "has the version '$FoundVersion', which isn't a version number" }
        else { "is version $FoundVersion" }
    return "new-AdDomain's scripts need include\global-config.ps1 $RequiredVersion or later, and '$GlobalConfigPath' $foundText. An older global-config.ps1 was probably copied over this release's, so build-lab stopped before any VM was built or changed. Put back this release's include\global-config.ps1 and keep your settings in new-AdDomain's overrides\overrides.psd1. new-AdDomain's UPGRADE.md shows how to move them there with Export-OverrideFile.ps1."
}

function Resolve-MemberDomainIdentity {
    # Decides which domain -AddMemberServers and -MoveMemberServers work in, once the DC
    # has been read. When the staged domain came from nothing anyone named
    # (DomainNameSource 'Shipped': no build profile, no new-AdDomain override file and an
    # unedited global-config.ps1) and the DC is in another domain, the DC's own domain is
    # used, with a WARN. Its DNS name, NetBIOS name and distinguished name come from
    # Get-ADDomain on the DC (Get-GuestMachineIdentity), so nothing is derived
    # here and no new-AdDomain function is called. A domain that was named keeps the DC
    # check's stop (Compare-DomainControllerIdentity).
    # Returns { Identity; Warning }: Identity is the staged identity, or a copy holding the
    # DC's DomainName, NetBIOSName, DomainDN and ServersOU. Warning is $null or the WARN.
    param (
        [Parameter(Mandatory)]
        [object]$StagedIdentity,
        [Parameter(Mandatory)]
        [object]$DomainControllerIdentity,
        [Parameter(Mandatory)]
        [string]$VmxFilePath
    )
    $result = [pscustomobject]@{ Identity = $StagedIdentity; Warning = $null }
    # -eq on strings ignores case, as DNS names do.
    if ([string]$DomainControllerIdentity.Domain -eq [string]$StagedIdentity.DomainName) {
        return $result
    }
    $stagedSourceProperty = $StagedIdentity.PSObject.Properties['DomainNameSource']
    if ($null -eq $stagedSourceProperty -or $stagedSourceProperty.Value -ne 'Shipped') {
        return $result
    }
    $domainControllerValues = @{}
    foreach ($propertyName in @('AdDomainDnsRoot', 'AdDomainNetBIOSName', 'AdDomainDistinguishedName')) {
        $domainControllerProperty = $DomainControllerIdentity.PSObject.Properties[$propertyName]
        $domainControllerValues[$propertyName] = $(if ($null -ne $domainControllerProperty) { [string]$domainControllerProperty.Value } else { '' })
    }
    if (-not $domainControllerValues['AdDomainDnsRoot'] -or -not $domainControllerValues['AdDomainNetBIOSName'] -or -not $domainControllerValues['AdDomainDistinguishedName']) {
        $result.Warning = "The DC at '$VmxFilePath' reports domain '$($DomainControllerIdentity.Domain)', and nothing named a domain for this run, but Get-ADDomain on the DC gave no domain, so its domain can't be used in place of the shipped '$($StagedIdentity.DomainName)'."
        return $result
    }
    $effectiveIdentity = $StagedIdentity.PSObject.Copy()
    $effectiveIdentity.DomainName  = $domainControllerValues['AdDomainDnsRoot']
    $effectiveIdentity.NetBIOSName = $domainControllerValues['AdDomainNetBIOSName']
    $effectiveIdentity.DomainDN    = $domainControllerValues['AdDomainDistinguishedName']
    $effectiveIdentity.ServersOU   = "OU=Servers,$($domainControllerValues['AdDomainDistinguishedName'])"
    $result.Identity = $effectiveIdentity
    $result.Warning  = "The DC at '$VmxFilePath' is in '$($effectiveIdentity.DomainName)' (NetBIOS $($effectiveIdentity.NetBIOSName)), and no build profile, new-AdDomain override file or edited global-config.ps1 names a domain, so the shipped '$($StagedIdentity.DomainName)' would apply. This run uses the DC's domain instead. To name it, set DomainName and NetBIOSName in new-AdDomain's overrides\overrides.psd1."
    return $result
}

function New-BuildManifest {
    # The build manifest held in memory: one row per fact, with the columns Section, Item,
    # Field, Value and Note, saved whole to -Path at each write point. Rows keep the order
    # they were first added, so two manifests compare line by line. The manifest observes
    # and never decides: no manifest step stops a build or changes its outcome. LogEntries
    # holds the manifest's own { Level; Message } lines until the next save logs them, so
    # none lands among the lines the run logs in a fixed order.
    # Returns { Path; Rows; LogEntries; FirstSaveDone }.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Returns a new in-memory manifest and changes nothing on disk; -WhatIf would not meaningfully apply.')]
    param (
        [Parameter(Mandatory)]
        [string]$Path
    )
    return [pscustomobject]@{
        Path          = $Path
        Rows          = [System.Collections.Generic.List[object]]::new()
        LogEntries    = [System.Collections.Generic.List[object]]::new()
        FirstSaveDone = $false
    }
}

function New-BuildManifestRow {
    # One manifest row. A $null value or note is written as an empty cell.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Returns a new row object and changes nothing; -WhatIf would not meaningfully apply.')]
    param (
        [Parameter(Mandatory)]
        [string]$Section,
        [Parameter(Mandatory)]
        [string]$Item,
        [Parameter(Mandatory)]
        [string]$Field,
        [AllowNull()]
        [AllowEmptyString()]
        [object]$Value,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Note
    )
    return [pscustomobject]@{
        Section = $Section
        Item    = $Item
        Field   = $Field
        Value   = $(if ($null -eq $Value) { '' } else { [string]$Value })
        Note    = $(if ($null -eq $Note) { '' } else { $Note })
    }
}

function Set-BuildManifestValue {
    # Adds the row for one Section, Item and Field, or replaces the one already there in
    # place, so a value set again keeps its first position. The key ignores case.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Changes only the in-memory manifest; -WhatIf would not meaningfully apply.')]
    param (
        [Parameter(Mandatory)]
        [object]$Manifest,
        [Parameter(Mandatory)]
        [string]$Section,
        [Parameter(Mandatory)]
        [string]$Item,
        [Parameter(Mandatory)]
        [string]$Field,
        [AllowNull()]
        [AllowEmptyString()]
        [object]$Value,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Note
    )
    $newRow = New-BuildManifestRow -Section $Section -Item $Item -Field $Field -Value $Value -Note $Note
    for ($rowIndex = 0; $rowIndex -lt $Manifest.Rows.Count; $rowIndex++) {
        $existingRow = $Manifest.Rows[$rowIndex]
        if ($existingRow.Section -eq $Section -and $existingRow.Item -eq $Item -and $existingRow.Field -eq $Field) {
            $Manifest.Rows[$rowIndex] = $newRow
            return
        }
    }
    $Manifest.Rows.Add($newRow)
}

function Add-BuildManifestLogEntry {
    # Holds one of the manifest's own log lines until the next save logs it. Every such
    # line starts with "Build manifest:".
    param (
        [Parameter(Mandatory)]
        [object]$Manifest,
        [Parameter(Mandatory)]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string]$Level,
        [Parameter(Mandatory)]
        [string]$Message
    )
    $Manifest.LogEntries.Add([pscustomobject]@{ Level = $Level; Message = "Build manifest: $Message" })
}

function Add-BuildManifestResult {
    # Adds what a manifest step returned, { Rows; LogEntries }, to the manifest: each row
    # through Set-BuildManifestValue, each line to the held lines.
    param (
        [Parameter(Mandatory)]
        [object]$Manifest,
        [Parameter(Mandatory)]
        [object]$Result
    )
    foreach ($resultRow in @($Result.Rows)) {
        if ($null -eq $resultRow) { continue }
        Set-BuildManifestValue -Manifest $Manifest -Section $resultRow.Section -Item $resultRow.Item -Field $resultRow.Field -Value $resultRow.Value -Note $resultRow.Note
    }
    foreach ($resultLogEntry in @($Result.LogEntries)) {
        if ($null -eq $resultLogEntry) { continue }
        $Manifest.LogEntries.Add($resultLogEntry)
    }
}

function Save-BuildManifest {
    # Writes every row held to <Path>.<ProcessId>.tmp with Export-Csv (UTF-8 with a BOM, no
    # type line), then moves it over the manifest. The first save moves without -Force, so
    # a manifest that already has the name (another run started in the same second) makes
    # the move fail. This run then writes <name>-<ProcessId>.csv from there on, with a WARN
    # naming both. Later saves move with -Force. A temporary file per process means two
    # runs never share one. Never throws: a failure is a held WARN and the build goes on.
    # Returns { Saved; Path; Error }.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes only the run''s own manifest in the logs folder; -WhatIf would not meaningfully apply.')]
    param (
        [Parameter(Mandatory)]
        [object]$Manifest,
        [int]$ProcessId = $PID
    )
    $result = [pscustomobject]@{ Saved = $false; Path = $Manifest.Path; Error = $null }
    if ($Manifest.Rows.Count -eq 0) {
        return $result
    }
    $temporaryPath = "$($Manifest.Path).$ProcessId.tmp"
    try {
        $csvEncoding = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }
        $manifestFolder = Split-Path -Path $Manifest.Path -Parent
        if ($manifestFolder -and -not (Test-Path -LiteralPath $manifestFolder -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $manifestFolder -Force -ErrorAction Stop
        }
        $Manifest.Rows | Select-Object -Property Section, Item, Field, Value, Note |
            Export-Csv -LiteralPath $temporaryPath -NoTypeInformation -Encoding $csvEncoding -ErrorAction Stop
        if ($Manifest.FirstSaveDone) {
            Move-Item -LiteralPath $temporaryPath -Destination $Manifest.Path -Force -ErrorAction Stop
        }
        else {
            try {
                Move-Item -LiteralPath $temporaryPath -Destination $Manifest.Path -ErrorAction Stop
            }
            catch {
                # The move without -Force failed. The name already being taken is the
                # signal that another run owns it, so this run takes its own name. Any
                # other failure is passed on.
                if (-not (Test-Path -LiteralPath $Manifest.Path -PathType Leaf)) { throw }
                $takenPath = $Manifest.Path
                $ownPath = Join-Path -Path (Split-Path -Path $takenPath -Parent) -ChildPath ('{0}-{1}{2}' -f [System.IO.Path]::GetFileNameWithoutExtension($takenPath), $ProcessId, [System.IO.Path]::GetExtension($takenPath))
                Move-Item -LiteralPath $temporaryPath -Destination $ownPath -Force -ErrorAction Stop
                $Manifest.Path = $ownPath
                Add-BuildManifestLogEntry -Manifest $Manifest -Level WARN -Message "'$takenPath' already exists, so this run writes '$ownPath'."
            }
            $Manifest.FirstSaveDone = $true
        }
        $result.Saved = $true
        $result.Path  = $Manifest.Path
    }
    catch {
        $result.Error = $_.Exception.Message
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        Add-BuildManifestLogEntry -Manifest $Manifest -Level WARN -Message "could not write '$($Manifest.Path)': $($result.Error) The build continues."
    }
    return $result
}

function Write-BuildManifest {
    # A write point: logs the held lines, saves the manifest, then logs any line the save
    # itself added. With -Outcome (the finally block's save) it also logs the one INFO line
    # naming the file and the outcome. Never throws.
    param (
        [Parameter(Mandatory)]
        [object]$Manifest,
        [string]$Outcome
    )
    try {
        foreach ($heldEntry in @($Manifest.LogEntries)) {
            Write-Log $heldEntry.Message -Level $heldEntry.Level
        }
        $Manifest.LogEntries.Clear()
        $saveResult = Save-BuildManifest -Manifest $Manifest
        foreach ($heldEntry in @($Manifest.LogEntries)) {
            Write-Log $heldEntry.Message -Level $heldEntry.Level
        }
        $Manifest.LogEntries.Clear()
        if ($Outcome -and $saveResult.Saved) {
            Write-Log "Build manifest: wrote '$($saveResult.Path)' (outcome $Outcome)." -Level INFO
        }
    }
    catch {
        # Logging itself failed here, so there is nowhere left to report it, and the build
        # must not stop for its record.
        try { Write-Log "Build manifest: could not write '$($Manifest.Path)': $($_.Exception.Message) The build continues." -Level WARN } catch { $null = $_ }
    }
}

function Invoke-GitQuery {
    # Runs one read-only git query against a project folder, through Invoke-NativeCommand,
    # as `git --no-optional-locks -C <folder> <arguments>`. --no-optional-locks keeps a
    # status query from writing a refreshed index into the project's .git, where the lock
    # could make another git process fail. git's own "error:" lines don't throw here, and a
    # non-zero exit is returned rather than thrown. A query that runs past -TimeoutSeconds
    # is killed, and that does throw. Returns { ExitCode; Output }, with stdout and stderr as
    # one array.
    param (
        [Parameter(Mandatory)]
        [string]$GitPath,
        [Parameter(Mandatory)]
        [string]$ProjectPath,
        [Parameter(Mandatory)]
        [string[]]$ArgumentList,
        [ValidateRange(1, 3600)]
        [int]$TimeoutSeconds = 15
    )
    $gitArgumentList = @('--no-optional-locks', '-C', $ProjectPath) + $ArgumentList
    return Invoke-NativeCommand -FilePath $GitPath -ArgumentList $gitArgumentList -OperationName ($ArgumentList -join ' ') `
        -AllowNonZeroExit -IgnoreOutputErrorText -TimeoutSeconds $TimeoutSeconds
}

function Get-ProjectSourceState {
    # The build manifest's Project rows for one project folder: Path (a full path), Commit
    # and WorkingTree. Commit is the 40-character hash HEAD names, or none or unknown with
    # the reason in its Note. WorkingTree is Clean or Modified, with the count of git status
    # entries, or none or unknown. Three cases, in order:
    #   - no .git (folder or file) at the folder's own root: not a git checkout, an INFO,
    #     and git is never run. A release copy is normal use, and a copy extracted inside
    #     some other checkout lands here too, so that checkout's commit is never recorded
    #   - a .git, and -GitPath $null (git isn't installed): unknown, a WARN
    #   - otherwise three queries: the top level git reports, compared with the folder
    #     after both are made full paths (git prints forward slashes), then HEAD, then
    #     `status --porcelain --untracked-files=normal`, counting only lines in porcelain
    #     entry form, so a warning git writes to stderr is never counted as a change
    # A modified tree is an INFO, not a WARN. -Note goes on the Commit row, joined to any
    # reason of its own. Never throws. Returns { Rows; LogEntries }.
    param (
        [Parameter(Mandatory)]
        [string]$ProjectName,
        [Parameter(Mandatory)]
        [string]$ProjectPath,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$GitPath,
        [string]$Note,
        [int]$TimeoutSeconds = 15
    )
    $rows       = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $logEntries = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $joinNote = { param ([string]$First, [string]$Second) @(@($First, $Second) | Where-Object { $_ }) -join '; ' }
    $folderText = $ProjectPath
    try { $folderText = ConvertTo-FullFileSystemPath -Path $ProjectPath } catch { $folderText = $ProjectPath }
    $folderText = $folderText.TrimEnd('\')
    $rows.Add((New-BuildManifestRow -Section 'Project' -Item $ProjectName -Field 'Path' -Value $folderText))
    $commitValue = 'unknown'
    $commitNote  = ''
    $treeValue   = 'unknown'
    $treeNote    = ''
    try {
        if (-not (Test-Path -LiteralPath (Join-Path -Path $folderText -ChildPath '.git'))) {
            $commitValue = 'none'; $commitNote = 'not a git checkout'; $treeValue = 'none'; $treeNote = 'not a git checkout'
            $logEntries.Add([pscustomobject]@{ Level = 'INFO'; Message = "Build manifest: $ProjectName at '$folderText' is not a git checkout, so no commit is recorded." })
        }
        elseif (-not $GitPath) {
            $commitNote = 'git not found'; $treeNote = 'git not found'
            $logEntries.Add([pscustomobject]@{ Level = 'WARN'; Message = "Build manifest: could not read the commit of $ProjectName at '$folderText': git not found." })
        }
        else {
            $firstLineOf = { param ([object[]]$Output) $line = @($Output | Where-Object { $_ }) | Select-Object -First 1; if ($line) { [string]$line } else { 'no output' } }
            $topLevelQuery = Invoke-GitQuery -GitPath $GitPath -ProjectPath $folderText -ArgumentList @('rev-parse', '--show-toplevel') -TimeoutSeconds $TimeoutSeconds
            $topLevelLine = @($topLevelQuery.Output | Where-Object { $_ -and $_ -notmatch '^(warning|error|fatal):' }) | Select-Object -First 1
            if ($topLevelQuery.ExitCode -ne 0 -or -not $topLevelLine) {
                $commitNote = & $firstLineOf $topLevelQuery.Output; $treeNote = $commitNote
                $logEntries.Add([pscustomobject]@{ Level = 'WARN'; Message = "Build manifest: could not read the commit of $ProjectName at '$folderText': $commitNote." })
            }
            else {
                $topLevelText = (ConvertTo-FullFileSystemPath -Path ([string]$topLevelLine)).TrimEnd('\')
                if ($topLevelText -ne $folderText) {
                    $commitValue = 'none'; $treeValue = 'none'
                    $commitNote = "git reports the top level '$topLevelText'"; $treeNote = $commitNote
                    $logEntries.Add([pscustomobject]@{ Level = 'WARN'; Message = "Build manifest: git reports the top level '$topLevelText' for $ProjectName at '$folderText', so no commit is recorded." })
                }
                else {
                    $headQuery = Invoke-GitQuery -GitPath $GitPath -ProjectPath $folderText -ArgumentList @('rev-parse', '--verify', 'HEAD') -TimeoutSeconds $TimeoutSeconds
                    $headLine = @($headQuery.Output | Where-Object { $_ -match '\A[0-9a-f]{40}([0-9a-f]{24})?\z' }) | Select-Object -First 1
                    if ($headQuery.ExitCode -eq 0 -and $headLine) {
                        $commitValue = [string]$headLine
                    }
                    else {
                        $commitNote = & $firstLineOf $headQuery.Output
                        $logEntries.Add([pscustomobject]@{ Level = 'WARN'; Message = "Build manifest: could not read the commit of $ProjectName at '$folderText': $commitNote." })
                    }
                    $statusQuery = Invoke-GitQuery -GitPath $GitPath -ProjectPath $folderText -ArgumentList @('status', '--porcelain', '--untracked-files=normal') -TimeoutSeconds $TimeoutSeconds
                    if ($statusQuery.ExitCode -ne 0) {
                        $treeNote = & $firstLineOf $statusQuery.Output
                        $logEntries.Add([pscustomobject]@{ Level = 'WARN'; Message = "Build manifest: could not read the working tree of $ProjectName at '$folderText': $treeNote." })
                    }
                    else {
                        # Porcelain v1 entries are two status characters and a space.
                        $statusEntryCount = @($statusQuery.Output | Where-Object { $_ -match '\A.. ' }).Count
                        if ($statusEntryCount -eq 0) {
                            $treeValue = 'Clean'
                        }
                        else {
                            $treeValue = 'Modified'; $treeNote = "$statusEntryCount entries in git status"
                            $logEntries.Add([pscustomobject]@{ Level = 'INFO'; Message = "Build manifest: $ProjectName at '$folderText' has $statusEntryCount entries in git status, so commit $commitValue may not describe every file." })
                        }
                    }
                }
            }
        }
    }
    catch {
        $commitValue = 'unknown'; $treeValue = 'unknown'
        $commitNote = ([string]$_.Exception.Message -split '\r?\n')[0]; $treeNote = $commitNote
        $logEntries.Add([pscustomobject]@{ Level = 'WARN'; Message = "Build manifest: could not read the commit of $ProjectName at '$folderText': $commitNote" })
    }
    $rows.Add((New-BuildManifestRow -Section 'Project' -Item $ProjectName -Field 'Commit' -Value $commitValue -Note (& $joinNote $commitNote $Note)))
    $rows.Add((New-BuildManifestRow -Section 'Project' -Item $ProjectName -Field 'WorkingTree' -Value $treeValue -Note $treeNote))
    return [pscustomobject]@{ Rows = $rows.ToArray(); LogEntries = $logEntries.ToArray() }
}

function Get-ScriptVersionRow {
    # One Script row of the build manifest: the header Version of the script at -Path, read
    # the way the version handshake reads it (Read-ScriptSetting parses the file and runs
    # nothing), so the manifest and the handshake's log line never disagree. -KnownVersion
    # is for build-lab.ps1, whose $scriptVersion is what its starting line prints. A header
    # with no Version line gives none, and a file that is missing or doesn't parse gives
    # unknown, each with a WARN. Returns { Rows; LogEntries }.
    param (
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Item,
        [string]$KnownVersion,
        [string]$Note
    )
    $logEntries = @()
    if ($KnownVersion) {
        $versionValue = $KnownVersion
    }
    else {
        $scriptSetting = Read-ScriptSetting -Path $Path
        if ($scriptSetting.Error) {
            $versionValue = 'unknown'
            $logEntries += [pscustomobject]@{ Level = 'WARN'; Message = "Build manifest: could not read the version of '$Path': $($scriptSetting.Error)" }
        }
        elseif (-not $scriptSetting.Version) {
            $versionValue = 'none'
            $logEntries += [pscustomobject]@{ Level = 'WARN'; Message = "Build manifest: '$Path' has no Version line in its header, so its version is recorded as none." }
        }
        else {
            $versionValue = [string]$scriptSetting.Version
        }
    }
    return [pscustomobject]@{ Rows = @(New-BuildManifestRow -Section 'Script' -Item $Item -Field 'Version' -Value $versionValue -Note $Note); LogEntries = $logEntries }
}

function Get-ProjectScriptVersionRow {
    # The Script rows for one project, one per script, each with Item
    # <project>\<path inside the project>. -MainScriptName gives that script and each
    # include\*.ps1 (build-lab and the VM builder). Without it, every .ps1 in the folder
    # outside tests\ (the staged new-AdDomain), found by globbing so a new file needs no
    # code change. -KnownVersion goes to the main script's row. Never throws.
    # Returns { Rows; LogEntries }.
    param (
        [Parameter(Mandatory)]
        [string]$ProjectName,
        [Parameter(Mandatory)]
        [string]$ProjectPath,
        [string]$MainScriptName,
        [string]$KnownVersion,
        [string]$Note
    )
    $rows       = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $logEntries = New-Object -TypeName 'System.Collections.Generic.List[object]'
    try {
        $projectRoot = (ConvertTo-FullFileSystemPath -Path $ProjectPath).TrimEnd('\')
        $scriptPaths = @()
        if ($MainScriptName) {
            $scriptPaths += Join-Path -Path $projectRoot -ChildPath $MainScriptName
            $includePath = Join-Path -Path $projectRoot -ChildPath 'include'
            if (Test-Path -LiteralPath $includePath -PathType Container) {
                $scriptPaths += @(Get-ChildItem -LiteralPath $includePath -Filter '*.ps1' -File -ErrorAction Stop | Sort-Object -Property Name | ForEach-Object { $_.FullName })
            }
        }
        else {
            $testsPrefix = (Join-Path -Path $projectRoot -ChildPath 'tests') + '\'
            $scriptPaths = @(Get-ChildItem -LiteralPath $projectRoot -Filter '*.ps1' -File -Recurse -ErrorAction Stop |
                Where-Object { -not $_.FullName.StartsWith($testsPrefix, [System.StringComparison]::OrdinalIgnoreCase) } |
                ForEach-Object { $_.FullName } | Sort-Object)
        }
        foreach ($scriptPath in $scriptPaths) {
            $relativePath = $scriptPath.Substring($projectRoot.Length).TrimStart('\')
            $scriptKnownVersion = if ($MainScriptName -and $relativePath -eq $MainScriptName) { $KnownVersion } else { $null }
            $scriptRow = Get-ScriptVersionRow -Path $scriptPath -Item "$ProjectName\$relativePath" -KnownVersion $scriptKnownVersion -Note $Note
            foreach ($row in @($scriptRow.Rows)) { $rows.Add($row) }
            foreach ($entry in @($scriptRow.LogEntries)) { $logEntries.Add($entry) }
        }
    }
    catch {
        $logEntries.Add([pscustomobject]@{ Level = 'WARN'; Message = "Build manifest: could not list the scripts of $ProjectName at '$ProjectPath': $($_.Exception.Message)" })
    }
    return [pscustomobject]@{ Rows = $rows.ToArray(); LogEntries = $logEntries.ToArray() }
}

function Get-IsoFileIdentity {
    # The build manifest's Iso rows for one ISO: Path (a full path), Length,
    # LastWriteTimeUtc and Sha256, under -Item. Hashing an 8 GB ISO takes seconds to a minute
    # or more, so the hash is kept in a cache, -CachePath, one row per ISO keyed by its full
    # path, length and LastWriteTimeUtc (as ticks). A row is used only when all three match
    # the file now, and the Sha256 Note then says "cached <time>", so a reader can tell a
    # remembered hash from one computed this run ("computed in N s"). Deleting the cache
    # makes the next run hash every ISO again. A cache that can't be read or doesn't have
    # the cache's columns is a WARN and is written afresh, a cache that can't be written is
    # a WARN and the hash is still recorded, and a file that can't be hashed gives Sha256
    # unknown and a WARN. A missing file gives one Path row, "not found", and -MissingText
    # as an INFO when it is given. Never throws. Returns { Rows; LogEntries }.
    param (
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Item,
        [Parameter(Mandatory)]
        [string]$CachePath,
        [string]$Note,
        [string]$MissingText
    )
    $rows       = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $logEntries = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $cacheColumns = 'Path,Length,LastWriteTimeUtcTicks,Sha256,ComputedUtc'
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            $rows.Add((New-BuildManifestRow -Section 'Iso' -Item $Item -Field 'Path' -Value 'not found' -Note $Note))
            if ($MissingText) { $logEntries.Add([pscustomobject]@{ Level = 'INFO'; Message = "Build manifest: $MissingText" }) }
            return [pscustomobject]@{ Rows = $rows.ToArray(); LogEntries = $logEntries.ToArray() }
        }
        $isoFile = Get-Item -LiteralPath $Path -ErrorAction Stop
        $rows.Add((New-BuildManifestRow -Section 'Iso' -Item $Item -Field 'Path' -Value $isoFile.FullName -Note $Note))
        $rows.Add((New-BuildManifestRow -Section 'Iso' -Item $Item -Field 'Length' -Value ([string]$isoFile.Length)))
        $rows.Add((New-BuildManifestRow -Section 'Iso' -Item $Item -Field 'LastWriteTimeUtc' -Value $isoFile.LastWriteTimeUtc.ToString('o')))
        $lengthText = [string]$isoFile.Length
        $ticksText  = [string]$isoFile.LastWriteTimeUtc.Ticks

        $cacheRows = @()
        if (Test-Path -LiteralPath $CachePath -PathType Leaf) {
            try {
                $cacheRows = @(Import-Csv -LiteralPath $CachePath -Encoding UTF8 -ErrorAction Stop)
                if ($cacheRows.Count -gt 0 -and (@($cacheRows[0].PSObject.Properties.Name) -join ',') -cne $cacheColumns) {
                    throw "its columns aren't $cacheColumns"
                }
            }
            catch {
                $cacheRows = @()
                $logEntries.Add([pscustomobject]@{ Level = 'WARN'; Message = "Build manifest: the ISO hash cache '$CachePath' can't be read ($($_.Exception.Message)), so '$($isoFile.FullName)' is hashed again and the cache is written afresh." })
            }
        }
        $cachedRow = @($cacheRows | Where-Object { $_.Path -eq $isoFile.FullName -and $_.Length -ceq $lengthText -and $_.LastWriteTimeUtcTicks -ceq $ticksText -and $_.Sha256 -match '\A[0-9A-F]{64}\z' }) | Select-Object -First 1
        if ($null -ne $cachedRow) {
            $rows.Add((New-BuildManifestRow -Section 'Iso' -Item $Item -Field 'Sha256' -Value $cachedRow.Sha256 -Note "cached $($cachedRow.ComputedUtc)"))
            return [pscustomobject]@{ Rows = $rows.ToArray(); LogEntries = $logEntries.ToArray() }
        }

        $hashWatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $isoHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $isoFile.FullName -ErrorAction Stop).Hash
        }
        catch {
            $rows.Add((New-BuildManifestRow -Section 'Iso' -Item $Item -Field 'Sha256' -Value 'unknown'))
            $logEntries.Add([pscustomobject]@{ Level = 'WARN'; Message = "Build manifest: could not hash '$($isoFile.FullName)': $($_.Exception.Message)" })
            return [pscustomobject]@{ Rows = $rows.ToArray(); LogEntries = $logEntries.ToArray() }
        }
        $hashSeconds = [math]::Round($hashWatch.Elapsed.TotalSeconds, 1)
        $rows.Add((New-BuildManifestRow -Section 'Iso' -Item $Item -Field 'Sha256' -Value $isoHash -Note "computed in $hashSeconds s"))
        try {
            $newCacheRows = @($cacheRows | Where-Object { $_.Path -ne $isoFile.FullName }) + @([pscustomobject]@{
                Path = $isoFile.FullName; Length = $lengthText; LastWriteTimeUtcTicks = $ticksText; Sha256 = $isoHash; ComputedUtc = (Get-Date).ToUniversalTime().ToString('o') })
            $csvEncoding = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }
            $newCacheRows | Select-Object -Property Path, Length, LastWriteTimeUtcTicks, Sha256, ComputedUtc |
                Export-Csv -LiteralPath $CachePath -NoTypeInformation -Encoding $csvEncoding -ErrorAction Stop
        }
        catch {
            $logEntries.Add([pscustomobject]@{ Level = 'WARN'; Message = "Build manifest: could not write the ISO hash cache '$CachePath': $($_.Exception.Message) The next run hashes '$($isoFile.FullName)' again." })
        }
    }
    catch {
        $logEntries.Add([pscustomobject]@{ Level = 'WARN'; Message = "Build manifest: could not hash '$Path': $($_.Exception.Message)" })
        if (@($rows | Where-Object { $_.Field -eq 'Sha256' }).Count -eq 0) {
            $rows.Add((New-BuildManifestRow -Section 'Iso' -Item $Item -Field 'Sha256' -Value 'unknown'))
        }
    }
    return [pscustomobject]@{ Rows = $rows.ToArray(); LogEntries = $logEntries.ToArray() }
}

function Get-OverrideFileRow {
    # The build manifest's Override rows for one project's override file: Path (the file a
    # user edits, as a full path) and Sha256, the hash of the file's bytes, which is the
    # one the reader's own INFO line names. The hash is recorded whether or not the file
    # holds a secret key, and no value from the file is ever a row. With no file, both rows
    # are none, with Note "no override file", and no line, since the reader logs its own.
    # The hash comes from -KnownSha256 when the caller already read the file (build-lab's
    # own), and otherwise from -HashPath, the file the run uses, which for new-AdDomain is
    # the staged copy the guest gets while Path names its source. With
    # -StagedProjectPath and -SourceProjectPath (new-AdDomain), each staged
    # overrides\config\<name>.csv that replaces a shipped config\<name>.csv gets a row group
    # of its own, Override,new-AdDomain\config\<name>.csv, Path the source file, Sha256 the
    # staged copy's. A file there with any other name gets no row, because new-AdDomain
    # ignores it with a WARN of its own. A file that can't be hashed gives Sha256 unknown
    # and a WARN. -Note goes on every row. Never throws. Returns { Rows; LogEntries }.
    param (
        [Parameter(Mandatory)]
        [string]$ProjectName,
        [Parameter(Mandatory)]
        [string]$NamedPath,
        [string]$HashPath,
        [switch]$UseKnownSha256,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$KnownSha256,
        [string]$StagedProjectPath,
        [string]$SourceProjectPath,
        [string]$Note
    )
    $rows       = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $logEntries = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $joinNote = { param ([string]$First, [string]$Second) @(@($First, $Second) | Where-Object { $_ }) -join '; ' }
    $hashOf = {
        param ([string]$FilePath)
        try { (Get-FileHash -Algorithm SHA256 -LiteralPath $FilePath -ErrorAction Stop).Hash }
        catch {
            $logEntries.Add([pscustomobject]@{ Level = 'WARN'; Message = "Build manifest: could not hash '$FilePath': $($_.Exception.Message)" })
            'unknown'
        }
    }
    try {
        if (-not $HashPath) { $HashPath = $NamedPath }
        $namedFullPath = $NamedPath
        try { $namedFullPath = ConvertTo-FullFileSystemPath -Path $NamedPath } catch { $namedFullPath = $NamedPath }
        if (-not (Test-Path -LiteralPath $HashPath -PathType Leaf)) {
            $rows.Add((New-BuildManifestRow -Section 'Override' -Item $ProjectName -Field 'Path' -Value 'none' -Note (& $joinNote 'no override file' $Note)))
            $rows.Add((New-BuildManifestRow -Section 'Override' -Item $ProjectName -Field 'Sha256' -Value 'none' -Note $Note))
        }
        else {
            $fileHash = if ($UseKnownSha256) { $(if ($KnownSha256) { $KnownSha256 } else { 'unknown' }) } else { & $hashOf $HashPath }
            $rows.Add((New-BuildManifestRow -Section 'Override' -Item $ProjectName -Field 'Path' -Value $namedFullPath -Note $Note))
            $rows.Add((New-BuildManifestRow -Section 'Override' -Item $ProjectName -Field 'Sha256' -Value $fileHash -Note $Note))
        }
        if ($StagedProjectPath -and $SourceProjectPath) {
            $stagedCsvFolder = Join-Path -Path $StagedProjectPath -ChildPath 'overrides\config'
            $shippedCsvFolder = Join-Path -Path $StagedProjectPath -ChildPath 'config'
            if (Test-Path -LiteralPath $stagedCsvFolder -PathType Container) {
                $shippedCsvNames = @(Get-ChildItem -LiteralPath $shippedCsvFolder -Filter '*.csv' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
                foreach ($stagedCsv in @(Get-ChildItem -LiteralPath $stagedCsvFolder -Filter '*.csv' -File -ErrorAction Stop | Sort-Object -Property Name)) {
                    $shippedName = @($shippedCsvNames | Where-Object { $_ -eq $stagedCsv.Name }) | Select-Object -First 1
                    if (-not $shippedName) { continue }
                    $csvItem = "$ProjectName\config\$shippedName"
                    $sourceCsvPath = Join-Path -Path (ConvertTo-FullFileSystemPath -Path $SourceProjectPath) -ChildPath "overrides\config\$($stagedCsv.Name)"
                    $rows.Add((New-BuildManifestRow -Section 'Override' -Item $csvItem -Field 'Path' -Value $sourceCsvPath -Note $Note))
                    $rows.Add((New-BuildManifestRow -Section 'Override' -Item $csvItem -Field 'Sha256' -Value (& $hashOf $stagedCsv.FullName) -Note $Note))
                }
            }
        }
    }
    catch {
        $logEntries.Add([pscustomobject]@{ Level = 'WARN'; Message = "Build manifest: could not hash '$HashPath': $($_.Exception.Message)" })
        if (@($rows | Where-Object { $_.Item -eq $ProjectName -and $_.Field -eq 'Sha256' }).Count -eq 0) {
            $rows.Add((New-BuildManifestRow -Section 'Override' -Item $ProjectName -Field 'Path' -Value $NamedPath -Note $Note))
            $rows.Add((New-BuildManifestRow -Section 'Override' -Item $ProjectName -Field 'Sha256' -Value 'unknown' -Note $Note))
        }
    }
    return [pscustomobject]@{ Rows = $rows.ToArray(); LogEntries = $logEntries.ToArray() }
}

function Get-InstallIsoItemName {
    # The Item of the install ISO's rows: its file name. The VMware Tools ISO's rows use the
    # Item windows.iso, so an install ISO with that name gets "(install ISO) <name>", and
    # neither row group can replace the other.
    param (
        [Parameter(Mandatory)]
        [string]$IsoPath
    )
    $isoFileName = Split-Path -Path $IsoPath -Leaf
    if ($isoFileName -eq 'windows.iso') { return "(install ISO) $isoFileName" }
    return $isoFileName
}

function Get-BuildManifestField {
    # A field of a hook object or a guest answer, or $null when the object or the field
    # isn't there, read without tripping strict mode.
    param (
        [AllowNull()]
        [object]$InputObject,
        [Parameter(Mandatory)]
        [string]$Name
    )
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Add-BuildManifestRunRow {
    # The rows made right after the starting line: the Run rows (ManifestFormat, Mode,
    # Started, Ended empty while the run goes on, Outcome Running, and the two log file
    # names), the one Snapshot row, and in -AddMemberServers and -MoveMemberServers the
    # one population row, NotApplicable, since neither mode runs directory population.
    param (
        [Parameter(Mandatory)]
        [object]$Manifest,
        [Parameter(Mandatory)]
        [string]$ParameterSetName,
        [Parameter(Mandatory)]
        [string]$TextLogPath,
        [Parameter(Mandatory)]
        [string]$ErrorLogPath,
        [Parameter(Mandatory)]
        [string]$Started
    )
    $modeName = switch ($ParameterSetName) {
        'GuestOnly'   { 'SkipVmBuild' }
        'AddMembers'  { 'AddMemberServers' }
        'MoveMembers' { 'MoveMemberServers' }
        default       { $ParameterSetName }
    }
    Set-BuildManifestValue -Manifest $Manifest -Section 'Run' -Item 'build-lab' -Field 'ManifestFormat' -Value '1'
    Set-BuildManifestValue -Manifest $Manifest -Section 'Run' -Item 'build-lab' -Field 'Mode' -Value $modeName
    Set-BuildManifestValue -Manifest $Manifest -Section 'Run' -Item 'build-lab' -Field 'Started' -Value $Started
    Set-BuildManifestValue -Manifest $Manifest -Section 'Run' -Item 'build-lab' -Field 'Ended' -Value ''
    Set-BuildManifestValue -Manifest $Manifest -Section 'Run' -Item 'build-lab' -Field 'Outcome' -Value 'Running'
    Set-BuildManifestValue -Manifest $Manifest -Section 'Run' -Item 'build-lab' -Field 'TextLog' -Value (Split-Path -Path $TextLogPath -Leaf)
    Set-BuildManifestValue -Manifest $Manifest -Section 'Run' -Item 'build-lab' -Field 'ErrorLog' -Value (Split-Path -Path $ErrorLogPath -Leaf)
    Set-BuildManifestValue -Manifest $Manifest -Section 'Snapshot' -Item '(none)' -Field 'Status' -Value 'NotTaken' -Note 'build-lab takes no snapshots yet'
    if ($modeName -in @('AddMemberServers', 'MoveMemberServers')) {
        Set-BuildManifestValue -Manifest $Manifest -Section 'Build' -Item 'population' -Field 'Outcome' -Value 'NotApplicable' -Note "-$modeName runs no directory population"
    }
}

function Add-BuildManifestProfileRow {
    # The Profile rows, from Set-StagedBuildProfile's result: under the profile's file name,
    # or (none), its Source (-ProfilePath, source new-AdDomain or none, with its row of the
    # README's 'Which profile a run uses' table in the Note), its Path, and the SHA-256 of
    # the staged copy the guest gets, or none for both when the run uses no profile.
    param (
        [Parameter(Mandatory)]
        [object]$Manifest,
        [Parameter(Mandatory)]
        [object]$Selection
    )
    $originPath = [string](Get-BuildManifestField -InputObject $Selection -Name 'OriginPath')
    $profileItem = if ($originPath) { Split-Path -Path $originPath -Leaf } else { '(none)' }
    $selectionRow = [string](Get-BuildManifestField -InputObject $Selection -Name 'Row')
    $profileSource = switch ($selectionRow) {
        '1'     { 'none' }
        '2'     { 'source new-AdDomain' }
        default { '-ProfilePath' }
    }
    $profileHash = [string](Get-BuildManifestField -InputObject $Selection -Name 'Sha256')
    Set-BuildManifestValue -Manifest $Manifest -Section 'Profile' -Item $profileItem -Field 'Source' -Value $profileSource -Note "row $selectionRow of the README's 'Which profile a run uses' table"
    Set-BuildManifestValue -Manifest $Manifest -Section 'Profile' -Item $profileItem -Field 'Path' -Value $(if ($originPath) { $originPath } else { 'none' })
    Set-BuildManifestValue -Manifest $Manifest -Section 'Profile' -Item $profileItem -Field 'Sha256' -Value $(if ($profileHash) { $profileHash } else { 'none' })
}

function Add-BuildManifestToolRow {
    # The Tool rows for the vmrun.exe the run found: its full path and its file's
    # ProductVersion, the Workstation release in use. A file with no version information
    # gives unknown and a WARN.
    param (
        [Parameter(Mandatory)]
        [object]$Manifest,
        [Parameter(Mandatory)]
        [string]$VmrunPath
    )
    Set-BuildManifestValue -Manifest $Manifest -Section 'Tool' -Item 'vmrun.exe' -Field 'Path' -Value $VmrunPath
    $productVersion = $null
    try { $productVersion = [string](Get-Item -LiteralPath $VmrunPath -ErrorAction Stop).VersionInfo.ProductVersion } catch { $productVersion = $null }
    if ($productVersion) {
        Set-BuildManifestValue -Manifest $Manifest -Section 'Tool' -Item 'vmrun.exe' -Field 'ProductVersion' -Value $productVersion.Trim()
    }
    else {
        Set-BuildManifestValue -Manifest $Manifest -Section 'Tool' -Item 'vmrun.exe' -Field 'ProductVersion' -Value 'unknown'
        Add-BuildManifestLogEntry -Manifest $Manifest -Level WARN -Message "'$VmrunPath' has no version information, so its ProductVersion is recorded as unknown."
    }
}

function Add-BuildManifestIsoRow {
    # The Iso rows of a run that builds VMs: the install ISO, the VMware Tools ISO
    # (windows.iso beside vmrun.exe, the file the VM builder attaches when it is there),
    # each through the hash cache, and one row for the answer ISO, which is never hashed
    # or named because it holds the Administrator password.
    param (
        [Parameter(Mandatory)]
        [object]$Manifest,
        [Parameter(Mandatory)]
        [string]$IsoPath,
        [Parameter(Mandatory)]
        [string]$VmrunPath,
        [Parameter(Mandatory)]
        [string]$CachePath
    )
    $installIso = Get-IsoFileIdentity -Path $IsoPath -Item (Get-InstallIsoItemName -IsoPath $IsoPath) -CachePath $CachePath
    Add-BuildManifestResult -Manifest $Manifest -Result $installIso
    $toolsIsoPath = Join-Path -Path (Split-Path -Path $VmrunPath -Parent) -ChildPath 'windows.iso'
    $toolsIso = Get-IsoFileIdentity -Path $toolsIsoPath -Item 'windows.iso' -CachePath $CachePath -Note 'the file the builder looks for' `
        -MissingText "the VMware Tools ISO '$toolsIsoPath' is not there, so its Path row says not found."
    Add-BuildManifestResult -Manifest $Manifest -Result $toolsIso
    Set-BuildManifestValue -Manifest $Manifest -Section 'Iso' -Item '(answer ISO)' -Field 'Status' -Value 'NotRecorded' -Note 'holds the Administrator password'
}

function Set-BuildManifestDomainRow {
    # The Build,domain rows: DomainName, with the source new-AdDomain gives it
    # (DomainNameSource) in its Note, NetBIOSName, and EffectiveValues, the validator's
    # summary line as the log printed it. Set again, in place, once an add or move run
    # takes the DC's own domain (-UsedDomainControllerDomain): DomainName's Note then says
    # so, and EffectiveValues keeps the staged summary with a Note saying this run used the
    # DC's domain instead.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Changes only the in-memory manifest; -WhatIf would not meaningfully apply.')]
    param (
        [Parameter(Mandatory)]
        [object]$Manifest,
        [Parameter(Mandatory)]
        [object]$Identity,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$EffectiveValues,
        [switch]$UsedDomainControllerDomain
    )
    $domainSource = [string](Get-BuildManifestField -InputObject $Identity -Name 'DomainNameSource')
    $domainNote = if ($UsedDomainControllerDomain) { "the DC's domain" } elseif ($domainSource) { $domainSource } else { 'source not reported' }
    Set-BuildManifestValue -Manifest $Manifest -Section 'Build' -Item 'domain' -Field 'DomainName' -Value (Get-BuildManifestField -InputObject $Identity -Name 'DomainName') -Note $domainNote
    Set-BuildManifestValue -Manifest $Manifest -Section 'Build' -Item 'domain' -Field 'NetBIOSName' -Value (Get-BuildManifestField -InputObject $Identity -Name 'NetBIOSName')
    Set-BuildManifestValue -Manifest $Manifest -Section 'Build' -Item 'domain' -Field 'EffectiveValues' -Value $EffectiveValues `
        -Note $(if ($UsedDomainControllerDomain) { "staged configuration; this run used the DC's domain" } else { '' })
}

function Add-BuildManifestNetworkRow {
    # The Build,network rows from the network hook (New-NetworkHookObject): NetworkType and
    # SubnetMask, the values the VMs got, each with its source in words in the Note. Where
    # the hook reports the network unused (NetworkUsed $false: -SkipVmBuild and
    # -MoveMemberServers), both rows are "not collected", with no line. A used network
    # whose hook lacks a field records that field as not collected, with one WARN.
    param (
        [Parameter(Mandatory)]
        [object]$Manifest,
        [AllowNull()]
        [object]$NetworkHook
    )
    $networkUsed = Get-BuildManifestField -InputObject $NetworkHook -Name 'NetworkUsed'
    if ($null -ne $networkUsed -and -not [bool]$networkUsed) {
        Set-BuildManifestValue -Manifest $Manifest -Section 'Build' -Item 'network' -Field 'NetworkType' -Value 'not collected' -Note 'network not used in this mode'
        Set-BuildManifestValue -Manifest $Manifest -Section 'Build' -Item 'network' -Field 'SubnetMask' -Value 'not collected' -Note 'network not used in this mode'
        return
    }
    $missingFields = @()
    if ($null -eq $networkUsed) { $missingFields += 'NetworkUsed' }
    $fieldValues = @{}
    foreach ($fieldName in @('NetworkType', 'NetworkSource', 'SubnetMask', 'SubnetMaskSource')) {
        $fieldValue = Get-BuildManifestField -InputObject $NetworkHook -Name $fieldName
        if ($null -eq $fieldValue -or [string]$fieldValue -eq '') { $missingFields += $fieldName; $fieldValues[$fieldName] = $null } else { $fieldValues[$fieldName] = [string]$fieldValue }
    }
    $valueOrMissing = { param ([string]$FieldName) if ($null -ne $fieldValues[$FieldName]) { $fieldValues[$FieldName] } else { 'not collected' } }
    $noteOrMissing = { param ([string]$FieldName) if ($null -ne $fieldValues[$FieldName]) { $fieldValues[$FieldName] } else { "not collected, the network hook has no $FieldName" } }
    Set-BuildManifestValue -Manifest $Manifest -Section 'Build' -Item 'network' -Field 'NetworkType' -Value (& $valueOrMissing 'NetworkType') -Note (& $noteOrMissing 'NetworkSource')
    Set-BuildManifestValue -Manifest $Manifest -Section 'Build' -Item 'network' -Field 'SubnetMask' -Value (& $valueOrMissing 'SubnetMask') -Note (& $noteOrMissing 'SubnetMaskSource')
    if ($missingFields.Count -gt 0) {
        Add-BuildManifestLogEntry -Manifest $Manifest -Level WARN -Message "the network hook has no $($missingFields -join ', '), so those network values are recorded as not collected."
    }
}

function Add-BuildManifestPopulationRow {
    # The Build,population rows and GuestLogs,population,Folder, from the population
    # outcome hook ($populationOutcome) and the settings hook ($populationSettings), made
    # before a failed population ends the run. Deferred is one Outcome row and nothing else.
    # For the four outcomes after a launch: the Outcome with the launch ID in its Note, the
    # seed, Population and DomainAdminCount with their sources, and the folder the results
    # were retrieved to. The seed comes from the terminal marker when it holds one, with
    # the marker's RandomSeedSource as its Note. Otherwise a given seed comes from the
    # settings hook with its source there, and a seed still to be drawn (Random) is
    # "not drawn", with a Note naming the outcome. No line for any outcome, since the run
    # logs the population itself. A hook that lacks a value records it as not collected,
    # with one WARN.
    param (
        [Parameter(Mandatory)]
        [object]$Manifest,
        [AllowNull()]
        [object]$Outcome,
        [AllowNull()]
        [object]$Settings
    )
    $outcomeName = [string](Get-BuildManifestField -InputObject $Outcome -Name 'Outcome')
    if (-not $outcomeName) {
        Set-BuildManifestValue -Manifest $Manifest -Section 'Build' -Item 'population' -Field 'Outcome' -Value 'not collected' -Note 'the population outcome hook has no Outcome'
        Add-BuildManifestLogEntry -Manifest $Manifest -Level WARN -Message 'the population outcome hook has no Outcome, so it is recorded as not collected.'
        return
    }
    if ($outcomeName -eq 'Deferred') {
        Set-BuildManifestValue -Manifest $Manifest -Section 'Build' -Item 'population' -Field 'Outcome' -Value 'Deferred' -Note '-DeferPopulation leaves directory population to the logon task'
        return
    }
    $launchId = [string](Get-BuildManifestField -InputObject $Outcome -Name 'LaunchId')
    Set-BuildManifestValue -Manifest $Manifest -Section 'Build' -Item 'population' -Field 'Outcome' -Value $outcomeName -Note "LaunchId $launchId"

    $missingValues = @()
    $marker = Get-BuildManifestField -InputObject $Outcome -Name 'Marker'
    $markerSeed = Get-BuildManifestField -InputObject $marker -Name 'RandomSeed'
    $settingsSource = Get-BuildManifestField -InputObject $Settings -Name 'PopulationSource'
    $sourceOf = { param ([string]$SettingName) $sourceName = Get-BuildManifestField -InputObject $settingsSource -Name $SettingName; if ($sourceName) { [string]$sourceName } else { 'Default' } }
    if ($null -ne $markerSeed -and [string]$markerSeed -ne '') {
        $markerSeedSource = [string](Get-BuildManifestField -InputObject $marker -Name 'RandomSeedSource')
        Set-BuildManifestValue -Manifest $Manifest -Section 'Build' -Item 'population' -Field 'RandomSeed' -Value $markerSeed -Note $markerSeedSource
    }
    else {
        $settingsSeed = Get-BuildManifestField -InputObject $Settings -Name 'PopulationSeed'
        if ($null -eq $settingsSeed -or [string]$settingsSeed -eq '') {
            $missingValues += 'PopulationSeed'
            Set-BuildManifestValue -Manifest $Manifest -Section 'Build' -Item 'population' -Field 'RandomSeed' -Value 'not collected' -Note 'not collected, the population settings hook has no PopulationSeed'
        }
        elseif ([string]$settingsSeed -eq 'Random') {
            $notDrawnNote = switch ($outcomeName) {
                'NeverStarted' { 'population never started, so no seed was drawn' }
                'TimedOut'     { 'population timed out before a seed was recorded' }
                'Failed'       { 'population failed before a seed was recorded' }
                default        { 'the completion marker recorded no seed' }
            }
            Set-BuildManifestValue -Manifest $Manifest -Section 'Build' -Item 'population' -Field 'RandomSeed' -Value 'not drawn' -Note $notDrawnNote
        }
        else {
            Set-BuildManifestValue -Manifest $Manifest -Section 'Build' -Item 'population' -Field 'RandomSeed' -Value $settingsSeed -Note (& $sourceOf 'PopulationSeed')
        }
    }
    foreach ($settingName in @('Population', 'DomainAdminCount')) {
        $settingValue = Get-BuildManifestField -InputObject $Settings -Name $settingName
        if ($null -eq $settingValue -or [string]$settingValue -eq '') {
            $missingValues += $settingName
            Set-BuildManifestValue -Manifest $Manifest -Section 'Build' -Item 'population' -Field $settingName -Value 'not collected' -Note "not collected, the population settings hook has no $settingName"
        }
        else {
            Set-BuildManifestValue -Manifest $Manifest -Section 'Build' -Item 'population' -Field $settingName -Value $settingValue -Note (& $sourceOf $settingName)
        }
    }
    $populationLogsPath = [string](Get-BuildManifestField -InputObject $Outcome -Name 'HostLogsPath')
    if ($populationLogsPath) {
        Set-BuildManifestValue -Manifest $Manifest -Section 'GuestLogs' -Item 'population' -Field 'Folder' -Value $populationLogsPath
    }
    if ($missingValues.Count -gt 0) {
        Add-BuildManifestLogEntry -Manifest $Manifest -Level WARN -Message "the population settings hook has no $($missingValues -join ', '), so those population values are recorded as not collected."
    }
}

function Add-BuildManifestVmRow {
    # A VM's rows, under its VM name. -Role, -Status and -VmxPath set those rows. With
    # -Identity (Get-GuestMachineIdentity's answer) it adds ComputerName, IPv4Address (the
    # address that matches -PlannedAddress, or with no planned address every address the
    # guest reports, joined with ';'), OsBuild and OsCaption, or unknown for the two OS rows
    # with a WARN when only the OS query failed. With -ReadError (the guest read itself
    # failed) the OS rows are unknown and the planned address is recorded with Note
    # planned, with a WARN. -PlannedAddressOnly records the planned address alone, for a
    # member that failed before any read.
    param (
        [Parameter(Mandatory)]
        [object]$Manifest,
        [Parameter(Mandatory)]
        [string]$VmName,
        [string]$Role,
        [string]$Status,
        [string]$VmxPath,
        [AllowNull()]
        [object]$Identity,
        [string]$ReadError,
        [string]$PlannedAddress,
        [switch]$PlannedAddressOnly
    )
    if ($Role) { Set-BuildManifestValue -Manifest $Manifest -Section 'Vm' -Item $VmName -Field 'Role' -Value $Role }
    if ($Status) { Set-BuildManifestValue -Manifest $Manifest -Section 'Vm' -Item $VmName -Field 'Status' -Value $Status }
    if ($VmxPath) { Set-BuildManifestValue -Manifest $Manifest -Section 'Vm' -Item $VmName -Field 'VmxPath' -Value $VmxPath }
    $plannedAddressRow = {
        if ($PlannedAddress) { Set-BuildManifestValue -Manifest $Manifest -Section 'Vm' -Item $VmName -Field 'IPv4Address' -Value $PlannedAddress -Note 'planned' }
        else { Set-BuildManifestValue -Manifest $Manifest -Section 'Vm' -Item $VmName -Field 'IPv4Address' -Value 'not collected' -Note 'the guest read failed, and this run plans no address' }
    }
    if ($PlannedAddressOnly) {
        & $plannedAddressRow
        return
    }
    if ($ReadError) {
        & $plannedAddressRow
        Set-BuildManifestValue -Manifest $Manifest -Section 'Vm' -Item $VmName -Field 'OsBuild' -Value 'unknown'
        Set-BuildManifestValue -Manifest $Manifest -Section 'Vm' -Item $VmName -Field 'OsCaption' -Value 'unknown'
        $addressText = if ($PlannedAddress) { ' and its planned address is recorded' } else { '' }
        Add-BuildManifestLogEntry -Manifest $Manifest -Level WARN -Message "could not read $VmName from the guest: $($ReadError.Trim().TrimEnd('.')). Its OS build is unknown$addressText."
        return
    }
    if ($null -eq $Identity) { return }
    Set-BuildManifestValue -Manifest $Manifest -Section 'Vm' -Item $VmName -Field 'ComputerName' -Value (Get-BuildManifestField -InputObject $Identity -Name 'Name')
    $reportedAddresses = @(@(Get-BuildManifestField -InputObject $Identity -Name 'Ipv4Addresses') | Where-Object { $_ } | ForEach-Object { ([string]$_ -split '/')[0] })
    if ($PlannedAddress -and $reportedAddresses -contains $PlannedAddress) {
        Set-BuildManifestValue -Manifest $Manifest -Section 'Vm' -Item $VmName -Field 'IPv4Address' -Value $PlannedAddress
    }
    elseif ($reportedAddresses.Count -gt 0) {
        Set-BuildManifestValue -Manifest $Manifest -Section 'Vm' -Item $VmName -Field 'IPv4Address' -Value ($reportedAddresses -join ';')
    }
    else {
        Set-BuildManifestValue -Manifest $Manifest -Section 'Vm' -Item $VmName -Field 'IPv4Address' -Value 'not collected' -Note 'the guest reports no IPv4 address'
    }
    $osBuild = [string](Get-BuildManifestField -InputObject $Identity -Name 'BuildNumber')
    $osCaption = [string](Get-BuildManifestField -InputObject $Identity -Name 'Caption')
    Set-BuildManifestValue -Manifest $Manifest -Section 'Vm' -Item $VmName -Field 'OsBuild' -Value $(if ($osBuild) { $osBuild } else { 'unknown' })
    Set-BuildManifestValue -Manifest $Manifest -Section 'Vm' -Item $VmName -Field 'OsCaption' -Value $(if ($osCaption) { $osCaption } else { 'unknown' })
    if (-not $osBuild) {
        $osError = [string](Get-BuildManifestField -InputObject $Identity -Name 'OsError')
        if (-not $osError) { $osError = 'the guest returned no OS build' }
        Add-BuildManifestLogEntry -Manifest $Manifest -Level WARN -Message "could not read the OS of $($VmName): $($osError.TrimEnd('.'))."
    }
}

function Add-BuildManifestMovedMemberRow {
    # The row set for one member a -MoveMemberServers run moved, once the re-query has
    # confirmed it. The run reads no member, so only the name, the role and the status are
    # known, and every other row is "not collected" with the reason in its Note.
    param (
        [Parameter(Mandatory)]
        [object]$Manifest,
        [Parameter(Mandatory)]
        [string]$Name
    )
    Set-BuildManifestValue -Manifest $Manifest -Section 'Vm' -Item $Name -Field 'ComputerName' -Value $Name -Note 'computer object name; build-lab gives a member the same VM and computer name'
    Set-BuildManifestValue -Manifest $Manifest -Section 'Vm' -Item $Name -Field 'Role' -Value 'Member'
    Set-BuildManifestValue -Manifest $Manifest -Section 'Vm' -Item $Name -Field 'Status' -Value 'Moved'
    foreach ($notReadField in @('IPv4Address', 'OsBuild', 'OsCaption')) {
        Set-BuildManifestValue -Manifest $Manifest -Section 'Vm' -Item $Name -Field $notReadField -Value 'not collected' -Note '-MoveMemberServers reads no member'
    }
    Set-BuildManifestValue -Manifest $Manifest -Section 'Vm' -Item $Name -Field 'VmxPath' -Value 'not collected' -Note '-MoveMemberServers knows no member VMX path'
}

#endregion Functions

#region Variables
# The region runs in this order, so nothing below the override file resets a value it set:
# the base constants, the override file, the sibling path defaults, then the derived paths.

# Printed in the starting log line so every log shows which version ran. Keep it in step
# with Version in .NOTES.
$scriptVersion      = '2.3.0'
$enableEventLogging = $true
$eventLogSourceName = 'build-lab'
$guestUserName      = 'Administrator'
$runTimestamp       = Get-Date -Format 'yyyyMMdd_HHmmss'

# Member servers. The cap is a scope limit on -MemberServerCount. The override file's
# MaxMemberServerCount changes it, so it is never a per-run value.
$maxMemberServerCount   = 5
$memberServerNamePrefix = 'SRVR-'
$memberServerIpOffset   = 10
# Matches exactly the names this script gives members (SRVR-01..SRVR-99), so
# -MoveMemberServers cannot pick up population's SRV-<seed>-<n> objects or anything else.
$memberServerNamePattern = '^' + [regex]::Escape($memberServerNamePrefix) + '\d{2}$'

# The oldest sibling releases this build-lab works with: the new-AdDomain
# (New-ADForestDeployment.ps1) and New-VMwareWorkstationVM releases that ship with this
# one, so a stop names a version a user can download. Each is compared with the
# sibling's header Version as [version], so a newer sibling passes.
$minimumAdDomainVersion  = '2.2.0'
$minimumVmBuilderVersion = '1.2.0'
# The first release of each sibling that reads an override file. Below it, a sibling would
# ignore its override file, which is a different reason to stop than being older than the
# minimum. These stay where they are when the minimums above move.
$adDomainOverrideFileVersion  = '2.1.0'
$vmBuilderOverrideFileVersion = '1.1.0'

#region Override file
# overrides\overrides.psd1 holds the user's standing settings, so an upgrade never touches
# them (OVERRIDE.md lists every key). Logging hasn't started yet, so every line is held
# here and logged right after the starting line, and a stop is held the same way and
# thrown there. The assignments run here, at script level, so each parameter's own
# validation attributes check the value. Inside a function they would set a local copy.
# A parameter the command line bound keeps its value.
$overrideFilePath     = Join-Path -Path $PSScriptRoot -ChildPath 'overrides\overrides.psd1'
$overrideCatalogPath  = Join-Path -Path $PSScriptRoot -ChildPath 'include\override-catalog.psd1'
$overrideInfoLines    = New-Object -TypeName 'System.Collections.Generic.List[string]'
$overrideWarningLines = New-Object -TypeName 'System.Collections.Generic.List[string]'
$overrideStopLines    = New-Object -TypeName 'System.Collections.Generic.List[string]'
$unusedMemberServerCountAssignment = $null
$overrideFile = Get-OverrideFile -Path $overrideFilePath -CatalogPath $overrideCatalogPath
foreach ($overrideLine in $overrideFile.Info) { $overrideInfoLines.Add($overrideLine) }
foreach ($overrideLine in $overrideFile.Warnings) { $overrideWarningLines.Add($overrideLine) }
if ($overrideFile.Error) {
    foreach ($overrideLine in ($overrideFile.Error -split '\r?\n')) { $overrideStopLines.Add($overrideLine) }
}
else {
    $overrideAssignmentResult = Get-OverrideParameterAssignment -OverrideFile $overrideFile -CatalogPath $overrideCatalogPath -BoundParameters $PSBoundParameters
    foreach ($overrideLine in $overrideAssignmentResult.Info) { $overrideInfoLines.Add($overrideLine) }
    foreach ($overrideLine in $overrideAssignmentResult.Warnings) { $overrideWarningLines.Add($overrideLine) }
    if ($overrideAssignmentResult.Error) {
        foreach ($overrideLine in ($overrideAssignmentResult.Error -split '\r?\n')) { $overrideStopLines.Add($overrideLine) }
    }
    else {
        foreach ($overrideAssignment in $overrideAssignmentResult.Assignments) {
            # -SkipVmBuild and -MoveMemberServers build no members, so the file's
            # MemberServerCount isn't assigned there and gets one line, below, once the cap
            # is final. Assigned, it would trip their stop for a count on the command line,
            # which names a parameter the run never passed. A count typed on the command
            # line still stops.
            if ($overrideAssignment.ParameterName -eq 'MemberServerCount' -and ($SkipVmBuild -or $MoveMemberServers)) {
                $unusedMemberServerCountAssignment = $overrideAssignment
                continue
            }
            $overrideAssignmentValue = $overrideAssignment.Value
            # A relative sibling path from the file means build-lab's folder, not wherever
            # the run was started from.
            if ($overrideAssignment.ParameterName -in @('VmBuilderScriptPath', 'AdDomainSourcePath') -and $overrideAssignmentValue -is [string]) {
                $overridePathIsRooted = $true
                try { $overridePathIsRooted = [System.IO.Path]::IsPathRooted($overrideAssignmentValue) } catch { $overridePathIsRooted = $true }
                if (-not $overridePathIsRooted) { $overrideAssignmentValue = Join-Path -Path $PSScriptRoot -ChildPath $overrideAssignmentValue }
            }
            try {
                Set-Variable -Name $overrideAssignment.ParameterName -Value $overrideAssignmentValue -ErrorAction Stop
            }
            catch {
                # The refusal's own text quotes the value, so it isn't used.
                $overrideStopLines.Add("Override file '$overrideFilePath': -$($overrideAssignment.ParameterName) doesn't accept the value of $($overrideAssignment.Key). OVERRIDE.md lists the values it accepts.")
            }
        }
        # The two constant keys. Each assignment sits inside an if, so the plain assignment
        # above stays the one the offline checks and the migration script read.
        if ($overrideFile.Values.ContainsKey('EnableEventLogging')) { $enableEventLogging = [bool]$overrideFile.Values['EnableEventLogging'] }
        if ($overrideFile.Values.ContainsKey('MaxMemberServerCount')) { $maxMemberServerCount = [int]$overrideFile.Values['MaxMemberServerCount'] }

        # The unused MemberServerCount gets one line: INFO, or a WARN when a full build or
        # -AddMemberServers would stop on it, because it isn't a whole number in the
        # parameter's range or is above the cap. It is never assigned and never stops this
        # run. The range is read from the parameter's own ValidateRange.
        if ($null -ne $unusedMemberServerCountAssignment) {
            $memberlessModeSwitchName = if ($MoveMemberServers) { '-MoveMemberServers' } else { '-SkipVmBuild' }
            $unusedCountValue = $unusedMemberServerCountAssignment.Value
            $unusedCountLine  = "Override file '$overrideFilePath': $($unusedMemberServerCountAssignment.Key)=$unusedCountValue not used; $memberlessModeSwitchName builds no member servers."
            $memberCountRange = @($MyInvocation.MyCommand.Parameters['MemberServerCount'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] })[0]
            $unusedCountNumber = $null
            if ($unusedCountValue -is [int] -or $unusedCountValue -is [long]) { $unusedCountNumber = [long]$unusedCountValue }
            elseif ($unusedCountValue -is [string] -and $unusedCountValue.Trim() -match '\A-?[0-9]{1,18}\z') { $unusedCountNumber = [long]$unusedCountValue.Trim() }
            if ($null -eq $unusedCountNumber -or $unusedCountNumber -lt [long]$memberCountRange.MinRange -or $unusedCountNumber -gt [long]$memberCountRange.MaxRange) {
                $overrideWarningLines.Add("$unusedCountLine It isn't a whole number from $($memberCountRange.MinRange) to $($memberCountRange.MaxRange), the range -MemberServerCount takes, so a full build or an -AddMemberServers run would stop on it.")
            }
            elseif ($unusedCountNumber -gt $maxMemberServerCount) {
                $overrideWarningLines.Add("$unusedCountLine It is above the MaxMemberServerCount cap of $maxMemberServerCount, so a full build or an -AddMemberServers run would stop on it.")
            }
            else {
                $overrideInfoLines.Add($unusedCountLine)
            }
        }
    }
}

# A shipped default that changed since the previous release gets one INFO line, unless
# this run set that key on the command line or in the override file. build-lab's keys
# take no value from a build profile, except NetworkType, which a profile also sets. Its
# shipped value has stayed nat, so this block never reports it, and a profile value needs
# no set-key entry here. A release that changes NetworkType's shipped value would need one.
# Nothing here stops the run, and a problem is a WARN.
$overrideReleaseTablePath = Join-Path -Path $PSScriptRoot -ChildPath 'include\release-values.psd1'
if ($overrideStopLines.Count -eq 0) {
    try {
        $changedCatalogData = Import-PowerShellDataFile -LiteralPath $overrideCatalogPath -ErrorAction Stop
        $changedReleaseTable = $null
        if (Test-Path -LiteralPath $overrideReleaseTablePath -PathType Leaf) {
            $changedReleaseTable = Import-PowerShellDataFile -LiteralPath $overrideReleaseTablePath -ErrorAction Stop
        }
        $changedSetKeys = New-Object -TypeName 'System.Collections.Generic.List[string]'
        foreach ($changedSetKey in @($overrideFile.Values.get_Keys())) { $changedSetKeys.Add([string]$changedSetKey) }
        $boundParameterNames = @($PSBoundParameters.get_Keys())
        foreach ($changedCatalogKey in @($changedCatalogData['Settings'].get_Keys())) {
            $changedCatalogEntry = $changedCatalogData['Settings'][$changedCatalogKey]
            if ($changedCatalogEntry['Target'] -ceq 'Parameter' -and $boundParameterNames -contains $changedCatalogEntry['Name']) { $changedSetKeys.Add([string]$changedCatalogKey) }
        }
        $changedDefaultResult = Get-OverrideChangedDefault -Catalog $changedCatalogData -ReleaseTable $changedReleaseTable -CurrentVersion $scriptVersion -SetKey ([string[]]$changedSetKeys.ToArray())
        foreach ($changedLine in @($changedDefaultResult.Info)) { if ($changedLine) { $overrideInfoLines.Add($changedLine) } }
        foreach ($changedLine in @($changedDefaultResult.Warnings)) { if ($changedLine) { $overrideWarningLines.Add($changedLine) } }
        if ($changedDefaultResult.Error) {
            foreach ($changedLine in ($changedDefaultResult.Error -split '\r?\n')) { if ($changedLine) { $overrideWarningLines.Add($changedLine) } }
        }
    }
    catch {
        $overrideWarningLines.Add("Changed default: the override catalog or the release table couldn't be read ($($_.Exception.GetType().FullName)), so changed defaults aren't reported for this run.")
    }
}
#endregion Override file

# The sibling path defaults fill only a path neither the command line nor the override
# file gave.
if (-not $VmBuilderScriptPath) {
    $VmBuilderScriptPath = Join-Path -Path $PSScriptRoot -ChildPath '..\New-VMwareWorkstationVM\New-VMwareWorkstationVM.ps1'
}
if (-not $AdDomainSourcePath) {
    $AdDomainSourcePath = Join-Path -Path $PSScriptRoot -ChildPath '..\new-AdDomain'
}
$adDomainGlobalConfigPath = Join-Path -Path $AdDomainSourcePath -ChildPath 'include\global-config.ps1'

$logDirectoryPath = Join-Path -Path $PSScriptRoot -ChildPath 'logs'
$csvLogFilePath   = Join-Path -Path $logDirectoryPath -ChildPath "build-lab-errors_$runTimestamp.csv"
$textLogFilePath  = Join-Path -Path $logDirectoryPath -ChildPath "build-lab_$runTimestamp.log"
# The build manifest is written beside the log, named after the run like it, and the ISO
# hash cache it keeps sits in the same folder.
$buildManifestPath = Join-Path -Path $logDirectoryPath -ChildPath "build-lab-manifest_$runTimestamp.csv"
$isoHashCachePath  = Join-Path -Path $logDirectoryPath -ChildPath 'iso-sha256-cache.csv'

$vmDirectoryPath = Join-Path -Path $VmStoragePath -ChildPath $VmName
$vmxFilePath     = Join-Path -Path $vmDirectoryPath -ChildPath "$VmName.vmx"

# The process ID keeps two runs started in the same second apart: each build's VM builder
# temp folder lives under this folder, member names (SRVR-NN) repeat across labs, and each
# run deletes its own staging folder at the end.
$stagingRootPath = Join-Path -Path $env:TEMP -ChildPath "BuildLab-$runTimestamp-$PID"
#endregion Variables

#region Main

Initialize-Logging -ScriptName 'build-lab.ps1' -CsvLogPath $csvLogFilePath -TextLogPath $textLogFilePath
# The event source is registered once per host by Register-EventLogSource.ps1, never here.
# When it isn't registered, or can't be checked, this run writes no events, and the
# warning is logged right after the starting line. The text and CSV logs always run, so
# the run still has a durable record. The override file can already have turned events off.
$eventLogSourceWarning = $null
if ($enableEventLogging) {
    $eventLogSourceCheck = Test-EventLogSource -SourceName $eventLogSourceName
    if (-not $eventLogSourceCheck.Registered) {
        $enableEventLogging    = $false
        $eventLogSourceWarning = $eventLogSourceCheck.Warning
    }
}

$guestPasswordPlainText = $null
# Set as the try block's last step (and before the -MoveMemberServers return), so the
# finally block can tell a completed run (event 1001) from one that stopped (1002).
$runCompleted = $false
# The build manifest records the run and never decides it. Each manifest step below sits in
# a try of its own, and a failure is a WARN. $buildOutcome is the Outcome its last save
# records: Running until the run ends, then Succeeded, MemberFailures, Failed, or
# Interrupted when neither the try nor the catch finished.
$buildManifest = New-BuildManifest -Path $buildManifestPath
$buildOutcome  = 'Running'
$gitPath = $null
# git is optional: without it a project with a .git records unknown, with a WARN.
$gitCommand = Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -ne $gitCommand) { $gitPath = $gitCommand.Source }

try {
    Write-Log "=== build-lab.ps1 $scriptVersion starting ===" -Level INFO
    if ($eventLogSourceWarning) {
        Write-Log $eventLogSourceWarning -Level WARN
    }
    Write-AppEvent -EnableEventLogging $enableEventLogging -SourceName $eventLogSourceName -EntryType Information -EventId 1000 -Message 'build-lab.ps1 started.'

    # The manifest's first rows: the run, build-lab and its override file, the snapshot row,
    # and the population row of the member-only modes. They are held and saved after the
    # override file's lines, so nothing comes between those and the starting line.
    try {
        Add-BuildManifestRunRow -Manifest $buildManifest -ParameterSetName $PSCmdlet.ParameterSetName -TextLogPath $textLogFilePath -ErrorLogPath $csvLogFilePath -Started (Get-Date).ToString('o')
        Add-BuildManifestResult -Manifest $buildManifest -Result (Get-ProjectSourceState -ProjectName 'build-lab' -ProjectPath $PSScriptRoot -GitPath $gitPath)
        Set-BuildManifestValue -Manifest $buildManifest -Section 'Project' -Item 'build-lab' -Field 'Version' -Value $scriptVersion
        Add-BuildManifestResult -Manifest $buildManifest -Result (Get-ProjectScriptVersionRow -ProjectName 'build-lab' -ProjectPath $PSScriptRoot -MainScriptName 'build-lab.ps1' -KnownVersion $scriptVersion)
        Add-BuildManifestResult -Manifest $buildManifest -Result (Get-OverrideFileRow -ProjectName 'build-lab' -NamedPath $overrideFilePath -UseKnownSha256 -KnownSha256 $overrideFile.Sha256)
    }
    catch { Add-BuildManifestLogEntry -Manifest $buildManifest -Level WARN -Message "could not record the run's first rows: $($_.Exception.Message)" }

    # The override file's lines, held since the Variables region. A stop comes before
    # anything is checked, staged, built or changed.
    foreach ($overrideLine in $overrideInfoLines) {
        Write-Log $overrideLine -Level INFO
    }
    foreach ($overrideLine in $overrideWarningLines) {
        Write-Log $overrideLine -Level WARN
    }
    if ($overrideStopLines.Count -gt 0) {
        foreach ($overrideLine in $overrideStopLines) {
            Write-Log $overrideLine -Level ERROR
        }
        throw "The override file '$overrideFilePath' can't be applied, so build-lab stopped before any VM was built or changed. $($overrideStopLines -join ' ')"
    }
    Write-BuildManifest -Manifest $buildManifest

    # CIDR prefix length derived from the subnet mask, passed to the guest deployment so it
    # can repair a DHCP fallback non-interactively (see Invoke-GuestAdForestDeployment).
    # Derived inside the try so an invalid mask is logged like any other failure. 0.0.0.0
    # passes the parameter pattern but gives prefix 0, which the guest deployment rejects
    # only after the full deployment timeout, so it is refused here instead. -MoveMemberServers
    # never uses the mask, so a move run skips the check and doesn't stop on it.
    $staticIpPrefixLength = $null
    if (-not $MoveMemberServers) {
        $staticIpPrefixLength = ConvertTo-PrefixLength -SubnetMask $SubnetMask
        if ($staticIpPrefixLength -lt 1) {
            throw "-SubnetMask '$SubnetMask' gives a prefix length of 0, which cannot describe a host network. Pass the network's real mask, such as 255.255.255.0."
        }
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

    # Only a full build and -AddMemberServers run the VM builder, so only they need it.
    # -SkipVmBuild reuses the DC and refuses members, and -MoveMemberServers builds nothing.
    $runBuildsVms = $activeParameterSet -in @('Build', 'AddMembers')
    if ($runBuildsVms -and -not (Test-Path -LiteralPath $VmBuilderScriptPath -PathType Leaf)) {
        throw "VM builder script not found: '$VmBuilderScriptPath'. Pass -VmBuilderScriptPath if New-VMwareWorkstationVM is not a sibling of this project."
    }
    # The VM builder's rows, in the modes that build VMs, and in -SkipVmBuild, which never
    # runs it, only when it is there and with a Note saying so. -MoveMemberServers has none.
    if ($activeParameterSet -ne 'MoveMembers' -and ($runBuildsVms -or (Test-Path -LiteralPath $VmBuilderScriptPath -PathType Leaf))) {
        try {
            $vmBuilderRowNote   = if ($runBuildsVms) { '' } else { 'not run this run' }
            $vmBuilderFolder    = Split-Path -Path $VmBuilderScriptPath -Parent
            Add-BuildManifestResult -Manifest $buildManifest -Result (Get-ProjectSourceState -ProjectName 'New-VMwareWorkstationVM' -ProjectPath $vmBuilderFolder -GitPath $gitPath -Note $vmBuilderRowNote)
            Add-BuildManifestResult -Manifest $buildManifest -Result (Get-ProjectScriptVersionRow -ProjectName 'New-VMwareWorkstationVM' -ProjectPath $vmBuilderFolder -MainScriptName (Split-Path -Path $VmBuilderScriptPath -Leaf) -Note $vmBuilderRowNote)
            Add-BuildManifestResult -Manifest $buildManifest -Result (Get-OverrideFileRow -ProjectName 'New-VMwareWorkstationVM' -NamedPath (Join-Path -Path $vmBuilderFolder -ChildPath 'overrides\overrides.psd1') -Note $vmBuilderRowNote)
        }
        catch { Add-BuildManifestLogEntry -Manifest $buildManifest -Level WARN -Message "could not record the VM builder's rows: $($_.Exception.Message)" }
    }
    $adForestDeploymentScriptPath = Join-Path -Path $AdDomainSourcePath -ChildPath 'New-ADForestDeployment.ps1'
    if (-not (Test-Path -LiteralPath $adForestDeploymentScriptPath -PathType Leaf)) {
        throw "New-ADForestDeployment.ps1 not found at '$adForestDeploymentScriptPath'. Pass -AdDomainSourcePath if new-AdDomain is not a sibling of this project."
    }
    if (-not (Test-Path -LiteralPath $adDomainGlobalConfigPath -PathType Leaf)) {
        throw "Domain configuration not found at '$adDomainGlobalConfigPath'. The domain and the build profile are read from new-AdDomain\include\global-config.ps1. Pass -AdDomainSourcePath if new-AdDomain is not a sibling of this project."
    }
    # The source new-AdDomain as a full path, so the log names its build profile without
    # '..' segments and -ProfilePath can be recognized when it names that same file.
    $adDomainSourceFullPath = ConvertTo-FullFileSystemPath -Path $AdDomainSourcePath
    $sourceBuildProfilePath = Join-Path -Path $adDomainSourceFullPath -ChildPath 'include\build-profile.psd1'
    # Bound with any value (even an empty one) means a profile was asked for, so it is checked.
    $buildProfilePath = $null
    if ($PSBoundParameters.ContainsKey('ProfilePath')) {
        $buildProfilePath = Confirm-BuildProfilePath -ProfilePath $ProfilePath
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
    try { Add-BuildManifestToolRow -Manifest $buildManifest -VmrunPath $vmrunPath } catch { Add-BuildManifestLogEntry -Manifest $buildManifest -Level WARN -Message "could not record the vmrun.exe rows: $($_.Exception.Message)" }

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

    # Stage new-AdDomain once, put the build profile in place, then read and check the
    # staged copy. Every mode needs the result: the move and the add check the existing DC
    # against it, members join it, and a full build verifies its promotion against it and
    # ships this same staged folder to the DC. Doing it here stops on a bad profile or
    # config before anything is pinged, built or changed.
    Write-Log "Staging new-AdDomain from '$adDomainSourceFullPath' into '$stagingRootPath'..." -Level INFO
    $stagedPayloadPath     = Copy-AdDomainPayloadToStaging -SourcePath $AdDomainSourcePath -StagingRootPath $stagingRootPath
    # new-AdDomain's rows: its commit from the source folder, read moments after the copy,
    # and its scripts and override files from the staged copy the guest gets. The add and
    # move modes deploy nothing, so their rows say so.
    try {
        $adDomainRowNote = if ($activeParameterSet -in @('AddMembers', 'MoveMembers')) { 'read on the host, not deployed this run' } else { '' }
        Add-BuildManifestResult -Manifest $buildManifest -Result (Get-ProjectSourceState -ProjectName 'new-AdDomain' -ProjectPath $adDomainSourceFullPath -GitPath $gitPath -Note $adDomainRowNote)
        Add-BuildManifestResult -Manifest $buildManifest -Result (Get-ProjectScriptVersionRow -ProjectName 'new-AdDomain' -ProjectPath $stagedPayloadPath -Note $adDomainRowNote)
        Add-BuildManifestResult -Manifest $buildManifest -Result (Get-OverrideFileRow -ProjectName 'new-AdDomain' -NamedPath (Join-Path -Path $adDomainSourceFullPath -ChildPath 'overrides\overrides.psd1') `
            -HashPath (Join-Path -Path $stagedPayloadPath -ChildPath 'overrides\overrides.psd1') -StagedProjectPath $stagedPayloadPath -SourceProjectPath $adDomainSourceFullPath -Note $adDomainRowNote)
    }
    catch { Add-BuildManifestLogEntry -Manifest $buildManifest -Level WARN -Message "could not record new-AdDomain's rows: $($_.Exception.Message)" }
    $buildProfileSelection = Set-StagedBuildProfile -StagedPayloadPath $stagedPayloadPath -SourceProfilePath $sourceBuildProfilePath -ProfilePath $buildProfilePath
    try { Add-BuildManifestProfileRow -Manifest $buildManifest -Selection $buildProfileSelection } catch { Add-BuildManifestLogEntry -Manifest $buildManifest -Level WARN -Message "could not record the profile rows: $($_.Exception.Message)" }
    foreach ($buildProfileLogEntry in $buildProfileSelection.LogEntries) {
        Write-Log $buildProfileLogEntry.Message -Level $buildProfileLogEntry.Level
    }
    # The payload zip leaves hidden items out. A hidden file the guest uses stops the run,
    # and anything else hidden is one WARN.
    $hiddenPayloadCheck = Test-PayloadHiddenItem -StagedPayloadPath $stagedPayloadPath -SourcePath $adDomainSourceFullPath -ProfileOriginPath $buildProfileSelection.OriginPath
    if ($hiddenPayloadCheck.Stop) {
        throw $hiddenPayloadCheck.Stop
    }
    if ($hiddenPayloadCheck.Warning) {
        Write-Log $hiddenPayloadCheck.Warning -Level WARN
    }

    # The version handshake. Each sibling's header Version is read by parsing, never by
    # running it, and Get-SiblingVersionOutcome says what to do with it. An older
    # new-AdDomain stops here, naming the version found, the version needed and why. The
    # VM builder is checked only in a run that builds VMs. An older one only WARNs, unless
    # it is too old to read an override file it has. An unreadable header WARNs, and the
    # feature checks below still apply.
    $stagedDeploymentScriptPath = Join-Path -Path $stagedPayloadPath -ChildPath 'New-ADForestDeployment.ps1'
    $adDomainVersionCheck = Get-SiblingVersionOutcome -ProjectName 'new-AdDomain' -ScriptPath $adForestDeploymentScriptPath `
        -FoundVersion (Get-ScriptHeaderVersion -Path $stagedDeploymentScriptPath) -MinimumVersion $minimumAdDomainVersion `
        -OverrideFileVersion $adDomainOverrideFileVersion
    try { Set-BuildManifestValue -Manifest $buildManifest -Section 'Project' -Item 'new-AdDomain' -Field 'Version' -Value $(if ($adDomainVersionCheck.Status -eq 'Unreadable') { 'unknown' } else { $adDomainVersionCheck.FoundVersion }) } catch { Add-BuildManifestLogEntry -Manifest $buildManifest -Level WARN -Message "could not record new-AdDomain's version: $($_.Exception.Message)" }
    if ($adDomainVersionCheck.Level -eq 'Stop') {
        throw $adDomainVersionCheck.Message
    }
    Write-Log $adDomainVersionCheck.Message -Level $adDomainVersionCheck.Level
    if ($runBuildsVms) {
        $vmBuilderVersionCheck = Get-SiblingVersionOutcome -ProjectName 'New-VMwareWorkstationVM' -ScriptPath $VmBuilderScriptPath `
            -FoundVersion (Get-ScriptHeaderVersion -Path $VmBuilderScriptPath) -MinimumVersion $minimumVmBuilderVersion `
            -OverrideFileVersion $vmBuilderOverrideFileVersion `
            -OverrideFilePath (Join-Path -Path (Split-Path -Path $VmBuilderScriptPath -Parent) -ChildPath 'overrides\overrides.psd1')
        try { Set-BuildManifestValue -Manifest $buildManifest -Section 'Project' -Item 'New-VMwareWorkstationVM' -Field 'Version' -Value $(if ($vmBuilderVersionCheck.Status -eq 'Unreadable') { 'unknown' } else { $vmBuilderVersionCheck.FoundVersion }) } catch { Add-BuildManifestLogEntry -Manifest $buildManifest -Level WARN -Message "could not record the VM builder's version: $($_.Exception.Message)" }
        if ($vmBuilderVersionCheck.Level -eq 'Stop') {
            throw $vmBuilderVersionCheck.Message
        }
        Write-Log $vmBuilderVersionCheck.Message -Level $vmBuilderVersionCheck.Level
    }
    $requiredGlobalConfig = Get-RequiredGlobalConfigVersion -ScriptPath @($stagedDeploymentScriptPath, (Join-Path -Path $stagedPayloadPath -ChildPath 'Initialize-ADDirectory.ps1'))
    if (-not $requiredGlobalConfig.Version -and $adDomainVersionCheck.Status -eq 'Ok') {
        Write-Log "new-AdDomain's scripts name no oldest global-config.ps1 they run with, so its version isn't checked. $(@($requiredGlobalConfig.Problems) -join ' ')" -Level WARN
    }

    $domainIdentity = Get-AdDomainIdentity -GlobalConfigPath (Join-Path -Path $stagedPayloadPath -ChildPath 'include\global-config.ps1') -AdDomainSourcePath $adDomainSourceFullPath `
        -RequiredGlobalConfigVersion ([string]$requiredGlobalConfig.Version)
    # The validator names staged files. Each line is logged naming the file to edit: the
    # profile's origin first, then anything else under the staged copy, such as the
    # override file or a replacement CSV, under the source new-AdDomain.
    $originPathParameters  = @{ StagedProfilePath = $buildProfileSelection.StagedProfilePath; OriginPath = $buildProfileSelection.OriginPath }
    $payloadPathParameters = @{ StagedProfilePath = $stagedPayloadPath; OriginPath = $adDomainSourceFullPath }
    $originTextFor = { param ([string[]]$Text) @(ConvertTo-OriginProfilePathText -Text @(ConvertTo-OriginProfilePathText -Text $Text @originPathParameters) @payloadPathParameters) }
    if ($domainIdentity.Summary) {
        Write-Log (@(& $originTextFor @($domainIdentity.Summary)) -join ' ') -Level INFO
    }
    foreach ($buildProfileInfoLine in @(& $originTextFor @($domainIdentity.Info))) {
        Write-Log $buildProfileInfoLine -Level INFO
    }
    foreach ($buildProfileWarningLine in @(& $originTextFor (@($domainIdentity.Warnings) + @($domainIdentity.PairWarnings)))) {
        Write-Log $buildProfileWarningLine -Level WARN
    }
    if ($domainIdentity.Error -or $domainIdentity.PairError) {
        # One stop per line, each starting with its source. Each is logged on its own line.
        $buildProfileErrorLines = @(& $originTextFor @(@($domainIdentity.Error, $domainIdentity.PairError) -split '\r?\n' | Where-Object { $_ -and $_.Trim() }))
        foreach ($buildProfileErrorLine in $buildProfileErrorLines) {
            Write-Log $buildProfileErrorLine -Level ERROR
        }
        throw "The build configuration is not valid, so build-lab stopped before any VM was built or changed. $($buildProfileErrorLines -join ' ')"
    }
    $sourceServiceAccountCsvPath = @(& $originTextFor @([string]$domainIdentity.ServiceAccountCsvPath))[0]
    if ($domainIdentity.PlaceholderRows.Count -gt 0) {
        $placeholderRowText = (@($domainIdentity.PlaceholderRows) | ForEach-Object { "'$($_.Name)' SPN '$($_.ServicePrincipalName)'" }) -join '; '
        throw "'$sourceServiceAccountCsvPath' has SPNs that still hold '{' or '}' after {DomainName} is substituted, so build-lab stopped before any VM was built or changed. Rows: $placeholderRowText. The only placeholder is {DomainName}, in any case. Fix those rows."
    }
    # An SPN that names a host in another domain is kept as written, with one WARN per
    # row, as the guest does. Only a run that deploys the DC, a full build or -SkipVmBuild,
    # gets the WARN, because only the deployment creates the service accounts. An add or
    # move run creates none, and it hasn't read the DC's own domain yet, so with the
    # fallback to that domain the line could name the wrong one.
    if (-not ($AddMemberServers -or $MoveMemberServers)) {
        foreach ($otherDomainRow in @($domainIdentity.OtherDomainRows)) {
            Write-Log "'$sourceServiceAccountCsvPath' row $($otherDomainRow.RowNumber) (Name '$($otherDomainRow.Name)'): SPN '$($otherDomainRow.ServicePrincipalName)' names host '$($otherDomainRow.HostName)', which is outside the build's domain '$($domainIdentity.DomainName)'. It is written as given. If it should follow the domain, write it as '$($otherDomainRow.SuggestedServicePrincipalName)'." -Level WARN
        }
    }
    # Where the expected domain came from, for the DC cross-check's mismatch message.
    $domainIdentitySource = switch ($domainIdentity.DomainNameSource) {
        'Profile'      { "the build profile '$($buildProfileSelection.OriginPath)'" }
        'OverrideFile' { "new-AdDomain's override file '$(Join-Path -Path $adDomainSourceFullPath -ChildPath 'overrides\overrides.psd1')'" }
        default {
            if ($buildProfileSelection.ProfileInUse -and -not $domainIdentity.DomainNameSource) { "the build profile '$($buildProfileSelection.OriginPath)'" }
            else { 'global-config.ps1' }
        }
    }
    # The domain rows, made here so a stop in the population or network checks below still
    # records them. They are saved after the network hook, with the network rows.
    $domainEffectiveValues = if ($domainIdentity.Summary) { @(& $originTextFor @($domainIdentity.Summary)) -join ' ' } else { '' }
    try { Set-BuildManifestDomainRow -Manifest $buildManifest -Identity $domainIdentity -EffectiveValues $domainEffectiveValues } catch { Add-BuildManifestLogEntry -Manifest $buildManifest -Level WARN -Message "could not record the domain rows: $($_.Exception.Message)" }

    # Directory population. A full build and -SkipVmBuild start it in the guest themselves,
    # so the staged new-AdDomain has to be one that reports it back. Checked by parsing the
    # staged Initialize-ADDirectory.ps1, before any VM is built or changed.
    $runDeploysDomainController = $activeParameterSet -in @('Build', 'GuestOnly')
    if ($runDeploysDomainController -and -not $DeferPopulation) {
        $populationSupportStop = Test-AdDomainPopulationSupport -ScriptPath (Join-Path -Path $stagedPayloadPath -ChildPath 'Initialize-ADDirectory.ps1') -SourcePath $adDomainSourceFullPath
        if ($populationSupportStop) {
            throw $populationSupportStop
        }
    }
    if ($runDeploysDomainController -and $DeferPopulation -and $PSBoundParameters.ContainsKey('PopulationTimeoutMinutes')) {
        Write-Log "-PopulationTimeoutMinutes $PopulationTimeoutMinutes is ignored, because -DeferPopulation leaves directory population to the logon task." -Level INFO
    }
    # The population settings hook: the values the guest's population will use, as validated
    # here, each with its source (Profile, OverrideFile or Default). In a build-lab run no
    # command line reaches the guest's population settings. A seed still to be drawn is
    # Random here. The outcome hook, $populationOutcome, is set after the population runs.
    $populationSettings = $null
    $populationOutcome  = $null
    if ($null -ne $domainIdentity.Population) {
        $populationSettings = [pscustomobject]@{
            Population       = $domainIdentity.Population
            DomainAdminCount = $domainIdentity.DomainAdminCount
            PopulationSeed   = $domainIdentity.PopulationSeed
            PopulationSource = $domainIdentity.PopulationSource
        }
        $populationOverrideText = "override file '$(Join-Path -Path $adDomainSourceFullPath -ChildPath 'overrides\overrides.psd1')'"
        Write-Log (ConvertTo-PopulationSettingsText -Settings $populationSettings -ProfileText "build profile '$($buildProfileSelection.OriginPath)'" -OverrideText $populationOverrideText) -Level INFO
    }

    # The network every VM in this run joins, and the mask it gets. -NetworkType comes from
    # the command line, the build profile, build-lab's override file or the default, and an
    # override value is set on the parameter without binding it, so the sources are read
    # from $PSBoundParameters and the override file's assignments, never from the value.
    # -AddMemberServers reads the DC's own network from its VMX on the host disk, because
    # the members have to join it. In the two modes that build VMs, the host check then
    # confirms this host can reach the DC's address through that network's adapter, and a
    # custom VMnet is checked against the VM builder's own -NetworkType, all before anything
    # is pinged, built or changed. A mask no one gave can follow the host adapter
    # (MaskFromAdapter), which recomputes the prefix length. The rest of the run uses
    # $effectiveNetworkType and $effectiveSubnetMask. The network hook, $networkSettings,
    # is set last.
    $networkOverrideAssignments = @()
    if ($null -ne $overrideAssignmentResult) { $networkOverrideAssignments = @($overrideAssignmentResult.Assignments) }
    $networkTypeAssignment = $networkOverrideAssignments | Where-Object { $_.ParameterName -eq 'NetworkType' } | Select-Object -First 1
    $subnetMaskAssignment  = $networkOverrideAssignments | Where-Object { $_.ParameterName -eq 'SubnetMask' } | Select-Object -First 1
    $networkResolveParameters = @{
        CommandLineValue = $(if ($PSBoundParameters.ContainsKey('NetworkType')) { $NetworkType } else { $null })
        OverrideValue    = $(if ($null -ne $networkTypeAssignment) { [string]$networkTypeAssignment.Value } else { $null })
        OverridePath     = $overrideFilePath
        ProfileValue     = $domainIdentity.NetworkType
        ProfilePath      = $buildProfileSelection.OriginPath
        DefaultValue     = $NetworkType
        Mode             = $activeParameterSet
    }
    if ($activeParameterSet -eq 'AddMembers') {
        $networkResolveParameters['DcVmxNetwork'] = Get-VmxNetworkType -VmxPath $vmxFilePath
        $networkResolveParameters['DcVmxPath']    = $vmxFilePath
    }
    $networkResolution = Resolve-RunNetworkType @networkResolveParameters
    foreach ($networkLogEntry in @($networkResolution.LogEntries)) {
        Write-Log $networkLogEntry.Message -Level $networkLogEntry.Level
    }
    $effectiveNetworkType = $NetworkType
    $effectiveSubnetMask  = $SubnetMask
    $networkHostCheck     = $null
    if ($networkResolution.NetworkUsed) {
        $effectiveNetworkType = $networkResolution.NetworkType
        $subnetMaskSource = if ($PSBoundParameters.ContainsKey('SubnetMask')) { 'command line' } elseif ($null -ne $subnetMaskAssignment) { 'override file' } else { 'default' }
        $effectiveNetwork  = ConvertTo-CanonicalNetworkType -NetworkType $effectiveNetworkType
        $networkHostState  = $null
        if ($effectiveNetwork.VmnetName) {
            $networkHostState = Get-HostNetworkState -RemoteIpAddress $StaticIpAddress
        }
        $networkHostCheck = Test-HostNetworkForAddress -NetworkType $effectiveNetwork.NetworkType -VmnetName $effectiveNetwork.VmnetName -IpAddress $StaticIpAddress `
            -SubnetMask $SubnetMask -SubnetMaskSource $subnetMaskSource -OverrideFilePath $overrideFilePath -HostState $networkHostState
        foreach ($networkLogEntry in @($networkHostCheck.LogEntries)) {
            Write-Log $networkLogEntry.Message -Level $networkLogEntry.Level
        }
        if ($networkHostCheck.Outcome -eq 'Stop') {
            throw $networkHostCheck.Message
        }
        # Every VM builder takes nat, bridged and hostonly, so only a custom VMnet is checked.
        if ($effectiveNetwork.NetworkType -like 'VMnet*') {
            $builderNetworkCheck = Test-VmBuilderNetworkType -VmBuilderScriptPath $VmBuilderScriptPath -NetworkType $effectiveNetwork.NetworkType
            if ($builderNetworkCheck.Outcome -eq 'Stop') {
                throw $builderNetworkCheck.Message
            }
            if ($builderNetworkCheck.Outcome -eq 'Warn') {
                Write-Log $builderNetworkCheck.Message -Level WARN
            }
        }
        $effectiveSubnetMask  = $networkHostCheck.SubnetMask
        $staticIpPrefixLength = $networkHostCheck.PrefixLength
    }
    $networkSettings = New-NetworkHookObject -Resolution $networkResolution -HostCheck $networkHostCheck
    try { Add-BuildManifestNetworkRow -Manifest $buildManifest -NetworkHook $networkSettings } catch { Add-BuildManifestLogEntry -Manifest $buildManifest -Level WARN -Message "could not record the network rows: $($_.Exception.Message)" }
    Write-BuildManifest -Manifest $buildManifest

    # The DC's own address and the gateway: the address the DC is about to get (full build)
    # or already has (-AddMemberServers). Not supplied for -SkipVmBuild / -MoveMemberServers.
    if ($StaticIpAddress) {
        Confirm-DomainControllerAddress -IpAddress $StaticIpAddress -SubnetMask $effectiveSubnetMask -NetworkType $effectiveNetworkType -DefaultGateway $DefaultGateway
    }
    # Without -DefaultGateway build-lab binds no gateway for the VM builder, and a
    # DefaultGateway in the builder's own override file then reaches every VM this run
    # builds. That gateway is read here the way the builder reads it, held to the rules
    # -DefaultGateway gets, and logged with a WARN, since the run asked for none. One the
    # VMs couldn't use stops the run: build-lab has no way to tell the builder "no gateway".
    $vmBuilderGateway = $null
    if (-not $DefaultGateway -and $runBuildsVms) {
        $vmBuilderGatewayRead = Get-VmBuilderOverrideGateway -VmBuilderScriptPath $VmBuilderScriptPath
        if ($vmBuilderGatewayRead.Problem) {
            Write-Log "-DefaultGateway was not given, and build-lab couldn't read whether New-VMwareWorkstationVM's override file '$($vmBuilderGatewayRead.OverrideFilePath)' sets DefaultGateway ($($vmBuilderGatewayRead.Problem)). If it does, every VM this run builds gets that gateway, unchecked here." -Level WARN
        }
        elseif ($vmBuilderGatewayRead.Gateway) {
            $vmBuilderGatewayProblem = Get-GatewayProblem -IpAddress $StaticIpAddress -SubnetMask $effectiveSubnetMask -Gateway $vmBuilderGatewayRead.Gateway
            if ($vmBuilderGatewayProblem) {
                throw "-DefaultGateway was not given, so New-VMwareWorkstationVM's override file '$($vmBuilderGatewayRead.OverrideFilePath)' would give every VM this run builds the gateway $($vmBuilderGatewayRead.Gateway), but $vmBuilderGatewayProblem. build-lab stopped before any VM was built or changed. Pass -DefaultGateway, or correct or remove DefaultGateway in that file."
            }
            $vmBuilderGateway = $vmBuilderGatewayRead.Gateway
            Write-Log "-DefaultGateway was not given, so New-VMwareWorkstationVM's override file '$($vmBuilderGatewayRead.OverrideFilePath)' gives every VM this run builds the gateway $vmBuilderGateway. It is inside the DC's subnet. Pass -DefaultGateway to choose the gateway here, or remove DefaultGateway from that file to build VMs with none." -Level WARN
        }
    }
    # The gateway the VMs get: -DefaultGateway, or the builder's own, or none. The member
    # plan keeps member addresses off it, and the guest deployment's DHCP-fallback repair
    # sets it. The builder calls still bind only -DefaultGateway, so the builder's file
    # keeps its say when build-lab has none.
    $effectiveDefaultGateway = if ($DefaultGateway) { $DefaultGateway } else { $vmBuilderGateway }
    # Early address check, full build only. -SkipVmBuild never has -StaticIpAddress (the
    # guest makes this check itself), and the add and move modes never run population, so
    # the subnet is not used there. The guest makes the real decision on the real address.
    if ($activeParameterSet -eq 'Build') {
        if ($domainIdentity.PrimarySubnet -eq 'Auto') {
            Write-Log "Early address check: PrimarySubnet is Auto, so the guest works out the subnet from the DC's own address." -Level INFO
        }
        elseif (Test-IpAddressInSubnet -IpAddress $StaticIpAddress -Subnet $domainIdentity.PrimarySubnet) {
            Write-Log "Early address check: PrimarySubnet $($domainIdentity.PrimarySubnet) contains the DC's address $StaticIpAddress." -Level INFO
        }
        else {
            Write-Log "Early address check: PrimarySubnet $($domainIdentity.PrimarySubnet) does not contain the DC's address $StaticIpAddress. The guest will use Auto, the subnet of the DC's own address, instead, and its `"Requested subnet`" test row will fail. To keep the subnet you asked for, change PrimarySubnet in the build profile or global-config.ps1, or the DC's -StaticIpAddress." -Level WARN
        }
    }
    # Before a static address is given to a new VM, make sure nothing already answers at it.
    # Only a full build assigns the DC an address; -AddMemberServers expects the DC to answer.
    if (-not ($SkipVmBuild -or $MoveMemberServers -or $AddMemberServers)) {
        if (Test-IpAddressResponds -IpAddress $StaticIpAddress) {
            throw "-StaticIpAddress $StaticIpAddress already answers ping, so another machine is using it. Nothing was built. Choose a free address; a second machine on the same address would leave both unreliable."
        }
        Write-Log "-StaticIpAddress $StaticIpAddress does not answer ping, so it is treated as free. (A host that blocks ping would not show up.)" -Level INFO
    }

    if ($MoveMemberServers) {
        # Separate later step: move joined member servers to OU=Servers on the existing DC.
        if ($MemberServerCount -gt 0) {
            throw "-MoveMemberServers runs on its own and builds nothing. Run the member server build (-MemberServerCount) and the move as separate invocations."
        }

        Write-Log "Waiting for the DC to answer guest operations (timeout: $GuestReadyTimeoutMinutes minute(s))..." -Level INFO
        Wait-GuestOperationsReady -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential -TimeoutMinutes $GuestReadyTimeoutMinutes
        Initialize-GuestTempDirectory -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential

        # The configuration is read again on this run, so confirm it still describes this DC.
        # With nothing naming a domain, the DC's own domain applies, and the identity is
        # final before the OU table below captures ServersOU.
        $domainControllerIdentity = Get-GuestMachineIdentity -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential `
            -HostStagingPath $stagingRootPath
        $memberDomainResolution = Resolve-MemberDomainIdentity -StagedIdentity $domainIdentity -DomainControllerIdentity $domainControllerIdentity -VmxFilePath $vmxFilePath
        if ($memberDomainResolution.Warning) {
            Write-Log $memberDomainResolution.Warning -Level WARN
        }
        $domainIdentity = $memberDomainResolution.Identity
        try {
            $memberUsesDcDomain = [bool]$memberDomainResolution.Warning -and [string]$domainIdentity.DomainName -eq [string](Get-BuildManifestField -InputObject $domainControllerIdentity -Name 'AdDomainDnsRoot')
            Set-BuildManifestDomainRow -Manifest $buildManifest -Identity $domainIdentity -EffectiveValues $domainEffectiveValues -UsedDomainControllerDomain:$memberUsesDcDomain
        }
        catch { Add-BuildManifestLogEntry -Manifest $buildManifest -Level WARN -Message "could not record the domain rows: $($_.Exception.Message)" }
        $identityMismatches = @(Compare-DomainControllerIdentity -Identity $domainControllerIdentity -ExpectedDomainName $domainIdentity.DomainName `
            -ExpectedDomainSource $domainIdentitySource)
        if ($identityMismatches.Count -gt 0) {
            throw "Nothing was moved: the VM at '$vmxFilePath' does not match this run: $($identityMismatches -join '; '). Check -VmStoragePath and -VmName, the build profile, and new-AdDomain's override file and global-config.ps1."
        }
        try { Add-BuildManifestVmRow -Manifest $buildManifest -VmName $VmName -Role 'ForestRoot' -Status 'Existing' -VmxPath $vmxFilePath -Identity $domainControllerIdentity } catch { Add-BuildManifestLogEntry -Manifest $buildManifest -Level WARN -Message "could not record the DC's rows: $($_.Exception.Message)" }

        $memberServerOuParameters = @{
            VmrunPath               = $vmrunPath
            VmxFilePath             = $vmxFilePath
            GuestCredential         = $guestCredential
            ServersOu               = $domainIdentity.ServersOU
            MemberServerNamePattern = $memberServerNamePattern
            HostStagingPath         = $stagingRootPath
        }

        $memberServerOuState = Get-GuestMemberServerOuState @memberServerOuParameters
        if (-not $memberServerOuState.ServersOuExists) {
            throw "'$($domainIdentity.ServersOU)' does not exist yet, so directory population has not run or has not finished. Wait for build-lab's population to finish, or, if the build used -DeferPopulation, log into the DC console as Administrator and wait for Initialize-ADDirectory.ps1 to finish, then re-run with -MoveMemberServers."
        }
        $memberServersToMove = @($memberServerOuState.InComputersContainer)
        $memberServersInOu   = @($memberServerOuState.InServersOu)
        Write-Log "Member servers in '$($memberServerOuState.ComputersContainer)': $(if ($memberServersToMove.Count) { $memberServersToMove -join ', ' } else { 'none' }). Already in '$($domainIdentity.ServersOU)': $(if ($memberServersInOu.Count) { $memberServersInOu -join ', ' } else { 'none' })." -Level INFO

        if ($memberServersToMove.Count -eq 0) {
            Write-Log "No member server computer objects to move." -Level WARN
        }
        else {
            if ($memberServersToMove.Count -gt $maxMemberServerCount) {
                throw "$($memberServersToMove.Count) member server computer objects match '$memberServerNamePattern', more than the cap of $maxMemberServerCount. Nothing was moved. Check the computers container for unexpected objects, or raise MaxMemberServerCount in overrides\overrides.psd1 (OVERRIDE.md lists it)."
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
            try { foreach ($movedMemberName in @($moveResult.Moved)) { Add-BuildManifestMovedMemberRow -Manifest $buildManifest -Name $movedMemberName } } catch { Add-BuildManifestLogEntry -Manifest $buildManifest -Level WARN -Message "could not record the moved members' rows: $($_.Exception.Message)" }
            Write-AppEvent -EnableEventLogging $enableEventLogging -SourceName $eventLogSourceName -EntryType Information -EventId 3000 -Message "Member servers moved to '$($domainIdentity.ServersOU)': $(@($memberServerOuState.InServersOu) -join ', ')."
        }
        $buildOutcome = 'Succeeded'
        Write-Log "=== build-lab.ps1 -MoveMemberServers complete ===" -Level SUCCESS
        $runCompleted = $true
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
        # With nothing naming a domain, the DC's own domain applies. The identity is final
        # here, before the member plan, the join credential and the joins use it.
        $domainControllerIdentity = Get-GuestMachineIdentity -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential `
            -HostStagingPath $stagingRootPath
        $memberDomainResolution = Resolve-MemberDomainIdentity -StagedIdentity $domainIdentity -DomainControllerIdentity $domainControllerIdentity -VmxFilePath $vmxFilePath
        if ($memberDomainResolution.Warning) {
            Write-Log $memberDomainResolution.Warning -Level WARN
        }
        $domainIdentity = $memberDomainResolution.Identity
        try {
            $memberUsesDcDomain = [bool]$memberDomainResolution.Warning -and [string]$domainIdentity.DomainName -eq [string](Get-BuildManifestField -InputObject $domainControllerIdentity -Name 'AdDomainDnsRoot')
            Set-BuildManifestDomainRow -Manifest $buildManifest -Identity $domainIdentity -EffectiveValues $domainEffectiveValues -UsedDomainControllerDomain:$memberUsesDcDomain
        }
        catch { Add-BuildManifestLogEntry -Manifest $buildManifest -Level WARN -Message "could not record the domain rows: $($_.Exception.Message)" }
        $identityMismatches = @(Compare-DomainControllerIdentity -Identity $domainControllerIdentity -ExpectedDomainName $domainIdentity.DomainName `
            -ExpectedDomainSource $domainIdentitySource -ExpectedIpAddress $StaticIpAddress -ExpectedPrefixLength $staticIpPrefixLength -ExpectedDefaultGateway $DefaultGateway)
        if ($identityMismatches.Count -gt 0) {
            # -SubnetMask and -DefaultGateway can come from build-lab's override file as well
            # as the command line, so the text names both places.
            $identityMismatchText = (@($identityMismatches) | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) + '.' }) -join ' '
            throw "No member servers were built, because the DC at '$vmxFilePath' does not match this run. $identityMismatchText Pass the DC's real -StaticIpAddress, -SubnetMask and -DefaultGateway. The last two can also come from build-lab's override file '$overrideFilePath', so check it too if it sets them. For the domain, check the build profile, new-AdDomain's override file and global-config.ps1."
        }
        $gatewayCheckDetail = if ($DefaultGateway) { "gateway $DefaultGateway matches" }
            elseif ($vmBuilderGateway) { "gateway not checked, because -DefaultGateway was not given, and the members get $vmBuilderGateway from New-VMwareWorkstationVM's override file" }
            else { 'gateway not checked and not set on the members, because -DefaultGateway was not given' }
        Write-Log "Existing DC verified ('$ntdsFilePath' present; domain and address match; $gatewayCheckDetail)." -Level SUCCESS
        try { Add-BuildManifestVmRow -Manifest $buildManifest -VmName $VmName -Role 'ForestRoot' -Status 'Existing' -VmxPath $vmxFilePath -Identity $domainControllerIdentity -PlannedAddress $StaticIpAddress } catch { Add-BuildManifestLogEntry -Manifest $buildManifest -Level WARN -Message "could not record the DC's rows: $($_.Exception.Message)" }

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
            throw "The member server count $MemberServerCount is above the cap of $maxMemberServerCount, so nothing was built. The count comes from -MemberServerCount, or from MemberServerCount in build-lab's override file '$overrideFilePath' when the command line doesn't give one. Lower the count where it was set, or raise MaxMemberServerCount in the same override file (OVERRIDE.md lists both)."
        }

        # The lowest free numbers, gaps first. Existing SRVR-NN folders and reserved names are
        # never reused (a leftover folder from a failed build would make the VM builder refuse
        # partway through the run), and each member's address follows its number.
        $memberNumbers     = @(Get-FreeMemberServerNumber -VmStoragePath $VmStoragePath -NamePrefix $memberServerNamePrefix -Count $MemberServerCount `
            -ReservedNames $reservedMemberNames)
        $memberIpAddresses = @(Get-MemberServerIpAddressList -DomainControllerIpAddress $StaticIpAddress -Offset $memberServerIpOffset `
            -MemberNumbers $memberNumbers -SubnetMask $effectiveSubnetMask -NetworkType $effectiveNetworkType -DefaultGateway $effectiveDefaultGateway)

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

    # The ISOs, hashed once the cheap checks above have passed and before any VM is built.
    if ($activeParameterSet -in @('Build', 'AddMembers')) {
        try { Add-BuildManifestIsoRow -Manifest $buildManifest -IsoPath $IsoPath -VmrunPath $vmrunPath -CachePath $isoHashCachePath } catch { Add-BuildManifestLogEntry -Manifest $buildManifest -Level WARN -Message "could not record the ISO rows: $($_.Exception.Message)" }
        Write-BuildManifest -Manifest $buildManifest
    }

    if (-not $AddMemberServers) {
        if ($SkipVmBuild) {
            Write-Log "-SkipVmBuild specified; reusing existing VM at '$vmxFilePath'." -Level INFO
        }
        else {
            Write-Log "Building VM '$VmName' via New-VMwareWorkstationVM.ps1. This usually takes 10-20 minutes, longer on slower storage..." -Level INFO
            $vmBuildParameters = Get-VmBuilderArgumentTable -IsoPath $IsoPath -AdminPassword $AdminPassword -VmName $VmName -VmStoragePath $VmStoragePath `
                -RamMB $RamMB -CpuCount $CpuCount -DiskGB $DiskGB -ComputerName $ComputerName -NetworkType $effectiveNetworkType `
                -StaticIpAddress $StaticIpAddress -SubnetMask $effectiveSubnetMask -DefaultGateway $DefaultGateway -DnsServer $DnsServer `
                -TimeoutMinutes $TimeoutMinutes -LogPath $logDirectoryPath -TempPath (Join-Path -Path $stagingRootPath -ChildPath "VMDeploy-$VmName")
            $null = & $VmBuilderScriptPath @vmBuildParameters
            # The VM builder only warns when the VM never answers on its address, so confirm it.
            if (-not (Wait-IpAddressResponds -IpAddress $StaticIpAddress)) {
                throw "VM '$VmName' was built but did not answer ping at $StaticIpAddress within 2 minutes, so the build is treated as failed. Check the VM console, and that $StaticIpAddress is in the subnet of the network it was built on, $effectiveNetworkType."
            }
            Write-Log "VM build complete; '$VmName' answers at $StaticIpAddress." -Level SUCCESS
            try { Add-BuildManifestVmRow -Manifest $buildManifest -VmName $VmName -Role 'ForestRoot' -Status 'Built' -VmxPath $vmxFilePath } catch { Add-BuildManifestLogEntry -Manifest $buildManifest -Level WARN -Message "could not record the DC's rows: $($_.Exception.Message)" }
            Write-BuildManifest -Manifest $buildManifest
            Write-AppEvent -EnableEventLogging $enableEventLogging -SourceName $eventLogSourceName -EntryType Information -EventId 3000 -Message "VM '$VmName' build complete."
        }

        Write-Log "Waiting for guest operations to become ready (timeout: $GuestReadyTimeoutMinutes minute(s))..." -Level INFO
        Wait-GuestOperationsReady -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential -TimeoutMinutes $GuestReadyTimeoutMinutes
        Write-Log "Guest operations ready." -Level SUCCESS

        if ($SkipVmBuild) {
            try { Add-BuildManifestVmRow -Manifest $buildManifest -VmName $VmName -Role 'ForestRoot' -Status 'Reused' -VmxPath $vmxFilePath } catch { Add-BuildManifestLogEntry -Manifest $buildManifest -Level WARN -Message "could not record the DC's rows: $($_.Exception.Message)" }
            Write-BuildManifest -Manifest $buildManifest
            # On a promoted DC the re-run would only do damage: the payload refresh deletes the
            # deployment and population logs, and the deployment's pre-flight then refuses.
            $ntdsFilePath = 'C:\Windows\NTDS\ntds.dit'
            if (Test-GuestPathExists -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential -PathType File -GuestPath $ntdsFilePath) {
                throw "The VM at '$vmxFilePath' is already a promoted domain controller ('$ntdsFilePath' present), so -SkipVmBuild stopped before changing it. A re-run would delete C:\temp\new-AdDomain (the deployment and population logs) and the deployment would then refuse to run. Use -AddMemberServers or -MoveMemberServers against this DC, or revert the VM to a pre-deployment snapshot to retry the deployment."
            }
        }

        # The zip is made from the staged folder checked above, not from a second copy.
        Write-Log "Zipping the staged new-AdDomain payload and copying it to the guest..." -Level INFO
        $payloadZipFilePath = New-AdDomainPayloadArchive -StagedPayloadPath $stagedPayloadPath -StagingRootPath $stagingRootPath
        Copy-PayloadToGuest -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential -PayloadZipFilePath $payloadZipFilePath
        Write-Log "Payload deployed to C:\temp\new-AdDomain in guest." -Level SUCCESS
        Write-AppEvent -EnableEventLogging $enableEventLogging -SourceName $eventLogSourceName -EntryType Information -EventId 3000 -Message 'new-AdDomain payload deployed to guest.'

        # The volatile boot marker, set just before the launch. Promotion is confirmed by it
        # being gone (a reboot since this point) plus the DC role (Test-GuestDomainPromotion).
        Set-GuestBootMarker -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential -HostStagingPath $stagingRootPath

        $deploymentLaunchError = Invoke-GuestAdForestDeployment -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential `
            -StaticIpAddress $StaticIpAddress -PrefixLength $staticIpPrefixLength -DefaultGateway $effectiveDefaultGateway -CreateScheduledTask:$DeferPopulation
        # A launch that vmrun reported as failed gets no success event. The run goes on to the
        # promotion check, which names the launch error if promotion never appears.
        if (-not $deploymentLaunchError) {
            Write-AppEvent -EnableEventLogging $enableEventLogging -SourceName $eventLogSourceName -EntryType Information -EventId 3000 -Message "New-ADForestDeployment.ps1$(if ($DeferPopulation) { ' -CreateScheduledTask' }) launched in guest."
        }

        $promotionResult = Test-GuestDomainPromotion -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential `
            -GuestReadyTimeoutMinutes $GuestReadyTimeoutMinutes -DeploymentTimeoutMinutes $DeploymentTimeoutMinutes -HostLogsRootPath $logDirectoryPath `
            -HostStagingPath $stagingRootPath -ExpectedDomainName $domainIdentity.DomainName -LaunchErrorMessage $deploymentLaunchError `
            -ScheduledTaskRequested:$DeferPopulation
        if ($promotionResult.HostLogsPath) {
            Write-Log "Guest deployment logs retrieved to '$($promotionResult.HostLogsPath)'." -Level INFO
            try { Set-BuildManifestValue -Manifest $buildManifest -Section 'GuestLogs' -Item 'deployment' -Field 'Folder' -Value $promotionResult.HostLogsPath } catch { Add-BuildManifestLogEntry -Manifest $buildManifest -Level WARN -Message "could not record the deployment logs row: $($_.Exception.Message)" }
        }
        # An unverified promotion fails the run whether or not members were requested, so it
        # can never end in the success footer and the "promotion succeeded" banner.
        if (-not $promotionResult.PromotionVerified) {
            $logsDetail = if ($promotionResult.HostLogsPath) { " Retrieved guest logs: '$($promotionResult.HostLogsPath)'." } else { '' }
            throw "AD forest promotion was not verified: $($promotionResult.NotVerifiedReason). No member servers were built. See the warnings above.$logsDetail"
        }
        Write-AppEvent -EnableEventLogging $enableEventLogging -SourceName $eventLogSourceName -EntryType Information -EventId 3000 -Message "AD forest promotion verified (ntds.dit present, the DC rebooted, and it is a DC in '$($domainIdentity.DomainName)')."
        # Directory population, started here over vmrun unless -DeferPopulation left it to
        # the logon task. Members are built only after it succeeds. The outcome hook,
        # $populationOutcome, is set for every outcome before a failure ends the run, with
        # the launch ID and the folder the results were retrieved to.
        if ($DeferPopulation) {
            $populationOutcome = [pscustomobject]@{ Outcome = 'Deferred'; Marker = $null; LaunchError = $null; LaunchId = $null; HostLogsPath = $null }
            try { Add-BuildManifestPopulationRow -Manifest $buildManifest -Outcome $populationOutcome -Settings $populationSettings } catch { Add-BuildManifestLogEntry -Manifest $buildManifest -Level WARN -Message "could not record the population rows: $($_.Exception.Message)" }
            Write-BuildManifest -Manifest $buildManifest
        }
        else {
            Write-Log "Waiting for the DC's directory to answer before starting directory population (timeout: $GuestReadyTimeoutMinutes minute(s))..." -Level INFO
            Wait-GuestDirectoryReady -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential -ExpectedDomainName $domainIdentity.DomainName `
                -HostStagingPath $stagingRootPath -TimeoutMinutes $GuestReadyTimeoutMinutes
            # The values that already name this run's staging folder.
            $populationLaunchId    = "$runTimestamp-$PID"
            $populationLaunchError = Invoke-GuestDirectoryPopulation -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential -LaunchId $populationLaunchId
            if (-not $populationLaunchError) {
                Write-AppEvent -EnableEventLogging $enableEventLogging -SourceName $eventLogSourceName -EntryType Information -EventId 3000 -Message "Directory population launched in guest (launch '$populationLaunchId')."
            }
            $populationResult = Test-GuestDirectoryPopulation -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential -LaunchId $populationLaunchId `
                -HostStagingPath $stagingRootPath -StartTimeoutMinutes $GuestReadyTimeoutMinutes -PopulationTimeoutMinutes $PopulationTimeoutMinutes -LaunchErrorMessage $populationLaunchError
            $populationCopy = Copy-GuestPopulationResultToHost -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential `
                -HostLogsRootPath $logDirectoryPath -Marker $populationResult.Marker
            $populationOutcome = [pscustomobject]@{
                Outcome      = $populationResult.Outcome
                Marker       = $populationResult.Marker
                LaunchError  = $populationResult.LaunchError
                LaunchId     = $populationLaunchId
                HostLogsPath = $populationCopy.Path
            }
            try { Add-BuildManifestPopulationRow -Manifest $buildManifest -Outcome $populationOutcome -Settings $populationSettings } catch { Add-BuildManifestLogEntry -Manifest $buildManifest -Level WARN -Message "could not record the population rows: $($_.Exception.Message)" }
            Write-BuildManifest -Manifest $buildManifest
            $populationLogsText = if ($populationCopy.Path) { "'$($populationCopy.Path)'" } else { "none (they are in C:\temp\new-AdDomain in the guest)" }
            if ($populationCopy.Path) {
                Write-Log "Directory population's logs and results retrieved to '$($populationCopy.Path)'." -Level INFO
            }
            if ($null -ne $populationResult.Marker) {
                $populationMarker = $populationResult.Marker
                $markerFields = @($populationMarker.PSObject.Properties.Name)
                $markerValue = { param ([string]$FieldName) if ($markerFields -contains $FieldName) { $populationMarker.$FieldName } else { $null } }
                # The seed actually used, from the marker. A null seed there means the run
                # stopped before setting one, so a seed given on the host is named instead.
                $populationSeedText = if ($null -ne (& $markerValue 'RandomSeed')) { "$(& $markerValue 'RandomSeed') ($(& $markerValue 'RandomSeedSource'))" }
                    elseif ($null -ne $populationSettings -and [string]$populationSettings.PopulationSeed -ne 'Random') { "$($populationSettings.PopulationSeed) (given, not reached)" }
                    else { 'not drawn' }
                Write-Log "Directory population $(& $markerValue 'State') in the guest: Population=$(& $markerValue 'Population'), DomainAdminCount=$(& $markerValue 'DomainAdminCount'), seed $populationSeedText; $(& $markerValue 'UsersCreated') users, $(& $markerValue 'GroupsCreated') groups and $(& $markerValue 'DomainAdminsAdded') Domain Admins added; test rows $(& $markerValue 'TestsPassed') passed, $(& $markerValue 'TestsFailed') failed." -Level INFO
                foreach ($failedTestRow in @(& $markerValue 'FailedTests' | Where-Object { $null -ne $_ })) {
                    $failedTestFields = @($failedTestRow.PSObject.Properties.Name)
                    $failedTestName   = if ($failedTestFields -contains 'TestName') { $failedTestRow.TestName } else { '' }
                    $failedTestDetail = if ($failedTestFields -contains 'Detail') { $failedTestRow.Detail } else { '' }
                    Write-Log "Population test row failed: $failedTestName -- $failedTestDetail" -Level WARN
                }
            }
            switch ($populationOutcome.Outcome) {
                'Succeeded' {
                    Write-Log 'Directory population finished in the guest.' -Level SUCCESS
                    Write-AppEvent -EnableEventLogging $enableEventLogging -SourceName $eventLogSourceName -EntryType Information -EventId 3000 -Message "Directory population finished in guest (launch '$populationLaunchId'): test rows $(& $markerValue 'TestsPassed') passed, $(& $markerValue 'TestsFailed') failed."
                }
                'Failed' {
                    $populationErrorText = ([string](& $markerValue 'Error')).Trim().TrimEnd('.')
                    if (-not $populationErrorText) { $populationErrorText = 'the marker names no error' }
                    throw "Directory population failed in the guest: $populationErrorText. No member servers were built. Retrieved logs: $populationLogsText."
                }
                default {
                    throw "$($populationResult.Reason) No member servers were built. Retrieved logs: $populationLogsText."
                }
            }
        }
        # The DC's own rows from the guest, once promotion is verified and population is
        # done (a population that failed has already ended the run). One short read with no
        # retry, so a guest that stopped answering costs minutes, not the retry's hour.
        $domainControllerReadIdentity = $null
        $domainControllerReadError    = $null
        try { $domainControllerReadIdentity = Get-GuestMachineIdentity -VmrunPath $vmrunPath -VmxFilePath $vmxFilePath -GuestCredential $guestCredential -HostStagingPath $stagingRootPath -NoRetry -VmrunTimeoutSeconds 120 }
        catch { $domainControllerReadError = $_.Exception.Message }
        try { Add-BuildManifestVmRow -Manifest $buildManifest -VmName $VmName -Identity $domainControllerReadIdentity -ReadError $domainControllerReadError -PlannedAddress $StaticIpAddress } catch { Add-BuildManifestLogEntry -Manifest $buildManifest -Level WARN -Message "could not record the DC's rows: $($_.Exception.Message)" }
        Write-BuildManifest -Manifest $buildManifest
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
                    -ComputerName $memberServer.Name -NetworkType $effectiveNetworkType -StaticIpAddress $memberServer.IpAddress -SubnetMask $effectiveSubnetMask `
                    -DefaultGateway $DefaultGateway -DnsServer $StaticIpAddress -TimeoutMinutes $TimeoutMinutes -LogPath $logDirectoryPath `
                    -TempPath (Join-Path -Path $stagingRootPath -ChildPath "VMDeploy-$($memberServer.Name)")
                $null = & $VmBuilderScriptPath @memberBuildParameters
                # The VM builder only warns when the VM never answers on its address, so confirm it.
                if (-not (Wait-IpAddressResponds -IpAddress $memberServer.IpAddress)) {
                    throw "VM '$($memberServer.Name)' was built but did not answer ping at $($memberServer.IpAddress) within 2 minutes, so the build is treated as failed. Check the VM console."
                }
                Write-Log "VM '$($memberServer.Name)' build complete; it answers at $($memberServer.IpAddress)." -Level SUCCESS
                Write-AppEvent -EnableEventLogging $enableEventLogging -SourceName $eventLogSourceName -EntryType Information -EventId 3000 -Message "Member server VM '$($memberServer.Name)' build complete."

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

                Write-AppEvent -EnableEventLogging $enableEventLogging -SourceName $eventLogSourceName -EntryType Information -EventId 3000 -Message "Member server '$($memberServer.Name)' joined to '$($domainIdentity.DomainName)'."
                $memberServerResults += [pscustomobject]@{ Name = $memberServer.Name; IpAddress = $memberServer.IpAddress; Status = 'Joined'; Detail = '' }
            }
            catch {
                $memberFailureMessage = $_.Exception.Message
                Write-Log "Member server '$($memberServer.Name)' failed: $memberFailureMessage Continuing with the remaining member servers." -Level ERROR
                Write-AppEvent -EnableEventLogging $enableEventLogging -SourceName $eventLogSourceName -EntryType Error -EventId 9000 -Message "Member server '$($memberServer.Name)' failed: $memberFailureMessage"
                $memberServerResults += [pscustomobject]@{ Name = $memberServer.Name; IpAddress = $memberServer.IpAddress; Status = 'Failed'; Detail = $memberFailureMessage }
            }
            # The member's rows, after its own try, so nothing the manifest does can fail it. A
            # joined member gets one short guest read, a failed one its plan only.
            $memberManifestStatus = $memberServerResults[$memberServerResults.Count - 1].Status
            $memberReadIdentity = $null
            $memberReadError    = $null
            if ($memberManifestStatus -eq 'Joined') {
                try { $memberReadIdentity = Get-GuestMachineIdentity -VmrunPath $vmrunPath -VmxFilePath $memberServer.VmxFilePath -GuestCredential $guestCredential -HostStagingPath $stagingRootPath -NoRetry -VmrunTimeoutSeconds 120 }
                catch { $memberReadError = $_.Exception.Message }
            }
            try {
                Add-BuildManifestVmRow -Manifest $buildManifest -VmName $memberServer.Name -Role 'Member' -Status $memberManifestStatus -VmxPath $memberServer.VmxFilePath `
                    -Identity $memberReadIdentity -ReadError $memberReadError -PlannedAddress $memberServer.IpAddress -PlannedAddressOnly:($memberManifestStatus -ne 'Joined')
            }
            catch { Add-BuildManifestLogEntry -Manifest $buildManifest -Level WARN -Message "could not record the member's rows: $($_.Exception.Message)" }
            Write-BuildManifest -Manifest $buildManifest
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
        $buildOutcome = 'MemberFailures'
        Write-Log "=== build-lab.ps1 finished with member server failures ===" -Level ERROR
    }
    else {
        $buildOutcome = 'Succeeded'
        Write-Log "=== build-lab.ps1 complete ===" -Level SUCCESS
    }

    # The "population has not run" notice is for a build that left population to the logon
    # task. -AddMemberServers ran against an existing DC whose population state is unknown,
    # and a build that ran population here has nothing left to say about it.
    $populationRanHere = $null -ne $populationOutcome -and $populationOutcome.Outcome -eq 'Succeeded'
    if (-not $AddMemberServers -and $DeferPopulation) {
        Write-Log "Directory population has NOT run yet. Log into the guest console as Administrator to trigger Initialize-ADDirectory.ps1 (registered as a logon-triggered scheduled task)." -Level INFO
    }
    if ($joinedMemberServerNames.Count -gt 0) {
        if ($populationRanHere) {
            Write-Log "Member servers $($joinedMemberServerNames -join ', ') are in the default CN=Computers container. Re-run with -MoveMemberServers to move them to OU=Servers." -Level INFO
        }
        else {
            Write-Log "Member servers $($joinedMemberServerNames -join ', ') are in the default CN=Computers container. Once directory population has finished, re-run with -MoveMemberServers to move them to OU=Servers." -Level INFO
        }
    }
    Show-PostBuildManualStepNotice -JoinedMemberServerNames $joinedMemberServerNames -OmitPopulationNotice:($AddMemberServers -or -not $DeferPopulation) -PopulationFinished:$populationRanHere

    if ($failedMemberServerNames.Count -gt 0) {
        throw "$($failedMemberServerNames.Count) of $($memberServerPlan.Count) member server(s) failed: $($failedMemberServerNames -join ', '). The DC is verified; see the member server summary above for each failure."
    }
    $runCompleted = $true
}
catch {
    if ($buildOutcome -eq 'Running') { $buildOutcome = 'Failed' }
    Write-Log "build-lab.ps1 failed: $($_.Exception.Message)" -Level FATAL
    Write-AppEvent -EnableEventLogging $enableEventLogging -SourceName $eventLogSourceName -EntryType Error -EventId 9000 -Message "build-lab.ps1 failed: $($_.Exception.Message)"
    throw
}
finally {
    $guestPasswordPlainText = $null
    $guestCredential        = $null
    $domainJoinCredential   = $null
    # The manifest's last save, before the staging folder is deleted. An outcome still
    # Running means neither the try nor the catch finished, as after CTRL+C.
    if ($buildOutcome -eq 'Running') { $buildOutcome = 'Interrupted' }
    try {
        Set-BuildManifestValue -Manifest $buildManifest -Section 'Run' -Item 'build-lab' -Field 'Ended' -Value (Get-Date).ToString('o')
        Set-BuildManifestValue -Manifest $buildManifest -Section 'Run' -Item 'build-lab' -Field 'Outcome' -Value $buildOutcome
    }
    catch { Add-BuildManifestLogEntry -Manifest $buildManifest -Level WARN -Message "could not record the run's end: $($_.Exception.Message)" }
    Write-BuildManifest -Manifest $buildManifest -Outcome $buildOutcome
    if (Test-Path -LiteralPath $stagingRootPath) {
        Remove-Item -LiteralPath $stagingRootPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($runCompleted) {
        Write-AppEvent -EnableEventLogging $enableEventLogging -SourceName $eventLogSourceName -EntryType Information -EventId 1001 -Message 'build-lab.ps1 finished.'
    }
    else {
        Write-AppEvent -EnableEventLogging $enableEventLogging -SourceName $eventLogSourceName -EntryType Error -EventId 1002 -Message 'build-lab.ps1 stopped before it finished. The FATAL line in its log says why.'
    }
}

#endregion Main
