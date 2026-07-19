"""Tests for search tool pack."""

from __future__ import annotations

from forge_conductor.tools import search as search_tools


def test_search_text_finds_line(tmp_path, forge_home):
    root = tmp_path / "proj"
    root.mkdir()
    (root / "a.txt").write_text("alpha\nfind-me-token here\nomega\n", encoding="utf-8")
    (root / "b.txt").write_text("nothing interesting\n", encoding="utf-8")
    nested = root / "pkg"
    nested.mkdir()
    (nested / "c.py").write_text("# find-me-token in python\n", encoding="utf-8")

    result = search_tools.svc_search_text("find-me-token", root=str(root))
    assert result["count"] >= 2
    paths = {h["path"] for h in result["hits"]}
    assert any(p.endswith("a.txt") for p in paths)
    assert any(p.endswith("c.py") for p in paths)
    assert all("find-me-token" in h["text"] for h in result["hits"])


def test_search_files_finds_name(tmp_path, forge_home):
    root = tmp_path / "proj"
    root.mkdir()
    (root / "readme.md").write_text("# hi\n", encoding="utf-8")
    (root / "app.py").write_text("print(1)\n", encoding="utf-8")
    sub = root / "src"
    sub.mkdir()
    (sub / "util.py").write_text("x=1\n", encoding="utf-8")
    (sub / "data.json").write_text("{}\n", encoding="utf-8")

    py = search_tools.svc_search_files("*.py", root=str(root))
    assert py["count"] >= 2
    assert all(m.endswith(".py") for m in py["matches"])

    named = search_tools.svc_search_files("*util*", root=str(root))
    assert named["count"] >= 1
    assert any("util.py" in m for m in named["matches"])
