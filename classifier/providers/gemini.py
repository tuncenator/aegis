"""Gemini CLI provider: subprocess call to `gemini -m MODEL -p PROMPT`."""
from __future__ import annotations

import os
import signal
import subprocess

from classifier.providers.base import run_with_retry
from classifier.rules import ProviderSpec


def _run_gemini(args: list[str], input_text: str, timeout: int, env: dict) -> subprocess.CompletedProcess:
    """Run gemini CLI in its own process group so we can kill it cleanly on timeout."""
    proc = subprocess.Popen(
        args,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
        start_new_session=True,
    )
    try:
        stdout, stderr = proc.communicate(input=input_text, timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait(timeout=5)
        raise
    return subprocess.CompletedProcess(args, proc.returncode, stdout, stderr)


def call(spec: ProviderSpec, system: str, user: str) -> str | None:
    prompt = f"{system}\n\n---\n\n{user}"

    def invoke():
        return _run_gemini(
            ["gemini", "-m", spec.model],
            input_text=prompt,
            timeout=spec.timeout_s,
            env=os.environ.copy(),
        )

    return run_with_retry(spec, invoke)
