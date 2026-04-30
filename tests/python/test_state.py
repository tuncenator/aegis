import json
import time
from pathlib import Path

import pytest

from classifier import state


@pytest.fixture
def tmp_state_dir(tmp_path, monkeypatch):
    monkeypatch.setattr(state, "STATE_DIR", tmp_path)
    return tmp_path


def test_load_missing_returns_default(tmp_state_dir):
    s = state.load("session-1")
    assert s.session_id == "session-1"
    assert s.enabled is True
    assert s.consecutive_denies == 0
    assert s.total_denies == 0
    assert s.paused_reason is None


def test_save_then_load_round_trip(tmp_state_dir):
    s = state.SessionState(session_id="abc", enabled=False, consecutive_denies=2,
                            total_denies=5, paused_reason="manual")
    state.save(s)
    loaded = state.load("abc")
    assert loaded == s


def test_record_decision_allow_resets_consecutive(tmp_state_dir):
    s = state.load("s1")
    s.consecutive_denies = 2
    state.record_decision(s, "allow")
    assert s.consecutive_denies == 0


def test_record_decision_deny_increments(tmp_state_dir):
    s = state.load("s1")
    state.record_decision(s, "deny")
    assert s.consecutive_denies == 1
    assert s.total_denies == 1


def test_record_decision_deny_pauses_at_consecutive_limit(tmp_state_dir):
    s = state.load("s1")
    for _ in range(3):
        state.record_decision(s, "deny", consecutive_limit=3, total_limit=20)
    assert s.enabled is False
    assert s.paused_reason == "consecutive_deny_limit"


def test_record_decision_deny_pauses_at_total_limit(tmp_state_dir):
    s = state.load("s1")
    s.total_denies = 19
    state.record_decision(s, "deny", consecutive_limit=999, total_limit=20)
    assert s.enabled is False
    assert s.paused_reason == "total_deny_limit"


def test_corrupt_file_is_recovered(tmp_state_dir):
    p = tmp_state_dir / "session-bad.json"
    p.write_text("{ this is not json")
    s = state.load("session-bad")
    assert s.session_id == "session-bad"
    assert s.enabled is True
