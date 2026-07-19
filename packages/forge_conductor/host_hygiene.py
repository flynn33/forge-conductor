"""Host hygiene: patch LM Studio Jinja templates and other host-side landmines.

LM Studio re-copies GGUF chat templates on model load; the stock Qwen template
raises on MCP multi-step rounds. We continuously neutralize that and similar
host issues so Forge can fail-forward.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any


BAD_MARKERS = (
    "No user query found in messages",
    "raise_exception('No user query found in messages.')",
)

GOOD_BLOCK = """{%- if ns.multi_step_tool %}
    {# MCP / tool multi-step may temporarily lack a plain user query; do not abort. #}
    {%- set ns.last_query_index = 0 %}
{%- endif %}"""

BAD_BLOCK = """{%- if ns.multi_step_tool %}
    {{- raise_exception('No user query found in messages.') }}
{%- endif %}"""


def _home() -> Path:
    return Path(os.environ.get("FORGE_CONDUCTOR_HOME", Path.home() / ".forge-conductor"))


def _diag(event: str, **fields: Any) -> None:
    rec = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "event": event,
        "src": "host_hygiene",
        **fields,
    }
    try:
        d = _home() / "logs"
        d.mkdir(parents=True, exist_ok=True)
        with (d / "failover-diagnostics.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, default=str) + "\n")
        with (d / "host-hygiene.log").open("a", encoding="utf-8") as fh:
            fh.write(f"{rec['ts']} {event} {json.dumps(fields, default=str)}\n")
    except OSError:
        pass


def patch_jinja_text(text: str) -> tuple[str, bool]:
    if "No user query found in messages" not in text:
        return text, False
    if BAD_BLOCK in text:
        return text.replace(BAD_BLOCK, GOOD_BLOCK), True
    old = "{{- raise_exception('No user query found in messages.') }}"
    if old in text:
        return (
            text.replace(
                old,
                "{%- set ns.last_query_index = 0 %}  {# MCP multi-step: no plain user query #}",
            ),
            True,
        )
    # looser
    if "raise_exception('No user query found in messages.')" in text:
        return (
            text.replace(
                "raise_exception('No user query found in messages.')",
                "set ns.last_query_index = 0",
            ),
            True,
        )
    return text, False


def _patch_file(path: Path) -> bool:
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        return False
    if "No user query found in messages" not in raw:
        return False
    # JSON files: walk strings
    if path.suffix.lower() == ".json":
        try:
            data = json.loads(raw)

            def walk(o: Any) -> bool:
                ch = False
                if isinstance(o, dict):
                    for k, v in list(o.items()):
                        if isinstance(v, str) and "No user query found in messages" in v:
                            nv, ok = patch_jinja_text(v)
                            if ok:
                                o[k] = nv
                                ch = True
                        else:
                            ch = walk(v) or ch
                elif isinstance(o, list):
                    for i, v in enumerate(o):
                        if isinstance(v, str) and "No user query found in messages" in v:
                            nv, ok = patch_jinja_text(v)
                            if ok:
                                o[i] = nv
                                ch = True
                        else:
                            ch = walk(v) or ch
                return ch

            if walk(data):
                path.write_text(
                    json.dumps(data, ensure_ascii=False, indent=2 if path.stat().st_size < 2_000_000 else None)
                    + ("\n" if path.stat().st_size < 2_000_000 else ""),
                    encoding="utf-8",
                )
                return True
        except (json.JSONDecodeError, OSError):
            nt, ok = patch_jinja_text(raw)
            if ok:
                try:
                    path.write_text(nt, encoding="utf-8")
                    return True
                except OSError:
                    return False
        return False

    nt, ok = patch_jinja_text(raw)
    if ok:
        try:
            path.write_text(nt, encoding="utf-8")
            return True
        except OSError:
            return False
    return False


def iter_jinja_targets() -> list[Path]:
    home = Path.home()
    out: list[Path] = []
    # Live engine templates (new folder every model load)
    temp = Path(os.environ.get("LOCALAPPDATA", str(home / "AppData" / "Local"))) / "Temp"
    if temp.is_dir():
        out.extend(temp.glob("lmstudio-llama-chat-template-*/chat-template.jinja"))
        out.extend(temp.glob("lmstudio-llama-chat-template-*/chat-template.ji"))
    # Conversations + model defaults + presets
    lm = home / ".lmstudio"
    if lm.is_dir():
        out.extend(lm.rglob("*.conversation.json"))
        cfg = lm / ".internal" / "user-concrete-model-default-config"
        if cfg.is_dir():
            out.extend(cfg.rglob("*.json"))
        presets = lm / "config-presets"
        if presets.is_dir():
            out.extend(presets.glob("*.json"))
    # Bundled safe template always available for copy
    return out


def patch_all_jinja() -> dict[str, Any]:
    patched: list[str] = []
    scanned = 0
    for p in iter_jinja_targets():
        if not p.is_file():
            continue
        try:
            if p.stat().st_size > 50_000_000:
                continue
        except OSError:
            continue
        scanned += 1
        if _patch_file(p):
            patched.append(str(p))
    # Ensure safe asset exists
    asset_dir = _home() / "scripts" / "assets"
    asset_dir.mkdir(parents=True, exist_ok=True)
    asset = asset_dir / "qwen-chat-template-mcp-safe.jinja"
    if not asset.is_file():
        # minimal note file if missing
        asset.write_text(
            "{# MCP-safe marker: multi_step_tool uses last_query_index=0 not raise #}\n",
            encoding="utf-8",
        )
    result = {
        "ok": True,
        "scanned": scanned,
        "patched_count": len(patched),
        "patched": patched[:40],
        "action": "jinja_no_user_query_neutralized",
    }
    _diag("jinja_patch", **{k: result[k] for k in ("scanned", "patched_count")})
    return result


def scan_lmstudio_log_for_jinja_errors(limit: int = 30) -> dict[str, Any]:
    """Read recent LM Studio main.log for template failures."""
    candidates = [
        Path(os.environ.get("APPDATA", "")) / "LM Studio" / "logs" / "main.log",
        Path.home() / "AppData" / "Roaming" / "LM Studio" / "logs" / "main.log",
    ]
    path = next((p for p in candidates if p.is_file()), None)
    if path is None:
        return {"ok": True, "log": None, "hits": 0, "recent": []}
    try:
        # tail-ish
        data = path.read_bytes()
        if len(data) > 400_000:
            data = data[-400_000:]
        text = data.decode("utf-8", errors="replace")
    except OSError as exc:
        return {"ok": False, "error": str(exc)}
    lines = [ln for ln in text.splitlines() if "No user query found" in ln or "applyPromptTemplate request returned 400" in ln]
    recent = lines[-limit:]
    return {
        "ok": True,
        "log": str(path),
        "hits": len(lines),
        "recent_count": len(recent),
        "latest": recent[-1][:300] if recent else None,
    }


def run_hygiene() -> dict[str, Any]:
    """Full host hygiene pass — safe to call frequently."""
    jinja = patch_all_jinja()
    logscan = scan_lmstudio_log_for_jinja_errors()
    # If log shows recent failures, patch again (new temp dirs)
    if logscan.get("hits", 0) > 0:
        jinja2 = patch_all_jinja()
        jinja["second_pass"] = jinja2
    presence = {"ok": False}
    try:
        from forge_conductor.store import connect

        conn = connect()
        n = conn.execute("SELECT COUNT(*) AS n FROM presence").fetchone()["n"]
        presence = {"ok": True, "presence_count": n}
    except Exception as exc:  # noqa: BLE001
        presence = {"ok": False, "error": str(exc)}

    out = {
        "ok": True,
        "jinja": jinja,
        "lmstudio_log": logscan,
        "presence": presence,
        "fail_forward": True,
        "host_steps": [
            "Jinja MCP abort patched where found (templates reappear on model reload — hygiene re-runs).",
            "If UI still stalled after patch: send a new message or start a new chat.",
            "Keep ForgeOrchestrator running so hygiene + MCP keepers survive reboot.",
        ],
    }
    _diag(
        "hygiene_run",
        patched=jinja.get("patched_count"),
        log_hits=logscan.get("hits"),
        presence=presence.get("presence_count"),
    )
    return out
