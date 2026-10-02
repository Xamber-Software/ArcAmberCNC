"""Single-writer LinuxCNC adapter; no Qt imports or GUI-thread waits."""

import importlib
import math
import os
import time
from collections import deque
from copy import deepcopy
from dataclasses import dataclass

from ._config import AXES, SYSTEMS, Configuration
from ._files import atomic_write, tool_table
from ._status import observe, offline


@dataclass
class _Step:
    method: str
    args: tuple
    guard: str = "connected"
    expected: object = None
    serial: int | None = None
    sent_at: float = 0.0
    active_result: bool = False


class Controller:
    """Own NML command/error channels on one worker thread.

    dispatch returns local acceptance, not execution success. poll advances
    commands and reports their lifecycle separately from observed machine state.
    The C extension's send itself can wait up to five seconds for NML receipt;
    callers must serialize *all* methods on a non-GUI worker thread.
    """

    def __init__(self, ini_path=None, module=None, clock=None):
        self._module = module
        self._clock = clock or time.monotonic
        self._ini_path = ini_path or os.environ.get("INI_FILE_NAME")
        self._stat = self._command = self._error_channel = self._config = None
        self._closed = False
        self._steps = deque()
        self._action = ""
        self._jogs = set()
        self._errors = deque(maxlen=100)
        self._command_state = "idle"
        self._command_message = ""
        self._snapshot = offline("等待 LinuxCNC 状态")

    @property
    def snapshot(self):
        return deepcopy(self._snapshot)

    def _constant(self, name):
        return getattr(self._module, name)

    def _result(self, state, message):
        self._command_state = state
        self._command_message = message
        if state in ("completed", "error", "unknown"):
            self._steps.clear()
        self._publish()

    def _publish(self):
        self._snapshot.update(
            commandState=self._command_state,
            commandMessage=self._command_message,
            errors=list(self._errors),
            capabilities=self._capabilities(),
        )

    def _disconnect(self, message):
        if self._steps or self._jogs:
            self._command_state = "unknown"
            self._command_message = "连接中断；命令结果未知，重连后不会重放"
        self._steps.clear()
        self._jogs.clear()
        self._stat = self._command = self._error_channel = None
        self._snapshot = offline(message)
        self._publish()

    def _refresh(self, advance):
        if self._closed:
            return self.snapshot
        try:
            if self._module is None:
                self._module = importlib.import_module("linuxcnc")
            if self._stat is None:
                self._stat = self._module.stat()
                self._command = self._module.command()
                self._error_channel = self._module.error_channel()
            self._stat.poll()
            actual_ini = getattr(self._stat, "ini_filename", None)
            path = self._ini_path or actual_ini
            if (
                self._ini_path
                and actual_ini
                and os.path.realpath(self._ini_path) != os.path.realpath(actual_ini)
            ):
                raise ValueError("运行中的 LinuxCNC 配置与所选 INI 不一致")
            if self._config is None or self._config.path != (
                os.path.realpath(path) if path else None
            ):
                self._config = Configuration(self._module, path)
            self._snapshot = observe(self._stat, self._module, self._config)
            if not self._snapshot["powered"] or self._snapshot["estop"]:
                self._jogs.clear()
            if self._config.joints and self._config.joints != self._stat.joints:
                raise ValueError("INI 与运行中的 joint 数量不一致")
            # Bound work and retained history; only this owner consumes errors.
            for _ in range(32):
                error = self._error_channel.poll()
                if not error:
                    break
                kind, message = error
                is_error = kind in (self._constant("NML_ERROR"), self._constant("OPERATOR_ERROR"))
                self._errors.append({"kind": int(kind), "message": str(message), "error": is_error})
                if is_error and self._steps:
                    self._result("error", str(message))
            if advance:
                self._advance()
            self._publish()
        except Exception as error:
            self._disconnect(f"LinuxCNC 不可用：{error}")
        return self.snapshot

    def poll(self):
        return self._refresh(True)

    def _require(self, condition, message):
        if not condition:
            raise ValueError(message)

    def _guard(self, name):
        s = self._snapshot
        self._require(s["connected"], "LinuxCNC 未连接，拒绝命令")
        if name == "connected":
            return
        self._require(s["powered"] and not s["estop"], "必须先解除急停并开启机床电源")
        if name in ("idle", "homedIdle", "jog"):
            self._require(not s["busy"] and not self._jogs, "机床必须空闲")
        if name in ("homedIdle", "homed"):
            self._require(self._homed(), "必须先完成全部 joint 回零")
        if name == "paused":
            self._require(s["mode"] == "auto" and s["paused"], "程序没有暂停")
        if name == "running":
            self._require(s["mode"] == "auto" and s["busy"] and not s["paused"], "程序没有运行")

    def _homed(self):
        return bool(
            self._config
            and (
                self._config.no_force_homing
                or (self._snapshot["homed"] and all(self._snapshot["homed"]))
            )
        )

    def _number(self, value, name, minimum=None, maximum=None):
        self._require(not isinstance(value, bool), name + " 必须是有限数值")
        try:
            value = float(value)
        except (ValueError, TypeError):
            raise ValueError(name + " 必须是有限数值") from None
        self._require(math.isfinite(value), name + " 必须是有限数值")
        self._require(minimum is None or value >= minimum, name + " 低于允许范围")
        self._require(maximum is None or value <= maximum, name + " 超过允许范围")
        return value

    def _axis(self, payload):
        axis = str(payload.get("axis", "")).upper()
        self._require(axis in self._snapshot["axes"], "必须明确指定配置中存在的轴")
        return axis

    def _boolean(self, payload, current):
        value = payload.get("enabled", payload.get("value", not current))
        self._require(isinstance(value, bool), "开关值必须是布尔值")
        return value

    def _step(self, method, *args, guard="connected", expected=None, active_result=False):
        return _Step(method, args, guard, expected, active_result=active_result)

    def _mode_steps(self, mode, guard):
        self._require(mode in ("manual", "mdi", "auto"), "无效任务模式")
        if self._snapshot["mode"] == mode:
            return []
        return [
            self._step(
                "mode",
                self._constant("MODE_" + mode.upper()),
                guard=guard,
                expected=lambda: self._snapshot["mode"] == mode,
            )
        ]

    def _motion_steps(self, mode, guard):
        self._require(mode in ("joint", "world"), "无效运动模式")
        target = self._constant("TRAJ_MODE_FREE" if mode == "joint" else "TRAJ_MODE_TELEOP")
        if self._stat.motion_mode == target:
            return []
        return [
            self._step(
                "teleop_enable",
                int(mode == "world"),
                guard=guard,
                expected=lambda: self._stat.motion_mode == target,
            )
        ]

    def _advance(self):
        if not self._steps:
            return
        step = self._steps[0]
        if step.serial is not None:
            echo = self._stat.echo_serial_number
            elapsed = self._clock() - step.sent_at
            if echo > step.serial:
                self._result("unknown", "发现其他命令写入；当前命令结果未知，后续步骤已取消")
                return
            if echo == step.serial:
                if self._stat.state == self._constant("RCS_ERROR"):
                    self._result("error", "LinuxCNC 拒绝命令：" + self._action)
                    return
                confirmed = step.expected is None or step.expected()
                done = self._stat.state == self._constant("RCS_DONE")
                if confirmed and (done or step.active_result):
                    if step.method == "abort":
                        self._jogs.clear()
                    elif step.method == "jog" and step.args[0] == self._constant("JOG_STOP"):
                        self._jogs.discard((step.args[1], step.args[2]))
                    self._steps.popleft()
                    if not self._steps:
                        self._result("completed", "LinuxCNC 已确认命令：" + self._action)
                        return
                elif elapsed > 10 and (done or not self._snapshot["busy"]):
                    self._result("unknown", "未能确认命令结果；不会重试：" + self._action)
                    return
                else:
                    return
            elif elapsed > 10:
                self._result("unknown", "未收到命令回执；不会重试：" + self._action)
                return
            else:
                return
            step = self._steps[0]
        try:
            self._guard(step.guard)
            # Only the next confirmed step is sent. No wait_complete is used.
            previous_serial = self._command.serial
            getattr(self._command, step.method)(*step.args)
            step.serial = self._command.serial
            step.sent_at = self._clock()
            if step.serial <= previous_serial:
                self._result("unknown", "命令发送未生成可确认的序号；不会重试")
                return
            self._command_state = "pending" if len(self._steps) > 1 else "sent"
            self._command_message = "等待 LinuxCNC 确认：" + self._action
            if step.method == "jog" and step.args[0] != self._constant("JOG_STOP"):
                self._jogs.add((step.args[1], step.args[2]))
        except ValueError as error:
            self._result("error", str(error))
        except Exception as error:
            self._result("unknown", f"命令发送结果未知；不会重试：{error}")

    def dispatch(self, action, payload=None):
        if not isinstance(action, str) or (payload is not None and not isinstance(payload, dict)):
            self._result("error", "命令格式无效")
            return False
        payload = dict(payload or {})
        # Never advance an old start command while handling a stop/release.
        if action == "jog.stop":
            self.stop_jog()
            return self._snapshot["connected"]
        self._refresh(False)
        aliases = {
            "estop": "machine.estop",
            "power": "machine.power",
            "spindle.cw": "spindle.forward",
            "spindle.ccw": "spindle.reverse",
            "mdi.go": "mdi.execute",
            "feed.override": "override.feed",
            "rapid.override": "override.rapid",
            "spindle.override": "override.spindle",
            "max-velocity": "velocity.max",
        }
        action = aliases.get(action, action)
        try:
            self._guard("connected")
            emergency = (
                action in ("program.stop", "spindle.stop")
                or action == "machine.estop"
                or (action == "machine.power" and self._snapshot["powered"])
            )
            if self._steps and not emergency:
                raise ValueError("上一条命令尚未确认")
            if emergency:
                self._steps.clear()
            steps = self._plan(action, payload)
            self._steps = deque(steps)
            self._action = action
            if not steps:
                self._result("completed", "机床已处于请求状态")
                return True
            self._command_state = "pending"
            self._command_message = "命令已接受：" + action
            self._advance()
            self._publish()
            return self._command_state not in ("error", "unknown")
        except (ValueError, TypeError, KeyError, AttributeError, OverflowError, OSError) as error:
            # Rejection cannot silently discard a previously accepted command.
            if self._steps:
                self._errors.append({"kind": 0, "error": True, "message": str(error)})
                self._publish()
            else:
                self._result("error", str(error))
            return False

    def _plan(self, action, payload):
        s, config = self._snapshot, self._config
        if action == "machine.estop":
            enabled = self._boolean(payload, s["estop"])
            target = self._constant("STATE_ESTOP" if enabled else "STATE_ESTOP_RESET")
            return [self._step("state", target, expected=lambda: self._stat.task_state == target)]
        if action == "machine.debug":
            self._require(not s["busy"] and not self._jogs, "运行时不能修改调试标志")
            value = payload.get("value")
            self._require(
                type(value) is int and 0 <= value <= 2147483647,
                "调试标志必须是 0 到 2147483647 的整数",
            )
            return [self._step("debug", value, expected=lambda: self._snapshot["debug"] == value)]
        if action == "machine.power":
            enabled = self._boolean(payload, s["powered"])
            self._require(not enabled or not s["estop"], "急停未解除，不能开启电源")
            target = self._constant("STATE_ON" if enabled else "STATE_OFF")
            return [self._step("state", target, expected=lambda: self._stat.task_state == target)]
        if action == "program.stop":
            return [self._step("abort", expected=lambda: not self._snapshot["busy"])]
        if action in ("program.run", "program.run-line", "program.step"):
            if action == "program.step" and s["paused"]:
                self._guard("paused")
                return [
                    self._step(
                        "auto", self._constant("AUTO_STEP"), guard="paused", active_result=True
                    )
                ]
            self._guard("homedIdle")
            self._require(bool(s["file"]), "尚未打开加工程序")
            line = self._number(payload.get("line", 0), "起始行", 0)
            self._require(line.is_integer(), "起始行必须是整数")
            if action == "program.run-line":
                self._require(line >= 1, "必须明确指定起始行")
            steps = self._mode_steps("auto", "homedIdle")
            args = (
                (self._constant("AUTO_STEP"),)
                if action == "program.step"
                else (self._constant("AUTO_RUN"), int(line))
            )
            steps.append(
                self._step(
                    "auto",
                    *args,
                    guard="homedIdle",
                    active_result=True,
                    expected=lambda: (
                        self._snapshot["busy"] or self._stat.state == self._constant("RCS_DONE")
                    ),
                )
            )
            return steps
        if action in ("program.pause", "program.resume"):
            guard = "running" if action == "program.pause" else "paused"
            self._guard(guard)
            paused = action == "program.pause"
            return [
                self._step(
                    "auto",
                    self._constant("AUTO_PAUSE" if paused else "AUTO_RESUME"),
                    guard=guard,
                    active_result=True,
                    expected=lambda: self._snapshot["paused"] == paused,
                )
            ]
        if action in ("program.optional", "program.block-delete"):
            key, method = (
                ("optionalStop", "set_optional_stop")
                if action == "program.optional"
                else ("blockDelete", "set_block_delete")
            )
            value = self._boolean(payload, s[key])
            return [self._step(method, int(value), expected=lambda: self._snapshot[key] == value)]
        if action == "machine.mode":
            self._guard("idle")
            mode = payload.get("mode")
            self._require(mode in ("manual", "mdi"), "界面任务模式必须是 manual 或 mdi")
            if mode == "mdi":
                self._guard("homedIdle")
            return self._mode_steps(mode, "homedIdle" if mode == "mdi" else "idle")
        if action in ("mode.joint", "mode.world", "motion.mode"):
            mode = payload.get("mode") if action == "motion.mode" else action.split(".")[1]
            guard = "homedIdle" if mode == "world" else "idle"
            self._guard(guard)
            return self._mode_steps("manual", guard) + self._motion_steps(mode, guard)
        if action in ("home", "unhome", "machine.home", "machine.unhome") or action.startswith(
            ("machine.home-", "machine.unhome-")
        ):
            self._guard("idle")
            home = action.startswith("machine.home") or action == "home"
            axis = action.rsplit("-", 1)[-1]
            if "joint" in payload:
                joint = self._number(payload["joint"], "joint", 0, self._stat.joints - 1)
                self._require(joint.is_integer(), "joint 必须是整数")
                joints = [int(joint)]
                self._require(
                    (config.home_sequences.get(int(joint)) or 0) >= 0, "同步回零组必须使用全部回零"
                )
            elif axis == "all":
                joints = [-1]
            else:
                self._require(axis in s["axes"], "轴不存在")
                joints = config.joint_map.get(axis, [])
                self._require(bool(joints), "当前运动学没有已知的轴与 joint 映射")
                self._require(
                    all((config.home_sequences.get(j) or 0) >= 0 for j in joints),
                    "同步回零组必须使用全部回零",
                )
            method = "home" if home else "unhome"
            steps = self._mode_steps("manual", "idle") + self._motion_steps("joint", "idle")
            for joint in joints:
                indices = list(range(self._stat.joints)) if joint == -1 else [joint]
                steps.append(
                    self._step(
                        method,
                        joint,
                        guard="idle",
                        expected=lambda indices=indices: all(
                            self._snapshot["homed"][j] == home for j in indices
                        ),
                    )
                )
            return steps
        if action in ("jog.start", "machine.jog-plus", "machine.jog-minus"):
            self._guard("jog")
            direction = (
                payload.get("direction")
                if action == "jog.start"
                else (1 if action.endswith("plus") else -1)
            )
            self._require(
                direction in (-1, 1) and not isinstance(direction, bool), "点动方向必须为 -1 或 1"
            )
            requested_mode = payload.get("mode", s["motionMode"])
            self._require(requested_mode == s["motionMode"], "请求点动模式与真实运动模式不一致")
            world = requested_mode == "world"
            explicit_joint = not world and type(payload.get("axis")) is int
            axis = None if explicit_joint else self._axis(payload)
            self._require(s["motionMode"] in ("joint", "world"), "未知运动模式，不能点动")
            if world:
                self._require(self._homed(), "世界坐标点动要求回零")
                index = AXES.index(axis)
                limit = config.axis_limits[axis]["maxVelocity"]
            else:
                joints = config.joint_map.get(axis, [])
                if explicit_joint:
                    index = int(self._number(payload["axis"], "joint", 0, self._stat.joints - 1))
                elif "joint" in payload:
                    joint = self._number(payload["joint"], "joint", 0, self._stat.joints - 1)
                    self._require(joint.is_integer(), "joint 必须是整数")
                    index = int(joint)
                    self._require(not joints or index in joints, "joint 不属于所选轴")
                else:
                    self._require(
                        len(joints) == 1, "必须有唯一的轴与 joint 映射；不能猜测或单独驱动同步轴"
                    )
                    index = joints[0]
                limit = config.joint_limits.get(index)
            self._require(limit is not None and limit > 0, "INI 缺少所选轴或 joint 的最大速度")
            velocity = self._number(payload.get("velocity"), "点动速度 (机床单位/秒)", 0, limit)
            self._require(velocity > 0, "点动速度必须大于零")
            increment = self._number(payload.get("increment", 0), "点动步距", 0)
            guard = "homedIdle" if world else "jog"
            steps = self._mode_steps("manual", guard) + self._motion_steps(
                "world" if world else "joint", guard
            )
            args = (
                self._constant("JOG_INCREMENT" if increment else "JOG_CONTINUOUS"),
                int(not world),
                index,
                direction * velocity,
            )
            if increment:
                args += (increment,)
            steps.append(self._step("jog", *args, guard=guard, active_result=True))
            return steps
        if action == "mdi.execute":
            return self._mdi_steps(payload.get("text"))
        if action.startswith("machine.zero-G"):
            system = action.removeprefix("machine.zero-")
            self._require(system in SYSTEMS or system == "G92", "无效坐标系")
            text = (
                "G92.1"
                if system == "G92"
                else f"G10 L2 P{SYSTEMS.index(system) + 1} "
                + " ".join(axis + "0" for axis in s["axes"])
                + " R0"
            )
            return self._mdi_steps(text)
        if action in ("machine.touch-off", "machine.zero-selected", "tool.touch-off"):
            axis = self._axis(payload)
            value = self._number(payload.get("value"), "坐标值")
            system = str(payload.get("system", "")).upper()
            self._require(system in SYSTEMS or system == "G92", "必须明确指定坐标系")
            value = self._program_units(value, axis)
            if action == "tool.touch-off" or payload.get("target") == "tool":
                self._require(s["tool"] is not None and s["tool"] > 0, "必须先装载刀具")
                # L10 computes against the active system; L11 uses G59.3.
                active = SYSTEMS[s["g5xIndex"] - 1] if 1 <= s["g5xIndex"] <= 9 else None
                self._require(
                    system == active or system == "G59.3", "刀具对刀仅支持当前坐标系或 G59.3"
                )
                lvalue = 10 if system == active else 11
                text = f"G10 L{lvalue} P{s['tool']} {axis}{value:.12g}"
            else:
                self._require(
                    payload.get("target", "workpiece") in ("workpiece", "fixture"), "无效对刀目标"
                )
                text = (
                    f"G92 {axis}{value:.12g}"
                    if system == "G92"
                    else f"G10 L20 P{SYSTEMS.index(system) + 1} {axis}{value:.12g}"
                )
            steps = self._mdi_steps(text)
            if (action == "tool.touch-off" or payload.get("target") == "tool") and "G43" in s[
                "activeCodes"
            ]:
                # NML reports any nonzero TLO as G43, including G43.1/G43.2.
                # This action deliberately reloads the explicitly touched tool;
                # it cannot infer or preserve an earlier dynamic/H selection.
                steps.append(self._step("mdi", f"G43 H{s['tool']}", guard="homedIdle"))
            return steps
        if action.startswith("spindle."):
            if action == "spindle.stop":
                return [
                    self._step(
                        "spindle",
                        self._constant("SPINDLE_OFF"),
                        0,
                        expected=lambda: self._snapshot["spindleDirection"] == 0,
                    )
                ]
            self._guard("idle")
            steps = self._mode_steps("manual", "idle")
            if action in ("spindle.forward", "spindle.reverse"):
                speed = payload.get("speed", config.default_spindle or abs(s["spindleSpeed"]))
                speed = self._number(speed, "主轴转速 RPM", config.spindle_min, config.spindle_max)
                self._require(speed > 0, "必须明确配置或输入大于零的主轴转速")
                constant = "SPINDLE_FORWARD" if action.endswith("forward") else "SPINDLE_REVERSE"
                steps.append(
                    self._step("spindle", self._constant(constant), speed, 0, guard="idle")
                )
            elif action in ("spindle.increase", "spindle.decrease"):
                self._require(s["spindleDirection"] != 0, "主轴尚未启动")
                steps.append(
                    self._step(
                        "spindle",
                        self._constant(
                            "SPINDLE_INCREASE"
                            if action.endswith("increase")
                            else "SPINDLE_DECREASE"
                        ),
                        0,
                        guard="idle",
                    )
                )
            elif action == "spindle.brake":
                enabled = self._boolean(payload, s["spindleBrake"])
                self._require(not s["spindleDirection"], "主轴旋转时不能操作抱闸")
                steps.append(
                    self._step(
                        "brake",
                        self._constant("BRAKE_ENGAGE" if enabled else "BRAKE_RELEASE"),
                        guard="idle",
                    )
                )
            else:
                raise ValueError("不支持的主轴命令")
            return steps
        if action in ("coolant.flood", "coolant.mist"):
            self._guard("ready")
            key = action.split(".")[1]
            enabled = self._boolean(payload, s[key])
            return [
                self._step(
                    key,
                    self._constant(key.upper() + ("_ON" if enabled else "_OFF")),
                    guard="ready",
                    expected=lambda: self._snapshot[key] == enabled,
                )
            ]
        if action == "machine.override-limits":
            self._guard("idle")
            self._require(
                any(
                    j.get("min_hard_limit", False) or j.get("max_hard_limit", False)
                    for j in self._stat.joint[: self._stat.joints]
                ),
                "没有触发硬限位",
            )
            return self._mode_steps("manual", "idle") + [
                self._step("override_limits", guard="idle")
            ]
        if action in ("override.feed", "override.rapid", "override.spindle", "velocity.max"):
            self._guard("ready")
            limits = {
                "override.feed": ("feedrate", "feedOverride", 0, config.feed_max),
                "override.rapid": ("rapidrate", "rapidOverride", 0, 1),
                "override.spindle": (
                    "spindleoverride",
                    "spindleOverride",
                    config.spindle_override_min,
                    config.spindle_override_max,
                ),
                "velocity.max": ("maxvel", "maxVelocity", 0, config.max_velocity),
            }
            method, key, minimum, maximum = limits[action]
            self._require(maximum is not None and maximum >= 0, "INI 没有速度上限")
            value = self._number(
                payload.get("value"),
                "倍率" if action.startswith("override.") else "最大速度",
                minimum,
                maximum,
            )
            return [
                self._step(
                    method,
                    value,
                    guard="ready",
                    expected=lambda: math.isclose(
                        self._snapshot[key], value, rel_tol=1e-6, abs_tol=1e-9
                    ),
                )
            ]
        if action in ("file.open", "file.save"):
            self._require(not s["busy"] and not self._jogs, "运行时不能更换程序")
            path = payload.get("path")
            self._require(
                isinstance(path, str) and os.path.isabs(path) and "\x00" not in path,
                "程序路径必须为绝对路径",
            )
            self._require(len(path.encode("utf-8")) <= 254, "程序路径过长")
            if action == "file.save":
                atomic_write(path, payload.get("text"))
            self._require(os.path.isfile(path), "程序文件不存在")
            return [
                self._step(
                    "program_open",
                    path,
                    expected=lambda: (
                        os.path.realpath(self._snapshot["file"]) == os.path.realpath(path)
                    ),
                )
            ]
        if action in ("tool.reload", "tooltable.save"):
            self._require(not s["busy"] and not self._jogs, "运行时不能重载刀具表")
            if action == "tooltable.save":
                text = payload.get("text")
                self._require(isinstance(text, str), "刀具表必须为文本")
                path = s["toolTablePath"]
                self._require(bool(path), "实际 INI 没有配置刀具表路径")
                tool_table(text)
                atomic_write(path, text)
            return [self._step("load_tool_table")]
        raise ValueError("尚不支持的控制动作：" + action)

    def _program_units(self, value, axis):
        if axis in "ABC":
            self._require(self._snapshot["angularUnits"] > 0, "未知角度单位")
            return value / self._snapshot["angularUnits"]
        codes = self._snapshot["activeCodes"]
        self._require("G20" in codes or "G21" in codes, "未知 G20/G21 程序单位")
        # linear_units is native units per millimetre; payload is native units.
        return value / self._snapshot["linearUnits"] / (25.4 if "G20" in codes else 1)

    def _mdi_steps(self, text):
        self._guard("homedIdle")
        self._require(isinstance(text, str) and bool(text.strip()), "MDI 命令为空")
        text = text.strip()
        self._require(
            not any(char in text for char in "\x00\r\n") and len(text.encode("utf-8")) <= 254,
            "MDI 必须为单行且不超过 254 字节",
        )
        return self._mode_steps("mdi", "homedIdle") + [self._step("mdi", text, guard="homedIdle")]

    def stop_jog(self):
        """Cancel unsent starts and stop every jog owned by this controller."""
        had_pending = bool(
            self._steps and self._action in ("jog.start", "machine.jog-plus", "machine.jog-minus")
        )
        if had_pending:
            self._steps.clear()
        jogs = sorted(self._jogs)
        self._refresh(False)
        if not self._snapshot["connected"]:
            if jogs or had_pending:
                self._result("unknown", "连接不可用，无法确认点动已停止")
            return
        if jogs:
            self._steps = deque(
                self._step("jog", self._constant("JOG_STOP"), mode, index) for mode, index in jogs
            )
            self._action = "jog.stop"
            self._advance()
        elif had_pending:
            self._result("completed", "尚未发送的点动已取消")
        self._publish()

    def close(self):
        if self._closed:
            return
        self.stop_jog()
        # Stops are sent once; close never starts or replays another operation.
        self._steps.clear()
        self._closed = True
        self._stat = self._command = self._error_channel = None
        self._snapshot = offline("控制器已关闭")
        self._publish()

    def _capabilities(self):
        s = self._snapshot
        connected = s["connected"] and not self._closed
        ready = connected and s["powered"] and not s["estop"]
        idle = ready and not s["busy"] and not self._jogs
        free = not self._steps
        homed_idle = idle and self._homed()
        caps = {
            "machine.estop": connected,
            "machine.debug": connected and free and not s["busy"] and not self._jogs,
            "machine.power": connected and (s["powered"] or not s["estop"]),
            "program.stop": connected,
            "jog.stop": connected,
            "spindle.stop": connected,
            "program.run": homed_idle and bool(s["file"]) and free,
            "program.run-line": homed_idle and bool(s["file"]) and free,
            "program.step": ready and bool(s["file"]) and (homed_idle or s["paused"]) and free,
            "program.pause": ready
            and s["mode"] == "auto"
            and s["busy"]
            and not s["paused"]
            and free,
            "program.resume": ready and s["mode"] == "auto" and s["paused"] and free,
            "program.optional": connected and free,
            "program.block-delete": connected and free,
            "machine.mode": idle and free,
            "motion.mode": idle and free,
            "mode.joint": idle and free,
            "mode.world": homed_idle and free,
            "machine.home-all": idle and free,
            "machine.unhome-all": idle and free,
            "home": idle and free,
            "unhome": idle and free,
            "machine.home": idle and free,
            "machine.unhome": idle and free,
            "mdi.execute": homed_idle and free,
            "mdi.go": homed_idle and free,
            "machine.touch-off": homed_idle and free,
            "machine.zero-selected": homed_idle and free,
            "tool.touch-off": homed_idle and bool(s["tool"]) and free,
            "tool.reload": connected and not s["busy"] and not self._jogs and free,
            "file.open": connected and not s["busy"] and not self._jogs and free,
            "coolant.flood": ready and free,
            "coolant.mist": ready and free,
            "override.feed": ready and free,
            "override.rapid": ready and free,
            "override.spindle": ready and free,
            "velocity.max": ready and free,
            "spindle.forward": idle and free,
            "spindle.reverse": idle and free,
            "spindle.cw": idle and free,
            "spindle.ccw": idle and free,
            "spindle.increase": idle and bool(s["spindleDirection"]) and free,
            "spindle.decrease": idle and bool(s["spindleDirection"]) and free,
            "spindle.brake": idle and not s["spindleDirection"] and free,
            "machine.override-limits": idle
            and free
            and bool(
                self._stat
                and any(
                    j.get("min_hard_limit", False) or j.get("max_hard_limit", False)
                    for j in self._stat.joint[: self._stat.joints]
                )
            ),
        }
        for axis in AXES:
            mapped = bool(self._config and self._config.joint_map.get(axis))
            caps["machine.home-" + axis] = idle and free and axis in s["axes"] and mapped
            caps["machine.unhome-" + axis] = caps["machine.home-" + axis]
        for system in (*SYSTEMS, "G92"):
            caps["machine.zero-" + system] = homed_idle and free
        caps["file.save"] = caps["file.open"]
        caps["tooltable.save"] = caps["tool.reload"] and bool(s["toolTablePath"])
        caps["jog.start"] = idle and free and (s["motionMode"] == "joint" or self._homed())
        caps["machine.jog-plus"] = caps["machine.jog-minus"] = caps["jog.start"]
        return caps
