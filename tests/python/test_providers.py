import subprocess
from unittest.mock import patch, MagicMock

import pytest

from classifier.providers import base, gemini, claude
from classifier.rules import ProviderSpec


def test_base_invokes_subprocess(monkeypatch):
    fake = MagicMock()
    fake.returncode = 0
    fake.stdout = '{"decision": "allow", "reason": "x"}'
    monkeypatch.setattr(subprocess, "run", MagicMock(return_value=fake))
    spec = ProviderSpec("gemini", "model-x", retries=1, timeout_s=5)
    out = gemini.call(spec, system="sys", user="usr")
    assert "allow" in out


def test_base_retries_on_nonzero_exit(monkeypatch):
    calls = []

    def fake_run(*a, **kw):
        calls.append(1)
        m = MagicMock()
        m.returncode = 0 if len(calls) >= 3 else 1
        m.stdout = '{"decision": "allow", "reason": "ok"}' if m.returncode == 0 else ""
        m.stderr = "transient"
        return m

    monkeypatch.setattr(subprocess, "run", fake_run)
    spec = ProviderSpec("gemini", "m", retries=3, timeout_s=5)
    out = gemini.call(spec, system="s", user="u")
    assert "allow" in out
    assert len(calls) == 3


def test_base_returns_none_on_exhausted(monkeypatch):
    monkeypatch.setattr(subprocess, "run",
                         MagicMock(return_value=MagicMock(returncode=1, stdout="", stderr="err")))
    spec = ProviderSpec("gemini", "m", retries=2, timeout_s=5)
    out = gemini.call(spec, system="s", user="u")
    assert out is None


def test_base_handles_timeout(monkeypatch):
    def boom(*a, **kw):
        raise subprocess.TimeoutExpired("cmd", 1)
    monkeypatch.setattr(subprocess, "run", boom)
    spec = ProviderSpec("gemini", "m", retries=1, timeout_s=1)
    out = gemini.call(spec, system="s", user="u")
    assert out is None


def test_claude_provider_sets_norename_env(monkeypatch):
    captured = {}

    def fake_run(cmd, **kw):
        captured["env"] = kw.get("env", {})
        m = MagicMock()
        m.returncode = 0
        m.stdout = '{"decision":"allow","reason":"x"}'
        return m

    monkeypatch.setattr(subprocess, "run", fake_run)
    spec = ProviderSpec("claude", "claude-haiku-4-5", retries=1, timeout_s=5)
    out = claude.call(spec, system="s", user="u")
    assert out is not None
    assert captured["env"].get("CCSWAP_NORENAME") == "1"
