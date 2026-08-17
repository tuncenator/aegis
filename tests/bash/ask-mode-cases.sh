#!/usr/bin/env bash
# ask_mode end-to-end tests. Feeds orchestrator.sh the same PreToolUse JSON
# shape Claude Code sends and asserts what reaches stdout.
#
#   ask_mode = "prompt" (default) -> ASK verdicts emit permissionDecision:ask
#   ask_mode = "defer"            -> ASK verdicts emit NOTHING, exit 0
#
# Deferring matters because a PreToolUse hook that returns "allow" or "ask"
# short-circuits Claude Code's permission pipeline; only exit 0 with empty
# stdout falls through to it, so the native auto-mode classifier decides.
#
# Hard denies (exit 2) and allows must be identical in both modes.
#
# Hermetic: no live model call. The classifier layer is exercised through
# AEGIS_TEST_MOCK_DECISION, which orchestrator.sh honours in place of the
# Python classifier.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$DIR/../../orchestrator.sh"

PASS=0; FAIL=0
FAILS=()

# Project config that turns deferral on, so the toml path is exercised and
# not just the AEGIS_ASK_MODE env var.
DEFER_CWD=$(mktemp -d)
mkdir -p "$DEFER_CWD/.aegis"
printf '[behavior]\nask_mode = "defer"\n' > "$DEFER_CWD/.aegis/aegis.toml"
PROMPT_CWD=$(mktemp -d)
trap 'rm -rf "$DEFER_CWD" "$PROMPT_CWD"' EXIT

payload() {
  # $1 = tool_name, $2 = key, $3 = value, $4 = cwd
  jq -nc --arg t "$1" --arg k "$2" --arg v "$3" --arg c "$4" \
    '{session_id:"ask-mode-test", transcript_path:"/nonexistent.jsonl",
      cwd:$c, hook_event_name:"PreToolUse", tool_name:$t,
      tool_input:{($k):$v}}'
}

# $1 name, $2 payload, $3 expected stdout shape (ask|allow|deny|empty), $4 expected exit
assert() {
  local name="$1" input="$2" want_out="$3" want_rc="$4" out rc got
  out=$(echo "$input" | "$ORCH" 2>/dev/null)
  rc=$?
  if [ -z "$out" ]; then got="empty"
  elif echo "$out" | grep -q '"permissionDecision":"ask"'; then got="ask"
  elif echo "$out" | grep -q '"permissionDecision":"allow"'; then got="allow"
  elif echo "$out" | grep -q '"permissionDecision":"deny"'; then got="deny"
  else got="unknown"
  fi
  if [ "$got" = "$want_out" ] && [ "$rc" = "$want_rc" ]; then
    PASS=$((PASS+1))
    printf 'ok   %-46s stdout=%-5s exit=%s\n' "$name" "$got" "$rc"
  else
    FAIL=$((FAIL+1))
    FAILS+=("$name: want stdout=$want_out exit=$want_rc, got stdout=$got exit=$rc")
    printf 'FAIL %-46s want=%s/%s got=%s/%s\n' "$name" "$want_out" "$want_rc" "$got" "$rc"
  fi
}

FORCE_PUSH_PROMPT=$(payload Bash command 'git push --force origin feature-x' "$PROMPT_CWD")
FORCE_PUSH_DEFER=$(payload Bash command 'git push --force origin feature-x' "$DEFER_CWD")

echo "--- ask_mode = prompt (default) ---"
assert "hard-ask: git push --force"        "$FORCE_PUSH_PROMPT" ask   0
assert "protected path: Edit /etc/passwd"  "$(payload Edit file_path /etc/passwd "$PROMPT_CWD")" ask 0

echo "--- ask_mode = defer (same commands) ---"
assert "hard-ask: git push --force"        "$FORCE_PUSH_DEFER" empty 0
assert "protected path: Edit /etc/passwd"  "$(payload Edit file_path /etc/passwd "$DEFER_CWD")" empty 0

echo "--- ask_mode = defer: deny and allow are unaffected ---"
assert "hard-deny: rm -rf /"               "$(payload Bash command 'rm -rf /' "$DEFER_CWD")"  empty 2
assert "allow: ls -la"                     "$(payload Bash command 'ls -la' "$DEFER_CWD")"    allow 0
assert "allow: ls -la (prompt mode)"       "$(payload Bash command 'ls -la' "$PROMPT_CWD")"   allow 0

echo "--- classifier layer (mocked verdict, no live model) ---"
AEGIS_TEST_MOCK_DECISION=ask assert "classifier ask, prompt mode" \
  "$(payload Bash command 'frobnicate --quux' "$PROMPT_CWD")" ask 0
AEGIS_TEST_MOCK_DECISION=ask assert "classifier ask, defer mode" \
  "$(payload Bash command 'frobnicate --quux' "$DEFER_CWD")" empty 0
AEGIS_TEST_MOCK_DECISION=allow assert "classifier allow, defer mode" \
  "$(payload Bash command 'frobnicate --quux' "$DEFER_CWD")" allow 0

echo "--- AEGIS_ASK_MODE env var overrides config ---"
AEGIS_ASK_MODE=defer assert "env defer beats prompt-mode cwd" "$FORCE_PUSH_PROMPT" empty 0
AEGIS_ASK_MODE=prompt assert "env prompt beats defer-mode cwd" "$FORCE_PUSH_DEFER" ask 0

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ] || { printf '  %s\n' "${FAILS[@]}" >&2; exit 1; }
