# 本地控制协议 v2

端点使用 AF_UNIX stream。父目录为同一用户所有的 0700 目录，socket 为 0600；服务不覆盖已有 socket。每帧为四字节大端无符号长度，随后 UTF-8 JSON，正文最大 65,536 字节。重复 JSON 字段、非有限数、非法版本、未知字段、无效参数与超长帧拒绝处理。

v1 保持 `{version:1, request_id, method:"health"}` 的旧格式，返回历史诊断结果和 `machine_connected:false`。它不获取控制会话，也不代表实际机床状态；保留用于 Tauri 兼容。

v2 请求：

```json
{"version":2,"request_id":"unique-id","method":"session.status","params":{"jog_lease":false}}
```

成功返回同版本和 request_id，以及对象 `result`；失败返回 `error:{code,message}`。同一连接的 request_id 不得复用。客户端不自动重发命令；发送后丢失回执视为结果未知。

| 方法 | 参数 | 返回 |
| --- | --- | --- |
| `session.attach` | 可选 `ini_path` | 状态快照；INI 不匹配或已有所有者则拒绝 |
| `session.status` | 可选布尔 `jog_lease` | 最新机床快照；只有已建立点动租约才能续期 |
| `command.execute` | `action`、对象 `payload` | `accepted` 与 `snapshot`；accepted 不是执行完成 |
| `preview.start` | 绝对 `path` | `job_id`；上下文由服务取得，客户端不能替换 |
| `preview.read` | `job_id`、非负整数 `offset` | 最多 256 段、next_offset、busy、done、units、bounds、error、warnings、truncated |
| `preview.cancel` | `job_id` | `cancelled:true` |

每个后续 v2 方法都要求当前连接持有会话。服务最多一个控制所有者，一个预览任务归属于该连接；断开释放所有权、取消预览和未发送的后续命令。其他 LinuxCNC 工具不受此 socket 所有权约束，应在部署时协调。

## 状态与操作

`connected` 是 LinuxCNC 状态有效，Qt 另外维护 `serviceConnected`，不得将二者混为一谈。位置数组按 `XYZABCUVW` 排列；长度为 LinuxCNC 原生单位、角度为原生角度单位，`linearUnits` 是原生单位/毫米，`angularUnits` 是原生单位/度。joint 编号独立于 axis，未知运动学映射不能猜测。预览输出 XYZ 的单位统一为毫米。

完整刀表保留在服务内供预览使用；网络快照使用 `toolTableRevision` 标识变化。网络错误历史保留最近 20 条，每条消息最多 1024 UTF-8 字节，附 errorHistoryCount/errorsTruncated，避免大刀表或长错误导致状态帧超限。

`commandState` 为 idle、pending、sent、completed、error、unknown；pending 可能仍在等待模式切换，sent 等待 LinuxCNC 回执，completed 表示该条命令已确认，**不等于整段加工程序结束**。当状态忙、条件改变或回执被外部写入者推进时，不继续发送后续步骤。

| action | payload |
| --- | --- |
| `machine.estop`、`machine.power` | 可选 enabled；缺省根据新鲜状态切换 |
| `machine.mode`、`motion.mode` | mode: manual/mdi 或 joint/world |
| `machine.debug` | value 为 0–2147483647 的整数；等待 stat.debug 确认 |
| `machine.home`、`machine.unhome` | 明确 joint；全回零使用 machine.home-all |
| `jog.start` | axis 字符或明确 joint 整数、mode、direction ±1、velocity 原生单位/秒、increment 原生单位 |
| `jog.stop` | 空对象；取消尚未发出的 start 并停止本会话点动 |
| `mdi.execute` | 单行 text，最多 254 字节 |
| `program.run`、`program.step`、`program.pause`、`program.resume`、`program.stop` | 空对象；program.run-line 带 1 起始 line |
| `spindle.cw`、`spindle.ccw` | 可选 RPM speed；无默认配置时要求明确转速 |
| `spindle.stop`、`spindle.increase`、`spindle.decrease`、`spindle.brake` | 抱闸可带 enabled |
| `coolant.flood`、`coolant.mist` | 可选 enabled |
| `override.feed`、`override.rapid`、`override.spindle`、`velocity.max` | value 为比例或原生单位/秒 |
| `machine.touch-off`、`tool.touch-off` | axis、原生单位 value、system、target |
| `file.open` | 绝对 path |
| `file.save` | 绝对 path、text；服务写入后请求加载 |
| `tool.reload`、`tooltable.save` | 重载为空；保存传 text，路径从实际 INI 获取 |

动作的可用性由 capability 提示，条件始终由 Controller 校验。程序/刀具编辑文本最多 60,000 UTF-8 字节，并受整个 JSON 帧上限约束，超限拒绝，不截断内容；断线后不补写或重放。

Qt GUI 每 100 ms 发时间戳给 socket 工作线程。心跳超过 350 ms 时客户端请求停止点动，不再续租。服务租约标称 600 ms；由于原生 NML 命令可能持有 GIL 等待回执，此值不是硬实时停止上限。停止、退出、窗口失焦及界面释放都应取消本次点动；禁止将自动重连变成重新启动点动。

预览子进程使用临时参数/INI 副本、无 stdin，并设置解释及收集超时。它只能建立只读 stat 初始化 tooldata，不能建立 command/error channel。崩溃、解释错误、结果超限或不支持的执行扩展均作为显式错误传回，不伪造刀路。更多运行方法与未验收范围见 [Qt 迁移记录](qt-qml-migration.md)。
