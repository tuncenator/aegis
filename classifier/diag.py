"""Decision log writer (JSONL append).

Schema for each row:
    {ts, session_id, tool, layer, decision, reason, model, latency_ms, tokens}

This schema MUST match the bash diag_emit helper in orchestrator.sh so
postmortem tooling sees a uniform stream regardless of which layer wrote
the row.
"""
from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path


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
) -> None:
    target = Path(os.path.expanduser(path))
    target.parent.mkdir(parents=True, exist_ok=True)
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
