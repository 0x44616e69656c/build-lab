# Overrides

This file is generated from `include\override-catalog.psd1`. Don't edit it. A change goes in the catalog, and this file is generated again.

## Where the file goes

Put your settings in `overrides\overrides.psd1` in the project folder. Git ignores that folder, so an upgrade never touches it. The file is a PowerShell data file holding one hashtable of constant values. Each value is a quoted string, a number, `$true`, `$false` or a list of those. Save it as UTF-8 with a BOM when it holds non-ASCII text. A key you leave out takes its shipped value.

For example, with settings at their shipped values:

```powershell
@{
    ComputerName = 'WIN2025'
    CpuCount = 2
}
```

To make the file from an older copy of the project, see [UPGRADE.md](UPGRADE.md).

## Precedence

A value given on the command line wins. Without one, a build profile's value applies, for the keys whose row says a profile sets them. Without that, the override file's value applies, and without that, the shipped value. A command-line value that differs from the override file's is logged as INFO.

## What a run logs

With no override file, a run logs one INFO line saying so, and the shipped settings apply. With one, it logs one INFO line naming the file, its SHA-256 and each setting it applied, with secret values shown as `<set>`. A key left empty gives a WARN, and its shipped value applies. A run stops when the file can't be read, holds a value that isn't a constant, holds an unknown key, or holds a value outside a key's permitted values.

## Settings

| Key | What it changes | How to override | Default | Permitted values | Why this default | Secret |
|---|---|---|---|---|---|---|
| `AdDomainSourcePath` | The default of `-AdDomainSourcePath`, described in the README and the script's help. | `overrides\overrides.psd1`, key `AdDomainSourcePath`. `-AdDomainSourcePath` on the command line also sets it, and the command line wins. | The `new-AdDomain` folder beside build-lab's folder | The path of a new-AdDomain folder. A relative path in the override file resolves from build-lab's folder, not the folder the run was started from. | The three lab projects are cloned or extracted side by side, so build-lab finds new-AdDomain without being told. | no |
| `ComputerName` | The default of `-ComputerName`, described in the README and the script's help. | `overrides\overrides.psd1`, key `ComputerName`. build-lab passes it to New-VMwareWorkstationVM for the DC, so it wins over that project's override file. `-ComputerName` on the command line also sets it, and the command line wins. | `WIN2025` | Text matching the pattern `^(?!-)(?!.*-$)[A-Za-z0-9-]{1,15}$`, ignoring case. | A short name that says what the DC runs and fits the 15-character NetBIOS limit. | no |
| `CpuCount` | The default of `-CpuCount`, described in the README and the script's help. | `overrides\overrides.psd1`, key `CpuCount`. build-lab passes it to New-VMwareWorkstationVM for the DC, so it wins over that project's override file. `-CpuCount` on the command line also sets it, and the command line wins. | 2 | A whole number from 1 to 64. | Enough for Windows Setup and forest promotion without crowding the host. | no |
| `DefaultGateway` | The default of `-DefaultGateway`, described in the README and the script's help. | `overrides\overrides.psd1`, key `DefaultGateway`. build-lab passes it to New-VMwareWorkstationVM for every VM when it has one, and then it wins over that project's override file. `-DefaultGateway` on the command line also sets it, and the command line wins. | None | Text matching the pattern `^((25[0-5]\|2[0-4][0-9]\|1[0-9][0-9]\|[1-9]?[0-9])\.){3}(25[0-5]\|2[0-4][0-9]\|1[0-9][0-9]\|[1-9]?[0-9])$`, ignoring case. | The gateway differs per host and network, so build-lab can't guess one. | no |
| `DeploymentTimeoutMinutes` | The default of `-DeploymentTimeoutMinutes`, described in the README and the script's help. | `overrides\overrides.psd1`, key `DeploymentTimeoutMinutes`. `-DeploymentTimeoutMinutes` on the command line also sets it, and the command line wins. | 30 | A whole number from 1 to 240. | Covers installing AD DS and promoting the forest on a slow guest. | no |
| `DiskGB` | The default of `-DiskGB`, described in the README and the script's help. | `overrides\overrides.psd1`, key `DiskGB`. build-lab passes it to New-VMwareWorkstationVM for the DC, so it wins over that project's override file. `-DiskGB` on the command line also sets it, and the command line wins. | 60 | A whole number from 20 to 2048. | Room for Windows Server 2025 with Desktop Experience and a domain controller, on a sparse disk that grows only as it fills. | no |
| `DnsServer` | The default of `-DnsServer`, described in the README and the script's help. | `overrides\overrides.psd1`, key `DnsServer`. build-lab passes it to New-VMwareWorkstationVM for the DC, so it wins over that project's override file. Members always use the DC. `-DnsServer` on the command line also sets it, and the command line wins. | `8.8.8.8` | Text matching the pattern `^((25[0-5]\|2[0-4][0-9]\|1[0-9][0-9]\|[1-9]?[0-9])\.){3}(25[0-5]\|2[0-4][0-9]\|1[0-9][0-9]\|[1-9]?[0-9])$`, ignoring case. | A public resolver the DC can use during its build, before it runs DNS itself. | no |
| `DomainJoinTimeoutMinutes` | The default of `-DomainJoinTimeoutMinutes`, described in the README and the script's help. | `overrides\overrides.psd1`, key `DomainJoinTimeoutMinutes`. `-DomainJoinTimeoutMinutes` on the command line also sets it, and the command line wins. | 20 | A whole number from 1 to 120. | Covers the reboot after the join and the wait until the member reports the domain. | no |
| `EnableEventLogging` | Whether build-lab writes its key events to the Windows Application event log. | `overrides\overrides.psd1`, key `EnableEventLogging`. | `$true` | $true or $false. | Key events in the event log let a SIEM or an event viewer follow each build. | no |
| `GuestReadyTimeoutMinutes` | The default of `-GuestReadyTimeoutMinutes`, described in the README and the script's help. | `overrides\overrides.psd1`, key `GuestReadyTimeoutMinutes`. `-GuestReadyTimeoutMinutes` on the command line also sets it, and the command line wins. | 20 | A whole number from 1 to 120. | Long enough for a new guest to start VMware Tools, and for the DC to come back from its promotion reboot. | no |
| `MaxMemberServerCount` | The most member servers one run builds, and the most computer objects -MoveMemberServers moves at once. | `overrides\overrides.psd1`, key `MaxMemberServerCount`. | 5 | A whole number from 1 to 99. Members are named SRVR-01 to SRVR-99, so 99 is the most the numbering allows. | A scope limit, so a mistyped -MemberServerCount can't start dozens of VM builds. | no |
| `MemberCpuCount` | The default of `-MemberCpuCount`, described in the README and the script's help. | `overrides\overrides.psd1`, key `MemberCpuCount`. build-lab passes it to New-VMwareWorkstationVM as -CpuCount for each member, so it wins over that project's override file. `-MemberCpuCount` on the command line also sets it, and the command line wins. | 1 | A whole number from 1 to 64. | A plain member server needs little, and several of them share the host with the DC. | no |
| `MemberDiskGB` | The default of `-MemberDiskGB`, described in the README and the script's help. | `overrides\overrides.psd1`, key `MemberDiskGB`. build-lab passes it to New-VMwareWorkstationVM as -DiskGB for each member, so it wins over that project's override file. `-MemberDiskGB` on the command line also sets it, and the command line wins. | 60 | A whole number from 20 to 2048. | Room for Windows Server 2025 with Desktop Experience, on a sparse disk that grows only as it fills. | no |
| `MemberRamMB` | The default of `-MemberRamMB`, described in the README and the script's help. | `overrides\overrides.psd1`, key `MemberRamMB`. build-lab passes it to New-VMwareWorkstationVM as -RamMB for each member, so it wins over that project's override file. `-MemberRamMB` on the command line also sets it, and the command line wins. | 2048 | A whole number from 512 to 65536. | Enough for a member server with Desktop Experience, small enough to run several beside the DC. | no |
| `MemberServerCount` | The default of `-MemberServerCount`, described in the README and the script's help. | `overrides\overrides.psd1`, key `MemberServerCount`. `-MemberServerCount` on the command line also sets it, and the command line wins. | 0 | A whole number from 0 to 99. MaxMemberServerCount caps it. | A full build makes the DC alone unless you ask for members. | no |
| `NetworkType` | The default of `-NetworkType`, described in the README and the script's help. | `overrides\overrides.psd1`, key `NetworkType`. build-lab passes it to New-VMwareWorkstationVM for every VM, so it wins over that project's override file. `-NetworkType` on the command line also sets it, and the command line wins. | `nat` | One of nat, bridged, hostonly. | NAT gives every VM internet access through the host with no change to the host's own network. | no |
| `RamMB` | The default of `-RamMB`, described in the README and the script's help. | `overrides\overrides.psd1`, key `RamMB`. build-lab passes it to New-VMwareWorkstationVM for the DC, so it wins over that project's override file. `-RamMB` on the command line also sets it, and the command line wins. | 4096 | A whole number from 512 to 65536. | Comfortable for a Windows Server 2025 domain controller with Desktop Experience, and small enough for most hosts. | no |
| `SubnetMask` | The default of `-SubnetMask`, described in the README and the script's help. | `overrides\overrides.psd1`, key `SubnetMask`. build-lab passes it to New-VMwareWorkstationVM for every VM, so it wins over that project's override file. `-SubnetMask` on the command line also sets it, and the command line wins. | `255.255.255.0` | Text matching the pattern `^((25[0-5]\|2[0-4][0-9]\|1[0-9][0-9]\|[1-9]?[0-9])\.){3}(25[0-5]\|2[0-4][0-9]\|1[0-9][0-9]\|[1-9]?[0-9])$`, ignoring case. | Workstation allocates its NAT network as a /24. | no |
| `TimeoutMinutes` | The default of `-TimeoutMinutes`, described in the README and the script's help. | `overrides\overrides.psd1`, key `TimeoutMinutes`. build-lab passes it to New-VMwareWorkstationVM for every VM, so it wins over that project's override file. `-TimeoutMinutes` on the command line also sets it, and the command line wins. | 90 | A whole number from 1 to 1440. | Covers a full unattended install on a slow host with room to spare. | no |
| `VmBuilderScriptPath` | The default of `-VmBuilderScriptPath`, described in the README and the script's help. | `overrides\overrides.psd1`, key `VmBuilderScriptPath`. `-VmBuilderScriptPath` on the command line also sets it, and the command line wins. | `New-VMwareWorkstationVM.ps1` in the `New-VMwareWorkstationVM` folder beside build-lab's folder | The path of New-VMwareWorkstationVM.ps1. A relative path in the override file resolves from build-lab's folder, not the folder the run was started from. | The three lab projects are cloned or extracted side by side, so build-lab finds the VM builder without being told. | no |
| `VmName` | The default of `-VmName`, described in the README and the script's help. | `overrides\overrides.psd1`, key `VmName`. build-lab passes it to New-VMwareWorkstationVM for the DC, so it wins over that project's override file. `-VmName` on the command line also sets it, and the command line wins. | `WS2025-Server` | Text matching the pattern `^[^\\/:*?"<>\|]{1,64}$`, ignoring case. | Names the operating system the DC runs, the same default New-VMwareWorkstationVM uses. | no |

## Retired keys

None.

## Not covered

These can't be set in the override file.

| Setting | Why it isn't covered |
|---|---|
| `AddMemberServers` | A mode switch, chosen for each run. |
| `AdminPassword` | A credential, and mandatory, so it is passed for each run and never stored as a setting. |
| `IsoPath` | The ISO is chosen for each run. |
| `MoveMemberServers` | A mode switch, chosen for each run. |
| `ProfilePath` | A build profile is chosen for each build. A standing domain belongs in new-AdDomain's override file instead. |
| `SkipVmBuild` | A mode switch, chosen for each run. |
| `StaticIpAddress` | Each DC needs its own address. |
| `VMware Workstation install folder` | build-lab searches the two standard Program Files folders for vmrun.exe. A Workstation installed elsewhere needs a script change. |
| `VmStoragePath` | Mandatory, and where the VMs go is chosen for each run. |
| `eventLogSourceName` | It names the event log source registered for build-lab, which a change would orphan. |
| `guestUserName` | The built-in Administrator account vmrun signs in to every guest with. |
| `logDirectoryPath` | The logs folder beside the script, where the VM builder and the guest logs land too. |
| `memberServerIpOffset` | Each member's address follows its number, so a change would move members away from the addresses earlier runs gave them. |
| `memberServerNamePrefix` | A change would stop -MoveMemberServers and the numbering from finding members built before it. |
| `scriptVersion` | It names the release that runs. |
| `stagingRootPath` | A folder per run under the temp folder, deleted when the run ends. |

## Security

Secret values sit in plain text in `overrides\overrides.psd1` on disk, and are masked only in logs. build-lab copies new-AdDomain, its overrides folder included, into the DC, where it stays at `C:\temp\new-AdDomain` after the build. new-AdDomain's OVERRIDE.md says which of its settings are secret.

## Other projects

Each lab project documents its own overrides:

- [New-VMwareWorkstationVM](https://github.com/0x44616e69656c/New-VMwareWorkstationVM/blob/main/OVERRIDE.md)
- [new-AdDomain](https://github.com/0x44616e69656c/new-AdDomain/blob/main/OVERRIDE.md)
