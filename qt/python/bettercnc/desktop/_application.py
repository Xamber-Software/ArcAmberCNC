"""PySide6 owns the QML engine and injects the public QObject backend."""

import argparse
import os
import sys
from pathlib import Path

from PySide6.QtCore import QCoreApplication, Qt, QTimer, QUrl
from PySide6.QtGui import QFont, QFontDatabase, QGuiApplication
from PySide6.QtQml import QQmlApplicationEngine
from PySide6.QtQuickControls2 import QQuickStyle

from ._backend import DesktopBackend


def main(argv=None):
    parser = argparse.ArgumentParser(description="BetterLinuxCNC QML desktop")
    parser.add_argument("-ini", "--ini", dest="ini", help="Require the service to use this INI")
    parser.add_argument("--socket", help="Private Unix socket of betterlinuxcnc-service")
    parser.add_argument("--program", help="Open a local G-code program")
    parser.add_argument("--qml", help=argparse.SUPPRESS)
    parser.add_argument("--smoke-test", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    QCoreApplication.setAttribute(Qt.ApplicationAttribute.AA_DontUseNativeMenuBar)
    app = QGuiApplication([sys.argv[0]])
    app.setApplicationName("BetterLinuxCNC")
    app.setApplicationVersion("0.2.0")
    app.setOrganizationName("Xamber-Software")
    QQuickStyle.setStyle("Basic")
    families = QFontDatabase.families()
    for family in ("Inter", "Noto Sans CJK SC", "PingFang SC", "Microsoft YaHei"):
        if family in families:
            font = QFont(family)
            font.setPixelSize(13)
            app.setFont(font)
            break
    source_qml = Path(__file__).resolve().parents[3] / "qml"
    qml = (
        Path(args.qml or os.environ.get("BETTERCNC_QML_DIR", ""))
        if (args.qml or os.environ.get("BETTERCNC_QML_DIR"))
        else source_qml
    )
    if not qml.is_dir():
        qml = Path(sys.prefix) / "share/betterlinuxcnc/qml"
    if not (qml / "Main.qml").is_file():
        print(f"QML installation is incomplete: {qml}", file=sys.stderr)
        return 1
    backend = DesktopBackend(socket_path=args.socket, ini_path=args.ini)
    app.installEventFilter(backend)
    engine = QQmlApplicationEngine()
    engine.addImportPath(str(qml))
    engine.setInitialProperties({"backend": backend})
    engine.load(QUrl.fromLocalFile(str(qml / "Main.qml")))
    if not engine.rootObjects():
        backend.close()
        return 1
    app.aboutToQuit.connect(backend.close)
    if args.program:
        QTimer.singleShot(500, lambda: backend.openProgram(args.program))
    if args.smoke_test:
        QTimer.singleShot(800, app.quit)
    code = app.exec()
    backend.close()
    del engine
    return code
