"""Ship the existing QML tree as data, preserving each module's qmldir."""

from pathlib import Path

from setuptools import setup

root = Path(__file__).parent
folders = sorted({path.parent for path in (root / "qml").rglob("*") if path.is_file()})
setup(
    data_files=[
        (
            "share/betterlinuxcnc/" + str(folder.relative_to(root)),
            [str(path.relative_to(root)) for path in folder.iterdir() if path.is_file()],
        )
        for folder in folders
    ]
)
