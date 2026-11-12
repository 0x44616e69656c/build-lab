# Contributing

Thanks for considering a contribution. This is a single-author utility script, but bug reports and pull requests are welcome.

## Reporting Bugs

Open a GitHub issue. Include:

- What you ran (the exact command line, with any secrets redacted)
- The first line of the text log, which names the build-lab version that ran
- Your override file, `overrides\overrides.psd1`, if you have one, and new-AdDomain's and New-VMwareWorkstationVM's if the problem is in those parts, with any secret value such as a DSRM password or product key removed
- What happened versus what you expected
- Your VMware Workstation version and Windows host version
- The Windows Server media you targeted (channel and image name, plus links if relevant)
- The relevant lines from the `logs` folder, meaning the text log, the CSV logs, the VM build transcript for every VM the run built (the DC and any member servers), and the `guest-<timestamp>` folder if there is one
- I love screenshots if they show something useful

If you would rather not use GitHub issues, reach out using the contact details in the README.

## Contributing Code: Fork and Pull Request

This project accepts code changes through the fork and pull request model only. Direct pushes to `main` are not accepted.

1. **Fork** the repository to your own account.
2. **Clone** your fork locally.
3. **Create a branch** off `main` for your change (`git checkout -b fix/short-description`).
4. **Make your change** and commit it with a clear message describing what and why.
5. **Push** the branch to your fork.
6. **Open a pull request** against this repository's `main` branch. Describe the problem, the fix, and how you tested it.

Keep each pull request focused on one logical change. Small, reviewable pull requests get looked at faster than large ones.

Pull requests aren't merged on GitHub. Each release replaces the published files from my development copy, so a change merged here would disappear at the next release. When I accept your pull request, I apply the change to my copy by hand and close the pull request with a note crediting you. The change ships in the next release.

## Pull Request Requirements

Before you open a pull request, confirm your change meets these:

- **PowerShell 5.1.** The script targets Windows PowerShell 5.1. Do not introduce PowerShell 7-only syntax or cmdlets.
- **PSScriptAnalyzer clean.** Run PSScriptAnalyzer and resolve warnings on the code you touched.
- **A new setting goes in the catalog.** Give it an entry in `include\override-catalog.psd1`, with what it changes (for a setting that isn't a parameter), its default and the reason for that default. `OVERRIDE.md` is generated from the catalog, so don't edit it by hand. I generate it again when I apply your change. A new setting never becomes a value to edit in the script itself.
- **No new hard-coded paths.** Paths come from parameters or are discovered at runtime. Do not add hard-coded drive letters or install locations.
- **Approved verbs.** Any new function must use a Microsoft approved PowerShell verb (`Get-Verb`).
- **Self-contained functions.** A function uses only its own parameters. If it needs an outside value, pass it in as a parameter rather than reading a global.
- **Secrets stay out of the diff.** No real passwords, product keys, IP addresses, or paths from your environment in code, comments, or examples.
- **Universally useful.** If a change is weird and only for your environment or moves away from test-lab builds, that is what your fork is for.
- **Describe your testing.** State what you ran the change against (Workstation version, media). End-to-end validation to date is against Windows Server 2025 evaluation media on VMware Workstation Pro 26H1, including the member server modes. Note it if you tested other media or versions.

## Questions

Open an issue or reach out using the contact details in the README.
