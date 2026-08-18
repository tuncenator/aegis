"""Decision log writer (JSONL append) with size-based rotation.

Schema for each row:
    {ts, session_id, tool, layer, decision, reason, model, latency_ms, tokens}

This schema MUST match what classifier/diagcli.py writes for the
deterministic bash layers, so postmortem tooling sees a uniform stream
regardless of which layer wrote the row.

Rotation: the log is appended to on every non-fall-through decision, which
in real use means hundreds of thousands of rows. When it reaches
max_bytes the file is renamed to <path>.1 (replacing any previous .1) and
a fresh file starts. One generation of history is kept on purpose: the log
is a debugging aid, not an audit trail, and an unbounded file in ~/.cache
is a liability nobody notices until it is hundreds of megabytes.
"""
from __future__ import annotations

import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path

# 32 MiB. At the ~292 bytes/row this schema averages, that is roughly
# 115k decisions per generation.
DEFAULT_MAX_BYTES = 32 * 1024 * 1024

# A rotation lock older than this was orphaned by a killed process.
_LOCK_STALE_S = 30


def _rotate_if_needed(target: Path, max_bytes: int) -> None:
    """Rename target to <name>.1 once it crosses max_bytes.

    Guarded by an O_EXCL lock file so two hooks that both observe a full log
    cannot both rotate: without it, the second rename replaces the first's
    freshly-retained generation with a one-row file, destroying the history
    the rotation existed to keep. Losing the lock race simply means skipping
    rotation this once; the next call rotates.
    """
    if not isinstance(max_bytes, int) or isinstance(max_bytes, bool) or max_bytes <= 0:
        return
    try:
        if target.stat().st_size < max_bytes:
            return
    except OSError:
        return

    lock = target.parent / (target.name + ".rotating")
    try:
        fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        # Another process is rotating, unless its lock was orphaned by a kill.
        try:
            if time.time() - lock.stat().st_mtime < _LOCK_STALE_S:
                return
            os.unlink(lock)
            fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except OSError:
            return
    except OSError:
        return

    try:
        # Re-check under the lock: the winner may already have rotated.
        if target.stat().st_size >= max_bytes:
            os.replace(target, target.parent / (target.name + ".1"))
    except OSError:
        # Logging must never break a tool call.
        pass
    finally:
        os.close(fd)
        try:
            os.unlink(lock)
        except OSError:
            pass


def emit(
    path: str,
    *,
    session_id: str,
    tool: str,
    layer: str,
    decision: str,
    reason: str,
    model: str | None,
    latency_ms: int,
    tokens: dict | None = None,
    max_bytes: int = DEFAULT_MAX_BYTES,
) -> None:
    target = Path(os.path.expanduser(path))
    target.parent.mkdir(parents=True, exist_ok=True)
    _rotate_if_needed(target, max_bytes)
    row = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "session_id": session_id,
        "tool": tool,
        "layer": layer,
        "decision": decision,
        "reason": reason,
        "model": model,
        "latency_ms": latency_ms,
        "tokens": tokens,
    }
    # 0600 on creation: rows quote pending command text and classifier reason
    # strings, which can repeat secret-bearing fragments. An existing file
    # keeps whatever mode the operator gave it -- os.open does not chmod.
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a") as f:
        f.write(json.dumps(row) + "\n")
