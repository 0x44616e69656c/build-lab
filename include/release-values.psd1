@{
    FormatVersion = 1
    Project = 'build-lab'
    Releases = @{
        '1.0' = @{
            Tag = 'v1.0'
            HeaderVersion = '1.0.0'
            Settings = @{
                AdDomainSourcePath = @{ NoDefault = $true }
                ComputerName = @{ Constant = 'WIN2025' }
                CpuCount = @{ Constant = 2 }
                DefaultGateway = @{ NoDefault = $true }
                DeploymentTimeoutMinutes = @{ Constant = 30 }
                DiskGB = @{ Constant = 60 }
                DnsServer = @{ Constant = '8.8.8.8' }
                EnableEventLogging = @{ Constant = $true }
                GuestReadyTimeoutMinutes = @{ Constant = 20 }
                NetworkType = @{ Constant = 'nat' }
                RamMB = @{ Constant = 4096 }
                SubnetMask = @{ Constant = '255.255.255.0' }
                TimeoutMinutes = @{ Constant = 90 }
                VmBuilderScriptPath = @{ NoDefault = $true }
                VmName = @{ Constant = 'WS2025-Server' }
            }
        }
        '2.0.0' = @{
            Tag = 'v2.0.0'
            HeaderVersion = '2.0.0'
            Settings = @{
                AdDomainSourcePath = @{ NoDefault = $true }
                ComputerName = @{ Constant = 'WIN2025' }
                CpuCount = @{ Constant = 2 }
                DefaultGateway = @{ NoDefault = $true }
                DeploymentTimeoutMinutes = @{ Constant = 30 }
                DiskGB = @{ Constant = 60 }
                DnsServer = @{ Constant = '8.8.8.8' }
                DomainJoinTimeoutMinutes = @{ Constant = 20 }
                EnableEventLogging = @{ Constant = $true }
                GuestReadyTimeoutMinutes = @{ Constant = 20 }
                MaxMemberServerCount = @{ Constant = 5 }
                MemberCpuCount = @{ Constant = 1 }
                MemberDiskGB = @{ Constant = 60 }
                MemberRamMB = @{ Constant = 2048 }
                MemberServerCount = @{ Constant = 0 }
                NetworkType = @{ Constant = 'nat' }
                RamMB = @{ Constant = 4096 }
                SubnetMask = @{ Constant = '255.255.255.0' }
                TimeoutMinutes = @{ Constant = 90 }
                VmBuilderScriptPath = @{ NoDefault = $true }
                VmName = @{ Constant = 'WS2025-Server' }
            }
        }
        '2.1.0' = @{
            Tag = 'v2.1.0'
            HeaderVersion = '2.1.0'
            Settings = @{
                AdDomainSourcePath = @{ NoDefault = $true }
                ComputerName = @{ Constant = 'WIN2025' }
                CpuCount = @{ Constant = 2 }
                DefaultGateway = @{ NoDefault = $true }
                DeploymentTimeoutMinutes = @{ Constant = 30 }
                DiskGB = @{ Constant = 60 }
                DnsServer = @{ Constant = '8.8.8.8' }
                DomainJoinTimeoutMinutes = @{ Constant = 20 }
                EnableEventLogging = @{ Constant = $true }
                GuestReadyTimeoutMinutes = @{ Constant = 20 }
                MaxMemberServerCount = @{ Constant = 5 }
                MemberCpuCount = @{ Constant = 1 }
                MemberDiskGB = @{ Constant = 60 }
                MemberRamMB = @{ Constant = 2048 }
                MemberServerCount = @{ Constant = 0 }
                NetworkType = @{ Constant = 'nat' }
                RamMB = @{ Constant = 4096 }
                SubnetMask = @{ Constant = '255.255.255.0' }
                TimeoutMinutes = @{ Constant = 90 }
                VmBuilderScriptPath = @{ NoDefault = $true }
                VmName = @{ Constant = 'WS2025-Server' }
            }
        }
        '2.2.0' = @{
            Tag = 'v2.2.0'
            HeaderVersion = '2.2.0'
            Settings = @{
                AdDomainSourcePath = @{ NoDefault = $true }
                ComputerName = @{ Constant = 'WIN2025' }
                CpuCount = @{ Constant = 2 }
                DefaultGateway = @{ NoDefault = $true }
                DeploymentTimeoutMinutes = @{ Constant = 30 }
                DiskGB = @{ Constant = 60 }
                DnsServer = @{ Constant = '8.8.8.8' }
                DomainJoinTimeoutMinutes = @{ Constant = 20 }
                EnableEventLogging = @{ Constant = $true }
                GuestReadyTimeoutMinutes = @{ Constant = 20 }
                MaxMemberServerCount = @{ Constant = 5 }
                MemberCpuCount = @{ Constant = 1 }
                MemberDiskGB = @{ Constant = 60 }
                MemberRamMB = @{ Constant = 2048 }
                MemberServerCount = @{ Constant = 0 }
                NetworkType = @{ Constant = 'nat' }
                RamMB = @{ Constant = 4096 }
                SubnetMask = @{ Constant = '255.255.255.0' }
                TimeoutMinutes = @{ Constant = 90 }
                VmBuilderScriptPath = @{ NoDefault = $true }
                VmName = @{ Constant = 'WS2025-Server' }
            }
        }
    }
}
