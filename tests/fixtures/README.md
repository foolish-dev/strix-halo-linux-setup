# Device fixtures

A **fixture** is a redacted snapshot of one machine's detection-relevant state:
the command output, sysfs nodes, procfs files and `/etc` config that the
installer's detection and verification code reads. Replaying a fixture lets the
**real bodies** of the detection helpers run against controlled data, instead of
being stubbed out by a test that overrides the very helper whose body holds the
bug.

The format is defined in exactly one place, `strix-halo-lib/fixture-format.sh`.
It lives in `strix-halo-lib/` rather than here because production code
(`--report`) sources it. This directory holds fixture *data*; the library holds
the *format*.

One fixture ships here today: `asus-gz302/`, captured on the flagship ASUS ROG
Flow Z13 (GZ302EA). The other ten device profiles have no fixture, and
`tests/device-fixture-replay.sh` prints that coverage number on every run.

## The two representations

The same content has two forms, and they round-trip: `unpack(pack(dir)) == dir`.
`tests/report-redaction.sh` asserts it.

### Directory form (canonical)

This is what `STRIX_HALO_FIXTURE_ROOT` points at and what CI replays.

```
tests/fixtures/<device-key>/
├── meta                       provenance, key=value
├── expected                   expected detection results
├── cmd/
│   ├── lspci-nn               captured stdout, one file per manifest entry
│   ├── lsmod
│   ├── modinfo-parm/<module>  present-but-empty vs. absent is meaningful
│   ├── modinfo-n/<module>
│   ├── udev-input/<eventN>
│   ├── file-mtimes            "<relpath> <epoch>", mtime of the REAL file
│   └── file-modes             "<relpath> <octal>", mode of the REAL file
├── sys/                       mirrored real paths, minus the leading slash
│   ├── class/dmi/id/sys_vendor
│   ├── module/hid_asus/initstate
│   └── bus/pci/devices/<slot>/uevent
├── proc/
│   ├── cmdline
│   └── stat                   the btime line only
└── etc/
    └── modprobe.d/<name>.conf
```

Two more files sit BESIDE that directory rather than inside it, because
`capture-device-fixture.sh --force` deletes and rewrites the directory:

```
tests/fixtures/
├── <device-key>/                       the fixture (machine-generated evidence)
├── <device-key>.fixture                packed transport copy, never committed
└── <device-key>.profile-corrections    human testimony, committed, optional
```

Because a mirrored path is just the real path with its leading `/` removed,
production code reaches live state and fixture state through one expression and
never an `if`/`else`:

```bash
local path="${STRIX_HALO_FIXTURE_ROOT:-}/sys/class/dmi/id/${field}"
```

Unset or empty, that expands to the literal `/sys/class/dmi/id/sys_vendor`.
Quote the variable; leave any trailing glob bare.

`expected` is an ordinary file inside the fixture, carried as an ordinary block
in the packed form. There is no separate `expect.*` namespace.

### Packed form (transport)

One text file. This is what `--report` emits and what a GitHub issue carries.

```
fixture_format=1
<key>=<value>                     # key ^[a-z][a-z0-9_.]*$, value is a raw single line
---BEGIN file <relpath>---
<verbatim bytes>
---END file <relpath>---
---BEGIN symlink <relpath>---
<link target>
---END symlink <relpath>---
```

- `<relpath>` is the path **inside** the fixture root, so `cmd/lspci-nn` and
  `sys/class/dmi/id/sys_vendor` are the same kind of thing.
- Delimiters sit at column 0.
- `meta` is not a block: its key/value lines are the header, so a packed fixture
  opens with something a human can read at a glance in an issue. `fixture_unpack`
  rebuilds `meta` from exactly those lines.
- If a file's content contains a line that would look like a delimiter, the
  packer emits an `omitted` block (`<delimiter collision>` as its body) rather
  than producing a corrupt archive. `fixture_validate` treats a stray delimiter
  inside a block as corruption.
- The format is line-oriented text. Packing normalises a file that lacks a
  trailing newline to having one, so `unpack(pack(dir)) == dir` holds byte for
  byte on anything `fixture_capture_tree` produced — it applies the same
  normalisation at capture time, which also keeps recaptures diffable.
- A full capture of a Strix Halo laptop packs to roughly 110 KB / 2500 lines,
  which is over GitHub's issue-body limit. Attach the `.fixture` file or use a
  gist; do not paste it inline.

### `.fixture` is the only permitted extension

A packed fixture **must** be named `<something>.fixture` and **must never** be
named `*.sh`. CI jobs 1 and 2 glob `find . -name '*.sh'` and would hand the file
to `bash -n` and `shellcheck`, which would fail on it.

## Fixture keys

A fixture directory is named for its **device key**, which is column 1 of
`STRIX_HALO_KNOWN_DEVICE_PROFILES` in `strix-halo-lib/device-profile-data.sh`:

```
asus-gz302  hp-zbook-ultra-g1a  hp-z2-g1a  framework-desktop  asus-tuf-a14
sixunited-axp77  gmktec-evo-x2  minisforum-ms-s1-max  ayaneo-next-2  gpd-win-5
```

Using the profile key as the directory name is what keeps fixtures and the
device matrix from drifting apart: a fixture for a device that is not in the
matrix, or a matrix row with no fixture, is visible by name.

## `meta` keys

```
fixture_format=1
device_key=asus-gz302
device_label=ASUS ROG Flow Z13 (GZ302)
captured_kernel=7.2.2-1-cachyos
captured_distro=cachyos
captured_date=2026-09-05T03:55:58Z
capture_tool_version=6.9.0
verified_on_real_hardware=true
```

`device_label` is resolved from the device matrix when
`device-profile-data.sh` is loaded, and falls back to the key.
`verified_on_real_hardware` records whether the capture came off the physical
device it describes: `fixture_capture_tree` writes `true`, and a hand-authored
or synthesised fixture leaves the default `false`. Only the ASUS GZ302 has ever
been verified on real hardware; the other ten profiles are DMI string matches,
so a fixture for one of them is `false` until somebody captures on the metal.

## What `expected` asserts

`expected` is written by `fixture_capture_tree()` (via
`fixture_expected_snapshot()` in `strix-halo-lib/fixture-format.sh`) and read
back by `tests/device-fixture-replay.sh`. It holds two kinds of line, and the
replay test asserts both.

### Detection keys

```
CAP_CS35L41=true
DEVICE_CLASS=tablet
WIFI_DRIVER=mt7925e
AUDIO_SUBSYSTEM_ID=1043:1fb3
```

Every `KEY=value` line is compared against the value the replay produced. A key
the replay emits but `expected` omits is skipped, so a contributor may leave out
an assertion they are unsure of. A key `expected` names and the replay does
**not** produce is a failure, not a skip — that is the drift between the two
halves of the format made visible.

### Verification rows

```
# verify wifi.wifi_aspm_workaround_status=ABSENT
# verify input.input_hid_config_status=REJECTED
# verify gpu.gpu_ppfeaturemask_status=LIVE
```

One line per `VERIFY_REGISTRY` row: the tri-state verdict
(`LIVE`/`PENDING`/`REJECTED`/`ABSENT`/`UNKNOWN`/`NA`) that
`sudo ./strix-halo-setup.sh --verify` would print for that fix on the captured
machine. A row gated on a `CAP_*` flag that is false records `NA` without
calling its resolver, exactly as `verify_run_report()` does.

They are **comment-prefixed on purpose**: a parser that predates them treats
them as comments and stays green, which is what let them be added to the format
without turning every fixture red on the day they were written.

That backward compatibility was, for one release, the whole of their fate — the
replay test skipped every `#` line, so the verification layer's own output was
captured into every fixture and checked by nothing. It is checked now. Ordinary
`#` comments are still skipped; only the `# verify ` prefix is meaningful.

**Every row is required.** With a non-empty `VERIFY_REGISTRY`, `expected` must
assert *every* verify row the replay produces; a fixture that asserts none of
them, or only some of them, is a malformed-fixture fault and the replay goes
red. This is the one place where the "a key `expected` omits is skipped" rule
above does **not** apply, and the asymmetry is deliberate: a detection key can
be left out because a contributor is unsure of it, but nobody writes a verify
row by hand — `fixture_expect_verify_rows()` writes all of them — so the only
way one goes missing is that it was deleted, and the row that gets deleted is
the row that just went red. That deletion used to be answered with a `NOTE:`
and a green build: stripping all thirteen rows out of the GZ302 fixture dropped
thirteen assertions off the run and the replay still passed.

The failure names the missing rows and tells you to recapture:

```
FAIL: asus-gz302: 'expected' asserts NONE of the 13 '# verify' row(s) this
      replay produces — the verification layer is entirely unasserted for this
      fixture; recapture with scripts/capture-device-fixture.sh
```

A capture taken before the rows existed looks exactly like that, and the fix is
`scripts/capture-device-fixture.sh --key <key> --force` on the machine — not a
hand-written row.

**A device that lacks the hardware still carries the row.** The floor does not
ask which rows a given machine "ought" to have: a row gated on a `CAP_*` flag
that is false is recorded as `NA`, never omitted, so a fixture from a machine
with no MT7925 and no ASUS WMI still carries all thirteen rows and simply says
`NA` on seven of them. `NA` satisfies the requirement like any other status,
which is what keeps the floor from shutting out a genuinely different device.

Asserting them is why `tests/device-fixture-replay.sh` sources
`probe-source.sh` and `verify-manager.sh` **first** and `display-fix.sh`
**last**. Every consumer library registers its rows behind a
`declare -F verify_register` guard, so a `verify-manager.sh` sourced late
registers nothing at all and the assertions would silently become vacuous rather
than red. `display-fix.sh` owns the thirteenth row. The test prints the registry
size on every run and fails outright if it is zero.

## When the fixture and the device matrix disagree

A replay failure is sorted into one of two classes, counted separately, because
they call for opposite responses:

```
Assertions failed: 3
  0 malformed-fixture fault(s)   — the FIXTURE gets fixed
  3 profile contradiction(s)     — the PROFILE RECORD is probably wrong
```

**(a) Malformed fixture.** A missing capture, an unreadable `meta`, a key the
replay cannot produce, a broken annotation. Contributor error; the fixture gets
fixed.

**(b) Profile contradiction.** The capture is well formed and
`STRIX_HALO_KNOWN_DEVICE_PROFILES` in `strix-halo-lib/device-profile-data.sh` is
what disagrees with it. Nine of the ten non-GZ302 rows were written from vendor
spec sheets, so the first real fixture for one of them may well land here — and
that failure is the feature working.

`device_profile_apply_record()` sets exactly eight variables from the matrix
row, and only these eight can be contradicted:

```
DEVICE_VENDOR  DEVICE_MODEL  DEVICE_CLASS  DEVICE_SUPPORT_TIER
CAP_Z13CTL  CAP_COMMAND_CENTER  CAP_DETACHABLE_KB  CAP_INTERNAL_OLED
```

(`CAP_Z13CTL` and `CAP_COMMAND_CENTER` are normalised to `false` for any
non-ASUS row first, because `device_detect()` forces them false after applying
the record. Everything else a fixture records — `CAP_CS35L41`, `CAP_MT7925`,
`CAP_ASUS_WMI`, `CAP_STRIX_HALO`, `CAP_ROCM`, `CAP_DASHBOARD`, every
`WIFI_*`/`GPU_*`/`INPUT_*`/`AUDIO_*` key — is detected from the hardware and
claimed by no record, so it cannot contradict one. Those are the ordinary replay
assertions' business.)

Two checks produce this class, and they are aimed at each other on purpose:

- **Check A — the record against the fixture's RAW captured evidence.** It reads
  `sys/class/dmi/id/{sys_vendor,product_name,product_family,board_name}` and
  `chassis_type` directly and **never opens `expected`**. It asserts that
  `device_profile_record_matches_dmi()` — the installer's own matcher, not a
  looser copy — would in fact select this profile for this machine, and that the
  record's class / detachable-keyboard / internal-panel claims survive contact
  with the SMBIOS enclosure type. Only unambiguous readings are asserted:
  chassis type 32 is the SMBIOS spelling of "Detachable", and the desktop /
  mini-PC / rack enclosures have no built-in panel or keyboard. Handheld-versus-
  laptop and tablet-versus-convertible are deliberately **not** asserted —
  vendors genuinely disagree, and a rule that misfires would force a bogus
  annotation, which is worse than no rule.
- **Check B — the record against the values `expected` recorded on the metal.**

Check A cannot be reached by editing `expected`. Check B is *tripped* by editing
`expected`. So "edit the fixture until CI is green" is closed from both ends.

### `<device-key>.profile-corrections`

The only way to resolve a contradiction. One correction per line, four
`|`-separated columns; `#` comments and blank lines are ignored:

```
FIELD|profile_value|hardware_value|why, in your own words
```

```
# tests/fixtures/framework-desktop.profile-corrections
CAP_DETACHABLE_KB|false|true|Firmware 3.09 reports SMBIOS chassis_type=32, which
is wrong on Framework's side — there is no keyboard on a Desktop. Tracked in #214.
```

`FIELD` is one of the eight above, or `PROFILE_DMI_MATCH` for "this machine's
DMI does not select this profile at all". The test rejects, as malformed-fixture
faults:

- an unknown field, or the same field corrected twice;
- a `profile_value` that is not what `device-profile-data.sh` says **today** —
  which is what makes the file self-cleaning, since fixing the record for real
  makes every annotation about it stale in the same change;
- a `hardware_value` that is not what the contradiction actually reported;
- a justification under 24 characters, or one still carrying a `<...>`
  placeholder;
- a correction that no longer corrects anything.

The failure message prints the exact line to paste, with the last column
pre-filled as `WHY: <reason>` for the annotator to replace.

**It lives outside the fixture directory** for two reasons, both load-bearing:
`capture-device-fixture.sh --force` does `rm -rf` on that directory, so an
annotation stored inside would be destroyed by the next routine kernel-bump
recapture; and a fixture directory is five hundred files of machine state that a
reviewer skims, whereas one new top-level file in a PR's file list says *a
profile record is being changed here* and is impossible to miss.

Accepted corrections are surfaced in the coverage table on every run:

```
  [x] framework-desktop      (kernel 6.18.3-arch1-1, captured 2026-10-02)
      ^ 1 profile record field(s) DISPUTED by this hardware; see framework-desktop.profile-corrections
```

## The three capture rules that are load-bearing

### 1. Every enumerated directory exists, even when empty

Create the directory with a `.gitkeep` inside. Git cannot store an empty
directory, and `find` distinguishes present-but-empty (rc 0) from absent
(rc 1) — losing that distinction makes a whole bug class unreproducible.

The concrete case: `/sys/bus/spi/devices` is **present and empty** on the
GZ302EA, and `device_detect_cs35l41()` runs

```bash
find /sys/bus/i2c/devices /sys/bus/spi/devices -maxdepth 1 -iname "*cs35l41*" ...
```

which exits 0 for an empty directory and 1 (with an error on stderr) for an
absent one. A fixture that dropped the empty directory would replay the wrong
branch.

`.gitkeep` is inert against every pattern the detection code matches on
(`*cs35l41*`, `*CSC3551*`, `card*`, `event*`), so it can never be mistaken for a
device.

### 2. Record the mode of every mirrored `/sys/module` file

A fixture tree cannot carry a permission bit. Git stores only the executable
bit, and every file in an unpacked mirror belongs to whoever unpacked it — so
asking the mirror whether a parameter is writable answers a question about the
test runner, never about the kernel. `cmd/file-modes` carries the real mode, and
`_probe_file_mode()` is the seam that reads it back.

This is load-bearing, not hygiene. The false-alarm invariant in
`verify_modprobe_option()` only escalates a stale value to `REJECTED` for a
parameter the kernel exposes read-only; a writable one may simply have been
changed at runtime by something else, so it degrades to `PENDING`. On the
GZ302EA `amdgpu/ppfeaturemask` is `0444` and `mt7925e/disable_aspm` is `0644`.
Without the captured mode, the `0444` parameter replays as writable and a
genuine `REJECT` silently becomes `REBOOT` — the same "reports success for a
setting the kernel threw away" failure the whole layer exists to prevent.

`cmd/file-mtimes` exists for the same reason one level up: a git checkout's
timestamps are arbitrary, so "the config file predates this boot" is meaningless
offline unless the real mtime travels with the capture.

### 3. Mirror leaf files only, never deep trees

The real `/sys/class/{drm,sound,input}/*` entries are symlinks into
`/sys/devices/...`. A fixture mirrors them as real directories, so an unbounded
`find` behaves differently: `find /sys/class/sound/ -name "card*"` does **not**
recurse on a real machine, but it would recurse into a deep mirror and return
paths that cannot exist. Keeping `sys/class/sound/cardN/` to a single `id` file
makes that recursion unobservable.

Two consequences worth knowing:

- `sys/class/drm/cardN/device/driver` is stored as a **relative symlink**
  (`../../../../bus/pci/drivers/amdgpu`) with a real `.gitkeep`-bearing target
  directory, because `gpu_get_drm_card()` resolves it with `readlink -f`. The
  relative target is the same shape the kernel emits, and it resolves inside the
  fixture root.
- Under `ip_discovery/die/0/`, the named aliases (`GC -> 11`) stay symlinks to
  their numeric siblings, because `gpu_get_ip_version()` looks them up by name.

## Redaction

`scripts/fixture-scrub.sed` is the single free-text scrubber. Every free-text
capture passes through it. Exactly four rules: UUID, MAC, `U: Uniq=`, `PARTUUID=`.
It is written to behave identically under `sed -f` and `sed -E -f`.

Structured key/value output uses a **read allowlist**, never a blocklist,
because property sets vary by device and distro and a blocklist eventually
misses one:

- **udev properties** are filtered to `DEVPATH`, `DEVNAME`, `SUBSYSTEM`,
  `ID_BUS`, `ID_PATH`, `ID_TYPE`, `ID_INTEGRATION`, `ID_VENDOR_ID`,
  `ID_MODEL_ID`, `ID_INPUT`, `ID_INPUT_*`.
- **DMI** is a fixed allowlist of seven fields: `sys_vendor`, `product_name`,
  `product_family`, `board_name`, `product_version`, `bios_version`,
  `chassis_type`.

**Never glob `/sys/class/dmi/id/*`.** `board_asset_tag` is mode 0444 — readable
by any user — and holds a serial-like value on shipping units that no generic
regex catches. Never read `product_serial`, `board_serial`, `chassis_serial`,
`product_uuid`, `board_asset_tag`, `chassis_asset_tag`, `modalias` or `uevent`.

The kernel log is captured **only** as lines matching `unknown parameter`. That
narrowness is the reason it can be captured at all: the full log carries the
hostname on every line, MACs and IPs in firewall lines, and the root UUID. The
matched line has a fixed shape — `hid_asus: unknown parameter 'fnlock_default'
ignored` — and contains no identifying data.

A lint that greps a fixture for unscrubbed secrets must **allowlist the
canonical placeholders** `00000000-0000-0000-0000-000000000000` and
`00:00:00:00:00:00`, which otherwise match the very patterns it looks for.

## Adding a detection input

One `_probe_*` one-liner in `strix-halo-lib/probe-source.sh`, and one manifest
entry in `strix-halo-lib/fixture-format.sh`. Nothing else. The manifests are
`FIXTURE_CMD_MANIFEST`, `FIXTURE_SYS_MANIFEST`, `FIXTURE_MODULE_ALLOWLIST` and
`FIXTURE_UNIT_ALLOWLIST`; a capture whose input is the mirror tree itself
(`file-mtimes`, `file-modes`) also goes in `FIXTURE_DEFERRED_CAPTURES` so it
runs after the mirrors exist rather than alongside the other commands.

Mark the entry `required` and it joins
`FIXTURE_REQUIRED_CAPTURES`, which is what makes the replay test fail **by name**
when the capture is missing. That matters because "empty" and "absent" are
indistinguishable to a probe caller, so a missing capture is otherwise silent.

## Module tri-state

`modinfo`'s three answers are encoded as file presence, mirroring the command's
own exit semantics:

| state | encoding |
|---|---|
| no such module | `cmd/modinfo-parm/<m>` **absent** (`modinfo` exited 1) |
| module exists, no parameters | `cmd/modinfo-parm/<m>` present and **empty** |
| module has parameters | `cmd/modinfo-parm/<m>` present with lines |
| module is built into the kernel | `cmd/modinfo-n/<m>` contains `(builtin)` |

The flagship bug this exists to catch lives in that table:
`/etc/modprobe.d/hid-asus.conf` sets `options hid_asus fnlock_default=0`, but
`cmd/modinfo-parm/hid_asus` is present and empty and
`sys/module/hid_asus/parameters/` does not exist — so the parameter can never
have taken effect, and `cmd/klog-unknown-params` says so in the kernel's own
words.

## Recapturing

```bash
source strix-halo-lib/fixture-format.sh

# Directory form -- the canonical checked-in artefact, what CI replays.
fixture_capture_tree tests/fixtures/asus-gz302 asus-gz302

# Packed form -- for transport only, when a fixture travels in an issue or PR.
fixture_pack tests/fixtures/asus-gz302 > /tmp/asus-gz302.fixture
fixture_validate /tmp/asus-gz302.fixture
fixture_unpack  /tmp/asus-gz302.fixture /tmp/replay
```

`fixture_capture_tree` needs no root, writes nothing outside its output
directory, and deliberately bypasses the `_probe_*` seam to run every command
live — it is the thing that *creates* fixtures. The packed file is a courier,
not a second source of truth: what lands in `tests/fixtures/` is the directory.

**`cmd/lsmod` churns on every kernel upgrade** (module list, sizes and use
counts all move), and `cmd/uname-r`, `cmd/modinfo-n/*` and
`sys/module/*/parameters/*` move with it. A recapture PR therefore carries a
large diff that is expected noise; review the `meta`, `expected`, `etc/` and
`cmd/klog-unknown-params` changes, and skim the rest.
