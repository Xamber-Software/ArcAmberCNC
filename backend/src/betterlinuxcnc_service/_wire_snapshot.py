"""Keep normal status frames bounded while retaining full state inside service."""

import hashlib
import json
from copy import deepcopy


def _text(value, limit):
    raw = str(value).encode("utf-8")
    if len(raw) <= limit:
        return str(value), False
    return raw[: limit - len("…".encode())].decode("utf-8", errors="ignore") + "…", True


def wire_snapshot(snapshot):
    result = deepcopy(snapshot)
    table = result.pop("toolTable", [])
    # This hash also invalidates the desktop preview when an external tool-table
    # edit is observed. Full rows stay server-side for the isolated interpreter.
    encoded = json.dumps(table, allow_nan=False, separators=(",", ":")).encode("utf-8")
    result["toolTableRevision"] = hashlib.sha256(encoded).hexdigest()
    errors = result.get("errors", [])
    result["errorHistoryCount"] = len(errors)
    result["errorsTruncated"] = len(errors) > 20
    result["errors"] = errors[-20:]
    for error in result["errors"]:
        error["message"], truncated = _text(error.get("message", ""), 1024)
        result["errorsTruncated"] |= truncated
    for key in ("message", "commandMessage"):
        if key in result:
            result[key], truncated = _text(result[key], 2048)
            result["errorsTruncated"] |= truncated
    return result
