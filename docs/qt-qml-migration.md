# Vue 到 Qt Quick/QML 的迁移与控制接入

2026-10-02：原生 QML 入口位于 `qt/`，保留 Vue 的布局、资源、中文文案、动作 ID、快捷键与面板交互。`frontend/` 继续用于 Web 预览和迁移对照，Tauri 桌面环境仍保留。用户随后要求接入完整操作，并明确先使用 Unix socket、不运行模拟器。

当前链路为 **QML → PySide6 QObject → Unix socket → 独立 Python 服务 → LinuxCNC**。Qt 进程不导入 LinuxCNC，服务不依赖 Qt。初版 C++ 应用启动器已由 PySide6 替换，C++ 只保留 Qt Quick Test 启动器；页面仍是原生 QML，没有 WebView。G 代码解释、插补、运动规划和实时执行继续由 LinuxCNC 核心负责，Python 做控制适配和隔离预览调度。

## 模块边界

| 公开入口 | 职责 |
| --- | --- |
| `bettercnc.desktop` | QML 引擎、只读快照、程序文档、桌面文件对话框、历史记录、显式工具启动 |
| `bettercnc.session` | v2 Unix socket 客户端；连接恢复只读取状态，不重发命令 |
| `betterlinuxcnc_service` | 私有 socket、会话唯一所有者、命令线程、点动租约、预览子进程 |
| `bettercnc_controller.Controller` | LinuxCNC stat/command/error channel、配置、操作条件、命令确认、程序与刀具表写入 |
| `bettercnc_preview` | 子进程调用 LinuxCNC `gcode.parse`，隔离参数副本，输出毫米制线段 |
| `BetterCnc.Ui`、`BetterCnc.Catalog` | 通用样式、控件、菜单元数据和本地资源 |
| `BetterCnc.Manual`、`Toolpath`、`Program` | 观察注入的公开数据，发出操作意图，保存各自展示状态 |
| `BetterCnc.Chrome`、`Workspace.qml` | 菜单、对话框、快捷键与功能组合 |

Python 跨模块只导入公开包入口，QML 跨模块只使用 `qmldir` 公开类型。`qt/scripts/check_boundaries.py` 同时检查两种边界。预览进程可使用**只读** `linuxcnc.stat().poll()` 初始化 LinuxCNC 2.9 的 tooldata 映射；命令和 error channel 仍仅由 Controller 持有。这是独立解释器所需的 vendor 初始化，不允许预览发送机床命令。

## 已接入的行为

- 真实连接、急停、电源、模式、joint/axis、回零状态、实际/指令位置、偏置、倍率、主轴、冷却、活动 G/M 代码及错误反馈。
- 急停、电源、回零/取消回零、joint/world 模式、连续/增量点动、MDI、主轴与抱闸、冷却、倍率、速度上限、工件与刀具对刀。
- 程序打开、重载、编辑保存、启动、从选中行启动、单步、暂停、恢复、停止、可选停止与跳行。保存由服务检查最新空闲状态后执行；显示文件必须与控制器加载文件一致才可运行。
- 刀具表显示、编辑保存与重载，保存路径取服务的实际 INI，格式在服务侧校验。编辑受单条 64 KiB 协议帧限制；大文件仍可从磁盘打开，不能截断保存。
- 解释器线段、执行行、投影切换、缩放、实际轨迹、坐标系与单位展示。离线时显示未知状态，不载入演示坐标或示意刀路。
- HAL 配置、仪表、示波器等菜单显式启动本机已安装的 LinuxCNC 工具；未安装或无配置的工具明确报错。

capability 用于界面可用性，服务在执行前重新检查条件。命令受理与 LinuxCNC 确认分别表示。协议、单位及连接生命周期见 [本地控制协议](local-control-protocol.md)。

## 启动

目标环境为 Debian 13、Qt/PySide6 6.8+、Python 3.11+ 和已安装的 LinuxCNC 2.9。`.deb` 同时安装 GUI 与独立服务启动器，并声明运行依赖；不安装守护服务、不自动启动 LinuxCNC、不改 INI/HAL。

在已经由用户启动的 LinuxCNC 会话旁，使用同一系统用户分别执行：

```sh
betterlinuxcnc-service --ini /absolute/path/machine.ini
betterlinuxcnc --ini /absolute/path/machine.ini
```

默认端点为 `$XDG_RUNTIME_DIR/betterlinuxcnc/control.sock`；未设置运行目录时使用 `/tmp/betterlinuxcnc/control.sock`。可为两条命令传相同的 `--socket /private/directory/control.sock`。父目录必须由当前用户拥有且为 0700，socket 为 0600。Qt 的 `--ini`（兼容 LinuxCNC 传入的 `-ini`）要求服务配置匹配；不会借此启动服务或切换机床配置。

Qt 关闭时请求停止本会话点动、取消未发送操作和预览；服务仍独立运行。不自动停止已经运行的加工程序。作为 LinuxCNC DISPLAY 使用时，其退出如何影响整套 LinuxCNC 生命周期以实际启动配置为准，不能假设后台永久运行。

源码运行（LinuxCNC 扩展需来自目标机匹配的系统安装）：

```sh
PYTHONPATH=backend/src python3 -m betterlinuxcnc_service --ini /absolute/path/machine.ini
python3 qt/app/main.py --ini /absolute/path/machine.ini
```

macOS 开发界面可使用 `python3.12 -m venv qt/.venv` 后安装 `PySide6==6.8.3`，再运行 `qt/.venv/bin/python qt/app/main.py`。LinuxCNC 不可用时保留离线界面，不模拟机床。

## 构建、检查与打包

在安装 Qt 开发工具和 PySide6 的环境中：

```sh
cmake -S qt -B qt/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib
cmake --build qt/build --parallel
ctest --test-dir qt/build --output-on-failure
(cd qt/build && cpack -G DEB)
```

macOS 配置时增加 `-DCMAKE_PREFIX_PATH="$HOME/Qt/current/macos"` 与 `-DPython3_EXECUTABLE="$PWD/qt/.venv/bin/python"`。不同平台使用不同构建目录。

完整 Debian 13 CI 入口：

```sh
docker run --rm --init --platform linux/amd64 \
  --mount "type=bind,src=$PWD,dst=/workspace" --workdir /workspace \
  -e QT_BUILD_DIR=/workspace/qt/build-debian \
  debian:13-slim bash qt/scripts/ci-check.sh --install-deps
```

脚本安装容器依赖、构建、执行 UI/Python/socket/解释器测试、生成 `.deb`，再解包检验两个启动器、Python 模块和 QML 资源。offscreen/software 仅用于 CI，正常运行使用目标桌面的图形环境。服务和 Qt 桌面也各自提供 wheel/sdist 构建入口；服务 wheel 不内置 LinuxCNC 本机扩展。

GitHub 工作流仍是 `.github/workflows/ci.yml`，`qt-build` 生成 `betterlinuxcnc-qt-debian13`，Python 3.11/3.13 job 验证服务包，保留 Web/Tauri job 和原有触发策略。Qt 包只上传，不自动安装到机床。

## 验证界限

本次按要求不启动模拟器或真实机床。控制测试通过公开 Controller 的 vendor 替身检查调用、条件与命令序列；socket 测试使用真实本地连接；几何测试调用 Debian LinuxCNC 的真实 `gcode` 扩展，所需状态初始化在无机床测试中使用替身。因此这些结果不能证明实际 NML、回零、换刀、硬件动作或目标 INI 已验收。

预览不是完整加工仿真：当前展示 XYZ 刀尖线段，旋转轴参与坐标数据但没有机床实体运动学/碰撞模型。Python REMAP、探测和依赖实际执行的用户代码不生成误导性预览；含 `#INCLUDE` 的 INI 需提供展开版本。参数写入只发生于临时副本。默认限制 32 MiB 程序、200,000 线段、20 秒解释，服务还有进程总超时；超过限制或解释错误明确显示原因。

M66 等外部输入由 LinuxCNC 预览解释器提供预览值，依赖输入的条件分支不能保证与实际执行一致。刀具对刀保存后，若已有非零刀长补偿，会显式从当前刀号重新加载 G43，替换动态 G43.1/G43.2 或其他 H 补偿；原为 G49 时不自动启用补偿。该语义在界面提交前提示。

GUI 心跳和服务 600 ms 点动租约是软件失联防护。LinuxCNC 原生命令发送可能等待 NML 回执并持有 Python GIL，停止请求可能延迟到该调用返回；不能将租约作为硬实时停机保证。物理安全链仍由机床系统负责。

Debian 13 Intel 核显上的中文字体、缩放、最小窗口、弹窗、释放/失焦行为与实际 INI/HAL 会话仍需现场验收。不同渲染栈不能仅凭本机截图宣称跨所有环境像素完全一致。README 继续由人工维护。
