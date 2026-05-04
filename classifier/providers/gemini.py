"""Gemini CLI provider: subprocess call to `gemini -m MODEL -p PROMPT`."""
from __future__ import annotations

import os
import subprocess

from classifier.providers.base import run_with_retry
from classifier.rules import ProviderSpec


def call(spec: ProviderSpec, system: str, user: str) -> str | None:
    prompt = f"{system}\n\n---\n\n{user}"

    def invoke():
        return subprocess.run(
            ["gemini", "-m", spec.model],
            input=prompt,
            capture_output=True, text=True, timeout=spec.timeout_s,
            env=os.environ.copy(),
        )

    return run_with_retry(spec, invoke)
