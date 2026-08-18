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


def _coerce(default: SessionState, data: dict) -> SessionState:
    """Build a SessionState from untrusted JSON, field by field.

    A half-written or hand-edited file used to reach record_decision with the
    wrong types -- {"consecutive_denies": "3"} raised TypeError on the += and
    exited the hook 1, an ignored hook error. Every field is type-checked
    against the default rather than splatted in.
    """
    out = SessionState(session_id=default.session_id)
    if isinstance(data.get("enabled"), bool):
        out.enabled = data["enabled"]
    for field_name in ("consecutive_denies", "total_denies"):
        v = data.get(field_name)
        if isinstance(v, int) and not isinstance(v, bool) and v >= 0:
            setattr(out, field_name, v)
    for field_name in ("paused_reason", "last_decision_at"):
        v = data.get(field_name)
        if isinstance(v, str) or v is None:
            setattr(out, field_name, v)
    return out


def load(session_id: str) -> SessionState:
    """Never raises. Corrupt, unreadable or wrong-typed state loads as default.

    Regular files only: a FIFO here would block open(2) and wedge the hook
    until Claude Code's timeout, which is itself a fail-open.
    """
    default = SessionState(session_id=session_id)
    p = _path(session_id)
    try:
        if not p.is_file():
            return default
        with p.open("r", encoding="utf-8", errors="replace") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return default
        return _coerce(default, data)
    except Exception:
        return default


def save(s: SessionState) -> None:
    """Never raises. A read-only HOME or a full disk must not break a decision.

    The counters are an optimisation for the deny-storm auto-pause, not part
    of the verdict, so losing a write is survivable; exiting the hook non-zero
    from here would not be.
    """
    s.last_decision_at = datetime.now(timezone.utc).isoformat()
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = _path(s.session_id).with_suffix(".json.tmp")
        tmp.write_text(json.dumps(asdict(s), indent=2))
        os.replace(tmp, _path(s.session_id))
    except Exception:
        pass


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
    """Delete stale session state files. Returns the count removed.

    A DISABLED session is never pruned, however old its file is. Its state is
    a standing decision by the operator (`aegis off`) or by the deny-storm
    auto-pause, not a cache entry -- and because __main__ returns early for a
    disabled session without re-saving, its mtime stops advancing the moment
    it is disabled, so it looks stale almost immediately. Deleting it would
    silently resurrect the session as enabled, which is the wrong failure
    direction and the exact opposite of what the operator asked for.

    For an enabled session the worst case is harmless: an unknown id loads as
    a fresh SessionState, so its deny counters reset.
    """
    if not isinstance(ttl_days, int) or isinstance(ttl_days, bool) or ttl_days <= 0:
        return 0
    if not STATE_DIR.exists():
        return 0
    cutoff = time.time() - ttl_days * 86400
    removed = 0
    for p in STATE_DIR.glob("*.json"):
        try:
            if p.stat().st_mtime >= cutoff:
                continue
            if not load(p.stem).enabled:
                continue  # standing operator decision, not a cache entry
            # Re-check immediately before unlinking: a concurrent `aegis off`
            # may have replaced the file since the stat above.
            if p.stat().st_mtime >= cutoff:
                continue
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
