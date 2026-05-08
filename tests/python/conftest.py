"""Pytest config -- ensures classifier package is importable and isolates side-effecting paths."""
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT))


@pytest.fixture(autouse=True)
def _isolate_errors_log(tmp_path, monkeypatch):
    """Redirect provider error log to a per-test tmp file so tests don't
    write to the real ~/.cache/aegis/errors.jsonl."""
    from classifier.providers import base
    monkeypatch.setattr(base, "_ERRORS_PATH", tmp_path / "errors.jsonl")
