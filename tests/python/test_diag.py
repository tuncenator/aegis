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
