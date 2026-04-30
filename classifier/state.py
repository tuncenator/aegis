"""Per-session state: enabled flag, deny counters, pause reason.

State is persisted to ~/.cache/aegis/sessions/<session_id>.json so toggles
from CLI / slash commands and counter increments from the classifier loop
share one source of truth.
"""
from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path

STATE_DIR = Path.home() / ".cache" / "aegis" / "sessions"


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
