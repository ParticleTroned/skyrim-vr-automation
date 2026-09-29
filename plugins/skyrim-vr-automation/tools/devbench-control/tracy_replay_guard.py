# SPDX-License-Identifier: GPL-3.0-or-later
"""Bound an existing Tracy MCP capture; this is not a collector or transport."""

import gc
import ctypes
import json
import math
import os
from pathlib import Path
import threading
import time


MIB = 1024 ** 2


def windows_memory(collector_pid):
    """Read private usage and OS headroom without WMI, elevation or dependencies."""
    if os.name != "nt" or type(collector_pid) is not int or collector_pid <= 0:
        raise ValueError("windows_collector_pid_required")
    from ctypes import wintypes

    class Counters(ctypes.Structure):
        _fields_ = [("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD)] + [
            (name, ctypes.c_size_t) for name in (
                "PeakWorkingSetSize", "WorkingSetSize", "QuotaPeakPagedPoolUsage",
                "QuotaPagedPoolUsage", "QuotaPeakNonPagedPoolUsage", "QuotaNonPagedPoolUsage",
                "PagefileUsage", "PeakPagefileUsage", "PrivateUsage")]

    class MemoryStatus(ctypes.Structure):
        _fields_ = [("length", wintypes.DWORD), ("load", wintypes.DWORD)] + [
            (name, ctypes.c_ulonglong) for name in (
                "totalPhysical", "availablePhysical", "totalPageFile", "availablePageFile",
                "totalVirtual", "availableVirtual", "availableExtendedVirtual")]

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    psapi = ctypes.WinDLL("psapi", use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    kernel.GlobalMemoryStatusEx.argtypes = [ctypes.POINTER(MemoryStatus)]
    kernel.GlobalMemoryStatusEx.restype = wintypes.BOOL
    psapi.GetProcessMemoryInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(Counters), wintypes.DWORD]
    psapi.GetProcessMemoryInfo.restype = wintypes.BOOL
    process = kernel.OpenProcess(0x1000 | 0x0010, False, collector_pid)
    if not process:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        counters = Counters()
        counters.cb = ctypes.sizeof(counters)
        memory = MemoryStatus()
        memory.length = ctypes.sizeof(memory)
        if not psapi.GetProcessMemoryInfo(process, ctypes.byref(counters), counters.cb):
            raise ctypes.WinError(ctypes.get_last_error())
        if not kernel.GlobalMemoryStatusEx(ctypes.byref(memory)):
            raise ctypes.WinError(ctypes.get_last_error())
        return {"pid": collector_pid, "utcNs": time.time_ns(),
                "privateBytes": counters.PrivateUsage,
                "availablePhysicalBytes": memory.availablePhysical,
                "availableCommitBytes": memory.availablePageFile}
    finally:
        kernel.CloseHandle(process)


def require_clean_collector(instances, tasks, memory, limit_mib=16384):
    """Reject hidden retained traces, shared work, and insufficient headroom."""
    if instances or any(t.get("status") not in ("completed", "failed") for t in tasks):
        raise RuntimeError("collector_busy_or_unproven")
    if not isinstance(limit_mib, int) or not 1024 <= limit_mib <= 32768:
        raise ValueError("capture_limit_out_of_range")
    for key in ("privateBytes", "availablePhysicalBytes", "availableCommitBytes"):
        if type(memory.get(key)) is not int or memory[key] < 0:
            raise ValueError("memory_receipt_missing:" + key)
    if memory["privateBytes"] > 512 * MIB:
        raise RuntimeError("collector_memory_not_released")
    required = (limit_mib + 8192) * MIB
    if min(memory["availablePhysicalBytes"], memory["availableCommitBytes"]) < required:
        raise RuntimeError("insufficient_capture_headroom")
    return {"clean": True, "limitMiB": limit_mib, "reserveMiB": 8192, **memory}


def require_fresh_preflight(preflight):
    """Require two recent memory proofs from this collector before arming."""
    samples = preflight["memorySamples"]
    if len(samples) != 2 or samples[1]["utcNs"] - samples[0]["utcNs"] < 1e9:
        raise RuntimeError("two_memory_samples_required")
    for sample in samples:
        if sample["pid"] != os.getpid():
            raise RuntimeError("collector_preflight_pid_mismatch")
        if not 0 <= time.time_ns() - sample["utcNs"] <= 30e9:
            raise RuntimeError("collector_preflight_expired")
        require_clean_collector(preflight["instances"], preflight["tasks"],
                                sample, preflight["limitMiB"])


def observe(worker):
    """Return bounded readiness evidence, without exporting live zone arrays."""
    stats = worker.get_all_gpu_zone_stats()
    valid = [s for s in stats.values() if s.count > 0 and s.min > 0 and s.total > 0]
    errors = [
        {"timeNs": m.time, "text": m.text}
        for m in worker.get_messages()
        if "tracyd3d11" in m.text.lower()
        and any(word in m.text.lower() for word in ("zero", "disjoint", "dropping", "error"))
    ]
    return {
        "utcNs": time.time_ns(), "monotonicNs": time.monotonic_ns(),
        "pid": worker.get_pid(), "connected": worker.is_connected(),
        "firstNs": worker.get_first_time(), "lastNs": worker.get_last_time(),
        "frames": worker.get_frame_count(), "gpuPasses": len(valid),
        "gpuSamples": sum(s.count for s in valid), "gpuErrors": errors,
    }


def require_gpu_ready(before, after, expected_pid):
    """Require fresh completed GPU work on the same uninterrupted connection."""
    for item in (before, after):
        if item["pid"] != expected_pid or item["connected"] is not True:
            raise RuntimeError("capture_identity_or_connection_changed")
        if item["gpuErrors"] or item["gpuPasses"] < 1 or item["gpuSamples"] < 1:
            raise RuntimeError("gpu_timestamps_invalid")
    elapsed = (after["monotonicNs"] - before["monotonicNs"]) / 1e9
    if elapsed < 0.5:
        raise RuntimeError("readiness_interval_too_short")
    if (after["frames"] - before["frames"] < 3
            or after["lastNs"] <= before["lastNs"]
            or after["gpuSamples"] <= before["gpuSamples"]):
        raise RuntimeError("gpu_timestamps_not_advancing")
    return {"ready": True, "before": before, "after": after}


def summarize_ns(values):
    """Retain the count and use linear-interpolated quantiles in milliseconds."""
    if not values:
        return {"count": 0, "meanMs": None, "medianMs": None, "p95Ms": None, "p99Ms": None}
    if any(not math.isfinite(v) or v <= 0 for v in values):
        raise ValueError("invalid_duration")
    ordered = sorted(values)

    def percentile(q):
        position = (len(ordered) - 1) * q
        lo = math.floor(position)
        hi = math.ceil(position)
        return (ordered[lo] + (ordered[hi] - ordered[lo]) * (position - lo)) / 1e6

    return {"count": len(values), "meanMs": sum(values) / len(values) / 1e6,
            "medianMs": percentile(.5), "p95Ms": percentile(.95), "p99Ms": percentile(.99)}


class CaptureGuard:
    """Disconnect on an independent deadline even when replay control stalls."""

    def __init__(self, worker, owner, expected_pid, seconds, receipt_path):
        if not owner or not isinstance(owner, str):
            raise ValueError("owner_required")
        if not isinstance(seconds, (int, float)) or not 1 <= seconds <= 600:
            raise ValueError("deadline_out_of_range")
        if worker.get_pid() != expected_pid or not worker.is_connected():
            raise RuntimeError("capture_identity_or_connection_changed")
        self.worker = worker
        self.lock = threading.RLock()
        self.path = Path(receipt_path)
        if not self.path.is_absolute() or not self.path.parent.is_dir():
            raise ValueError("existing_absolute_evidence_directory_required")
        self.state = {"owner": owner, "pid": expected_pid, "armedUtcNs": time.time_ns(),
                      "deadlineSeconds": seconds, "ready": False, "replayAdmitted": False,
                      "stopReason": None, "disconnectRequested": False}
        # Exclusive creation prevents accidental overwrite of a previous attempt.
        with self.path.open("x", encoding="utf-8") as output:
            json.dump(self.state, output, indent=2)
        self.timer = threading.Timer(seconds, self.stop, args=("deadline",))
        self.timer.daemon = True
        self.timer.start()

    def persist(self):
        temporary = self.path.with_suffix(self.path.suffix + ".tmp")
        with temporary.open("w", encoding="utf-8") as output:
            json.dump(self.state, output, indent=2)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, self.path)

    def ready(self, before):
        try:
            result = require_gpu_ready(before, observe(self.worker), self.state["pid"])
        except Exception as error:
            with self.lock:
                self.state["failure"] = str(error)
            self.stop("readiness_failed")
            raise
        with self.lock:
            if self.state["stopReason"] is not None:
                raise RuntimeError("capture_already_stopped")
            self.state["readiness"] = result
            self.state["ready"] = True
            self.persist()
            return result

    def admit(self):
        boundary = observe(self.worker)
        with self.lock:
            if not self.state["ready"] or self.state["stopReason"] is not None:
                raise RuntimeError("capture_not_ready")
            if self.state["replayAdmitted"]:
                raise RuntimeError("replay_already_admitted")
            if not boundary["connected"] or boundary["gpuErrors"]:
                raise RuntimeError("capture_unhealthy_before_replay")
            readiness = self.state["readiness"]["after"]
            if (boundary["gpuPasses"] < 1
                    or boundary["gpuSamples"] < readiness["gpuSamples"]
                    or boundary["frames"] < readiness["frames"]
                    or boundary["lastNs"] < readiness["lastNs"]):
                raise RuntimeError("capture_progress_regressed")
            self.state["replayAdmitted"] = True
            self.state["beforeReplay"] = boundary
            self.persist()
            return boundary

    def prepare(self):
        """Check GPU progress and admit without an intervening transport call."""
        try:
            before = observe(self.worker)
            time.sleep(0.75)
            readiness = self.ready(before)
            admission = self.admit()
            return {"readiness": readiness, "admission": admission}
        except Exception as error:
            with self.lock:
                self.state["failure"] = str(error)
            self.stop("admission_failed")
            raise

    def finish(self):
        """Verify the final GPU drain and stop within the collector process."""
        try:
            with self.lock:
                if self.state["stopReason"] is not None:
                    return dict(self.state)
                if not self.state["replayAdmitted"]:
                    raise RuntimeError("replay_not_admitted")
            before = observe(self.worker)
            time.sleep(0.75)
            after = observe(self.worker)
            require_gpu_ready(before, after, self.state["pid"])
            with self.lock:
                self.state["completion"] = {
                    "before": before, "after": after,
                    "drainSeconds": (after["monotonicNs"] - before["monotonicNs"]) / 1e9}
            return self.stop("replay_complete")
        except Exception as error:
            with self.lock:
                self.state["failure"] = str(error)
            self.stop("completion_failed")
            raise

    def stop(self, reason):
        with self.lock:
            if self.state["stopReason"] is not None:
                return dict(self.state)
            self.state["stopReason"] = reason
            self.state["stopUtcNs"] = time.time_ns()
            try:
                # Do not query statistics under the collector data lock here.
                # Disconnect must remain available when an export is blocked.
                self.worker.disconnect()
                self.state["disconnectRequested"] = True
            except Exception as error:
                self.state["disconnectError"] = str(error)
            finally:
                self.worker = None
                self.timer.cancel()
            try:
                self.persist()
            except Exception as error:
                self.state["persistenceError"] = str(error)
            return dict(self.state)

    def release(self):
        if self.state["stopReason"] is None:
            raise RuntimeError("stop_capture_before_release")
        self.timer.join(timeout=2)
        if self.timer.is_alive():
            raise RuntimeError("capture_timer_still_running")
        return dict(self.state)


def dispatch(worker, tracy_module, request):
    """Operate only on the guard belonging to the explicitly named capture."""
    owner = request["owner"]
    guards = getattr(tracy_module, "_vr_replay_guards", None)
    if guards is None:
        guards = {}
        tracy_module._vr_replay_guards = guards
    action = request["action"]
    if action in ("arm", "prepare"):
        if guards:
            raise RuntimeError("capture_guard_already_owned")
        try:
            require_fresh_preflight(request["preflight"])
            claim_path = Path(request["processClaimPath"])
            process_identity = {"pid": request["expectedPid"],
                                "startedUtc": request["processStartedUtc"], "owner": owner}
            if not process_identity["startedUtc"] or not claim_path.is_absolute():
                raise ValueError("process_start_identity_required")
            with claim_path.open("x", encoding="utf-8") as output:
                json.dump(process_identity, output, indent=2)
            guard = CaptureGuard(worker, owner, request["expectedPid"],
                                 request["seconds"], request["receiptPath"])
        except Exception:
            worker.disconnect()
            raise
        guards[owner] = guard
        guard.state["preflight"] = request["preflight"]
        try:
            guard.persist()
        except Exception:
            guard.stop("arm_receipt_failed")
            raise
        return guard.prepare() if action == "prepare" else dict(guard.state)
    guard = guards.get(owner)
    if guard is None or worker.get_pid() != guard.state["pid"]:
        raise RuntimeError("capture_guard_owner_mismatch")
    if action == "observe":
        return observe(worker)
    if action == "ready":
        return guard.ready(request["before"])
    if action == "admit":
        return guard.admit()
    if action == "stop":
        return guard.stop(request["reason"])
    if action == "finish":
        return guard.finish()
    if action == "status":
        return dict(guard.state)
    if action == "release":
        result = guard.release()
        del guards[owner]
        gc.collect()
        return result
    raise ValueError("unknown_guard_action")


def eval_code(helper_path, request):
    """Make an MCP eval without retaining ctx in function/global reference cycles."""
    return (
        "try:\n"
        " import gc, json, runpy\n"
        f" _helpers = runpy.run_path({str(helper_path)!r})\n"
        f" _request = json.loads({json.dumps(request)!r})\n"
        " print(json.dumps(_helpers['dispatch'](ctx, tracy, _request)))\n"
        "finally:\n"
        " globals().clear()\n"
    )


CLEANUP_EVAL = "import gc\nprint({'collected':gc.collect()})\nglobals().clear()"
