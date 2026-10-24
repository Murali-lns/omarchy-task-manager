#!/usr/bin/python3
"""Unit tests for the Task Manager collector. No live process is killed except
a sleep child this file starts itself, and only by that exact PID."""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "bin"))
import taskman  # noqa: E402


def stat_line(pid, comm, state, ppid, flags, utime, stime, starttime):
    # Fields after comm: state ppid pgrp session tty tpgid flags minflt cminflt
    # majflt cmajflt utime stime cutime cstime priority nice num_threads
    # itrealvalue starttime
    rest = [
        state, ppid, pid, pid, 0, -1, flags,
        0, 0, 0, 0,
        utime, stime, 0, 0,
        20, 0, 1, 0, starttime,
    ]
    return f"{pid} ({comm}) " + " ".join(str(part) for part in rest) + "\n"


class ParserTests(unittest.TestCase):
    def test_pid_stat_keeps_spaces_inside_comm(self):
        parsed = taskman.parse_pid_stat("42 (my app) S 1 1 1 0 -1 0 0 0 0 0 5 7 0 0 20 0 1 0 99\n")
        self.assertEqual(parsed["comm"], "my app")
        self.assertEqual(parsed["pid"], 42)
        self.assertEqual(parsed["ppid"], 1)
        self.assertEqual(parsed["utime"], 5)
        self.assertEqual(parsed["stime"], 7)
        self.assertEqual(parsed["starttime"], 99)

    def test_host_cpu_percent_uses_idle_delta(self):
        self.assertIsNone(taskman.host_cpu_percent(None, None, 100, 50))
        self.assertEqual(taskman.host_cpu_percent(100, 80, 200, 100), 80.0)
        self.assertEqual(taskman.host_cpu_percent(100, 40, 100, 40), None)

    def test_process_cpu_is_share_of_total_not_one_core(self):
        self.assertEqual(taskman.process_cpu_percent(10, 20, 100), 10.0)
        self.assertIsNone(taskman.process_cpu_percent(None, 20, 100))
        self.assertIsNone(taskman.process_cpu_percent(30, 20, 100))

    def test_meminfo_treats_available_as_free(self):
        text = "MemTotal: 1000 kB\nMemAvailable: 250 kB\nSwapTotal: 100 kB\nSwapFree: 40 kB\n"
        parsed = taskman.parse_meminfo(text)
        self.assertEqual(parsed["memTotal"], 1000 * 1024)
        self.assertEqual(parsed["memUsed"], 750 * 1024)
        self.assertEqual(parsed["memPercent"], 75.0)
        self.assertEqual(parsed["swapUsed"], 60 * 1024)

    def test_net_dev_skips_loopback(self):
        text = "lo: 9 0 0 0 0 0 0 0 8 0 0 0 0 0 0 0\neth0: 100 0 0 0 0 0 0 0 40 0 0 0 0 0 0 0\n"
        self.assertEqual(taskman.parse_net_dev(text), (100, 40))

    def test_diskstats_skips_partitions_and_loop(self):
        text = "\n".join([
            "7 0 loop0 1 0 10 0 1 0 10 0 0 0 0 0 0 0 0",
            "8 0 sda 1 0 100 0 1 0 50 0 0 0 0 0 0 0 0",
            "8 1 sda1 1 0 80 0 1 0 20 0 0 0 0 0 0 0 0",
            "259 0 nvme0n1 1 0 4 0 1 0 2 0 0 0 0 0 0 0 0",
            "259 1 nvme0n1p1 1 0 4 0 1 0 2 0 0 0 0 0 0 0 0",
        ])
        self.assertEqual(taskman.parse_diskstats(text), ((100 + 4) * 512, (50 + 2) * 512))

    def test_user_hidden_overrides_system_autostart(self):
        system = [taskman.parse_desktop(
            "[Desktop Entry]\nName=Printer\nExec=print-applet\n",
            "system",
            "print-applet.desktop",
        )]
        user = [taskman.parse_desktop("[Desktop Entry]\nHidden=true\n", "user", "print-applet.desktop")]
        merged = taskman.merge_autostart(system, user)
        self.assertEqual(merged, [{
            "name": "Printer",
            "exec": "print-applet",
            "enabled": False,
            "source": "user",
            "file": "print-applet.desktop",
        }])

    def test_protection_refuses_init_kernel_other_user_and_session(self):
        self.assertIn("init", taskman.protection_reason(1, "systemd", "S", 0, 0, 1000))
        self.assertIn("Kernel", taskman.protection_reason(9, "kthread", "S", taskman.PF_KTHREAD, 0, 1000))
        self.assertIn("Session-critical", taskman.protection_reason(20, "quickshell", "S", 0, 1000, 1000))
        self.assertIn("another user", taskman.protection_reason(30, "firefox", "S", 0, 0, 1000))
        self.assertEqual(taskman.protection_reason(30, "firefox", "S", 0, 1000, 1000), "")


class EndTests(unittest.TestCase):
    def live(self, **overrides):
        row = {"comm": "sleep", "state": "S", "flags": 0, "uid": 1000, "starttime": 50}
        row.update(overrides)
        return row

    def test_end_refuses_bad_pid_signal_and_recycled_starttime(self):
        calls = []
        for pid in (0, 1, -5, True):
            result = taskman.perform_end(pid, 50, "TERM", self.live(), 1000, calls.append)
            self.assertFalse(result["ok"])
        recycled = taskman.perform_end(42, 50, "TERM", self.live(starttime=51), 1000, calls.append)
        self.assertIn("reused", recycled["error"])
        missing = taskman.perform_end(42, 50, "TERM", None, 1000, calls.append)
        self.assertIn("already gone", missing["error"])
        bad_signal = taskman.perform_end(42, 50, "HUP", self.live(), 1000, calls.append)
        self.assertFalse(bad_signal["ok"])
        self.assertEqual(calls, [])

    def test_end_signals_only_the_matching_pid(self):
        calls = []

        def killer(pid, sig):
            calls.append((pid, sig))

        result = taskman.perform_end(42, 50, "KILL", self.live(), 1000, killer)
        self.assertTrue(result["ok"])
        self.assertEqual(calls, [(42, signal.SIGKILL)])

    def test_cli_refuses_pid_one_without_signaling(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "1").mkdir()
            (root / "1" / "stat").write_text(stat_line(1, "systemd", "S", 0, 0, 1, 1, 1))
            (root / "1" / "status").write_text("Uid:\t0\t0\t0\t0\nVmRSS:\t1 kB\n")
            completed = subprocess.run(
                [sys.executable, str(Path(__file__).resolve().parent / "bin" / "taskman.py"),
                 "end", "--pid", "1", "--starttime", "1", "--signal", "KILL", "--proc-root", str(root)],
                check=False,
                capture_output=True,
                text=True,
            )
        payload = json.loads(completed.stdout)
        self.assertFalse(payload["ok"])
        self.assertIn("greater than 1", payload["error"])
        self.assertNotEqual(completed.returncode, 0)

    def test_perform_end_batch_signals_multiple_matching_pids(self):
        calls = []
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for pid, start in [(10, 50), (20, 60)]:
                (root / str(pid)).mkdir()
                (root / str(pid) / "stat").write_text(stat_line(pid, "sleep", "S", 1, 0, 1, 1, start))
                (root / str(pid) / "status").write_text("Uid:\t1000\t1000\t1000\t1000\nVmRSS:\t100 kB\n")
            targets = [{"pid": 10, "starttime": 50}, {"pid": 20, "starttime": 60}]
            result = taskman.perform_end_batch(targets, "TERM", root, 1000, lambda pid, sig: calls.append((pid, sig)))
        self.assertTrue(result["ok"])
        self.assertEqual(result["count"], 2)
        self.assertEqual(result["ended"], [10, 20])
        self.assertEqual(calls, [(10, signal.SIGTERM), (20, signal.SIGTERM)])

    def test_production_end_does_not_signal_by_pid(self):
        source = (Path(__file__).resolve().parent / "bin" / "taskman.py").read_text(encoding="utf-8")
        self.assertNotIn("os.kill", source)
        self.assertIn("pidfd_open", source)
        self.assertIn("pidfd_send_signal", source)
        self.assertNotIn('["hyprctl"', source)
        self.assertIn('HYPRCTL = "/usr/bin/hyprctl"', source)


class SnapshotTests(unittest.TestCase):
    def write_tree(self, root: Path, user, idle=1000, net_rx=1000):
        (root / "stat").write_text(
            f"cpu  {user} 0 0 {idle} 0 0 0 0 0 0\n"
            f"cpu0 {user} 0 0 {idle} 0 0 0 0 0 0\n"
        )
        (root / "meminfo").write_text("MemTotal: 1000 kB\nMemAvailable: 400 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n")
        (root / "uptime").write_text("120.0 0\n")
        (root / "loadavg").write_text("0.10 0.20 0.30 1/2 1\n")
        (root / "net").mkdir(exist_ok=True)
        (root / "net" / "dev").write_text(f"lo: 1 0 0 0 0 0 0 0 1 0 0 0 0 0 0 0\neth0: {net_rx} 0 0 0 0 0 0 0 500 0 0 0 0 0 0 0\n")
        (root / "diskstats").write_text("8 0 sda 1 0 10 0 1 0 4 0 0 0 0 0 0 0 0\n")
        proc = root / "77"
        proc.mkdir(exist_ok=True)
        (proc / "stat").write_text(stat_line(77, "sleep", "S", 1, 0, user, 0, 10))
        (proc / "status").write_text("Uid:\t1000\t1000\t1000\t1000\nVmRSS:\t12 kB\n")
        (proc / "cmdline").write_bytes(b"/usr/bin/sleep\x0030\x00")

    def test_second_detail_sample_reports_cpu_and_app_kind(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "proc"
            root.mkdir()
            state = Path(tmp) / "sample.json"
            self.write_tree(root, 10)

            def sleeper(_seconds):
                self.write_tree(root, 30)

            first = taskman.collect_snapshot(root, state, True, {77: "sleep"}, [], 1000, 1.0, sleeper)
            self.assertTrue(first["ok"])
            self.assertEqual(first["host"]["cpuPercent"], 100.0)
            self.assertEqual(len(first["processes"]), 1)
            row = first["processes"][0]
            self.assertEqual(row["name"], "sleep")
            self.assertEqual(row["kind"], "app")
            self.assertEqual(row["windowTitle"], "sleep")
            self.assertEqual(row["cpu"], 100.0)
            self.assertFalse(row["protected"])
            self.assertEqual(row["memBytes"], 12 * 1024)
            saved = json.loads(state.read_text())
            self.assertEqual(saved["detail"], True)
            self.assertNotIn("cmdline", json.dumps(saved))

    def test_summary_omits_process_list(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "proc"
            root.mkdir()
            state = Path(tmp) / "sample.json"
            self.write_tree(root, 10)
            taskman.collect_snapshot(root, state, False, {}, [], 1000, 1.0, lambda _s: None)
            self.write_tree(root, 20, idle=1010)
            second = taskman.collect_snapshot(root, state, False, {}, [{"name": "hidden"}], 1000, 3.0, lambda _s: None)
        self.assertEqual(second["processes"], [])
        self.assertEqual(second["startup"], [])
        self.assertEqual(second["host"]["cpuPercent"], 50.0)
        self.assertEqual(second["host"]["memPercent"], 60.0)
        self.assertEqual(second["host"]["netRxBps"], 0.0)
        self.assertEqual(second["host"]["gpus"], [])


class GpuTests(unittest.TestCase):
    def test_nvidia_query_converts_mib_and_ignores_missing_util(self):
        text = "0, NVIDIA GeForce GTX 1650, 0, 511, 4096, 66\n1, Broken, N/A, N/A, N/A, N/A\n"
        rows = taskman.parse_nvidia_query(text)
        self.assertEqual(rows[0]["name"], "NVIDIA GeForce GTX 1650")
        self.assertEqual(rows[0]["busyPercent"], 0.0)
        self.assertEqual(rows[0]["memUsed"], 511 * 1024 * 1024)
        self.assertEqual(rows[0]["memTotal"], 4096 * 1024 * 1024)
        self.assertEqual(rows[0]["tempC"], 66)
        self.assertIsNone(rows[1]["busyPercent"])
        self.assertIsNone(rows[1]["memUsed"])

    def test_hybrid_cards_prefer_sysfs_for_amd_and_smi_for_nvidia(self):
        cards = [
            {
                "vendor": "0x10de", "device": "0x1f9d", "driver": "nvidia", "boot": False,
                "busy": None, "memUsed": None, "memTotal": None, "tempC": None,
            },
            {
                "vendor": "0x1002", "device": "0x164c", "driver": "amdgpu", "boot": True,
                "busy": 14, "memUsed": 1000, "memTotal": 4000, "tempC": 75,
            },
        ]
        names = {("1002", "164c"): "Lucienne"}
        nvidia = taskman.parse_nvidia_query("0, NVIDIA GeForce GTX 1650, 3, 512, 4096, 70\n")
        rows = taskman.assemble_gpus(cards, nvidia, names)
        self.assertEqual([row["shortName"] for row in rows], ["AMD", "NVIDIA"])
        self.assertEqual(rows[0]["name"], "AMD Lucienne")
        self.assertEqual(rows[0]["busyPercent"], 14.0)
        self.assertEqual(rows[0]["memPercent"], 25.0)
        self.assertEqual(rows[0]["tempC"], 75)
        self.assertEqual(rows[1]["busyPercent"], 3.0)
        self.assertNotIn("_boot", rows[0])

    def test_smi_failure_still_reports_the_other_gpu(self):
        cards = [{
            "vendor": "0x1002", "device": "0x164c", "driver": "amdgpu", "boot": True,
            "busy": 8, "memUsed": 10, "memTotal": 20, "tempC": None,
        }]
        rows = taskman.assemble_gpus(cards, [], {})
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["name"], "AMD GPU")
        self.assertIsNone(rows[0]["tempC"])

    def test_sysfs_ignores_connectors_and_reads_busy(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            connector = root / "card2-eDP-1" / "device"
            connector.mkdir(parents=True)
            (connector / "vendor").write_text("0x1002\n")
            (connector / "gpu_busy_percent").write_text("99\n")
            device = root / "card2" / "device"
            device.mkdir(parents=True)
            (device / "vendor").write_text("0x1002\n")
            (device / "device").write_text("0x164c\n")
            (device / "boot_vga").write_text("1\n")
            (device / "gpu_busy_percent").write_text("14\n")
            (device / "mem_info_vram_used").write_text("1000\n")
            (device / "mem_info_vram_total").write_text("4000\n")
            hwmon = device / "hwmon" / "hwmon0"
            hwmon.mkdir(parents=True)
            (hwmon / "temp1_input").write_text("75000\n")
            os.symlink("amdgpu", device / "driver")
            nvidia = root / "card1" / "device"
            nvidia.mkdir(parents=True)
            (nvidia / "vendor").write_text("0x10de\n")
            (nvidia / "device").write_text("0x1f9d\n")
            os.symlink("nvidia", nvidia / "driver")
            ids = root / "pci.ids"
            ids.write_text("1002  AMD\n\t164c  Lucienne\n")
            calls = []

            def runner():
                calls.append("smi")
                return "0, NVIDIA GeForce GTX 1650, 1, 256, 4096, 60\n"

            rows = taskman.read_live_gpus(root, runner, ids)
        self.assertEqual(calls, ["smi"])
        self.assertEqual([row["name"] for row in rows], ["AMD Lucienne", "NVIDIA GeForce GTX 1650"])
        self.assertEqual(rows[0]["tempC"], 75)
        self.assertEqual(rows[0]["busyPercent"], 14.0)

    def test_snapshot_keeps_gpu_out_of_the_delta_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "proc"
            root.mkdir()
            state = Path(tmp) / "sample.json"
            (root / "stat").write_text("cpu  1 0 0 1 0 0 0 0 0 0\n")
            (root / "meminfo").write_text("MemTotal: 1000 kB\nMemAvailable: 500 kB\n")
            (root / "uptime").write_text("1.0 0\n")
            (root / "loadavg").write_text("0 0 0 1/1 1\n")
            (root / "net").mkdir()
            (root / "net" / "dev").write_text("")
            (root / "diskstats").write_text("")
            gpus = [{"name": "AMD Lucienne", "vendor": "amd", "shortName": "AMD", "busyPercent": 9, "memUsed": 10, "memTotal": 40, "tempC": 40}]
            payload = taskman.collect_snapshot(root, state, False, {}, [], 1000, 1.0, lambda _s: None, gpus)
            saved = state.read_text()
        self.assertEqual(payload["host"]["gpus"][0]["busyPercent"], 9.0)
        self.assertNotIn("Lucienne", saved)


class ProcessGpuTests(unittest.TestCase):
    def test_fdinfo_merges_the_same_client_and_keeps_engine_time(self):
        card = taskman.parse_fdinfo_gpu(
            "drm-driver:\tamdgpu\n"
            "drm-client-id:\t11\n"
            "drm-pdev:\t0000:05:00.0\n"
            "drm-engine-gfx:\t1000000000 ns\n"
            "drm-engine-compute:\t0 ns\n"
            "drm-resident-vram:\t12 KiB\n"
        )
        render = taskman.parse_fdinfo_gpu(
            "drm-driver:\tamdgpu\n"
            "drm-client-id:\t11\n"
            "drm-pdev:\t0000:05:00.0\n"
            "drm-resident-vram:\t4 MiB\n"
        )
        other = taskman.parse_fdinfo_gpu(
            "drm-driver:\tamdgpu\n"
            "drm-client-id:\t22\n"
            "drm-pdev:\t0000:05:00.0\n"
            "drm-resident-vram:\t1 MiB\n"
        )
        merged = taskman.accumulate_fdinfo([card, render, other])
        self.assertEqual(merged["engines"], 1000000000)
        self.assertEqual(merged["vram"], 4 * 1024 * 1024 + 1024 * 1024)
        self.assertEqual(merged["drivers"], ["amdgpu"])
        self.assertEqual(taskman.gpu_engine_percent(1000000000, 1500000000, 1.0), 50.0)
        self.assertIsNone(taskman.gpu_engine_percent(1500000000, 1000000000, 1.0))

    def test_pmon_keeps_memory_when_utilization_is_blank(self):
        text = (
            "# gpu pid type sm mem enc dec jpg ofa fb ccpm command\n"
            "0 1066 C - - - - - - 508 0 python\n"
        )
        parsed = taskman.parse_nvidia_pmon(text)
        self.assertEqual(parsed[1066]["sm"], None)
        self.assertEqual(parsed[1066]["mem"], 508 * 1024 * 1024)
        fields = taskman.process_gpu_fields(
            {"stat": {"pid": 1066, "starttime": 9}, "gpuNs": None, "gpuVram": 0, "gpuDrivers": []},
            {},
            1.0,
            parsed,
        )
        self.assertFalse(fields["gpuKnown"])
        self.assertEqual(fields["gpuMemBytes"], 508 * 1024 * 1024)
        self.assertIn("NVIDIA", fields["gpuNote"])
        self.assertIn("508 MB", fields["gpuNote"])

    def test_card_fdinfo_becomes_a_process_percent(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc = Path(tmp) / "77"
            (proc / "fd").mkdir(parents=True)
            (proc / "fdinfo").mkdir()
            os.symlink("/dev/dri/card0", proc / "fd" / "3")
            (proc / "fdinfo" / "3").write_text(
                "drm-driver:\tamdgpu\n"
                "drm-client-id:\t11\n"
                "drm-pdev:\t0000:05:00.0\n"
                "drm-engine-gfx:\t1000000000 ns\n"
                "drm-resident-vram:\t12 KiB\n"
            )
            first = taskman.read_process_gpu(proc)
            (proc / "fdinfo" / "3").write_text(
                "drm-driver:\tamdgpu\n"
                "drm-client-id:\t11\n"
                "drm-pdev:\t0000:05:00.0\n"
                "drm-engine-gfx:\t1500000000 ns\n"
                "drm-resident-vram:\t12 KiB\n"
            )
            second = taskman.read_process_gpu(proc)
        self.assertEqual(first["engines"], 1000000000)
        fields = taskman.process_gpu_fields(
            {"stat": {"pid": 77, "starttime": 10}, "gpuNs": second["engines"], "gpuVram": second["vram"], "gpuDrivers": second["drivers"]},
            {"start": 10, "gpuNs": first["engines"]},
            1.0,
            {},
        )
        self.assertEqual(fields["gpu"], 50.0)
        self.assertTrue(fields["gpuKnown"])
        self.assertEqual(fields["gpuNote"], "AMD 12 KB")


class LiveChildTests(unittest.TestCase):
    def test_end_stops_only_a_child_this_test_started(self):
        child = subprocess.Popen(["sleep", "30"])
        try:
            stat = Path(f"/proc/{child.pid}/stat").read_text()
            parsed = taskman.parse_pid_stat(stat)
            self.assertIsNotNone(parsed)
            completed = subprocess.run(
                [sys.executable, str(Path(__file__).resolve().parent / "bin" / "taskman.py"),
                 "end", "--pid", str(child.pid), "--starttime", str(parsed["starttime"]), "--signal", "TERM"],
                check=False,
                capture_output=True,
                text=True,
            )
            payload = json.loads(completed.stdout)
            self.assertTrue(payload["ok"], payload)
            self.assertEqual(payload["pid"], child.pid)
            child.wait(timeout=3)
            self.assertNotEqual(child.returncode, None)
        finally:
            if child.poll() is None:
                os.kill(child.pid, signal.SIGKILL)
                child.wait(timeout=3)

    def test_wrong_starttime_leaves_the_child_running(self):
        child = subprocess.Popen(["sleep", "30"])
        try:
            stat = Path(f"/proc/{child.pid}/stat").read_text()
            parsed = taskman.parse_pid_stat(stat)
            self.assertIsNotNone(parsed)
            completed = subprocess.run(
                [sys.executable, str(Path(__file__).resolve().parent / "bin" / "taskman.py"),
                 "end", "--pid", str(child.pid), "--starttime", str(parsed["starttime"] + 1), "--signal", "KILL"],
                check=False,
                capture_output=True,
                text=True,
            )
            payload = json.loads(completed.stdout)
            self.assertFalse(payload["ok"], payload)
            self.assertIn("reused", payload["error"])
            self.assertIsNone(child.poll())
            with self.assertRaises(taskman.IdentityChanged):
                taskman.signal_pinned(child.pid, parsed["starttime"] + 1, signal.SIGKILL, Path("/proc"))
            self.assertIsNone(child.poll())
        finally:
            if child.poll() is None:
                os.kill(child.pid, signal.SIGKILL)
                child.wait(timeout=3)

    def test_end_targets_stops_multiple_children(self):
        child1 = subprocess.Popen(["sleep", "30"])
        child2 = subprocess.Popen(["sleep", "30"])
        try:
            stat1 = Path(f"/proc/{child1.pid}/stat").read_text()
            parsed1 = taskman.parse_pid_stat(stat1)
            stat2 = Path(f"/proc/{child2.pid}/stat").read_text()
            parsed2 = taskman.parse_pid_stat(stat2)
            self.assertIsNotNone(parsed1)
            self.assertIsNotNone(parsed2)
            targets = json.dumps([
                {"pid": child1.pid, "starttime": parsed1["starttime"]},
                {"pid": child2.pid, "starttime": parsed2["starttime"]}
            ])
            completed = subprocess.run(
                [sys.executable, str(Path(__file__).resolve().parent / "bin" / "taskman.py"),
                 "end", "--targets", targets, "--signal", "TERM"],
                check=False,
                capture_output=True,
                text=True,
            )
            payload = json.loads(completed.stdout)
            self.assertTrue(payload["ok"], payload)
            self.assertEqual(payload["count"], 2)
            self.assertEqual(sorted(payload["ended"]), sorted([child1.pid, child2.pid]))
            child1.wait(timeout=3)
            child2.wait(timeout=3)
            self.assertNotEqual(child1.returncode, None)
            self.assertNotEqual(child2.returncode, None)
        finally:
            for c in (child1, child2):
                if c.poll() is None:
                    os.kill(c.pid, signal.SIGKILL)
                    c.wait(timeout=3)


if __name__ == "__main__":
    unittest.main()
