"""Public QObject behavior over a real Unix socket, with no controller process."""

import copy
import tempfile
import time
import unittest
from pathlib import Path

from bettercnc.desktop import DesktopBackend
from PySide6.QtCore import QCoreApplication, QObject, QSettings, QUrl
from PySide6.QtGui import QGuiApplication
from PySide6.QtQml import QQmlApplicationEngine
from PySide6.QtTest import QTest
from test_session import Peer

APP = QGuiApplication.instance() or QGuiApplication([])


class DesktopTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cnc-document-", dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.state = {
            "connected": True,
            "powered": True,
            "estop": False,
            "mode": "manual",
            "axes": ["X", "Y", "Z"],
            "actualPosition": [0.0] * 9,
            "commandedPosition": [0.0] * 9,
            "linearUnits": 1,
            "busy": False,
            "file": "",
            "errors": [],
            "capabilities": {},
            "commandState": "idle",
        }
        self.peer = Peer(self.reply)
        self.addCleanup(self.peer.close)
        settings = QSettings(str(Path(self.temporary.name) / "ui.ini"), QSettings.Format.IniFormat)
        self.backend = DesktopBackend(socket_path=self.peer.path, settings=settings)
        self.addCleanup(self.backend.close)
        self.wait(lambda: self.backend.snapshot.get("serviceConnected"))

    def reply(self, request):
        method, params = request["method"], request["params"]
        if method == "session.attach":
            return {}
        if method == "session.status":
            return copy.deepcopy(self.state)
        if method == "command.execute":
            if params["action"] == "file.open":
                self.state["file"] = params["payload"]["path"]
            return {"accepted": True, "snapshot": copy.deepcopy(self.state)}
        if method == "preview.start":
            return {"job_id": "fixture"}
        if method == "preview.read":
            return {
                "done": True,
                "busy": False,
                "units": "mm",
                "next_offset": 1,
                "segments": [{"type": "feed", "start": [0, 0, 0], "end": [1, 2, 0], "line": 2}],
                "bounds": {"min": [0, 0, 0], "max": [1, 2, 0]},
            }
        return {}

    def wait(self, predicate, timeout=3):
        deadline = time.monotonic() + timeout
        while not predicate() and time.monotonic() < deadline:
            QTest.qWait(20)
        self.assertTrue(predicate())

    def actions(self):
        return [
            r["params"]["action"] for r in self.peer.requests if r["method"] == "command.execute"
        ]

    def test_state_is_only_updated_from_service(self):
        self.backend.dispatch("machine.power", {})
        self.wait(lambda: "machine.power" in self.actions())
        self.assertTrue(self.backend.snapshot["powered"])
        self.state["powered"] = False
        self.wait(lambda: not self.backend.snapshot["powered"])

    def test_qml_whole_number_debug_value_uses_protocol_integer(self):
        self.assertTrue(self.backend.dispatch("machine.debug", {"value": 42.0}))
        self.wait(lambda: "machine.debug" in self.actions())
        request = next(r for r in self.peer.requests if r["method"] == "command.execute")
        self.assertIs(type(request["params"]["payload"]["value"]), int)
        self.assertEqual(request["params"]["payload"]["value"], 42)
        self.assertFalse(self.backend.dispatch("machine.debug", {"value": 1.5}))

    def test_existing_tool_table_accepts_linuxcnc_case_and_decimal_syntax(self):
        table = Path(self.temporary.name) / "tool.tbl"
        table.write_text("t1 p1 z2. d6. ; existing tool\n")
        self.state["toolTablePath"] = str(table)
        self.wait(lambda: len(self.backend.toolTable) == 1)
        self.assertEqual(self.backend.toolTable[0]["Z"], 2)
        self.assertEqual(self.backend.toolTableText, table.read_text())

    def test_real_document_and_remote_geometry_are_bound_to_public_properties(self):
        program = (Path(self.temporary.name) / "part.ngc").resolve()
        program.write_text("G21\nG1 X1 Y2 F100\nM2\n")
        self.assertTrue(self.backend.openProgram(str(program)))
        self.wait(lambda: not self.backend.program.previewBusy)
        self.assertEqual(self.backend.program.lines[1], "G1 X1 Y2 F100")
        self.assertEqual(self.backend.program.segments[0]["end"], [1, 2, 0])
        self.assertEqual(self.backend.program.previewError, "")
        self.wait(lambda: self.backend.snapshot.get("file") == str(program))

    def test_ui_freeze_stops_jog_instead_of_renewing_it_in_worker(self):
        QTest.qWait(180)
        self.backend.dispatch("jog.start", {"axis": "X", "direction": 1, "velocity": 1})
        self.wait(lambda: "jog.start" in self.actions())
        self.wait(lambda: any(r["params"].get("jog_lease") for r in self.peer.requests))
        # Deliberately stop the GUI event loop while the socket worker continues.
        time.sleep(0.65)
        self.assertIn("jog.stop", self.actions())

    def test_busy_program_cannot_be_overwritten(self):
        program = Path(self.temporary.name) / "busy.ngc"
        program.write_text("M2\n")
        self.state["busy"] = True
        self.wait(lambda: self.backend.snapshot.get("busy"))
        self.assertFalse(self.backend.saveProgram(str(program), "G0 X100\n"))
        self.assertEqual(program.read_text(), "M2\n")

    def test_service_reachable_does_not_mean_machine_connected(self):
        self.state["connected"] = False
        self.state["powered"] = False
        self.state["axes"] = []
        self.state["actualPosition"] = None
        self.wait(lambda: not self.backend.snapshot["connected"])
        self.assertTrue(self.backend.snapshot["serviceConnected"])
        self.assertIsNone(self.backend.snapshot["actualPosition"])

    def test_edit_is_sent_to_service_without_locally_overwriting_the_program(self):
        program = (Path(self.temporary.name) / "service-owned.ngc").resolve()
        program.write_text("M2\n")
        original = self.peer.responder

        def reject_edit(request):
            if request["method"] == "command.execute":
                return {"accepted": False, "snapshot": copy.deepcopy(self.state)}
            return original(request)

        self.peer.responder = reject_edit
        self.assertTrue(self.backend.saveProgram(str(program), "G0 X100\n"))
        self.wait(lambda: "file.save" in self.actions())
        self.assertEqual(program.read_text(), "M2\n")
        self.assertNotIn("file.open", self.actions())

    def test_offline_editor_cannot_replace_a_machine_file(self):
        program = Path(self.temporary.name) / "offline.ngc"
        program.write_text("M2\n")
        self.state["connected"] = False
        self.wait(lambda: not self.backend.snapshot["connected"])
        self.assertFalse(self.backend.saveProgram(str(program), "G0 X100\n"))
        self.assertEqual(program.read_text(), "M2\n")

    def test_history_clipboard_paste_never_executes_commands(self):
        APP.clipboard().setText("G0 X10\nM3 S1000")
        self.backend.dispatch("mdi.paste", {})
        QTest.qWait(200)
        self.assertEqual(self.backend.history, ["G0 X10", "M3 S1000"])
        self.assertNotIn("mdi.execute", self.actions())

    def test_real_qobject_notifications_update_the_qml_geometry(self):
        qml = Path(__file__).resolve().parents[2] / "qml"
        engine = QQmlApplicationEngine()
        warnings = []
        engine.warnings.connect(
            lambda items: warnings.extend(str(item.toString()) for item in items)
        )
        engine.addImportPath(str(qml))
        engine.setInitialProperties({"backend": self.backend})
        engine.load(QUrl.fromLocalFile(str(qml / "Main.qml")))
        try:
            self.assertTrue(engine.rootObjects())
            window = engine.rootObjects()[0]
            canvas = window.findChild(QObject, "toolpathCanvas")
            self.assertIsNotNone(canvas)
            program = (Path(self.temporary.name) / "qobject.ngc").resolve()
            program.write_text("G21\nG1 X1 Y2 F100\nM2\n")
            self.assertTrue(self.backend.openProgram(str(program)))
            self.wait(lambda: not self.backend.program.previewBusy)

            def geometry():
                value = canvas.property("geometry")
                return value.toVariant() if hasattr(value, "toVariant") else value

            self.wait(lambda: len(geometry()) == 1)
            self.assertEqual(geometry()[0]["end"], [1, 2, 0])
            problems = [
                w
                for w in warnings
                if any(
                    text in w
                    for text in ("ReferenceError", "TypeError", "Unable to assign", "Binding loop")
                )
            ]
            self.assertEqual(problems, [])
        finally:
            for window in engine.rootObjects():
                window.setProperty("visible", False)
            engine.deleteLater()
            QCoreApplication.sendPostedEvents()


if __name__ == "__main__":
    unittest.main()
