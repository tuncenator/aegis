import json
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent.parent
CLI = REPO / "bin" / "aegis"


def _run(*args, env=None):
    return subprocess.run([str(CLI), *args], capture_output=True, text=True, env=env)


@pytest.fixture
def isolated_state(tmp_path, monkeypatch):
    monkeypatch.setenv("AEGIS_STATE_DIR", str(tmp_path))
    return tmp_path


def test_status_no_session_returns_message(isolated_state, monkeypatch):
    r = _run("status")
    assert r.returncode == 0
    assert "no session" in r.stdout.lower() or "no active" in r.stdout.lower()


def test_off_then_on_round_trip(isolated_state, monkeypatch):
    monkeypatch.setenv("AEGIS_STATE_DIR", str(isolated_state))
    r = _run("off", "--session", "s1", env={**__import__("os").environ, "AEGIS_STATE_DIR": str(isolated_state)})
    assert r.returncode == 0
    state_file = isolated_state / "s1.json"
    assert state_file.exists()
    obj = json.loads(state_file.read_text())
    assert obj["enabled"] is False

    r = _run("on", "--session", "s1", env={**__import__("os").environ, "AEGIS_STATE_DIR": str(isolated_state)})
    assert r.returncode == 0
    obj = json.loads(state_file.read_text())
    assert obj["enabled"] is True
    assert obj["consecutive_denies"] == 0


def test_status_specific_session(isolated_state, monkeypatch):
    state_file = isolated_state / "s2.json"
    state_file.write_text(json.dumps({
        "session_id": "s2", "enabled": True, "consecutive_denies": 1,
        "total_denies": 3, "paused_reason": None, "last_decision_at": "2026-04-30T00:00:00Z",
    }))
    r = _run("status", "--session", "s2",
             env={**__import__("os").environ, "AEGIS_STATE_DIR": str(isolated_state)})
    assert r.returncode == 0
    assert "enabled" in r.stdout.lower()
    assert "s2" in r.stdout
