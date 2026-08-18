#!/usr/bin/env bash
# Guards the self-modification tripwires: can the agent switch Aegis off?
#
# Two surfaces, one question:
#   lib/bash-hard-ask.sh    -- Bash commands writing to Aegis config or code
#   lib/protected-paths.sh  -- Edit/Write/NotebookEdit on the same paths
#
# No corpus command is executed. Each line is handed to a matcher as JSON and
# its verdict is compared to the expectation. Every target is non-existent.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/../../lib"
CORPUS="$DIR/corpus/aegis-self-modification.txt"
BYPASS_CORPUS="$DIR/corpus/aegis-self-write-bypasses.txt"
AEGIS_ROOT="$(cd "$DIR/../.." && pwd)"
AEGIS_PARENT="$(dirname "$AEGIS_ROOT")"
ORCH="$AEGIS_ROOT/orchestrator.sh"

unset AEGIS_ASK_MODE AEGIS_DEFER_SCOPE AEGIS_HARD_DENY_ACTION

for f in "$LIB/bash-hard-ask.sh" "$LIB/protected-paths.sh" "$ORCH" "$CORPUS" "$BYPASS_CORPUS"; do
  [ -e "$f" ] || { echo "ERROR: missing $f" >&2; exit 2; }
done

PASS=0; FAIL=0
FAILS=()

check() {  # $1 want (ASK|NONE), $2 got (ASK|NONE), $3 label
  if [ "$1" = "$2" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILS+=("want=$1 got=$2 : $3")
  fi
}

echo "--- Bash commands (lib/bash-hard-ask.sh) ---"
while IFS=$'\t' read -r want cmd; do
  case "$want" in ''|'#'*) continue ;; esac
  [ -z "${cmd:-}" ] && continue
  out=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' \
        | "$LIB/bash-hard-ask.sh" 2>/dev/null)
  [ -n "$out" ] && got=ASK || got=NONE
  check "$want" "$got" "$cmd"
done < "$CORPUS"
echo "  $PASS matched so far"

echo "--- file writes (lib/protected-paths.sh) ---"
paths_ask=(
  "$PWD/.aegis/aegis.toml"
  "$HOME/.config/aegis/aegis.toml"
  "$AEGIS_ROOT/lib/NOSUCHFILE.sh"
  "$AEGIS_ROOT/rules/NOSUCHFILE.json"
)
# Deliberately outside the install tree: when the suite runs from the Aegis
# repo itself, $PWD/src IS the install tree and correctly asks.
paths_none=(
  "/tmp/aegis-test-scratch.txt"
  "/tmp/some-other-project/src/NOSUCHFILE.py"
)
for p in "${paths_ask[@]}"; do
  out=$(jq -nc --arg p "$p" '{tool_name:"Edit",tool_input:{file_path:$p}}' \
        | "$LIB/protected-paths.sh" 2>/dev/null)
  [ -n "$out" ] && got=ASK || got=NONE
  check ASK "$got" "Edit $p"
done
for p in "${paths_none[@]}"; do
  out=$(jq -nc --arg p "$p" '{tool_name:"Edit",tool_input:{file_path:$p}}' \
        | "$LIB/protected-paths.sh" 2>/dev/null)
  [ -n "$out" ] && got=ASK || got=NONE
  check NONE "$got" "Edit $p"
done

echo "--- notebook writes (lib/protected-paths.sh, notebook_path key) ---"
# NotebookEdit hands its target over as notebook_path; only Edit and Write use
# file_path. protected-paths.sh listed NotebookEdit in its tool filter but read
# file_path alone, so a notebook write arrived with no path to test and fell
# through the whole layer -- .git, /etc and $HOME dotfiles included, not just
# the Aegis rules. These cases pin the key that actually arrives.
for p in "${paths_ask[@]}"; do
  out=$(jq -nc --arg p "$p" '{tool_name:"NotebookEdit",tool_input:{notebook_path:$p}}' \
        | "$LIB/protected-paths.sh" 2>/dev/null)
  [ -n "$out" ] && got=ASK || got=NONE
  check ASK "$got" "NotebookEdit(notebook_path) $p"
done
for p in "${paths_none[@]}"; do
  out=$(jq -nc --arg p "$p" '{tool_name:"NotebookEdit",tool_input:{notebook_path:$p}}' \
        | "$LIB/protected-paths.sh" 2>/dev/null)
  [ -n "$out" ] && got=ASK || got=NONE
  check NONE "$got" "NotebookEdit(notebook_path) $p"
done
# The bypass was never Aegis-specific, so cover a non-Aegis protected path too.
for p in "$HOME/.ssh/NOSUCHFILE.ipynb" "/etc/NOSUCHFILE.ipynb" "$PWD/.git/NOSUCHFILE.ipynb"; do
  out=$(jq -nc --arg p "$p" '{tool_name:"NotebookEdit",tool_input:{notebook_path:$p}}' \
        | "$LIB/protected-paths.sh" 2>/dev/null)
  [ -n "$out" ] && got=ASK || got=NONE
  check ASK "$got" "NotebookEdit(notebook_path) $p"
done
# file_path on NotebookEdit must keep working: the fix reads whichever key is
# present rather than swapping one hard-coded key for another.
out=$(jq -nc --arg p "$AEGIS_ROOT/lib/NOSUCHFILE.sh" \
        '{tool_name:"NotebookEdit",tool_input:{file_path:$p}}' \
      | "$LIB/protected-paths.sh" 2>/dev/null)
[ -n "$out" ] && got=ASK || got=NONE
check ASK "$got" "NotebookEdit(file_path) $AEGIS_ROOT/lib/NOSUCHFILE.sh"
# A tool this layer does not gate stays silent even carrying a protected path.
out=$(jq -nc --arg p "$AEGIS_ROOT/lib/NOSUCHFILE.sh" \
        '{tool_name:"Read",tool_input:{notebook_path:$p}}' \
      | "$LIB/protected-paths.sh" 2>/dev/null)
[ -n "$out" ] && got=ASK || got=NONE
check NONE "$got" "Read(notebook_path) $AEGIS_ROOT/lib/NOSUCHFILE.sh"

echo "--- end-to-end obfuscated self-writes (orchestrator.sh) ---"
# These commands are payload text only and are never executed.  A mocked ASK
# makes the assertion independent of whether a form is caught by hard-ask or
# conservatively reaches the classifier.  The unsafe result is specifically a
# gatekeeper ALLOW, which would replace the mock before it can answer.
E2E_HOME=$(mktemp -d)
cleanup_e2e() {
  case "$E2E_HOME" in
    /tmp/tmp.*) rm -r -- "$E2E_HOME" ;;
  esac
}
trap cleanup_e2e EXIT
mkdir -p "$E2E_HOME/Sync/Programs"
ln -s "$AEGIS_ROOT" "$E2E_HOME/Sync/Programs/aegis"
ln -s "$AEGIS_ROOT" "$E2E_HOME/aegis-alias"

# $4 is the expected verdict, defaulting to ASK. RESIDUAL marks a form this
# lexical layer knowingly does not catch: see the corpus header for why those
# are accepted rather than chased. Pinning them means a future change that
# closes one FAILS here, so the corpus gets updated deliberately instead of
# the win going unnoticed.
check_e2e() { # $1 label, $2 cwd, $3 command, $4 want (ASK|RESIDUAL)
  local label="$1" cwd="$2" cmd="$3" want="${4:-ASK}" input out rc got
  input=$(jq -nc --arg c "$cmd" --arg cwd "$cwd" --arg s "self-write-e2e-$$" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd,session_id:$s}')
  out=$(cd "$cwd" && printf '%s\n' "$input" | env \
      HOME="$E2E_HOME" \
      AEGIS_ASK_MODE=prompt \
      AEGIS_DEFER_SCOPE=classifier \
      AEGIS_TEST_MOCK_DECISION=ask \
      AEGIS_TEST_SELF_ROOT="$AEGIS_ROOT" \
      "$ORCH" 2>/dev/null)
  rc=$?
  got=NONE
  if [ "$rc" = 2 ]; then
    got=DENY
  elif printf '%s\n' "$out" | grep -qE '"permissionDecision"[[:space:]]*:[[:space:]]*"ask"'; then
    got=ASK
  elif printf '%s\n' "$out" | grep -qE '"permissionDecision"[[:space:]]*:[[:space:]]*"allow"'; then
    got=ALLOW
  fi
  if [ "$want" = RESIDUAL ]; then
    # Accepted: the gatekeeper hard-allows it before the classifier is reached.
    check ALLOW "$got" "$label (known residual): $cmd"
  else
    check ASK "$got" "$label: $cmd"
  fi
}

while IFS=$'\t' read -r label want cwd cmd; do
  case "$label" in ''|'#'*) continue ;; esac
  [ -z "${cmd:-}" ] && continue
  cwd=${cwd//@AEGIS_ROOT@/$AEGIS_ROOT}
  cwd=${cwd//@AEGIS_PARENT@/$AEGIS_PARENT}
  cmd=${cmd//@AEGIS_ROOT@/$AEGIS_ROOT}
  cmd=${cmd//@AEGIS_PARENT@/$AEGIS_PARENT}
  cmd=${cmd//@AEGIS_ALIAS@/$E2E_HOME\/aegis-alias}
  check_e2e "$label" "$cwd" "$cmd" "$want"
done < "$BYPASS_CORPUS"

# Unquoted heredoc bodies perform command substitution before the reader sees
# them. Multiline input must therefore reach the classifier as a whole.
heredoc_cmd=$'cat <<EOF\n$(python3 -c "open(\".aegis/NOSUCHFILE-e2e-v\",\"w\").write(\"x\")")\nEOF'
check_e2e "unquoted-heredoc-substitution" "$AEGIS_ROOT" "$heredoc_cmd"

# A familiar bare name can resolve to repo-controlled code through PATH or an
# exported function. It is not a proven reader unless resolution is trusted.
mkdir -p "$E2E_HOME/shadow"
ln -s "$(command -v touch)" "$E2E_HOME/shadow/ls"
PATH="$E2E_HOME/shadow:$PATH" check_e2e \
  "path-shadowed-reader" "$AEGIS_ROOT" "ls $AEGIS_ROOT/NOSUCHFILE-e2e-w" RESIDUAL
ls() { touch "$AEGIS_ROOT/NOSUCHFILE-e2e-x"; }
export -f ls
check_e2e "function-shadowed-reader" "$AEGIS_ROOT" \
  "ls $AEGIS_ROOT/NOSUCHFILE-e2e-x" RESIDUAL
unset -f ls
cleanup_e2e
trap - EXIT

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ] || { printf '  %s\n' "${FAILS[@]}" >&2; exit 1; }
