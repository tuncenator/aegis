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
# LAYERS. The loosening settings live in a stubbed GLOBAL config (one HOME per
# combination) because they are global-only: <cwd>/.aegis/aegis.toml is a file
# inside whatever repository the agent has open, so it may only ratchet toward
# the stricter value. The ratchet is asserted below; without it any repo could
# check in defer_scope = "all" and silence every tripwire.
#
# Hermetic on three axes:
#   - No live model call. The classifier layer is exercised through
#     AEGIS_TEST_MOCK_DECISION, which orchestrator.sh honours in place of the
#     Python classifier; the deny cases drive the real classifier with a chain
#     of one unknown provider, so it exhausts without touching the network.
#   - No developer config. HOME is stubbed per case and the AEGIS_* behavior
#     overrides are cleared, so the operator's own aegis.toml cannot steer it.
#   - No credentials. The provider API keys are unset. Stubbing HOME is not
#     enough on its own: the SDK reads GEMINI_API_KEY from the environment.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$DIR/../../orchestrator.sh"

# --- isolation --------------------------------------------------------------
unset AEGIS_ASK_MODE AEGIS_DEFER_SCOPE AEGIS_HARD_DENY_ACTION AEGIS_TEST_MOCK_DECISION
unset GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_GENAI_API_KEY ANTHROPIC_API_KEY

PASS=0; FAIL=0
FAILS=()
TMPDIRS=()

# A stubbed HOME carrying one global config. $1 = toml body ("" for none).
mkhome() {
  local dir; dir=$(mktemp -d); TMPDIRS+=("$dir")
  mkdir -p "$dir/.config/aegis"
  [ -n "$1" ] && printf '%s\n' "$1" > "$dir/.config/aegis/aegis.toml"
  echo "$dir"
}

# A project directory, optionally carrying an (untrusted) project config.
mkcwd() {
  local dir; dir=$(mktemp -d); TMPDIRS+=("$dir")
  if [ -n "$1" ]; then
    mkdir -p "$dir/.aegis"
    printf '%s\n' "$1" > "$dir/.aegis/aegis.toml"
  fi
  echo "$dir"
}

H_PROMPT=$(mkhome "")
H_DEFER=$(mkhome '[behavior]
ask_mode = "defer"')
H_DEFER_ALL=$(mkhome '[behavior]
ask_mode = "defer"
defer_scope = "all"')
H_DEFER_CLS=$(mkhome '[behavior]
ask_mode = "defer"
defer_scope = "classifier"')

PLAIN_CWD=$(mkcwd "")

cleanup() { rm -rf "${TMPDIRS[@]}"; }
trap cleanup EXIT

payload() {
  # $1 = tool_name, $2 = key, $3 = value, $4 = cwd
  jq -nc --arg t "$1" --arg k "$2" --arg v "$3" --arg c "$4" \
    '{session_id:"ask-mode-test", transcript_path:"/nonexistent.jsonl",
      cwd:$c, hook_event_name:"PreToolUse", tool_name:$t,
      tool_input:{($k):$v}}'
}

# $1 name, $2 payload, $3 expected stdout (ask|allow|deny|empty), $4 exit, $5 HOME
assert() {
  local name="$1" input="$2" want_out="$3" want_rc="$4" home="$5" out rc got
  out=$(echo "$input" | HOME="$home" "$ORCH" 2>/dev/null)
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

force_push() { payload Bash command 'git push --force origin feature-x' "${1:-$PLAIN_CWD}"; }
etc_write()  { payload Edit file_path /etc/passwd "${1:-$PLAIN_CWD}"; }
novel()      { payload Bash command 'frobnicate --quux' "${1:-$PLAIN_CWD}"; }
rm_root()    { payload Bash command 'rm -rf /' "${1:-$PLAIN_CWD}"; }
ls_la()      { payload Bash command 'ls -la' "${1:-$PLAIN_CWD}"; }

echo "--- ask_mode = prompt (default): everything asks ---"
assert "hard-ask: git push --force"       "$(force_push)" ask 0 "$H_PROMPT"
assert "protected path: Edit /etc/passwd" "$(etc_write)"  ask 0 "$H_PROMPT"

echo "--- ask_mode = defer, defer_scope default: deterministic asks survive ---"
assert "hard-ask still prompts"           "$(force_push)" ask 0 "$H_DEFER"
assert "protected path still prompts"     "$(etc_write)"  ask 0 "$H_DEFER"
assert "explicit defer_scope=classifier"  "$(force_push)" ask 0 "$H_DEFER_CLS"

echo "--- ask_mode = defer, defer_scope = all: deterministic asks go silent ---"
assert "hard-ask defers"                  "$(force_push)" empty 0 "$H_DEFER_ALL"
assert "protected path defers"            "$(etc_write)"  empty 0 "$H_DEFER_ALL"

echo "--- deny and allow are unaffected by either setting ---"
assert "hard-deny: rm -rf / (defer)"      "$(rm_root)" empty 2 "$H_DEFER"
assert "hard-deny: rm -rf / (defer all)"  "$(rm_root)" empty 2 "$H_DEFER_ALL"
assert "allow: ls -la (defer)"            "$(ls_la)"   allow 0 "$H_DEFER"
assert "allow: ls -la (defer all)"        "$(ls_la)"   allow 0 "$H_DEFER_ALL"
assert "allow: ls -la (prompt)"           "$(ls_la)"   allow 0 "$H_PROMPT"

echo "--- classifier layer (mocked verdict, no live model) ---"
# The classifier's own ASK defers under ask_mode=defer in BOTH scopes:
# defer_scope only governs the deterministic layers.
AEGIS_TEST_MOCK_DECISION=ask assert "classifier ask, prompt mode" \
  "$(novel)" ask 0 "$H_PROMPT"
AEGIS_TEST_MOCK_DECISION=ask assert "classifier ask, defer + scope=classifier" \
  "$(novel)" empty 0 "$H_DEFER"
AEGIS_TEST_MOCK_DECISION=ask assert "classifier ask, defer + scope=all" \
  "$(novel)" empty 0 "$H_DEFER_ALL"
AEGIS_TEST_MOCK_DECISION=allow assert "classifier allow, defer mode" \
  "$(novel)" allow 0 "$H_DEFER"

echo "--- env vars override config ---"
AEGIS_ASK_MODE=defer AEGIS_DEFER_SCOPE=all assert "env defer+all beats prompt config" \
  "$(force_push)" empty 0 "$H_PROMPT"
AEGIS_ASK_MODE=prompt assert "env prompt beats defer config" \
  "$(force_push)" ask 0 "$H_DEFER_ALL"
AEGIS_DEFER_SCOPE=classifier assert "env scope=classifier beats config scope=all" \
  "$(force_push)" ask 0 "$H_DEFER_ALL"

# The project layer is untrusted: <cwd>/.aegis/aegis.toml lives inside the
# repository the agent has open. It may tighten, never loosen. Without this,
# any repo could check in defer_scope = "all" and silence every tripwire the
# "classifier" default exists to preserve.
echo "--- project config may ratchet, never loosen ---"
CWD_WANTS_ALL=$(mkcwd '[behavior]
ask_mode = "defer"
defer_scope = "all"')
CWD_WANTS_STRICT=$(mkcwd '[behavior]
ask_mode = "prompt"
defer_scope = "classifier"')

assert "project defer_scope=all is ignored" \
  "$(force_push "$CWD_WANTS_ALL")" ask 0 "$H_DEFER_CLS"
assert "project ask_mode=defer is ignored" \
  "$(force_push "$CWD_WANTS_ALL")" ask 0 "$H_PROMPT"
assert "project may tighten scope to classifier" \
  "$(force_push "$CWD_WANTS_STRICT")" ask 0 "$H_DEFER_ALL"
AEGIS_TEST_MOCK_DECISION=ask assert "project may tighten ask_mode to prompt" \
  "$(novel "$CWD_WANTS_STRICT")" ask 0 "$H_DEFER"

# A classifier DENY is never deferred: the snapshot's hard_deny section
# (Data Exfiltration) arrives as a deny, and deferring it would hand the call
# to the native classifier instead of to the operator.
#
# These run the REAL Python classifier end to end, still without a model call:
# the provider chain is a single unknown provider, which _call_provider returns
# None for immediately, so the chain exhausts and on_exhaustion synthesizes the
# deny verdict. chain and on_exhaustion are global-only, so they live in the
# stubbed HOME rather than in a project config.
echo "--- classifier DENY under ask_mode=defer (real classifier, no model) ---"
deny_home() {
  mkhome "[classifier]
chain = [ { provider = \"none\", model = \"unused\", retries = 1, timeout_s = 1 } ]
on_exhaustion = \"deny\"

[behavior]
ask_mode = \"defer\"
defer_scope = \"all\"
hard_deny_action = \"$1\""
}
H_DENY_PROMPT=$(deny_home prompt)
H_DENY_BLOCK=$(deny_home block)

deny_payload() {
  jq -nc --arg c "$PLAIN_CWD" --arg s "ask-mode-deny-$1-$$-$RANDOM" \
    '{session_id:$s,transcript_path:"/nonexistent.jsonl",cwd:$c,
      hook_event_name:"PreToolUse",tool_name:"Bash",
      tool_input:{command:"frobnicate --quux"}}'
}

# defer_scope = "all" is deliberate here: even the most permissive deferral
# setting must not swallow a deny.
assert "deny surfaces as ask, not silence"  "$(deny_payload a)" ask   0 "$H_DENY_PROMPT"
assert "deny hard-blocks with action=block" "$(deny_payload b)" empty 2 "$H_DENY_BLOCK"

# ONE PARSER. ask_mode and defer_scope used to be read TWICE: by an awk line
# matcher in lib/ask-mode.sh for the deterministic shell layers, and by tomllib
# in classifier/rules.py for the classifier and `aegis status`.
# orchestrator.sh exports the shell answer and rules.py lets the environment
# override its own parsed value, so the awk reading was the one that actually
# gated tool calls -- and it disagreed with the TOML spec on ordinary files.
#
# Each config below is one of those disagreements. The expected result is
# always what the file MEANS, i.e. what tomllib says, because that is now the
# only reading of it there is.
echo "--- one parser: the shell layers agree with tomllib ---"
unset AEGIS_ASK_MODE AEGIS_DEFER_SCOPE

# The dangerous one, and the only divergence that ran LOOSER than the file.
# The value here is a boolean, so defer_scope is never validly set and the
# deterministic tripwires stay armed. The awk reader lifted "all" out of the
# trailing COMMENT and disarmed them, while `aegis status` went on reporting
# them active -- a silently disabled guard reads exactly like a working one.
H_BOOL_COMMENT=$(mkhome '[behavior]
ask_mode = "defer"
defer_scope = false # "all"')
assert "a value in a comment is not a value" "$(force_push)" ask 0 "$H_BOOL_COMMENT"

# A comment after a table header is legal TOML. The awk header match anchored
# on end-of-line, so the whole [behavior] table went unseen and BOTH keys fell
# back to their defaults. Stricter than the file, but still not the file.
H_HEADER_COMMENT=$(mkhome '[behavior] # operator note
ask_mode = "defer"
defer_scope = "all"')
assert "comment after [behavior] header: scope" "$(force_push)" empty 0 "$H_HEADER_COMMENT"
AEGIS_TEST_MOCK_DECISION=ask assert "comment after [behavior] header: mode" \
  "$(novel)" empty 0 "$H_HEADER_COMMENT"

# Regression from the multi-line-string tracking the awk reader grew to fix a
# different divergence: a bare `# """` comment contains an odd number of `"""`
# runs, so the reader believed a multi-line string had opened and ignored the
# whole rest of the file.
H_HASH_TRIPLE=$(mkhome '[behavior]
ask_mode = "defer"
# """ a comment that looks like a heredoc
defer_scope = "all"')
assert "a # \"\"\" comment opens nothing" "$(force_push)" empty 0 "$H_HASH_TRIPLE"

# TOML literal strings are single-quoted. The awk reader only ever looked for
# a double-quoted value, so this key was invisible to it.
H_LITERAL=$(mkhome "[behavior]
ask_mode = \"defer\"
defer_scope = 'all'")
assert "literal (single-quoted) string value" "$(force_push)" empty 0 "$H_LITERAL"

# Control, and the reason multi-line tracking was added at all: defer_scope
# here is string CONTENT, not a setting, and must not be read as one.
H_MULTILINE=$(mkhome '[behavior]
ask_mode = "defer"
note = """
defer_scope = "all"
"""')
assert "config inside a multi-line string is content" "$(force_push)" ask 0 "$H_MULTILINE"

# The parity property itself, asserted directly instead of through a decision:
# whatever the shell layers act on must be what classifier/rules.py computes
# for the same input. Both sides are the same tomllib loader now, so these
# cases are a structural guard -- they fail the moment anyone reintroduces a
# second reader on either side.
echo "--- parity: shell resolver == classifier/rules.py ---"
REPO="$DIR/../.."
# shellcheck source=../../lib/ask-mode.sh
. "$REPO/lib/ask-mode.sh"
PYBIN="$REPO/.venv/bin/python3"
[ -x "$PYBIN" ] || PYBIN=python3

record() { # $1 name, $2 got, $3 want
  local got want
  got=$(printf '%s' "$2" | tr '\t' '/')
  want=$(printf '%s' "$3" | tr '\t' '/')
  if [ "$got" = "$want" ]; then
    PASS=$((PASS+1))
    printf 'ok   %-52s %s\n' "$1" "$got"
  else
    FAIL=$((FAIL+1))
    FAILS+=("$1: want $want, got $got")
    printf 'FAIL %-52s want=%s got=%s\n' "$1" "$want" "$got"
  fi
}

parity() { # $1 name, $2 HOME, $3 cwd
  local sh py
  sh=$(export HOME="$2"; aegis_resolve_behavior "$3")
  py=$(export HOME="$2"; env PYTHONPATH="$REPO" "$PYBIN" -P -c '
import sys
from classifier import rules
cfg = rules.load_config(sys.argv[1] or None)
sys.stdout.write(cfg.ask_mode + "\t" + cfg.defer_scope + "\n")' "$3" 2>/dev/null)
  record "$1" "$sh" "$py"
}

parity "parity: bool with \"all\" in a comment" "$H_BOOL_COMMENT"   "$PLAIN_CWD"
parity "parity: comment after table header"    "$H_HEADER_COMMENT" "$PLAIN_CWD"
parity "parity: bare # \"\"\" comment"         "$H_HASH_TRIPLE"    "$PLAIN_CWD"
parity "parity: literal string value"          "$H_LITERAL"        "$PLAIN_CWD"
parity "parity: multi-line string content"     "$H_MULTILINE"      "$PLAIN_CWD"
parity "parity: no config anywhere"            "$H_PROMPT"         "$PLAIN_CWD"
parity "parity: project tries to loosen"       "$H_DEFER_CLS"      "$CWD_WANTS_ALL"
parity "parity: project ratchets tighter"      "$H_DEFER_ALL"      "$CWD_WANTS_STRICT"

# ONE READ. orchestrator.sh takes both keys from a single call so that a
# config edit landing mid-resolution cannot combine the ask_mode of one
# version of the file with the defer_scope of another and synthesize a
# defer/all pair that never existed on disk.
echo "--- one read: both keys from a single resolution ---"
record "both keys come from one resolution" \
  "$(export HOME="$H_DEFER_ALL"; aegis_resolve_behavior "$PLAIN_CWD")" \
  "$(printf 'defer\tall')"
record "the ratchet applies to the pair" \
  "$(export HOME="$H_DEFER_ALL"; aegis_resolve_behavior "$CWD_WANTS_STRICT")" \
  "$(printf 'prompt\tclassifier')"

# FAIL SAFE. Reading the config now costs a python3 spawn, so it can fail in
# ways awk could not. Every one of those failures must land on the STRICTER
# value of each setting. Guessing defer/all on error would disarm every
# deterministic tripwire exactly when Aegis is least sure of itself, and
# unlike a spurious prompt that failure is invisible.
echo "--- fail safe: an unusable parse resolves strict ---"
ORPHAN=$(mktemp -d); TMPDIRS+=("$ORPHAN")
mkdir -p "$ORPHAN/lib"
cp "$REPO/lib/ask-mode.sh" "$ORPHAN/lib/ask-mode.sh"

# Copied out of the install tree: classifier.rules is not importable, so the
# one parser is unreachable even though python3 itself runs.
record "parser unreachable resolves strict" \
  "$(export HOME="$H_DEFER_ALL"
     . "$ORPHAN/lib/ask-mode.sh"
     aegis_resolve_behavior "$PLAIN_CWD")" \
  "$(printf 'prompt\tclassifier')"

# No interpreter at all.
record "missing python3 resolves strict" \
  "$(export HOME="$H_DEFER_ALL"
     . "$ORPHAN/lib/ask-mode.sh"
     export PATH="$ORPHAN/no-such-bin"
     aegis_resolve_behavior "$PLAIN_CWD")" \
  "$(printf 'prompt\tclassifier')"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ] || { printf '  %s\n' "${FAILS[@]}" >&2; exit 1; }
