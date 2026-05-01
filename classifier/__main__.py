"""Aegis classifier entrypoint.

Reads PreToolUse JSON on stdin, walks the configured provider chain,
applies state-aware deny counters, writes a Claude Code permission
decision JSON on stdout (or empty for silent fall-through when disabled).

Note: when the chain exhausts and `cfg.on_exhaustion` is "deny", the
synthetic exhaustion decision still flows through state.record_decision,
so it counts toward consecutive/total deny limits and can auto-pause the
session. This is intentional: a runaway chain that always exhausts to
deny should look like a deny-storm to the counters.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path
from typing import Any

from classifier import decision, diag, prompt, rules, state, transcript
from classifier.providers import claude as claude_provider
from classifier.providers import gemini as gemini_provider


def _call_provider(spec: rules.ProviderSpec, system: str, user: str) -> str | None:
    if spec.provider == "gemini":
        return gemini_provider.call(spec, system, user)
    if spec.provider == "claude":
        return claude_provider.call(spec, system, user)
    return None


def _read_claude_md(cwd: str | None) -> str | None:
    if not cwd:
        return None
    p = Path(cwd) / "CLAUDE.md"
    if not p.exists():
        return None
    try:
        return p.read_text()
    except OSError:
        return None


def main() -> int:
    t0 = time.time()
    raw = sys.stdin.read()
    try:
        payload: dict[str, Any] = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        return 0

    session_id = payload.get("session_id", "unknown")
    cwd = payload.get("cwd")
    cfg = rules.load_config(cwd)

    sess = state.load(session_id)
    if not sess.enabled:
        # Silent fall-through; let Claude Code prompt the user normally.
        # Do NOT emit diag -- silent fall-throughs are not logged.
        return 0

    snap = rules.load_snapshot()
    parsed = transcript.parse(payload.get("transcript_path", ""), cfg.last_user_messages)
    pending = {"tool_name": payload.get("tool_name"), "tool_input": payload.get("tool_input", {})}

    sys_p = prompt.build_system_prompt(snap, cfg)
    usr_p = prompt.build_user_prompt(parsed, pending, _read_claude_md(cwd), cfg, cwd=cwd)

    raw_response: str | None = None
    used_model: str | None = None
    d: decision.Decision | None = None
    for spec in cfg.classifier_chain:
        out = _call_provider(spec, sys_p, usr_p)
        if out is None:
            continue
        # Try parse; if malformed, attempt one repair on this provider.
        try:
            d = decision.parse_response(out)
        except decision.DecisionError:
            repair_user = usr_p + "\n\nYour previous reply was not valid. Reply ONLY with the JSON object."
            out = _call_provider(spec, sys_p, repair_user)
            if out is None:
                continue
            try:
                d = decision.parse_response(out)
            except decision.DecisionError:
                continue
        raw_response = out
        used_model = spec.model
        break

    if raw_response is None or d is None:
        # Chain exhausted: apply on_exhaustion behavior.
        d = decision.Decision(decision=cfg.on_exhaustion, reason="classifier chain exhausted")

    # Update counters and persist state.
    state.record_decision(
        sess,
        d.decision,
        consecutive_limit=cfg.consecutive_deny_limit,
        total_limit=cfg.total_deny_limit,
    )
    state.save(sess)

    diag.emit(
        cfg.diag_path,
        session_id=session_id,
        tool=payload.get("tool_name", "?"),
        layer="classifier",
        decision=d.decision,
        reason=d.reason,
        model=used_model,
        latency_ms=int((time.time() - t0) * 1000),
    )

    sys.stdout.write(decision.to_hook_output(d))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
