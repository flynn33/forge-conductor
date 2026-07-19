"""Tests for Playwright browser tool pack."""

from __future__ import annotations

import pytest

from forge_conductor.config import ensure_home
from forge_conductor.tools import browser as br

# Simple self-contained HTML (no network)
_DATA_HTML = (
    "data:text/html,"
    "<!doctype html><html><head><title>Forge Browser Test</title></head>"
    "<body>"
    "<h1 id='heading'>Hello Forge</h1>"
    "<input id='name' type='text' value='' />"
    "<button id='btn' type='button'>Go</button>"
    "</body></html>"
)


def _chromium_available() -> bool:
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        return False
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            browser.close()
        return True
    except Exception:
        return False


pytestmark = pytest.mark.skipif(
    not _chromium_available(),
    reason="Playwright Chromium not installed (uv run playwright install chromium)",
)


@pytest.fixture(autouse=True)
def _close_browser_after():
    yield
    br.svc_close()


def test_navigate_snapshot_close(forge_home):
    ensure_home()
    nav = br.svc_navigate(_DATA_HTML)
    assert nav.get("ok") is True
    assert "Forge Browser Test" in (nav.get("title") or "")

    snap = br.svc_snapshot()
    assert snap.get("ok") is True
    assert "Hello Forge" in (snap.get("text") or "")
    assert "Forge Browser Test" in (snap.get("title") or "")

    closed = br.svc_close()
    assert closed.get("ok") is True
    assert closed.get("closed") is True


def test_click_type_screenshot(forge_home, tmp_path):
    ensure_home()
    br.svc_navigate(_DATA_HTML)

    typed = br.svc_type("#name", "conductor", clear=True)
    assert typed.get("ok") is True

    clicked = br.svc_click("#btn")
    assert clicked.get("ok") is True

    shot_path = tmp_path / "shot.png"
    shot = br.svc_screenshot(str(shot_path))
    assert shot.get("ok") is True
    assert shot_path.is_file()
    assert shot_path.stat().st_size > 0

    br.svc_close()
