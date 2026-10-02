# 前端架构规范

本文件补充 [根目录规范](../AGENT.md)。`frontend/` 保留为 Vue 迁移对照和 Web 预览，`src-tauri/` 保留既有桌面环境；新增正式桌面入口为 [`qt/`](../qt/AGENTS.md) 的原生 Qt Quick/QML 界面。原生 AXIS 应用已删除。当前 Tauri 仅可查询 Python 本地诊断服务，不接 LinuxCNC、HAL 或真实加工文件。

2026-10-02 的 [Qt 迁移决策](../docs/qt-qml-migration.md) 取代此前“Tauri 为唯一正式入口”的约定。此目录继续保持 Vue → Tauri IPC → Rust → Unix socket 的已有诊断边界，历史控制设计见 [Tauri 架构记录](../docs/tauri-local-control-architecture.md)。浏览器仅保留界面预览和展示测试能力，不提供直接连接 Python 的 HTTP/WebSocket 路径；不要为迁移同步新增 Web 机床控制能力。

## 目录与职责

```text
src/
  app/                        启动、全局样式接入
  pages/                      页面组合与布局，不持有设备逻辑
  packages/
    controller-session/        桌面服务连接提示；Tauri 诊断调用私有
    axis-catalog/             源码核对后的菜单、工具栏、固定演示数据
    axis-presentation/        跨区域展示对话框宿主和入口元数据查找
    ui-system/                Linear 风格视觉规范、通用控件与 Reka UI 组合
    axis-chrome/              AXIS 菜单、工具栏、展示对话框
    manual-control/           Manual / MDI 面板及倍率控件
    toolpath-view/            静态 SVG 刀路示意、Preview / DRO
    program-view/             只读程序列表、选中行及右键菜单
tests/                        浏览器端公共行为验收
public/axis/                  Web 独立持有的历史图标快照与许可证
```

模块根目录只放稳定公开入口，例如 `index.ts`、`model.ts`。Vue 组件、CSS、store 实现和数据细节放在模块的 `lib/` 下。禁止通过 `../other/lib/...` 绕过入口，也禁止入口批量导出内部实现。

这是按业务能力组织的大型项目。组件、状态、校验、适配器和测试应跟随业务所有权留在同一个模块，禁止按文件类型建立全局 `components/`、`stores/`、`api/`，也不创建 `utils/`、`common/`、`shared/` 杂物目录。模块内可以按复杂度划分私有子目录。公开 API、所有权与分层对照见 [packages/README.md](src/packages/README.md)。

## 允许的依赖方向

- `app → pages → 功能模块`，应用层也可使用公开入口；任何 package 不得反向导入 app/pages。
- `axis-catalog`、`ui-system` 和当前的 `controller-session` 不导入其他 package；Tauri API 仅允许由 `controller-session` 使用。
- `axis-presentation → axis-catalog`。
- `manual-control / toolpath-view / program-view → axis-catalog / axis-presentation / ui-system`。
- `axis-chrome` 是 AXIS 入口组合层：除上述三个基础模块外，只能依赖 `manual-control/presentation.ts` 和 `toolpath-view/presentation.ts` 的稳定展示接口。
- 功能模块之间禁止互相导入，由页面或明确的入口组合层组合。所有依赖禁止成环；基础模块不得反向依赖功能模块。
- 外部测试从页面或公开入口观察行为；模块内部测试只能导入公开入口和本模块 tests 夹具。

`npm run lint:boundaries` 对上述规则强制报错，并扫描 Vue SFC 和 TypeScript 类型依赖。不得加忽略或绕过路径别名来消除报错。新增模块要先在规则与本文件里明确其职责和依赖。

## 状态与交互

- Pinia 仅保存本地展示状态，按业务归属由模块私有 store 持有。输入框优先用组件局部状态。
- `manual-control` 拥有选轴、Manual/MDI 标签与点动选择；`program-view` 拥有程序行选择；`toolpath-view` 拥有 Preview/DRO、视图开关和缩放。通过各模块必要的公开展示接口供菜单及快捷键组合使用。
- `axis-presentation` 仅承载跨区域展示对话框宿主和入口元数据查找，不得发展为全局业务状态、机床状态或万能 action 分发器。
- 位置、主轴和运行状态来自固定只读样例，绝不能根据按钮点击假装机床已响应。
- 点动、运行、回零、急停、主轴等入口只打开“未连接控制器”的说明；不实现按住运动、计时运动、网络请求或后台任务。
- 菜单、标签、展示开关、滑条、选中行和对话框可交互。手动输入文本可以编辑，“执行”按钮不发送指令。
- 入口名称和排列以 [功能对照表](docs/axis-parity.md) 链接的历史 AXIS Tcl/Python 源码为准；不得重新依赖已删除的本地 AXIS 目录。条件显示的轴、车床、PyVCP 等必须在对照表说明，不能声称覆盖所有自定义机床界面。

## 视觉与性能

界面统一使用简体中文及国内数控常用术语，采用 Linear 风格的深石墨工作台、细分隔线、紧凑排版与低饱和紫色强调，保留静态预览。主界面不显示品牌图标、底部状态栏、连接提示、演示标签或示例回零标记；坐标读数与操作按钮保留。视觉规范见 [前端视觉说明](docs/linear-visual-style.md)。文案跟随各业务模块维护，不建立全局翻译杂物目录；操作 ID、轴名、G/M 代码、文件名、参数名及快捷键键名不翻译。只翻译内置演示程序的说明性注释，不改动程序指令。术语及设计交付见 [UI 设计交接](docs/ui-design/README.md)。前端资源由 Web 独立持有，不再依赖原生 AXIS 图标生成器、Tk 运行时或源码目录。Tailwind 提供布局工具，设计 token 与通用控件 CSS 由 ui-system 管理，各业务模块拥有自己的布局样式。迁移以当前 Web 视觉和行为为对照，Qt 侧样式归其 `Ui` 模块；仅在用户要求时同步修改 Web。`ui-system/lib/theme.css` 统一维护 Web 颜色与基础样式；`UiIcon` 是公开的无业务 SVG 图标组件，各业务模块负责动作与图标的映射。现有 `TkButton/TkRange/TkDialog` 名称作为兼容入口保留，不代表继续采用 Tk 外观。

当前静态预览使用 SVG，不安装 Three.js。后续真实刀路渲染独立于 Vue 高频响应式树；大几何数据使用不可变/浅引用，按需绘制，并在 Debian 13 Intel 核显目标机验证 WebGL 与 WebKitGTK。不能用 macOS 浏览器结果代替目标机验收。

## 控制接入与未来扩展

- `controller-session`：保留桌面服务诊断组件与 `health` 桥接；按当前视觉要求，主界面不挂载该组件，不显示连接状态或发起定时查询。Tauri 调用保持私有；此前的控制会话扩展设计作为历史约束保留，当前控制接入工作归 Qt 独立适配层。服务可达不等于机床已连接，机床操作继续不可执行。
- `protocol`：本地消息结构、版本、生成类型与校验规则，不能承载 UI；不为此新增 OpenAPI 或 HTTP 网关。
- `desktop-platform`：隔离窗口、文件对话框等通用桌面能力，不拥有机床命令或控制会话。Tauri 控制桥接归 `controller-session`，避免两处重复管理连接。
- Rust 当前仅暴露 `service_health`，socket 路径由宿主决定；Python 位于根目录 `backend/`，仅接受健康查询。当前不构造状态 Channel 或机床控制入口；将来接入时 Python 独占机床校验和 LinuxCNC 通道，预览计算独立运行。
- 接入后命令不乐观更新机床状态，不重放未知结果的运动指令；失焦/断连的点动停止策略由完整控制链负责。

## 质量与发布

使用 npm 和提交的 `package-lock.json`，Node 24 LTS。运行 `npm ci`、`npm run check`、`npm run build` 和受影响的 `npm run test:e2e`。边界、类型和格式检查全部纳入 check。新边界规则必须做预期失败的反例验证。测试通过公开 UI，不跨模块 mock 私有实现。

静态资源全部本地提供；不得加载外部字体、CDN 或遥测。按原仓库和图标各自许可证保存出处。Vite 预览使用 5173，Tauri 开发使用 1420；桌面打包嵌入本地 `dist`。CI 的 Web 产物继续只供预览；新增 Tauri `.deb` 和 Python 包作为独立产物上传，不自动部署。浏览器测试不能代替目标 Debian 机器上的 WebKitGTK、窗口生命周期和实际控制验收。

桌面修改运行 `npm run desktop:check`、`npm run desktop:test` 和对应平台打包。Rust 工具链固定于 `src-tauri/rust-toolchain.toml`，依赖固定于 `Cargo.lock`；CLI/API 依赖也使用 npm 锁文件。Rust 集成测试需要 Python 3.11+，可用 `SERVICE_TEST_PYTHON` 指定解释器。Python 检查见 `backend/README.md`。

## README 维护

遵循根目录 `AGENT.md` 的 README 人工维护规则：包括本目录和各模块在内的 README 仅由人工修改，AI 不得自动更新，也不得通过全目录格式化顺带改写。
