"""Diag emitter for the deterministic bash layers of orchestrator.sh.

orchestrator.sh used to inline a python heredoc that hardcoded
~/.cache/aegis/decisions.jsonl, so the [logging] diag_path setting only
governed the Python classifier's rows and the bash layers wrote somewhere
else. Routing both through this module keeps one destination, one schema,
and one rotation policy.

Usage:  python3 -m classifier.diagcli SESSION TOOL LAYER DECISION REASON [CWD]
"""
from __future__ import annotations

import sys

from classifier import diag, rules


def main(argv: list[str]) -> int:
    if len(argv) < 5:
        return 0
    session_id, tool, layer, decision, reason = argv[:5]
    cwd = argv[5] if len(argv) > 5 else None
    try:
        cfg = rules.load_config(cwd)
        diag.emit(
            cfg.diag_path,
            session_id=session_id,
            tool=tool,
            layer=layer,
            decision=decision,
            reason=reason,
            model=None,
            latency_ms=0,
            max_bytes=cfg.diag_max_bytes,
        )
    except Exception:
        # Diagnostics must never break a tool call.
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
