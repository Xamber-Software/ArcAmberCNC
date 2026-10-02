#!/bin/bash
# Public build/check/package entry point for a disposable Debian 13 container.
set -euo pipefail

qt_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
qt_build_dir=${QT_BUILD_DIR:-"$qt_root/build"}

if [[ $# -gt 1 || ( $# -eq 1 && $1 != --install-deps ) ]]; then
  echo "Usage: bash qt/scripts/ci-check.sh [--install-deps]" >&2
  exit 2
fi

if [[ ${1:-} == --install-deps ]]; then
  if [[ $(id -u) -ne 0 ]]; then
    echo "--install-deps requires root inside the disposable Debian 13 container." >&2
    exit 2
  fi
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates build-essential cmake ninja-build pkg-config dpkg-dev file python3 \
    qt6-base-dev qt6-declarative-dev qt6-declarative-dev-tools qt6-svg-dev \
    qml6-module-qtqml qml6-module-qtqml-models qml6-module-qtqml-workerscript \
    qml6-module-qtquick qml6-module-qtquick-window qml6-module-qtquick-controls \
    qml6-module-qtquick-layouts qml6-module-qtquick-templates \
    qml6-module-qtquick-shapes qml6-module-qtquick-dialogs qml6-module-qttest \
    python3-pyside6.qtcore python3-pyside6.qtgui python3-pyside6.qtqml \
    python3-pyside6.qtquick python3-pyside6.qtquickcontrols2 python3-pyside6.qttest \
    linuxcnc-uspace python3-opengl fonts-noto-cjk fonts-liberation
fi

cmake -S "$qt_root" -B "$qt_build_dir" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib \
  -DPython3_EXECUTABLE=/usr/bin/python3 -DBUILD_TESTING=ON
cmake --build "$qt_build_dir" --parallel

qt_runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/betterlinuxcnc-qt-ci.XXXXXX")
qt_package_root=$(mktemp -d "${TMPDIR:-/tmp}/betterlinuxcnc-qt-package.XXXXXX")
trap 'rm -rf "$qt_runtime_dir" "$qt_package_root"' EXIT
XDG_RUNTIME_DIR="$qt_runtime_dir" ctest --test-dir "$qt_build_dir" \
  --output-on-failure --no-tests=error

# Only upload packages generated from the source checked by this invocation.
find "$qt_build_dir" -maxdepth 1 -type f -name '*.deb' -delete
(cd "$qt_build_dir" && cpack -G DEB)
packages=("$qt_build_dir"/*.deb)
[[ -f ${packages[0]} ]]
for package in "${packages[@]}"; do
  dpkg-deb --info "$package"
  dpkg-deb --contents "$package"
  dpkg-deb --extract "$package" "$qt_package_root"
  qt_smoke_log="$qt_build_dir/Testing/Temporary/package-smoke.log"
  qt_installed_python="$qt_package_root/usr/lib/betterlinuxcnc/python"
  qt_installed_qml="$qt_package_root/usr/share/betterlinuxcnc/qml"
  # Explicit package paths validate the unpacked installation, with no service or
  # simulator running and no chance of connecting to a machine's default socket.
  PYTHONPATH="$qt_installed_python" BETTERCNC_QML_DIR="$qt_installed_qml" \
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QT_QUICK_CONTROLS_STYLE=Basic \
    XDG_RUNTIME_DIR="$qt_runtime_dir" timeout 15s \
    "$qt_package_root/usr/bin/betterlinuxcnc" --smoke-test \
    --socket "$qt_runtime_dir/no-controller.sock" >"$qt_smoke_log" 2>&1
  cat "$qt_smoke_log"
  PYTHONPATH="$qt_installed_python" "$qt_package_root/usr/bin/betterlinuxcnc-service" --help
  PYTHONPATH="$qt_installed_python" python3 - "$qt_installed_python" "$qt_smoke_log" <<'PYCODE'
from pathlib import Path
import importlib
import re
import sys

root = Path(sys.argv[1]).resolve()
for name in ("bettercnc.desktop", "bettercnc.session", "betterlinuxcnc_service",
             "bettercnc_controller", "bettercnc_preview"):
    module = importlib.import_module(name)
    if not Path(module.__file__).resolve().is_relative_to(root):
        sys.exit(f"Packaged module was loaded outside the extracted package: {name}")
log = Path(sys.argv[2]).read_text()
if re.search(r"QQmlApplicationEngine failed|ReferenceError:|TypeError:|Unable to assign|Binding loop detected", log):
    sys.exit("The packaged application reported QML errors.")
print("Packaged launchers, Python modules and QML loaded successfully without a controller.")
PYCODE

done
