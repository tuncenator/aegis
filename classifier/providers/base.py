"""Shared subprocess invocation with retry and timeout."""
from __future__ import annotations

import json
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

from classifier.rules import ProviderSpec

_ERRORS_PATH = Path(os.path.expanduser("~/.cache/aegis/errors.jsonl"))


def _log_error(provider: str, model: str, attempt: int, reason: str) -> None:
    _ERRORS_PATH.parent.mkdir(parents=True, exist_ok=True)
    row = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "provider": provider,
        "model": model,
        "attempt": attempt,
        "reason": reason,
    }
    with _ERRORS_PATH.open("a") as f:
        f.write(json.dumps(row) + "\n")


def run_with_retry(
    spec: ProviderSpec,
    invoke: Callable[[], subprocess.CompletedProcess],
) -> str | None:
    """Call invoke() up to spec.retries times. Return stdout on success, None on exhaustion."""
    for attempt in range(max(1, spec.retries)):
        try:
            r = invoke()
        except subprocess.TimeoutExpired:
            _log_error(spec.provider, spec.model, attempt + 1, f"timeout ({spec.timeout_s}s)")
            continue
        except OSError as e:
            _log_error(spec.provider, spec.model, attempt + 1, f"OSError: {e}")
            return None
        if r.returncode != 0:
            _log_error(spec.provider, spec.model, attempt + 1, f"rc={r.returncode} stderr={r.stderr[:200]}")
            continue
        if not r.stdout.strip():
            _log_error(spec.provider, spec.model, attempt + 1, "empty stdout")
            continue
        return r.stdout
    return None
