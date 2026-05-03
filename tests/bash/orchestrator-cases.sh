#!/usr/bin/env bash
# End-to-end orchestrator tests. Pipes various PreToolUse JSON shapes through
# orchestrator.sh and asserts the layer dispatch is correct.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$DIR/../../orchestrator.sh"

PASS=0; FAIL=0
FAILS=()

# want_decision is a pipe-separated list of acceptable decisions, e.g. "ask" or "allow|deny|ask".
# want_exit is a pipe-separated list of acceptable exit codes, e.g. "0" or "0|2".
assert() {
  local name="$1" input="$2" want_decision="$3" want_exit="$4"
  local out rc
  out=$(echo "$input" | "$ORCH" 2>/dev/null)
  rc=$?
  local got_decision="silent"
  if [ "$rc" = 2 ]; then got_decision="deny"
  elif echo "$out" | grep -qE '"permissionDecision"[[:space:]]*:[[:space:]]*"allow"'; then got_decision="allow"
  elif echo "$out" | grep -qE '"permissionDecision"[[:space:]]*:[[:space:]]*"ask"'; then got_decision="ask"
  elif echo "$out" | grep -qE '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then got_decision="deny"
  fi
  local d_ok=0 e_ok=0
  case "|$want_decision|" in *"|$got_decision|"*) d_ok=1 ;; esac
  case "|$want_exit|" in *"|$rc|"*) e_ok=1 ;; esac
  if [ "$d_ok" = 1 ] && [ "$e_ok" = 1 ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILS+=("$name: want=$want_decision/$want_exit got=$got_decision/$rc")
  fi
}

# Read-only / harmless tools always allow without classifier.
assert "Read tool"  '{"tool_name":"Read","tool_input":{"file_path":"/x"}}'  allow 0
assert "Glob tool"  '{"tool_name":"Glob","tool_input":{"pattern":"*.py"}}'  allow 0
assert "Grep tool"  '{"tool_name":"Grep","tool_input":{"pattern":"foo"}}'   allow 0
assert "TodoWrite"  '{"tool_name":"TodoWrite","tool_input":{}}'              allow 0
assert "Agent tool" '{"tool_name":"Agent","tool_input":{"description":"x","prompt":"y"}}' allow 0
assert "Task tool"  '{"tool_name":"Task","tool_input":{"description":"x","prompt":"y"}}'  allow 0
assert "WebFetch"   '{"tool_name":"WebFetch","tool_input":{"url":"https://example.com"}}'  allow 0
assert "WebSearch"  '{"tool_name":"WebSearch","tool_input":{"query":"foo"}}'              allow 0

# Bash safe command: gatekeeper allow.
assert "ls"           '{"tool_name":"Bash","tool_input":{"command":"ls"}}'           allow 0
assert "git status"   '{"tool_name":"Bash","tool_input":{"command":"git status"}}'   allow 0

# Bash hard-deny: rm -rf /
assert "rm -rf /"     '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'     deny  2

# Bash hard-ask: git push --force
assert "git push -f"  '{"tool_name":"Bash","tool_input":{"command":"git push --force"}}' ask 0

# Edit on protected path.
assert "Edit /etc"    '{"tool_name":"Edit","tool_input":{"file_path":"/etc/passwd"}}' ask 0

# Bash unrecognized: falls to classifier. With AEGIS_TEST_MOCK_DECISION=ask the harness
# sees "ask"; unmocked, the real classifier may return any of allow|deny|ask depending on
# what the model thinks of "foobar quux", so we accept all three when running live.
# session_id is unique-per-run to avoid persistent state (auto-pause from prior denies)
# silently neutering this case into a fall-through.
NOVEL_SESS="orch-test-novel-$$-$RANDOM"
assert "novel cmd" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"foobar quux\"},\"session_id\":\"$NOVEL_SESS\"}" \
  "allow|deny|ask" "0|2"
rm -f "$HOME/.cache/aegis/sessions/$NOVEL_SESS.json" 2>/dev/null || true

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ] || { printf '  %s\n' "${FAILS[@]}" >&2; exit 1; }
