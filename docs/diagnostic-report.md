# Diagnostic Report (`--report`)

`./strix-halo-setup.sh --report` writes a shareable diagnostic bundle describing
what this machine looks like and what the toolkit's fixes are actually doing on
it. It applies nothing, changes nothing, and needs no `sudo`.

This page has two halves. The first is for **reporters** — anyone opening an
issue. The second is for **maintainers** — what to do with a bundle once it
arrives.

---

## For reporters

### Running it

```bash
./strix-halo-setup.sh --report
```

No root. Nothing is installed, modified, enabled or removed. If you run it under
`sudo` anyway, the bundle is still written to *your* home directory and chowned
back to you — never to `/root`.

Two files are written, both named for the UTC timestamp of the run:

| File | What it is |
| :--- | :--- |
| `strix-halo-report-<stamp>.md` | The human half. Markdown, meant to be read and pasted. |
| `strix-halo-report-<stamp>.fixture` | The machine half. A packed device fixture a maintainer can replay. |

The `.md` file also embeds a copy of the fixture between two HTML-comment
markers at the end, so pasting the `.md` alone is enough — a maintainer can lift
the fixture straight back out of it.

By default they land in your home directory. `--report-out DIR` puts them
somewhere else:

```bash
./strix-halo-setup.sh --report --report-out /tmp
```

### What is in it

The `.md` bundle has these sections:

- **Device** — the detected model, vendor, class, support tier, fixture key, and
  the seven `CAP_*` capability flags detection produced.
- **DMI (read allowlist)** — exactly seven fields: `sys_vendor`, `product_name`,
  `product_family`, `board_name`, `product_version`, `bios_version`,
  `chassis_type`. Nothing else in `/sys/class/dmi/id/` is ever read.
- **Applied fix verification** — the same tri-state table `--verify` prints:
  every registered fix, whether it is `LIVE`, awaiting a `REBOOT`, `REJECT`ed by
  the kernel, not applied, unknown, or n/a for this device.
- **Hardware** — filtered `lspci -nn`, `lsusb`, `lsmod` and `aplay -l`, cut down
  to the display / audio / network / input lines the toolkit cares about.
- **Configuration this toolkit can write** — `/proc/cmdline`, every
  `/etc/modprobe.d/*.conf`, and the bootloader cmdline fragments
  (`/etc/default/limine`, `/etc/default/grub`, `/etc/kernel/cmdline`).
- **Kernel log excerpt** — omitted unless you pass `--report-logs`. See below.
- **Findings** — anything the bundle's own self-check wants a human to look at.

### What is *not* in it

Removed before the file is written, then re-scanned for afterwards by a set of
detectors written independently of the removers:

- serial numbers (`product_serial`, `board_serial`, `chassis_serial`,
  `product_uuid`, `board_asset_tag`, `chassis_asset_tag` are never *read* in the
  first place)
- MAC addresses
- filesystem UUIDs and `PARTUUID=` values
- IPv4 and IPv6 addresses
- WiFi network names (SSIDs), including saved ones you are not connected to
- your hostname and your username
- `/home/<you>` and `/root/` paths
- `ID_SERIAL*` / `ID_WWN*` udev properties, and input-device `Uniq=` lines

Package lists, browser data, dotfiles, `/etc` outside the four config paths
above, and your kernel log (by default) are not collected at all.

Note that the report is not small — a full bundle from a Strix Halo laptop is
around 130 KB. That is larger than GitHub's issue-body limit, so in practice you
will usually **attach** the two files to the issue by drag-and-drop rather than
pasting the `.md` inline.

### Reading the redaction banner

After writing the bundle, `--report` re-reads every byte of it and looks for the
things it just removed. Two outcomes:

**Clean** — you get the two paths and nothing else:

```
✓  Diagnostic report written to /home/you/strix-halo-report-20260905-111446.md
Machine-readable fixture: /home/you/strix-halo-report-20260905-111446.fixture
```

That bundle is safe to share.

**Not clean** — something identifying survived, and you get this instead:

```
################################################################
# UNSAFE REPORT — identifying data survived redaction.         #
# The bundle has been renamed to *.UNSAFE and made 0600.       #
# Do NOT share it. Please open an issue quoting the classes    #
# and line numbers above (never the lines themselves).         #
################################################################
```

The files are renamed to `*.UNSAFE` and made readable only by you. **Do not
share an `.UNSAFE` bundle.** The lines above the banner name a *class* (`MAC`,
`UUID`, `IPV4`, `HOSTNAME`, `SSID`, …) and line numbers, never the matching
text. Open an issue quoting only those class-and-line-number lines. That is a
bug in the redactor and it is worth knowing about — but the file itself stays on
your machine.

### `--report-logs`

```bash
./strix-halo-setup.sh --report-logs   # only when a maintainer asks
```

This adds a filtered excerpt of this boot's kernel log. **Use it only when a
maintainer asks for it.** The verification layer already extracts the one thing
the kernel log is diagnostically needed for — the fixed-shape
`<module>: unknown parameter '<name>' ignored` line, which carries no
identifying data — so a general log dump keeps nearly all of the privacy risk
and adds little. It is also dropped entirely if your hostname or username turn
out not to be safely substitutable, rather than being emitted half-redacted.

---

## For maintainers

### Extracting the fixture

A bundle's machine half is a packed device fixture. Lift it out with:

```bash
bash scripts/extract-fixture.sh <pasted-issue.md> tests/fixtures/<device-key>
```

The input can be the report `.md` (the extractor finds the marker block and
strips the fences) or the bare `.fixture` file. The output directory is the only
path ever written to; the unpacker refuses any entry whose relative path is
absolute, contains `..`, or escapes the target through a symlink. A pasted issue
is untrusted input and is treated as opaque bytes until it has passed
`fixture_validate`.

`<device-key>` is column 1 of `STRIX_HALO_KNOWN_DEVICE_PROFILES` in
`strix-halo-lib/device-profile-data.sh` — `asus-gz302`, `hp-zbook-ultra-g1a`,
`framework-desktop`, and so on. Fixture directory names and device-matrix rows
are the same namespace on purpose: a fixture for a device that is not in the
matrix, or a matrix row with no fixture, is visible by name.

**The unpacked fixture needs no editing.** Do not hand-tidy it, do not
"normalise" values, do not delete files that look redundant. A present-but-empty
file and an absent file mean different things (`modinfo` exists / does not
exist), empty directories are load-bearing (`find` exits 0 on an empty directory
and 1 on an absent one), and `cmd/file-modes` carries permission bits that a git
checkout physically cannot. Editing any of those turns a faithful capture into a
fiction. Then:

```bash
bash tests/fixture-sanitization-lint.sh tests/fixtures
bash tests/device-fixture-replay.sh
```

### A fixture records what happened, not what is correct

This is the part that matters most, and it is easy to get backwards.

A submitted fixture's `expected` file records **what that machine's detection
actually produced**. It is not a statement that those values are right. The two
are only the same thing on hardware that has been verified — and exactly one of
the eleven profiles in this repository has been: the ASUS GZ302. The other ten
are DMI string matches written from spec sheets, and nobody has ever watched
them run.

So when a Framework Desktop bundle arrives with `CAP_MT7925=false`, there are
two possible readings:

1. that machine genuinely has no MediaTek radio, or
2. detection failed to see one that is there.

Committing the fixture uncritically picks reading (1) by default and freezes it
as expected behaviour — the detection bug becomes a permanently asserted
regression test, and the next person to fix it will see CI go red and assume
*they* broke something. That is worse than having no fixture at all.

**Before trusting a first fixture from a new profile,** read its `expected`
values against the reporter's own raw `lspci -nn` and `lsmod` blocks in the
human half of the same bundle:

- `CAP_MT7925=false` — is there a `14c3:7925` (or another MT792x) line in the
  PCI block?
- `CAP_CS35L41=false` — is there a `cs35l41` module loaded, or a `CSC3551` ACPI
  device in the audio codec output?
- `CAP_INTERNAL_OLED=false`, `CAP_DETACHABLE_KB=false`, `CAP_ASUS_WMI=false` —
  do the DMI fields and the USB block agree?
- Does the `Device` section's model and support tier match the machine the
  reporter says they have?

If the raw output contradicts `expected`, you have found a detection bug. Fix
the detection first, recapture or re-derive `expected`, and say so in the merge
commit. A first fixture that fails replay is the layer doing its job.

Only a capture taken on the physical device carries
`verified_on_real_hardware=true` in its `meta` — a hand-authored or synthesised
fixture leaves it `false`. Check it.

### See also

- [Contributing a Device Fixture](contributing-a-device-fixture.md) — the
  contributor-facing capture procedure.
- [`tests/fixtures/README.md`](../tests/fixtures/README.md) — the fixture
  format in full, including the three capture rules that are load-bearing.
- [`strix-halo-lib/README.md`](../strix-halo-lib/README.md) — the probe seam,
  the verification vocabulary, and the libraries behind these flags.
