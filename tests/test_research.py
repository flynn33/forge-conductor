"""Tests for research tool pack."""

from __future__ import annotations

import httpx
import pytest

from forge_conductor.config import ensure_home
from forge_conductor.store import connect, document_get, migrate
from forge_conductor.tools import research as res


def test_web_search_unconfigured(forge_home, monkeypatch):
    ensure_home()
    monkeypatch.delenv("FORGE_SEARCH_API_KEY", raising=False)
    result = res.svc_web_search(
        "forge conductor",
        config={"search_provider": "none", "api_key_env": "FORGE_SEARCH_API_KEY"},
    )
    assert result["code"] == "provider_unconfigured"
    assert "message" in result
    assert result.get("retryable") is False
    assert result["detail"]["api_key_env"] == "FORGE_SEARCH_API_KEY"


def test_web_search_missing_key_even_with_provider_name(forge_home, monkeypatch):
    ensure_home()
    monkeypatch.delenv("FORGE_SEARCH_API_KEY", raising=False)
    result = res.svc_web_search(
        "query",
        config={"search_provider": "brave", "api_key_env": "FORGE_SEARCH_API_KEY"},
    )
    assert result["code"] == "provider_unconfigured"


def test_http_fetch_with_mock_transport(forge_home):
    ensure_home()
    body = b"hello research pack"

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=body, headers={"content-type": "text/plain"})

    transport = httpx.MockTransport(handler)
    original = httpx.Client

    class PatchedClient(original):
        def __init__(self, *args, **kwargs):
            kwargs["transport"] = transport
            super().__init__(*args, **kwargs)

    try:
        httpx.Client = PatchedClient  # type: ignore[misc, assignment]
        result = res.svc_http_fetch("https://example.test/doc")
    finally:
        httpx.Client = original  # type: ignore[misc, assignment]

    assert result.get("ok") is True
    assert result["status_code"] == 200
    assert result["body"] == "hello research pack"
    assert result["truncated"] is False


def test_http_fetch_size_limit(forge_home):
    ensure_home()
    big = b"x" * 5000

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=big, headers={"content-type": "text/plain"})

    transport = httpx.MockTransport(handler)
    original = httpx.Client

    class PatchedClient(original):
        def __init__(self, *args, **kwargs):
            kwargs["transport"] = transport
            super().__init__(*args, **kwargs)

    try:
        httpx.Client = PatchedClient  # type: ignore[misc, assignment]
        result = res.svc_http_fetch("https://example.test/big", max_bytes=1000)
    finally:
        httpx.Client = original  # type: ignore[misc, assignment]

    assert result.get("ok") is True
    assert result["truncated"] is True
    assert result["bytes"] == 1000
    assert len(result["body"]) == 1000


def test_doc_ingest_and_search_roundtrip(forge_home, tmp_path):
    ensure_home()
    conn = connect()
    migrate(conn)

    doc_path = tmp_path / "notes.txt"
    doc_path.write_text(
        "Forge-Conductor research notes about browser packs and documents.",
        encoding="utf-8",
    )

    ingested = res.svc_doc_ingest(conn, str(doc_path), title="Research Notes")
    assert ingested["ok"] is True
    assert ingested["title"] == "Research Notes"
    assert ingested["chars"] > 0

    row = document_get(conn, ingested["id"])
    assert row is not None
    assert "browser packs" in row["body"]

    found = res.svc_doc_search(conn, "browser packs")
    assert found["ok"] is True
    assert found["count"] >= 1
    assert any(r["id"] == ingested["id"] for r in found["results"])

    miss = res.svc_doc_search(conn, "zzzz-not-present-xyz")
    assert miss["count"] == 0


def test_doc_ingest_missing_file(forge_home, tmp_path):
    ensure_home()
    conn = connect()
    migrate(conn)
    missing = tmp_path / "no-such-file.txt"
    with pytest.raises(FileNotFoundError):
        res.svc_doc_ingest(conn, str(missing))
