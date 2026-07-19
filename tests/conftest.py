import os
import pytest
from pathlib import Path


@pytest.fixture
def forge_home(tmp_path, monkeypatch):
    home = tmp_path / "forge-home"
    home.mkdir()
    monkeypatch.setenv("FORGE_CONDUCTOR_HOME", str(home))
    return home
