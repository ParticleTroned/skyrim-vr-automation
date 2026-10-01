# SPDX-License-Identifier: GPL-3.0-or-later
import gc
import csv
from contextlib import redirect_stdout
import hashlib
import importlib.util
from io import StringIO
import json
import os
from pathlib import Path
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import weakref

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "tools/devbench-control/tracy_replay_guard.py"
spec = importlib.util.spec_from_file_location("tracy_replay_guard", HELPER)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class Worker:
    def __init__(self):
        self.connected = True
        self.stops = 0
        self.frames = 10
        self.samples = 10
        self.messages = []

    def get_pid(self): return 17
    def is_connected(self): return self.connected
    def get_first_time(self): return 1
    def get_last_time(self): return self.frames * 1000000
    def get_frame_count(self): return self.frames
    def get_messages(self): return self.messages
    def get_all_gpu_zone_stats(self):
        return {"pass": SimpleNamespace(count=self.samples, min=10, total=self.samples * 10)}
    def disconnect(self):
        self.connected = False
        self.stops += 1


class TimingWorker(Worker):
    def __init__(self):
        super().__init__()
        self.connected = False
        self.plots = {
            name: [(2000000, 1.0), (3000000, 2.0)]
            for name in guard.FRAME_TIMING_UNITS
        }
        self.plots["VR::AdditionalMetric"] = [(2000000, 4.0)]

    def is_background_done(self): return True
    def get_first_time(self): return 1500000
    def get_last_time(self): return 5000000
    def get_frame_count(self): return 2
    def get_frame_boundaries(self):
        return [(1000000, 2000000), (2000000, 3000000)]
    def get_all_zone_stats(self):
        return {"Game::MainUpdateCpu (0x1)[64] <7>": SimpleNamespace(count=2)}
    def get_all_gpu_zone_stats(self):
        return {"Game::MainUpdateD3D11": SimpleNamespace(count=2)}
    def get_zone_occurrences_with_thread(self, name, max_samples):
        self.cpu_limit = max_samples
        return [(1200000, 300000, 13), (2200000, 400000, 13)]
    def get_gpu_zone_occurrences(self, name, max_samples):
        self.gpu_limit = max_samples
        return [(1300000, 200000), (2300000, 250000)]
    def get_plots(self):
        return [SimpleNamespace(name=name, count=len(samples))
                for name, samples in self.plots.items()]
    def get_plot_samples(self, name, max_samples):
        self.plot_limit = max_samples
        return self.plots[name][:max_samples]


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.worker = Worker()
        self.tracy = SimpleNamespace()
        memory = {"pid": os.getpid(), "utcNs": time.time_ns(),
                  "privateBytes": 60 * guard.MIB,
                  "availablePhysicalBytes": 40 * 1024 * guard.MIB,
                  "availableCommitBytes": 40 * 1024 * guard.MIB}
        preflight = {"memorySamples": [dict(memory, utcNs=memory["utcNs"] - 1000000000), memory],
                     "instances": [], "tasks": [], "limitMiB": 16384}
        self.request = {"action": "arm", "owner": "test", "expectedPid": 17,
                        "preflight": preflight,
                        "seconds": 10, "processStartedUtc": "2026-09-29T19:00:00Z",
                        "processClaimPath": str(self.path / "process.json"),
                        "receiptPath": str(self.path / "guard.json")}
        guard.reserve_process(self.request)
        self.addCleanup(self.cleanup)

    def cleanup(self):
        for item in list(getattr(self.tracy, "_vr_replay_guards", {}).values()):
            item.stop("test_cleanup")
            item.release()

    def arm(self):
        return guard.dispatch(self.worker, self.tracy, self.request)

    def call(self, action, **kwargs):
        return guard.dispatch(self.worker, self.tracy,
                              {"owner": "test", "action": action, **kwargs})

    def readiness(self):
        before = guard.observe(self.worker)
        before["monotonicNs"] -= 1000000000
        self.worker.frames += 5
        self.worker.samples += 5
        return self.call("ready", before=before)

    def test_hidden_ten_gib_blocks_empty_registry(self):
        memory = {"privateBytes": 10 * 1024 * guard.MIB,
                  "availablePhysicalBytes": 40 * 1024 * guard.MIB,
                  "availableCommitBytes": 40 * 1024 * guard.MIB}
        with self.assertRaisesRegex(RuntimeError, "not_released"):
            guard.require_clean_collector([], [], memory)
        memory["privateBytes"] = 60 * guard.MIB
        self.assertTrue(guard.require_clean_collector([], [], memory)["clean"])

    def test_both_physical_and_commit_headroom_required(self):
        for field in ("availablePhysicalBytes", "availableCommitBytes"):
            memory = {"privateBytes": 60 * guard.MIB,
                      "availablePhysicalBytes": 40 * 1024 * guard.MIB,
                      "availableCommitBytes": 40 * 1024 * guard.MIB}
            memory[field] = 20 * 1024 * guard.MIB
            with self.assertRaisesRegex(RuntimeError, "headroom"):
                guard.require_clean_collector([], [], memory)

    def test_shared_or_cancelled_work_cannot_be_assumed_idle(self):
        with self.assertRaisesRegex(RuntimeError, "busy"):
            guard.require_clean_collector([{"id": "other-owner"}], [], {})
        with self.assertRaisesRegex(RuntimeError, "busy"):
            guard.require_clean_collector([], [{"status": "cancelled"}], {})

    def test_missing_memory_is_not_zero(self):
        with self.assertRaisesRegex(ValueError, "memory_receipt_missing"):
            guard.require_clean_collector([], [], {})

    def test_arm_requires_recent_memory_proof_from_actual_collector(self):
        self.request["preflight"]["memorySamples"][0]["pid"] += 1
        with self.assertRaisesRegex(RuntimeError, "pid_mismatch"):
            self.arm()
        self.assertFalse(self.worker.connected)

    def test_arm_rejects_expired_memory_proof(self):
        for sample in self.request["preflight"]["memorySamples"]:
            sample["utcNs"] -= 31000000000
        with self.assertRaisesRegex(RuntimeError, "expired"):
            self.arm()
        self.assertFalse(self.worker.connected)

    def test_bad_process_claim_does_not_touch_unowned_worker(self):
        self.request["processClaimPath"] = "relative.json"
        with self.assertRaisesRegex(ValueError, "process_start_identity"):
            self.arm()
        self.assertTrue(self.worker.connected)

    def test_reservation_precedes_guard_and_blocks_reconnection(self):
        self.assertFalse(hasattr(self.tracy, "_vr_replay_guards"))
        with self.assertRaises(FileExistsError):
            guard.reserve_process(self.request)

    def test_abort_before_guard_disconnects_reserved_worker(self):
        result = guard.dispatch(self.worker, self.tracy, dict(self.request, action="abort"))
        self.assertEqual(result["stopReason"], "failure_before_guard")
        self.assertFalse(self.worker.connected)
        self.assertTrue((self.path / "process.json").exists())

    def test_abort_after_guard_preserves_failure_and_cancels_timer(self):
        self.arm()
        self.call("stop", reason="readiness_failed")
        result = guard.dispatch(self.worker, self.tracy, dict(self.request, action="abort"))
        self.assertEqual(result["stopReason"], "readiness_failed")
        self.assertEqual(self.worker.stops, 1)
        self.call("release")

    def test_arm_and_abort_reject_wrong_pid_or_claim_owner(self):
        for action in ("arm", "abort"):
            for changes in ({"expectedPid": 99}, {"owner": "other"}):
                with self.assertRaisesRegex(RuntimeError, "identity|claim_mismatch"):
                    guard.dispatch(self.worker, self.tracy, dict(self.request, action=action, **changes))
                self.assertTrue(self.worker.connected)

    def test_abort_rejects_another_guard_owner(self):
        self.arm()
        other = dict(self.request, owner="other", action="abort",
                     processClaimPath=str(self.path / "other.json"))
        guard.reserve_process(other)
        with self.assertRaisesRegex(RuntimeError, "owner_mismatch"):
            guard.dispatch(self.worker, self.tracy, other)
        self.assertTrue(self.worker.connected)

    def test_abort_without_reservation_leaves_worker_untouched(self):
        (self.path / "process.json").unlink()
        with self.assertRaises(FileNotFoundError):
            guard.dispatch(self.worker, self.tracy, dict(self.request, action="abort"))
        self.assertTrue(self.worker.connected)

    @unittest.skipUnless(os.name == "nt", "Windows memory API")
    def test_live_read_only_memory_receipt(self):
        memory = guard.windows_memory(os.getpid())
        self.assertEqual(memory["pid"], os.getpid())
        self.assertGreater(memory["privateBytes"], 0)
        self.assertGreater(memory["availablePhysicalBytes"], 0)
        self.assertGreater(memory["availableCommitBytes"], 0)

    def test_no_replay_before_gpu_gate_and_only_one_admission(self):
        self.arm()
        with self.assertRaisesRegex(RuntimeError, "not_ready"):
            self.call("admit")
        self.readiness()
        self.assertEqual(self.call("admit")["pid"], 17)
        with self.assertRaisesRegex(RuntimeError, "already_admitted"):
            self.call("admit")

    def test_zero_frequency_rejects_and_disconnects_without_admission(self):
        self.arm()
        before = guard.observe(self.worker)
        self.worker.messages = [SimpleNamespace(time=100, text=
            "TracyD3D11: zero GPU timestamp frequency; dropping.")]
        with self.assertRaisesRegex(RuntimeError, "timestamps_invalid"):
            self.call("ready", before=before)
        state = self.call("status")
        self.assertFalse(state["replayAdmitted"])
        self.assertEqual(state["stopReason"], "readiness_failed")
        self.assertFalse(self.worker.connected)

    def test_cpu_frames_without_new_gpu_samples_fail(self):
        self.arm()
        before = guard.observe(self.worker)
        before["monotonicNs"] -= 1000000000
        self.worker.frames += 10
        with self.assertRaisesRegex(RuntimeError, "not_advancing"):
            self.call("ready", before=before)

    def test_control_delay_does_not_expire_healthy_readiness(self):
        self.arm()
        self.readiness()
        self.tracy._vr_replay_guards["test"].state["readiness"]["after"]["monotonicNs"] -= 14000000000
        self.assertEqual(self.call("admit")["pid"], 17)

    def test_delayed_admission_still_rejects_gpu_regression(self):
        self.arm()
        self.readiness()
        self.worker.samples -= 1
        with self.assertRaisesRegex(RuntimeError, "regressed"):
            self.call("admit")

    def test_long_observation_interval_with_gpu_progress_is_valid(self):
        before = guard.observe(self.worker)
        before["monotonicNs"] -= 14000000000
        self.worker.frames += 5
        self.worker.samples += 5
        self.assertTrue(guard.require_gpu_ready(before, guard.observe(self.worker), 17)["ready"])

    def test_route_deadline_allows_measured_duration_and_control_margin(self):
        self.request["seconds"] = 180
        self.assertEqual(self.arm()["deadlineSeconds"], 180)
        self.assertTrue(self.worker.connected)

    def advance_gpu(self, seconds):
        self.assertEqual(seconds, 0.75)
        self.worker.frames += 5
        self.worker.samples += 5

    def test_prepare_keeps_readiness_and_admission_inside_one_call(self):
        self.request["action"] = "prepare"
        with patch.object(guard.time, "sleep", side_effect=self.advance_gpu), \
                patch.object(guard.time, "monotonic_ns", side_effect=[
                    13000000000, 13750000000, 13751000000]):
            result = guard.dispatch(self.worker, self.tracy, self.request)
        self.assertTrue(result["readiness"]["ready"])
        self.assertEqual(result["admission"]["frames"], 15)
        self.assertTrue(self.call("status")["replayAdmitted"])
        with self.assertRaisesRegex(RuntimeError, "already_admitted"):
            self.call("admit")

    def test_prepare_retains_gpu_failure_and_never_admits(self):
        self.request["action"] = "prepare"
        with patch.object(guard.time, "sleep"), \
                patch.object(guard.time, "monotonic_ns", side_effect=[0, 750000000]):
            with self.assertRaisesRegex(RuntimeError, "not_advancing"):
                guard.dispatch(self.worker, self.tracy, self.request)
        state = self.call("status")
        self.assertEqual(state["failure"], "gpu_timestamps_not_advancing")
        self.assertFalse(state["replayAdmitted"])
        self.assertFalse(self.worker.connected)

    def test_finish_drains_and_disconnects_in_one_call(self):
        self.arm()
        self.readiness()
        self.call("admit")
        with patch.object(guard.time, "sleep", side_effect=self.advance_gpu), \
                patch.object(guard.time, "monotonic_ns", side_effect=[0, 750000000]):
            result = self.call("finish")
        self.assertEqual(result["stopReason"], "replay_complete")
        self.assertGreater(result["completion"]["after"]["gpuSamples"],
                           result["completion"]["before"]["gpuSamples"])
        self.assertFalse(self.worker.connected)
        self.assertEqual(self.worker.stops, 1)

    def test_finish_records_slow_drain_without_rejecting_healthy_data(self):
        self.arm()
        self.readiness()
        self.call("admit")
        with patch.object(guard.time, "sleep", side_effect=self.advance_gpu), \
                patch.object(guard.time, "monotonic_ns", side_effect=[0, 2100000000]):
            self.call("finish")
        state = self.call("status")
        self.assertEqual(state["stopReason"], "replay_complete")
        self.assertEqual(state["completion"]["drainSeconds"], 2.1)
        self.assertFalse(self.worker.connected)

    def test_finish_rejects_missing_final_gpu_progress(self):
        self.arm()
        self.readiness()
        self.call("admit")
        with patch.object(guard.time, "sleep"), \
                patch.object(guard.time, "monotonic_ns", side_effect=[0, 750000000]):
            with self.assertRaisesRegex(RuntimeError, "not_advancing"):
                self.call("finish")
        self.assertEqual(self.call("status")["stopReason"], "completion_failed")
        self.assertFalse(self.worker.connected)

    def test_finish_cannot_accept_a_replay_that_was_not_admitted(self):
        self.arm()
        with self.assertRaisesRegex(RuntimeError, "not_admitted"):
            self.call("finish")
        self.assertFalse(self.worker.connected)

    def test_finish_preserves_an_existing_deadline_failure(self):
        self.arm()
        self.call("stop", reason="deadline")
        self.assertEqual(self.call("finish")["stopReason"], "deadline")
        self.assertEqual(self.worker.stops, 1)

    def test_wrong_process_or_disconnect_fails_gate(self):
        first = guard.observe(self.worker)
        second = dict(first, pid=99)
        with self.assertRaisesRegex(RuntimeError, "identity"):
            guard.require_gpu_ready(first, second, 17)
        second = dict(first, connected=False)
        with self.assertRaisesRegex(RuntimeError, "connection"):
            guard.require_gpu_ready(first, second, 17)

    def test_deadline_stops_without_status_calls(self):
        self.request["seconds"] = 1
        self.arm()
        time.sleep(1.15)
        receipt = json.loads((self.path / "guard.json").read_text())
        self.assertEqual(receipt["stopReason"], "deadline")
        self.assertFalse(self.worker.connected)
        self.assertEqual(self.worker.stops, 1)
        self.call("stop", reason="too_late")
        self.assertEqual(self.worker.stops, 1)

    def test_no_reconnect_claim_survives_guard_release(self):
        self.arm()
        self.call("stop", reason="replay_complete")
        self.call("release")
        self.worker.connected = True
        self.request["receiptPath"] = str(self.path / "second.json")
        with self.assertRaises(FileExistsError):
            guard.reserve_process(self.request)
        self.assertTrue(self.worker.connected)

    def test_owner_and_release_guards(self):
        self.arm()
        with self.assertRaisesRegex(RuntimeError, "stop_capture"):
            self.call("release")
        with self.assertRaisesRegex(RuntimeError, "owner_mismatch"):
            guard.dispatch(self.worker, self.tracy, {"owner": "other", "action": "stop"})
        self.assertTrue(self.worker.connected)

    def test_disconnect_still_runs_if_receipt_write_fails(self):
        self.arm()
        active = self.tracy._vr_replay_guards["test"]
        def fail(): raise OSError("disk unavailable")
        active.persist = fail
        result = self.call("stop", reason="failure")
        self.assertFalse(self.worker.connected)
        self.assertEqual(result["persistenceError"], "disk unavailable")

    def test_namespace_clear_releases_worker_despite_function_cycle(self):
        worker = Worker()
        reference = weakref.ref(worker)
        namespace = {"ctx": worker, "tracy": self.tracy}
        # Model the reference cycle produced by a function defined in MCP eval.
        exec("def hold(): return ctx\n", namespace)
        exec(guard.CLEANUP_EVAL, namespace)
        del worker
        self.assertIsNone(reference())
        self.assertEqual(namespace, {})

    def test_generated_eval_clears_namespace_on_exception(self):
        namespace = {"ctx": self.worker, "tracy": self.tracy}
        code = guard.eval_code(HELPER, {"owner": "absent", "action": "status"})
        with self.assertRaisesRegex(RuntimeError, "owner_mismatch"):
            exec(code, namespace)
        self.assertEqual(namespace, {})

    def test_quantiles_and_missing_data(self):
        result = guard.summarize_ns([1000000, 2000000, 3000000, 4000000])
        self.assertEqual(result["meanMs"], 2.5)
        self.assertEqual(result["medianMs"], 2.5)
        self.assertAlmostEqual(result["p95Ms"], 3.85)
        self.assertAlmostEqual(result["p99Ms"], 3.97)
        self.assertIsNone(guard.summarize_ns([])["p99Ms"])
        with self.assertRaises(ValueError): guard.summarize_ns([0])

    def test_export_frame_timing_keeps_complete_raw_samples_and_window_stats(self):
        worker = TimingWorker()
        result = guard.export_frame_timing(worker, self.path, 2000000, 4000000)
        summary = json.loads(Path(result["summaryPath"]).read_text(encoding="utf-8"))
        with Path(result["samplesPath"]).open(newline="", encoding="utf-8") as source:
            rows = list(csv.DictReader(source))
        self.assertEqual(result["missingRequired"], [])
        self.assertEqual(result["requiredNotEmitted"], [])
        self.assertEqual(result["requiredOutsideWindow"], [])
        self.assertEqual(result["sourceCountMismatches"], [])
        self.assertEqual(summary["series"]["VR::PoseToSubmitMs"]["selected"]["p99"], 1.99)
        self.assertEqual(summary["series"]["VR::OpenVRCpuFrameMs"]["unit"], "ms")
        self.assertEqual(summary["series"]["VR::ReprojectionFlags"]["unit"], "flags")
        self.assertEqual(summary["series"]["Game::MainUpdateCpu"]["selected"]["count"], 1)
        self.assertEqual(summary["series"]["VR::AdditionalMetric"]["unit"], "native")
        self.assertEqual(result["rawRows"], len(rows))
        self.assertEqual(result["samplesSha256"], hashlib.sha256(
            Path(result["samplesPath"]).read_bytes()).hexdigest())
        self.assertEqual(summary["series"]["VR::PoseToSubmitMs"]["selectedMaxGapNs"],
                         1000000)
        self.assertGreater(worker.plot_limit, 2)
        self.assertGreater(worker.cpu_limit, 2)
        with self.assertRaises(FileExistsError):
            guard.export_frame_timing(worker, self.path)

    def test_export_frame_timing_rejects_truncated_plot_without_publication(self):
        worker = TimingWorker()
        worker.plots["VR::PoseToSubmitMs"] = [(2000000, 1.0), (3000000, 2.0)]
        original = worker.get_plot_samples
        worker.get_plot_samples = lambda name, max_samples: (
            original(name, max_samples)[:1] if name == "VR::PoseToSubmitMs"
            else original(name, max_samples))
        with self.assertRaisesRegex(RuntimeError, "plot_export_count_mismatch"):
            guard.export_frame_timing(worker, self.path)
        self.assertFalse((self.path / "tracy-frame-timing-samples.csv").exists())
        self.assertFalse((self.path / "tracy-frame-timing-summary.json").exists())

    def test_export_frame_timing_hash_failure_leaves_no_published_files(self):
        worker = TimingWorker()
        with patch.object(guard, "_sha256_file", side_effect=OSError("hash failed")):
            with self.assertRaisesRegex(OSError, "hash failed"):
                guard.export_frame_timing(worker, self.path)
        self.assertFalse((self.path / "tracy-frame-timing-samples.csv").exists())
        self.assertFalse((self.path / "tracy-frame-timing-summary.json").exists())
        self.assertFalse(list(self.path.glob(".tracy-frame-timing-*.tmp")))
        self.assertGreater(guard.export_frame_timing(worker, self.path)["rawRows"], 0)

    def test_export_frame_timing_marks_conditional_plots_without_fake_zero(self):
        worker = TimingWorker()
        del worker.plots["VR::AppPostSubmitGpuMs"]
        del worker.plots["VR::CompositorRenderCpuMs"]
        result = guard.export_frame_timing(worker, self.path)
        self.assertIn("VR::AppPostSubmitGpuMs", result["plotsNotEmitted"])
        self.assertNotIn("VR::AppPostSubmitGpuMs", result["missingRequired"])
        self.assertIn("VR::CompositorRenderCpuMs", result["plotsNotEmitted"])
        self.assertNotIn("VR::CompositorRenderCpuMs", result["missingRequired"])
        summary = json.loads(Path(result["summaryPath"]).read_text(encoding="utf-8"))
        self.assertEqual(summary["series"]["Tracy::FrameInterval"]["selected"]["count"], 2)

    def test_export_frame_timing_preserves_reported_zero(self):
        worker = TimingWorker()
        worker.plots["VR::CompositorRenderGpuMs"] = [(2000000, 0.0), (3000000, 0.0)]
        result = guard.export_frame_timing(worker, self.path, 2000000, 4000000)
        summary = json.loads(Path(result["summaryPath"]).read_text(encoding="utf-8"))
        series = summary["series"]["VR::CompositorRenderGpuMs"]
        self.assertEqual(series["selected"]["count"], 2)
        self.assertEqual(series["selected"]["mean"], 0.0)
        self.assertEqual(series["availability"], "selected")

    def test_export_frame_timing_distinguishes_absent_zone_and_window_gap(self):
        worker = TimingWorker()
        worker.get_all_gpu_zone_stats = lambda: {}
        worker.get_gpu_zone_occurrences = lambda *_: []
        result = guard.export_frame_timing(worker, self.path, 2200000, 2800000)
        self.assertEqual(result["requiredNotEmitted"], ["Game::MainUpdateD3D11"])
        self.assertEqual(result["requiredOutsideWindow"], ["Tracy::FrameInterval"])
        self.assertIn("VR::PoseToSubmitMs", result["plotsOutsideWindow"])
        self.assertEqual(set(result["missingRequired"]), {
            "Tracy::FrameInterval", "Game::MainUpdateD3D11"})
        summary = json.loads(Path(result["summaryPath"]).read_text(encoding="utf-8"))
        self.assertEqual(summary["series"]["Game::MainUpdateD3D11"]["availability"],
                         "not_emitted")
        self.assertEqual(summary["series"]["Tracy::FrameInterval"]["availability"],
                         "outside_window")

    def test_frame_timing_eval_exports_and_releases_namespace(self):
        namespace = {"ctx": TimingWorker()}
        output = StringIO()
        code = guard.frame_timing_eval_code(HELPER, self.path, 2000000, 4000000)
        with redirect_stdout(output):
            exec(code, namespace)
        self.assertEqual(namespace, {})
        receipt = json.loads(output.getvalue())
        self.assertEqual(receipt["missingRequired"], [])
        self.assertTrue(Path(receipt["samplesPath"]).is_file())

    def test_packaged_helper_and_protocol_match_source(self):
        for relative in ("tools/devbench-control/tracy_replay_guard.py",
                         "tools/devbench-control/tracy-replay-runner.js",
                         "tools/devbench-control/tracy-replay.md",
                         "skills/devbench-control/SKILL.md"):
            self.assertEqual((ROOT / relative).read_bytes(),
                             (ROOT / "plugins/skyrim-vr-automation" / relative).read_bytes())


if __name__ == "__main__":
    unittest.main(verbosity=2)
