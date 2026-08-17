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


def to_hook_output(d: Decision, ask_mode: str = "prompt") -> str:
    """Convert a classifier Decision to a Claude Code hook payload.

    Classifier-emitted DENY is downgraded to ASK so the user always has
    an override path; the classifier's reason is surfaced as the ASK
    prompt text. The only hard-block channel is the deterministic
    bash-denylist layer, which exits the orchestrator with rc=2 before
    this function runs. State counters and the diagnostic log still see
    the classifier's original verdict, so deny-storms can still auto-
    pause the session even though each individual ASK is overridable.

    With ask_mode="defer" an ASK surfaces as the empty string instead:
    the caller writes nothing and exits 0, which is the only hook result
    that falls through to Claude Code's own permission pipeline, letting
    its native auto-mode classifier take the ambiguous middle rather than
    interrupting the user. Allows are unaffected.

    A DENY verdict is NEVER deferred, in either mode. The snapshot's
    hard_deny section (Data Exfiltration) reaches this function as a deny,
    and deferring it would hand an exfiltration call to the native
    classifier instead of to the operator. ask_mode exists to let the
    native classifier absorb genuine ambiguity; a deny is not ambiguity.
    Whether the deny prompts or hard-blocks is cfg.hard_deny_action,
    applied by surface() below.
    """
    surfaced = "ask" if d.decision == "deny" else d.decision
    if surfaced == "ask" and ask_mode == "defer" and d.decision != "deny":
        return ""
    payload = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": surfaced,
        }
    }
    if surfaced in ("ask", "deny") and d.reason:
        payload["hookSpecificOutput"]["permissionDecisionReason"] = d.reason
    return json.dumps(payload)


def surface(
    d: Decision,
    ask_mode: str = "prompt",
    hard_deny_action: str = "prompt",
) -> tuple[str, int]:
    """Return (stdout, exit_code) for a Decision.

    Exit code 2 is Claude Code's hard block: stdout is ignored and stderr
    goes back to the model. It is only ever produced here when the
    operator opted in with hard_deny_action="block"; the default
    ("prompt") keeps the README's philosophy that the classifier never
    hard-blocks and the operator is the final authority.
    """
    if d.decision == "deny" and hard_deny_action == "block":
        return "", 2
    return to_hook_output(d, ask_mode), 0
