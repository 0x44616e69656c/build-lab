# Example override file for build-lab. Each release generates it from
# include\override-catalog.psd1 and replaces it, so don't edit it here.
#
# No run reads this file. To use it, copy the lines you need into the @{ } of
# overrides\overrides.psd1 in the project folder, or copy this whole file there.
# Then remove the # in front of each setting you want to change and set your value.
# Leave the others commented out, because a setting you uncomment counts as one you
# chose, even at its shipped value. A setting left commented out keeps its shipped
# value, and follows that value when a later release changes it.
#
# Every value shown is the shipped one, so a copy left as it is changes nothing.
# A setting shown with no value has no default that can be written here. Give it
# a value before you remove its #, or the run stops.
#
# OVERRIDE.md lists the values each setting accepts, why it ships as it does, and
# what else can set it. Save the file as UTF-8 with a BOM if you add non-ASCII text.

@{
    # The new-AdDomain folder build-lab stages, checks and copies into the DC.
    # Shipped default, in words. The new-AdDomain folder beside build-lab's folder.
    # AdDomainSourcePath =

    # The Windows computer name the DC gets.
    # ComputerName = 'WIN2025'

    # How many virtual CPUs the DC gets.
    # CpuCount = 2

    # The default gateway every VM gets.
    # Shipped default, in words. None.
    # DefaultGateway =

    # Whether population waits for a console logon instead of starting unattended.
    # DeferPopulation = $false

    # The longest wait for ntds.dit after the forest deployment starts, in minutes.
    # DeploymentTimeoutMinutes = 30

    # The size of the DC's disk, in GB.
    # DiskGB = 60

    # The DNS server the DC uses during its build.
    # DnsServer = '8.8.8.8'

    # The longest wait for each member's join reboot and domain membership, in minutes.
    # DomainJoinTimeoutMinutes = 20

    # Whether build-lab writes its key events to the Windows Application event log.
    # EnableEventLogging = $true

    # The longest wait for a guest, the DC reboot, its directory or population, in minutes.
    # GuestReadyTimeoutMinutes = 20

    # The most member servers one run builds, and the most computer objects -MoveMemberServers moves at once.
    # MaxMemberServerCount = 5

    # How many virtual CPUs each member server gets.
    # MemberCpuCount = 1

    # The size of each member server's disk, in GB.
    # MemberDiskGB = 60

    # The memory each member server gets, in MB.
    # MemberRamMB = 2048

    # How many member servers a full build makes and joins to the domain.
    # MemberServerCount = 0

    # The VMware network every VM's adapter connects to.
    # NetworkType = 'nat'

    # The longest wait for directory population to finish, in minutes.
    # PopulationTimeoutMinutes = 240

    # The memory the DC gets, in MB.
    # RamMB = 4096

    # The subnet mask every VM gets.
    # SubnetMask = '255.255.255.0'

    # The longest wait for each VM to come online after it starts, in minutes.
    # TimeoutMinutes = 90

    # The New-VMwareWorkstationVM.ps1 that builds each VM.
    # Shipped default, in words. New-VMwareWorkstationVM.ps1 in the New-VMwareWorkstationVM folder beside build-lab's folder.
    # VmBuilderScriptPath =

    # The DC's VM name, which also names its folder and VMX file.
    # VmName = 'WS2025-Server'
}
