---
name: Bug Report
about: Report a problem with the Strix Halo Linux Setup scripts
title: '[BUG] '
labels: bug
assignees: ''
---

## Bug Description
<!-- A clear and concise description of what the bug is -->

## Diagnostic bundle (required)

Run this — **no `sudo` needed**. It applies nothing and changes nothing:

```bash
./strix-halo-setup.sh --report
```

It writes two files to your home directory:

- `strix-halo-report-<timestamp>.md` — paste it below, or attach it
- `strix-halo-report-<timestamp>.fixture` — the machine-readable half (also
  embedded in the `.md`, so the `.md` on its own is enough)

The bundle carries your distribution, kernel, hardware inventory, detected device
profile, the configuration this toolkit can write, and a check of every applied
fix against live kernel state — so there is nothing here you need to copy by
hand.

**Serial numbers, MAC addresses, filesystem UUIDs, WiFi network names, your
hostname and your username are removed before the file is written, and the file
is re-scanned afterwards to confirm they are gone.** DMI serial and asset-tag
fields are never read in the first place. Your kernel log is not included unless
you explicitly pass `--report-logs`, which you should only do if a maintainer
asks.

If you see an **UNSAFE REPORT** banner, something identifying survived the
redaction pass and the files have been renamed `*.UNSAFE`. **Do not paste or
attach an `.UNSAFE` file.** Open an issue saying so instead, quoting only the
class names and line numbers the banner printed — never the lines themselves.
That is a bug in the redactor and we want to hear about it.

<details>
<summary>strix-halo-report-&lt;timestamp&gt;.md</summary>

```text
<!-- Paste the whole .md file here -->
```

</details>

> A full bundle is around 130 KB, which is larger than GitHub's issue-body limit.
> If GitHub rejects the issue for length, delete the paste and attach both files
> by dragging them into the comment box instead.

**If you could not run `--report`,** say why here and fill in the section below
by hand:

<!-- Explain here if applicable -->

## System Information
<!-- The bundle above already contains all of this. Fill it in only if you could not run --report. -->
**Distribution:** <!-- e.g., Arch Linux, Ubuntu 26.04, Fedora 43 -->
**Kernel Version:** <!-- Output of: uname -r -->
**Script Version:** <!-- Check the header of strix-halo-setup.sh, or run: grep 'Version:' strix-halo-setup.sh -->
**Device:** <!-- e.g., ASUS ROG Flow Z13 (GZ302EA), Framework Desktop -->

## Steps to Reproduce
1. 
2. 
3. 

## Expected Behavior
<!-- What you expected to happen -->

## Actual Behavior
<!-- What actually happened -->

## Error Messages
```
<!-- Paste any error messages here -->
```

## Additional Context
<!-- Add any other context about the problem here -->

## Checklist
- [ ] I have searched existing issues for duplicates
- [ ] I am using one of the supported distributions (Arch, Debian/Ubuntu, Fedora, OpenSUSE)
- [ ] I attached a `--report` bundle (or explained why I could not)
- [ ] The bundle did **not** print an UNSAFE REPORT banner
- [ ] I have an active internet connection
