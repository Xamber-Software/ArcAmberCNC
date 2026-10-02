"""Filesystem/process adapter around the LinuxCNC RS274 canonical interface.

Call this in the dedicated preview child process, never the controller process:
LinuxCNC's gcode extension and INI environment are process-global and nonreentrant.
"""

import configparser
import importlib
import math
import os
import tempfile
from pathlib import Path

from ._canonical import AXES, READY_COMMENT, Canonical


def _result(line_count=0):
    return {
        "units": "mm",
        "segments": [],
        "bounds": {"min": [], "max": []},
        "lineCount": line_count,
        "warnings": [],
        "truncated": False,
    }


def _vector(context, name):
    values = context.get(name, [])
    if not isinstance(values, (list, tuple)) or len(values) > 9:
        raise ValueError(f"{name} 必须是最多 9 轴的坐标数组。")
    result = [float(v) for v in values] + [0.0] * (9 - len(values))
    if not all(math.isfinite(v) for v in result):
        raise ValueError(f"{name} 包含无效坐标。")
    return result


def _parameters(context, target):
    values = {}
    source = context.get("parameterFile")
    if source:
        path = Path(source).expanduser()
        if not path.is_absolute() and context.get("iniPath"):
            path = Path(context["iniPath"]).resolve().parent / path
        # Missing requested parameter files are errors, not silently empty state.
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            fields = line.split()
            if len(fields) != 2:
                raise ValueError("参数文件格式无效，无法建立预览副本。")
            index, value = int(fields[0]), float(fields[1])
            if not math.isfinite(value):
                raise ValueError("参数文件包含非有限值。")
            values[index] = value
    index = int(context.get("g5xIndex", values.get(5220, 1)))
    if not 1 <= index <= 9:
        raise ValueError("工件坐标系编号必须在 1 到 9 之间。")
    values[5220] = index
    if "g5xOffset" in context:
        for offset, value in enumerate(_vector(context, "g5xOffset"), 1):
            values[5200 + 20 * index + offset] = value
    if "rotationXY" in context:
        angle = float(context["rotationXY"])
        if not math.isfinite(angle):
            raise ValueError("坐标旋转角度无效。")
        values[5210 + 20 * index] = angle
    if "g92Offset" in context:
        g92 = _vector(context, "g92Offset")
        values[5210] = int(any(v != 0 for v in g92))
        for offset, value in enumerate(g92, 1):
            values[5210 + offset] = value
    target.write_text(
        "".join(f"{index} {value:.17g}\n" for index, value in sorted(values.items())),
        encoding="utf-8",
    )


def _ini(context, program_path, directory):
    ini = configparser.ConfigParser(
        interpolation=None, strict=False, inline_comment_prefixes=(";",)
    )
    source = context.get("iniPath")
    base = program_path.parent
    if source:
        source = Path(source).expanduser().resolve(strict=True)
        base = source.parent
        content = source.read_text(encoding="utf-8")
        if any(line.lstrip().upper().startswith("#INCLUDE") for line in content.splitlines()):
            raise ValueError("预览需要展开后的 INI；当前配置含 #INCLUDE，未执行不完整解释。")
        ini.read_string(content)
    # Python remaps can perform arbitrary real-world actions. A geometry-only
    # interpreter must not execute those hooks in a running machine's process.
    if ini.has_option("RS274NGC", "REMAP") or ini.has_option("PYTHON", "TOPLEVEL"):
        raise ValueError("此机床配置包含 Python/REMAP 扩展，不能在隔离刀路预览中执行；预览未生成。")
    for section in ("RS274NGC", "DISPLAY", "TRAJ"):
        if not ini.has_section(section):
            ini.add_section(section)
    ini.set("RS274NGC", "PARAMETER_FILE", str(directory / "parameters.var"))
    ini.set("RS274NGC", "LOG_FILE", str(directory / "interpreter.log"))
    # Runtime G92 can be active even when persistence is disabled at machine
    # startup. The snapshot, rather than that startup policy, governs this copy.
    if "g92Offset" in context:
        ini.set("RS274NGC", "DISABLE_G92_PERSISTENCE", "0")
    subpaths = ini.get("RS274NGC", "SUBROUTINE_PATH", fallback="").split(":")
    resolved = [str(program_path.parent)]
    for path in filter(None, subpaths):
        candidate = Path(path.strip()).expanduser()
        resolved.append(str(candidate if candidate.is_absolute() else base / candidate))
    ini.set("RS274NGC", "SUBROUTINE_PATH", ":".join(dict.fromkeys(resolved)))
    prefix = Path(
        ini.get("DISPLAY", "PROGRAM_PREFIX", fallback=str(program_path.parent))
    ).expanduser()
    ini.set("DISPLAY", "PROGRAM_PREFIX", str(prefix if prefix.is_absolute() else base / prefix))
    if not ini.has_option("TRAJ", "LINEAR_UNITS"):
        ini.set(
            "TRAJ",
            "LINEAR_UNITS",
            "inch" if abs(context["linearUnits"] - 1 / 25.4) < 1e-6 else "mm",
        )
    destination = directory / "preview.ini"
    with destination.open("w", encoding="utf-8") as stream:
        ini.write(stream)
    return destination, ini.get("RS274NGC", "RS274NGC_STARTUP_CODE", fallback="")


def _initial_codes(context, startup):
    units = context["linearUnits"]
    angular = context["angularUnits"]
    codes = ["G21 G90 G40 G49 G94 F0"]
    if context.get("toolOffset"):
        offsets = _vector(context, "toolOffset")
        codes.append(
            "G43.1 "
            + " ".join(
                f"{axis}{value / units if axis in 'XYZUVW' else value / angular:.17g}"
                for axis, value in zip(AXES, offsets, strict=True)
                if context.get("axisMask", 7) & (1 << AXES.index(axis))
            )
        )
    if context.get("actualPosition"):
        position = _vector(context, "actualPosition")
        codes.append(
            "G53 G0 "
            + " ".join(
                f"{axis}{value / units if axis in 'XYZUVW' else value / angular:.17g}"
                for axis, value in zip(AXES, position, strict=True)
                if context.get("axisMask", 7) & (1 << AXES.index(axis))
            )
        )
    codes.append("G20" if abs(units - 1 / 25.4) < 1e-6 else "G21")
    codes.extend(
        line for line in str(context.get("startupCode", startup)).splitlines() if line.strip()
    )
    codes.append(f"({READY_COMMENT})")
    return codes


def parse_program(path: str, context: dict, *, status_factory=None) -> dict:
    """Interpret in the preview child; return machine-space tool-tip paths in mm.

    Context positions, offsets and tool-table lengths are native machine units;
    ``linearUnits`` is LinuxCNC's units/mm. No LinuxCNC command channel is opened.
    Errors preserve the parsed prefix and explicitly mark it as incomplete.
    ``status_factory`` is an in-process vendor seam for interpreter tests, never
    a request field. Production uses a read-only stat channel to initialize
    LinuxCNC's native tooldata lookup; no command/error/HAL channel is opened.
    """
    result = _result()
    canon = None
    try:
        context = dict(context)
        context["linearUnits"] = float(context.get("linearUnits", 1.0))
        context["angularUnits"] = float(context.get("angularUnits", 1.0))
        if not math.isfinite(context["angularUnits"]) or context["angularUnits"] <= 0:
            raise ValueError("angularUnits 必须是有效的正数（机器角度单位/度）。")
        if not math.isfinite(context["linearUnits"]) or context["linearUnits"] <= 0:
            raise ValueError("linearUnits 必须是有效的正数（机器单位/毫米）。")
        source = Path(path).expanduser().resolve(strict=True)
        if not source.is_file() or source.stat().st_size > 32 * 1024 * 1024:
            raise ValueError("预览文件必须是最多 32 MiB 的普通文件。")
        with source.open("rb") as stream:
            result["lineCount"] = sum(1 for _ in stream)
        gcode = importlib.import_module("gcode")
        max_segments = min(500_000, max(1, int(context.get("maxSegments", 200_000))))
        timeout = min(120.0, max(0.1, float(context.get("maxSeconds", 20.0))))
        if not math.isfinite(timeout):
            raise ValueError("预览超时设置无效。")
        with tempfile.TemporaryDirectory(prefix="bettercnc-preview-") as temporary:
            directory = Path(temporary)
            ini_path, startup = _ini(context, source, directory)
            parameter_file = directory / "parameters.var"
            _parameters(context, parameter_file)
            # RS274 tool lookup uses libtooldata, in addition to get_tool.
            # Its public initialization entry is stat.poll(). Retain the stat
            # object through parse: TOOL_NML builds borrow its table pointer.
            try:
                status = (status_factory or importlib.import_module("linuxcnc").stat)()
                status.poll()
                # LinuxCNC's first poll can report an absent tool mmap only on
                # stderr; the next poll turns that condition into an exception.
                status.poll()
            except Exception as exc:
                raise RuntimeError(f"无法初始化 LinuxCNC 只读刀具状态，预览未执行：{exc}") from exc
            actual_ini = getattr(status, "ini_filename", None)
            if context.get("iniPath") and actual_ini:
                if Path(context["iniPath"]).resolve() != Path(actual_ini).resolve():
                    raise ValueError("预览配置与运行中的 LinuxCNC 不一致。")
            canon = Canonical(gcode, context, parameter_file, max_segments, timeout)
            previous_directory = Path.cwd()
            previous_ini = os.environ.get("INI_FILE_NAME")
            try:
                os.chdir(directory)
                os.environ["INI_FILE_NAME"] = str(ini_path)
                code, line = gcode.parse(str(source), canon, _initial_codes(context, startup))
                if code > gcode.MIN_ERROR:
                    # gcode.parse adds a one-line lookahead for read errors;
                    # its final next_line callback already identifies that
                    # physical line. Execution errors report the same line.
                    failed_line = min(int(line), canon.line) if canon.line > 0 else int(line)
                    result["error"] = {"message": str(gcode.strerror(code)), "line": failed_line}
            finally:
                os.chdir(previous_directory)
                if previous_ini is None:
                    os.environ.pop("INI_FILE_NAME", None)
                else:
                    os.environ["INI_FILE_NAME"] = previous_ini
    except ModuleNotFoundError as exc:
        result["error"] = {"message": f"LinuxCNC RS274 解释器不可用：{exc}", "line": 0}
    except (Exception, KeyboardInterrupt) as exc:
        message = canon.error_message if canon and canon.error_message else str(exc)
        result["error"] = {
            "message": message or "预览解释已中止。",
            "line": canon.line if canon else 0,
        }
    if canon:
        result["segments"] = canon.segments
        result["warnings"] = canon.warnings
        result["truncated"] = canon.truncated or bool(result.get("error") and canon.segments)
        if canon.segments:
            points = (
                point for segment in canon.segments for point in (segment["start"], segment["end"])
            )
            low = [math.inf] * 3
            high = [-math.inf] * 3
            for point in points:
                for axis in range(3):
                    low[axis] = min(low[axis], point[axis])
                    high[axis] = max(high[axis], point[axis])
            result["bounds"] = {"min": low, "max": high}
    return result
