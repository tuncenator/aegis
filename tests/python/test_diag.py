"""Tests for classifier.diag -- JSONL decision log writer."""
import json
from pathlib import Path

import pytest

from classifier import diag


@pytest.fixture
def tmp_log(tmp_path):
    return tmp_path / "decisions.jsonl"


def test_emit_writes_jsonl_line(tmp_log):
    diag.emit(str(tmp_log), session_id="s1", tool="Bash", layer="hard-allow",
              decision="allow", reason="ok", model=None, latency_ms=4)
    lines = tmp_log.read_text().strip().splitlines()
    assert len(lines) == 1
    obj = json.loads(lines[0])
    assert obj["session_id"] == "s1"
    assert obj["layer"] == "hard-allow"
    assert obj["decision"] == "allow"
    assert "ts" in obj


def test_emit_appends(tmp_log):
    diag.emit(str(tmp_log), session_id="s1", tool="Bash", layer="hard-allow",
              decision="allow", reason="x", model=None, latency_ms=4)
    diag.emit(str(tmp_log), session_id="s1", tool="Edit", layer="classifier",
              decision="deny", reason="protected", model="gemini-x", latency_ms=420)
    lines = tmp_log.read_text().strip().splitlines()
    assert len(lines) == 2


def test_emit_handles_missing_dir(tmp_path):
    target = tmp_path / "subdir" / "decisions.jsonl"
    diag.emit(str(target), session_id="s", tool="Bash", layer="classifier",
              decision="allow", reason="x", model="m", latency_ms=10)
    assert target.exists()


# --- rotation ---------------------------------------------------------------
# The log is appended to on every non-fall-through decision. Unrotated it
# reached 70 MB / 242k rows in real use, so emit() now renames the file to
# <path>.1 once it crosses max_bytes.

def _row(path, **kw):
    diag.emit(
        str(path),
        session_id=kw.get("session_id", "s"),
        tool=kw.get("tool", "Bash"),
        layer=kw.get("layer", "classifier"),
        decision=kw.get("decision", "allow"),
        reason=kw.get("reason", "r"),
        model=kw.get("model"),
        latency_ms=kw.get("latency_ms", 0),
        max_bytes=kw.get("max_bytes", diag.DEFAULT_MAX_BYTES),
    )


def test_no_rotation_below_threshold(tmp_log):
    for _ in range(5):
        _row(tmp_log)
    assert len(tmp_log.read_text().splitlines()) == 5
    assert not Path(str(tmp_log) + ".1").exists()


def test_rotates_when_over_max_bytes(tmp_log):
    for _ in range(20):
        _row(tmp_log)
    before = tmp_log.stat().st_size
    assert before > 0
    _row(tmp_log, max_bytes=1)  # next write sees a file past the threshold
    assert Path(str(tmp_log) + ".1").stat().st_size == before
    assert len(tmp_log.read_text().splitlines()) == 1


def test_rotation_keeps_only_one_generation(tmp_log):
    _row(tmp_log)
    _row(tmp_log, max_bytes=1, reason="second")
    _row(tmp_log, max_bytes=1, reason="third")
    assert not Path(str(tmp_log) + ".2").exists()
    # .1 holds the most recent rotation, not the oldest.
    assert "second" in Path(str(tmp_log) + ".1").read_text()


def test_max_bytes_zero_disables_rotation(tmp_log):
    for _ in range(5):
        _row(tmp_log, max_bytes=0)
    assert len(tmp_log.read_text().splitlines()) == 5
    assert not Path(str(tmp_log) + ".1").exists()


def test_new_log_is_created_private(tmp_log):
    """Rows quote pending command text and classifier reason strings, which
    can repeat secret-bearing fragments."""
    import stat
    _row(tmp_log)
    assert stat.S_IMODE(tmp_log.stat().st_mode) == 0o600


def test_rotation_leaves_no_lock_behind(tmp_log):
    _row(tmp_log)
    _row(tmp_log, max_bytes=1)
    assert not Path(str(tmp_log) + ".rotating").exists()


def test_a_held_lock_defers_rotation_instead_of_racing(tmp_log):
    """Two hooks that both see a full log must not both rotate: the second
    rename would replace the first's retained generation with a one-row file."""
    import os
    _row(tmp_log, reason="original")
    lock = Path(str(tmp_log) + ".rotating")
    fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        _row(tmp_log, max_bytes=1, reason="appended")
        assert not Path(str(tmp_log) + ".1").exists()
        assert "original" in tmp_log.read_text()
        assert "appended" in tmp_log.read_text()
    finally:
        os.close(fd)
        lock.unlink()


def test_stale_lock_does_not_block_rotation_forever(tmp_log):
    import os, time as _t
    _row(tmp_log)
    lock = Path(str(tmp_log) + ".rotating")
    lock.write_text("")
    old = _t.time() - 10 * diag._LOCK_STALE_S
    os.utime(lock, (old, old))
    _row(tmp_log, max_bytes=1)
    assert Path(str(tmp_log) + ".1").exists()


def test_non_integer_max_bytes_never_raises(tmp_log):
    """diag.emit runs before the verdict is surfaced; raising here turned a
    configured hard block into an ignored hook error."""
    for bad in ("x", None, True, 1.5):
        _row(tmp_log, max_bytes=bad)
    assert len(tmp_log.read_text().splitlines()) == 4
