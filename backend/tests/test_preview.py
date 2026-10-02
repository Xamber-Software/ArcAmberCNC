"""Public preview adapter tests and real RS274 integration when installed."""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from bettercnc_preview import parse_program


def status_stub():
    # Only the read-only NML initializer is replaced; integration tests below
    # still execute the actual RS274 extension and native arc interpolation.
    return SimpleNamespace(poll=lambda: None)


class PreviewTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.path = self.directory / "test.ngc"
        self.path.write_text("G21\nG0 X0\nG1 X10 F100\nM2\n", encoding="utf-8")

    def fake_interpreter(self, callback):
        def parse(path, canon, initcodes):
            self.assertEqual(Path(path), self.path.resolve())
            canon.comment(initcodes[-1][1:-1])
            canon.next_line(SimpleNamespace(sequence_number=2))
            return callback(canon)

        return SimpleNamespace(parse=parse, MIN_ERROR=5, strerror=lambda code: "RS274 error")

    def test_canonical_units_offsets_rotation_and_line_numbers(self):
        def moves(canon):
            canon.set_g5x_offset(1, *([1.0, 2.0, 0.0] + [0.0] * 6))
            canon.set_g92_offset(*([1.0, 0.0, 0.0] + [0.0] * 6))
            canon.set_xy_rotation(90)
            canon.straight_traverse(*([0.0] * 9))
            canon.next_line(SimpleNamespace(sequence_number=3))
            canon.straight_feed(*([1.0] + [0.0] * 8))
            return 0, 4

        with patch.dict(sys.modules, {"gcode": self.fake_interpreter(moves)}):
            result = parse_program(str(self.path), {}, status_factory=status_stub)
        self.assertNotIn("error", result)
        self.assertEqual(result["units"], "mm")
        self.assertEqual(len(result["segments"]), 1)
        self.assertEqual(result["segments"][0]["line"], 3)
        for actual, expected in zip(result["segments"][0]["end"], [25.4, 101.6, 0], strict=True):
            self.assertAlmostEqual(actual, expected)
        self.assertTrue(result["warnings"])  # No invented origin-to-first-position line.

    def test_parameter_file_and_environment_are_isolated(self):
        source = self.directory / "machine.var"
        original = "5220 1\n5221 42\n"
        source.write_text(original, encoding="utf-8")
        cwd = Path.cwd()
        old_ini = os.environ.get("INI_FILE_NAME")

        def parse(canon):
            copy = Path(canon.parameter_file)
            self.assertNotEqual(copy, source)
            self.assertIn("5221 42", copy.read_text())
            self.assertEqual(copy.parent.resolve(), Path.cwd())
            self.assertNotEqual(os.environ["INI_FILE_NAME"], old_ini)
            copy.write_text("5220 2\n5221 999\n", encoding="utf-8")
            return 0, 4

        with patch.dict(sys.modules, {"gcode": self.fake_interpreter(parse)}):
            result = parse_program(
                str(self.path), {"parameterFile": str(source)}, status_factory=status_stub
            )
        self.assertNotIn("error", result)
        self.assertEqual(source.read_text(), original)
        self.assertEqual(Path.cwd(), cwd)
        self.assertEqual(os.environ.get("INI_FILE_NAME"), old_ini)

    def test_segment_limit_reports_incomplete_prefix(self):
        def moves(canon):
            for x in range(1, 5):
                canon.straight_feed(float(x), *([0.0] * 8))
            return 0, 4

        with patch.dict(sys.modules, {"gcode": self.fake_interpreter(moves)}):
            result = parse_program(
                str(self.path),
                {"actualPosition": [0.0] * 9, "maxSegments": 2},
                status_factory=status_stub,
            )
        self.assertEqual(len(result["segments"]), 2)
        self.assertTrue(result["truncated"])
        self.assertIn("不完整", result["error"]["message"])

    def test_interpreter_error_line_is_not_lookahead_line(self):
        def failure(canon):
            canon.next_line(SimpleNamespace(sequence_number=3))
            return 10, 4

        with patch.dict(sys.modules, {"gcode": self.fake_interpreter(failure)}):
            result = parse_program(str(self.path), {}, status_factory=status_stub)
        self.assertEqual(result["error"], {"message": "RS274 error", "line": 3})

    def test_interpreter_unavailable_is_explicit(self):
        with patch.dict(sys.modules, {"gcode": None}):
            result = parse_program(str(self.path), {}, status_factory=status_stub)
        self.assertEqual(result["segments"], [])
        self.assertIn("解释器不可用", result["error"]["message"])

    def test_machine_python_remaps_are_not_executed_by_preview(self):
        ini = self.directory / "machine.ini"
        ini.write_text("[RS274NGC]\nREMAP = M6 python=change_tool\n", encoding="utf-8")
        fake = self.fake_interpreter(lambda canon: self.fail("Remap interpreter must not execute"))
        with patch.dict(sys.modules, {"gcode": fake}):
            result = parse_program(
                str(self.path), {"iniPath": str(ini)}, status_factory=status_stub
            )
        self.assertIn("REMAP", result["error"]["message"])

    def test_missing_tooldata_initialization_is_an_error_before_interpretation(self):
        def unavailable():
            raise RuntimeError("stat unavailable")

        fake = self.fake_interpreter(
            lambda canon: self.fail("Uninitialized tooldata must not execute")
        )
        with patch.dict(sys.modules, {"gcode": fake}):
            result = parse_program(str(self.path), {}, status_factory=unavailable)
        self.assertEqual(result["segments"], [])
        self.assertIn("只读刀具状态", result["error"]["message"])

    def test_cli_writes_structured_error_without_gcode(self):
        request = self.directory / "request.json"
        output = self.directory / "result.json"
        request.write_text(
            json.dumps({"path": str(self.directory / "missing.ngc")}), encoding="utf-8"
        )
        completed = subprocess.run(
            [
                sys.executable,
                "-m",
                "bettercnc_preview",
                "--request",
                str(request),
                "--output",
                str(output),
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(completed.returncode, 1)
        self.assertIn("error", json.loads(output.read_text(encoding="utf-8")))


@unittest.skipUnless(importlib.util.find_spec("gcode"), "LinuxCNC gcode extension is not installed")
class RealRS274Tests(unittest.TestCase):
    def parse(self, code, **context):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.ngc"
            path.write_text(code, encoding="utf-8")
            return parse_program(
                str(path),
                {"linearUnits": 1.0, "actualPosition": [0.0] * 9, **context},
                status_factory=status_stub,
            )

    def test_metric_arc_and_line_numbers(self):
        result = self.parse("G21 G90\nG0 X10 Y0\nG3 X0 Y10 I-10 J0 F100\nM2\n")
        self.assertNotIn("error", result)
        self.assertGreater(len(result["segments"]), 20)
        self.assertEqual(result["segments"][0]["type"], "rapid")
        self.assertEqual(result["segments"][-1]["line"], 3)
        self.assertAlmostEqual(result["segments"][-1]["end"][1], 10)
        self.assertAlmostEqual(result["bounds"]["max"][0], 10)

    def test_inch_machine_and_g91_start_at_real_position(self):
        result = self.parse(
            "G20 G91\nG1 X1 F10\nM2\n", linearUnits=1 / 25.4, actualPosition=[2.0, 3.0, 0.0]
        )
        self.assertNotIn("error", result)
        self.assertAlmostEqual(result["segments"][0]["start"][0], 50.8)
        self.assertAlmostEqual(result["segments"][0]["end"][0], 76.2)

    def test_g5x_g92_and_rotation_are_machine_space(self):
        result = self.parse(
            "G21 G90\nG0 X0 Y0 Z0\nG1 X10 F100\nM2\n",
            g5xOffset=[100, 200, 30],
            g92Offset=[1, 2, 3],
            rotationXY=90,
        )
        self.assertNotIn("error", result)
        for actual, expected in zip(result["segments"][-1]["end"], [98, 211, 33], strict=True):
            self.assertAlmostEqual(actual, expected)

    def test_g18_and_g19_arcs(self):
        for plane, start, arc, expected in [
            ("G18", "X10 Z0", "X0 Z10 I-10 K0", [0, 0, 10]),
            ("G19", "Y10 Z0", "Y0 Z10 J-10 K0", [0, 0, 10]),
        ]:
            with self.subTest(plane=plane):
                result = self.parse(f"G21 G90 {plane}\nG0 {start}\nG2 {arc} F100\nM2\n")
                self.assertNotIn("error", result)
                self.assertGreater(len(result["segments"]), 20)
                for actual, end in zip(result["segments"][-1]["end"], expected, strict=True):
                    self.assertAlmostEqual(actual, end)

    def test_tool_offset_updates_tip_without_fictitious_motion(self):
        result = self.parse("G21 G90\nG43.1 Z10\nG1 Z5 F100\nM2\n")
        self.assertNotIn("error", result)
        self.assertEqual(len(result["segments"]), 1)
        self.assertAlmostEqual(result["segments"][0]["start"][2], -10)
        self.assertAlmostEqual(result["segments"][0]["end"][2], 5)

    def test_tool_program_without_controller_returns_error_instead_of_crashing(self):
        import linuxcnc

        try:
            status = linuxcnc.stat()
            status.poll()
            status.poll()
        except Exception:
            pass
        else:
            self.skipTest("This regression exercises unavailable tooldata, not a running machine")
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            path, request, output = (
                folder / "tool.ngc",
                folder / "request.json",
                folder / "result.json",
            )
            path.write_text("T1 M6\nG43 H1\nM2\n", encoding="utf-8")
            request.write_text(json.dumps({"path": str(path), "context": {}}), encoding="utf-8")
            completed = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "bettercnc_preview",
                    "--request",
                    str(request),
                    "--output",
                    str(output),
                ],
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(completed.returncode, 1, completed.stderr)
            self.assertIn("只读刀具状态", json.loads(output.read_text())["error"]["message"])

    def test_invalid_gcode_reports_physical_line(self):
        result = self.parse("G21\nG999\nM2\n")
        self.assertIn("error", result)
        self.assertEqual(result["error"]["line"], 2)


if __name__ == "__main__":
    unittest.main()
