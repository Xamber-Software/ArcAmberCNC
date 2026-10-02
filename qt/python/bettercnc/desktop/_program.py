"""Local program document; preview results arrive from the control service."""

from pathlib import Path

from PySide6.QtCore import Property, QObject, Signal, Slot

MAX_PROGRAM_BYTES = 32 * 1024 * 1024


class ProgramModel(QObject):
    changed = Signal()
    selectedLineChanged = Signal()
    previewRequested = Signal(str, int)
    cancelRequested = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._path = ""
        self._text = ""
        self._lines = []
        self._selected = 0
        self._segments = []
        self._bounds = {}
        self._busy = False
        self._error = ""
        self._warnings = []
        self._generation = 0

    filePath = Property(str, lambda self: self._path, notify=changed)
    fileName = Property(str, lambda self: Path(self._path).name, notify=changed)
    text = Property(str, lambda self: self._text, notify=changed)
    lines = Property("QStringList", lambda self: self._lines, notify=changed)
    segments = Property("QVariantList", lambda self: self._segments, notify=changed)
    bounds = Property("QVariantMap", lambda self: self._bounds, notify=changed)
    previewBusy = Property(bool, lambda self: self._busy, notify=changed)
    previewError = Property(str, lambda self: self._error, notify=changed)
    previewWarnings = Property("QStringList", lambda self: self._warnings, notify=changed)

    def _select(self, value):
        value = max(0, min(len(self._lines), int(value)))
        if value != self._selected:
            self._selected = value
            self.selectedLineChanged.emit()

    selectedLine = Property(int, lambda self: self._selected, _select, notify=selectedLineChanged)

    def load(self, path, context=None):
        file = Path(path).expanduser().resolve(strict=True)
        if not file.is_file() or file.stat().st_size > MAX_PROGRAM_BYTES:
            raise ValueError("请选择不超过 32 MiB 的加工程序文件")
        data = file.read_bytes()
        if b"\0" in data:
            raise ValueError("加工程序包含二进制数据")
        try:
            text = data.decode("utf-8-sig")
        except UnicodeDecodeError:
            text = data.decode("latin-1")
        self._path = str(file)
        self._text = text
        self._lines = text.splitlines()
        self._select(1 if self._lines else 0)
        self.preview(context)

    def preview(self, context=None):
        if not self._path:
            return
        self.cancel()
        self._segments = []
        self._bounds = {}
        self._error = ""
        self._warnings = []
        self._busy = True
        self.changed.emit()
        self.previewRequested.emit(self._path, self._generation)

    @Slot(int, dict)
    def acceptPreview(self, generation, result):
        if generation != self._generation:
            return
        self._busy = False
        problem = result.get("error")
        if problem:
            if isinstance(problem, dict):
                line = problem.get("line", 0)
                message = problem.get("message", "G 代码解释失败")
                self._error = f"第 {line} 行：{message}" if line else message
            else:
                self._error = str(problem)
        elif result.get("units") != "mm":
            self._error = "预览服务返回了无效坐标单位"
        else:
            self._segments = result.get("segments", [])
            self._bounds = result.get("bounds", {})
            self._warnings = result.get("warnings", [])
            if result.get("truncated"):
                self._warnings.append("程序超过预览容量，只显示部分刀路")
        self.changed.emit()

    def cancel(self):
        self._generation += 1
        self._busy = False
        self.cancelRequested.emit()
