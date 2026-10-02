# 原生 Qt Quick 界面规范

先遵循根目录 [AGENT.md](../AGENT.md) 和 `$code-boundary-standards`。本目录是原生桌面入口，使用 PySide6、Python 3.11+、CMake 和 Qt 6.8+；C++17 只用于 UI 测试启动器。`frontend/` 保留为迁移对照与 Web 预览。不得把 Vue 页面嵌入 WebView 来代替 QML 迁移。

## 模块与公开入口

- `app/` 只拥有应用启动和 QML 引擎配置；`qml/Main.qml` 与 `qml/Workspace.qml` 组合窗口和功能模块，不拥有机床规则。
- `qml/BetterCnc/<Capability>/qmldir` 声明模块的公开类型；跨模块使用 `import BetterCnc.<Capability> 1.0`，不得使用相对路径、JavaScript 文件或 `internal` 类型绕过入口。
- `Ui` 拥有颜色、字体、图标绘制和通用控件；`Catalog` 拥有菜单/工具栏元数据、中文文案及有出处的资源。两者不依赖功能模块，也不互相依赖；历史样例不可作为生产状态。
- `Manual` 拥有手动/MDI、选轴和倍率；`Toolpath` 展示服务解释的线段、实际轨迹及坐标数显；`Program` 展示真实程序文本、选中行及执行行。三者只依赖 `Ui` 和 `Catalog`，通过注入的公开数据接口观察机床及程序。
- `Chrome` 拥有菜单、工具栏和说明对话框，可依赖 `Ui`、`Catalog` 及 `ManualState`、`ToolpathState` 的公开展示接口，不导入其他功能模块的面板或私有类型。
- `Workspace` 组装功能面板、共享展示状态与快捷键。不得建立全局 `utils`、`stores`、`shared`、万能 action 分发器或机床状态桶。模块依赖必须无环。
- CMake 的资源列表、`qmldir` 与 `scripts/check_boundaries.py` 一起维护；新增模块先明确所有权及依赖，再更新检查，不通过忽略规则消除违规。
- Python 公开入口为 `bettercnc.desktop` 和 `bettercnc.session`；下划线文件为私有实现。desktop 只跨模块导入 session 公开入口；session 只依赖标准库。Qt 进程不得导入 `linuxcnc`、`gcode`、`hal` 或 backend 包。

## 展示与系统边界

- 保持现有 Vue 的布局、颜色、字号、文案、动作 ID、快捷键、焦点与可编辑输入行为；大窗口、紧凑断点及最小窗口均须验收。
- `ManualState`、`ToolpathState` 和组件内属性只保存展示状态。坐标、主轴和运行状态从服务只读快照更新，发出命令不代表动作完成。
- `DesktopBackend` 通过专用 QThread 的 socket 客户端接收状态及提交命令；桌面不启动 LinuxCNC 或 Python 服务。点动使用 GUI 心跳、服务租约和释放/失焦停止；重连只恢复状态读取，不重放命令。
- QML 组件不得直接访问平台、网络、文件、进程或 LinuxCNC。桌面可读程序文件，程序和刀具表写入必须经服务在最新状态下校验。独立服务保留规则与唯一命令写入口，LinuxCNC 保留实时职责。
- Qt 使用 v2 控制会话；Tauri/Rust 继续使用 v1 `health`。服务可达与机床连接分别表示。
- 静态资源全部本地提供，保留许可证与出处，不加载 CDN、外部字体或遥测。服务在独立进程解释刀路，通过有界分页传输；几何图层不能随每次坐标快照完整重绘。

## 验证与发布

- 修改后运行 CMake 配置/构建、`ctest --test-dir qt/build --output-on-failure` 及受影响 QML 的 `qmllint -I qt/qml`；测试使用公开模块和可观察 UI，不跨模块导入内部实现。
- 新建或修改依赖规则时，临时加入非法导入，确认失败，删除反例，再确认正常代码通过。
- 公共 UI 测试以 `objectName`、键盘和鼠标操作观察行为；Python 测试经公开接口与真实 Unix socket，使用受控服务替身。不得为测试暴露私有实现，不启动模拟器或机床。
- macOS 构建和无屏测试不能替代 Debian 13、Intel 核显、中文字体、缩放与窗口生命周期验收。容器构建不表示目标机图形或机床已验证。
- `.github/workflows/ci.yml` 的原生 Qt job 调用 `scripts/ci-check.sh`，运行测试并生成独立 `.deb`；产物只上传，不自动安装或部署到机床。
- 构建、启动、打包及对照验收步骤见 [Qt 迁移说明](../docs/qt-qml-migration.md)。所有 README 仅由人工维护。
