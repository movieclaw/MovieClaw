import json
import tempfile
import unittest
from pathlib import Path

from mac_scroll_report import combine, pool


def frames(seg, hitch_ms, dur_ms, dropped=0):
    return {"ev": "frames", "seg": seg, "dur_ms": dur_ms, "hitch_ms": hitch_ms, "hitch_ratio": hitch_ms / dur_ms * 1000,
            "dropped": dropped, "period_ms": 8.33, "p95_ms": 9, "p99_ms": 20, "max_ms": 30, "over50": 0, "over100": 0,
            "main_busy_pct": 10, "long_tasks": 1}


class ScrollReportTests(unittest.TestCase):
    def test_runs_pool_by_total_time_not_by_averaging_ratios(self):
        runs = [frames("v", 10, 1000), frames("v", 90, 3000)]
        self.assertAlmostEqual(combine(runs)["hitch_ratio"], 25)

    def test_traces_group_segments_and_skip_other_events(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = []
            for index in range(2):
                path = Path(tmp) / f"run{index}.jsonl"
                lines = [{"ev": "net", "t": 1}, frames("v.fling", 5, 1000), frames("h.poster", 1, 1000)]
                path.write_text("\n".join(json.dumps(line) for line in lines) + "\n")
                paths.append(path)
            pooled = pool(paths)
        self.assertEqual(list(pooled), ["v.fling", "h.poster"])
        self.assertEqual(len(pooled["v.fling"]), 2)

    def test_drop_percentage_uses_the_frame_period(self):
        self.assertAlmostEqual(combine([frames("v", 0, 833, dropped=10)])["drop_pct"], 10, places=1)


if __name__ == "__main__":
    unittest.main()
