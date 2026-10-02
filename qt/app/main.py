#!/usr/bin/env python3
"""Source-tree launcher; installed launches use the same desktop entry point."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))

from bettercnc.desktop import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main())
