"""Per-session state: enabled flag, deny counters, pause reason.

State is persisted to ~/.cache/aegis/sessions/<session_id>.json so toggles
from CLI / slash commands and counter increments from the classifier loop
share one source of truth.
"""
from __future__ import annotations

import json
import os
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path

STATE_DIR = Path.home() / ".cache" / "aegis" / "sessions"

# One state file is written per Claude Code session and nothing ever removed
# them, so the directory grew to ~1k files. Pruning runs at most once a day
# (guarded by the mtime of this stamp) because the alternative -- scanning
# the directory on every hook call -- is a directory walk in the latency
# path of every tool call.
PRUNE_STAMP_NAME = ".prune-stamp"
PRUNE_INTERVAL_S = 24 * 3600


@dataclass
class SessionState:
    session_id: str
    enabled: bool = True
    consecutive_denies: int = 0
    total_denies: int = 0
    paused_reason: str | None = None
    last_decision_at: str | None = None


def _path(session_id: str) -> Path:
    return STATE_DIR / f"{session_id}.json"


def load(session_id: str) -> SessionState:
    p = _path(session_id)
    if not p.exists():
        return SessionState(session_id=session_id)
    try:
        data = json.loads(p.read_text())
        return SessionState(**{**asdict(SessionState(session_id=session_id)), **data})
    except (json.JSONDecodeError, OSError, TypeError):
        # Corrupt or unreadable: fall back to defaults and rewrite on next save.
        return SessionState(session_id=session_id)


def save(s: SessionState) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    s.last_decision_at = datetime.now(timezone.utc).isoformat()
    tmp = _path(s.session_id).with_suffix(".json.tmp")
    tmp.write_text(json.dumps(asdict(s), indent=2))
    os.replace(tmp, _path(s.session_id))


def record_decision(
    s: SessionState,
    decision: str,
    consecutive_limit: int = 3,
    total_limit: int = 20,
) -> None:
    """Update counters and optionally trip auto-pause. Caller must save() after."""
    if decision == "deny":
        s.consecutive_denies += 1
        s.total_denies += 1
        if s.consecutive_denies >= consecutive_limit:
            s.enabled = False
            s.paused_reason = "consecutive_deny_limit"
        elif s.total_denies >= total_limit:
            s.enabled = False
            s.paused_reason = "total_deny_limit"
    elif decision == "allow":
        s.consecutive_denies = 0


def prune(ttl_days: int = 14) -> int:
    """Delete session state files not touched in ttl_days. Returns the count.

    Deleting a session's file is harmless: state.load() rebuilds a default
    SessionState for an unknown id, so the worst case for a session that is
    somehow still live after the TTL is that its deny counters reset.
    """
    if ttl_days <= 0 or not STATE_DIR.exists():
        return 0
    cutoff = time.time() - ttl_days * 86400
    removed = 0
    for p in STATE_DIR.glob("*.json"):
        try:
            if p.stat().st_mtime < cutoff:
                p.unlink()
                removed += 1
        except OSError:
            continue
    return removed


def prune_if_due(ttl_days: int = 14, interval_s: int = PRUNE_INTERVAL_S) -> int:
    """Run prune() at most once per interval. Never raises."""
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        stamp = STATE_DIR / PRUNE_STAMP_NAME
        now = time.time()
        if stamp.exists() and now - stamp.stat().st_mtime < interval_s:
            return 0
        stamp.touch()
        return prune(ttl_days)
    except OSError:
        return 0
