from pathlib import Path

import pytest

from forge_conductor.config import get_home, ensure_home, load_config, default_config


def test_get_home_from_env(forge_home):
    assert get_home() == forge_home


def test_ensure_home_creates_layout(forge_home):
    ensure_home()
    assert (forge_home / "config.toml").is_file()
    assert (forge_home / "agents").is_dir()
    assert (forge_home / "cache").is_dir()


def test_load_config_defaults(forge_home):
    ensure_home()
    cfg = load_config()
    assert cfg["browser"]["headless"] is True
    assert cfg["coordinator"]["enabled"] is True
    assert cfg["coordinator"]["lease_ttl_sec"] == 60
    assert cfg["coordinator"]["presence_ttl_sec"] == 30


def test_default_config_keys():
    cfg = default_config()
    assert "log_level" in cfg
    assert "profile_dir" in cfg["browser"]
    assert "default_timeout_sec" in cfg["shell"]
    assert "search_provider" in cfg["research"]
    assert "api_key_env" in cfg["research"]
    assert "allowed_roots" in cfg
    assert cfg["browser"]["headless"] is True
    assert cfg["browser"]["profile_dir"] == ""
    assert cfg["coordinator"]["enabled"] is True
    assert cfg["coordinator"]["lease_ttl_sec"] == 60
    assert cfg["coordinator"]["presence_ttl_sec"] == 30
    assert cfg["shell"]["default_timeout_sec"] == 30
    assert cfg["research"]["search_provider"] == "none"
    assert cfg["research"]["api_key_env"] == "FORGE_SEARCH_API_KEY"
    assert cfg["allowed_roots"] == []


def test_load_config_corrupt_raises(forge_home):
    ensure_home()
    (forge_home / "config.toml").write_text("[[[not valid", encoding="utf-8")
    with pytest.raises((ValueError, Exception)) as exc_info:
        load_config()
    assert "config.toml" in str(exc_info.value).lower() or "config" in str(exc_info.value).lower()
