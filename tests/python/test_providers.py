import subprocess
from unittest.mock import MagicMock, patch

import pytest

from classifier.providers import base, gemini, claude
from classifier.rules import ProviderSpec


def _mock_popen(returncode=0, stdout="", stderr=""):
    proc = MagicMock()
    proc.communicate.return_value = (stdout, stderr)
    proc.returncode = returncode
    proc.pid = 12345
    proc.wait.return_value = returncode
    return proc


def test_base_invokes_subprocess(monkeypatch):
    proc = _mock_popen(returncode=0, stdout='{"decision": "allow", "reason": "x"}')
    monkeypatch.setattr(subprocess, "Popen", MagicMock(return_value=proc))
    spec = ProviderSpec("gemini", "model-x", retries=1, timeout_s=5)
    out = gemini.call(spec, system="sys", user="usr")
    assert "allow" in out


def test_base_retries_on_nonzero_exit(monkeypatch):
    calls = []

    def fake_popen(*a, **kw):
        calls.append(1)
        if len(calls) >= 3:
            return _mock_popen(returncode=0, stdout='{"decision": "allow", "reason": "ok"}')
        return _mock_popen(returncode=1, stdout="", stderr="transient")

    monkeypatch.setattr(subprocess, "Popen", fake_popen)
    spec = ProviderSpec("gemini", "m", retries=3, timeout_s=5)
    out = gemini.call(spec, system="s", user="u")
    assert "allow" in out
    assert len(calls) == 3


def test_base_returns_none_on_exhausted(monkeypatch):
    proc = _mock_popen(returncode=1, stdout="", stderr="err")
    monkeypatch.setattr(subprocess, "Popen", MagicMock(return_value=proc))
    spec = ProviderSpec("gemini", "m", retries=2, timeout_s=5)
    out = gemini.call(spec, system="s", user="u")
    assert out is None


def test_base_handles_timeout(monkeypatch):
    proc = MagicMock()
    proc.communicate.side_effect = subprocess.TimeoutExpired("cmd", 1)
    proc.pid = 12345
    proc.wait.return_value = -9
    monkeypatch.setattr(subprocess, "Popen", MagicMock(return_value=proc))
    monkeypatch.setattr("os.killpg", MagicMock())
    spec = ProviderSpec("gemini", "m", retries=1, timeout_s=1)
    out = gemini.call(spec, system="s", user="u")
    assert out is None


def test_claude_provider_sets_norename_env(monkeypatch):
    captured = {}

    def fake_popen(cmd, **kw):
        captured["env"] = kw.get("env", {})
        return _mock_popen(returncode=0, stdout='{"decision":"allow","reason":"x"}')

    monkeypatch.setattr(subprocess, "Popen", fake_popen)
    spec = ProviderSpec("claude", "claude-haiku-4-5", retries=1, timeout_s=5)
    out = claude.call(spec, system="s", user="u")
    assert out is not None
    assert captured["env"].get("CCSWAP_NORENAME") == "1"
