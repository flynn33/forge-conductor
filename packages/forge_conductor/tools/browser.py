"""Browser tools: Playwright automation + FastMCP registration."""

from __future__ import annotations

import uuid
from pathlib import Path
from typing import Any

# Process-level Playwright state (lazy launch; closed by browser_close).
_pw: Any = None
_browser: Any = None
_context: Any = None
_page: Any = None
_profile_dir: Path | None = None


def _install_guidance() -> str:
    return (
        "Playwright Chromium is not available. Install browsers with: "
        "uv run playwright install chromium"
    )


def _structured_error(
    code: str,
    message: str,
    *,
    retryable: bool = False,
    detail: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "code": code,
        "message": message,
        "retryable": retryable,
        "detail": detail or {},
    }


def _config_and_ids() -> tuple[dict[str, Any], str, Path]:
    """Return (browser_config, client_id, home) from runtime ctx or defaults."""
    from forge_conductor.config import default_config, get_home, load_config
    from forge_conductor.server import get_ctx

    ctx = get_ctx()
    if ctx is not None:
        browser_cfg = dict((ctx.config.get("browser") or {}))
        return browser_cfg, ctx.client_id, ctx.home

    try:
        cfg = load_config()
    except Exception:
        cfg = default_config()
    browser_cfg = dict((cfg.get("browser") or {}))
    return browser_cfg, "default", get_home()


def _resolve_profile_dir() -> Path:
    browser_cfg, client_id, home = _config_and_ids()
    profile = (browser_cfg.get("profile_dir") or "").strip()
    if profile:
        path = Path(profile).expanduser()
    else:
        path = home / "cache" / "browser" / client_id
    path.mkdir(parents=True, exist_ok=True)
    return path


def _headless() -> bool:
    browser_cfg, _, _ = _config_and_ids()
    return bool(browser_cfg.get("headless", True))


def _client_id() -> str | None:
    from forge_conductor.server import get_ctx

    ctx = get_ctx()
    return ctx.client_id if ctx is not None else None


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


def _ensure_page() -> Any:
    """Lazy-launch Chromium with a persistent context under the profile dir."""
    global _pw, _browser, _context, _page, _profile_dir

    if _page is not None:
        return _page

    try:
        from playwright.sync_api import sync_playwright
    except ImportError as exc:
        raise RuntimeError(_install_guidance()) from exc

    profile = _resolve_profile_dir()
    _profile_dir = profile
    headless = _headless()

    try:
        _pw = sync_playwright().start()
        # persistent_context keeps profile on disk per client_id
        _context = _pw.chromium.launch_persistent_context(
            user_data_dir=str(profile),
            headless=headless,
        )
        _browser = _context.browser
        if _context.pages:
            _page = _context.pages[0]
        else:
            _page = _context.new_page()
    except Exception as exc:
        _cleanup_soft()
        raise RuntimeError(f"{_install_guidance()} ({exc})") from exc

    return _page


def _cleanup_soft() -> None:
    """Best-effort teardown without raising."""
    global _pw, _browser, _context, _page, _profile_dir

    for obj, method in (
        (_context, "close"),
        (_browser, "close"),
        (_pw, "stop"),
    ):
        if obj is None:
            continue
        try:
            getattr(obj, method)()
        except Exception:
            pass

    _pw = None
    _browser = None
    _context = None
    _page = None
    _profile_dir = None


def svc_navigate(url: str, *, client_id: str | None = None) -> dict[str, Any]:
    """Navigate the browser to *url*. Audits when runtime ctx is available."""
    del client_id  # reserved; audit uses get_ctx when present
    page = _ensure_page()
    try:
        response = page.goto(url, wait_until="domcontentloaded")
        status = response.status if response is not None else None
        result = {
            "url": page.url,
            "title": page.title(),
            "status": status,
            "ok": True,
        }
        _audit("browser_navigate", {"url": url, "final_url": page.url, "status": status}, status="ok")
        return result
    except Exception as exc:
        _audit(
            "browser_navigate",
            {"url": url},
            status="error",
            error=str(exc),
        )
        return _structured_error(
            "navigate_failed",
            str(exc),
            retryable=True,
            detail={"url": url},
        )


def svc_snapshot() -> dict[str, Any]:
    """Return URL, title, visible text, and a compact accessibility snapshot."""
    page = _ensure_page()
    text = ""
    try:
        text = page.inner_text("body")
    except Exception:
        try:
            text = page.content()
        except Exception:
            text = ""

    a11y: Any = None
    try:
        a11y = page.accessibility.snapshot()
    except Exception:
        a11y = None

    # Cap large text payloads
    max_chars = 100_000
    truncated = len(text) > max_chars
    if truncated:
        text = text[:max_chars]

    return {
        "url": page.url,
        "title": page.title(),
        "text": text,
        "text_truncated": truncated,
        "accessibility": a11y,
        "ok": True,
    }


def svc_click(selector: str) -> dict[str, Any]:
    """Click the first element matching *selector*."""
    page = _ensure_page()
    try:
        page.click(selector, timeout=10_000)
        return {"ok": True, "selector": selector, "url": page.url}
    except Exception as exc:
        return _structured_error(
            "click_failed",
            str(exc),
            retryable=True,
            detail={"selector": selector},
        )


def svc_type(selector: str, text: str, *, clear: bool = False) -> dict[str, Any]:
    """Type *text* into the element matching *selector*."""
    page = _ensure_page()
    try:
        if clear:
            page.fill(selector, text, timeout=10_000)
        else:
            page.click(selector, timeout=10_000)
            page.keyboard.type(text)
        return {"ok": True, "selector": selector, "url": page.url}
    except Exception as exc:
        return _structured_error(
            "type_failed",
            str(exc),
            retryable=True,
            detail={"selector": selector},
        )


def svc_screenshot(path: str | None = None) -> dict[str, Any]:
    """Capture a PNG screenshot; write under profile dir if *path* omitted."""
    page = _ensure_page()
    if path:
        out = Path(path).expanduser()
        if not out.is_absolute():
            out = Path.cwd() / out
    else:
        profile = _profile_dir or _resolve_profile_dir()
        out = profile / f"screenshot-{uuid.uuid4().hex[:12]}.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    try:
        page.screenshot(path=str(out), full_page=True)
        return {"ok": True, "path": str(out), "url": page.url}
    except Exception as exc:
        return _structured_error(
            "screenshot_failed",
            str(exc),
            retryable=True,
            detail={"path": str(out)},
        )


def svc_close() -> dict[str, Any]:
    """Close browser/context and release Playwright resources."""
    had_session = _page is not None or _context is not None or _pw is not None
    _cleanup_soft()
    return {"ok": True, "closed": had_session}


def register(mcp: Any) -> None:
    """Register browser tools on *mcp* and record names in TOOL_NAMES."""
    from forge_conductor.server import TOOL_NAMES

    @mcp.tool
    def browser_navigate(url: str) -> dict[str, Any]:
        """Navigate the browser to a URL (lazy-launches Chromium)."""
        return svc_navigate(url, client_id=_client_id())

    @mcp.tool
    def browser_snapshot() -> dict[str, Any]:
        """Return page URL, title, text content, and accessibility tree."""
        return svc_snapshot()

    @mcp.tool
    def browser_click(selector: str) -> dict[str, Any]:
        """Click an element matching the CSS/Playwright selector."""
        return svc_click(selector)

    @mcp.tool
    def browser_type(selector: str, text: str, clear: bool = False) -> dict[str, Any]:
        """Type text into an element; set clear=true to replace existing value."""
        return svc_type(selector, text, clear=clear)

    @mcp.tool
    def browser_screenshot(path: str | None = None) -> dict[str, Any]:
        """Capture a full-page PNG screenshot to path (or profile cache)."""
        return svc_screenshot(path)

    @mcp.tool
    def browser_close() -> dict[str, Any]:
        """Close the browser session and clean up resources."""
        return svc_close()

    TOOL_NAMES.update(
        {
            "browser_navigate",
            "browser_snapshot",
            "browser_click",
            "browser_type",
            "browser_screenshot",
            "browser_close",
        }
    )
