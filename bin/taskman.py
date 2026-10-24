#!/usr/bin/python3
"""Local process snapshot and single-PID end for the Task Manager plugin.

Reads /proc, XDG autostart, and local GPU counters. NVIDIA utilization comes
from nvidia-smi only when the proprietary driver does not publish a sysfs
busy percent. Never kills by name, never signals a process group, and never
signals by PID alone. End task opens a pidfd, re-checks the start time, and
sends the signal through that descriptor so a recycled PID cannot be ended.
"""

from __future__ import annotations

import argparse
import csv
import errno
import io
import json
import os
import pwd
import re
import signal
import sys
import time
from pathlib import Path

PF_KTHREAD = 0x00200000
STALE_SECONDS = 10.0
INLINE_SAMPLE_SECONDS = 0.2
CMDLINE_LIMIT = 240
STATE_NAME = "sample.json"

PROTECTED_COMMS = frozenset({
    "systemd",
    "systemd-journald",
    "systemd-logind",
    "systemd-userdbd",
    "dbus-broker",
    "dbus-broker-launch",
    "dbus-daemon",
    "Hyprland",
    "hyprland",
    "quickshell",
})

STATE_LABELS = {
    "R": "Running",
    "S": "Sleeping",
    "D": "Disk sleep",
    "Z": "Zombie",
    "T": "Stopped",
    "t": "Tracing",
    "I": "Idle",
    "X": "Dead",
}

PARTITION_RE = re.compile(r"^(?:sd|vd|hd|xvd)[a-z]+\d+$|p\d+$")
SKIP_DISK_PREFIX = ("loop", "ram", "fd", "dm-", "zram", "sr")
CARD_RE = re.compile(r"^card\d+$")
GPU_LIMIT = 8
NVIDIA_SMI = "/usr/bin/nvidia-smi"
HYPRCTL = "/usr/bin/hyprctl"
NVIDIA_FIELDS = "index,name,utilization.gpu,memory.used,memory.total,temperature.gpu"
VENDOR_SHORT = {"1002": "AMD", "10de": "NVIDIA", "8086": "Intel"}
DRIVER_VENDOR = {"amdgpu": "amd", "nvidia": "nvidia", "i915": "intel", "xe": "intel"}


def fail(message: str) -> dict:
    return {"ok": False, "error": message}


def parse_cpu_times(line: str) -> tuple[int, int] | None:
    parts = line.split()
    if len(parts) < 5 or not parts[0].startswith("cpu"):
        return None
    try:
        nums = [int(part) for part in parts[1:]]
    except ValueError:
        return None
    if len(nums) < 4:
        return None
    idle = nums[3] + (nums[4] if len(nums) > 4 else 0)
    total = sum(nums[:8]) if len(nums) >= 8 else sum(nums)
    return total, idle


def host_cpu_percent(prev_total, prev_idle, total, idle):
    if prev_total is None or prev_idle is None:
        return None
    delta_total = total - prev_total
    delta_idle = idle - prev_idle
    if delta_total <= 0:
        return None
    percent = (1 - (delta_idle / delta_total)) * 100
    return round(max(0.0, min(100.0, percent)), 1)


def process_cpu_percent(prev_ticks, ticks, delta_total):
    if prev_ticks is None or delta_total is None or delta_total <= 0:
        return None
    if ticks < prev_ticks:
        return None
    return round(((ticks - prev_ticks) / delta_total) * 100, 1)


def byte_rate(prev, curr, elapsed):
    if prev is None or elapsed is None or elapsed <= 0 or elapsed > STALE_SECONDS:
        return None
    if curr < prev:
        return None
    return round((curr - prev) / elapsed, 1)


def parse_pid_stat(text: str) -> dict | None:
    raw = text.strip()
    left = raw.find("(")
    right = raw.rfind(")")
    if left < 1 or right < left:
        return None
    pid_text = raw[:left].strip()
    if not pid_text.isdigit():
        return None
    rest = raw[right + 2:].split()
    if len(rest) < 20:
        return None
    try:
        return {
            "pid": int(pid_text),
            "comm": raw[left + 1:right],
            "state": rest[0],
            "ppid": int(rest[1]),
            "flags": int(rest[6]),
            "utime": int(rest[11]),
            "stime": int(rest[12]),
            "starttime": int(rest[19]),
        }
    except (ValueError, IndexError):
        return None


def parse_status(text: str) -> dict:
    uid = None
    rss_bytes = 0
    for line in text.splitlines():
        if line.startswith("Uid:"):
            parts = line.split()
            if len(parts) >= 2 and parts[1].isdigit():
                uid = int(parts[1])
        elif line.startswith("VmRSS:"):
            parts = line.split()
            if len(parts) >= 2 and parts[1].isdigit():
                rss_bytes = int(parts[1]) * 1024
    return {"uid": uid, "rss_bytes": rss_bytes}


def parse_meminfo(text: str) -> dict:
    values = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        key, rest = line.split(":", 1)
        number = rest.strip().split()
        if number and number[0].isdigit():
            values[key] = int(number[0]) * 1024
    total = values.get("MemTotal", 0)
    available = values.get("MemAvailable", 0)
    swap_total = values.get("SwapTotal", 0)
    swap_free = values.get("SwapFree", 0)
    used = max(0, total - available) if total else 0
    swap_used = max(0, swap_total - swap_free)
    return {
        "memTotal": total,
        "memUsed": used,
        "memPercent": round(used / total * 100, 1) if total else 0.0,
        "swapTotal": swap_total,
        "swapUsed": swap_used,
        "swapPercent": round(swap_used / swap_total * 100, 1) if swap_total else 0.0,
    }


def parse_loadavg(text: str) -> list:
    parts = text.split()
    if len(parts) < 3:
        return [None, None, None]
    try:
        return [float(parts[0]), float(parts[1]), float(parts[2])]
    except ValueError:
        return [None, None, None]


def parse_uptime(text: str) -> float:
    try:
        return float(text.split()[0])
    except (ValueError, IndexError):
        return 0.0


def parse_net_dev(text: str) -> tuple[int, int]:
    rx = tx = 0
    for line in text.splitlines():
        if ":" not in line:
            continue
        iface, rest = line.split(":", 1)
        if iface.strip() == "lo":
            continue
        parts = rest.split()
        if len(parts) < 9:
            continue
        try:
            rx += int(parts[0])
            tx += int(parts[8])
        except ValueError:
            continue
    return rx, tx


def include_disk(name: str) -> bool:
    if name.startswith(SKIP_DISK_PREFIX) or PARTITION_RE.search(name):
        return False
    return True


def parse_diskstats(text: str) -> tuple[int, int]:
    read_bytes = write_bytes = 0
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 10:
            continue
        name = parts[2]
        if not include_disk(name):
            continue
        try:
            read_bytes += int(parts[5]) * 512
            write_bytes += int(parts[9]) * 512
        except ValueError:
            continue
    return read_bytes, write_bytes


def hex_id(value: str) -> str:
    raw = (value or "").strip().lower()
    if raw.startswith("0x"):
        raw = raw[2:]
    return raw


def clean_percent(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    if number != number or number in (float("inf"), float("-inf")):
        return None
    return round(max(0.0, min(100.0, number)), 1)


def clean_bytes(value):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return None
    return value


def clean_temp(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    if number != number or number < -40 or number > 150:
        return None
    return int(round(number))


def percent_used(used, total):
    if used is None or total is None or total <= 0:
        return None
    return round(max(0.0, min(100.0, (used / total) * 100)), 1)


def clean_gpu_rows(rows) -> list:
    if not isinstance(rows, list):
        return []
    cleaned = []
    for row in rows[:GPU_LIMIT]:
        if not isinstance(row, dict):
            continue
        used = clean_bytes(row.get("memUsed"))
        total = clean_bytes(row.get("memTotal"))
        cleaned.append({
            "name": str(row.get("name") or "GPU")[:80],
            "vendor": str(row.get("vendor") or "other")[:16],
            "shortName": str(row.get("shortName") or "GPU")[:16],
            "busyPercent": clean_percent(row.get("busyPercent")),
            "memUsed": used,
            "memTotal": total,
            "memPercent": percent_used(used, total),
            "tempC": clean_temp(row.get("tempC")),
        })
    return cleaned


def short_for_vendor(vendor_hex: str) -> str:
    return VENDOR_SHORT.get(hex_id(vendor_hex), "")


def gpu_title(vendor_hex: str, pci_name: str) -> str:
    brand = short_for_vendor(vendor_hex)
    label = (pci_name or "").strip()
    if brand and label and brand.lower() not in label.lower():
        return f"{brand} {label}"[:80]
    if label:
        return label[:80]
    if brand:
        return f"{brand} GPU"
    return "GPU"


def vendor_key(vendor_hex: str, driver: str) -> str:
    brand = short_for_vendor(vendor_hex)
    if brand:
        return brand.lower()
    return DRIVER_VENDOR.get(driver, "other")


def parse_optional_int(text: str):
    raw = (text or "").strip()
    if not raw.isdigit():
        return None
    return int(raw)


def parse_nvidia_number(text: str):
    raw = (text or "").strip().strip("[]")
    if not raw or raw.upper() in ("N/A", "NA"):
        return None
    try:
        number = float(raw)
    except ValueError:
        return None
    if number != number or number in (float("inf"), float("-inf")):
        return None
    return number


def parse_nvidia_query(text: str) -> list:
    rows = []
    for parts in csv.reader(io.StringIO(text or "")):
        if len(parts) < 6:
            continue
        name = parts[1].strip()
        busy = parse_nvidia_number(parts[2])
        used_mib = parse_nvidia_number(parts[3])
        total_mib = parse_nvidia_number(parts[4])
        temp = parse_nvidia_number(parts[5])
        if not name and busy is None and used_mib is None:
            continue
        used = None if used_mib is None else int(used_mib) * 1024 * 1024
        total = None if total_mib is None else int(total_mib) * 1024 * 1024
        rows.append({
            "name": name or "NVIDIA GPU",
            "vendor": "nvidia",
            "shortName": "NVIDIA",
            "busyPercent": None if busy is None else round(max(0.0, min(100.0, busy)), 1),
            "memUsed": used,
            "memTotal": total,
            "memPercent": percent_used(used, total),
            "tempC": None if temp is None else int(round(temp)),
        })
        if len(rows) >= GPU_LIMIT:
            break
    return rows


def lookup_pci_names(pairs, ids_text: str) -> dict:
    wanted = {(hex_id(vendor), hex_id(device)) for vendor, device in pairs}
    wanted.discard(("", ""))
    found = {}
    if not wanted or not ids_text:
        return found
    current = ""
    for line in ids_text.splitlines():
        if not line or line[0] == "#":
            continue
        if line[0] != "\t":
            parts = line.split()
            current = parts[0].lower() if parts else ""
            continue
        if line.startswith("\t\t"):
            continue
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and (current, parts[0].lower()) in wanted:
            found[(current, parts[0].lower())] = parts[1].strip()
            if len(found) == len(wanted):
                break
    return found


def is_nvidia_card(card: dict) -> bool:
    return hex_id(card.get("vendor", "")) == "10de" or card.get("driver") == "nvidia"


def card_to_gpu(card: dict, names: dict) -> dict | None:
    busy = card.get("busy")
    if isinstance(busy, bool) or not isinstance(busy, int) or busy < 0 or busy > 100:
        busy = None
    used = clean_bytes(card.get("memUsed"))
    total = clean_bytes(card.get("memTotal"))
    if busy is None and used is None and total is None:
        return None
    vendor = card.get("vendor") or ""
    key = (hex_id(vendor), hex_id(card.get("device") or ""))
    return {
        "name": gpu_title(vendor, names.get(key, "")),
        "vendor": vendor_key(vendor, card.get("driver") or ""),
        "shortName": short_for_vendor(vendor) or "GPU",
        "busyPercent": None if busy is None else float(busy),
        "memUsed": used,
        "memTotal": total,
        "tempC": card.get("tempC") if isinstance(card.get("tempC"), int) and not isinstance(card.get("tempC"), bool) else None,
    }


def assemble_gpus(cards, nvidia_rows, names) -> list:
    if not isinstance(cards, list):
        cards = []
    if not isinstance(nvidia_rows, list):
        nvidia_rows = []
    if not isinstance(names, dict):
        names = {}
    emitted = []
    nvidia_boot = False
    for card in cards:
        if not isinstance(card, dict):
            continue
        if is_nvidia_card(card):
            nvidia_boot = nvidia_boot or bool(card.get("boot"))
            if card.get("busy") is None and card.get("memUsed") is None:
                continue
        row = card_to_gpu(card, names)
        if not row:
            continue
        row["_boot"] = bool(card.get("boot"))
        emitted.append(row)
    if nvidia_rows and not any(row.get("vendor") == "nvidia" for row in emitted):
        usable = [row for row in nvidia_rows if isinstance(row, dict)][:GPU_LIMIT]
        for row in usable:
            copied = dict(row)
            copied["_boot"] = nvidia_boot and len(usable) == 1
            emitted.append(copied)
    emitted.sort(key=lambda row: (0 if row.get("_boot") else 1, str(row.get("name") or "")))
    for row in emitted:
        row.pop("_boot", None)
    return clean_gpu_rows(emitted)


def read_int_file(path: Path):
    return parse_optional_int(read_text(path))


def read_temp_c(hwmon: Path):
    if not hwmon.is_dir():
        return None
    try:
        children = sorted(p for p in hwmon.iterdir() if p.is_dir())
    except OSError:
        return None
    for child in children:
        milli = read_int_file(child / "temp1_input")
        if milli is None:
            continue
        return int(round(milli / 1000))
    return None


def driver_name(device: Path) -> str:
    try:
        return Path(os.readlink(device / "driver")).name
    except OSError:
        return ""


def read_sysfs_cards(drm_root: Path) -> list:
    cards = []
    try:
        names = sorted(os.listdir(drm_root))
    except OSError:
        return cards
    for name in names:
        if not CARD_RE.fullmatch(name):
            continue
        device = drm_root / name / "device"
        if not device.is_dir():
            continue
        busy = read_int_file(device / "gpu_busy_percent")
        if busy is not None and (busy < 0 or busy > 100):
            busy = None
        cards.append({
            "name": name,
            "vendor": read_text(device / "vendor").strip().lower(),
            "device": read_text(device / "device").strip().lower(),
            "driver": driver_name(device),
            "boot": read_text(device / "boot_vga").strip() == "1",
            "busy": busy,
            "memUsed": read_int_file(device / "mem_info_vram_used"),
            "memTotal": read_int_file(device / "mem_info_vram_total"),
            "tempC": read_temp_c(device / "hwmon"),
        })
        if len(cards) >= GPU_LIMIT:
            break
    return cards


def read_pci_ids(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def default_pci_ids() -> Path:
    for candidate in (Path("/usr/share/hwdata/pci.ids"), Path("/usr/share/misc/pci.ids")):
        if candidate.is_file():
            return candidate
    return Path("/usr/share/hwdata/pci.ids")


def default_nvidia_query() -> str:
    import subprocess
    if not os.path.isfile(NVIDIA_SMI) or not os.access(NVIDIA_SMI, os.X_OK):
        return ""
    try:
        completed = subprocess.run(
            [NVIDIA_SMI, "--query-gpu=" + NVIDIA_FIELDS, "--format=csv,noheader,nounits"],
            check=False,
            capture_output=True,
            text=True,
            timeout=2.0,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if completed.returncode != 0:
        return ""
    return completed.stdout or ""


def read_live_gpus(drm_root: Path, nvidia_runner, pci_ids: Path) -> list:
    """One sample of local GPUs. A missing or slow NVIDIA query must not hide
    an AMD or Intel card that already published its own counters."""
    cards = read_sysfs_cards(drm_root)
    nvidia_text = ""
    if any(is_nvidia_card(card) and card.get("busy") is None for card in cards):
        try:
            nvidia_text = nvidia_runner() or ""
        except (OSError, TimeoutError):
            nvidia_text = ""
    pairs = [
        (card["vendor"], card["device"])
        for card in cards
        if not is_nvidia_card(card) and card.get("vendor") and card.get("device")
    ]
    names = lookup_pci_names(pairs, read_pci_ids(pci_ids) if pairs else "")
    return assemble_gpus(cards, parse_nvidia_query(nvidia_text), names)


def decode_cmdline(raw: bytes) -> str:
    parts = [part.decode("utf-8", "replace") for part in raw.split(b"\0") if part]
    return " ".join(parts)[:CMDLINE_LIMIT]


def display_name(comm: str, cmdline: str) -> str:
    if cmdline:
        argv0 = cmdline.split(" ", 1)[0]
        base = argv0.rsplit("/", 1)[-1]
        if base and (not comm or base.startswith(comm) or comm.startswith(base[:15])):
            return base[:80]
    return comm or "?"


def parse_desktop(text: str, source: str, file_name: str) -> dict | None:
    in_entry = False
    fields = {}
    saw_entry = False
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            in_entry = line == "[Desktop Entry]"
            saw_entry = saw_entry or in_entry
            continue
        if in_entry and "=" in line:
            key, value = line.split("=", 1)
            fields[key.strip()] = value.strip()
    if not saw_entry:
        return None
    hidden = fields.get("Hidden", "").lower() == "true"
    gnome = fields.get("X-GNOME-Autostart-enabled", "true").lower()
    return {
        "name": fields.get("Name", ""),
        "exec": fields.get("Exec", ""),
        "enabled": (not hidden) and gnome not in ("false", "0"),
        "controls_enabled": "Hidden" in fields or "X-GNOME-Autostart-enabled" in fields,
        "source": source,
        "file": file_name,
    }


def merge_autostart(system_entries: list, user_entries: list) -> list:
    merged = {entry["file"]: dict(entry) for entry in system_entries}
    for user in user_entries:
        current = merged.get(user["file"])
        if current is None:
            row = dict(user)
            if not row["name"]:
                row["name"] = row["file"]
            merged[user["file"]] = row
            continue
        if user["name"]:
            current["name"] = user["name"]
        if user["exec"]:
            current["exec"] = user["exec"]
        if user["controls_enabled"]:
            current["enabled"] = user["enabled"]
        current["source"] = "user"
    rows = []
    for entry in merged.values():
        rows.append({
            "name": entry["name"] or entry["file"],
            "exec": entry["exec"],
            "enabled": bool(entry["enabled"]),
            "source": entry["source"],
            "file": entry["file"],
        })
    rows.sort(key=lambda row: row["name"].lower())
    return rows


def protection_reason(pid: int, comm: str, state: str, flags: int, uid, my_uid: int) -> str:
    if pid <= 1:
        return "System init cannot be ended."
    if flags & PF_KTHREAD:
        return "Kernel thread."
    if state == "Z":
        return "Zombie — the parent has to reap it."
    if comm in PROTECTED_COMMS:
        return "Session-critical process."
    if uid is None:
        return "Owner unknown."
    if uid != my_uid:
        return "Owned by another user. This task manager will not escalate."
    return ""


def window_titles(clients) -> dict:
    titles = {}
    if not isinstance(clients, list):
        return titles
    for client in clients:
        if not isinstance(client, dict):
            continue
        pid = client.get("pid")
        if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 1:
            continue
        title = client.get("title") or client.get("class") or ""
        titles[pid] = str(title)[:160]
    return titles


def user_name(uid, cache: dict) -> str:
    if uid is None:
        return "?"
    if uid in cache:
        return cache[uid]
    try:
        cache[uid] = pwd.getpwuid(uid).pw_name
    except KeyError:
        cache[uid] = str(uid)
    return cache[uid]


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def read_bytes(path: Path) -> bytes:
    try:
        return path.read_bytes()
    except OSError:
        return b""


def default_state_path() -> Path:
    override = os.environ.get("TASKMAN_STATE_PATH", "").strip()
    if override:
        return Path(override)
    return Path.home() / ".local" / "state" / "omarchy" / "task-manager" / STATE_NAME


def load_state(path: Path) -> dict:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return payload if isinstance(payload, dict) else {}


def save_state(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
    os.chmod(path, 0o600)


def sample_host(proc_root: Path) -> dict:
    stat_text = read_text(proc_root / "stat")
    aggregate = None
    cores = []
    for line in stat_text.splitlines():
        if line.startswith("cpu "):
            aggregate = parse_cpu_times(line)
        elif line.startswith("cpu"):
            parsed = parse_cpu_times(line)
            if parsed:
                cores.append(parsed)
    if aggregate is None:
        aggregate = (0, 0)
    disk = parse_diskstats(read_text(proc_root / "diskstats"))
    net = parse_net_dev(read_text(proc_root / "net" / "dev"))
    return {
        "total": aggregate[0],
        "idle": aggregate[1],
        "cores": cores,
        "diskRead": disk[0],
        "diskWrite": disk[1],
        "netRx": net[0],
        "netTx": net[1],
        "mem": parse_meminfo(read_text(proc_root / "meminfo")),
        "load": parse_loadavg(read_text(proc_root / "loadavg")),
        "uptime": parse_uptime(read_text(proc_root / "uptime")),
    }


def sample_processes(proc_root: Path) -> dict:
    found = {}
    try:
        names = os.listdir(proc_root)
    except OSError:
        return found
    for name in names:
        if not name.isdigit():
            continue
        parsed = parse_pid_stat(read_text(proc_root / name / "stat"))
        if not parsed or parsed["pid"] != int(name):
            continue
        if parsed["flags"] & PF_KTHREAD:
            continue
        status = parse_status(read_text(proc_root / name / "status"))
        cmdline = decode_cmdline(read_bytes(proc_root / name / "cmdline"))
        gpu = read_process_gpu(proc_root / name)
        found[parsed["pid"]] = {
            "stat": parsed,
            "status": status,
            "cmdline": cmdline,
            "gpuNs": gpu["engines"],
            "gpuVram": gpu["vram"],
            "gpuDrivers": gpu["drivers"],
        }
    return found


def core_percents(prev_cores, cores) -> list:
    percents = []
    for index, (total, idle) in enumerate(cores):
        prev = prev_cores[index] if index < len(prev_cores) else None
        if not prev:
            percents.append(None)
            continue
        percents.append(host_cpu_percent(prev.get("total"), prev.get("idle"), total, idle))
    return percents


def build_host(prev: dict, sample: dict, elapsed) -> dict:
    prev_cores = prev.get("cores") if isinstance(prev.get("cores"), list) else []
    mem = sample["mem"]
    stale = elapsed is None or elapsed <= 0 or elapsed > STALE_SECONDS
    return {
        "cpuPercent": None if stale else host_cpu_percent(prev.get("total"), prev.get("idle"), sample["total"], sample["idle"]),
        "cpuCount": len(sample["cores"]),
        "cores": [] if stale else core_percents(prev_cores, sample["cores"]),
        "memUsed": mem["memUsed"],
        "memTotal": mem["memTotal"],
        "memPercent": mem["memPercent"],
        "swapUsed": mem["swapUsed"],
        "swapTotal": mem["swapTotal"],
        "swapPercent": mem["swapPercent"],
        "load": sample["load"],
        "uptimeSec": round(sample["uptime"], 1),
        "diskReadBps": None if stale else byte_rate(prev.get("diskRead"), sample["diskRead"], elapsed),
        "diskWriteBps": None if stale else byte_rate(prev.get("diskWrite"), sample["diskWrite"], elapsed),
        "netRxBps": None if stale else byte_rate(prev.get("netRx"), sample["netRx"], elapsed),
        "netTxBps": None if stale else byte_rate(prev.get("netTx"), sample["netTx"], elapsed),
    }


GPU_MEM_SHOW = 1024 * 1024
FDINFO_READ_CAP = 32
DRIVER_LABEL = {"amdgpu": "AMD", "i915": "Intel", "xe": "Intel", "nvidia": "NVIDIA"}
SIZE_UNITS = {
    "b": 1,
    "kib": 1024,
    "kb": 1024,
    "mib": 1024 ** 2,
    "mb": 1024 ** 2,
    "gib": 1024 ** 3,
    "gb": 1024 ** 3,
}


def parse_size_token(text: str):
    parts = (text or "").split()
    if not parts:
        return None
    try:
        number = float(parts[0])
    except ValueError:
        return None
    if number < 0 or number != number:
        return None
    unit = parts[1].lower() if len(parts) > 1 else "b"
    return int(number * SIZE_UNITS.get(unit, 1))


def parse_fdinfo_gpu(text: str) -> dict | None:
    """One DRM fdinfo record. Card nodes carry engine time; render nodes carry VRAM.
    The same client-id must be merged, not added, or one process is counted twice."""
    driver = client = pdev = ""
    vram = None
    engines = 0
    saw_engine = False
    saw_drm = False
    for line in text.splitlines():
        if ":" not in line:
            continue
        key, rest = line.split(":", 1)
        key = key.strip()
        rest = rest.strip()
        if key == "drm-driver":
            driver = rest
            saw_drm = True
        elif key == "drm-client-id":
            client = rest
        elif key == "drm-pdev":
            pdev = rest
        elif key == "drm-resident-vram":
            vram = parse_size_token(rest)
        elif key == "drm-memory-vram" and vram is None:
            vram = parse_size_token(rest)
        elif key.startswith("drm-engine-") and key.count("-") == 2:
            ns = rest.split()
            if ns and ns[0].isdigit():
                engines += int(ns[0])
                saw_engine = True
    if not saw_drm:
        return None
    return {
        "key": (driver, pdev, client or f"anon-{id(text)}"),
        "driver": driver,
        "vram": 0 if vram is None else vram,
        "engines": engines if saw_engine else None,
    }


def accumulate_fdinfo(records: list) -> dict:
    merged = {}
    for record in records:
        if not isinstance(record, dict) or "key" not in record:
            continue
        current = merged.get(record["key"])
        if current is None:
            merged[record["key"]] = {
                "driver": record.get("driver") or "",
                "vram": record.get("vram") or 0,
                "engines": record.get("engines"),
            }
            continue
        if (record.get("vram") or 0) > current["vram"]:
            current["vram"] = record.get("vram") or 0
        if record.get("engines") is not None:
            current["engines"] = max(current["engines"] or 0, record["engines"])
    engines = None
    if any(row["engines"] is not None for row in merged.values()):
        engines = sum(row["engines"] or 0 for row in merged.values())
    drivers = sorted({row["driver"] for row in merged.values() if row["driver"]})
    return {
        "vram": sum(row["vram"] for row in merged.values()),
        "engines": engines,
        "drivers": drivers,
    }


def gpu_engine_percent(prev_ns, curr_ns, elapsed):
    if isinstance(prev_ns, bool) or isinstance(curr_ns, bool):
        return None
    if not isinstance(prev_ns, int) or not isinstance(curr_ns, int):
        return None
    if elapsed is None or elapsed <= 0 or elapsed > STALE_SECONDS or curr_ns < prev_ns:
        return None
    percent = ((curr_ns - prev_ns) / (elapsed * 1_000_000_000)) * 100
    return round(max(0.0, min(100.0, percent)), 1)


def driver_label(drivers) -> str:
    labels = []
    for driver in drivers or []:
        label = DRIVER_LABEL.get(driver, "")
        if label and label not in labels:
            labels.append(label)
    return "+".join(labels)


def short_bytes(value: int) -> str:
    if value >= 1024 ** 3:
        scaled = value / (1024 ** 3)
        text = f"{scaled:.1f}" if scaled < 10 else f"{scaled:.0f}"
        return text + " GB"
    if value >= 1024 ** 2:
        return f"{value / (1024 ** 2):.0f} MB"
    if value >= 1024:
        return f"{value / 1024:.0f} KB"
    return f"{value} B"


def note_piece(label: str, mem: int) -> str:
    if mem <= 0:
        return ""
    return f"{label or 'GPU'} {short_bytes(mem)}"


def read_process_gpu(proc_dir: Path) -> dict:
    empty = {"vram": 0, "engines": None, "drivers": []}
    fd_dir = proc_dir / "fd"
    try:
        names = os.listdir(fd_dir)
    except OSError:
        return empty
    records = []
    for name in names:
        if len(records) >= FDINFO_READ_CAP or not name.isdigit():
            continue
        try:
            target = os.readlink(fd_dir / name)
        except OSError:
            continue
        if "/dev/dri/" not in target:
            continue
        parsed = parse_fdinfo_gpu(read_text(proc_dir / "fdinfo" / name))
        if parsed:
            records.append(parsed)
    if not records:
        return empty
    return accumulate_fdinfo(records)


def parse_nvidia_pmon(text: str) -> dict:
    """pid -> {sm, mem}. sm stays None when the driver prints '-' — memory still counts."""
    found = {}
    for line in (text or "").splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 10 or not parts[1].isdigit():
            continue
        pid = int(parts[1])
        sm = parse_nvidia_number(parts[3])
        fb = parse_nvidia_number(parts[9])
        row = {
            "sm": None if sm is None else round(max(0.0, min(100.0, sm)), 1),
            "mem": None if fb is None else int(fb) * 1024 * 1024,
        }
        current = found.get(pid)
        if current and current.get("sm") is not None and row["sm"] is None:
            continue
        found[pid] = row
    return found


def default_nvidia_pmon() -> str:
    import subprocess
    if not os.path.isfile(NVIDIA_SMI) or not os.access(NVIDIA_SMI, os.X_OK):
        return ""
    try:
        completed = subprocess.run(
            [NVIDIA_SMI, "pmon", "-c", "1", "-s", "um"],
            check=False,
            capture_output=True,
            text=True,
            timeout=2.0,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if completed.returncode != 0:
        return ""
    return completed.stdout or ""


def process_gpu_fields(item: dict, previous: dict, elapsed, nvidia: dict) -> dict:
    parsed = item.get("stat") or {}
    same = previous.get("start") == parsed.get("starttime")
    prev_ns = previous.get("gpuNs") if same else None
    amd_pct = gpu_engine_percent(prev_ns, item.get("gpuNs"), elapsed)
    nv = nvidia.get(parsed.get("pid")) if isinstance(nvidia, dict) else None
    if not isinstance(nv, dict):
        nv = {}
    nv_pct = nv.get("sm")
    if isinstance(nv_pct, bool) or not isinstance(nv_pct, (int, float)):
        nv_pct = None
    percents = [value for value in (amd_pct, nv_pct) if value is not None]
    vram = item.get("gpuVram") if isinstance(item.get("gpuVram"), int) and not isinstance(item.get("gpuVram"), bool) else 0
    nv_mem = nv.get("mem") if isinstance(nv.get("mem"), int) and not isinstance(nv.get("mem"), bool) else 0
    notes = []
    if vram > 0:
        notes.append(note_piece(driver_label(item.get("gpuDrivers")) or "GPU", vram))
    if nv_mem > 0:
        notes.append(note_piece("NVIDIA", nv_mem))
    return {
        "gpu": max(percents) if percents else None,
        "gpuKnown": bool(percents),
        "gpuMemBytes": max(0, vram) + max(0, nv_mem),
        "gpuNote": " | ".join(notes)[:160],
    }


def build_processes(found: dict, prev_procs: dict, delta_total, titles: dict, my_uid: int, elapsed=None, nvidia_procs=None) -> list:
    names = {}
    rows = []
    for pid, item in found.items():
        parsed = item["stat"]
        status = item["status"]
        reason = protection_reason(pid, parsed["comm"], parsed["state"], parsed["flags"], status["uid"], my_uid)
        previous = prev_procs.get(str(pid)) or prev_procs.get(pid) or {}
        prev_ticks = previous.get("ticks") if previous.get("start") == parsed["starttime"] else None
        title = titles.get(pid, "")
        gpu = process_gpu_fields(item, previous if previous.get("start") == parsed["starttime"] else {}, elapsed, nvidia_procs or {})
        rows.append({
            "pid": pid,
            "ppid": parsed["ppid"],
            "name": display_name(parsed["comm"], item["cmdline"]),
            "user": user_name(status["uid"], names),
            "cpu": process_cpu_percent(prev_ticks, parsed["utime"] + parsed["stime"], delta_total),
            "memBytes": status["rss_bytes"],
            "gpu": gpu["gpu"],
            "gpuKnown": gpu["gpuKnown"],
            "gpuMemBytes": gpu["gpuMemBytes"],
            "gpuNote": gpu["gpuNote"],
            "state": parsed["state"],
            "status": STATE_LABELS.get(parsed["state"], parsed["state"] or "Unknown"),
            "kind": "app" if pid in titles else "background",
            "windowTitle": title,
            "protected": bool(reason),
            "protectReason": reason,
            "starttime": parsed["starttime"],
            "cmdline": item["cmdline"],
        })
    return rows


def state_from_sample(sample: dict, procs: dict, detail: bool, mono: float) -> dict:
    stored = {}
    for pid, item in procs.items():
        parsed = item["stat"]
        entry = {"ticks": parsed["utime"] + parsed["stime"], "start": parsed["starttime"]}
        gpu_ns = item.get("gpuNs")
        if isinstance(gpu_ns, int) and not isinstance(gpu_ns, bool) and gpu_ns >= 0:
            entry["gpuNs"] = gpu_ns
        stored[str(pid)] = entry
    return {
        "mono": mono,
        "total": sample["total"],
        "idle": sample["idle"],
        "cores": [{"total": total, "idle": idle} for total, idle in sample["cores"]],
        "diskRead": sample["diskRead"],
        "diskWrite": sample["diskWrite"],
        "netRx": sample["netRx"],
        "netTx": sample["netTx"],
        "procs": stored if detail else {},
        "detail": detail,
    }


def elapsed_since(prev: dict, mono: float):
    previous = prev.get("mono")
    if not isinstance(previous, (int, float)) or isinstance(previous, bool):
        return None
    return mono - float(previous)


def collect_snapshot(proc_root: Path, state_path: Path, detail: bool, titles: dict, autostart: list,
                     my_uid: int, mono: float, sleeper, gpus=None, nvidia_procs=None) -> dict:
    """Compare this sample with the previous one. Opening the process list
    without a process baseline takes a short second sample in-process so the
    first view is not stuck on an empty CPU column."""
    prev = load_state(state_path)
    sample = sample_host(proc_root)
    now = mono
    procs = {}
    compared = prev
    elapsed = elapsed_since(prev, now)
    if detail:
        procs = sample_processes(proc_root)
        have_baseline = bool(prev.get("detail")) and isinstance(prev.get("procs"), dict)
        if not have_baseline:
            sleeper(INLINE_SAMPLE_SECONDS)
            compared = state_from_sample(sample, procs, True, mono)
            now = mono + INLINE_SAMPLE_SECONDS
            sample = sample_host(proc_root)
            procs = sample_processes(proc_root)
            elapsed = INLINE_SAMPLE_SECONDS
    host = build_host(compared, sample, elapsed)
    host["gpus"] = clean_gpu_rows(gpus)
    delta_total = None
    if detail and elapsed is not None and 0 < elapsed <= STALE_SECONDS:
        delta_total = sample["total"] - int(compared.get("total") or 0)
    prev_procs = compared.get("procs") if isinstance(compared.get("procs"), dict) else {}
    processes = build_processes(procs, prev_procs, delta_total, titles, my_uid, elapsed, nvidia_procs) if detail else []
    for row in processes:
        row["memPercent"] = round(row["memBytes"] / host["memTotal"] * 100, 1) if host["memTotal"] else 0.0
    save_state(state_path, state_from_sample(sample, procs, detail, now))
    return {
        "ok": True,
        "detail": detail,
        "host": host,
        "processes": processes,
        "startup": autostart if detail else [],
    }


def read_autostart(user_dir: Path, system_dir: Path) -> list:
    def load_dir(directory: Path, source: str) -> list:
        rows = []
        if not directory.is_dir():
            return rows
        for path in sorted(directory.glob("*.desktop")):
            if path.is_symlink():
                continue
            parsed = parse_desktop(read_text(path), source, path.name)
            if parsed:
                rows.append(parsed)
        return rows

    return merge_autostart(load_dir(system_dir, "system"), load_dir(user_dir, "user"))


def read_windows(runner) -> dict:
    try:
        raw = runner()
    except (OSError, TimeoutError):
        return {}
    try:
        payload = json.loads(raw or "")
    except json.JSONDecodeError:
        return {}
    return window_titles(payload)


def evaluate_end(pid, expected_start, signal_name: str, live: dict | None, my_uid: int) -> str | None:
    if signal_name not in ("TERM", "KILL"):
        return "Signal must be TERM or KILL."
    if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 1:
        return "PID must be an integer greater than 1."
    if isinstance(expected_start, bool) or not isinstance(expected_start, int) or expected_start < 0:
        return "Start time is required so a recycled PID cannot be ended."
    if live is None:
        return "That process is already gone."
    if live["starttime"] != expected_start:
        return "PID was reused. Refresh and try again."
    return protection_reason(pid, live["comm"], live["state"], live["flags"], live["uid"], my_uid) or None


class IdentityChanged(Exception):
    """The pinned task is not the one the user selected."""


def signal_pinned(pid: int, expected_start: int, sig: int, proc_root: Path) -> None:
    """Signal the task pinned by a pidfd, or raise if that task is gone.

    Signaling by PID alone can hit a recycled PID. Open the descriptor first,
    re-read the start time, and send the signal through the descriptor. A
    reuse after the open makes the signal fail instead of hitting the new task.
    """
    fd = os.pidfd_open(pid)
    try:
        live = live_process(proc_root, pid)
        if live is None or live["starttime"] != expected_start:
            raise IdentityChanged()
        signal.pidfd_send_signal(fd, sig)
    finally:
        os.close(fd)


def perform_end(pid, expected_start, signal_name: str, live: dict | None, my_uid: int, killer=None, proc_root: Path | None = None) -> dict:
    reason = evaluate_end(pid, expected_start, signal_name, live, my_uid)
    if reason:
        return fail(reason)
    sig = signal.SIGTERM if signal_name == "TERM" else signal.SIGKILL
    try:
        if killer is not None:
            killer(pid, sig)
        elif proc_root is not None:
            signal_pinned(pid, expected_start, sig, proc_root)
        else:
            return fail("No pinned signal path.")
    except IdentityChanged:
        return fail("PID was reused. Refresh and try again.")
    except ProcessLookupError:
        return fail("That process is already gone.")
    except PermissionError:
        return fail("Not permitted to end that process.")
    except OSError as exc:
        if getattr(exc, "errno", None) == errno.ESRCH:
            return fail("That process is already gone.")
        return fail("Not permitted to end that process.")
    return {"ok": True, "pid": pid, "signal": signal_name}


def perform_end_batch(targets: list[dict], signal_name: str, proc_root: Path, my_uid: int, killer=None) -> dict:
    if signal_name not in ("TERM", "KILL"):
        return fail("Signal must be TERM or KILL.")
    if not isinstance(targets, list) or not targets:
        return fail("targets must be a non-empty list.")
    ended = []
    errors = []
    for target in targets:
        if not isinstance(target, dict):
            continue
        pid = target.get("pid")
        starttime = target.get("starttime")
        if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 1:
            errors.append(f"PID {pid}: must be an integer greater than 1.")
            continue
        if isinstance(starttime, bool) or not isinstance(starttime, int) or starttime < 0:
            errors.append(f"PID {pid}: start time is required.")
            continue
        live = live_process(proc_root, pid)
        pinned_root = None if killer is not None else proc_root
        res = perform_end(pid, starttime, signal_name, live, my_uid, killer, pinned_root)
        if res.get("ok"):
            ended.append(pid)
        else:
            errors.append(f"PID {pid}: {res.get('error')}")
    if ended:
        return {"ok": True, "ended": ended, "count": len(ended), "signal": signal_name}
    return fail("; ".join(errors) if errors else "No processes could be ended.")


def live_process(proc_root: Path, pid: int) -> dict | None:
    if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0:
        return None
    parsed = parse_pid_stat(read_text(proc_root / str(pid) / "stat"))
    if not parsed or parsed["pid"] != pid:
        return None
    status = parse_status(read_text(proc_root / str(pid) / "status"))
    return {
        "comm": parsed["comm"],
        "state": parsed["state"],
        "flags": parsed["flags"],
        "uid": status["uid"],
        "starttime": parsed["starttime"],
    }


def emit(payload: dict) -> int:
    json.dump(payload, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0 if payload.get("ok") is True else 1


def default_window_runner():
    import subprocess
    if not os.path.isfile(HYPRCTL) or not os.access(HYPRCTL, os.X_OK):
        return ""
    completed = subprocess.run(
        [HYPRCTL, "clients", "-j"],
        check=False,
        capture_output=True,
        text=True,
        timeout=1.0,
    )
    return completed.stdout


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Task Manager local snapshot and single-PID end.")
    parser.add_argument("command", choices=("snapshot", "end"))
    parser.add_argument("--detail", action="store_true")
    parser.add_argument("--pid", type=int)
    parser.add_argument("--starttime", type=int)
    parser.add_argument("--targets", default="")
    parser.add_argument("--signal", choices=("TERM", "KILL"), default="TERM")
    parser.add_argument("--state", default="")
    parser.add_argument("--proc-root", default="/proc")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    proc_root = Path(args.proc_root)
    state_path = Path(args.state) if args.state else default_state_path()
    if args.command == "snapshot":
        titles = read_windows(default_window_runner) if args.detail and str(proc_root) == "/proc" else {}
        autostart = []
        if args.detail and str(proc_root) == "/proc":
            autostart = read_autostart(
                Path.home() / ".config" / "autostart",
                Path("/etc/xdg/autostart"),
            )
        gpus = []
        if str(proc_root) == "/proc":
            try:
                gpus = read_live_gpus(Path("/sys/class/drm"), default_nvidia_query, default_pci_ids())
            except OSError:
                gpus = []
        nvidia_procs = {}
        if args.detail and str(proc_root) == "/proc" and any(row.get("vendor") == "nvidia" for row in gpus):
            try:
                nvidia_procs = parse_nvidia_pmon(default_nvidia_pmon())
            except OSError:
                nvidia_procs = {}
        payload = collect_snapshot(
            proc_root,
            state_path,
            args.detail,
            titles,
            autostart,
            os.getuid(),
            time.monotonic(),
            time.sleep,
            gpus,
            nvidia_procs,
        )
        return emit(payload)
    if args.targets:
        try:
            targets = json.loads(args.targets)
        except (ValueError, TypeError) as e:
            return emit(fail(f"Invalid targets JSON: {e}"))
        payload = perform_end_batch(targets, args.signal, proc_root, os.getuid())
        return emit(payload)
    if args.pid is None or args.starttime is None:
        return emit(fail("end requires --pid and --starttime or --targets."))
    live = live_process(proc_root, args.pid)
    payload = perform_end(args.pid, args.starttime, args.signal, live, os.getuid(), proc_root=proc_root)
    return emit(payload)


if __name__ == "__main__":
    sys.exit(main())
