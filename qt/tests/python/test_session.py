"""Exercise the public client against a real, private Unix socket test peer."""

import json
import os
import socket
import struct
import tempfile
import threading
import unittest
from pathlib import Path

from bettercnc.session import RemoteError, SessionClient


def read_frame(connection):
    def exact(count):
        result = b""
        while len(result) < count:
            chunk = connection.recv(count - len(result))
            if not chunk:
                raise EOFError
            result += chunk
        return result

    size = struct.unpack("!I", exact(4))[0]
    return json.loads(exact(size))


class Peer:
    def __init__(self, responder, fragmented=False):
        self.temporary = tempfile.TemporaryDirectory(prefix="cnc-client-", dir="/tmp")
        self.path = Path(self.temporary.name) / "control.sock"
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(self.path))
        self.path.chmod(0o600)
        self.listener.listen()
        self.listener.settimeout(0.1)
        self.stop = threading.Event()
        self.requests = []
        self.responder = responder
        self.fragmented = fragmented
        self.connection = None
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        while not self.stop.is_set():
            try:
                connection, _ = self.listener.accept()
            except TimeoutError:
                continue
            except OSError:
                return
            self.connection = connection
            connection.settimeout(2)
            try:
                while not self.stop.is_set():
                    request = read_frame(connection)
                    self.requests.append(request)
                    result = self.responder(request)
                    if result is None:
                        break
                    response = {"version": 2, "request_id": request["request_id"], "result": result}
                    if "raw" in result:
                        response = result["raw"]
                    body = json.dumps(response).encode()
                    data = struct.pack("!I", len(body)) + body
                    if self.fragmented:
                        for index in range(0, len(data), 3):
                            connection.sendall(data[index : index + 3])
                    else:
                        connection.sendall(data)
            except (EOFError, OSError):
                pass
            finally:
                connection.close()
                self.connection = None

    def close(self):
        self.stop.set()
        if self.connection:
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        self.listener.close()
        self.thread.join(3)
        self.temporary.cleanup()


class SessionTests(unittest.TestCase):
    def peer(self, responder, **kwargs):
        peer = Peer(responder, **kwargs)
        self.addCleanup(peer.close)
        client = SessionClient(peer.path)
        self.addCleanup(client.close)
        return peer, client

    def test_fragmented_v2_status_does_not_claim_machine_connection(self):
        peer, client = self.peer(lambda _: {"connected": False}, fragmented=True)
        state = client.poll()
        self.assertFalse(state["connected"])
        self.assertTrue(client.connected)
        self.assertEqual([r["method"] for r in peer.requests], ["session.attach", "session.status"])

    def test_machine_command_disconnect_is_unknown_and_is_not_replayed(self):
        peer, client = self.peer(lambda r: {} if r["method"] == "session.attach" else None)
        client.connect()
        with self.assertRaises(RemoteError) as failure:
            client.execute("program.run", {})
        self.assertEqual(failure.exception.code, "result_unknown")
        self.assertFalse(client.connected)
        with self.assertRaises(ConnectionError):
            client.execute("program.run", {})
        self.assertEqual(sum(r["method"] == "command.execute" for r in peer.requests), 1)

    def test_incorrect_response_identity_disconnects(self):
        _, client = self.peer(
            lambda _: {"raw": {"version": 2, "request_id": "wrong", "result": {}}}
        )
        with self.assertRaises(ConnectionError):
            client.connect()
        self.assertFalse(client.connected)

    def test_v1_health_cannot_impersonate_control_protocol(self):
        _, client = self.peer(
            lambda r: {"raw": {"version": 1, "request_id": r["request_id"], "result": {}}}
        )
        with self.assertRaises(ConnectionError):
            client.connect()

    def test_oversized_response_is_rejected(self):
        _, client = self.peer(lambda _: {"content": "x" * 65536})
        with self.assertRaises(ConnectionError):
            client.connect()

    def test_second_owner_rejection_is_clear(self):
        _, client = self.peer(
            lambda r: {
                "raw": {
                    "version": 2,
                    "request_id": r["request_id"],
                    "error": {"code": "control_in_use", "message": "已有控制界面连接"},
                }
            }
        )
        with self.assertRaises(RemoteError) as failure:
            client.connect()
        self.assertEqual(failure.exception.code, "control_in_use")
        self.assertFalse(client.connected)

    def test_public_endpoint_permissions_are_rejected_before_connect(self):
        peer, client = self.peer(lambda _: {})
        os.chmod(peer.path.parent, 0o755)
        with self.assertRaises(RemoteError) as failure:
            client.connect()
        self.assertEqual(failure.exception.code, "unsafe_endpoint")
        self.assertEqual(peer.requests, [])

    def test_explicit_command_is_not_sent_when_never_connected(self):
        peer, client = self.peer(lambda _: {})
        with self.assertRaises(ConnectionError):
            client.execute("machine.power")
        self.assertEqual(peer.requests, [])

    def test_requested_ini_is_checked_during_attach(self):
        peer = Peer(lambda _: {})
        self.addCleanup(peer.close)
        client = SessionClient(peer.path, ini_path="/tmp/expected.ini")
        self.addCleanup(client.close)
        client.connect()
        self.assertEqual(
            peer.requests[0]["params"], {"ini_path": str(Path("/tmp/expected.ini").resolve())}
        )

    def test_invalid_error_shape_disconnects_cleanly(self):
        _, client = self.peer(
            lambda r: {"raw": {"version": 2, "request_id": r["request_id"], "error": ["bad"]}}
        )
        with self.assertRaises(ConnectionError):
            client.connect()
        self.assertFalse(client.connected)

    def test_non_finite_state_is_not_published(self):
        _, client = self.peer(lambda _: {"actualPosition": [float("nan")]})
        with self.assertRaises(ConnectionError):
            client.connect()
        self.assertFalse(client.connected)


if __name__ == "__main__":
    unittest.main()
