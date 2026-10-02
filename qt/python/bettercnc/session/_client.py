"""Versioned, bounded request/reply connection to the private Unix endpoint."""

import json
import os
import socket
import stat
import struct
import tempfile
import uuid
from pathlib import Path

MAX_FRAME_BYTES = 65536


class RemoteError(RuntimeError):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def _unique_object(items):
    value = {}
    for key, item in items:
        if key in value:
            raise ValueError("服务响应包含重复字段")
        value[key] = item
    return value


def _invalid_constant(value):
    raise ValueError(f"服务响应包含非法数值：{value}")


class SessionClient:
    """One owner connection. Failed commands are never reconnected or replayed."""

    def __init__(self, path=None, *, ini_path=None):
        runtime = Path(os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir())
        self.path = Path(path) if path else runtime / "betterlinuxcnc/control.sock"
        self._socket = None
        self._ini = str(Path(ini_path).expanduser().resolve()) if ini_path else None

    @property
    def connected(self):
        return self._socket is not None

    def connect(self):
        self.close()
        directory = self.path.parent.lstat()
        endpoint = self.path.lstat()
        if (
            not stat.S_ISDIR(directory.st_mode)
            or directory.st_uid != os.getuid()
            or stat.S_IMODE(directory.st_mode) & 0o077
            or not stat.S_ISSOCK(endpoint.st_mode)
            or endpoint.st_uid != os.getuid()
            or stat.S_IMODE(endpoint.st_mode) & 0o077
        ):
            raise RemoteError("unsafe_endpoint", "本地服务 socket 的所有者或私有权限不正确")
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(2)
        try:
            connection.connect(str(self.path))
            self._socket = connection
            self.request("session.attach", {"ini_path": self._ini} if self._ini else {})
        except Exception:
            connection.close()
            self._socket = None
            raise

    def close(self):
        if self._socket is not None:
            self._socket.close()
            self._socket = None

    def _read(self, size):
        chunks = bytearray()
        while len(chunks) < size:
            chunk = self._socket.recv(size - len(chunks))
            if not chunk:
                raise ConnectionError("本地服务连接中断")
            chunks.extend(chunk)
        return bytes(chunks)

    def request(self, method, params):
        if self._socket is None:
            raise ConnectionError("本地控制服务尚未连接")
        request_id = uuid.uuid4().hex
        payload = json.dumps(
            {"version": 2, "request_id": request_id, "method": method, "params": params},
            ensure_ascii=False,
            allow_nan=False,
            separators=(",", ":"),
        ).encode("utf-8")
        if len(payload) > MAX_FRAME_BYTES:
            raise ValueError("本地服务请求超过报文大小限制")
        try:
            self._socket.settimeout(8 if method == "command.execute" else 2)
            self._socket.sendall(struct.pack("!I", len(payload)) + payload)
            length = struct.unpack("!I", self._read(4))[0]
            if not 0 < length <= MAX_FRAME_BYTES:
                raise ValueError("本地服务响应长度无效")
            response = json.loads(
                self._read(length),
                object_pairs_hook=_unique_object,
                parse_constant=_invalid_constant,
            )
            if (
                not isinstance(response, dict)
                or type(response.get("version")) is not int
                or response["version"] != 2
                or response.get("request_id") != request_id
                or set(response)
                not in ({"version", "request_id", "result"}, {"version", "request_id", "error"})
            ):
                raise ValueError("本地控制服务协议不匹配")
            if "error" in response:
                problem = response["error"]
                if (
                    not isinstance(problem, dict)
                    or set(problem) != {"code", "message"}
                    or not isinstance(problem["code"], str)
                    or not isinstance(problem["message"], str)
                ):
                    raise ValueError("本地服务返回了无效错误")
                raise RemoteError(problem["code"], problem["message"])
            if not isinstance(response["result"], dict):
                raise ValueError("本地服务返回了无效结果")
            return response["result"]
        except RemoteError:
            raise
        except (OSError, ValueError, TypeError, KeyError) as error:
            self.close()
            if method == "command.execute":
                raise RemoteError(
                    "result_unknown", f"命令结果未知，已断开且不会自动重发：{error}"
                ) from error
            raise ConnectionError(f"本地服务通信失败：{error}") from error

    def poll(self, jog_lease=False):
        if not self.connected:
            self.connect()
        return self.request("session.status", {"jog_lease": bool(jog_lease)})

    def execute(self, action, payload=None):
        return self.request("command.execute", {"action": action, "payload": payload or {}})
