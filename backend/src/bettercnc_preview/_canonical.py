"""Canonical geometry sink for LinuxCNC's real gcode interpreter.

The coordinate transform and arc interface follow LinuxCNC's GPL-2.0-or-later
rs274/interpret.py and glcanon.py, Copyright 2004-2006 Jeff Epler. RS274 and
arc interpolation remain in LinuxCNC; this module only collects its callbacks.
"""

import math
import time

AXES = "XYZABCUVW"
EMPTY_TOOL = (-1,) + (0.0,) * 12 + (0,)
READY_COMMENT = "BETTERCNC_PREVIEW_INITIALIZED"


class PreviewStopped(Exception):
    pass


class Canonical:
    def __init__(self, gcode, context, parameter_file, max_segments, timeout):
        self.gcode = gcode
        self.context = context
        self.parameter_file = str(parameter_file)
        self.max_segments = max_segments
        self.deadline = time.monotonic() + timeout
        self.segments = []
        self.warnings = []
        self.error_message = ""
        self.truncated = False
        self.line = 0
        self.recording = False
        self.known_position = bool(context.get("actualPosition"))
        self.lo = (0.0,) * 9
        self.offset = (0.0,) * 9
        self.plane = 1
        self.rotation_cos = 1.0
        self.rotation_sin = 0.0
        self.rotation_xy = 0.0
        self.tools = [tuple(row) for row in context.get("toolTable", [])]
        for system in ("g5x", "g92"):
            for axis in AXES.lower():
                setattr(self, f"{system}_offset_{axis}", 0.0)

    def stop(self, message, truncated=False):
        self.error_message = message
        self.truncated = truncated
        raise PreviewStopped(message)

    def check_abort(self):
        if time.monotonic() > self.deadline:
            self.stop("预览解释超时；显示的刀路不完整。", True)
        return False

    def next_line(self, state):
        self.line = max(0, int(state.sequence_number))
        self.check_abort()

    def set_g5x_offset(self, index, *values):
        for axis, value in zip(AXES.lower(), values, strict=True):
            setattr(self, f"g5x_offset_{axis}", float(value))

    def set_g92_offset(self, *values):
        for axis, value in zip(AXES.lower(), values, strict=True):
            setattr(self, f"g92_offset_{axis}", float(value))

    def set_xy_rotation(self, degrees):
        self.rotation_xy = float(degrees)
        self.rotation_cos = math.cos(math.radians(degrees))
        self.rotation_sin = math.sin(math.radians(degrees))

    def set_plane(self, plane):
        self.plane = int(plane)

    def transformed(self, values):
        point = [
            float(v) + getattr(self, f"g92_offset_{a}")
            for a, v in zip(AXES.lower(), values, strict=True)
        ]
        x, y = point[:2]
        point[0] = x * self.rotation_cos - y * self.rotation_sin
        point[1] = x * self.rotation_sin + y * self.rotation_cos
        return tuple(
            v + getattr(self, f"g5x_offset_{a}") for a, v in zip(AXES.lower(), point, strict=True)
        )

    def append(self, kind, endpoint):
        self.check_abort()
        if not all(math.isfinite(v) for v in endpoint):
            self.stop("解释器返回了非有限坐标，预览已停止。", True)
        if self.recording and self.known_position and endpoint[:3] != self.lo[:3]:
            if len(self.segments) >= self.max_segments:
                self.stop(f"预览达到 {self.max_segments} 段上限；显示的刀路不完整。", True)
            self.segments.append(
                {
                    "type": kind,
                    "start": [v * 25.4 for v in self.lo[:3]],
                    "end": [v * 25.4 for v in endpoint[:3]],
                    "line": self.line,
                }
            )
        elif self.recording and not self.known_position:
            self.warnings.append("未提供起始机床位置，首段移动的起点未知，未绘制首段。")
        self.lo = tuple(endpoint)
        self.known_position = True

    def straight_traverse(self, *values):
        self.append("rapid", self.transformed(values))

    def straight_feed(self, *values):
        self.append("feed", self.transformed(values))

    def arc_feed(self, *values):
        self.check_abort()
        turns = abs(int(values[4]))
        # arc_to_segments allocates the full arc; bound multi-turn allocation
        # before entering the C++ helper as well as bounding the total result.
        if turns > max(1, (self.max_segments - len(self.segments)) // 128):
            self.stop("圆弧圈数超出预览段数上限；显示的刀路不完整。", True)
        if not self.known_position:
            self.stop("圆弧起点未知，请提供当前位置后重新预览。")
        for endpoint in self.gcode.arc_to_segments(self, *values, 64):
            self.append("feed", endpoint)

    def tool_offset(self, *values):
        # Changing a tool offset moves the represented tip, not the spindle.
        self.lo = tuple(
            p - new + old for p, new, old in zip(self.lo, values, self.offset, strict=True)
        )
        self.offset = tuple(float(v) for v in values)

    def change_tool(self, pocket):
        if 0 <= pocket < len(self.tools):
            if self.context.get("randomToolChanger"):
                self.tools[0], self.tools[pocket] = self.tools[pocket], self.tools[0]
            elif pocket == 0:
                self.tools[0] = EMPTY_TOOL
            else:
                self.tools[0] = self.tools[pocket]

    def get_tool(self, pocket):
        return self.tools[pocket] if 0 <= pocket < len(self.tools) else EMPTY_TOOL

    def get_external_length_units(self):
        return float(self.context.get("linearUnits", 1.0))

    def get_external_angular_units(self):
        return float(self.context.get("angularUnits", 1.0))

    def get_axis_mask(self):
        return int(self.context.get("axisMask", 7))

    def get_block_delete(self):
        return bool(self.context.get("blockDelete", False))

    def comment(self, text):
        if text == READY_COMMENT:
            self.recording = True
        elif text.startswith(("AXIS,stop", "PREVIEW,stop")):
            self.stop("程序请求停止预览；显示的刀路不完整。", True)
        elif text.lower().startswith(("py,", "pyreload")):
            self.stop("预览不执行程序中的 Python 扩展。")

    def straight_probe(self, *values):
        self.stop("探测结果依赖机床输入，无法生成完整的离线刀路。")

    def rigid_tap(self, x, y, z):
        start = self.lo
        self.append("feed", self.transformed((x, y, z) + self.lo[3:]))
        self.append("feed", start)

    def user_defined_function(self, number, p, q):
        self.stop(f"M{100 + int(number)} 用户程序的结果不可离线确定，预览已停止。")

    def message(self, text):
        if text and text not in self.warnings and len(self.warnings) < 50:
            self.warnings.append(str(text))

    def dwell(self, seconds):
        self.check_abort()

    def set_feed_rate(self, value):
        pass

    def set_traverse_rate(self, value):
        pass

    def set_feed_mode(self, value):
        pass

    def set_spindle_rate(self, value):
        pass
