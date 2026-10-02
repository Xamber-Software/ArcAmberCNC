"""Bounded v1 diagnostic and v2 single-owner control envelopes."""

import json
from dataclasses import dataclass

MAX_FRAME_BYTES = 65536


class ProtocolError(ValueError):
    def __init__(self, code, message, *, request_id="", version=2):
        super().__init__(message)
        self.code = code
        self.request_id = request_id
        self.version = version


@dataclass(frozen=True)
class Request:
    version: int
    request_id: str
    method: str
    params: dict


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate field")
        result[key] = value
    return result


def _invalid_constant(value):
    raise ValueError(f"invalid JSON constant: {value}")


def decode(payload):
    request_id, version = "", 1
    try:
        message = json.loads(
            payload, object_pairs_hook=_unique_object, parse_constant=_invalid_constant
        )
        if not isinstance(message, dict):
            raise ValueError("request must be an object")
        candidate = message.get("request_id")
        if not isinstance(candidate, str) or not 1 <= len(candidate) <= 64:
            raise ValueError("request_id must contain 1 to 64 characters")
        request_id = candidate
        received_version = message.get("version")
        if type(received_version) is not int or received_version not in (1, 2):
            raise ProtocolError(
                "unsupported_version",
                "supported protocol versions: 1, 2",
                request_id=request_id,
                version=version,
            )
        version = received_version
        expected = {"version", "request_id", "method"}
        if version == 2:
            expected.add("params")
        if set(message) != expected or not isinstance(message["method"], str):
            raise ValueError("request fields do not match the protocol")
        params = message.get("params", {})
        if not isinstance(params, dict):
            raise ValueError("params must be an object")
        return Request(version, request_id, message["method"], params)
    except ProtocolError:
        raise
    except (ValueError, UnicodeDecodeError, RecursionError) as error:
        raise ProtocolError(
            "invalid_request", str(error), request_id=request_id, version=version
        ) from None


def encode(version, request_id, *, result=None, error=None):
    message = {"version": version, "request_id": request_id}
    if error is not None:
        message["error"] = {"code": error.code}
        if version == 2:
            message["error"]["message"] = str(error)
    else:
        message["result"] = result
    data = json.dumps(message, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode(
        "utf-8"
    )
    if len(data) > MAX_FRAME_BYTES:
        # Never send an invalid frame, including an unexpectedly large snapshot.
        data = json.dumps(
            {
                "version": version,
                "request_id": request_id,
                "error": {"code": "response_too_large", "message": "response exceeds frame limit"},
            },
            separators=(",", ":"),
        ).encode()
    return data


def health(request):
    if request.method != "health":
        raise ProtocolError("unsupported_method", "v1 permits only health")
    return {"service": "betterlinuxcnc", "mode": "diagnostics-only", "machine_connected": False}


def response(payload):
    """Legacy internal helper retained for v1 callers."""
    try:
        request = decode(payload)
        if request.version != 1:
            raise ProtocolError(
                "unsupported_version", "use a v2 session", request_id=request.request_id, version=1
            )
        return encode(1, request.request_id, result=health(request))
    except ProtocolError as error:
        return encode(error.version, error.request_id, error=error)
