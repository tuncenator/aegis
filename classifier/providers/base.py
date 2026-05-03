"""Shared subprocess invocation with retry and timeout."""
from __future__ import annotations

import subprocess
from typing import Callable

from classifier.rules import ProviderSpec


def run_with_retry(
    spec: ProviderSpec,
    invoke: Callable[[], subprocess.CompletedProcess],
) -> str | None:
    """Call invoke() up to spec.retries times. Return stdout on success, None on exhaustion."""
    for _ in range(max(1, spec.retries)):
        try:
            r = invoke()
        except subprocess.TimeoutExpired:
            continue
        except OSError:
            return None
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout
    return None
