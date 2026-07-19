"""Home directory layout and config.toml loading."""

from __future__ import annotations

import copy
import os
import tomllib
from pathlib import Path
from typing import Any


_DEFAULT_CONFIG_TOML = """\
# Forge-Conductor configuration
log_level = "info"
allowed_roots = []

[browser]
headless = true
profile_dir = ""

[coordinator]
enabled = true
lease_ttl_sec = 60
presence_ttl_sec = 30

[shell]
# Keep under typical Claude MCP host timeouts (~60s)
default_timeout_sec = 30

[research]
search_provider = "none"
api_key_env = "FORGE_SEARCH_API_KEY"
"""


def get_home() -> Path:
    """Return the Forge-Conductor home directory.

    Uses FORGE_CONDUCTOR_HOME when set; otherwise ~/.forge-conductor.
    """
    env = os.environ.get("FORGE_CONDUCTOR_HOME")
    if env:
        return Path(env)
    return Path.home() / ".forge-conductor"


def default_config() -> dict[str, Any]:
    """Return a deep copy of the default configuration."""
    return {
        "log_level": "info",
        "allowed_roots": [],
        "browser": {
            "headless": True,
            "profile_dir": "",
        },
        "coordinator": {
            "enabled": True,
            "lease_ttl_sec": 60,
            "presence_ttl_sec": 30,
        },
        "shell": {
            "default_timeout_sec": 30,
        },
        "research": {
            "search_provider": "none",
            "api_key_env": "FORGE_SEARCH_API_KEY",
        },
    }


def ensure_home() -> Path:
    """Create home directory layout and default config.toml if missing.

    Creates:
      - agents/
      - cache/
      - cache/browser/
      - config.toml (defaults only if not present)

    Returns the home path.
    """
    home = get_home()
    home.mkdir(parents=True, exist_ok=True)
    (home / "agents").mkdir(exist_ok=True)
    (home / "cache").mkdir(exist_ok=True)
    (home / "cache" / "browser").mkdir(exist_ok=True)
    (home / "bin").mkdir(exist_ok=True)
    (home / "logs").mkdir(exist_ok=True)
    (home / "scripts").mkdir(exist_ok=True)

    config_path = home / "config.toml"
    if not config_path.exists():
        config_path.write_text(_DEFAULT_CONFIG_TOML, encoding="utf-8")

    return home


def _deep_merge(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    """Deep-merge override into base (override wins). Does not mutate inputs."""
    result = copy.deepcopy(base)
    for key, value in override.items():
        if (
            key in result
            and isinstance(result[key], dict)
            and isinstance(value, dict)
        ):
            result[key] = _deep_merge(result[key], value)
        else:
            result[key] = copy.deepcopy(value)
    return result


def load_config() -> dict[str, Any]:
    """Load config.toml from home, deep-merged over defaults.

    Raises ValueError if config.toml exists but is unparseable.
    """
    home = get_home()
    config_path = home / "config.toml"
    defaults = default_config()

    if not config_path.is_file():
        return defaults

    try:
        raw = config_path.read_text(encoding="utf-8")
        file_cfg = tomllib.loads(raw)
    except tomllib.TOMLDecodeError as exc:
        raise ValueError(
            f"Failed to parse config.toml at {config_path}: {exc}"
        ) from exc
    except OSError as exc:
        raise ValueError(
            f"Failed to read config.toml at {config_path}: {exc}"
        ) from exc

    if not isinstance(file_cfg, dict):
        raise ValueError(
            f"config.toml at {config_path} must contain a TOML table at the root"
        )

    return _deep_merge(defaults, file_cfg)
