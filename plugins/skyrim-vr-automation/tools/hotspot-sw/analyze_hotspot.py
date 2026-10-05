"""Identify stationary hotspot windows from preserved DevBench recording-3 data."""
import argparse
import csv
import datetime as dt
import hashlib
import json
import math
from pathlib import Path

POLICY = {
    "poseIntervalMs": 100, "maximumGapMs": 350, "minimumPauseMs": 2000,
    "comparisonPauseMs": 20000, "tailMs": 10000, "playerRadiusUnits": 4.0,
    "headRadiusMetres": 0.03, "headAngleDegrees": 3.0,
    "playerAngleDegrees": 3.0, "maximumClockUncertaintyMs": 500,
}


def archived(run, name):
    receipt = json.loads((run / name).read_text(encoding="utf-8-sig"))
    path = Path(receipt["archivePath"])
    data = path.read_bytes()
    if len(data) != receipt["byteLength"] or hashlib.sha256(data).hexdigest().upper() != receipt["sha256"].upper():
        raise ValueError(f"Archived evidence changed: {path}")
    return data


def finite(values):
    return all(isinstance(v, (float, int)) and not isinstance(v, bool) and math.isfinite(v) for v in values)


def distance(a, b):
    return math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)))


def angle(a, b):
    # Rotation matrices are OpenVR row-major 3x4.
    indices = (0, 1, 2, 4, 5, 6, 8, 9, 10)
    return math.degrees(math.acos(max(-1, min(1, (sum(a[i] * b[i] for i in indices) - 1) / 2))))


def rotation_valid(matrix):
    rows = [matrix[i:i+3] for i in (0, 4, 8)]
    if any(abs(sum(v*v for v in row) - 1) > .02 for row in rows):
        return False
    return all(abs(sum(a*b for a, b in zip(rows[i], rows[j]))) < .02
               for i, j in ((0, 1), (0, 2), (1, 2)))


def circular_delta(a, b):
    return abs((a - b + 180) % 360 - 180)


def pose_samples(recording):
    meta = recording["meta"]
    if meta["format"] != "devbench-recording-3":
        raise ValueError("Unsupported recording format")
    for name in ("poseCapture", "trackingCapture"):
        if meta[name]["version"]["major"] != 2:
            raise ValueError(f"Unsupported {name} schema")
    tracking = {sample["tMs"]: sample for sample in recording["trackingSamples"]}
    events = sorted(recording["activityEvents"], key=lambda e: e["tMs"])
    event_index = 0
    menus = set(meta.get("openMenusAtStart", []))
    pose = None
    previous = -1
    samples = []
    scene_epoch = 0
    for step in recording["steps"]:
        if "wait" not in step or "atMs" not in step:
            continue
        t = step["atMs"]
        if not finite([t]) or t <= previous:
            raise ValueError("Non-monotonic pose timestamps")
        previous = t
        if "pose" in step:
            pose = step["pose"]
        while event_index < len(events) and events[event_index]["tMs"] <= t:
            event = events[event_index]
            if event.get("kind") == "menu":
                if event["opening"]:
                    menus.add(event["name"])
                else:
                    menus.discard(event["name"])
            elif event.get("kind") in ("cell", "lifecycle"):
                scene_epoch += 1
            event_index += 1
        track = tracking.get(t)
        valid = pose is not None and len(pose) == 5 and finite(pose)
        valid = valid and not (menus - {"HUD Menu", "HUDMenu"})
        hmd = track.get("hmd", {}) if track else {}
        matrix = hmd.get("matrix", [])
        valid = valid and hmd.get("valid") is True and hmd.get("connected") is True
        valid = valid and len(matrix) == 12 and finite(matrix) and rotation_valid(matrix)
        samples.append({"tMs": t, "valid": bool(valid), "pose": pose,
                        "matrix": matrix, "frame": track.get("frame") if track else None,
                        "origin": track.get("originCode") if track else None, "sceneEpoch": scene_epoch})
    return samples


def pauses(samples):
    result = []
    group = []
    def finish():
        if not group:
            return
        duration = group[-1]["tMs"] - group[0]["tMs"]
        if duration < POLICY["minimumPauseMs"]:
            return
        first = group[0]
        result.append({"startMs": first["tMs"], "endMs": group[-1]["tMs"],
                       "durationMs": duration, "confirmedAtMs": first["tMs"] + POLICY["minimumPauseMs"],
                       "comparisonEligible": duration >= POLICY["comparisonPauseMs"],
                       "playerPosition": first["pose"][:3], "playerYawPitchDegrees": first["pose"][3:],
                       "hmdTrackingMatrix": first["matrix"], "trackingOrigin": first["origin"],
                       "sceneEpoch": first["sceneEpoch"], "sampleCount": len(group)})
    for sample in samples:
        if not sample["valid"]:
            finish(); group = []
            continue
        if group:
            first, previous = group[0], group[-1]
            head_a = [first["matrix"][i] for i in (3, 7, 11)]
            head_b = [sample["matrix"][i] for i in (3, 7, 11)]
            compatible = (
                sample["tMs"] - previous["tMs"] <= POLICY["maximumGapMs"]
                and sample["frame"] is not None and sample["frame"] > previous["frame"]
                and sample["origin"] == first["origin"] and sample["sceneEpoch"] == first["sceneEpoch"]
                and distance(first["pose"][:3], sample["pose"][:3]) <= POLICY["playerRadiusUnits"]
                and distance(head_a, head_b) <= POLICY["headRadiusMetres"]
                and angle(first["matrix"], sample["matrix"]) <= POLICY["headAngleDegrees"]
                and all(circular_delta(a,b) <= POLICY["playerAngleDegrees"]
                        for a,b in zip(first["pose"][3:],sample["pose"][3:]))
            )
            if not compatible:
                finish(); group = []
        group.append(sample)
    finish()
    return result


def clock_bounds(markers, correlation):
    anchors = [m for m in markers if m["label"] == "record-clock"
               and m["detail"]["correlationId"] == correlation]
    if not anchors:
        raise ValueError("No correlated pose/QPC clock anchors")
    frequencies = {m["qpcFrequency"] for m in anchors}
    if len(frequencies) != 1 or next(iter(frequencies)) <= 0:
        raise ValueError("Inconsistent QPC frequency")
    frequency = next(iter(frequencies))
    lower = max(m["detail"]["beginQpc"] - (m["detail"]["elapsedMs"] + 1)*frequency/1000 for m in anchors)
    upper = min(m["detail"]["endQpc"] - m["detail"]["elapsedMs"]*frequency/1000 for m in anchors)
    if upper < lower or (upper-lower)*1000/frequency > POLICY["maximumClockUncertaintyMs"]:
        raise ValueError("Pose clock anchors disagree or are too uncertain")
    return lower, upper, frequency


def analyze(run):
    state = json.loads((run / "hotspot-sw.json").read_text(encoding="utf-8-sig"))
    if state["schema"] != "hotspot-sw-v1":
        raise ValueError("Unknown hotspot protocol")
    recording = json.loads(archived(run, "pose-archive.json"))
    markers = [json.loads(line) for line in (run / "markers.jsonl").read_text(encoding="utf-8-sig").splitlines() if line.strip()]
    interaction = json.loads((run / "interaction/capture-interaction.session.json").read_text(encoding="utf-8-sig"))
    correlation = recording["meta"]["correlationId"]
    if correlation != interaction["sessionId"]:
        raise ValueError("Recording belongs to another session")
    lower, upper, frequency = clock_bounds(markers, correlation)
    utc_anchors = [(dt.datetime.fromisoformat(m["utc"].replace("Z","+00:00")).timestamp() - m["qpc"]/frequency)
                   for m in markers if m["qpcFrequency"] == frequency]
    if max(utc_anchors)-min(utc_anchors) > .1:
        raise ValueError("Wall clock changed; fpsVR/pose UTC alignment unavailable")
    utc_offset = sum(utc_anchors)/len(utc_anchors)
    measurement_end = next(m["qpc"] for m in reversed(markers) if m["label"] == "measurement-end")
    samples = [sample for sample in pose_samples(recording)
               if upper + sample["tMs"]*frequency/1000 <= measurement_end]
    result = pauses(samples)
    poll_intervals = []
    requests = {}
    for marker in markers:
        label = marker["label"]
        if label.endswith("-request"):
            requests[label[:-8]] = marker["qpc"]
        if label.endswith("-response") and label[:-9] in requests:
            poll_intervals.append((requests[label[:-9]], marker["qpc"], label[:-9]))
    windows = []
    for index, pause in enumerate(result, 1):
        pause["id"] = index
        pause["startQpcLower"] = lower + pause["startMs"]*frequency/1000
        pause["endQpcUpper"] = upper + pause["endMs"]*frequency/1000
        if pause["endQpcUpper"] > measurement_end:
            pause["comparisonEligible"] = False
            pause["ineligibleReason"] = "pause overlaps measurement stop/cleanup"
        if pause["comparisonEligible"]:
            # Conservative interior: full window stays inside the pause for every clock anchor.
            end = lower + pause["endMs"]*frequency/1000
            start = end - POLICY["tailMs"]*frequency/1000
            utc = lambda value: dt.datetime.fromtimestamp(value/frequency + utc_offset, dt.timezone.utc).isoformat()
            windows.append({"pause": index, "startQpc": int(start), "endQpc": int(end),
                            "startUtc": utc(start), "endUtc": utc(end), "qpcFrequency": frequency})
            pause["pollIntervalsInTail"] = [label for a,b,label in poll_intervals if a < end and b > start]
            pause["telemetryFilesInPause"] = [
                m["label"][:-9]+".json" for m in markers
                if m["label"].startswith("health-") and m["label"].endswith("-response")
                and pause["startQpcLower"] <= m["qpc"] <= pause["endQpcUpper"]]
    with (run / "hotspot-route.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.writer(stream)
        writer.writerow(["recordMs", "qpcLower", "qpcUpper", "valid", "frame",
                         "playerX", "playerY", "playerZ", "playerYaw", "playerPitch",
                         "hmdTrackingMatrix", "trackingOrigin"])
        for sample in samples:
            writer.writerow([sample["tMs"], lower + sample["tMs"]*frequency/1000,
                             upper + sample["tMs"]*frequency/1000, sample["valid"],
                             sample["frame"], *(sample["pose"] or [None]*5),
                             json.dumps(sample["matrix"]), sample["origin"]])
    trace = run / "stack-wait/trace-result.json"
    trace_summary = json.loads(trace.read_text(encoding="utf-8-sig")) if trace.exists() else {"state":"pending"}
    if trace.exists():
        if trace_summary.get("schema") != "csx-stack-wait-trace-v1" or trace_summary.get("instance") != state["runId"]:
            raise ValueError("WPR trace receipt belongs to another run or schema")
    for window in windows:
        window["wprCaptured"] = (
            trace_summary.get("state") == "stopped" and not trace_summary.get("errors")
            and trace_summary.get("qpcFrequency") == frequency
            and trace_summary.get("startedQpc", math.inf) <= window["startQpc"]
            and trace_summary.get("stopRequestedQpc", -math.inf) >= window["endQpc"]
        )
    report = {"schema":"hotspot-sw-segments-v1", "policy":POLICY, "run":state,
              "clockOriginQpcBounds":[lower,upper], "clockUncertaintyMs":(upper-lower)*1000/frequency,
              "recordingLimited":recording["meta"].get("limitReached"),
              "invalidPoseSamples":sum(not s["valid"] for s in samples),
              "pauses":result, "windows":windows, "trace":trace_summary,
              "limitations":[
                  "Stationary is a pose classification, not proof of render settling or absence of CPU work.",
                  "Player/world units and HMD tracking metres are retained separately; exact rendered-eye world pose is unavailable.",
                  "CPU stack/wait and GPU pass attribution remain pending; capture does not prove a cause.",
                  "Telemetry counters require matching collection generation and conservative snapshot boundaries; no per-eye inference.",
                  "Raw frames during walking, menus, gaps and short pauses remain preserved; they are excluded from pause means."
              ]}
    (run / "hotspot-segments.json").write_text(json.dumps(report,indent=2),encoding="utf-8")
    with (run / "hotspot-windows.csv").open("w",newline="",encoding="utf-8") as stream:
        writer=csv.DictWriter(stream,fieldnames=["pause","startQpc","endQpc","startUtc","endUtc","qpcFrequency","wprCaptured"])
        writer.writeheader(); writer.writerows(windows)
    print(f"Found {len(result)} pauses; {len(windows)} have comparable final-10-second windows.")
    print(f"Clock uncertainty: {(upper-lower)*1000/frequency:.1f} ms; WPR: {trace_summary['state']}.")
    print(run / "hotspot-segments.json")
    return report


if __name__ == "__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("--run-directory",required=True,type=Path)
    args=parser.parse_args()
    analyze(args.run_directory)
