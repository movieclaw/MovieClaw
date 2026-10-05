import tempfile
import unittest
from pathlib import Path

from mac_performance_report import hitch_summary, input_summary, resource_summary
from mac_resource_sample import cpu_percent


class PerformanceReportTests(unittest.TestCase):
    def test_one_cpu_second_uses_the_machine_timebase(self):
        self.assertEqual(cpu_percent(24_000_000, 1_000_000_000, 125, 3), 100)
        self.assertEqual(cpu_percent(1_000_000_000, 1_000_000_000, 1, 1), 100)

    def test_legacy_resource_samples_cannot_pass_cpu_acceptance(self):
        sample = {"cpu_percent": .01, "footprint_mb": 200}
        self.assertIsNone(resource_summary([sample])["cpu_average_percent"])
        sample["cpu_timebase"] = [125, 3]
        self.assertEqual(resource_summary([sample])["cpu_average_percent"], .01)

    def test_missing_input_samples_are_not_reported_as_zero_latency(self):
        self.assertIsNone(input_summary([])["p95_ms"])

    def test_latency_includes_event_queue_wait_and_uses_tail_percentiles(self):
        events = [{"ev": "input.commit", "start": 100, "t": 100 + i} for i in range(1, 101)]
        summary = input_summary(events)
        self.assertEqual(summary["p95_ms"], 95)
        self.assertEqual(summary["p99_ms"], 99)

    def test_hitch_export_references_and_other_processes(self):
        xml = '''<trace-query-result><node>
        <row><start-time>0</start-time><duration id="d">2000000</duration>
        <process id="p"><pid>42</pid></process></row>
        <row><start-time>1</start-time><duration ref="d"/><process ref="p"/></row>
        <row><start-time>2</start-time><duration>999000000</duration>
        <process><pid>43</pid></process></row>
        </node></trace-query-result>'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "hitches.xml"
            path.write_text(xml)
            summary = hitch_summary(path, 42, 2)
        self.assertEqual(summary["count"], 2)
        self.assertEqual(summary["ratio_ms_per_s"], 2)
        self.assertEqual(summary["max_ms"], 2)

    def test_event_queue_wait_is_separate_from_work_after_delivery(self):
        summary = input_summary([{"ev": "input.commit", "start": 10, "received": 90, "t": 100}])
        self.assertEqual(summary["p95_ms"], 90)
        self.assertEqual(summary["queue_p95_ms"], 80)
        self.assertEqual(summary["after_delivery_p95_ms"], 10)


if __name__ == "__main__":
    unittest.main()
