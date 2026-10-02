"""Process entry point. JSON files keep large geometry off the command socket."""

import argparse
import json
from pathlib import Path

from . import parse_program


def main():
    parser = argparse.ArgumentParser(description="LinuxCNC RS274 isolated preview")
    parser.add_argument("--request", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        request_path = Path(args.request)
        if request_path.stat().st_size > 8 * 1024 * 1024:
            raise ValueError("预览请求超出 8 MiB 上限。")
        request = json.loads(request_path.read_text(encoding="utf-8"))
        result = parse_program(request["path"], request.get("context", {}))
    except Exception as exc:
        result = {
            "units": "mm",
            "segments": [],
            "bounds": {"min": [], "max": []},
            "lineCount": 0,
            "truncated": False,
            "warnings": [],
            "error": {"message": str(exc), "line": 0},
        }
    destination = Path(args.output)
    temporary = destination.with_name(destination.name + ".tmp")
    temporary.write_text(json.dumps(result, ensure_ascii=False, allow_nan=False), encoding="utf-8")
    temporary.replace(destination)
    return 1 if result.get("error") else 0


if __name__ == "__main__":
    raise SystemExit(main())
