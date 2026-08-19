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


def _read_regular_text(p: Path) -> str | None:
    """Read a path only if it is a REGULAR file, tolerating any content.

    Two failure modes this closes, both reachable from a checked-in file in
    whatever repository the agent has open:

    - A FIFO (or a symlink to one) blocks open(2) forever. Git cannot store a
      FIFO but it can store a symlink to one, and a build step can create one.
      The hook then hangs until Claude Code's timeout, which is an ignored
      hook error, i.e. the gate disappears -- and an orphaned reader is left
      holding the pipe.
    - Bytes that are not valid UTF-8 raise UnicodeDecodeError, which is not an
      OSError. Anything escaping here exits the hook 1 with empty stdout,
      another ignored hook error. One 0xE7 byte was enough.

    errors="replace" rather than a bail-out: mojibake in a prompt is harmless,
    losing the gate is not.
    """
    try:
        if not p.is_file():          # False for FIFOs, directories, sockets
            return None
        with p.open("r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except Exception:
        return None


def _read_claude_md(cwd: str | None, include: bool) -> str | None:
    """Read <cwd>/CLAUDE.md, or None.

    `include` is checked HERE, not just downstream in prompt.build_user_prompt:
    the call site passes this result as an argument, so the file was being read
    even when the operator had set include_claude_md = false. That made a
    setting meant to keep repo-controlled prose out of the gate's own prompt
    fail to keep the repo's bytes out of the gate's process.
    """
    if not cwd or not include:
        return None
    return _read_regular_text(Path(cwd) / "CLAUDE.md")


def main() -> int:
    t0 = time.time()
    raw = sys.stdin.read()
    try:
        payload: dict[str, Any] = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        return 0

    session_id = payload.get("session_id", "unknown")
    cwd = payload.get("cwd")
    # Config loading runs before any verdict is surfaced, so an exception
    # here exits 1 with empty stdout -- which Claude Code reads as an ignored
    # hook error, silently turning a configured hard block into a pass. That
    # is reachable from the repo the agent has open, via <cwd>/.aegis: a
    # scalar where a table belongs, or a file of arbitrary bytes. rules.py
    # degrades every malformed layer to safe defaults on its own; this is the
    # backstop for the one thing it cannot catch, a bug in itself.
    try:
        cfg = rules.load_config(cwd)
    except Exception:
        cfg = rules.default_config()

    sess = state.load(session_id)
    if not sess.enabled:
        # Silent fall-through; let Claude Code prompt the user normally.
        # Do NOT emit diag -- silent fall-throughs are not logged.
        return 0

    snap = rules.load_snapshot()
    parsed = transcript.parse(payload.get("transcript_path", ""), cfg.last_user_messages)
    pending = {"tool_name": payload.get("tool_name"), "tool_input": payload.get("tool_input", {})}

    sys_p = prompt.build_system_prompt(snap, cfg)
    usr_p = prompt.build_user_prompt(
        parsed, pending, _read_claude_md(cwd, cfg.include_claude_md), cfg, cwd=cwd)

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
    # Housekeeping, at most once a day and never fatal: one state file is
    # written per session and nothing else removes them.
    try:
        state.prune_if_due(cfg.session_ttl_days)
    except Exception:
        pass

    # Diagnostics must never change a decision. This call runs BEFORE the
    # verdict is surfaced, so an exception here (a bad diag_path, a full
    # disk, a malformed max_bytes) would exit non-zero with empty stdout --
    # which Claude Code reads as an ignored hook error, turning a configured
    # hard block into a silent pass. Config values are type-checked in
    # rules.py; this is the backstop for everything else.
    try:
        diag.emit(
            cfg.diag_path,
            session_id=session_id,
            tool=payload.get("tool_name", "?"),
            layer="classifier",
            decision=d.decision,
            reason=d.reason,
            model=used_model,
            latency_ms=int((time.time() - t0) * 1000),
            max_bytes=cfg.diag_max_bytes,
        )
    except Exception:
        pass

    # In ask_mode="defer" an ASK surfaces as the empty string, so nothing
    # is written and Claude Code's own permission pipeline decides. A DENY
    # verdict is never deferred; with hard_deny_action="block" it comes
    # back as rc=2, Claude Code's hard block, with the reason on stderr
    # (stdout is ignored for rc=2).
    out, rc = decision.surface(d, cfg.ask_mode, cfg.hard_deny_action)
    if rc == 2:
        sys.stderr.write(f"aegis: blocked -- {d.reason}\n")
    else:
        sys.stdout.write(out)
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
