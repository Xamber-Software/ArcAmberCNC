"""Validated atomic editing owned by the same policy boundary as program load."""

import math
import os
import re
import stat
import tempfile
from pathlib import Path


def tool_table(text):
    seen_tools = set()
    for number, source in enumerate(text.splitlines(), 1):
        line = source.split(";", 1)[0].strip()
        if not line:
            continue
        fields = {}
        for word in line.split():
            match = re.fullmatch(
                r"([TPXYZABCUVWDIJQ])([-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?)", word, re.I
            )
            if not match:
                raise ValueError(f"刀具表第 {number} 行无法解析字段 {word}")
            key, value = match.group(1).upper(), float(match.group(2))
            if key in fields or not math.isfinite(value):
                raise ValueError(f"刀具表第 {number} 行字段重复或数值无效")
            if key in "TPQ" and (
                not re.fullmatch(r"[+]?\d+", match.group(2)) or value > 2147483647
            ):
                raise ValueError(f"刀具表第 {number} 行 {key} 必须是 32 位非负整数")
            if key == "Q" and value > 9:
                raise ValueError(f"刀具表第 {number} 行 Q 必须在 0 到 9 之间")
            if key == "D" and value < 0:
                raise ValueError(f"刀具表第 {number} 行直径不能为负数")
            fields[key] = value
        if not {"T", "P"}.issubset(fields):
            raise ValueError(f"刀具表第 {number} 行必须包含 T 与 P")
        if fields["T"] in seen_tools:
            raise ValueError(f"刀具表第 {number} 行刀号重复")
        seen_tools.add(fields["T"])


def atomic_write(path, text):
    if not isinstance(text, str) or "\x00" in text or len(text.encode("utf-8")) > 60000:
        raise ValueError("文件内容必须为不含 NUL 的 UTF-8 文本且不超过 60000 字节")
    target = Path(path)
    if not target.is_absolute() or not target.parent.is_dir() or target.is_symlink():
        raise ValueError("文件路径必须是有效绝对路径，不能覆盖符号链接")
    mode = 0o600
    if target.exists():
        original = target.stat()
        if not stat.S_ISREG(original.st_mode):
            raise ValueError("只能写入普通文件")
        mode = stat.S_IMODE(original.st_mode)
    descriptor, temporary = tempfile.mkstemp(prefix=".bettercnc-", dir=target.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), mode)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
