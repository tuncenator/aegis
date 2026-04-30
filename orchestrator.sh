#!/usr/bin/env bash
# Aegis PreToolUse hook orchestrator.
# Dispatches by tool_name through layered decision pipelines.
#
# Pipeline (Bash):
#   1. lib/bash-denylist.sh      (exit 2 = hard block)
#   2. lib/bash-hard-ask.sh      (ASK if matched, else silent fall-through)
#   3. lib/bash-gatekeeper.sh    (ALLOW if matched, else silent fall-through)
#   4. classifier (Python)       (ALLOW | DENY | ASK)
#
# Pipeline (Edit/Write/NotebookEdit):
#   1. lib/protected-paths.sh    (ASK if matched, else silent fall-through)
#   2. classifier (Python)
#
# Pipeline (Read-only tools: Read/Glob/Grep/TodoWrite/TaskCreate/etc.):
#   ALLOW immediately, no classifier.

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib"

# Test-mode shortcut: when AEGIS_TEST_MOCK_DECISION is set, return that decision.
mock_classifier() {
  case "${AEGIS_TEST_MOCK_DECISION:-}" in
    allow) echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'; exit 0 ;;
    deny)  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"mock"}}'; exit 0 ;;
    ask)   echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask"}}'; exit 0 ;;
    *) return 1 ;;
  esac
}

emit_allow() {
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
  exit 0
}

# Read whole stdin; we'll re-feed it to layer scripts.
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
SESS=$(echo "$INPUT" | jq -r '.session_id // "unknown"')

# Diag emitter for deterministic layers. Calls a python one-liner.
diag_emit() {
  local layer="$1" decision="$2" reason="$3" sess="$4" tool="$5"
  python3 - "$sess" "$tool" "$layer" "$decision" "$reason" <<'PY'
import sys, json, os, datetime, pathlib
sess, tool, layer, decision, reason = sys.argv[1:]
target = pathlib.Path(os.path.expanduser("~/.cache/aegis/decisions.jsonl"))
target.parent.mkdir(parents=True, exist_ok=True)
row = {
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "session_id": sess, "tool": tool, "layer": layer,
    "decision": decision, "reason": reason, "model": None,
    "latency_ms": 0, "tokens": None,
}
with target.open("a") as f:
    f.write(json.dumps(row) + "\n")
PY
}

# Read-only / harmless tools: allow without any classifier.
case "$TOOL" in
  Read|Glob|Grep|TodoWrite|TaskCreate|TaskUpdate|TaskList|TaskGet|TaskOutput|TaskStop)
    diag_emit "read-only" "allow" "harmless tool" "$SESS" "$TOOL"
    emit_allow
    ;;
esac

# Layer dispatch by tool family.
if [ "$TOOL" = "Bash" ]; then
  # Layer 1: hard-deny (exits 2 if matched; we propagate).
  echo "$INPUT" | "$LIB/bash-denylist.sh"
  rc=$?
  if [ "$rc" = 2 ]; then
    diag_emit "hard-deny" "deny" "bash-denylist matched" "$SESS" "$TOOL"
    exit 2
  fi

  # Layer 2: hard-ask.
  out=$(echo "$INPUT" | "$LIB/bash-hard-ask.sh")
  if [ -n "$out" ]; then
    diag_emit "hard-ask" "ask" "$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // "hard-ask matched"')" "$SESS" "$TOOL"
    echo "$out"; exit 0
  fi

  # Layer 3: hard-allow (gatekeeper).
  out=$(echo "$INPUT" | "$LIB/bash-gatekeeper.sh")
  if [ -n "$out" ]; then
    diag_emit "hard-allow" "allow" "bash-gatekeeper matched" "$SESS" "$TOOL"
    echo "$out"; exit 0
  fi

  # Layer 4: classifier.
  mock_classifier && exit 0
  echo "$INPUT" | env PYTHONPATH="$DIR" python3 -m classifier
  exit 0
fi

# Edit / Write / NotebookEdit: protected-paths first, then classifier.
case "$TOOL" in
  Edit|Write|NotebookEdit)
    out=$(echo "$INPUT" | "$LIB/protected-paths.sh")
    if [ -n "$out" ]; then
      diag_emit "protected-paths" "ask" "$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // "protected path"')" "$SESS" "$TOOL"
      echo "$out"; exit 0
    fi
    mock_classifier && exit 0
    echo "$INPUT" | env PYTHONPATH="$DIR" python3 -m classifier
    exit 0
    ;;
esac

# All other tools (WebFetch, WebSearch, Agent, MCP tools, etc.): straight to classifier.
mock_classifier && exit 0
echo "$INPUT" | exec env PYTHONPATH="$DIR" python3 -m classifier
