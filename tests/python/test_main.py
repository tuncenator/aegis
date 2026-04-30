"""Tests for classifier.__main__ -- full chain orchestration via stdin/stdout.

AP1: exercises main() through monkeypatched sys.stdin, not internal helpers.
AP2: _call_provider is mocked at the Python function level, no real CLI.
AP3: autouse fixtures isolate state dir and diag emit.
"""
import io
import json

import pytest

from classifier import __main__ as main_mod


@pytest.fixture(autouse=True)
def isolate_state(tmp_path, monkeypatch):
    from classifier import state
    monkeypatch.setattr(state, "STATE_DIR", tmp_path)
    return tmp_path


@pytest.fixture(autouse=True)
def mock_diag(monkeypatch):
    from classifier import diag
    calls = []
    def fake_emit(path, **kw):
        calls.append(kw)
    monkeypatch.setattr(diag, "emit", fake_emit)
    return calls


@pytest.fixture
def fake_stdin(monkeypatch):
    def _set(payload: dict):
        monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))
    return _set


def test_main_first_provider_succeeds(monkeypatch, fake_stdin, capsys, tmp_path, mock_diag):
    monkeypatch.setattr(main_mod, "_call_provider",
                         lambda spec, sys_p, usr_p: '{"decision":"allow","reason":"ok"}'
                         if spec.provider == "gemini" else None)
    fake_stdin({"tool_name": "Bash", "tool_input": {"command": "ls"}, "session_id": "s1"})
    rc = main_mod.main()
    assert rc == 0
    out = json.loads(capsys.readouterr().out)
    assert out["hookSpecificOutput"]["permissionDecision"] == "allow"
    assert len(mock_diag) == 1
    assert mock_diag[0]["layer"] == "classifier"


def test_main_falls_to_second_provider(monkeypatch, fake_stdin, capsys, mock_diag):
    calls = []
    def stub(spec, sys_p, usr_p):
        calls.append(spec.provider)
        if len(calls) == 1:
            return None
        return '{"decision":"deny","reason":"r"}'
    monkeypatch.setattr(main_mod, "_call_provider", stub)
    fake_stdin({"tool_name": "Bash", "tool_input": {"command": "ls"}, "session_id": "s2"})
    rc = main_mod.main()
    assert rc == 0
    out = json.loads(capsys.readouterr().out)
    assert out["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert len(calls) == 2


def test_main_on_exhaustion_returns_ask(monkeypatch, fake_stdin, capsys):
    monkeypatch.setattr(main_mod, "_call_provider", lambda *a, **kw: None)
    fake_stdin({"tool_name": "Bash", "tool_input": {"command": "ls"}, "session_id": "s3"})
    rc = main_mod.main()
    assert rc == 0
    out = json.loads(capsys.readouterr().out)
    assert out["hookSpecificOutput"]["permissionDecision"] == "ask"


def test_main_disabled_session_falls_through(monkeypatch, fake_stdin, capsys, tmp_path, mock_diag):
    from classifier import state
    s = state.SessionState(session_id="paused", enabled=False, paused_reason="manual")
    state.save(s)
    fake_stdin({"tool_name": "Bash", "tool_input": {"command": "x"}, "session_id": "paused"})
    rc = main_mod.main()
    assert rc == 0
    assert capsys.readouterr().out.strip() == ""
    assert mock_diag == []  # silent fall-through emits NO diag row
