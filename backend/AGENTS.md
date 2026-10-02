# Python 本地服务边界

先遵循根目录 `AGENT.md` 和 `$code-boundary-standards`。

- 本目录是独立 Python 包；不导入前端实现，也不依赖原生 AXIS。
- v1 `health` 保持历史诊断格式；v2 提供单写入者控制会话、状态、命令和隔离预览。不得伪造反馈，也不启动 LinuxCNC。
- 公开入口为 `betterlinuxcnc_service`（`main`、`serve` 与 `python -m betterlinuxcnc_service`）、`bettercnc_controller.Controller`、`bettercnc_preview.parse_program` 与预览 CLI；下划线文件为私有实现。
- service 只依赖 controller/preview 的公开入口。controller 拥有机床规则、文件写入和 LinuxCNC 命令/错误通道；preview 在独立进程调用 LinuxCNC 的 `gcode` 扩展，不复制解释器。两者不能反向依赖传输层或 Qt。
- 所有 Controller 调用在一个工作线程串行执行。点动必须有会话租约，失联停止本会话点动并取消未发送步骤，任何未知结果都不得自动重试。机床文件写入必须在最新状态校验后执行，不能信任客户端 capability。
- 测试从公开对象、安装后的 CLI 和 socket 观察行为；允许注入 vendor 模块、时钟和预览进程工厂，不导入私有文件。真实 gcode 测试仅解释临时程序，不启动模拟器或硬件。
- 修改后运行 Ruff 检查、格式检查、安装包构建和 `unittest`；涉及协议时还运行 Rust 跨进程集成测试。
