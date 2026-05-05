"""Claude CLI provider: subprocess call to `claude --model MODEL -p PROMPT`.

Sets CCSWAP_NORENAME=1 so a recursive Aegis evaluation of the embedded session
doesn't trigger ccswap's autorename worker.
"""
from __future__ import annotations

import os
import signal
import subprocess

from classifier.providers.base import run_with_retry
from classifier.rules import ProviderSpec


def _run_claude(args: list[str], input_text: str, timeout: int, env: dict) -> subprocess.CompletedProcess:
    """Run claude CLI in its own process group so we can kill it cleanly on timeout."""
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
    env = os.environ.copy()
    env["CCSWAP_NORENAME"] = "1"

    def invoke():
        return _run_claude(
            ["claude", "--model", spec.model, "-p", "-"],
            input_text=prompt,
            timeout=spec.timeout_s,
            env=env,
        )

    return run_with_retry(spec, invoke)
