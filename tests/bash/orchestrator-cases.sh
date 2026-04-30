#!/usr/bin/env bash
# End-to-end orchestrator tests. Pipes various PreToolUse JSON shapes through
# orchestrator.sh and asserts the layer dispatch is correct.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$DIR/../../orchestrator.sh"

PASS=0; FAIL=0
FAILS=()

assert() {
  local name="$1" input="$2" want_decision="$3" want_exit="$4"
  local out rc
  out=$(echo "$input" | "$ORCH" 2>/dev/null)
  rc=$?
  local got_decision="silent"
  if [ "$rc" = 2 ]; then got_decision="deny"
  elif echo "$out" | grep -q '"permissionDecision":"allow"'; then got_decision="allow"
  elif echo "$out" | grep -q '"permissionDecision":"ask"'; then got_decision="ask"
  fi
  if [ "$got_decision" = "$want_decision" ] && [ "$rc" = "$want_exit" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILS+=("$name: want=$want_decision/$want_exit got=$got_decision/$rc")
  fi
}

# Read-only tools always allow without classifier.
assert "Read tool"  '{"tool_name":"Read","tool_input":{"file_path":"/x"}}'  allow 0
assert "Glob tool"  '{"tool_name":"Glob","tool_input":{"pattern":"*.py"}}'  allow 0
assert "Grep tool"  '{"tool_name":"Grep","tool_input":{"pattern":"foo"}}'   allow 0
assert "TodoWrite"  '{"tool_name":"TodoWrite","tool_input":{}}'              allow 0

# Bash safe command: gatekeeper allow.
assert "ls"           '{"tool_name":"Bash","tool_input":{"command":"ls"}}'           allow 0
assert "git status"   '{"tool_name":"Bash","tool_input":{"command":"git status"}}'   allow 0

# Bash hard-deny: rm -rf /
assert "rm -rf /"     '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'     deny  2

# Bash hard-ask: git push --force
assert "git push -f"  '{"tool_name":"Bash","tool_input":{"command":"git push --force"}}' ask 0

# Edit on protected path.
assert "Edit /etc"    '{"tool_name":"Edit","tool_input":{"file_path":"/etc/passwd"}}' ask 0

# Bash unrecognized: falls to classifier (we use AEGIS_TEST_MOCK_DECISION env to short-circuit).
assert "novel cmd"    '{"tool_name":"Bash","tool_input":{"command":"foobar quux"}}'   ask 0   # classifier mock returns ask in test mode

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ] || { printf '  %s\n' "${FAILS[@]}" >&2; exit 1; }
