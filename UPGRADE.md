![build-lab upgrade banner showing Fizmo the imp, a network cable over one shoulder, sliding a drive into a tower server beside the word "upgrade"](images/Logos/build-lab-upgrade-banner.jpg)

# Upgrading build-lab to 2.2

**Not tested yet.** These steps come from reading the code and from offline tests that run each migration script against copies of the older releases. Nobody has carried a modified 2.1, 2.0 or 1.0 setup through them and built a lab on live VMs. Until that run passes, keep your old folders, treat this as a careful reading rather than a proven path, and tell me where it's wrong.

This covers all three starting points, 2.1, 2.0 and 1.0. The path is the same for each. Coming from 2.0 or 1.0 just means more to read in step 6.

## What an upgrade touches

Nothing gets installed. Upgrading means replacing the three project folders and carrying your settings across. The VMs you already built are left alone, and a DC keeps the domain it was built with.

Up to 2.1 your settings lived in tracked files, mostly new-AdDomain's `include\global-config.ps1` and its CSV files, and the parameter defaults in `build-lab.ps1` and `New-VMwareWorkstationVM.ps1`. From 2.2 they live in an `overrides` folder in each project, which git ignores and no upgrade touches. Each project ships an `Export-OverrideFile.ps1` that reads your old copy without running it and writes what you changed into that folder. This is the last upgrade that needs your edits moved.

[OVERRIDE.md](OVERRIDE.md) lists every setting build-lab's override file can hold. new-AdDomain and New-VMwareWorkstationVM each have their own.

## The versions that go together

| Project | Version | Why |
|---|---|---|
| build-lab | 2.2 | This release |
| new-AdDomain | 2.1 | build-lab 2.2 checks its version and stops on an older one before building anything |
| New-VMwareWorkstationVM | 1.1 | build-lab 2.2 checks its version too. An older one gets a WARN, and stops the run only when it has an override file it would ignore |

## Never edited a file?

If you never changed a file in any of the three projects, there is nothing to move. In the folder that holds them:

```powershell
git -C .\build-lab pull
git -C .\new-AdDomain pull
git -C .\New-VMwareWorkstationVM pull
```

Not sure? These list every file you changed in a clone:

```powershell
git -C .\build-lab status
git -C .\new-AdDomain status
git -C .\New-VMwareWorkstationVM status
```

Nothing listed in any of them means `git pull` was all it took. Skip to step 7.

## Step 1. Keep the old folders and get fresh copies

Run these in the folder that holds the three projects, so the new copies keep the sibling layout build-lab expects.

```powershell
Rename-Item -Path .\build-lab -NewName build-lab-old
Rename-Item -Path .\new-AdDomain -NewName new-AdDomain-old
Rename-Item -Path .\New-VMwareWorkstationVM -NewName New-VMwareWorkstationVM-old
git clone https://github.com/0x44616e69656c/build-lab.git
git clone https://github.com/0x44616e69656c/new-AdDomain.git
git clone https://github.com/0x44616e69656c/New-VMwareWorkstationVM.git
```

Downloaded zips instead? Extract each one to a folder with the project's name, next to its `-old` folder, look the files over, then unblock them:

```powershell
Get-ChildItem -Path .\build-lab, .\new-AdDomain, .\New-VMwareWorkstationVM -Recurse -File | Unblock-File
```

## Step 2. Move build-lab's edits

The migration reads `build-lab-old` and never runs anything in it. With `-WhatIf` it writes nothing except its log.

```powershell
cd .\build-lab
.\Export-OverrideFile.ps1 -SourcePath ..\build-lab-old -WhatIf
```

Its log, `logs\Export-OverrideFile_<timestamp>.csv`, has one row per setting with what it found and why. If it looks right, run it for real and read the result:

```powershell
.\Export-OverrideFile.ps1 -SourcePath ..\build-lab-old
Get-Content .\overrides\overrides.psd1
cd ..
```

What it does with each kind of setting:

- **A default you changed** in `build-lab.ps1`, such as `-RamMB` or the member server cap, is written to `overrides\overrides.psd1`, with a comment naming the line it came from
- **A default you never changed** is left out, so the shipped value applies and later releases can improve it
- **A value 2.2 would refuse** is written commented out with the reason. Fix it and remove the `#`
- **A value worked out at run time** can't be read without running the script, so it's listed for you to set by hand
- **A relative `-AdDomainSourcePath` or `-VmBuilderScriptPath` default** is written with a WARN. In the override file a relative path resolves from build-lab's folder, not from wherever you started the run, so check it still points where you meant
- **An existing override file** is never overwritten. The new one goes to `overrides\migrated-<date>-<time>\` for you to merge by hand

build-lab 1.0 had no member server settings, so a 1.0 copy just has fewer rows.

## Step 3. Move the two siblings' edits

Each sibling ships its own migration script, and works the same way. new-AdDomain's is the one that matters most, because that is where the domain, the password policy and the CSV files live.

```powershell
cd .\new-AdDomain
.\Export-OverrideFile.ps1 -SourcePath ..\new-AdDomain-old -WhatIf
.\Export-OverrideFile.ps1 -SourcePath ..\new-AdDomain-old
cd ..
cd .\New-VMwareWorkstationVM
.\Export-OverrideFile.ps1 -SourcePath ..\New-VMwareWorkstationVM-old -WhatIf
.\Export-OverrideFile.ps1 -SourcePath ..\New-VMwareWorkstationVM-old
cd ..
```

new-AdDomain's script also reports defaults that changed since your release, such as `lab.local` becoming `lab.test`, and writes them only with `-KeepPreviousDefaults`. Its [UPGRADE.md](https://github.com/0x44616e69656c/new-AdDomain/blob/main/UPGRADE.md) explains which ones and when you want the switch. The builder's [UPGRADE.md](https://github.com/0x44616e69656c/New-VMwareWorkstationVM/blob/main/UPGRADE.md) covers its image names and answer file settings.

Don't copy an old `include\global-config.ps1` over the new one. build-lab 2.2 checks its version and stops with a message saying an older copy was put back.

## Step 4. Bring your build profile

A build profile was never tracked by git, so copy it across if you keep one in new-AdDomain's folder:

```powershell
Copy-Item -Path .\new-AdDomain-old\include\build-profile.psd1 -Destination .\new-AdDomain\include\build-profile.psd1
```

Skip this if `.\new-AdDomain-old\include\build-profile.psd1` doesn't exist. Profiles you keep elsewhere and pass with `-ProfilePath` need nothing.

## Step 5. Your existing labs

A DC built by build-lab 1.0 or 2.0 is in `lab.local`, because that was new-AdDomain's default then. 2.2 handles it in two ways.

- **Adding or moving member servers.** When nothing names a domain (no profile, no override file and no edit to `global-config.ps1`), `-AddMemberServers` and `-MoveMemberServers` read the DC's own domain from the DC and use it, with a WARN that names both domains. The `lab.local` profile 2.1 needed still works, so keep passing it if you already do. **Not tested.** No live run has used this against a DC built before `lab.test`.
- **Full builds.** A full build with nothing naming a domain gives `lab.test`. To keep building `lab.local`, add these two lines to new-AdDomain's `overrides\overrides.psd1`, inside its `@{ }`, or keep passing the profile. Expect a WARN that `.local` is reserved for multicast DNS.

```powershell
    DomainName = 'lab.local'
    NetBIOSName = 'LAB'
```

Once a domain is named, the add and move runs check the DC against it again, so a DC in `lab.test` would then need its own profile.

## Step 6. Scripts that call build-lab

No parameter has been removed or renamed since 1.0, so a command line that worked before still parses. 2.2 adds no parameter. What a wrapper might notice is behavior.

**From 2.1.**

- An override file with a typo, an unknown key or a bad value stops the run before anything is built, with exit code 1. No file at all is one INFO line.
- An older new-AdDomain, or an older `global-config.ps1`, stops the run before anything is built.
- Member work against a `lab.local` DC goes ahead with a WARN where 2.1 stopped.

**From 2.0, as well.** The three items under [Breaking for 2.0 users](README.md#breaking-for-20-users). The second no longer applies, as step 5 says.

**From 1.0, as well.** Read [Changed behavior](README.md#changed-behavior-read-this-if-you-used-10). The changes most likely to trip a wrapper are these.

- A promotion that can't be verified now fails the run with exit code 1. 1.0 reported success after a fixed wait.
- Bad addresses and some passwords are refused before anything is built.
- `-SkipVmBuild` refuses a promoted DC and can't be combined with member servers. `-AddMemberServers` is the replacement for that case.

## Step 7. Do a first run

Do a full build under a new `-VmName` before you point 2.2 at a lab you care about. The first log line names the build-lab version that ran. The lines after it name the override file with its SHA-256 and every setting it applied, and the version of each sibling, so the first run doubles as the check that your settings came across. Each project also logs one INFO line for any shipped default that changed since its last release and that your run didn't set, naming the override key that keeps the old value. build-lab 2.2 changes none of its own. A bad value stops the run before a VM exists. When that build looks right, the `-old` folders can go.

## Later upgrades

From 2.2 on, keep every change in the three `overrides` folders and your build profiles. A clone then upgrades with `git pull` in each folder, as in "Never edited a file?" above. From zips, get the new releases into fresh folders as in step 1, then copy the three `overrides` folders across:

```powershell
Copy-Item -Path .\build-lab-old\overrides -Destination .\build-lab -Recurse
Copy-Item -Path .\new-AdDomain-old\overrides -Destination .\new-AdDomain -Recurse
Copy-Item -Path .\New-VMwareWorkstationVM-old\overrides -Destination .\New-VMwareWorkstationVM -Recurse
```

A project with no `overrides` folder gives an error for that line, which you can ignore. Nothing else carries over.

## What has been tested

The migration was run offline against unedited copies of build-lab 1.0, 2.0 and 2.1 taken from their release tags, and against copies with edited defaults, values it should refuse and a file already in `overrides`. None of that has been followed by a live build. 2.1 itself was run end to end on live VMs in all four modes, with new-AdDomain 2.0 and New-VMwareWorkstationVM 1.0.2. 2.2's own live run is still to come.
