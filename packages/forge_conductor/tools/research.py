"""Research tools: web search, HTTP fetch, document ingest/search + FastMCP registration."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import httpx

from forge_conductor import store

# Default fetch limits
_DEFAULT_TIMEOUT_SEC = 30.0
_MAX_BODY_BYTES = 2 * 1024 * 1024  # ~2MB


def _structured_error(
    code: str,
    message: str,
    *,
    retryable: bool = False,
    detail: dict[str, Any] | None = None,
) -> dict[str, Any]:
    from forge_conductor.errors import ToolError, tool_error_payload

    return tool_error_payload(
        ToolError(code, message, retryable=retryable, detail=detail or {})
    )


def _research_config() -> dict[str, Any]:
    from forge_conductor.config import default_config, load_config
    from forge_conductor.server import get_ctx

    ctx = get_ctx()
    if ctx is not None and isinstance(ctx.config, dict):
        return dict(ctx.config.get("research") or {})
    try:
        cfg = load_config()
    except Exception:
        cfg = default_config()
    return dict(cfg.get("research") or {})


def _client_id() -> str | None:
    from forge_conductor.server import get_ctx

    ctx = get_ctx()
    return ctx.client_id if ctx is not None else None


def _require_conn():
    from forge_conductor.server import get_ctx

    ctx = get_ctx()
    if ctx is None:
        raise RuntimeError("Runtime context not initialized")
    return ctx.conn


def _audit(
    tool: str,
    args: dict[str, Any],
    *,
    status: str,
    error: str | None = None,
) -> None:
    from forge_conductor.server import get_ctx

    ctx = get_ctx()
    if ctx is None:
        return
    from forge_conductor import audit

    audit.append(
        ctx.conn,
        tool=tool,
        args=args,
        status=status,
        client_id=ctx.client_id,
        mutating=True,
        error=error,
    )


def svc_web_search(
    query: str,
    *,
    max_results: int = 5,
    config: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Search the web via configured provider.

    Without a configured provider/API key, returns a structured
    ``provider_unconfigured`` error (does not raise).
    """
    research = config if config is not None else _research_config()
    provider = str(research.get("search_provider") or "none").strip().lower()
    api_key_env = str(research.get("api_key_env") or "FORGE_SEARCH_API_KEY")
    api_key = os.environ.get(api_key_env) or ""

    if provider in ("", "none") or not api_key:
        return _structured_error(
            "provider_unconfigured",
            (
                "Web search provider is not configured. "
                f"Set research.search_provider and provide an API key via {api_key_env}."
            ),
            retryable=False,
            detail={
                "provider": provider or "none",
                "api_key_env": api_key_env,
                "query": query,
            },
        )

    # Future providers can be plugged in here; v1 only documents the error path.
    return _structured_error(
        "provider_unsupported",
        f"Search provider '{provider}' is not implemented in this version.",
        retryable=False,
        detail={
            "provider": provider,
            "api_key_env": api_key_env,
            "query": query,
            "max_results": max_results,
        },
    )


def svc_http_fetch(
    url: str,
    *,
    timeout_sec: float = _DEFAULT_TIMEOUT_SEC,
    max_bytes: int = _MAX_BODY_BYTES,
    headers: dict[str, str] | None = None,
    client_id: str | None = None,
) -> dict[str, Any]:
    """Fetch *url* with httpx; enforce timeout and size limit (~2MB default)."""
    del client_id  # reserved; audit uses get_ctx when present
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"):
        return _structured_error(
            "invalid_url",
            f"URL scheme must be http or https, got {parsed.scheme!r}",
            retryable=False,
            detail={"url": url},
        )

    try:
        with httpx.Client(
            timeout=timeout_sec,
            follow_redirects=True,
            headers=headers,
        ) as client:
            with client.stream("GET", url) as response:
                chunks: list[bytes] = []
                total = 0
                truncated = False
                for chunk in response.iter_bytes():
                    if not chunk:
                        continue
                    remaining = max_bytes - total
                    if remaining <= 0:
                        truncated = True
                        break
                    if len(chunk) > remaining:
                        chunks.append(chunk[:remaining])
                        total += remaining
                        truncated = True
                        break
                    chunks.append(chunk)
                    total += len(chunk)

                raw = b"".join(chunks)
                content_type = response.headers.get("content-type", "")
                # Decode text-ish bodies; otherwise note binary
                text: str | None
                if "charset=" in content_type.lower() or content_type.lower().startswith(
                    ("text/", "application/json", "application/xml", "application/javascript")
                ) or not content_type:
                    text = raw.decode("utf-8", errors="replace")
                else:
                    # still attempt utf-8 for unknown types
                    try:
                        text = raw.decode("utf-8")
                    except UnicodeDecodeError:
                        text = None

                result: dict[str, Any] = {
                    "ok": True,
                    "url": str(response.url),
                    "status_code": response.status_code,
                    "headers": {
                        k: v
                        for k, v in response.headers.items()
                        if k.lower() in ("content-type", "content-length", "server")
                    },
                    "bytes": total,
                    "truncated": truncated,
                    "body": text if text is not None else None,
                    "binary": text is None,
                }
                _audit(
                    "http_fetch",
                    {
                        "url": url,
                        "status_code": response.status_code,
                        "bytes": total,
                        "truncated": truncated,
                    },
                    status="ok" if response.is_success else "error",
                )
                return result
    except httpx.TimeoutException as exc:
        _audit("http_fetch", {"url": url}, status="error", error=str(exc))
        return _structured_error(
            "timeout",
            f"Request timed out after {timeout_sec}s",
            retryable=True,
            detail={"url": url},
        )
    except httpx.HTTPError as exc:
        _audit("http_fetch", {"url": url}, status="error", error=str(exc))
        return _structured_error(
            "fetch_failed",
            str(exc),
            retryable=True,
            detail={"url": url},
        )


def _load_ingest_body(path_or_url: str, *, timeout_sec: float = _DEFAULT_TIMEOUT_SEC) -> tuple[str, str]:
    """Return (body, resolved_source) for a local path or http(s) URL."""
    parsed = urlparse(path_or_url)
    if parsed.scheme in ("http", "https"):
        fetched = svc_http_fetch(path_or_url, timeout_sec=timeout_sec)
        if fetched.get("code"):
            raise ValueError(fetched.get("message") or "fetch failed")
        if fetched.get("binary") or fetched.get("body") is None:
            raise ValueError("Fetched content is not text")
        return str(fetched["body"]), str(fetched.get("url") or path_or_url)

    path = Path(path_or_url).expanduser().resolve()
    if not path.is_file():
        raise FileNotFoundError(f"Not a file: {path}")
    return path.read_text(encoding="utf-8", errors="replace"), str(path)


def svc_doc_ingest(
    conn,
    path_or_url: str,
    *,
    title: str | None = None,
    client_id: str | None = None,
) -> dict[str, Any]:
    """Load text from a local path or URL and store as a document."""
    del client_id
    body, source = _load_ingest_body(path_or_url)
    doc_title = title if title else (Path(source).name if not source.startswith("http") else source)
    row = store.document_ingest(conn, title=doc_title, body=body, source=source)
    _audit(
        "doc_ingest",
        {"id": row["id"], "title": row["title"], "source": source, "chars": len(body)},
        status="ok",
    )
    return {
        "ok": True,
        "id": row["id"],
        "title": row["title"],
        "source": row["source"],
        "created_at": row["created_at"],
        "chars": len(body),
    }


def svc_doc_search(
    conn,
    query: str,
    *,
    limit: int = 50,
) -> dict[str, Any]:
    """Search ingested documents by title/body LIKE match."""
    hits = store.document_search(conn, query, limit=limit)
    # Omit full body from list results for brevity; include a snippet
    results = []
    for h in hits:
        body = h["body"] or ""
        snippet = body[:300] + ("…" if len(body) > 300 else "")
        results.append(
            {
                "id": h["id"],
                "title": h["title"],
                "source": h["source"],
                "created_at": h["created_at"],
                "snippet": snippet,
            }
        )
    return {"ok": True, "query": query, "count": len(results), "results": results}


def register(mcp: Any) -> None:
    """Register research tools on *mcp* and record names in TOOL_NAMES."""
    from forge_conductor.server import TOOL_NAMES

    @mcp.tool
    def web_search(query: str, max_results: int = 5) -> dict[str, Any]:
        """Search the web (requires configured provider + API key)."""
        return svc_web_search(query, max_results=max_results)

    @mcp.tool
    def http_fetch(
        url: str,
        timeout_sec: float = _DEFAULT_TIMEOUT_SEC,
        max_bytes: int = _MAX_BODY_BYTES,
    ) -> dict[str, Any]:
        """Fetch a URL; returns status, headers subset, and body (size-limited)."""
        return svc_http_fetch(
            url,
            timeout_sec=timeout_sec,
            max_bytes=max_bytes,
            client_id=_client_id(),
        )

    @mcp.tool
    def doc_ingest(path_or_url: str, title: str | None = None) -> dict[str, Any]:
        """Ingest a local file or URL body into the documents store."""
        return svc_doc_ingest(
            _require_conn(),
            path_or_url,
            title=title,
            client_id=_client_id(),
        )

    @mcp.tool
    def doc_search(query: str, limit: int = 50) -> dict[str, Any]:
        """Search previously ingested documents by substring."""
        return svc_doc_search(_require_conn(), query, limit=limit)

    TOOL_NAMES.update(
        {
            "web_search",
            "http_fetch",
            "doc_ingest",
            "doc_search",
        }
    )
