@{
    # The settings build-lab.ps1 reads from overrides\overrides.psd1. OVERRIDE.md is
    # generated from this file, so a change here is followed by a fresh OVERRIDE.md. The
    # offline suite checks both against the script.
    Project  = 'build-lab'
    Settings = @{
        AdDomainSourcePath = @{
            Target        = 'Parameter'
            Name          = 'AdDomainSourcePath'
            ExampleNote   = 'The new-AdDomain folder build-lab stages, checks and copies into the DC'
            ShippedText   = 'The `new-AdDomain` folder beside build-lab''s folder'
            ShippedReason = 'The three lab projects are cloned or extracted side by side, so build-lab finds new-AdDomain without being told'
            ValuesNote    = 'A relative path in the override file resolves from build-lab''s folder, not the folder the run was started from'
            Rule          = @{ Type = 'String'; MinLength = 1; Description = 'the path of a new-AdDomain folder' }
        }
        ComputerName = @{
            Target        = 'Parameter'
            Name          = 'ComputerName'
            ExampleNote   = 'The Windows computer name the DC gets'
            Shipped       = 'WIN2025'
            ShippedReason = 'A short name that says what the DC runs and fits the 15-character NetBIOS limit'
            OverrideNote  = 'build-lab passes it to New-VMwareWorkstationVM for the DC, so it wins over that project''s override file'
        }
        CpuCount = @{
            Target        = 'Parameter'
            Name          = 'CpuCount'
            ExampleNote   = 'How many virtual CPUs the DC gets'
            Shipped       = 2
            ShippedReason = 'Enough for Windows Setup and forest promotion without crowding the host'
            OverrideNote  = 'build-lab passes it to New-VMwareWorkstationVM for the DC, so it wins over that project''s override file'
        }
        DefaultGateway = @{
            Target        = 'Parameter'
            Name          = 'DefaultGateway'
            ExampleNote   = 'The default gateway every VM gets'
            ShippedText   = 'None'
            ShippedReason = 'The gateway differs per host and network, so build-lab can''t guess one'
            OverrideNote  = 'build-lab passes it to New-VMwareWorkstationVM for every VM when it has one, and then it wins over that project''s override file. When it has none, a DefaultGateway in that file applies, and build-lab logs it and checks it against the DC''s subnet'
        }
        DeferPopulation = @{
            Target        = 'Parameter'
            Name          = 'DeferPopulation'
            ExampleNote   = 'Whether population waits for a console logon instead of starting unattended'
            Shipped       = $false
            ShippedReason = 'A full build populates the directory unattended unless asked not to'
            ValuesNote    = 'Used only by a full build and -SkipVmBuild'
            Rule          = @{ Type = 'Boolean' }
        }
        DeploymentTimeoutMinutes = @{
            Target        = 'Parameter'
            Name          = 'DeploymentTimeoutMinutes'
            ExampleNote   = 'The longest wait for ntds.dit after the forest deployment starts, in minutes'
            Shipped       = 30
            ShippedReason = 'Covers installing AD DS and promoting the forest on a slow guest'
        }
        DiskGB = @{
            Target        = 'Parameter'
            Name          = 'DiskGB'
            ExampleNote   = 'The size of the DC''s disk, in GB'
            Shipped       = 60
            ShippedReason = 'Room for Windows Server 2025 with Desktop Experience and a domain controller, on a sparse disk that grows only as it fills'
            OverrideNote  = 'build-lab passes it to New-VMwareWorkstationVM for the DC, so it wins over that project''s override file'
        }
        DnsServer = @{
            Target        = 'Parameter'
            Name          = 'DnsServer'
            ExampleNote   = 'The DNS server the DC uses during its build'
            Shipped       = '8.8.8.8'
            ShippedReason = 'A public resolver the DC can use during its build, before it runs DNS itself'
            OverrideNote  = 'build-lab passes it to New-VMwareWorkstationVM for the DC, so it wins over that project''s override file. Members always use the DC'
        }
        DomainJoinTimeoutMinutes = @{
            Target        = 'Parameter'
            Name          = 'DomainJoinTimeoutMinutes'
            ExampleNote   = 'The longest wait for each member''s join reboot and domain membership, in minutes'
            Shipped       = 20
            ShippedReason = 'Covers the reboot after the join and the wait until the member reports the domain'
        }
        EnableEventLogging = @{
            Target        = 'Constant'
            Name          = 'enableEventLogging'
            Shipped       = $true
            Summary       = 'Whether build-lab writes its key events to the Windows Application event log'
            ShippedReason = 'Key events in the event log let a SIEM or an event viewer follow each build'
            ValuesNote    = 'Events are written only after Register-EventLogSource.ps1 has registered the build-lab source on the host'
            Rule          = @{ Type = 'Boolean' }
        }
        GuestReadyTimeoutMinutes = @{
            Target        = 'Parameter'
            Name          = 'GuestReadyTimeoutMinutes'
            ExampleNote   = 'The longest wait for a guest, the DC reboot, its directory or population, in minutes'
            Shipped       = 20
            ShippedReason = 'Long enough for a new guest to start VMware Tools, and for the DC to come back from its promotion reboot'
        }
        MaxMemberServerCount = @{
            Target        = 'Constant'
            Name          = 'maxMemberServerCount'
            Shipped       = 5
            Summary       = 'The most member servers one run builds, and the most computer objects -MoveMemberServers moves at once'
            ShippedReason = 'A scope limit, so a mistyped -MemberServerCount can''t start dozens of VM builds'
            ValuesNote    = 'Members are named SRVR-01 to SRVR-99, so 99 is the most the numbering allows'
            Rule          = @{ Type = 'Integer'; Minimum = 1; Maximum = 99 }
        }
        MemberCpuCount = @{
            Target        = 'Parameter'
            Name          = 'MemberCpuCount'
            ExampleNote   = 'How many virtual CPUs each member server gets'
            Shipped       = 1
            ShippedReason = 'A plain member server needs little, and several of them share the host with the DC'
            OverrideNote  = 'build-lab passes it to New-VMwareWorkstationVM as -CpuCount for each member, so it wins over that project''s override file'
        }
        MemberDiskGB = @{
            Target        = 'Parameter'
            Name          = 'MemberDiskGB'
            ExampleNote   = 'The size of each member server''s disk, in GB'
            Shipped       = 60
            ShippedReason = 'Room for Windows Server 2025 with Desktop Experience, on a sparse disk that grows only as it fills'
            OverrideNote  = 'build-lab passes it to New-VMwareWorkstationVM as -DiskGB for each member, so it wins over that project''s override file'
        }
        MemberRamMB = @{
            Target        = 'Parameter'
            Name          = 'MemberRamMB'
            ExampleNote   = 'The memory each member server gets, in MB'
            Shipped       = 2048
            ShippedReason = 'Enough for a member server with Desktop Experience, small enough to run several beside the DC'
            OverrideNote  = 'build-lab passes it to New-VMwareWorkstationVM as -RamMB for each member, so it wins over that project''s override file'
        }
        MemberServerCount = @{
            Target        = 'Parameter'
            Name          = 'MemberServerCount'
            ExampleNote   = 'How many member servers a full build makes and joins to the domain'
            Shipped       = 0
            ShippedReason = 'A full build makes the DC alone unless you ask for members'
            ValuesNote    = 'MaxMemberServerCount caps it. -SkipVmBuild and -MoveMemberServers build no members and leave it unused'
        }
        NetworkType = @{
            Target        = 'Parameter'
            Name          = 'NetworkType'
            ExampleNote   = 'The VMware network every VM''s adapter connects to'
            Shipped       = 'nat'
            ShippedReason = 'NAT gives every VM internet access through the host with no change to the host''s own network'
            OverrideNote  = 'build-lab passes it to New-VMwareWorkstationVM for every VM, so it wins over that project''s override file. A build profile''s NetworkType also sets it, and wins over this file'
            ValuesNote    = 'nat, bridged, hostonly, or VMnet0 to VMnet99 with no leading zero. VMnet0, VMnet1 and VMnet8 are taken as bridged, hostonly and nat. A custom VMnet must already exist. The online check needs a host virtual adapter on it, and build-lab looks for that adapter before it builds anything'
        }
        PopulationTimeoutMinutes = @{
            Target        = 'Parameter'
            Name          = 'PopulationTimeoutMinutes'
            ExampleNote   = 'The longest wait for directory population to finish, in minutes'
            Shipped       = 240
            ShippedReason = 'The logon task''s own four-hour limit'
            ValuesNote    = 'Used only when population runs unattended'
        }
        RamMB = @{
            Target        = 'Parameter'
            Name          = 'RamMB'
            ExampleNote   = 'The memory the DC gets, in MB'
            Shipped       = 4096
            ShippedReason = 'Comfortable for a Windows Server 2025 domain controller with Desktop Experience, and small enough for most hosts'
            OverrideNote  = 'build-lab passes it to New-VMwareWorkstationVM for the DC, so it wins over that project''s override file'
        }
        SubnetMask = @{
            Target        = 'Parameter'
            Name          = 'SubnetMask'
            ExampleNote   = 'The subnet mask every VM gets'
            Shipped       = '255.255.255.0'
            ShippedReason = 'Workstation allocates its NAT network as a /24'
            OverrideNote  = 'build-lab passes it to New-VMwareWorkstationVM for every VM, so it wins over that project''s override file'
            ValuesNote    = 'When neither the command line nor this file gives it, a full build or an -AddMemberServers run takes the prefix of the host adapter that holds the DC''s subnet, and logs it'
        }
        TimeoutMinutes = @{
            Target        = 'Parameter'
            Name          = 'TimeoutMinutes'
            ExampleNote   = 'The longest wait for each VM to come online after it starts, in minutes'
            Shipped       = 90
            ShippedReason = 'Covers a full unattended install on a slow host with room to spare'
            OverrideNote  = 'build-lab passes it to New-VMwareWorkstationVM for every VM, so it wins over that project''s override file'
        }
        VmBuilderScriptPath = @{
            Target        = 'Parameter'
            Name          = 'VmBuilderScriptPath'
            ExampleNote   = 'The New-VMwareWorkstationVM.ps1 that builds each VM'
            ShippedText   = '`New-VMwareWorkstationVM.ps1` in the `New-VMwareWorkstationVM` folder beside build-lab''s folder'
            ShippedReason = 'The three lab projects are cloned or extracted side by side, so build-lab finds the VM builder without being told'
            ValuesNote    = 'A relative path in the override file resolves from build-lab''s folder, not the folder the run was started from'
            Rule          = @{ Type = 'String'; MinLength = 1; Description = 'the path of New-VMwareWorkstationVM.ps1' }
        }
        VmName = @{
            Target        = 'Parameter'
            Name          = 'VmName'
            ExampleNote   = 'The DC''s VM name, which also names its folder and VMX file'
            Shipped       = 'WS2025-Server'
            ShippedReason = 'Names the operating system the DC runs, the same default New-VMwareWorkstationVM uses'
            OverrideNote  = 'build-lab passes it to New-VMwareWorkstationVM for the DC, so it wins over that project''s override file'
        }
    }
    Siblings = @{
        'New-VMwareWorkstationVM' = @('Edition', 'GuestOS', 'ImageNameDatacenter', 'ImageNameStandard', 'InputLocale', 'LogPath', 'Organization', 'PostSetupDelayMinutes', 'ProductKey', 'RestartTimeoutMinutes', 'ShowConsole', 'ShutdownTimeoutMinutes', 'SystemLocale', 'TempPath', 'TimeZone', 'UserLocale')
        'new-AdDomain'            = @('CaCommonName', 'CaDatabasePath', 'CaHashAlgorithm', 'CaKeyLength', 'CaLogPath', 'CaValidityYears', 'ComputerCount', 'DnsForwarders', 'DomainAdminCount', 'DomainMode', 'DomainName', 'DsrmPassword', 'ForestMode', 'GroupCount', 'LaptopPrefix', 'LockoutDurationMinutes', 'LockoutThreshold', 'MaxCompanyCount', 'MaxDA', 'MaxGroupMembers', 'MaxGroupNestingDepth', 'MaxPasswordAgeDays', 'MinCompanyCount', 'MinDA', 'MinGroupMembers', 'MinPasswordLength', 'NetBIOSName', 'NtpServers', 'PasswordHistoryCount', 'PasswordLength', 'PctDisabled', 'PctLocked', 'PctPwExpired', 'PctPwNeverExpires', 'PctRemoteUsers', 'PctSmartcard', 'Population', 'PrimarySiteName', 'PrimarySubnet', 'RandomSeed', 'RequiredOSBuild', 'ServerPrefix', 'UpnPattern', 'UserCount', 'WorkstationPrefix')
    }
    Document = @{
        NotCovered = @(
            @{ Name = 'AddMemberServers'; Reason = 'A mode switch, chosen for each run' }
            @{ Name = 'AdminPassword'; Reason = 'A credential, and mandatory, so it is passed for each run and never stored as a setting' }
            @{ Name = 'IsoPath'; Reason = 'The ISO is chosen for each run' }
            @{ Name = 'MoveMemberServers'; Reason = 'A mode switch, chosen for each run' }
            @{ Name = 'ProfilePath'; Reason = 'A build profile is chosen for each build. A standing domain belongs in new-AdDomain''s override file instead' }
            @{ Name = 'SkipVmBuild'; Reason = 'A mode switch, chosen for each run' }
            @{ Name = 'StaticIpAddress'; Reason = 'Each DC needs its own address' }
            @{ Name = 'VMware Workstation install folder'; Reason = 'build-lab searches the two standard Program Files folders for vmrun.exe. A Workstation installed elsewhere needs a script change' }
            @{ Name = 'VmStoragePath'; Reason = 'Mandatory, and where the VMs go is chosen for each run' }
            @{ Name = 'buildManifestPath'; Reason = 'The build manifest is written to the logs folder, named after the run like its log' }
            @{ Name = 'eventLogSourceName'; Reason = 'It names the event log source registered for build-lab, which a change would orphan' }
            @{ Name = 'guestUserName'; Reason = 'The built-in Administrator account vmrun signs in to every guest with' }
            @{ Name = 'isoHashCachePath'; Reason = 'The ISO hash cache sits in the logs folder. Delete it to make the next run hash every ISO again' }
            @{ Name = 'logDirectoryPath'; Reason = 'The logs folder beside the script, where the VM builder and the guest logs land too' }
            @{ Name = 'memberServerIpOffset'; Reason = 'Each member''s address follows its number, so a change would move members away from the addresses earlier runs gave them' }
            @{ Name = 'memberServerNamePrefix'; Reason = 'A change would stop -MoveMemberServers and the numbering from finding members built before it' }
            @{ Name = 'scriptVersion'; Reason = 'It names the release that runs' }
            @{ Name = 'stagingRootPath'; Reason = 'A folder per run under the temp folder, deleted when the run ends' }
        )
        Security = @(
            'build-lab copies new-AdDomain, its overrides folder included, into the DC, where it stays at `C:\temp\new-AdDomain` after the build. new-AdDomain''s OVERRIDE.md says which of its settings are secret'
        )
    }
}
