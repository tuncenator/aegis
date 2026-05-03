"""Parse classifier model output and format Claude Code hook responses."""
from __future__ import annotations

import json
import re
from dataclasses import dataclass

VALID = {"allow", "deny", "ask"}


class DecisionError(Exception):
    pass


@dataclass
class Decision:
    decision: str
    reason: str


_FENCE_RE = re.compile(r"```(?:json)?\s*(.*?)\s*```", re.DOTALL)


def parse_response(text: str) -> Decision:
    s = text.strip()
    if not s:
        raise DecisionError("empty response")
    # Strip code fence if present.
    m = _FENCE_RE.search(s)
    if m:
        s = m.group(1).strip()
    # Try to find a top-level JSON object if the model added prose.
    if not s.startswith("{"):
        brace = s.find("{")
        if brace >= 0:
            s = s[brace:]
    try:
        obj = json.loads(s)
    except json.JSONDecodeError as e:
        raise DecisionError(f"invalid JSON: {e}") from e
    d = obj.get("decision")
    if d not in VALID:
        raise DecisionError(f"invalid decision value: {d!r}")
    return Decision(decision=d, reason=str(obj.get("reason", "")))


def to_hook_output(d: Decision) -> str:
    """Convert a classifier Decision to a Claude Code hook payload.

    Classifier-emitted DENY is downgraded to ASK so the user always has
    an override path; the classifier's reason is surfaced as the ASK
    prompt text. The only hard-block channel is the deterministic
    bash-denylist layer, which exits the orchestrator with rc=2 before
    this function runs. State counters and the diagnostic log still see
    the classifier's original verdict, so deny-storms can still auto-
    pause the session even though each individual ASK is overridable.
    """
    surfaced = "ask" if d.decision == "deny" else d.decision
    payload = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": surfaced,
        }
    }
    if surfaced in ("ask", "deny") and d.reason:
        payload["hookSpecificOutput"]["permissionDecisionReason"] = d.reason
    return json.dumps(payload)
