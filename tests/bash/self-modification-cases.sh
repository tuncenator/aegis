#!/usr/bin/env bash
# Guards the self-modification tripwires: can the agent switch Aegis off?
#
# Two surfaces, one question:
#   lib/bash-hard-ask.sh    -- Bash commands writing to Aegis config or code
#   lib/protected-paths.sh  -- Edit/Write/NotebookEdit on the same paths
#
# Nothing here is executed. Each corpus line is handed to a matcher as a JSON
# payload and the matcher's verdict is compared to the expectation. Every
# target path is deliberately non-existent.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/../../lib"
CORPUS="$DIR/corpus/aegis-self-modification.txt"
AEGIS_ROOT="$(cd "$DIR/../.." && pwd)"

unset AEGIS_ASK_MODE AEGIS_DEFER_SCOPE AEGIS_HARD_DENY_ACTION

for f in "$LIB/bash-hard-ask.sh" "$LIB/protected-paths.sh" "$CORPUS"; do
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

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ] || { printf '  %s\n' "${FAILS[@]}" >&2; exit 1; }
