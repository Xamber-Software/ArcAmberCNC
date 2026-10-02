"""Single-writer session ownership, serialized controller work and jog leases."""

import asyncio
import os
import time
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy

from bettercnc_controller import Controller

from ._preview_jobs import PreviewJobs
from ._protocol import ProtocolError
from ._wire_snapshot import wire_snapshot

JOG_LEASE_SECONDS = 0.6


class ControllerRuntime:
    def __init__(self, ini_path=None, controller_factory=None, process_factory=None):
        self._factory = controller_factory or Controller
        self._ini = ini_path
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="linuxcnc-owner")
        self._controller = None
        self._owner = None
        self._releasing = False
        self._generation = 0
        self._snapshot = None
        self._lease_deadline = None
        self._jog_expired = False
        self._jobs = PreviewJobs(process_factory)
        self._poll_task = asyncio.create_task(self._poll_loop())

    async def _work(self, function, *args):
        return await asyncio.get_running_loop().run_in_executor(self._executor, function, *args)

    def _expired(self):
        return self._lease_deadline is not None and time.monotonic() >= self._lease_deadline

    def _poll(self, generation):
        if self._releasing or generation != self._generation or self._controller is None:
            return
        if self._expired() or self._jog_expired:
            self._jog_expired = False
            self._lease_deadline = None
            self._controller.stop_jog()
        self._snapshot = self._controller.poll()

    async def _poll_loop(self):
        while True:
            if self._owner is not None and not self._releasing:
                try:
                    await self._work(self._poll, self._generation)
                except Exception:
                    # A vendor adapter exception must not make a stale online
                    # snapshot available to command/preview callers.
                    self._snapshot = None
            await asyncio.sleep(0.1)

    def _new_controller(self, generation):
        if generation != self._generation:
            return None
        self._controller = self._factory(ini_path=self._ini)
        self._snapshot = self._controller.poll()
        return self._snapshot

    def _close_controller(self):
        if self._controller is not None:
            try:
                # close cancels unsent operations and stops owned jogs only;
                # never abort a machining program when a desktop disconnects.
                self._controller.close()
            finally:
                self._controller = None
        self._snapshot = None

    async def release(self, owner):
        if self._owner is not owner:
            return
        self._releasing = True
        self._generation += 1  # invalidate queued work before awaiting anything
        self._lease_deadline = None
        self._jog_expired = True
        try:
            await self._work(self._close_controller)
        finally:
            await self._jobs.clear(owner)
            if self._owner is owner:
                self._owner = None
                self._releasing = False

    async def close(self):
        self._poll_task.cancel()
        await asyncio.gather(self._poll_task, return_exceptions=True)
        if self._owner is not None:
            await self.release(self._owner)
        self._executor.shutdown(wait=False, cancel_futures=True)

    def _params(self, params, required=(), optional=()):
        if not set(required).issubset(params) or not set(params).issubset(
            set(required) | set(optional)
        ):
            raise ProtocolError("invalid_params", "parameters do not match this method")

    def _observed(self):
        if self._snapshot is None:
            raise ProtocolError("status_unavailable", "controller status is unavailable")
        return wire_snapshot(self._snapshot)

    def _execute(self, owner, generation, action, payload):
        if (
            self._releasing
            or owner is not self._owner
            or generation != self._generation
            or self._controller is None
        ):
            raise ProtocolError("session_expired", "control session expired before command send")
        if action in ("jog.start", "machine.jog-plus", "machine.jog-minus") and self._expired():
            self._controller.stop_jog()
            self._lease_deadline = None
            raise ProtocolError("jog_lease_expired", "jog lease expired before command send")
        accepted = self._controller.dispatch(action, payload)
        if accepted and action in ("jog.stop", "program.stop", "machine.estop", "machine.power"):
            self._lease_deadline = None
        if not accepted and action in ("jog.start", "machine.jog-plus", "machine.jog-minus"):
            self._controller.stop_jog()
            self._lease_deadline = None
        if self._expired():
            self._controller.stop_jog()
            self._lease_deadline = None
        self._snapshot = self._controller.snapshot
        return {"accepted": bool(accepted), "snapshot": wire_snapshot(self._snapshot)}

    async def handle(self, owner, method, params):
        if method == "session.attach":
            self._params(params, optional=("ini_path",))
            requested_ini = params.get("ini_path")
            if requested_ini is not None and (
                not isinstance(requested_ini, str) or not os.path.isabs(requested_ini)
            ):
                raise ProtocolError("invalid_params", "ini_path must be an absolute path")
            if (
                requested_ini
                and self._ini
                and os.path.realpath(requested_ini) != os.path.realpath(self._ini)
            ):
                raise ProtocolError(
                    "ini_mismatch", "desktop INI differs from the service configuration"
                )
            if self._owner is not None and self._owner is not owner:
                raise ProtocolError("control_in_use", "another desktop owns machine control")
            if self._owner is None:
                self._owner = owner
                self._generation += 1
                self._lease_deadline = None
                self._jog_expired = False
                try:
                    await self._work(self._new_controller, self._generation)
                except Exception:
                    await self.release(owner)
                    raise
            observed = self._observed()
            actual_ini = observed.get("iniPath") or self._ini
            if requested_ini and (
                not actual_ini or os.path.realpath(requested_ini) != os.path.realpath(actual_ini)
            ):
                await self.release(owner)
                raise ProtocolError(
                    "ini_mismatch", "desktop INI cannot be matched to the running controller"
                )
            return observed
        if self._owner is not owner:
            raise ProtocolError("not_attached", "attach this connection before using v2 methods")
        if method == "session.status":
            self._params(params, optional=("jog_lease",))
            renewal = params.get("jog_lease", False)
            if type(renewal) is not bool:
                raise ProtocolError("invalid_params", "jog_lease must be boolean")
            if self._expired():
                self._jog_expired = True
            elif renewal and self._lease_deadline is not None:
                self._lease_deadline = time.monotonic() + JOG_LEASE_SECONDS
            return self._observed()
        if method == "command.execute":
            self._params(params, required=("action", "payload"))
            action, payload = params["action"], params["payload"]
            if not isinstance(action, str) or not action or not isinstance(payload, dict):
                raise ProtocolError(
                    "invalid_params", "action must be a string and payload an object"
                )
            if action in ("jog.start", "machine.jog-plus", "machine.jog-minus"):
                self._lease_deadline = time.monotonic() + JOG_LEASE_SECONDS
                self._jog_expired = False
            return await self._work(self._execute, owner, self._generation, action, payload)
        if method == "preview.start":
            self._params(params, required=("path",))
            context = deepcopy(self._snapshot or {})
            if not context.get("connected"):
                raise ProtocolError(
                    "status_unavailable", "preview needs an observed machine configuration"
                )
            keys = (
                "g5xIndex",
                "axisMask",
                "blockDelete",
                "actualPosition",
                "g5xOffset",
                "g92Offset",
                "toolOffset",
                "rotationXY",
                "linearUnits",
                "angularUnits",
                "randomToolChanger",
                "iniPath",
                "parameterFile",
                "toolTablePath",
                "toolTable",
            )
            context = {key: context[key] for key in keys if context.get(key) is not None}
            return await self._jobs.start(owner, params["path"], context)
        if method == "preview.read":
            self._params(params, required=("job_id", "offset"))
            return self._jobs.read(owner, params["job_id"], params["offset"])
        if method == "preview.cancel":
            self._params(params, required=("job_id",))
            return await self._jobs.cancel(owner, params["job_id"])
        raise ProtocolError("unsupported_method", "unsupported v2 method")
