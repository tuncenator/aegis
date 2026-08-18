#!/usr/bin/env bash
# ask_mode / defer_scope end-to-end tests. Feeds orchestrator.sh the same
# PreToolUse JSON shape Claude Code sends and asserts what reaches stdout.
#
#   ask_mode = "prompt" (default) -> ASK verdicts emit permissionDecision:ask
#   ask_mode = "defer"            -> ASK verdicts emit NOTHING, exit 0
#
#   defer_scope = "classifier" (default) -> under defer, only the LLM
#       classifier's verdicts go silent. Aegis's deterministic tripwires
#       (bash-hard-ask, protected-paths) still prompt: the auto-mode rule
#       snapshot has no rules for /etc, /usr/bin, ~/.ssh, .git or .claude,
#       so deferring them would drop the check entirely.
#   defer_scope = "all"                  -> deterministic asks defer too.
#
# Deferring matters because a PreToolUse hook that returns "allow" or "ask"
# short-circuits Claude Code's permission pipeline; only exit 0 with empty
# stdout falls through to it, so the native auto-mode classifier decides.
#
# Hard denies (exit 2) and allows must be identical in every combination.
#
# Hermetic on two axes:
#   - No live model call. The classifier layer is exercised through
#     AEGIS_TEST_MOCK_DECISION, which orchestrator.sh honours in place of
#     the Python classifier.
#   - No developer state. HOME is stubbed and every AEGIS_* override is
#     cleared, so the operator's own ~/.config/aegis/aegis.toml (which may
#     well set ask_mode = "defer") cannot steer the assertions.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$DIR/../../orchestrator.sh"

# --- isolation --------------------------------------------------------------
unset AEGIS_ASK_MODE AEGIS_DEFER_SCOPE AEGIS_HARD_DENY_ACTION AEGIS_TEST_MOCK_DECISION
REAL_HOME="$HOME"
STUB_HOME=$(mktemp -d)
export HOME="$STUB_HOME"

PASS=0; FAIL=0
FAILS=()

# One cwd per config combination, so the TOML path is exercised and not just
# the env vars. An absent [behavior] table means the built-in defaults.
mkcwd() {  # $1 = toml body ("" for none)
  local dir; dir=$(mktemp -d)
  if [ -n "$1" ]; then
    mkdir -p "$dir/.aegis"
    printf '%s\n' "$1" > "$dir/.aegis/aegis.toml"
  fi
  echo "$dir"
}

PROMPT_CWD=$(mkcwd "")
DEFER_CWD=$(mkcwd '[behavior]
ask_mode = "defer"')
DEFER_ALL_CWD=$(mkcwd '[behavior]
ask_mode = "defer"
defer_scope = "all"')
DEFER_CLS_CWD=$(mkcwd '[behavior]
ask_mode = "defer"
defer_scope = "classifier"')

cleanup() {
  export HOME="$REAL_HOME"
  rm -rf "$STUB_HOME" "$PROMPT_CWD" "$DEFER_CWD" "$DEFER_ALL_CWD" "$DEFER_CLS_CWD"
}
trap cleanup EXIT

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
  # The shell layers emit compact JSON, the Python classifier emits
  # json.dumps spacing, so match both.
  if [ -z "$out" ]; then got="empty"
  elif echo "$out" | grep -qE '"permissionDecision"[[:space:]]*:[[:space:]]*"ask"'; then got="ask"
  elif echo "$out" | grep -qE '"permissionDecision"[[:space:]]*:[[:space:]]*"allow"'; then got="allow"
  elif echo "$out" | grep -qE '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then got="deny"
  else got="unknown"
  fi
  if [ "$got" = "$want_out" ] && [ "$rc" = "$want_rc" ]; then
    PASS=$((PASS+1))
    printf 'ok   %-52s stdout=%-5s exit=%s\n' "$name" "$got" "$rc"
  else
    FAIL=$((FAIL+1))
    FAILS+=("$name: want stdout=$want_out exit=$want_rc, got stdout=$got exit=$rc")
    printf 'FAIL %-52s want=%s/%s got=%s/%s\n' "$name" "$want_out" "$want_rc" "$got" "$rc"
  fi
}

force_push() { payload Bash command 'git push --force origin feature-x' "$1"; }
etc_write()  { payload Edit file_path /etc/passwd "$1"; }
novel()      { payload Bash command 'frobnicate --quux' "$1"; }

echo "--- ask_mode = prompt (default): everything asks ---"
assert "hard-ask: git push --force"          "$(force_push "$PROMPT_CWD")" ask 0
assert "protected path: Edit /etc/passwd"    "$(etc_write  "$PROMPT_CWD")" ask 0

echo "--- ask_mode = defer, defer_scope default: deterministic asks survive ---"
assert "hard-ask still prompts"              "$(force_push "$DEFER_CWD")" ask 0
assert "protected path still prompts"        "$(etc_write  "$DEFER_CWD")" ask 0
assert "explicit defer_scope=classifier"     "$(force_push "$DEFER_CLS_CWD")" ask 0

echo "--- ask_mode = defer, defer_scope = all: deterministic asks go silent ---"
assert "hard-ask defers"                     "$(force_push "$DEFER_ALL_CWD")" empty 0
assert "protected path defers"               "$(etc_write  "$DEFER_ALL_CWD")" empty 0

echo "--- deny and allow are unaffected by either setting ---"
assert "hard-deny: rm -rf / (defer)"         "$(payload Bash command 'rm -rf /' "$DEFER_CWD")"     empty 2
assert "hard-deny: rm -rf / (defer all)"     "$(payload Bash command 'rm -rf /' "$DEFER_ALL_CWD")" empty 2
assert "allow: ls -la (defer)"               "$(payload Bash command 'ls -la' "$DEFER_CWD")"       allow 0
assert "allow: ls -la (defer all)"           "$(payload Bash command 'ls -la' "$DEFER_ALL_CWD")"   allow 0
assert "allow: ls -la (prompt)"              "$(payload Bash command 'ls -la' "$PROMPT_CWD")"      allow 0

echo "--- classifier layer (mocked verdict, no live model) ---"
# The classifier's own ASK defers under ask_mode=defer in BOTH scopes:
# defer_scope only governs the deterministic layers.
AEGIS_TEST_MOCK_DECISION=ask assert "classifier ask, prompt mode" \
  "$(novel "$PROMPT_CWD")" ask 0
AEGIS_TEST_MOCK_DECISION=ask assert "classifier ask, defer + scope=classifier" \
  "$(novel "$DEFER_CWD")" empty 0
AEGIS_TEST_MOCK_DECISION=ask assert "classifier ask, defer + scope=all" \
  "$(novel "$DEFER_ALL_CWD")" empty 0
AEGIS_TEST_MOCK_DECISION=allow assert "classifier allow, defer mode" \
  "$(novel "$DEFER_CWD")" allow 0

echo "--- env vars override config ---"
AEGIS_ASK_MODE=defer AEGIS_DEFER_SCOPE=all assert "env defer+all beats prompt-mode cwd" \
  "$(force_push "$PROMPT_CWD")" empty 0
AEGIS_ASK_MODE=prompt assert "env prompt beats defer-mode cwd" \
  "$(force_push "$DEFER_ALL_CWD")" ask 0
AEGIS_DEFER_SCOPE=classifier assert "env scope=classifier beats cwd scope=all" \
  "$(force_push "$DEFER_ALL_CWD")" ask 0

# A classifier DENY is never deferred: the snapshot's hard_deny section
# (Data Exfiltration) arrives as a deny, and deferring it would hand the call
# to the native classifier instead of to the operator.
#
# These two run the REAL Python classifier end to end, still without a model
# call: the provider chain is a single unknown provider, which _call_provider
# returns None for immediately, so the chain exhausts and on_exhaustion
# synthesizes the deny verdict.
echo "--- classifier DENY under ask_mode=defer (real classifier, no model) ---"
deny_cwd() {
  mkcwd "[classifier]
chain = [ { provider = \"none\", model = \"unused\", retries = 1, timeout_s = 1 } ]
on_exhaustion = \"deny\"

[behavior]
ask_mode = \"defer\"
defer_scope = \"all\"
hard_deny_action = \"$1\""
}
DENY_PROMPT_CWD=$(deny_cwd prompt)
DENY_BLOCK_CWD=$(deny_cwd block)

deny_payload() {
  jq -nc --arg c "$1" --arg s "ask-mode-deny-$2-$$-$RANDOM" \
    '{session_id:$s,transcript_path:"/nonexistent.jsonl",cwd:$c,
      hook_event_name:"PreToolUse",tool_name:"Bash",
      tool_input:{command:"frobnicate --quux"}}'
}

# defer_scope = "all" is deliberate here: even the most permissive deferral
# setting must not swallow a deny.
assert "deny surfaces as ask, not silence" "$(deny_payload "$DENY_PROMPT_CWD" a)" ask   0
assert "deny hard-blocks with action=block" "$(deny_payload "$DENY_BLOCK_CWD" b)" empty 2

rm -rf "$DENY_PROMPT_CWD" "$DENY_BLOCK_CWD"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ] || { printf '  %s\n' "${FAILS[@]}" >&2; exit 1; }
