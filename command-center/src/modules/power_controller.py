import re
import subprocess
from pathlib import Path

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
