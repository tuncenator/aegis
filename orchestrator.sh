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
# Pipeline (Harmless tools):
#   Read/Glob/Grep/TodoWrite/TaskCreate/.../Agent/Task/WebFetch/WebSearch
#   ALLOW immediately, no classifier.
#   - Agent/Task (subagent dispatch): each subagent tool call comes back
#     through this hook, so gating the dispatch adds noise without safety.
#   - WebFetch/WebSearch: read-only network reads, no side effects.
#
# ASK handling is centralized here, not in the layer scripts. The layers
# stay pure pattern matchers that emit their ask JSON; this file decides
# whether that ask reaches Claude Code (ask_mode=prompt) or is swallowed
# into a silent exit 0 (ask_mode=defer). Converting inside a layer would
# be wrong: the orchestrator reads an empty layer result as "no match" and
# would continue to the NEXT Aegis layer, so a deferred hard-ask could end
# up allowed by the gatekeeper or the LLM classifier instead of handed to
# Claude Code's native auto-mode classifier.
#
# Under ask_mode=defer, defer_scope decides WHICH asks go silent:
#   classifier (default) -- only the LLM classifier's verdicts defer. The
#     deterministic layers above still prompt, because the auto-mode rule
#     snapshot has no rules for the ground they cover (/etc, /usr/bin,
#     ~/.ssh, .git, .claude, force push) and they fire on ~0.2% of calls.
#   all -- deterministic asks defer too; only hard-deny (exit 2) survives.

set -u

# Resolve symlinks so the plugin path (~/.../plugin/orchestrator.sh) finds
# the real aegis root and its .venv. readlink -f follows the chain.
SRC="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
DIR="$(cd "$(dirname "$SRC")" && pwd)"
LIB="$DIR/lib"

# Prefer the project's uv-managed venv so the classifier sees google-genai
# and other Python deps.
if [ -x "$DIR/.venv/bin/python" ]; then
  export PATH="$DIR/.venv/bin:$PATH"
fi

# Test-mode shortcut: when AEGIS_TEST_MOCK_DECISION is set, return that decision.
mock_classifier() {
  case "${AEGIS_TEST_MOCK_DECISION:-}" in
    allow) echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'; exit 0 ;;
    deny)  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"mock"}}'; exit 0 ;;
    ask)   emit_classifier_ask '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask"}}' ;;
    *) return 1 ;;
  esac
}

emit_allow() {
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
  exit 0
}

# Surface an ASK from a DETERMINISTIC layer (bash-hard-ask, protected-paths,
# the gatekeeper's ask exit). Swallowed only when ask_mode=defer AND
# defer_scope=all. Always exits 0.
emit_ask() {
  if [ "$ASK_MODE" = "defer" ] && [ "$DEFER_SCOPE" = "all" ]; then
    exit 0
  fi
  echo "$1"
  exit 0
}

# Surface an ASK that stands in for the LLM classifier's verdict. Always
# swallowed under ask_mode=defer regardless of defer_scope, matching what
# classifier/decision.py does with a real verdict. Always exits 0.
emit_classifier_ask() {
  if [ "$ASK_MODE" != "defer" ]; then
    echo "$1"
  fi
  exit 0
}

# Read whole stdin; we'll re-feed it to layer scripts.
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
SESS=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# shellcheck source=lib/ask-mode.sh
. "$LIB/ask-mode.sh"
ASK_MODE=$(aegis_resolve_ask_mode "$CWD")
export AEGIS_ASK_MODE="$ASK_MODE"
DEFER_SCOPE=$(aegis_resolve_defer_scope "$CWD")
export AEGIS_DEFER_SCOPE="$DEFER_SCOPE"

# Diag emitter for the deterministic layers. Delegates to classifier.diagcli
# so the [logging] diag_path and max_bytes settings govern these rows too;
# this used to be an inline heredoc that hardcoded the default path, which
# meant the bash layers and the classifier could log to different files.
diag_emit() {
  local layer="$1" decision="$2" reason="$3" sess="$4" tool="$5"
  env PYTHONPATH="$DIR" python3 -m classifier.diagcli \
    "$sess" "$tool" "$layer" "$decision" "$reason" "${CWD:-}" 2>/dev/null || true
}

# Read-only / harmless tools: allow without any classifier.
# Agent/Task are subagent dispatchers; the subagent's individual tool calls
# come back through this hook, so gating the dispatch itself adds noise without
# safety. WebFetch/WebSearch are read-only network reads.
case "$TOOL" in
  Read|Glob|Grep|TodoWrite|TaskCreate|TaskUpdate|TaskList|TaskGet|TaskOutput|TaskStop|Agent|Task|WebFetch|WebSearch)
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
    emit_ask "$out"
  fi

  # Layer 3: hard-allow (gatekeeper). The gatekeeper also has one ASK exit
  # (heredoc body containing a DB write), so read its verdict rather than
  # treating any output as an allow.
  out=$(echo "$INPUT" | "$LIB/bash-gatekeeper.sh")
  if [ -n "$out" ]; then
    if echo "$out" | grep -q '"permissionDecision":"ask"'; then
      diag_emit "hard-ask" "ask" "bash-gatekeeper ask" "$SESS" "$TOOL"
      emit_ask "$out"
    fi
    diag_emit "hard-allow" "allow" "bash-gatekeeper matched" "$SESS" "$TOOL"
    echo "$out"; exit 0
  fi

  # Layer 4: classifier. Its exit code is propagated: with
  # [behavior] hard_deny_action = "block" it returns 2 (hard block) instead
  # of writing a decision.
  mock_classifier && exit 0
  echo "$INPUT" | env PYTHONPATH="$DIR" python3 -m classifier
  exit $?
fi

# Edit / Write / NotebookEdit: protected-paths first, then classifier.
case "$TOOL" in
  Edit|Write|NotebookEdit)
    out=$(echo "$INPUT" | "$LIB/protected-paths.sh")
    if [ -n "$out" ]; then
      diag_emit "protected-paths" "ask" "$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // "protected path"')" "$SESS" "$TOOL"
      emit_ask "$out"
    fi
    mock_classifier && exit 0
    echo "$INPUT" | env PYTHONPATH="$DIR" python3 -m classifier
    exit $?
    ;;
esac

# All other tools (MCP tools, etc.): straight to classifier.
mock_classifier && exit 0
echo "$INPUT" | exec env PYTHONPATH="$DIR" python3 -m classifier
