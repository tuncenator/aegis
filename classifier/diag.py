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
from datetime import datetime, timezone
from pathlib import Path

# 32 MiB. At the ~292 bytes/row this schema averages, that is roughly
# 115k decisions per generation.
DEFAULT_MAX_BYTES = 32 * 1024 * 1024


def _rotate_if_needed(target: Path, max_bytes: int) -> None:
    if max_bytes <= 0:
        return
    try:
        if target.stat().st_size < max_bytes:
            return
    except OSError:
        return
    try:
        os.replace(target, target.parent / (target.name + ".1"))
    except OSError:
        # A concurrent hook already rotated it, or the directory is not
        # writable. Either way, logging must never break a tool call.
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
    with target.open("a") as f:
        f.write(json.dumps(row) + "\n")
