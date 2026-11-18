#!/usr/bin/env python3
"""Counterexamples for the suite runner; no real Swift or hardware run."""
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import sys
sys.dont_write_bytecode = True
import unittest

spec = importlib.util.spec_from_file_location("runner", Path(__file__).with_name("suite-summary.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class SuiteRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.log = self.root / "suite.log"

    def summary(self):
        output = io.StringIO()
        with redirect_stdout(output), redirect_stderr(output):
            status = runner.summarize(self.log)
        return status, output.getvalue()

    def stage(self, kind, cases, status=0, xml=True, suffix=""):
        text = "".join(f"Test Case '-[Target.Case {name}]' {result} (0.001 seconds).\n" for name, result in cases)
        stage = self.root / (kind + suffix + ".log")
        stage.write_text(text)
        if xml:
            elements = "".join(f'<testcase classname="Target.Case" name="{name}">' + ('<failure/>' if result == 'failed' else '') + '</testcase>' for name, result in cases)
            # Deliberately mimic SwiftPM: skipped cases have no <skipped/> tag.
            (self.root / (kind + suffix + ".xml")).write_text('<testsuites><testsuite>' + elements + '</testsuite></testsuites>')
        record = dict(kind=kind, status=status, log=stage.name, xml=kind + suffix + ".xml", expected=[f"Target.Case/{name}" for name, _ in cases])
        with self.log.open("a") as log:
            log.write(text + runner.MARKER + json.dumps(record) + "\n")
        return record

    def test_parallel_skip_is_not_a_pass_and_serial_skip_is_not_counted_twice(self):
        self.stage("parallel", [("green", "passed"), ("optional", "skipped")])
        self.stage("timing", [("budget", "passed"), ("optionalBudget", "skipped")])
        status, output = self.summary()
        self.assertEqual(status, 0, output)
        self.assertIn("bestanden:     2", output)
        self.assertIn("uebersprungen: 2", output)

    def test_parallel_failure_survives_later_green_timing_stage(self):
        self.stage("parallel", [("red", "failed")], status=1)
        self.stage("timing", [("budget", "passed")])
        status, output = self.summary()
        self.assertEqual(status, 1)
        self.assertIn("rot:           1", output)
        self.assertIn("bestanden:     1", output)

    def test_exit_without_failed_line_is_not_green(self):
        self.stage("parallel", [("green", "passed")], status=1)
        self.assertEqual(self.summary()[0], 1)

    def test_crash_without_failed_line_is_counted(self):
        self.stage("parallel", [], status=-6, xml=False)
        self.stage("timing", [("budget", "passed")])
        status, output = self.summary()
        self.assertEqual(status, 1)
        self.assertIn("abgestuerzt:   1", output)

    def test_signal_and_fatal_diagnostics_count_one_crash_without_a_build_error(self):
        self.log.write_text("error: Process '/xctest' exited with unexpected signal code 5\nFatal error: synthetic crash\n")
        status, output = self.summary()
        self.assertEqual(status, 1)
        self.assertIn("abgestuerzt:   1", output)
        self.assertIn("baufehler:     0", output)

    def test_missing_or_corrupt_xml_is_not_green(self):
        self.stage("parallel", [("green", "passed")], xml=False)
        self.assertEqual(self.summary()[0], 1)
        (self.root / "parallel.xml").write_text("<broken>")
        self.assertEqual(self.summary()[0], 1)

    def test_missing_or_duplicate_case_is_not_green(self):
        self.stage("parallel", [("green", "passed")])
        stage = self.root / "parallel.log"
        stage.write_text("")
        self.assertEqual(self.summary()[0], 1)
        line = "Test Case '-[Target.Case green]' passed (0.001 seconds).\n"
        stage.write_text(line * 2)
        self.assertEqual(self.summary()[0], 1)

    def test_empty_and_failed_build_remain_red(self):
        self.log.write_text("error: build failed\n")
        status, output = self.summary()
        self.assertEqual(status, 1)
        self.assertIn("baufehler:     1", output)
        self.assertIn("KEIN LAUF", output)

    def test_historical_serial_fixtures(self):
        fixtures = runner.ROOT / "Tests/fixtures/suite-summary"
        for name, expected in [("gruen", 0), ("rot", 1), ("absturz", 1), ("baufehler", 1)]:
            with self.subTest(name=name):
                self.log.write_text((fixtures / (name + ".log")).read_text())
                self.assertEqual(self.summary()[0], expected)

    def test_quick_trigger_and_timing_ownership(self):
        tests = ["Target.Presets/long", "Target.Other/green", "Target.Budget/long"]
        rows = [("long", "Presets/long", ["Sources/PlanariumPresets/**"], "Migration"),
                ("long", "Budget/long", ["Sources/Runtime/**"], "Long"),
                ("timing", "Budget", ["Sources/Runtime/**"], "Time")]
        quick = runner.plan(tests, rows, "quick", [])
        self.assertEqual(quick['omitted'], ["Target.Presets/long"])
        self.assertEqual(quick['timing'], ["Target.Budget/long"])
        touched = runner.plan(tests, rows, "quick", ["Sources/PlanariumPresets/Resources/new.json"])
        self.assertIn("Target.Presets/long", touched['parallel'])
        self.assertEqual(touched['omitted'], [])
        full = runner.plan(tests, rows, "full", [])
        self.assertEqual(set(full['parallel'] + full['timing']), set(tests))
        self.assertFalse(set(full['parallel']) & set(full['timing']))

    def test_later_success_cannot_complete_a_missing_planned_stage(self):
        self.stage("parallel", [("green", "passed")])
        plan = dict(parallel=["Target.Case/green"], timing=["Target.Case/budget"])
        (self.root / "plan.json").write_text(json.dumps(plan))
        with self.log.open("a") as log:
            log.write("SUITE-PLAN plan.json\nSUITE-END Wandzeit: 1 s\n")
        self.assertEqual(self.summary()[0], 1)

    def test_interrupted_run_is_not_green_even_after_parallel_success(self):
        self.stage("parallel", [("green", "passed")])
        (self.root / "plan.json").write_text(json.dumps(dict(parallel=["Target.Case/green"], timing=[])))
        with self.log.open("a") as log:
            log.write("SUITE-PLAN plan.json\n")
        self.assertEqual(self.summary()[0], 1)

    def test_termination_output_without_newline_does_not_hide_a_completed_case(self):
        self.log.write_text("Planarium termination: queuedTest Case '-[Target.Case green]' passed (0.1 seconds).\n")
        status, output = self.summary()
        self.assertEqual(status, 0)
        self.assertIn("bestanden:     1", output)

    def test_stale_profile_filter_fails_instead_of_silently_losing_tests(self):
        with self.assertRaises(ValueError):
            runner.plan(["Target.Case/green"], [("timing", "RemovedTest", ["**"], "Time")], "full", [])


if __name__ == "__main__":
    unittest.main()
