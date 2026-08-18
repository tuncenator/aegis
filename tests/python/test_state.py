import json
import os
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


# --- pruning ----------------------------------------------------------------
# One state file is written per Claude Code session and nothing removed them,
# so ~/.cache/aegis/sessions grew to ~1k files in real use.

def test_prune_removes_only_files_older_than_ttl(tmp_state_dir):
    old = tmp_state_dir / "old.json"
    new = tmp_state_dir / "new.json"
    old.write_text("{}")
    new.write_text("{}")
    stale = time.time() - 30 * 86400
    os.utime(old, (stale, stale))

    assert state.prune(ttl_days=14) == 1
    assert not old.exists()
    assert new.exists()


def test_prune_ignores_non_json_entries(tmp_state_dir):
    stamp = tmp_state_dir / state.PRUNE_STAMP_NAME
    stamp.write_text("")
    stale = time.time() - 999 * 86400
    os.utime(stamp, (stale, stale))
    state.prune(ttl_days=1)
    assert stamp.exists()


def test_prune_ttl_zero_is_a_noop(tmp_state_dir):
    p = tmp_state_dir / "s.json"
    p.write_text("{}")
    stale = time.time() - 999 * 86400
    os.utime(p, (stale, stale))
    assert state.prune(ttl_days=0) == 0
    assert p.exists()


def test_prune_if_due_runs_once_per_interval(tmp_state_dir):
    p = tmp_state_dir / "s.json"
    p.write_text("{}")
    stale = time.time() - 999 * 86400
    os.utime(p, (stale, stale))

    assert state.prune_if_due(ttl_days=1) == 1
    # Second call inside the interval is skipped, stamp still fresh.
    other = tmp_state_dir / "s2.json"
    other.write_text("{}")
    os.utime(other, (stale, stale))
    assert state.prune_if_due(ttl_days=1) == 0
    assert other.exists()


def test_prune_if_due_runs_again_once_the_interval_lapses(tmp_state_dir):
    p = tmp_state_dir / "s.json"
    p.write_text("{}")
    stale = time.time() - 999 * 86400
    os.utime(p, (stale, stale))
    state.prune_if_due(ttl_days=1)

    stamp = tmp_state_dir / state.PRUNE_STAMP_NAME
    long_ago = time.time() - 2 * state.PRUNE_INTERVAL_S
    os.utime(stamp, (long_ago, long_ago))

    other = tmp_state_dir / "s2.json"
    other.write_text("{}")
    os.utime(other, (stale, stale))
    assert state.prune_if_due(ttl_days=1) == 1
    assert not other.exists()


def test_prune_survives_a_missing_state_dir(tmp_path, monkeypatch):
    monkeypatch.setattr(state, "STATE_DIR", tmp_path / "gone")
    assert state.prune(ttl_days=1) == 0


def test_prune_never_deletes_a_disabled_session(tmp_state_dir):
    """A disabled session's file is a standing decision, not a cache entry.

    __main__ returns early for a disabled session WITHOUT re-saving, so its
    mtime stops advancing the moment it is disabled and it looks stale almost
    immediately. Pruning it silently resurrected the session as enabled --
    the exact opposite of what `aegis off` was asked to do.
    """
    off = state.SessionState(session_id="turned-off", enabled=False, paused_reason="manual")
    state.save(off)
    paused = state.SessionState(session_id="auto-paused", enabled=False,
                                paused_reason="consecutive_deny_limit")
    state.save(paused)
    live = state.SessionState(session_id="still-on", enabled=True)
    state.save(live)

    stale = time.time() - 999 * 86400
    for name in ("turned-off", "auto-paused", "still-on"):
        p = tmp_state_dir / f"{name}.json"
        os.utime(p, (stale, stale))

    assert state.prune(ttl_days=1) == 1  # only the enabled one
    assert state.load("turned-off").enabled is False
    assert state.load("auto-paused").enabled is False
    assert state.load("auto-paused").paused_reason == "consecutive_deny_limit"
    assert not (tmp_state_dir / "still-on.json").exists()


def test_prune_rejects_a_non_integer_ttl(tmp_state_dir):
    p = tmp_state_dir / "s.json"
    p.write_text("{}")
    stale = time.time() - 999 * 86400
    os.utime(p, (stale, stale))
    assert state.prune(ttl_days="x") == 0
    assert state.prune(ttl_days=True) == 0
    assert p.exists()


def test_prune_skips_a_file_refreshed_after_the_stat(tmp_state_dir, monkeypatch):
    """Narrows the unlink race: re-stat immediately before removing."""
    p = tmp_state_dir / "racy.json"
    state.save(state.SessionState(session_id="racy", enabled=True))
    stale = time.time() - 999 * 86400
    os.utime(p, (stale, stale))

    real_load = state.load

    def touch_then_load(session_id):
        result = real_load(session_id)
        os.utime(p, None)  # concurrent writer refreshes the file
        return result

    monkeypatch.setattr(state, "load", touch_then_load)
    assert state.prune(ttl_days=1) == 0
    assert p.exists()
