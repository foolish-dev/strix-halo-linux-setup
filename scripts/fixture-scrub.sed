# ==============================================================================
# Strix Halo fixture scrubber
# Version: 6.10.0
#
# The single free-text scrubber for captured fixture artefacts.  Every free-text
# capture (lspci/lsusb/lsmod/aplay output, /proc and /etc mirrors, udev
# properties) is passed through this script by fixture_capture_tree().
#
# Exactly four rules.  Each is written with explicit character-class repetition
# and without back-references so that the script behaves IDENTICALLY under
# `sed -f` (BRE) and `sed -E -f` (ERE); an interval such as \{8\} or a \(...\)
# group would change meaning between the two dialects and `sed -E` hard-fails on
# a `\1` right-hand side.  Do not "simplify" these back into intervals.
#
# Structured key/value output (udev properties, DMI) is filtered by a read
# ALLOWLIST in fixture-format.sh instead; this scrubber is the free-text net,
# not the primary defence.  In particular DMI is never globbed:
# /sys/class/dmi/id/board_asset_tag is mode 0444 on shipping units and holds a
# serial-like value that no generic regex catches.
#
# The canonical placeholders written here (the all-zero UUID and the all-zero
# MAC) must be allowlisted by any lint that greps for unscrubbed secrets, since
# they match the very patterns the lint looks for.
# ==============================================================================

# 1. UUIDs (root=UUID=..., /etc/fstab-style references, udev ID_FS_UUID).
s/\b[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]\b/00000000-0000-0000-0000-000000000000/g

# 2. MAC addresses.  Six colon-separated octets are required, so a PCI address
#    (c4:00.0), a PCI id ([14c3:7925]) and a USB id (0b05:1a30) cannot match.
s/\b[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]\b/00:00:00:00:00:00/g

# 3. /proc/bus/input/devices unique identifiers (touchscreen/pen serials).
s/^U: Uniq=.*$/U: Uniq=/

# 4. PARTUUID references in bootloader configs and /proc/cmdline.
s/PARTUUID=[0-9a-fA-F-][0-9a-fA-F-]*/PARTUUID=REDACTED/g
