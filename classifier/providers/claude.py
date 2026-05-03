"""Claude CLI provider: subprocess call to `claude --model MODEL -p PROMPT`.

Sets CCSWAP_NORENAME=1 so a recursive Aegis evaluation of the embedded session
doesn't trigger ccswap's autorename worker. Modeled after ccswap's own _call_claude.
"""
from __future__ import annotations

import os
import subprocess

from classifier.providers.base import run_with_retry
from classifier.rules import ProviderSpec


def call(spec: ProviderSpec, system: str, user: str) -> str | None:
    prompt = f"{system}\n\n---\n\n{user}"
    env = os.environ.copy()
    env["CCSWAP_NORENAME"] = "1"

    def invoke():
        return subprocess.run(
            ["claude", "--model", spec.model, "-p", prompt],
            capture_output=True, text=True, timeout=spec.timeout_s, env=env,
        )

    return run_with_retry(spec, invoke)
