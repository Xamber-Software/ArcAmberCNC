"""Socket IO stays off the GUI thread; only a fresh UI lease keeps jogging."""

import time

from PySide6.QtCore import QObject, QTimer, Signal, Slot

from bettercnc.session import RemoteError, SessionClient


class ControllerWorker(QObject):
    snapshotReady = Signal(dict)
    previewReady = Signal(int, dict)
    rejected = Signal(str)
    accepted = Signal(str, dict)
    stopped = Signal()

    def __init__(self, socket_path=None, ini_path=None, factory=SessionClient):
        super().__init__()
        self._client = factory(socket_path, ini_path=ini_path)
        self._timer = None
        self._snapshot = {}
        self._last_heartbeat = 0
        self._jog = False
        self._next_connect = 0
        self._preview = None

    @Slot()
    def start(self):
        self._timer = QTimer(self)
        self._timer.setInterval(100)
        self._timer.timeout.connect(self.poll)
        self._timer.start()
        self.poll()

    @Slot(float)
    def heartbeat(self, timestamp):
        self._last_heartbeat = timestamp

    def _offline(self, message, unknown=False):
        self._jog = False
        self._snapshot = {
            "connected": False,
            "serviceConnected": False,
            "connecting": False,
            "message": str(message),
            "axes": [],
            "homed": [],
            "powered": False,
            "estop": True,
            "busy": False,
            "capabilities": {},
            "actualPosition": None,
            "commandedPosition": None,
            "velocity": None,
            "file": "",
            "errors": [],
            "commandState": "unknown" if unknown else "disconnected",
            "commandMessage": str(message) if unknown else "",
        }
        self.snapshotReady.emit(self._snapshot)

    @Slot()
    def poll(self):
        if not self._client.connected and time.monotonic() < self._next_connect:
            return
        try:
            fresh = time.monotonic() - self._last_heartbeat < 0.35
            if self._jog and not fresh:
                self.stopJog()
            self._snapshot = self._client.poll(jog_lease=self._jog and fresh)
            self._snapshot.update(serviceConnected=True, connecting=False)
            self.snapshotReady.emit(self._snapshot)
            self._poll_preview()
        except (OSError, RuntimeError, ValueError) as error:
            self._client.close()
            self._next_connect = time.monotonic() + 1
            self._offline(str(error))
            if self._preview:
                self.previewReady.emit(self._preview["generation"], {"error": str(error)})
                self._preview = None

    @Slot(str, dict)
    def dispatch(self, action, payload):
        try:
            if action == "jog.start" and time.monotonic() - self._last_heartbeat >= 0.35:
                raise ValueError("界面心跳已过期，未发送点动指令")
            response = self._client.execute(action, payload)
            state = response.get("snapshot", self._snapshot)
            if not isinstance(state, dict) or type(response.get("accepted")) is not bool:
                self._client.close()
                raise RemoteError("result_unknown", "命令响应无效，结果未知且不会重发")
            state.update(serviceConnected=True, connecting=False)
            self._snapshot = state
            self.snapshotReady.emit(state)
            if not response.get("accepted"):
                self.rejected.emit(state.get("commandMessage") or "操作未被接受")
            elif action == "jog.start":
                self._jog = True
            elif action in ("jog.stop", "program.stop", "machine.estop", "machine.power"):
                self._jog = False
            if response.get("accepted"):
                self.accepted.emit(action, payload)
        except (OSError, RuntimeError, ValueError) as error:
            unknown = isinstance(error, RemoteError) and error.code == "result_unknown"
            if unknown or not self._client.connected:
                self._offline(str(error), unknown=unknown)
            self.rejected.emit(str(error))

    @Slot()
    def stopJog(self):
        active = self._jog
        self._jog = False
        if active and self._client.connected:
            self.dispatch("jog.stop", {})

    @Slot(str, int)
    def startPreview(self, path, generation):
        self.cancelPreview()
        try:
            if not self._client.connected:
                raise ConnectionError("本地服务未连接，无法解释 G 代码")
            result = self._client.request("preview.start", {"path": path})
            self._preview = {
                "id": result["job_id"],
                "generation": generation,
                "offset": 0,
                "segments": [],
            }
        except (OSError, RuntimeError, ValueError, KeyError) as error:
            self.previewReady.emit(generation, {"error": str(error)})

    def _poll_preview(self):
        job = self._preview
        if not job:
            return
        try:
            result = self._client.request(
                "preview.read", {"job_id": job["id"], "offset": job["offset"]}
            )
        except RemoteError as error:
            self.previewReady.emit(job["generation"], {"error": str(error)})
            self._preview = None
            return
        if result.get("busy"):
            return
        job["segments"].extend(result.get("segments", []))
        job["offset"] = result.get("next_offset", job["offset"])
        if result.get("done") or result.get("error"):
            result["segments"] = job["segments"]
            self.previewReady.emit(job["generation"], result)
            self._preview = None

    @Slot()
    def cancelPreview(self):
        if self._preview and self._client.connected:
            try:
                self._client.request("preview.cancel", {"job_id": self._preview["id"]})
            except (OSError, RuntimeError, ValueError):
                pass
        self._preview = None

    @Slot()
    def shutdown(self):
        if self._timer is not None:
            self._timer.stop()
        self.stopJog()
        self.cancelPreview()
        self._client.close()
        self.stopped.emit()
