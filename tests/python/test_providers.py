import subprocess
from unittest.mock import MagicMock, patch

import pytest

from classifier.providers import claude, gemini
from classifier.rules import ProviderSpec


def _mock_popen(returncode=0, stdout="", stderr=""):
    proc = MagicMock()
    proc.communicate.return_value = (stdout, stderr)
    proc.returncode = returncode
    proc.pid = 12345
    proc.wait.return_value = returncode
    return proc


# ---------- gemini SDK provider ----------

def _patch_gemini_client(monkeypatch, response_text=None, raise_exc=None):
    """Patch genai.Client so generate_content returns or raises as configured."""
    monkeypatch.setattr(gemini, "_resolve_api_key", lambda: "fake-key")

    fake_resp = MagicMock()
    fake_resp.text = response_text

    fake_models = MagicMock()
    if raise_exc is not None:
        fake_models.generate_content = MagicMock(side_effect=raise_exc)
    else:
        fake_models.generate_content = MagicMock(return_value=fake_resp)

    fake_client = MagicMock()
    fake_client.models = fake_models

    fake_client_ctor = MagicMock(return_value=fake_client)
    monkeypatch.setattr(gemini.genai, "Client", fake_client_ctor)
    return fake_client_ctor, fake_models


def test_gemini_returns_response_text(monkeypatch):
    _patch_gemini_client(monkeypatch, response_text='{"decision": "allow", "reason": "x"}')
    spec = ProviderSpec("gemini", "model-x", retries=1, timeout_s=5)
    out = gemini.call(spec, system="sys", user="usr")
    assert "allow" in out


def test_gemini_returns_none_without_api_key(monkeypatch):
    monkeypatch.setattr(gemini, "_resolve_api_key", lambda: None)
    spec = ProviderSpec("gemini", "m", retries=1, timeout_s=5)
    assert gemini.call(spec, system="s", user="u") is None


def test_gemini_retries_on_empty_response(monkeypatch):
    monkeypatch.setattr(gemini, "_resolve_api_key", lambda: "fake-key")
    responses = [MagicMock(text=""), MagicMock(text=""), MagicMock(text='{"decision":"allow","reason":"x"}')]
    fake_models = MagicMock()
    fake_models.generate_content = MagicMock(side_effect=responses)
    fake_client = MagicMock()
    fake_client.models = fake_models
    monkeypatch.setattr(gemini.genai, "Client", MagicMock(return_value=fake_client))

    spec = ProviderSpec("gemini", "m", retries=3, timeout_s=5)
    out = gemini.call(spec, system="s", user="u")
    assert "allow" in out
    assert fake_models.generate_content.call_count == 3


def test_gemini_retries_on_api_error(monkeypatch):
    from google.genai import errors as genai_errors

    monkeypatch.setattr(gemini, "_resolve_api_key", lambda: "fake-key")

    err = genai_errors.APIError(500, {"error": {"message": "boom"}}, None)
    final = MagicMock(text='{"decision":"allow","reason":"ok"}')
    fake_models = MagicMock()
    fake_models.generate_content = MagicMock(side_effect=[err, err, final])
    fake_client = MagicMock()
    fake_client.models = fake_models
    monkeypatch.setattr(gemini.genai, "Client", MagicMock(return_value=fake_client))

    spec = ProviderSpec("gemini", "m", retries=3, timeout_s=5)
    out = gemini.call(spec, system="s", user="u")
    assert "allow" in out


def test_gemini_returns_none_when_exhausted(monkeypatch):
    _patch_gemini_client(monkeypatch, response_text="")
    spec = ProviderSpec("gemini", "m", retries=2, timeout_s=5)
    assert gemini.call(spec, system="s", user="u") is None


def test_gemini_handles_timeout(monkeypatch):
    _patch_gemini_client(monkeypatch, raise_exc=TimeoutError("deadline"))
    spec = ProviderSpec("gemini", "m", retries=1, timeout_s=1)
    assert gemini.call(spec, system="s", user="u") is None


def test_gemini_resolves_key_from_dotenv(monkeypatch, tmp_path):
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    monkeypatch.delenv("GOOGLE_API_KEY", raising=False)
    fake_dotenv = tmp_path / ".env"
    fake_dotenv.write_text(f'{"GEMINI_API_KEY"}={"from-file"!r}\n')
    monkeypatch.setattr(gemini, "_DOTENV", fake_dotenv)
    assert gemini._resolve_api_key() == "from-file"


def test_gemini_resolves_key_from_env_first(monkeypatch, tmp_path):
    monkeypatch.setenv("GEMINI_API_KEY", "from-env")
    fake_dotenv = tmp_path / ".env"
    fake_dotenv.write_text('GEMINI_API_KEY=from-file\n')
    monkeypatch.setattr(gemini, "_DOTENV", fake_dotenv)
    assert gemini._resolve_api_key() == "from-env"


# ---------- claude CLI provider (unchanged) ----------

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
