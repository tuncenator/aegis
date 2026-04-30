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

# Read-only / harmless tools: allow without any classifier.
case "$TOOL" in
  Read|Glob|Grep|TodoWrite|TaskCreate|TaskUpdate|TaskList|TaskGet|TaskOutput|TaskStop)
    emit_allow
    ;;
esac

# Layer dispatch by tool family.
if [ "$TOOL" = "Bash" ]; then
  # Layer 1: hard-deny (exits 2 if matched; we propagate).
  echo "$INPUT" | "$LIB/bash-denylist.sh"
  rc=$?
  [ "$rc" = 2 ] && exit 2

  # Layer 2: hard-ask.
  out=$(echo "$INPUT" | "$LIB/bash-hard-ask.sh")
  if [ -n "$out" ]; then echo "$out"; exit 0; fi

  # Layer 3: hard-allow (gatekeeper).
  out=$(echo "$INPUT" | "$LIB/bash-gatekeeper.sh")
  if [ -n "$out" ]; then echo "$out"; exit 0; fi

  # Layer 4: classifier.
  mock_classifier && exit 0
  echo "$INPUT" | env PYTHONPATH="$DIR" python3 -m classifier
  exit 0
fi

# Edit / Write / NotebookEdit: protected-paths first, then classifier.
case "$TOOL" in
  Edit|Write|NotebookEdit)
    out=$(echo "$INPUT" | "$LIB/protected-paths.sh")
    if [ -n "$out" ]; then echo "$out"; exit 0; fi
    mock_classifier && exit 0
    echo "$INPUT" | env PYTHONPATH="$DIR" python3 -m classifier
    exit 0
    ;;
esac

# All other tools (WebFetch, WebSearch, Agent, MCP tools, etc.): straight to classifier.
mock_classifier && exit 0
echo "$INPUT" | exec env PYTHONPATH="$DIR" python3 -m classifier
