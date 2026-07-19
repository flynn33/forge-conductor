"""Structured tool error types and payload helpers."""

from __future__ import annotations

from typing import Any


class ToolError(Exception):
    """Structured error raised or converted for MCP tool responses."""

    def __init__(
        self,
        code: str,
        message: str,
        retryable: bool = False,
        detail: Any = None,
    ) -> None:
        self.code = code
        self.message = message
        self.retryable = retryable
        self.detail = detail if detail is not None else {}
        super().__init__(message)


def tool_error_payload(exc: ToolError | Exception) -> dict[str, Any]:
    """Return a structured error dict: code, message, retryable, detail.

    Accepts :class:`ToolError` or a generic exception (mapped to
    ``code="error"``, non-retryable).
    """
    if isinstance(exc, ToolError):
        detail = exc.detail if isinstance(exc.detail, dict) else {"value": exc.detail}
        return {
            "code": exc.code,
            "message": exc.message,
            "retryable": bool(exc.retryable),
            "detail": detail or {},
        }
    return {
        "code": "error",
        "message": str(exc),
        "retryable": False,
        "detail": {},
    }
