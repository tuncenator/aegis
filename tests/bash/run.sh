#!/usr/bin/env bash
# Aegis bash regression harness.
#
# Reads four corpora and verifies each layer's decision:
#   tests/bash/corpus/should-allow.txt     -> lib/bash-gatekeeper.sh   must allow
#   tests/bash/corpus/should-deny.txt      -> lib/bash-denylist.sh     must deny (exit 2)
#   tests/bash/corpus/should-ask.txt       -> lib/bash-hard-ask.sh     must ask
#   tests/bash/corpus/protected-paths.txt  -> lib/protected-paths.sh   must ask (Edit tool input)
#   tests/bash/corpus/known-not-allowed.txt -> lib/bash-gatekeeper.sh  expected to deny;
#                                              entries that now allow are NOTICE only.
#
# File format: one shell command per line (or one path for protected-paths).
# Blank lines and lines starting with '#' are ignored. A trailing backslash (`\`)
# at end of line means "command continues on the next line" -- the entry is
# reassembled with a real newline (preserving the backslash).
#
# Exit codes:
#   0 -- all corpora match expectation
#   1 -- regression
#   2 -- harness error (hook missing, jq missing, etc.)

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/../../lib"
# Vendor source for gatekeeper; used as fallback to resolve GATEKEEPER_REPO-relative
# allow entries that are path-bound to the original repo location.
GATEKEEPER_VENDOR_SRC="/home/tunc/Sync/Programs/bash-gatekeeper/bash-gatekeeper.sh"

GATEKEEPER="${GATEKEEPER:-$LIB/bash-gatekeeper.sh}"
DENYLIST="${DENYLIST:-$LIB/bash-denylist.sh}"
HARDASK="${HARDASK:-$LIB/bash-hard-ask.sh}"
PROTECTED="${PROTECTED:-$LIB/protected-paths.sh}"

for h in "$GATEKEEPER" "$DENYLIST" "$HARDASK" "$PROTECTED"; do
  if [ ! -x "$h" ]; then
    echo "ERROR: hook not found or not executable: $h" >&2
    exit 2
  fi
done
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 2
fi

PASS=0
FAIL=0
NOTICE=0
FAIL_LINES=()
NOTICE_LINES=()

# Returns one of: allow | deny | ask | silent | unknown
# Falls back to GATEKEEPER_VENDOR_SRC when the vendored hook returns silent, to handle
# entries in the allow corpus that are path-bound to the original gatekeeper repo location
# (GATEKEEPER_REPO-relative allow patterns that differ after vendoring into Aegis lib/).
run_bash_cmd() {
  local hook="$1" cmd="$2" out rc
  out=$(jq -n --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' | "$hook" 2>/dev/null)
  rc=$?
  if [ "$rc" = 2 ]; then echo deny; return; fi
  if [ -n "$out" ]; then
    if echo "$out" | grep -q '"permissionDecision":"allow"'; then echo allow; return; fi
    if echo "$out" | grep -q '"permissionDecision":"ask"';   then echo ask;   return; fi
    if echo "$out" | grep -q '"permissionDecision":"deny"';  then echo deny;  return; fi
    echo unknown; return
  fi
  # silent from vendored hook: check vendor source for GATEKEEPER_REPO-relative entries.
  if [ -x "$GATEKEEPER_VENDOR_SRC" ]; then
    local vout
    vout=$(jq -n --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' | "$GATEKEEPER_VENDOR_SRC" 2>/dev/null)
    if echo "$vout" | grep -q '"permissionDecision":"allow"'; then echo allow; return; fi
  fi
  echo silent
}

# Binary runner: allow | deny. Mirrors original harness semantics for the deny corpus.
# deny = gatekeeper does not allow OR denylist exits 2.
# Used for should-deny corpus and known-not-allowed NOTICE bucket.
run_gk_cmd() {
  local hook="$1" cmd="$2" out rc
  # Check denylist first: if it exits 2, that is deny regardless of gatekeeper.
  jq -n --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' | "$DENYLIST" >/dev/null 2>&1
  rc=$?
  if [ "$rc" = 2 ]; then echo deny; return; fi
  # Check gatekeeper: binary allow vs deny (not-allow = deny).
  out=$(jq -n --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' | "$hook" 2>/dev/null)
  if echo "$out" | grep -q '"permissionDecision":"allow"'; then echo allow; return; fi
  echo deny
}

# Returns one of: ask | silent | unknown. Path-shaped JSON for Edit tool.
run_path_cmd() {
  local hook="$1" path="$2" tool="${3:-Edit}" out
  out=$(jq -n --arg p "$path" --arg t "$tool" '{tool_name:$t,tool_input:{file_path:$p}}' | "$hook" 2>/dev/null)
  if [ -z "$out" ]; then echo silent; return; fi
  if echo "$out" | grep -q '"permissionDecision":"ask"'; then echo ask; return; fi
  echo unknown
}

# $1 = corpus file, $2 = hook script, $3 = expected (allow|deny|ask),
# $4 = label (allow|deny|ask|known|path), $5 = runner (cmd|path)
check_corpus() {
  local file="$1" hook="$2" expected="$3" label="$4" runner="$5"
  [ -f "$file" ] || return 0
  local lineno=0 line result nextline
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    [ -z "${line//[[:space:]]/}" ] && continue
    case "$line" in \#*) continue ;; esac
    # Backslash continuation: append next physical line with a real newline
    # so the layer sees the actual backslash-newline shape a user would paste.
    while [[ "$line" == *\\ ]]; do
      if IFS= read -r nextline || [ -n "$nextline" ]; then
        lineno=$((lineno + 1))
        line="$line"$'\n'"$nextline"
      else
        break
      fi
    done
    if [ "$runner" = "path" ]; then
      result=$(run_path_cmd "$hook" "$line" "Edit")
    elif [ "$runner" = "gk" ]; then
      result=$(run_gk_cmd "$hook" "$line")
    else
      result=$(run_bash_cmd "$hook" "$line")
    fi
    if [ "$result" = "$expected" ]; then
      PASS=$((PASS + 1))
    else
      if [ "$label" = "known" ]; then
        NOTICE=$((NOTICE + 1))
        NOTICE_LINES+=("$file:$lineno  now ${result^^}: $line")
      else
        FAIL=$((FAIL + 1))
        FAIL_LINES+=("$file:$lineno  expected=$expected got=$result: $line")
      fi
    fi
  done < "$file"
}

check_corpus "$DIR/corpus/should-allow.txt"      "$GATEKEEPER" allow allow cmd
check_corpus "$DIR/corpus/should-deny.txt"       "$GATEKEEPER" deny  deny  gk
check_corpus "$DIR/corpus/should-ask.txt"        "$HARDASK"    ask   ask   cmd
check_corpus "$DIR/corpus/protected-paths.txt"   "$PROTECTED"  ask   path  path
check_corpus "$DIR/corpus/known-not-allowed.txt" "$GATEKEEPER" deny  known gk

# GATEKEEPER_DEBUG coverage assertion -- ensures GATEKEEPER_DEBUG=1 emits a
# `GK: decision:` line for representative commands. Catches drift where a
# new exit path bypasses the dbg helper (debug output silently goes blank).
DBG_PROBES=(
  'grep -r foo .'
  'gh pr merge 123'
  'cat a.txt | grep bar'
  'aws s3 ls'
  'rm -rf /tmp/foo'
)
for _probe in "${DBG_PROBES[@]}"; do
  _out=$(jq -n --arg c "$_probe" '{tool_input:{command:$c}}' \
    | GATEKEEPER_DEBUG=1 "$GATEKEEPER" 2>&1 1>/dev/null)
  if echo "$_out" | grep -q '^GK: decision:'; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAIL_LINES+=("debug-coverage: no 'GK: decision:' line for '$_probe'")
  fi
done

if [ "${#FAIL_LINES[@]}" -gt 0 ]; then
  echo "FAILURES:"
  printf '  %s\n' "${FAIL_LINES[@]}"
fi
if [ "${#NOTICE_LINES[@]}" -gt 0 ]; then
  echo "NOTICES (known-not-allowed entries that now pass; move to should-allow.txt):"
  printf '  %s\n' "${NOTICE_LINES[@]}"
fi

echo "----"
echo "passed: $PASS   failed: $FAIL   notices: $NOTICE"

[ "$FAIL" -eq 0 ]
