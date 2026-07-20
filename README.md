# build-lab

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE.svg)](https://learn.microsoft.com/powershell/)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows-0078D6.svg)](https://www.microsoft.com/windows)
[![VMware Workstation 17+](https://img.shields.io/badge/VMware%20Workstation-17%2B-607078.svg)](https://www.vmware.com/products/workstation-pro.html)

Stands up a lab Active Directory domain controller from an ISO in one command: builds the Windows Server 2025 VM, promotes the forest, and stages a lived-in AD domain that populates itself at your first Administrator logon.

I designed this because I like a fresh lab environment, but I do not like building a lab for the umpteenth time when the lab build may take more time than what I wanted to test.

## Why?

There are plenty of ways to deploy a Windows Server VM. There are plenty of scripts that promote an AD forest. There are even a few scripts that will give you that "lived in" feel.

What I could not find was one command that goes the whole way, ISO to a domain with objects in it, never opens a GUI, still leaves enough of a log trail to tell you why the script broke on the day it breaks, and requires exactly zero tooling outside of what Microsoft and VMware ship as part of the OS and hypervisor. So I wrote one.

## What It Does

`build-lab.ps1` is an orchestrator. It does not build a VM or promote a forest itself. It drives two sibling projects and stitches them together so one command takes you from an ISO to a promoted domain controller. Specifically:

1. Calls `New-VMwareWorkstationVM.ps1` to create and start a Windows Server 2025 VM with the CPU, RAM, disk, and static network settings you pass in.
2. Zips the `new-AdDomain` project on the host and pushes it into the guest at `C:\temp\new-AdDomain` over vmrun VIX guest operations, then verifies the payload landed.
3. Launches `New-ADForestDeployment.ps1 -CreateScheduledTask` inside the guest to install AD DS and promote the forest.

```text
build-lab.ps1
      │
      ▼
New-VMwareWorkstationVM.ps1 ──► Windows Server 2025 VM
      │
      ▼
new-AdDomain payload ────────► C:\temp\new-AdDomain in the guest
      │
      ▼
New-ADForestDeployment.ps1 ──► forest promoted, verified by ntds.dit
      │
      ▼
scheduled task, waiting on your Administrator logon
      │
      ▼
Initialize-ADDirectory.ps1 ──► a domain with things in it
```

Here is the part that trips people up, so read it before you run anything.

Successful AD promotion immediately reboots Windows, which tears down the vmrun guest-operations channel mid-call. A blocking call hung on that reboot and never came back, so the guest script is launched fire-and-forget. That means there is no exit code to read at all, not even an untrustworthy one. Build-lab verifies success by polling for `C:\Windows\NTDS\ntds.dit`. If the file never appears before timeout, guest deployment logs are retrieved automatically.

And one thing requires a tiny bit of your effort. Creating OUs, users, groups, the Enterprise CA, and GPOs is `Initialize-ADDirectory.ps1`'s job, and that runs from a scheduled task triggered at the next Administrator logon. I know it's unreasonable, but I need you to log in at least once. Build-lab cannot log in for you. When it finishes it prints a red banner reminding you to log into the guest console as Administrator to kick that off. The task keeps waiting either way, so nothing is lost if you miss the banner. You just get to stare at an empty domain first, wondering where all your objects went until you log in to debug and suddenly things start populating.

## Features

- One command takes you from an ISO to a promoted domain controller. No GUI, no answer-file editing, no clicking Next.
- Promotion is confirmed by looking for `ntds.dit` in the guest, not by trusting a process that reboots out from under you.
- Directory population is staged and waiting, so the domain fills itself in the moment you log on.
- Three sources of logs land in one folder: the orchestrator's, the VM builder's, and the guest's own.
- Key events go to the Windows Application event log, if you want a SIEM to see this.
- `-SkipVmBuild` re-runs just the guest phases against a VM you already built.

## Screenshots

**1. The built-in help.** `Get-Help .\build-lab.ps1 -Examples` gives you the synopsis and both invocation patterns without opening the script.

![Get-Help output showing the build-lab.ps1 synopsis and two examples](images/build_1.jpg)

**2. Kicking off a full build.** The command line and the first minute of output. The ISO edition is identified, `autounattend.xml` is generated, the virtual disk and VMX are written, and the VM starts headless.

![Console at the start of a build-lab run, showing VM creation and answer file generation](images/build_2.jpg)

**3. The guest, mid-install.** Unattended Windows Setup running in the VM with the VMware Tools installer firing from the OOBE pass. Nothing to do here but wait.

![VM console during unattended Windows Setup running the VMware Tools installer](images/build_3.jpg)

**4. The VM build finishes and hands off.** Installation media is ejected, the CD/DVD drives are stripped out of the VMX, and the VM restarts. Then guest operations come up, the `new-AdDomain` payload lands in `C:\temp\new-AdDomain`, promotion launches fire-and-forget, and the poll for `ntds.dit` begins.

![Console showing VM build complete, guest operations ready, payload deployed, and promotion artifact polling](images/build_5.jpg)

**5. The banner you must not ignore.** `ntds.dit` appears, promotion is verified, and the red banner tells you directory population still needs a manual logon. Those `[DEBUG]` polling lines above it look alarming. They are not. "VMware Tools are not running" and "Invalid user name or password" are what a guest mid-reboot looks like from the outside, and the poll is built to shrug them off and keep going. The `[WARN]` about guest log retrieval is the same story, and the run still reports success.

![Console showing promotion verified and the red ACTION REQUIRED banner](images/build_7.jpg)

**6. Directory population, once you log on.** This is the manual step the banner was shouting about. `Initialize-ADDirectory.ps1` fires from its scheduled task, removes that task, verifies the services, saves dcdiag and repadmin reports, sets DNS forwarders, and turns on the AD Recycle Bin.

![Initialize-ADDirectory.ps1 running inside the guest after Administrator logon](images/build_6.jpg)

## Requirements

- **VMware Workstation 17 or newer.** The script finds `vmrun.exe` under the standard Program Files install paths.
- **Windows PowerShell 5.1.** This targets 5.1, where `Write-EventLog` is the correct API. See [Known Limitations](#known-limitations) if you are thinking about a PowerShell 7 port.
- **Local Administrator on the host,** to register the `build-lab` Application event log source. That is the only thing that needs it. If registration fails, the script falls back to the built-in `Application` source automatically and keeps going, so an unelevated run works fine. The guest operations authenticate against the guest, not the host.
- **A Windows Server 2025 ISO.**
- **The two sibling projects.** `New-VMwareWorkstationVM` and `new-AdDomain` are expected to sit next to this project on disk (`..\New-VMwareWorkstationVM` and `..\new-AdDomain`). If you keep them somewhere else, point at them with `-VmBuilderScriptPath` and `-AdDomainSourcePath`.

```text
Sibling Projects/
├── build-lab/
├── New-VMwareWorkstationVM/
└── new-AdDomain/
```

### All the stuff you need to make this script work

- [VMware Workstation Pro (Free)](https://knowledge.broadcom.com/external/article/368667/download-and-license-vmware-desktop-hype.html)
- [Windows Server 2025 (Evaluation)](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2025)
- [New-VMwareWorkstationVM](https://github.com/0x44616e69656c/New-VMwareWorkstationVM)
- [New-AdDomain](https://github.com/0x44616e69656c/new-AdDomain)

## Tested On

- **Windows 11 host, VMware Workstation Pro 26H1.** Full build verified end to end: VM build, payload copy, and forest promotion confirmed by `ntds.dit`. The script's floor is Workstation 17+, which is what the vmrun guest-operations calls need, but 26H1 is what the end-to-end runs have actually been against. You are updating your software right?
- **Windows Server 2025 Standard Evaluation (Desktop Experience), `SERVER_EVAL_x64FRE` media.** Built at 8 GB RAM, 4 vCPU, and a 120 GB disk. Other editions and VL or retail media are unverified. The unattended install matches on exact edition name strings, and those differ between evaluation and VL media, so expect to adjust if you switch.

## Quick Start

Clone the repository:

```powershell
git clone https://github.com/0x44616e69656c/build-lab.git
cd build-lab
```

Then run it:

```powershell
$pw = ConvertTo-SecureString 'P@ssw0rd!' -AsPlainText -Force
.\build-lab.ps1 -IsoPath 'C:\ISOs\WS2025.iso' -AdminPassword $pw `
    -VmStoragePath 'C:\VMs' -StaticIpAddress '192.168.220.50' -DefaultGateway '192.168.220.2'
```

**Pick that IP carefully, because it is the one thing that will quietly ruin your afternoon.** `-NetworkType` defaults to `nat`, which puts the guest on VMnet8. Workstation always allocates a NAT network as a Class C and hands out fixed roles inside it:

| Address | Role |
|---|---|
| `net.1` | Host virtual network adapter. Reserved. |
| `net.2` | The NAT device. This is your gateway, and your DNS server. |
| `net.3` to `net.127` | Yours, for static IPs. |
| `net.128` to `net.254` | The virtual DHCP server's pool. Keep out. |

So `-StaticIpAddress` needs to be somewhere in `net.3` to `net.127`, and `-DefaultGateway` is always `net.2`. Land in the DHCP pool and you are gambling on a conflict. Land outside the subnet entirely and the guest simply never answers. The build sits there politely polling an address that cannot answer until the script times out.

The subnet itself is the part nobody can tell you. Workstation picks it when you install it and it differs from host to host, so `192.168.220.0/24` above is illustrative, not a default. Yours is in Edit > Virtual Network Editor > VMnet8.

The run in the screenshots above took about twenty-five minutes from start to red banner on a reasonably quick host. Budget an hour and go do something else. The default timeouts allow for considerably longer than that before anything gives up, which is fine for a build you are not watching. When the red banner appears, log into the guest console as Administrator to start directory population.

## Additional Examples

### A build with the knobs turned up

The Quick Start uses the fewest parameters that work. This shows a few more options. Many of these, like `-DeploymentTimeoutMinutes`, you will never need.

```powershell
$pw = ConvertTo-SecureString 'P@ssw0rd!' -AsPlainText -Force
.\build-lab.ps1 -IsoPath 'D:\ISOs\WS2025.iso' -AdminPassword $pw `
    -VmStoragePath 'D:\VMs' -VmName 'DC01' -ComputerName 'DC01' `
    -RamMB 8192 -CpuCount 4 -DiskGB 120 `
    -StaticIpAddress '192.168.220.50' -SubnetMask '255.255.255.0' `
    -DefaultGateway '192.168.220.2' -DnsServer '1.1.1.1' `
    -DeploymentTimeoutMinutes 45
```

Those are roughly the specs behind the screenshots above. 4 GB and 2 vCPU are the defaults and they do work, but AD DS is happier with more, and the build finishes sooner. `-DeploymentTimeoutMinutes 45` buys headroom on a slow host. Raising it costs nothing when the build succeeds, because the poll exits as soon as `ntds.dit` appears.

### Re-running against a VM you already built

```powershell
$pw = ConvertTo-SecureString 'P@ssw0rd!' -AsPlainText -Force
.\build-lab.ps1 -SkipVmBuild -AdminPassword $pw -VmStoragePath 'C:\VMs' -VmName 'LabServer01'
```

`-SkipVmBuild` reuses the existing VMX at `<VmStoragePath>\<VmName>\<VmName>.vmx` and jumps straight to copying the payload and promoting. Good for iterating on the domain build without paying the VM-build tax every time. Pass the same `-VmStoragePath` and `-VmName` you built the VM with. Note it re-runs the whole guest phase every time; it does not pick up a failed build where it left off.

Two things to know before you reach for it. `-SkipVmBuild` and `-StaticIpAddress` are in different parameter sets, so you cannot pass an address here even if you want to, and the guest script gets called without the network arguments. On a VM that already has its static IP from the original build, that is fine. It only matters if the guest fell back to DHCP and you were counting on this run to repair it, which it will not.

The other one is destructive. Copying the payload deletes `C:\temp\new-AdDomain` first, and the guest's own deployment logs live inside that folder. Re-running with `-SkipVmBuild` throws them away before it starts. Pull anything you still want out of the guest first.

You could also log into the guest and run `New-ADForestDeployment.ps1` with its own parameters. Options. We have options.

## Parameters

| Parameter | Default | Notes |
|---|---|---|
| `-IsoPath` | **Required** (full build) | Path to the Windows Server 2025 ISO. Not needed with `-SkipVmBuild`. |
| `-AdminPassword` | **Required** | `SecureString`. Guest Administrator password. Cannot contain a double-quote. |
| `-VmStoragePath` | **Required** | Parent folder for the VM. The VMX resolves to `<VmStoragePath>\<VmName>\<VmName>.vmx`. |
| `-StaticIpAddress` | **Required** (full build) | Static IP for the guest. Mandatory here even though the child script treats it as optional, because without it the child returns before the guest network exists. |
| `-VmName` | `WS2025-Server` | VM name and folder name. |
| `-ComputerName` | `WIN2025` | Guest Windows computer name (max 15 chars). |
| `-RamMB` | `4096` | Guest RAM in MB (512 to 65536). |
| `-CpuCount` | `2` | Virtual CPUs (1 to 64). |
| `-DiskGB` | `60` | Virtual disk size in GB (20 to 2048). |
| `-NetworkType` | `nat` | `nat`, `bridged`, or `hostonly`. |
| `-SubnetMask` | `255.255.255.0` | Dotted-decimal mask; converted to a CIDR prefix for the guest. |
| `-DefaultGateway` | none | Optional gateway address. |
| `-DnsServer` | `8.8.8.8` | DNS server for the guest during build. |
| `-TimeoutMinutes` | `90` | Upper bound on the VM build (1 to 1440). |
| `-VmBuilderScriptPath` | `..\New-VMwareWorkstationVM\New-VMwareWorkstationVM.ps1` | Override if the sibling project is relocated. |
| `-AdDomainSourcePath` | `..\new-AdDomain` | Override if the sibling project is relocated. |
| `-GuestReadyTimeoutMinutes` | `20` | How long to wait for guest operations to come up (1 to 120). |
| `-DeploymentTimeoutMinutes` | `30` | How long to poll for `ntds.dit` before failing (1 to 240). Raise it if the guest is slow or heavily loaded. |
| `-SkipVmBuild` | switch | Reuse an existing VM and run only the guest phases. |

## Logs

Logs live in `<script dir>\logs`. Because build-lab drives a child script and a guest, one folder collects logs from three different places. Every run produces:

- `build-lab_<timestamp>.log` -- the orchestrator's own text log, every level.
- `build-lab-errors_<timestamp>.csv` -- the orchestrator's structured rows, WARN, ERROR, and FATAL only. Columns: `Timestamp,Level,Script,Message`. Import with `Import-Csv`.

A full build (anything without `-SkipVmBuild`) also gets the VM builder's own logs, written here because build-lab hands it this folder as its `-LogPath`:

- `VMDeploy_<timestamp>.csv` -- the VM build log, every level. Different shape from the orchestrator's CSV. Columns: `Timestamp,Level,Message,ErrorDetail`.
- `VMDeploy_<timestamp>_Transcript.txt` -- a full PowerShell transcript of the VM build. This is the one to read when the VM itself is the problem.

And on the way out:

- `guest-<timestamp>\` -- the guest's own `new-AdDomain` deployment logs, pulled back from the VM. This happens on both paths. After a successful promotion you get them for the record, and after a promotion timeout you get them so you can read the failure, which is the case you actually care about. Retrieval is best-effort either way. If the guest is mid-reboot or the folder is not there, you get a WARN instead of the logs. On the success path the build still succeeds. On the timeout path the build was already failing, and losing the logs just means failing without the evidence.

Key events (start, stop, VM build, payload deploy, promotion verified, failures) also go to the Windows Application event log under the `build-lab` source for SIEM ingestion. Set `$enableEventLogging` to `$false` in the script's variable section to turn that off.

If you file a bug report, include everything in the `logs` folder.

## Configuration Notes

- **The guest promotion is launched fire-and-forget (`vmrun -noWait`).** A blocking call held one VIX channel open across the guest's promotion reboot and, on some hosts, never returned, hanging the whole run. `-noWait` returns as soon as the guest process starts, and artifact polling handles the rest.
- **Promotion is verified by `ntds.dit`, not by exit code.** There is no exit code to check. `-noWait` returns at launch, and the success path reboots mid-call anyway. See [What It Does](#what-it-does).
- **The guest script is called `-NonInteractive` with the static network values.** A console-less vmrun run cannot answer a `Read-Host` prompt, so the guest is told everything up front and can repair a DHCP fallback from the unattended pass in place.

## Known Limitations

- **Directory population does not run automatically.** It is a logon-triggered scheduled task inside the guest. You must log into the guest console as Administrator to start it. This is deliberate. Running it unattended would mean storing a domain Administrator password under a startup-triggered task. That's the one security compromise I decided not to make, even for a lab. I'm not convinced I made a good decision. There are plenty of other compromises in here that are just as questionable and just as fine for a lab. I may change this later.
- **Passwords with a double-quote character are rejected** because they break vmrun argument quoting.
- **Guest log retrieval is best-effort and does sometimes fail.** The pull happens right after the promotion reboot, so vmrun can come back with "A file was not found" or "VMware Tools are not running" if the guest is not back yet. You get a WARN, not a failure, and the build still reports success. Do not re-run with `-SkipVmBuild` to try again, because that deletes `C:\temp\new-AdDomain` and the logs with it. Once the guest is up, pull them by hand instead. They are still sitting in `C:\temp\new-AdDomain\logs`:

  ```powershell
  & 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe' -T ws -gu Administrator -gp '<password>' `
      runProgramInGuest 'C:\VMs\DC01\DC01.vmx' 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
      -NoProfile -Command "Compress-Archive -LiteralPath 'C:\temp\new-AdDomain\logs' -DestinationPath 'C:\temp\adDeploymentLogs.zip' -Force"

  & 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe' -T ws -gu Administrator -gp '<password>' `
      copyFileFromGuestToHost 'C:\VMs\DC01\DC01.vmx' 'C:\temp\adDeploymentLogs.zip' 'C:\temp\adDeploymentLogs.zip'
  ```
- **`Write-EventLog` is deprecated in PowerShell 7+.** This script targets 5.1, where it is correct. A PowerShell 7 port would need `New-WinEvent` against a registered ETW manifest.
- **Not every VM builder option is exposed.** build-lab passes through the parameters in the table above and no others, so `-Edition`, `-TimeZone`, and `-ProductKey` fall back to `New-VMwareWorkstationVM.ps1`'s own defaults. In practice that means you always get Standard edition, on Pacific time, with no product key. If you need Datacenter or a different time zone, call the VM builder directly and then come back with `-SkipVmBuild`. Alternatively, you could edit the defaults in the script within your own repo. Your call. I might extract the config elements to a separate file like I did in `new-AdDomain` to make this easier to manage. Put in the request if this matters to you.

## Security Notes

This is a lab tool and it makes trades a production tool has no business making. They are deliberate, but you should know what they are before you point this at anything you care about.

- **The guest password is visible in the host process list.** vmrun takes credentials as command-line arguments (`-gp`), so for the life of every guest operation, anything on your host that can enumerate processes can read that password in the clear. That is vmrun's API, not something the script can work around. Do not reuse a real credential here, and think twice about running it on a host you share.
- **That password is the guest's local Administrator password.** Every guest operation runs as `Administrator` with `-AdminPassword`, and the same value seeds the unattended install. One password, full control of the guest.
- **Keep it out of your shell history.** The examples use `ConvertTo-SecureString 'P@ssw0rd!' -AsPlainText -Force` because it reads well on a page, but it puts the plaintext in your session and your history. `-AdminPassword` is a mandatory `SecureString`, so you can leave it off the command line entirely and let PowerShell prompt you with masked input.
- **vmrun output is password-scrubbed before it hits the logs, and nothing else is.** The password is replaced with `***` in anything vmrun returns, error text included. Host paths, IP addresses, usernames, and VM names are not. Read a log before you paste it into an issue.
- **The payload stays in the guest.** `C:\temp\new-AdDomain` is left in place after the build, and so is `C:\temp\adDeploymentLogs.zip`, the log bundle the host pulls back. The only thing cleaned up is the payload zip. Fine for a lab you are about to throw away, worth a thought if the VM outlives the experiment.

## Troubleshooting

**"-SkipVmBuild was specified but no VMX exists at ..."** -- The VMX path is built as `<VmStoragePath>\<VmName>\<VmName>.vmx`. Pass the same `-VmStoragePath` and `-VmName` you built the VM with, and do not include the VM's own folder in `-VmStoragePath`. A VM at `D:\VMware\DC01\DC01.vmx` needs `-VmStoragePath 'D:\VMware' -VmName 'DC01'`.

**"VMX already exists at ..."** -- You are trying to do a full build over an existing VM. Remove the files, pick a different `-VmName`, or add `-SkipVmBuild` to reuse it.

**"Guest operations did not become ready ..."** -- VMware Tools is not up, or the Administrator credential is being rejected while the guest finishes OOBE/specialize, or `-AdminPassword` is wrong. Open the VM console and watch setup progress. The error message names which of these the last probe hit.

**"AD forest promotion did not complete within N minute(s)"** -- `ntds.dit` never appeared. Read the retrieved guest log in `logs\guest-<timestamp>\`; the error message quotes any fatal line it found. If the guest is just slow, raise `-DeploymentTimeoutMinutes`.

**"vmrun.exe not found ..."** -- VMware Workstation is not installed where the script looks. It only checks the two standard Program Files locations, so confirm Workstation 17+ is installed and that `vmrun.exe` sits under one of them. Hack the script if you must, but your edit gets clobbered the next time you pull a new version of the script.

**The build says promotion succeeded but the domain is empty.** -- Working as designed. You still need to log into the guest as Administrator to run directory population. See [Known Limitations](#known-limitations).

## Contact

- Mastodon: [@daniel@infosec.exchange](https://infosec.exchange/@daniel)
- Email: 0x44616e69656c {AT} [not-this]danielowen[.]com
- LinkedIn: [linkedin.com/in/danielowen](https://www.linkedin.com/in/danielowen/)
- Web: [danielowen.com](https://danielowen.com)

## Contributing

Bug reports and pull requests are welcome. This is a single-author utility script, but changes come in through the fork and pull request model, not direct pushes to `master`. See [CONTRIBUTING.md](CONTRIBUTING.md) for how to file a useful bug report and what a pull request needs to clear (PowerShell 5.1 only, PSScriptAnalyzer clean, no hard-coded paths, approved verbs, no secrets in the diff).

## License

Released under the [MIT License](LICENSE). Use, copy, modify, and distribute it freely, including commercially, as long as the copyright notice and license text stay in place. Provided "as is", without warranty of any kind.
