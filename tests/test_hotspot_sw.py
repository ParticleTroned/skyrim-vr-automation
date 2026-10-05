import importlib.util
import math
import datetime as dt
import hashlib
import json
import tempfile
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location("hotspot",Path(__file__).resolve().parents[1]/"tools/hotspot-sw/analyze_hotspot.py")
hotspot=importlib.util.module_from_spec(spec)
spec.loader.exec_module(hotspot)


def sample(t,x=0,yaw=0):
    angle=math.radians(yaw)
    return {"tMs":t,"valid":True,"pose":[x,0,0,0,0],
            "matrix":[math.cos(angle),0,math.sin(angle),0,0,1,0,1.6,-math.sin(angle),0,math.cos(angle),0],
            "frame":t+1,"origin":1,"sceneEpoch":0}


class SegmentationTests(unittest.TestCase):
    def test_stationary_noise_and_final_window(self):
        rows=[sample(t,.5*math.sin(t),.5*math.cos(t)) for t in range(0,25100,100)]
        pauses=hotspot.pauses(rows)
        self.assertEqual(len(pauses),1)
        self.assertTrue(pauses[0]["comparisonEligible"])
        self.assertEqual(pauses[0]["confirmedAtMs"],2000)

    def test_slow_drift_never_stationary_long_window(self):
        self.assertFalse(any(p["comparisonEligible"] for p in hotspot.pauses([sample(t,t/1000) for t in range(30100)[::100]])))

    def test_turn_splits_view_at_same_position(self):
        result=hotspot.pauses([sample(t,yaw=0 if t<22000 else 30) for t in range(45100)[::100]])
        self.assertEqual(len(result),2)
        self.assertTrue(all(p["comparisonEligible"] for p in result))

    def test_gaps_and_invalid_tracking_split(self):
        rows=[sample(t) for t in range(30100)[::100]]
        rows=[r for r in rows if not 10000<r["tMs"]<12000]
        rows[150]["valid"]=False
        self.assertEqual(len(hotspot.pauses(rows)),3)

    def test_stale_frames_are_not_quiet(self):
        rows=[sample(t) for t in range(30100)[::100]]
        for row in rows:row["frame"]=10
        self.assertEqual(hotspot.pauses(rows),[])

    def test_origin_and_scene_changes_split(self):
        rows=[sample(t) for t in range(30100)[::100]]
        for row in rows:
            row["origin"]=1 if row["tMs"]<10000 else 2
            row["sceneEpoch"]=0 if row["tMs"]<20000 else 1
        self.assertEqual(len(hotspot.pauses(rows)),3)

    def test_short_pause_retained_not_comparable(self):
        p=hotspot.pauses([sample(t) for t in range(5100)[::100]])[0]
        self.assertFalse(p["comparisonEligible"])

    def test_clock_intersection_and_foreign_owner(self):
        markers=[{"label":"record-clock","qpcFrequency":1000,"detail":{"beginQpc":1000,"endQpc":1020,"elapsedMs":100,"correlationId":"own"}},
                 {"label":"record-clock","qpcFrequency":1000,"detail":{"beginQpc":2005,"endQpc":2010,"elapsedMs":1100,"correlationId":"own"}}]
        self.assertEqual(hotspot.clock_bounds(markers,"own"),(904,910,1000))
        with self.assertRaises(ValueError):hotspot.clock_bounds(markers,"foreign")

    def test_future_and_invalid_schema_fail_closed(self):
        for meta in ({"format":"future"},{"format":"devbench-recording-3","poseCapture":{"version":{"major":3}}}):
            with self.assertRaises(ValueError):hotspot.pose_samples({"meta":meta})

    def test_end_to_end_clock_windows_exclude_cleanup(self):
        with tempfile.TemporaryDirectory(prefix="hotspot-test-") as temp:
            run=Path(temp)
            (run/"interaction").mkdir()
            state={"schema":"hotspot-sw-v1","runId":"fixture","state":"captured"}
            (run/"hotspot-sw.json").write_text(json.dumps(state))
            (run/"interaction/capture-interaction.session.json").write_text(json.dumps({"sessionId":"owner"}))
            rec={"meta":{"format":"devbench-recording-3","correlationId":"owner","poseCapture":{"version":{"major":2}},"trackingCapture":{"version":{"major":2}},"limitReached":False},
                 "activityEvents":[],"trackingSamples":[],"steps":[]}
            for t in range(0,31000,100):
                rec["steps"].append({"atMs":t,"wait":100,"pose":[0,0,0,0,0]})
                rec["trackingSamples"].append({"tMs":t,"frame":t+1,"originCode":1,"hmd":{"valid":True,"connected":True,"matrix":sample(t)["matrix"]}})
            raw=json.dumps(rec).encode()
            path=run/"recording.json";path.write_bytes(raw)
            receipt={"archivePath":str(path),"byteLength":len(raw),"sha256":hashlib.sha256(raw).hexdigest()}
            (run/"pose-archive.json").write_text(json.dumps(receipt))
            epoch=dt.datetime(2026,9,19,tzinfo=dt.timezone.utc)
            def marker(label,qpc,detail):
                return {"label":label,"qpc":qpc,"qpcFrequency":1000,"utc":(epoch+dt.timedelta(milliseconds=qpc)).isoformat(),"detail":detail}
            markers=[marker("record-clock",1100,{"beginQpc":1090,"endQpc":1110,"elapsedMs":100,"correlationId":"owner"}),
                     marker("measurement-end",26000,{})]
            (run/"markers.jsonl").write_text("\n".join(json.dumps(m) for m in markers))
            result=hotspot.analyze(run)
            self.assertEqual(len(result["windows"]),1)
            self.assertLessEqual(result["windows"][0]["endQpc"],26000)
            self.assertEqual(result["windows"][0]["endQpc"]-result["windows"][0]["startQpc"],10000)
            self.assertFalse(result["windows"][0]["wprCaptured"])
            self.assertEqual(result["pauses"][0]["durationMs"],24900)

    def test_menu_and_missing_tracking_invalid(self):
        m={"format":"devbench-recording-3","poseCapture":{"version":{"major":2}},"trackingCapture":{"version":{"major":2}},"openMenusAtStart":["Main Menu"]}
        rec={"meta":m,"steps":[{"atMs":100,"wait":100,"pose":[0,0,0,0,0]},{"atMs":200,"wait":100}],
             "activityEvents":[],"trackingSamples":[{"tMs":100,"frame":1,"originCode":1,"hmd":{"valid":True,"connected":True,"matrix":sample(100)["matrix"]}}]}
        self.assertTrue(all(not s["valid"] for s in hotspot.pose_samples(rec)))


if __name__=="__main__":
    unittest.main()
