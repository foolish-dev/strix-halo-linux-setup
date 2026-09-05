# Contributing a Device Fixture

A **device fixture** is a redacted snapshot of everything this toolkit's
detection and verification code reads on one machine: command output, sysfs
nodes, procfs files, and the `/etc` config the installer writes. Checked into
`tests/fixtures/`, it lets the **real bodies** of the detection helpers run
against your machine's data in CI, forever, on every future change.

If you own a Strix Halo device that is not an ASUS ROG Flow Z13, capturing one
is the single most useful thing you can contribute.

---

## CALL FOR FIXTURES

> *The section below is written to be pasted verbatim into a GitHub issue or
> Discussion. It is addressed to device owners, not to maintainers.*

<!-- ---------------- 8< ---------- paste from here ---------- >8 ---------- -->

### Do you own a Strix Halo machine? One command would make this project honest about it.

This project ships hardware fixes for **eleven** AMD Strix Halo devices —
ASUS ROG Flow Z13, HP ZBook Ultra G1a, HP Z2 Mini G1a, Framework Desktop,
ASUS TUF Gaming A14, Sixunited AXP77, GMKtec EVO-X2, Minisforum MS-S1 Max,
AYANEO NEXT 2 and GPD Win 5.

**Exactly one of them has ever been run on the real hardware.** The other ten
device profiles are DMI string matches written from vendor spec sheets. Every
`CAP_*` flag in them — whether your machine has Cirrus CS35L41 speaker amps, a
detachable keyboard, an internal OLED panel — is somebody's reading of a product
page. Nobody has checked. We would like to stop guessing.

If you own one of those machines, you can end the guessing for your device in
about a minute:

```bash
git clone https://github.com/foolish-dev/strix-halo-linux-setup.git
cd strix-halo-linux-setup
./scripts/capture-device-fixture.sh
```

That is the whole thing. It writes two files under `tests/fixtures/` and stops.

**What it does *not* do**, and this is checked, not merely promised:

- It **needs no root** — do not run it with `sudo`.
- It **changes nothing** on your machine. It never loads or unloads a kernel
  module, never starts, stops, enables or disables a systemd unit, never invokes
  a package manager, and never writes to `/etc`, `/usr`, `/boot` or `/var`. The
  only two paths it writes are the fixture directory and its packed sibling.
- It **does not collect anything that identifies you or your machine.**
  Serial numbers, asset tags, hardware UUIDs and MAC addresses are not scrubbed
  out afterwards — they are *never read in the first place*. DMI is a fixed
  allowlist of seven model/vendor/BIOS fields; udev output is a fixed allowlist
  of eleven properties; the kernel log is narrowed to lines of the single fixed
  shape `<module>: unknown parameter '<name>' ignored`. Anything free-text that
  does get captured is then run through a scrubber, and then an independent lint
  re-reads every byte that landed on disk and refuses the capture if it finds a
  UUID, a MAC or an input-device serial. The capture is safe to attach to a
  public issue. If you would like to confirm that yourself, read it: it is
  roughly five hundred files of plain text, and `cat tests/fixtures/<your-key>/expected` is the
  interesting page.

Then attach `tests/fixtures/<your-key>.fixture` to an issue, or open a pull
request with the directory. Either is fine — the file is a single self-contained
text archive of the capture (around 120 KB, too big to paste inline, so please
attach it rather than pasting).

**One thing to know before you look at the result: your fixture may well fail
CI, and that is the point.** Everything the fixture records is what our
detection code *actually did* on your machine, not what it should have done. If
CI comes back saying `THE PROFILE RECORD IS PROBABLY WRONG`, you have just found
a real bug in this repository that nobody could have found without your
hardware. Say so in the issue, tell us which lines look wrong, and **please do
not edit the capture to make it go green** — that would turn a genuine hardware
report into a rubber stamp and is precisely the outcome the test is built to
prevent.

Devices we have never seen: **HP ZBook Ultra G1a, HP Z2 Mini G1a, Framework
Desktop, ASUS TUF Gaming A14, Sixunited AXP77, GMKtec EVO-X2, Minisforum MS-S1
Max, AYANEO NEXT 2, GPD Win 5** — and any Strix Halo machine not on that list at
all, which is even more valuable, because it means the device matrix is missing
a row.

<!-- ---------------- 8< ---------- paste to here ------------ >8 ---------- -->

---

## Read this before you start

> **Step 5 is the point of the exercise.** Nine of the ten non-GZ302 profiles in
> this repository have never been run on the hardware they claim to support;
> they are DMI string matches written from spec sheets. If `expected` says
> `CAP_CS35L41=false` and your machine has Cirrus amplifiers, that is a bug in
> this repository, and your PR is the first evidence of it. A failing first
> fixture is the feature working — do not adjust it until it goes green.

The capture tool records what detection *did*, not what detection *should have
done*. Those are the same thing only on hardware somebody has verified, and so
far that is one device out of eleven. Your job is not to produce a green
fixture. Your job is to produce an honest one and tell us which lines look
wrong.

---

## The procedure

Four commands, then a read, then a PR. None of it needs root.

### 1. Clone

```bash
git clone https://github.com/foolish-dev/strix-halo-linux-setup.git
cd strix-halo-linux-setup
```

### 2. Capture

```bash
./scripts/capture-device-fixture.sh
```

**Requires no root. Modifies nothing.** It never calls `modprobe`, never
starts/stops/enables/disables a unit, never invokes a package manager, and never
writes to `/etc`, `/usr`, `/boot` or `/var`. The only two paths it writes are
`tests/fixtures/<key>/` and its sibling `tests/fixtures/<key>.fixture` (the
packed transport copy).

The key is chosen for you from your machine's DMI. Override it if you need to:

```bash
./scripts/capture-device-fixture.sh --key framework-desktop
./scripts/capture-device-fixture.sh --out /tmp/mycapture --force
```

Before it reports success the tool runs detection twice — once against the
fixture it just wrote, once live — and refuses the capture if the two disagree.
You cannot submit a fixture that does not reproduce your own machine. That
comparison includes every row `--verify` would print, so a capture that is lossy
for the *verification* layer is rejected too, not just one that is lossy for
detection. A successful run says so:

```
  live and fixture detection agree on every key
  13 verification row(s) resolve identically live and in replay
```

### 3. Lint

```bash
bash tests/fixture-sanitization-lint.sh tests/fixtures
```

The independent check that the scrubber actually ran. It re-reads every byte
that landed in the tree and looks for serials, MACs and UUIDs. A contributor's
scrubber can be skipped; CI's cannot, so run this yourself first. It takes a
directory argument, so you can point it at a capture that lives outside the
repo.

### 4. Replay

```bash
bash tests/device-fixture-replay.sh
```

This is the test CI will run. It replays your fixture through the real,
unmodified detection code — there are no function overrides in it, and that
absence is the whole point. Like the lint, it takes a directory argument
(`bash tests/device-fixture-replay.sh /tmp/mycapture-parent`) so a capture can
be replayed before it is committed.

**This is the step that may go red, and going red may be correct.**
[What CI will say](#what-ci-will-say) below is the map.

### 5. Read `expected` and say what is wrong

```bash
cat tests/fixtures/<your-key>/expected
```

Read every line. This is the step nobody else can do for you, because nobody
else has the machine in front of them.

The file has two kinds of line.

**Detection keys**, `KEY=value`:

```
CAP_CS35L41=true
DEVICE_CLASS=tablet
WIFI_DRIVER=mt7925e
GPU_DEVICE_ID=1002:1586
```

For each `CAP_*=false`, ask whether it is *true* that your machine lacks that
hardware. For each detected model, class and support tier, ask whether it
describes the machine you are sitting at. Cross-check against your own
`lspci -nn`, `lsusb` and `lsmod` output.

**Verification rows**, `# verify <component>.<status_fn>=<STATUS>`:

```
# verify input.input_hid_config_status=REJECTED
# verify gpu.gpu_ppfeaturemask_status=LIVE
# verify audio.audio_cs35l41_config_status=ABSENT
```

These are what `sudo ./strix-halo-setup.sh --verify` would say about each fix on
your machine, recorded so CI can hold the verification layer to it. `ABSENT`
just means the fix is not applied — a fresh clone has nothing applied, so a
column of `ABSENT` is normal and correct. `REJECTED` means the kernel is
*ignoring* something the toolkit wrote, which is the bug class this whole layer
exists to catch. They are comment-prefixed only so that older tooling can read
the file; the replay test asserts every one of them.

**All of them are required.** The replay fails a fixture whose `expected`
asserts none of the verify rows, and one that asserts only some of them, naming
the rows that are missing. A detection key may be left out of `expected` — the
replay skips one it emits and `expected` omits, so you can decline to assert a
value you are unsure of — but a verify row may not, because you never write one:
the capture tool writes all thirteen, and the only way one goes missing is that
somebody deleted it. Deleting the row that just went red is exactly the failure
this rule exists to prevent, and it used to work.

If your capture predates the verification rows, this is the failure you will
get, and the fix is to recapture rather than to hand-write the rows:

```bash
bash scripts/capture-device-fixture.sh --key <your-key> --force
```

**If your machine lacks the hardware a row covers, the row is still there.**
A row gated on a `CAP_*` flag that is false is recorded as `NA` without its
resolver ever being called, so a machine with no MT7925 and no ASUS WMI still
produces all thirteen rows and simply reads `NA` on seven of them. `NA`
satisfies the requirement like any other status — you never have to invent a
verdict for hardware you do not have, and you must not delete the line instead.

Then say so in the PR description — plainly, line by line:

> `CAP_CS35L41=false`, but this machine has Cirrus CS35L41 amplifiers;
> `lsmod` shows `snd_hda_scodec_cs35l41_i2c` loaded and `dmesg` mentions
> `CSC3551`. I believe this is a detection bug, not a real absence.

Do **not** edit `expected` to make the replay pass. A wrong line in `expected`
is a finding; silencing it converts a detection bug into a permanently asserted
regression test, and the next person to fix that bug will see CI go red and
assume they broke something. (It will not work anyway — see
[the second check](#the-annotation-that-resolves-a-contradiction).)

### 6. Open the PR

Title it:

```
fixture: <device>
```

for example `fixture: Framework Desktop (Ryzen AI Max+ 395)`. Include your
distro and kernel version, and the list of `expected` lines you believe are
wrong.

**Commit the directory, not the packed `.fixture` file.** The packed file is a
courier for issues and email; checking it in would carry the same capture twice.

---

## What CI will say

`tests/device-fixture-replay.sh` sorts every failure into one of two classes and
counts them separately in its closing summary, because they call for opposite
responses:

```
Assertions failed: 3
  0 malformed-fixture fault(s)   — the FIXTURE gets fixed
  3 profile contradiction(s)     — the PROFILE RECORD is probably wrong
```

### (a) Malformed fixture — *the fixture gets fixed*

The capture is missing, incomplete, or annotated wrong. Typical messages:

| Message | What to do |
| :--- | :--- |
| `missing capture 'cmd/lspci-nn'` | Recapture with `--force`. A capture that is absent is indistinguishable from hardware that is absent, which is why this fails by name. |
| `meta says fixture_format='2', this replay understands 1` | Your checkout is older or newer than the fixture. |
| `not a device key in STRIX_HALO_KNOWN_DEVICE_PROFILES` | Your machine matched no profile, so the key was slugged from DMI. Say so in the PR — the matrix needs a new row. |
| `'expected' names 'X', which this replay does not produce` | The capture and the replay have drifted apart. Recapture. |
| `'expected' asserted nothing` | The fixture cannot fail, so it is not a fixture. |
| `'expected' asserts NONE of the 13 '# verify' row(s) this replay produces` | The fixture asserts its detection keys and nothing about the verification layer — usually a capture older than the rows. Recapture with `--force`; do not hand-write the rows. |
| `'expected' asserts only 12 of the 13 '# verify' row(s) this replay produces; missing: ...` | A row was removed, or the registry grew since the capture. Recapture and read what changed. A row your hardware cannot exercise is recorded as `NA`, never deleted. |
| `verify input.input_hid_config_status (expected: LIVE, actual: REJECTED)` | Either a genuine regression in the verification layer, or a stale fixture — recapture and read the diff. |

### (b) Profile contradiction — *the profile record is probably wrong*

The capture is well formed. What disagrees is
`STRIX_HALO_KNOWN_DEVICE_PROFILES` in `strix-halo-lib/device-profile-data.sh`.

```
FAIL: framework-desktop: THE PROFILE RECORD IS PROBABLY WRONG — CAP_DETACHABLE_KB:
      device-profile-data.sh says 'false', this hardware says 'true'
      (SMBIOS chassis_type=32 is literally 'Detachable')
```

**This is the message you came here to produce.** It means the device matrix
made a claim about your machine that your machine disagrees with. Report it;
do not silence it.

The device matrix dictates exactly eight values, and only these eight can be
contradicted:

```
DEVICE_VENDOR  DEVICE_MODEL  DEVICE_CLASS  DEVICE_SUPPORT_TIER
CAP_Z13CTL  CAP_COMMAND_CENTER  CAP_DETACHABLE_KB  CAP_INTERNAL_OLED
```

Everything else a fixture records — `CAP_CS35L41`, `CAP_MT7925`,
`CAP_ASUS_WMI`, `CAP_STRIX_HALO`, `CAP_ROCM`, `CAP_DASHBOARD`, and every
`WIFI_*`/`GPU_*`/`INPUT_*`/`AUDIO_*` key — is *detected from the hardware* and
claimed by no record, so it cannot contradict one. Those are held to account by
the ordinary replay assertions instead: whatever your machine reported is what
CI will assert from then on.

Two independent checks produce this class, and they are aimed at each other on
purpose:

- **Check A — the record against your raw captured evidence.** It reads the DMI
  vendor/product/family/board strings and the SMBIOS chassis type straight out
  of the fixture, and never looks at `expected` at all. It asserts that the
  profile's own DMI matcher would in fact select this profile for your machine,
  and that the record's class / detachable-keyboard / internal-panel claims are
  not contradicted by the enclosure your firmware reports. (Only unambiguous
  readings are asserted. `chassis_type=32` is the SMBIOS spelling of
  "Detachable", and a desktop or mini-PC enclosure has no built-in panel or
  keyboard to speak of; finer distinctions like handheld-versus-laptop are *not*
  asserted, because vendors genuinely disagree about them and a rule that
  misfires would force you to write a bogus annotation.)
- **Check B — the record against the values your machine recorded in
  `expected`.** Editing `expected` to make a replay assertion go green moves its
  value away from the record and trips this check instead.

So the "edit the fixture until CI is green" route is closed from both ends:
Check A cannot be reached by editing `expected`, and Check B is *tripped* by it.

### The annotation that resolves a contradiction

Sometimes the record is right and the disagreement is real and expected — or the
record is wrong and is being fixed in the same change, and the fixture has to
keep replaying green in between. Both cases need the same thing: an explicit,
signed statement, in a file a reviewer cannot miss.

```
tests/fixtures/<device-key>.profile-corrections
```

One correction per line, four `|`-separated columns:

```
FIELD|profile_value|hardware_value|why, in your own words
```

For example:

```
# tests/fixtures/framework-desktop.profile-corrections
CAP_DETACHABLE_KB|false|true|Firmware 3.09 reports SMBIOS chassis_type=32 on the
Desktop, which is wrong on Framework's side — there is no keyboard. Tracked in #214.
```

The test enforces four things about that line, and each of them exists to stop
it from becoming a rubber stamp:

1. **`FIELD` must be one of the eight** the device matrix dictates, or
   `PROFILE_DMI_MATCH` for "this machine's DMI does not select this profile at
   all". Anything else is a malformed-fixture fault.
2. **`profile_value` must be what `device-profile-data.sh` says *today*.** This
   is what makes the file self-cleaning: the moment somebody fixes the record for
   real, every annotation about it goes stale and the test demands its deletion
   in the same change.
3. **`hardware_value` must be what the contradiction actually reported.** An
   annotation cannot cover a disagreement it does not describe.
4. **The justification must be at least 24 characters and must not still carry
   the `<...>` placeholder.** "wrong", "n/a" and an untouched template are all
   rejected.

A correction that no longer corrects anything is a failure too. So is a second
correction for the same field.

The test prints the exact line to paste, with the last column pre-filled as
`WHY: <the reason it detected>` for you to replace with your own words:

```
      CAP_DETACHABLE_KB|false|true|WHY: SMBIOS chassis_type=32 is literally 'Detachable'
```

**Why the file lives beside the fixture and not inside it.** Two reasons, and
both are load-bearing:

- `capture-device-fixture.sh --force` does `rm -rf` on the fixture directory
  before recapturing. An annotation stored inside would be destroyed by the next
  routine kernel-bump recapture, and the human testimony would silently vanish
  along with the machine-generated evidence it annotates.
- A fixture directory is 500 files of captured machine state. A reviewer skims
  it. A new top-level `tests/fixtures/<key>.profile-corrections` in the file
  list of a PR is one line that says *a profile record is being changed here*,
  and it is impossible to miss.

Accepted corrections are also surfaced in the coverage table every run:

```
  [x] framework-desktop      (kernel 6.18.3-arch1-1, captured 2026-10-02)
      ^ 1 profile record field(s) DISPUTED by this hardware; see framework-desktop.profile-corrections
```

---

## Alternative: submit a `--report` bundle instead

If you would rather not clone the repo, run

```bash
./strix-halo-setup.sh --report
```

and attach both files to an issue. A maintainer extracts the fixture from it
with `scripts/extract-fixture.sh`. See
[Diagnostic Report](diagnostic-report.md). The capture path above is better
when you can use it, because you get to run step 5 yourself.

---

## What is scrubbed, and why

### Free text

Every free-text capture passes through `scripts/fixture-scrub.sed`, the single
scrubber, which has exactly four rules:

| Rule | Becomes |
| :--- | :--- |
| filesystem UUID | `00000000-0000-0000-0000-000000000000` |
| MAC address | `00:00:00:00:00:00` |
| `U: Uniq=<value>` (input device unique id) | `U: Uniq=` |
| `PARTUUID=<value>` | `PARTUUID=REDACTED` |

A lint that greps a fixture for unscrubbed secrets has to **allowlist those two
canonical placeholders**, because they match the very patterns it is looking
for. `tests/fixture-sanitization-lint.sh` does.

### Structured output uses a read allowlist, never a blocklist

Property sets vary by device and by distro, and a blocklist eventually misses
one. So the capture reads only what is named:

- **udev properties** are filtered to `DEVPATH`, `DEVNAME`, `SUBSYSTEM`,
  `ID_BUS`, `ID_PATH`, `ID_TYPE`, `ID_INTEGRATION`, `ID_VENDOR_ID`,
  `ID_MODEL_ID`, `ID_INPUT` and `ID_INPUT_*`.
- **DMI** is a fixed allowlist of seven fields: `sys_vendor`, `product_name`,
  `product_family`, `board_name`, `product_version`, `bios_version`,
  `chassis_type`.

### `board_asset_tag` and `product_sku` are deliberately never read

**Never glob `/sys/class/dmi/id/*`.** On the flagship GZ302EA both
`board_asset_tag` and `product_sku` are mode `0444` — world-readable, no root
required — and `board_asset_tag` holds a serial-shaped string
(`ATN…`, twenty characters) that no generic UUID/MAC/serial regex catches. A
scrubber cannot save you here; only not reading the field can. The same applies
to `product_serial`, `board_serial`, `chassis_serial`, `product_uuid`,
`chassis_asset_tag`, `modalias` and `uevent`.

This is why DMI is an allowlist of seven names rather than "everything except
the obviously bad ones".

### The kernel log

Captured **only** as lines matching `unknown parameter`. That narrowness is what
makes capturing it possible at all: a full kernel log carries your hostname on
every line, MACs and IP addresses in firewall lines, and your root filesystem
UUID. The matched line has a fixed shape —
`hid_asus: unknown parameter 'fnlock_default' ignored` — and contains nothing
identifying.

---

## Fixture keys

A fixture directory is named for its **device key**, which is column 1 of
`STRIX_HALO_KNOWN_DEVICE_PROFILES` in `strix-halo-lib/device-profile-data.sh`:

```
asus-gz302  hp-zbook-ultra-g1a  hp-z2-g1a  framework-desktop  asus-tuf-a14
sixunited-axp77  gmktec-evo-x2  minisforum-ms-s1-max  ayaneo-next-2  gpd-win-5
```

Using the profile key as the directory name is what keeps fixtures and the
device matrix from drifting apart: a fixture for a device that is not in the
matrix, or a matrix row with no fixture, is visible by name. If your machine
matches nothing, the capture tool falls back to a slug of `sys_vendor` plus
`product_name` — mention that in the PR, because it usually means the matrix
needs a new row.

A packed fixture must be named `<something>.fixture` and **never** `*.sh`: CI
globs `find . -name '*.sh'` and would hand the file to `bash -n` and
`shellcheck`.

---

## Recapturing on a new kernel

`cmd/lsmod` churns on every kernel upgrade — the module list, sizes and use
counts all move — and `cmd/uname-r`, `cmd/modinfo-n/*` and
`sys/module/*/parameters/*` move with it. A recapture PR therefore carries a
**large diff that is almost entirely meaningless noise**.

`meta` records `captured_kernel` (and `captured_distro`, `captured_date`,
`capture_tool_version`) precisely so a reviewer can tell noise from signal. When
`captured_kernel` changed, review these and skim the rest:

- `meta`
- `expected` — both the detection keys and the `# verify` rows
- `etc/`
- `cmd/klog-unknown-params`

Everything else moving is expected. A `# verify` row that moved from `LIVE` to
`REJECTED` across a kernel bump is the single most interesting line such a diff
can contain: it means the new kernel stopped honouring something the toolkit
writes.

`--force` deletes and rewrites the fixture directory. It does **not** touch
`tests/fixtures/<key>.profile-corrections`, which is why that file lives outside
the directory.

---

## See also

- [`tests/fixtures/README.md`](../tests/fixtures/README.md) — the fixture format
  in full: both representations, the `meta` keys, the module tri-state table,
  the three capture rules that are load-bearing, and the annotation format.
- [Diagnostic Report](diagnostic-report.md) — `--report`, and what a maintainer
  does with a submitted bundle.
- [`strix-halo-lib/README.md`](../strix-halo-lib/README.md) — the probe seam and
  the verification vocabulary.
