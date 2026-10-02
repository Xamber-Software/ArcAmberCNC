"""Own disposable RS274 child processes and bounded pages, never NML commands."""

import asyncio
import contextlib
import json
import os
import sys
import tempfile
import uuid
from pathlib import Path

from ._protocol import ProtocolError


class PreviewJobs:
    def __init__(self, process_factory=None):
        self._spawn = process_factory or asyncio.create_subprocess_exec
        self._jobs = {}

    async def start(self, owner, path, context):
        if not isinstance(path, str) or not os.path.isabs(path) or not Path(path).is_file():
            raise ProtocolError(
                "invalid_params", "preview path must name an existing absolute file"
            )
        # One result per owner prevents unbounded processes, geometry and temp files.
        await self.clear(owner)
        directory = tempfile.TemporaryDirectory(prefix="bettercnc-preview-")
        folder = Path(directory.name)
        request = folder / "request.json"
        output = folder / "output.json"
        request.write_text(
            json.dumps({"path": path, "context": context}, allow_nan=False), encoding="utf-8"
        )
        job_id = uuid.uuid4().hex
        # The .deb launcher inserts a private library into sys.path. Child
        # interpreters do not inherit sys.path, so propagate the installed root.
        environment = os.environ.copy()
        package_root = str(Path(__file__).resolve().parents[1])
        inherited_path = environment.get("PYTHONPATH")
        environment["PYTHONPATH"] = package_root + (
            os.pathsep + inherited_path if inherited_path else ""
        )
        try:
            process = await self._spawn(
                sys.executable,
                "-m",
                "bettercnc_preview",
                "--request",
                str(request),
                "--output",
                str(output),
                stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
                env=environment,
            )
        except Exception:
            directory.cleanup()
            raise
        job = {"owner": owner, "process": process, "directory": directory, "result": None}
        self._jobs[job_id] = job
        job["task"] = asyncio.create_task(self._collect(job, output))
        return {"job_id": job_id}

    async def _collect(self, job, output):
        try:
            await asyncio.wait_for(job["process"].wait(), 30)
            if not output.is_file() or output.stat().st_size > 128 * 1024 * 1024:
                code = job["process"].returncode
                reason = f"signal {-code}" if code is not None and code < 0 else f"exit {code}"
                raise ValueError(f"解释器进程异常退出（{reason}），未返回有效的有界预览结果")
            result = await asyncio.to_thread(lambda: json.loads(output.read_text(encoding="utf-8")))
            if not isinstance(result, dict) or not isinstance(result.get("segments"), list):
                raise ValueError("invalid preview result")
            job["result"] = result
        except asyncio.CancelledError:
            raise
        except Exception as error:
            if job["process"].returncode is None:
                await self._terminate(job["process"])
            job["result"] = {
                "segments": [],
                "units": "mm",
                "bounds": {"min": [], "max": []},
                "error": {"message": str(error), "line": 0},
                "warnings": [],
                "truncated": False,
            }

    async def _terminate(self, process):
        if process.returncode is not None:
            return
        with contextlib.suppress(ProcessLookupError):
            process.terminate()
        try:
            await asyncio.wait_for(process.wait(), 2)
        except TimeoutError:
            with contextlib.suppress(ProcessLookupError):
                process.kill()
            await process.wait()

    def _owned(self, owner, job_id):
        if (
            not isinstance(job_id, str)
            or job_id not in self._jobs
            or self._jobs[job_id]["owner"] is not owner
        ):
            raise ProtocolError("unknown_job", "preview job is not owned by this session")
        return self._jobs[job_id]

    def read(self, owner, job_id, offset):
        job = self._owned(owner, job_id)
        if type(offset) is not int or offset < 0:
            raise ProtocolError("invalid_params", "offset must be a nonnegative integer")
        result = job["result"]
        reply = {
            "busy": result is None,
            "segments": [],
            "next_offset": offset,
            "done": False,
            "units": "mm",
            "bounds": {"min": [], "max": []},
            "error": None,
            "warnings": [],
            "truncated": False,
        }
        if result is None:
            return reply
        segments = result["segments"]
        if offset > len(segments):
            raise ProtocolError("invalid_params", "offset exceeds the preview result")
        reply.update(
            bounds=result.get("bounds", reply["bounds"]),
            error=result.get("error"),
            warnings=result.get("warnings", [])[:100],
            truncated=bool(result.get("truncated", False)),
        )
        page = segments[offset : offset + 256]
        reply["segments"] = page
        # Reserve envelope/id and UTF-8 overhead; never exceed the 64 KiB framing.
        while page and len(json.dumps(reply, ensure_ascii=False, allow_nan=False).encode()) > 60000:
            page.pop()
        if not page and offset < len(segments):
            raise ProtocolError("response_too_large", "one preview segment exceeds the frame limit")
        reply["next_offset"] = offset + len(page)
        reply["done"] = reply["next_offset"] == len(segments)
        return reply

    async def cancel(self, owner, job_id):
        job = self._owned(owner, job_id)
        self._jobs.pop(job_id)
        job["task"].cancel()
        await self._terminate(job["process"])
        await asyncio.gather(job["task"], return_exceptions=True)
        job["directory"].cleanup()
        return {"cancelled": True}

    async def clear(self, owner):
        for job_id, job in list(self._jobs.items()):
            if job["owner"] is owner:
                await self.cancel(owner, job_id)
