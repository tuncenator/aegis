"""Gemini provider via google-genai SDK.

Direct API call (no CLI subprocess), so we avoid the gemini CLI's agentic
loop, tool detection, and Node startup overhead. Empirical p99 with 17k
prompts: ~0.9s vs CLI's 15-17s.

Auth: GEMINI_API_KEY (or GOOGLE_API_KEY) from env, with fallback to
~/.gemini/.env where the gemini CLI stores its key.
"""
from __future__ import annotations

import os
from pathlib import Path

from google import genai
from google.genai import errors as genai_errors
from google.genai import types

from classifier.providers.base import _log_error
from classifier.rules import ProviderSpec

_DOTENV = Path.home() / ".gemini" / ".env"


def _resolve_api_key() -> str | None:
    key = os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")
    if key:
        return key
    if _DOTENV.exists():
        try:
            for line in _DOTENV.read_text().splitlines():
                line = line.strip()
                if line.startswith("GEMINI_API_KEY="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
        except OSError:
            return None
    return None


def call(spec: ProviderSpec, system: str, user: str) -> str | None:
    key = _resolve_api_key()
    if not key:
        _log_error(spec.provider, spec.model, 1, "no GEMINI_API_KEY available")
        return None

    client = genai.Client(
        api_key=key,
        http_options=types.HttpOptions(timeout=spec.timeout_s * 1000),
    )
    cfg = types.GenerateContentConfig(
        system_instruction=system,
        thinking_config=types.ThinkingConfig(thinking_level=types.ThinkingLevel.MINIMAL),
        temperature=0.0,
    )

    for attempt in range(max(1, spec.retries)):
        try:
            resp = client.models.generate_content(
                model=spec.model,
                contents=user,
                config=cfg,
            )
        except genai_errors.APIError as e:
            _log_error(spec.provider, spec.model, attempt + 1, f"api_error: {e}")
            continue
        except (TimeoutError, ConnectionError) as e:
            _log_error(spec.provider, spec.model, attempt + 1, f"{type(e).__name__}: {e}")
            continue

        text = (resp.text or "").strip()
        if not text:
            _log_error(spec.provider, spec.model, attempt + 1, "empty response")
            continue
        return text
    return None
