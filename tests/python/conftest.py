"""Pytest config -- makes the classifier importable and isolates every path
and environment variable that would otherwise let the operator's real setup
leak into a test run.

This matters more than usual here. Aegis reads ~/.config/aegis/aegis.toml at
classify time, so a developer whose own config sets [behavior] ask_mode =
"defer" used to see genuine, confusing failures: the suite asserts the
"prompt" default while the machine says defer. Tests must describe the code,
not the machine they run on.
"""
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT))

# Every AEGIS_* override the code honours. Any one of these left set in the
# developer's shell would silently steer a test.
AEGIS_ENV_VARS = (
    "AEGIS_ASK_MODE",
    "AEGIS_DEFER_SCOPE",
    "AEGIS_HARD_DENY_ACTION",
    "AEGIS_STATE_DIR",
    "AEGIS_TEST_MOCK_DECISION",
)


@pytest.fixture(autouse=True)
def _isolate_environment(tmp_path, monkeypatch):
    """Point HOME, the global config, and the session state dir at tmp.

    HOME is redirected for the benefit of subprocesses (tests/python/test_cli.py
    shells out to bin/aegis), but the module-level constants derived from
    Path.home() were already resolved at import time, so they are patched
    directly as well.
    """
    from classifier import rules, state
    from classifier.providers import base

    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))
    for var in AEGIS_ENV_VARS:
        monkeypatch.delenv(var, raising=False)

    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", home / ".config" / "aegis" / "aegis.toml")
    monkeypatch.setattr(state, "STATE_DIR", tmp_path / "sessions")
    monkeypatch.setattr(base, "_ERRORS_PATH", tmp_path / "errors.jsonl")
