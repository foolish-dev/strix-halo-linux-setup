import json
import os
import re
import shutil
import subprocess
import threading
import time
from pathlib import Path

from PyQt6.QtCore import QObject, pyqtSignal

# z13ctl valid profiles: quiet, balanced, performance, custom
# We map our 7 tray profiles to z13ctl profiles + explicit TDP overrides.
# tdp=None means let the firmware manage TDP for that stock profile.
POWER_PROFILES = {
    "emergency":   {"z13ctl_profile": "quiet",       "tdp": 10},
    "battery":     {"z13ctl_profile": "quiet",       "tdp": 18},
    "efficient":   {"z13ctl_profile": "quiet",       "tdp": 30},
    "quiet":       {"z13ctl_profile": "quiet",       "tdp": None},
    "balanced":    {"z13ctl_profile": "balanced",    "tdp": 40},
    "performance": {"z13ctl_profile": "performance", "tdp": 55},
    "gaming":      {"z13ctl_profile": "performance", "tdp": 70},
    "maximum":     {"z13ctl_profile": "performance", "tdp": 90},
}

_AUTO_CONFIG_FILE = Path.home() / ".config" / "strix-halo" / "auto.conf"
_PROFILE_CACHE_FILE = Path.home() / ".config" / "strix-halo" / "tray-profile.conf"


class PowerController:
    """Manages power profiles and battery settings via z13ctl."""

    def __init__(self, notifier):
        self.notifier = notifier
        self._last_status_text = ""
        self.available = self.check_available()
        self.current_profile = self._read_current_profile(self._last_status_text)
        self._auto_enabled = False
        self._ac_profile = "performance"
        self._battery_profile = "balanced"
        self._last_plugged = None
        self._load_auto_config()

    def check_available(self):
        result = self._run_z13ctl(["z13ctl", "status"], timeout=5)
        ok = bool(result and result.returncode == 0)
        # Keep the stdout so callers can read the live profile without paying
        # for a second z13ctl invocation on every poll.
        self._last_status_text = result.stdout if ok else ""
        return ok

    def refresh_availability(self):
        self.available = self.check_available()
        if self.available:
            self.current_profile = self._read_current_profile(self._last_status_text)
        return self.available

    def _notify_unavailable(self, action):
        self.notifier.notify(
            "Hardware Control Unavailable",
            f"{action} requires a supported device control backend.",
            "warning",
            4000,
        )
        return False

    def _run_z13ctl(self, args, timeout=10):
        last_result = None
        for cmd in (args, ["sudo", "-n"] + args):
            try:
                result = subprocess.run(
                    cmd,
                    capture_output=True,
                    text=True,
                    timeout=timeout,
                )
            except Exception:
                continue
            last_result = result
            if result.returncode == 0:
                return result
        return last_result

    def _result_error(self, result):
        if result is None:
            return "Unable to execute z13ctl"
        detail = result.stderr.strip() or result.stdout.strip() or "Unknown error"
        lowered = detail.lower()
        if (
            "permission" in lowered
            or "password is required" in lowered
            or "not permitted" in lowered
        ):
            detail = (
                f"{detail}\n"
                "Log out and back in if the installer just added your account to the 'users' group."
            )
        return detail

    @staticmethod
    def _parse_profile(status_text):
        """Pull the live profile name out of z13ctl status output."""
        for line in (status_text or "").splitlines():
            low = line.lower()
            if "profile" in low and ":" in line:
                return line.split(":", 1)[1].strip().lower()
        return None

    def _read_current_profile(self, status_text=None):
        # Live value first (3-tier: quiet/balanced/performance, or custom once a
        # TDP override is active). Callers that already ran z13ctl status hand
        # their stdout in — including an empty one when the call failed, which
        # is why only status_text=None triggers a fresh call here.
        live = self._parse_profile(status_text)
        if live is None and status_text is None:
            try:
                result = self._run_z13ctl(["z13ctl", "status"], timeout=5)
                if result and result.returncode == 0:
                    live = self._parse_profile(result.stdout)
            except Exception:
                pass

        # The saved tray profile preserves 7-tier names like gaming/maximum, but
        # only while it still agrees with the live one — power-profiles-daemon,
        # asusd or a plug/unplug can move the platform profile behind our back.
        cached = None
        try:
            if _PROFILE_CACHE_FILE.exists():
                val = _PROFILE_CACHE_FILE.read_text().strip()
                if val in POWER_PROFILES:
                    cached = val
        except Exception:
            pass

        if cached is not None:
            if live is None:
                return cached
            # Anything that is not a firmware profile (z13ctl reports "custom"
            # after our own tdp --set) is still our tray profile.
            if live not in ("quiet", "balanced", "performance"):
                return cached
            if POWER_PROFILES[cached]["z13ctl_profile"] == live:
                return cached

        return live or "balanced"

    @staticmethod
    def _read_sysfs(path):
        try:
            return path.read_text().strip()
        except OSError:
            return ""

    @classmethod
    def _read_hwmon_die_temp(cls, hwmon, labels):
        """Return the labelled die temperature (°C) of one hwmon device."""
        unlabelled = None
        for temp_input in sorted(hwmon.glob("temp*_input")):
            raw_value = cls._read_sysfs(temp_input)
            if not raw_value.lstrip("-").isdigit():
                continue
            temp_value = int(raw_value) / 1000.0
            label = cls._read_sysfs(
                temp_input.with_name(temp_input.name.replace("_input", "_label"))
            ).lower()
            if label:
                if label in labels:
                    return temp_value
            elif unlabelled is None:
                unlabelled = temp_value
        return unlabelled

    def _read_hwmon_apu_temp(self):
        """APU temperature from the AMD die sensors, or None when absent.

        k10temp registers a hwmon device and no thermal zone, so the
        /sys/class/thermal scan below can only ever see ACPI chassis zones.
        """
        devices = {}
        try:
            for hwmon in sorted(Path("/sys/class/hwmon").glob("hwmon*")):
                name = self._read_sysfs(hwmon / "name").lower()
                if name and name not in devices:
                    devices[name] = hwmon
        except Exception:
            return None

        for driver, labels in (
            ("k10temp", ("tctl", "tdie")),
            ("zenpower", ("tctl", "tdie")),
            ("amdgpu", ("edge",)),
        ):
            hwmon = devices.get(driver)
            if hwmon is None:
                continue
            temp_value = self._read_hwmon_die_temp(hwmon, labels)
            if temp_value is not None:
                return f"{int(round(temp_value))}°C"
        return None

    def _read_apu_temp(self):
        hwmon_temp = self._read_hwmon_apu_temp()
        if hwmon_temp is not None:
            return hwmon_temp

        temps = []

        try:
            for zone in Path("/sys/class/thermal").glob("thermal_zone*"):
                temp_file = zone / "temp"
                if not temp_file.exists():
                    continue

                raw_value = temp_file.read_text().strip()
                if not raw_value or not raw_value.lstrip("-").isdigit():
                    continue

                temp_value = float(int(raw_value))
                if abs(temp_value) > 1000:
                    temp_value /= 1000.0

                zone_label = ""
                zone_type = zone / "type"
                if zone_type.exists():
                    zone_label = zone_type.read_text().strip().lower()

                temps.append((zone_label, temp_value))
        except Exception:
            pass

        for preferred in ("apu", "cpu", "k10temp", "package", "soc"):
            for zone_label, temp_value in temps:
                if preferred in zone_label:
                    return f"{int(round(temp_value))}°C"

        if temps:
            return f"{int(round(max(value for _, value in temps)))}°C"

        return "--°C"

    def _read_fan_summary(self):
        # Group per hwmon device: several drivers expose inputs for the same
        # physical fans, so mixing them across devices is arbitrary. 0 RPM is a
        # valid reading (stopped fans), not a missing sensor.
        devices = []

        try:
            hwmons = sorted(Path("/sys/class/hwmon").glob("hwmon*"))
        except Exception:
            hwmons = []

        for hwmon in hwmons:
            readings = []
            for fan_input in sorted(hwmon.glob("fan*_input")):
                raw_value = self._read_sysfs(fan_input)
                if raw_value.isdigit():
                    readings.append(int(raw_value))
            if readings:
                devices.append(readings)

        if not devices:
            return "-- RPM"

        # Prefer the device reporting the most spinning fans; fall back to the
        # one with the most inputs when everything is stopped. sorted() above
        # keeps the tie-break stable across boots and module load order.
        spinning = [readings for readings in devices if any(v > 0 for v in readings)]
        if spinning:
            best = max(spinning, key=lambda readings: sum(1 for v in readings if v > 0))
        else:
            best = max(devices, key=len)

        return " / ".join(f"{value} RPM" for value in best[:2])

    def _fallback_status(self):
        return "\n".join([
            f"APU: {self._read_apu_temp()}",
            f"Fans: {self._read_fan_summary()}",
        ])

    def _load_auto_config(self):
        try:
            if _AUTO_CONFIG_FILE.exists():
                for line in _AUTO_CONFIG_FILE.read_text().splitlines():
                    line = line.strip()
                    if not line or line.startswith('#'):
                        continue
                    if '=' in line:
                        k, v = line.split('=', 1)
                        k, v = k.strip(), v.strip().strip('"').strip("'")
                        if k == 'AUTO_SWITCH':
                            self._auto_enabled = v in ('1', 'true', 'yes')
                        elif k == 'AC_PROFILE':
                            if v in POWER_PROFILES:
                                self._ac_profile = v
                        elif k == 'BATTERY_PROFILE':
                            if v in POWER_PROFILES:
                                self._battery_profile = v
        except Exception:
            pass

    def _save_auto_config(self):
        try:
            _AUTO_CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
            lines = [
                f'AUTO_SWITCH={"1" if self._auto_enabled else "0"}',
                f'AC_PROFILE={self._ac_profile}',
                f'BATTERY_PROFILE={self._battery_profile}',
            ]
            _AUTO_CONFIG_FILE.write_text('\n'.join(lines) + '\n')
        except Exception:
            pass

    def is_auto_enabled(self):
        return self._auto_enabled

    def get_ac_profile(self):
        return self._ac_profile

    def get_battery_profile(self):
        return self._battery_profile

    def set_auto(self, enabled):
        if not self.available:
            self._notify_unavailable("Auto power switching")
            return False
        self._auto_enabled = enabled
        self._save_auto_config()
        if enabled:
            self._last_plugged = None  # force immediate check
            self.check_auto_switch()
        status = "enabled" if enabled else "disabled"
        self.notifier.notify("Auto Power", f"Auto-switching {status}", "info", 2000)
        return True

    def check_auto_switch(self):
        """Check power source and switch profile automatically if enabled."""
        if not self._auto_enabled:
            return
        try:
            batt = self.get_battery_info()
            plugged = batt.get("plugged")
            if plugged is None:
                return
            if plugged == self._last_plugged:
                return
            self._last_plugged = plugged
            target = self._ac_profile if plugged else self._battery_profile
            self.set_profile(target)
        except Exception:
            pass  # don't let a sysfs read failure kill the caller

    def get_profile_details(self):
        """Return (spl, sppt, fppt) wattages parsed from z13ctl status."""
        try:
            result = self._run_z13ctl(["z13ctl", "status"], timeout=5)
            if result and result.returncode == 0:
                for line in result.stdout.splitlines():
                    if "tdp" in line.lower() and "pl1" in line.lower():
                        vals = [int(m) for m in re.findall(r'(\d+)W', line)]
                        if len(vals) >= 3:
                            return vals[0], vals[1], vals[2]
                        if len(vals) == 1:
                            return vals[0], vals[0], vals[0]
        except Exception:
            pass
        # Fallback: use the profile's configured TDP
        spec = POWER_PROFILES.get(self.current_profile, {})
        tdp = spec.get("tdp") or 40
        return tdp, tdp, tdp

    def set_profile(self, profile):
        if not self.available:
            return self._notify_unavailable("Profile changes")
        try:
            spec = POWER_PROFILES.get(profile)
            if spec:
                z13_profile = spec["z13ctl_profile"]
            else:
                # Accept raw z13ctl profile names (quiet/balanced/performance/custom)
                z13_profile = profile

            # Call z13ctl directly (daemon mode handles permissions)
            result = self._run_z13ctl(["z13ctl", "profile", "--set", z13_profile], timeout=30)
            if result and result.returncode == 0:
                self.current_profile = profile
                # Persist tray-level profile name (survives restarts)
                try:
                    _PROFILE_CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
                    _PROFILE_CACHE_FILE.write_text(profile + '\n')
                except Exception:
                    pass
                # Apply TDP override if specified (TDP requires elevated privileges)
                tdp_applied = True
                if spec and spec.get("tdp"):
                    tdp_val = spec["tdp"]
                    tdp_cmd = ["z13ctl", "tdp", "--set", str(tdp_val)]
                    if tdp_val > 75:
                        tdp_cmd.append("--force")
                    tdp_result = self._run_z13ctl(tdp_cmd, timeout=10)
                    tdp_applied = bool(tdp_result and tdp_result.returncode == 0)
                    if not tdp_applied:
                        self.notifier.notify_error(
                            "TDP Override Failed", self._result_error(tdp_result)
                        )
                # The success toast quotes the profile's wattage, so only send it
                # once that wattage actually took. The profile switch itself did
                # succeed either way.
                if tdp_applied:
                    self.notifier.notify_profile_change(profile, result.stdout.strip())
                return True
            else:
                self.notifier.notify_error("Profile Change Failed", self._result_error(result))
                return False
        except Exception as e:
            self.notifier.notify_error("Profile Change Failed", str(e))
            return False

    def set_tdp(self, watts):
        if not self.available:
            return self._notify_unavailable("TDP overrides")
        try:
            result = self._run_z13ctl(["z13ctl", "tdp", "--set", str(watts)], timeout=10)
            if result and result.returncode == 0:
                self.notifier.notify("Power", f"TDP set to {watts}W", "success", 2000)
                return True
            else:
                self.notifier.notify_error("TDP Failed", self._result_error(result))
                return False
        except Exception as e:
            self.notifier.notify_error("Error", str(e))
            return False

    def set_fan_curve(self, curve):
        if not self.available:
            return self._notify_unavailable("Fan curve changes")
        try:
            result = self._run_z13ctl(["z13ctl", "fancurve", "--set", curve], timeout=10)
            if result and result.returncode == 0:
                self.notifier.notify("Fans", "Custom curve applied", "success", 2000)
                return True
            self.notifier.notify_error("Fan Curve Failed", self._result_error(result))
            return False
        except Exception as e:
            self.notifier.notify_error("Error", str(e))
            return False

    def set_charge_limit(self, limit):
        if not self.available:
            return self._notify_unavailable("Battery charge limits")
        try:
            result = self._run_z13ctl(["z13ctl", "batterylimit", "--set", str(limit)], timeout=10)
            if result and result.returncode == 0:
                self.notifier.notify(
                    "Battery", f"Charge limit set to {limit}%", "success", 2000
                )
                return True
            else:
                self.notifier.notify_error("Charge Limit Failed", self._result_error(result))
                return False
        except Exception as e:
            self.notifier.notify_error("Error", str(e))
            return False

    def get_status(self):
        try:
            if not self.available:
                return self._fallback_status()
            result = self._run_z13ctl(["z13ctl", "status"], timeout=10)
            return result.stdout.strip() if result and result.returncode == 0 else "Unknown"
        except Exception:
            return self._fallback_status()

    @staticmethod
    def _read_supply(sup, name):
        try:
            return (sup / name).read_text().strip()
        except OSError:
            return ""

    def _find_system_battery(self):
        """Return the machine's own battery, ignoring peripheral batteries.

        The first entry of /sys/class/power_supply is not the system battery.
        On the GZ302EA the detachable keyboard reports itself as a Battery with
        capacity=0 and status=Unknown, and readdir order places it before BAT0 --
        so taking the first hit shows a flat, always-plugged-in battery.
        Peripheral packs are identified by scope=Device and/or present=0.
        """
        candidates = []
        for sup in Path("/sys/class/power_supply").glob("*"):
            if self._read_supply(sup, "type") != "Battery":
                continue
            if self._read_supply(sup, "scope") == "Device":
                continue
            if self._read_supply(sup, "present") == "0":
                continue
            if not (sup / "capacity").exists():
                continue
            candidates.append(sup)

        if not candidates:
            return None
        # Prefer the conventional BAT* naming when several qualify.
        candidates.sort(key=lambda s: (not s.name.upper().startswith("BAT"), s.name))
        return candidates[0]

    def _on_external_power(self):
        """True when a mains supply reports online, None when none is present."""
        for sup in Path("/sys/class/power_supply").glob("*"):
            if self._read_supply(sup, "type") != "Mains":
                continue
            online = self._read_supply(sup, "online")
            if online:
                return online == "1"
        return None

    def get_battery_info(self):
        try:
            bat = self._find_system_battery()
            if bat is not None:
                status = self._read_supply(bat, "status").lower() or "unknown"
                pct = int(self._read_supply(bat, "capacity") or 0)

                # Prefer the mains supply for AC state: a battery status of
                # "Full"/"Unknown"/"Not charging" says nothing about the adapter.
                plugged = self._on_external_power()
                if plugged is None:
                    plugged = status not in ("discharging", "unknown")

                return {
                    "percent": pct,
                    "plugged": plugged,
                    "status": status,
                }
        except Exception:
            pass
        return {"percent": None, "plugged": None, "status": "unknown"}


# ==============================================================================
# Applied-fix verification
#
# `strix-halo-setup.sh --verify --json` is the installer's own tri-state view of
# what it applied, rendered machine-readably.  The dashboard reads it and does
# nothing else with it: this class never applies, repairs or elevates anything,
# so it needs no root and never prompts for a password.
#
# The one state that matters most here is "pending" — configured correctly but
# only live after a reboot.  The dashboard had no way to say that at all.
# ==============================================================================

# The installer's status strings, worst first.  This ordering is what puts the
# rows a user can act on at the top of the dashboard's list.
VERIFY_STATUS_ORDER = ("rejected", "pending", "unknown", "absent", "live", "na")

# Statuses worth showing a user.  "absent" means a fix was never applied (a
# deliberate choice on most machines) and "na" means the device does not have
# the hardware, so neither is a problem to report.
VERIFY_ATTENTION = ("rejected", "pending")

_VERIFY_ENV_OVERRIDE = "STRIX_HALO_SETUP"


class FixVerificationController(QObject):
    """Reads the installer's --verify --json state, off the GUI thread.

    Results come back through a signal, never through QTimer.singleShot():
    singleShot() is silently a no-op when called from a plain threading.Thread
    (no event dispatcher on that thread), which is exactly how an earlier
    version of the RGB worker lost its notifications.
    """

    # Carries the parsed snapshot dict, or None when it could not be produced.
    updated = pyqtSignal(object)

    # A verification run is cheap (~0.4 s on the flagship) but it shells out and
    # reads journalctl, so it is refreshed on demand rather than on the 3 s poll.
    MIN_REFRESH_INTERVAL = 300.0
    RUN_TIMEOUT = 45

    def __init__(self):
        super().__init__()
        self._snapshot = None
        self._lock = threading.Lock()
        self._running = False
        self._last_run = 0.0
        self.installer = self._find_installer()

    # ------------------------------------------------------------------
    # Discovery
    # ------------------------------------------------------------------
    @staticmethod
    def _candidate_paths():
        """Where the installer might be, best first.

        The dashboard is installed system-wide but the installer itself stays in
        whatever checkout the user ran it from, so there is no single answer —
        hence the env override, which is the only reliable one.
        """
        override = os.environ.get(_VERIFY_ENV_OVERRIDE, "").strip()
        if override:
            yield Path(override)

        try:
            # modules/power_controller.py -> src -> command-center -> repo root
            yield Path(__file__).resolve().parents[3] / "strix-halo-setup.sh"
        except IndexError:
            pass

        for path in (
            "/usr/local/share/strix-halo/strix-halo-setup.sh",
            "/opt/strix-halo-linux-setup/strix-halo-setup.sh",
        ):
            yield Path(path)

        try:
            home = Path.home()
        except Exception:
            home = None
        if home is not None:
            yield home / "strix-halo-linux-setup" / "strix-halo-setup.sh"
            yield home / ".local" / "share" / "strix-halo" / "strix-halo-setup.sh"

        found = shutil.which("strix-halo-setup.sh")
        if found:
            yield Path(found)

    @classmethod
    def _find_installer(cls):
        for candidate in cls._candidate_paths():
            try:
                if candidate.is_file() and os.access(candidate, os.R_OK):
                    return candidate
            except OSError:
                continue
        return None

    def available(self):
        return self.installer is not None

    def snapshot(self):
        return self._snapshot

    # ------------------------------------------------------------------
    # Running it
    # ------------------------------------------------------------------
    def refresh_async(self, force=False):
        """Kick a background run.  Returns True when one was actually started.

        Everything that could fail — no installer, one already in flight, too
        soon since the last — is answered with a quiet False.  A dashboard that
        cannot tell you about verification is not a dashboard that should stop
        working.
        """
        if self.installer is None:
            return False
        with self._lock:
            if self._running:
                return False
            if not force and self._last_run and \
                    (time.monotonic() - self._last_run) < self.MIN_REFRESH_INTERVAL:
                return False
            self._running = True
        threading.Thread(target=self._worker, daemon=True).start()
        return True

    def _worker(self):
        snapshot = None
        try:
            snapshot = self._run_verify()
        except Exception:
            snapshot = None
        finally:
            with self._lock:
                self._running = False
                self._last_run = time.monotonic()
        if snapshot is not None:
            self._snapshot = snapshot
        try:
            self.updated.emit(snapshot)
        except Exception:
            pass

    def _run_verify(self):
        env = dict(os.environ)
        # A fixture root describes someone else's machine; the dashboard must
        # always report on THIS one, whatever is exported in the session.
        env.pop("STRIX_HALO_FIXTURE_ROOT", None)
        try:
            result = subprocess.run(
                ["bash", str(self.installer), "--verify", "--json"],
                capture_output=True,
                text=True,
                timeout=self.RUN_TIMEOUT,
                cwd=str(self.installer.parent),
                env=env,
            )
        except Exception:
            return None
        # 0 = nothing rejected, 1 = something is rejected: both are real answers.
        # Anything else (2 = library missing, or an installer too old to know
        # --json and printing "Unknown option") is not.
        if result.returncode not in (0, 1):
            return None
        return self._parse(result.stdout)

    @staticmethod
    def _parse(text):
        """Parse and shape-check the document.  None on anything unexpected."""
        try:
            data = json.loads(text)
        except Exception:
            return None
        if not isinstance(data, dict):
            return None
        if data.get("schema") != "strix-halo-verify":
            return None
        checks = data.get("checks")
        summary = data.get("summary")
        if not isinstance(checks, list) or not isinstance(summary, dict):
            return None

        clean = []
        for check in checks:
            if not isinstance(check, dict):
                continue
            status = str(check.get("status") or "unknown")
            if status not in VERIFY_STATUS_ORDER:
                status = "unknown"
            clean.append({
                "id": str(check.get("id") or ""),
                "component": str(check.get("component") or ""),
                "label": str(check.get("label") or ""),
                "status": status,
                "detail": str(check.get("detail") or ""),
            })

        counts = {}
        for key in VERIFY_STATUS_ORDER:
            try:
                counts[key] = int(summary.get(key, 0))
            except (TypeError, ValueError):
                counts[key] = 0

        return {
            "device": str(data.get("device") or "unknown"),
            "kernel": str(data.get("kernel") or "unknown"),
            "checks": clean,
            "counts": counts,
        }

    # ------------------------------------------------------------------
    # Presentation helpers (pure; safe to call from the GUI thread)
    # ------------------------------------------------------------------
    @staticmethod
    def attention_rows(snapshot):
        """Rejected first, then pending — the rows a user can act on."""
        if not snapshot:
            return []
        rows = [c for c in snapshot["checks"] if c["status"] in VERIFY_ATTENTION]
        rows.sort(key=lambda c: VERIFY_STATUS_ORDER.index(c["status"]))
        return rows

    @staticmethod
    def headline(snapshot):
        """(text, tone) for the dashboard.  tone: bad | warn | ok | idle."""
        if not snapshot:
            return ("Applied fixes not checked", "idle")
        counts = snapshot["counts"]
        rejected, pending = counts["rejected"], counts["pending"]
        live = counts["live"]
        if rejected:
            noun = "fix is" if rejected == 1 else "fixes are"
            return (f"{rejected} {noun} being ignored by this kernel", "bad")
        if pending:
            noun = "fix needs" if pending == 1 else "fixes need"
            return (f"{pending} {noun} a reboot to take effect", "warn")
        if live:
            return (f"{live} applied fixes verified live", "ok")
        return ("No applied fixes to verify", "idle")

    @classmethod
    def summary_line(cls, snapshot):
        """One compact line for the tray menu and tooltip."""
        if not snapshot:
            return None
        counts = snapshot["counts"]
        parts = [f"{counts['live']} live"]
        if counts["pending"]:
            parts.append(f"{counts['pending']} awaiting reboot")
        if counts["rejected"]:
            parts.append(f"{counts['rejected']} rejected")
        return " · ".join(parts)
