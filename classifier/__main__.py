"""Aegis classifier entrypoint.

Reads PreToolUse JSON on stdin, writes Claude Code permission decision JSON on stdout.
This is a placeholder -- full implementation in Phase 7.
"""
import json
import sys


def main() -> int:
    sys.stdin.read()
    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "ask",
        }
    }
    json.dump(out, sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
