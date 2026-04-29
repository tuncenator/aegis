# Phase 3: Orchestrator + Python Skeleton

**Feature**: project-initiation
**Estimated Context Budget**: ~60k tokens

**Difficulty**: medium
**Visual**: no
**Functional**: yes

**Execution Mode**: sequential
**Batch**: 3

---

## Objective

Build the single PreToolUse hook entry (`orchestrator.sh`) that dispatches by `tool_name` through the layered decision pipelines authored in Phases 1-2 (bash-denylist, bash-hard-ask, bash-gatekeeper, protected-paths) and finally to the Python classifier. Land an end-to-end orchestrator test harness that uses an `AEGIS_TEST_MOCK_DECISION` env var to short-circuit the classifier subprocess. Land a placeholder Python classifier package whose `__main__` returns `{"permissionDecision":"ask"}` so orchestrator tests run end-to-end before Phase 7 ships the real classifier.

This phase wires the entire dispatch surface that Phases 4-7 hang their internals off. After this phase, the project has a working PreToolUse hook surface; later phases only enrich the classifier's decision-making.

---

## Deliverables

1. `orchestrator.sh` -- PreToolUse hook entry. Single dispatch by `tool_name` across read-only fast path, Bash pipeline, Edit/Write/NotebookEdit pipeline, fall-through-to-classifier for everything else. Includes a `mock_classifier` shell function honoring `AEGIS_TEST_MOCK_DECISION`. Made executable (`chmod +x`).
2. `tests/bash/orchestrator-cases.sh` -- End-to-end orchestrator harness. Pipes 10 PreToolUse JSON shapes through `orchestrator.sh` and asserts decision + exit code for each. Made executable (`chmod +x`).
3. `classifier/__init__.py` -- Module docstring only; marks the package.
4. `classifier/__main__.py` -- Placeholder entrypoint. Reads stdin, writes `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask"}}` to stdout, returns exit 0. Phase 7 replaces this entirely.
5. `tests/python/conftest.py` -- Adds the project root to `sys.path` so `from classifier import ...` works from pytest.

---

## Detailed Requirements

### File 1: `orchestrator.sh` (project root)

Create `/home/tunc/Sync/Programs/aegis/orchestrator.sh` with the verbatim content below. Lines are commented inline with what each block does; the body matches plan Task 6 Step 2 with one correction: the trailing `python3 -m aegis_classifier` invocation in the plan is wrong (legacy artifact from an earlier draft); the correct module name is `classifier`. All three classifier invocations in this file MUST use `python3 -m classifier`.

```bash
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
CLASSIFIER="$DIR/classifier"

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
  echo "$INPUT" | exec env PYTHONPATH="$DIR" python3 -m classifier
fi

# Edit / Write / NotebookEdit: protected-paths first, then classifier.
case "$TOOL" in
  Edit|Write|NotebookEdit)
    out=$(echo "$INPUT" | "$LIB/protected-paths.sh")
    if [ -n "$out" ]; then echo "$out"; exit 0; fi
    mock_classifier && exit 0
    echo "$INPUT" | exec env PYTHONPATH="$DIR" python3 -m classifier
    ;;
esac

# All other tools (WebFetch, WebSearch, Agent, MCP tools, etc.): straight to classifier.
mock_classifier && exit 0
echo "$INPUT" | exec env PYTHONPATH="$DIR" python3 -m classifier
```

After writing, run:

```bash
chmod +x /home/tunc/Sync/Programs/aegis/orchestrator.sh
```

#### Dispatch logic explanation (read this so you understand WHY the structure is shaped like this)

- `set -u` only -- never `set -e`. Layer scripts deliberately exit 0 with empty stdout on no-match (silent fall-through). `set -e` would crash the orchestrator on the first such "fall-through" (which is non-failure).
- `INPUT=$(cat)` reads stdin once at the top so it can be re-fed to multiple layer scripts via `echo "$INPUT" | ...`. Stdin can only be read once otherwise.
- Tool name extraction uses `jq -r '.tool_name // empty'`. Never grep/sed JSON.
- The read-only tool list is a `case` with the explicit names: `Read|Glob|Grep|TodoWrite|TaskCreate|TaskUpdate|TaskList|TaskGet|TaskOutput|TaskStop`. These are the harmless surfaces from the design spec. `emit_allow` exits 0 inside the case body, so the script never reaches the Bash dispatch below.
- Bash pipeline (Layer 1, denylist):
  - `echo "$INPUT" | "$LIB/bash-denylist.sh"` (NOT capturing stdout, since denylist's contract is "empty stdout, exit 2 on match"). `rc=$?` captures the exit code. If `rc=2`, propagate via `exit 2` (this is the hard-deny propagation). Otherwise fall through to Layer 2.
  - Important: denylist's stdout is empty either way, so we do NOT use `out=$(...)` here; we want stderr (its diagnostic output) to flow to the user.
- Bash pipeline (Layer 2, hard-ask) and (Layer 3, gatekeeper):
  - Both layers' contract is "stdout = decision JSON if matched, empty if no match; exit code always 0".
  - Pattern: `out=$(echo "$INPUT" | "$LIB/<layer>.sh"); if [ -n "$out" ]; then echo "$out"; exit 0; fi`. Non-empty stdout means matched -- emit it to our stdout and exit 0. Empty means fall through.
- Bash pipeline (Layer 4, classifier):
  - First `mock_classifier && exit 0` -- if `AEGIS_TEST_MOCK_DECISION` is set, the function emits a hardcoded decision and exits inside itself (so the outer `&& exit 0` is belt-and-suspenders).
  - Otherwise `echo "$INPUT" | exec env PYTHONPATH="$DIR" python3 -m classifier`. The `exec` replaces this shell process with the Python process so we don't pay the cost of an extra fork. `PYTHONPATH="$DIR"` ensures `from classifier import ...` resolves to our package at the project root.
- Edit/Write/NotebookEdit pipeline:
  - Layer 1: protected-paths.sh emits ASK JSON if matched, empty if not. Same `out=$(...)` pattern as hard-ask/gatekeeper.
  - Layer 2: classifier (mock-or-real, same pattern).
- Catch-all at the bottom: WebFetch, WebSearch, Agent, MCP tools etc. -- straight to classifier. The `case "$TOOL" in Edit|Write|NotebookEdit) ...; ;; esac` block exits inside its own body for those tools, so the trailing `mock_classifier && exit 0; echo "$INPUT" | exec env PYTHONPATH="$DIR" python3 -m classifier` only fires for tools NOT matched above.

#### Why the trailing classifier invocation differs from plan Task 6 Step 2

Plan Task 6 Step 2 ends with `echo "$INPUT" | exec python3 -m aegis_classifier`. Two errors there:
1. Module name: it's `classifier`, not `aegis_classifier`. The package directory the brief says we create is `classifier/`. Use `python3 -m classifier`.
2. Missing `env PYTHONPATH="$DIR"`. Without `PYTHONPATH` set to the project root, Python won't find the `classifier` package unless cwd happens to be the project root. We set `PYTHONPATH="$DIR"` explicitly to match the earlier two classifier invocations.

The corrected catch-all block is:

```bash
mock_classifier && exit 0
echo "$INPUT" | exec env PYTHONPATH="$DIR" python3 -m classifier
```

All three classifier invocations in the file are identical: `mock_classifier && exit 0; echo "$INPUT" | exec env PYTHONPATH="$DIR" python3 -m classifier`.

### File 2: `tests/bash/orchestrator-cases.sh`

Create `/home/tunc/Sync/Programs/aegis/tests/bash/orchestrator-cases.sh` with the verbatim content below (matches plan Task 6 Step 1).

```bash
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
```

After writing, run:

```bash
chmod +x /home/tunc/Sync/Programs/aegis/tests/bash/orchestrator-cases.sh
```

#### Test case count and rationale

10 assertions. The brief lists 10 cases; the plan content above contains those exact 10. Counting from top to bottom:

| # | Name | Input tool | Expected decision | Expected exit | Layer that fires |
|---|------|-----------|-------------------|---------------|------------------|
| 1 | Read tool | Read | allow | 0 | read-only fast path |
| 2 | Glob tool | Glob | allow | 0 | read-only fast path |
| 3 | Grep tool | Grep | allow | 0 | read-only fast path |
| 4 | TodoWrite | TodoWrite | allow | 0 | read-only fast path |
| 5 | ls | Bash | allow | 0 | bash-gatekeeper (Layer 3) |
| 6 | git status | Bash | allow | 0 | bash-gatekeeper (Layer 3) |
| 7 | rm -rf / | Bash | deny | 2 | bash-denylist (Layer 1) |
| 8 | git push -f | Bash | ask | 0 | bash-hard-ask (Layer 2) |
| 9 | Edit /etc | Edit | ask | 0 | protected-paths |
| 10 | novel cmd | Bash | ask | 0 | classifier (mocked or placeholder) |

Test 10 is the one that depends on `AEGIS_TEST_MOCK_DECISION=ask` (or on Phase 3's placeholder classifier returning `ask`). Either path returns the same answer, so the test is meaningful regardless of whether the env var is set. The strategy doc and brief explicitly call out this dual-mode design.

#### Why this harness is a separate file (not part of `tests/bash/run.sh`)

`tests/bash/run.sh` (built in Phase 2) is corpus-driven: it reads `tests/bash/corpus/*.txt` and dispatches each line to a single layer script. The orchestrator test harness exercises the orchestrator's dispatch logic across multiple tool types and across the full pipeline (denylist into hard-ask into gatekeeper into classifier). Conceptually different. Different file, different invocation.

### File 3: `classifier/__init__.py`

Create `/home/tunc/Sync/Programs/aegis/classifier/__init__.py` with this exact content:

```python
"""Aegis classifier package -- slow path for permission decisions."""
```

That is the entire file. One line. Module docstring only. Marks `classifier/` as a Python package.

Use straight ASCII (`--`, not the unicode em dash). The user's global rules forbid unicode in source files.

### File 4: `classifier/__main__.py` (placeholder)

Create `/home/tunc/Sync/Programs/aegis/classifier/__main__.py` with this exact content:

```python
"""Aegis classifier entrypoint.

Reads PreToolUse JSON on stdin, writes Claude Code permission decision JSON on stdout.
This is a placeholder -- full implementation in Phase 7.
"""
import json
import sys


def main() -> int:
    sys.stdin.read()
    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "ask",
        }
    }
    json.dump(out, sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

Notes:
- `sys.stdin.read()` consumes stdin (we don't parse it; placeholder ignores content). This is intentional -- when called from the orchestrator with `echo "$INPUT" | python3 -m classifier`, the orchestrator's stdin write must be drained or the producer-side `echo` would SIGPIPE.
- `json.dump` writes the dict to stdout. No trailing newline -- Claude Code's hook output spec doesn't require one and matching the plan's output exactly avoids surprise.
- `return 0` from `main()`, then `raise SystemExit(main())` in the module's `if __name__ == "__main__"` guard. This is the canonical Python entrypoint pattern.
- Module docstring uses `--` (ASCII double hyphen), not the unicode em dash.

Phase 7 replaces this file entirely with the full chain orchestration. Do not over-engineer the placeholder; minimal is correct.

### File 5: `tests/python/conftest.py`

Create `/home/tunc/Sync/Programs/aegis/tests/python/conftest.py` with this exact content:

```python
"""Pytest config -- ensures classifier package is importable."""
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT))
```

`Path(__file__).resolve().parent.parent.parent` walks: `tests/python/conftest.py` -> `tests/python/` -> `tests/` -> `<repo root>`. Verify by `pwd` of `<repo root>` resolving to `/home/tunc/Sync/Programs/aegis`.

### Step-by-step implementation order

Execute in this exact order. Each step's verification gate must pass before the next step.

1. Create `tests/bash/orchestrator-cases.sh` (the test) FIRST, before `orchestrator.sh`. Run it -- it should fail with "orchestrator.sh missing" or similar. This confirms the failing-test step (TDD cadence per the project's discipline).
2. Create `orchestrator.sh`. `chmod +x` both the test and the orchestrator.
3. Run `AEGIS_TEST_MOCK_DECISION=ask /home/tunc/Sync/Programs/aegis/tests/bash/orchestrator-cases.sh`. Expect `PASS=10 FAIL=0`. This works without a classifier package because the test sets `AEGIS_TEST_MOCK_DECISION=ask`, which short-circuits the classifier subprocess inside `mock_classifier`.
4. Run the full bash suite as a regression: `cd /home/tunc/Sync/Programs/aegis && tests/bash/run.sh && AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh`. Both must pass.
5. Create `classifier/__init__.py`.
6. Create `classifier/__main__.py` (placeholder).
7. Create `tests/python/conftest.py`.
8. Verify pytest discovery: `cd /home/tunc/Sync/Programs/aegis && python3 -m pytest tests/python/ -v` (or `uv run python -m pytest tests/python/ -v` if uv is preferred). Expect "no tests ran" or "no tests collected", with no errors. Phase 4+ adds real tests.
9. Smoke the placeholder classifier directly: `echo '{"tool_name":"WebFetch","tool_input":{"url":"https://x"}}' | env PYTHONPATH=/home/tunc/Sync/Programs/aegis python3 -m classifier`. Expect `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask"}}` on stdout.
10. Re-run orchestrator tests WITHOUT the env var: `cd /home/tunc/Sync/Programs/aegis && unset AEGIS_TEST_MOCK_DECISION; tests/bash/orchestrator-cases.sh`. Expect `PASS=10 FAIL=0`. Test 10 ("novel cmd") expects ASK; the placeholder returns ASK; both modes converge on the same outcome. This test exercises the real classifier subprocess path (without burning gemini tokens) end-to-end.

### Edge cases to handle (explicitly)

- **Tool name missing/empty**: `TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')` returns the empty string when the JSON has no `tool_name` field or `tool_name` is null. The empty string does NOT match any case branch above, so the script falls to the catch-all classifier invocation. This is correct: any unknown tool gets the LLM treatment.
- **Malformed JSON on stdin**: `jq -r` will print a parse error to stderr and return empty. Per above, empty `TOOL` falls to the catch-all (mock or classifier). The classifier itself reads stdin and returns a generic ask. The orchestrator never crashes on malformed input.
- **Layer script missing**: `echo "$INPUT" | "$LIB/bash-denylist.sh"` would fail with "no such file" if the file isn't present. Phase 1 vendors `bash-denylist.sh` and `bash-gatekeeper.sh`; Phase 2 adds `bash-hard-ask.sh` and `protected-paths.sh`. All four MUST exist before the orchestrator can pass its tests. If any are missing, halt and report; do not patch around it.
- **Classifier subprocess failure**: under the placeholder this can't happen; under the real classifier (Phase 7) failures fall back per `cfg.on_exhaustion`. Phase 3 doesn't need to handle this.
- **`AEGIS_TEST_MOCK_DECISION` set to something other than allow/deny/ask**: the `case` statement's catch-all `*) return 1 ;;` falls through (the function returns nonzero). The outer `mock_classifier && exit 0` then evaluates false; control falls to the real classifier invocation. Setting the env var to e.g. "yes" effectively unsets it.
- **Read-only tool with extra unexpected fields in `tool_input`**: orchestrator never inspects `tool_input` for read-only tools. It dispatches purely on `tool_name`. So `Read` with any `tool_input` shape returns ALLOW.
- **Bash tool with no `command` field**: orchestrator passes the JSON to `bash-denylist.sh` etc. Each layer script handles its own input parsing. If the command field is missing, layers will silently fall through, ending in the classifier (or the placeholder/mock).
- **Edit/Write/NotebookEdit with no `file_path` field**: same. `protected-paths.sh` falls through; classifier handles it.
- **Layer script emits stdout AND exits 2**: The orchestrator's denylist invocation doesn't capture stdout (it's not in `out=$(...)`). Stdout emitted by denylist would go to terminal stdout. But denylist's contract is "empty stdout on match; exit 2 on match". If a future denylist accidentally emitted stdout on a match, it would leak through. Phase 3 trusts the contract -- do not defend against future contract violations here.

### Integration points with other phases

- Consumes Phase 1's `lib/bash-denylist.sh`, `lib/bash-gatekeeper.sh`. Wire format documented under "External Interfaces Consumed" below.
- Consumes Phase 2's `lib/bash-hard-ask.sh`, `lib/protected-paths.sh`, `tests/bash/run.sh`. Wire format documented under "External Interfaces Consumed" below.
- Phase 4-6 don't touch `orchestrator.sh` or any Phase 3 file (they build classifier internals).
- Phase 7 modifies `orchestrator.sh` (adds `diag_emit` shell helper) and replaces `classifier/__main__.py` entirely. Phase 3 must not assume `__main__.py` will remain a placeholder forever; design accordingly (the placeholder is genuinely throwaway).
- Phase 8's CLI (`bin/aegis`) imports `classifier.state` directly. The `tests/python/conftest.py` from this phase ensures pytest can resolve those imports.
- Phase 9's installer copies the entire project tree, including `orchestrator.sh`, into `~/.claude/plugins/aegis/`.

---

## Dependencies

**Requires**:
- Phase 1: `lib/bash-denylist.sh` (vendored), `lib/bash-gatekeeper.sh` (vendored), `pyproject.toml` (provides pytest config so `python3 -m pytest tests/python/` resolves), `.gitignore` (for `__pycache__/`), `classifier/log.py` (logging is set up but Phase 3 doesn't import it -- placeholder is intentionally minimal).
- Phase 2: `lib/bash-hard-ask.sh`, `lib/protected-paths.sh`, `tests/bash/run.sh` (used as a regression gate after Phase 3 lands), corpora files (used by `run.sh`).

**Enables**:
- Phase 4: `tests/python/conftest.py` makes the classifier package importable from pytest -- Phase 4's `test_state.py` and `test_rules.py` rely on `from classifier import state, rules`.
- Phase 5: same as Phase 4. Plus the `__main__.py` placeholder being in place lets Phase 5's downstream tests run end-to-end.
- Phase 6: same.
- Phase 7: replaces `classifier/__main__.py` and modifies `orchestrator.sh`. Phase 7 needs the file structure Phase 3 created.

---

## Completion Criteria

- [ ] `orchestrator.sh` created at the project root, executable.
- [ ] `tests/bash/orchestrator-cases.sh` created, executable.
- [ ] `classifier/__init__.py` created with module docstring.
- [ ] `classifier/__main__.py` placeholder created.
- [ ] `tests/python/conftest.py` created.
- [ ] `AEGIS_TEST_MOCK_DECISION=ask /home/tunc/Sync/Programs/aegis/tests/bash/orchestrator-cases.sh` reports `PASS=10 FAIL=0`.
- [ ] `unset AEGIS_TEST_MOCK_DECISION; /home/tunc/Sync/Programs/aegis/tests/bash/orchestrator-cases.sh` reports `PASS=10 FAIL=0` (verifies placeholder integration).
- [ ] `cd /home/tunc/Sync/Programs/aegis && tests/bash/run.sh` reports a pass for all corpora (regression check from Phase 2).
- [ ] `cd /home/tunc/Sync/Programs/aegis && python3 -m pytest tests/python/ -v` runs without errors (no tests yet to fail or pass).
- [ ] `echo '{"tool_name":"WebFetch","tool_input":{"url":"https://x"}}' | env PYTHONPATH=/home/tunc/Sync/Programs/aegis python3 -m classifier` outputs `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask"}}`.
- [ ] All Functional QA checks below have been executed and their outputs captured into the phase summary.
- [ ] Phase summary saved at `docs/agent/project-initiation/summaries/PHASE_03_SUMMARY.md`.
- [ ] STATUS.md updated.

---

## Testing Requirements

### Bash test (the primary verification)

`/home/tunc/Sync/Programs/aegis/tests/bash/orchestrator-cases.sh` is the harness this phase ships and must pass.

Mandatory invocations:

```bash
# With mock decision (used during normal CI -- avoids any classifier path).
AEGIS_TEST_MOCK_DECISION=ask /home/tunc/Sync/Programs/aegis/tests/bash/orchestrator-cases.sh

# Without mock (verifies the placeholder __main__ wires correctly).
unset AEGIS_TEST_MOCK_DECISION
/home/tunc/Sync/Programs/aegis/tests/bash/orchestrator-cases.sh
```

Both must report `PASS=10 FAIL=0`.

### Bash regression

Phase 2's full corpus harness must still pass after Phase 3 lands (Phase 3 doesn't modify any Phase 1/2 file, but verify):

```bash
cd /home/tunc/Sync/Programs/aegis && tests/bash/run.sh
```

### Python pytest discovery smoke

```bash
cd /home/tunc/Sync/Programs/aegis && python3 -m pytest tests/python/ -v
```

Expect "no tests collected" or "no tests ran" with exit 0. Phase 4 adds real tests.

### Direct classifier placeholder smoke

```bash
echo '{"tool_name":"WebFetch","tool_input":{"url":"https://x"}}' | env PYTHONPATH=/home/tunc/Sync/Programs/aegis python3 -m classifier
```

Expected stdout (exact match):
```json
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask"}}
```

(Note: `json.dump` produces `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask"}}` -- whitespace after each colon, no trailing newline, no fence. Match this exactly.)

---

## Functional QA

This phase ships Surface 1 (`orchestrator.sh`, the PreToolUse hook) and Surface 3 (`python3 -m classifier`, the placeholder slow path). Each check below names a real surface invocation and a concrete observable outcome. Run each check, capture stdout, stderr, exit code, and paste into the phase summary's "Functional QA Results" section.

- [ ] **(Surface 1, Loop 1) Routine command, fast path via gatekeeper.** Run `echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | /home/tunc/Sync/Programs/aegis/orchestrator.sh`. Stdout MUST equal `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}`. Exit code MUST be 0. The orchestrator should hit Layer 3 (gatekeeper) -- no Python startup, no subprocess to gemini. To confirm zero Python startup: time the call (`time echo '...' | ./orchestrator.sh`) and observe wall-clock < 50ms on a warm host.

- [ ] **(Surface 1, Loop 2) Catastrophic command, hard-deny.** Run `echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | /home/tunc/Sync/Programs/aegis/orchestrator.sh`. Stdout MUST be empty. Exit code MUST be 2. Stderr SHOULD contain a diagnostic message from `bash-denylist.sh` (Phase 1's vendored script emits one). The hard-deny path is the only way the orchestrator emits exit 2; no other layer does.

- [ ] **(Surface 1, Loop 3) Risky command, hard-ask.** Run `echo '{"tool_name":"Bash","tool_input":{"command":"git push --force"}}' | /home/tunc/Sync/Programs/aegis/orchestrator.sh`. Stdout MUST contain `"permissionDecision":"ask"` AND `"permissionDecisionReason"` matching the reason `lib/bash-hard-ask.sh` emits for force-push (Phase 2 spec: "git push with force flag" or similar). Exit code MUST be 0. Classifier MUST NOT have been called -- verify by ensuring no Python process appeared in `ps` mid-call (or by adding `set -x` temporarily and observing the dispatch log; remove before commit).

- [ ] **(Surface 1, Loop 5) Protected-path edit.** Run `echo '{"tool_name":"Edit","tool_input":{"file_path":"/etc/passwd"}}' | /home/tunc/Sync/Programs/aegis/orchestrator.sh`. Stdout MUST contain `"permissionDecision":"ask"` AND `"permissionDecisionReason"` referencing `/etc` (Phase 2's `protected-paths.sh` is the source of the reason text). Exit code MUST be 0. Classifier MUST NOT have been called.

- [ ] **(Surface 1, Loop 6) Read-only fast path.** Run `echo '{"tool_name":"Read","tool_input":{"file_path":"/x"}}' | /home/tunc/Sync/Programs/aegis/orchestrator.sh`. Stdout MUST equal `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}`. Exit code MUST be 0. The script MUST NOT invoke any layer script -- verify by `set -x` instrumentation OR by a temporary `echo "DEBUG: layer X" >&2` line in each layer (do NOT commit such instrumentation; this is for one-off verification).

- [ ] **(Surface 1, Mechanic 3) Full orchestrator harness.** Run `AEGIS_TEST_MOCK_DECISION=ask /home/tunc/Sync/Programs/aegis/tests/bash/orchestrator-cases.sh`. Stdout MUST end with `PASS=10 FAIL=0`. Exit code MUST be 0. Then re-run with `unset AEGIS_TEST_MOCK_DECISION; /home/tunc/Sync/Programs/aegis/tests/bash/orchestrator-cases.sh` -- same expected output (placeholder classifier returns ASK; test 10 expects ASK; converges).

- [ ] **(Surface 3, Mechanic 5) Placeholder classifier direct invocation.** Run `echo '{"tool_name":"WebFetch","tool_input":{"url":"https://x"}}' | env PYTHONPATH=/home/tunc/Sync/Programs/aegis python3 -m classifier`. Stdout MUST equal `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask"}}` (note `json.dump` whitespace: spaces after colons, no spaces after commas). Exit code MUST be 0. The placeholder is the seam Phase 7 replaces; verifying it here ensures Phase 4-6's downstream pytest setup (which invokes the package via `python3 -m classifier` in a subprocess) won't break.

### Anti-patterns to watch for in this phase

- **AP1 -- importing classifier directly**: tempting to write a Python test that calls `from classifier.__main__ import main; main()`. Don't. Use subprocess invocation: `subprocess.run(["python3", "-m", "classifier"], input=..., env={"PYTHONPATH": "..."}, ...)`. The placeholder is throwaway and Phase 3 doesn't ship Python tests for it; this anti-pattern is more relevant in Phase 7. Note it now so future phases don't slip.
- **AP4 -- asserting only exit code for layer dispatch**: orchestrator-cases.sh's `assert` function correctly checks BOTH the decision (parsed from stdout) AND the exit code. Don't simplify to just one or the other.
- **AP5 -- skipping silent fall-through assertions**: orchestrator-cases.sh's "ls" and "git status" tests verify that those commands reach the gatekeeper (allow), NOT the hard-ask layer (which would be a false ask). The test infrastructure asserts the layer that DID fire by checking exit code/decision combo. If you find yourself adding tests that don't assert which layer fired, stop.
- **AP7 -- `set -e` in the orchestrator**: the orchestrator MUST use `set -u` only. Adding `set -e` would crash the orchestrator the first time a layer script returned non-zero (e.g., grep -q with no match inside a layer). Verify the first line after the shebang reads `set -u`.
- **AP8 -- forgetting to test fall-to-next-layer**: orchestrator-cases.sh's "novel cmd" case tests that an unrecognized Bash command falls through denylist (silent), hard-ask (silent), gatekeeper (silent), and reaches the classifier. If you're tempted to skip this case because the classifier is "just a placeholder", don't -- fall-through dispatch is the orchestrator's most subtle behavior and the test must exercise it.
- **AP9 -- installing the in-progress hook into ~/.claude/**: do NOT register `orchestrator.sh` in `~/.claude/plugins/aegis/` or in your live `~/.claude/settings.json` for "easier testing". A buggy in-progress hook would gate every tool call in every Claude Code session on this machine. Test exclusively via `echo '<fixture>' | ./orchestrator.sh` from the dev tree. Phase 9 handles installation.

---

## Helpers Required

This phase has no mechanical dependencies that helpers cover. No invocations of credential lookup, SSH-to-target-and-run, cross-service calls, log fetching, queue/cache reset, or other known-hard categories. The mechanics here are: write 5 small files, run a bash test harness against local files, run pytest against an empty test dir. All inline, all one-shot.

---

## External Interfaces Consumed

This phase orchestrates the layer scripts authored in Phases 1-2. The orchestrator reads JSON on stdin from Claude Code (input shape) and emits JSON to stdout (decision shape consumed by Claude Code). The layer scripts emit decision JSON that the orchestrator passes through verbatim. Each must be observed against a real instance.

- **`lib/bash-denylist.sh` -- exit code + stderr contract** (Phase 1 vendored)
  - **Consumed by**: `orchestrator.sh` Bash pipeline Layer 1.
  - **Expected shape**: stdout = empty (always). exit code = 0 if no match, 2 if matched. Diagnostic message on stderr if matched.
  - **How to capture**: `echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | /home/tunc/Sync/Programs/aegis/lib/bash-denylist.sh; echo "rc=$?"` -- expect empty stdout, `rc=2`, and stderr text. Then `echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | /home/tunc/Sync/Programs/aegis/lib/bash-denylist.sh; echo "rc=$?"` -- expect empty stdout, `rc=0`, no stderr.
  - **If not observable**: Phase 1 must be complete before this phase runs. If `lib/bash-denylist.sh` is missing, halt and report; do not stub it.

- **`lib/bash-hard-ask.sh` -- decision JSON contract** (Phase 2 authored)
  - **Consumed by**: `orchestrator.sh` Bash pipeline Layer 2.
  - **Expected shape**: stdout = `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"<text>"}}` if matched, else empty. exit code = 0 always.
  - **How to capture**: `echo '{"tool_name":"Bash","tool_input":{"command":"git push --force"}}' | /home/tunc/Sync/Programs/aegis/lib/bash-hard-ask.sh` -- expect ASK JSON with a reason field on stdout. Then `echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | /home/tunc/Sync/Programs/aegis/lib/bash-hard-ask.sh` -- expect empty stdout, exit 0.
  - **If not observable**: Phase 2 must be complete. Halt if missing.

- **`lib/bash-gatekeeper.sh` -- decision JSON contract** (Phase 1 vendored)
  - **Consumed by**: `orchestrator.sh` Bash pipeline Layer 3.
  - **Expected shape**: stdout = `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}` if matched, else empty. exit code = 0 always.
  - **How to capture**: `echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | /home/tunc/Sync/Programs/aegis/lib/bash-gatekeeper.sh` -- expect ALLOW JSON. Then `echo '{"tool_name":"Bash","tool_input":{"command":"foobar quux"}}' | /home/tunc/Sync/Programs/aegis/lib/bash-gatekeeper.sh` -- expect empty stdout, exit 0.
  - **If not observable**: Phase 1 must be complete. Halt if missing.

- **`lib/protected-paths.sh` -- decision JSON contract** (Phase 2 authored)
  - **Consumed by**: `orchestrator.sh` Edit/Write/NotebookEdit pipeline Layer 1.
  - **Expected shape**: stdout = `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"<text>"}}` if matched, else empty. exit code = 0 always.
  - **How to capture**: `echo '{"tool_name":"Edit","tool_input":{"file_path":"/etc/passwd"}}' | /home/tunc/Sync/Programs/aegis/lib/protected-paths.sh` -- expect ASK JSON. Then `echo '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/x"}}' | /home/tunc/Sync/Programs/aegis/lib/protected-paths.sh` -- expect empty stdout.
  - **If not observable**: Phase 2 must be complete. Halt if missing.

- **PreToolUse JSON shape** (Claude Code emits this to the hook on stdin) -- DOCUMENTED, not observed
  - **Consumed by**: `orchestrator.sh` parses `tool_name` from this on stdin.
  - **Expected shape** (per `PROJECT_PLAN.md` Data Schemas section):
    ```json
    {
      "session_id": "abc-123",
      "tool_name": "Bash",
      "tool_input": { "command": "git status" },
      "cwd": "/home/user/project",
      "transcript_path": "/path/to/transcript.jsonl"
    }
    ```
  - **How to capture**: there is no live Claude Code session available in this dev environment to capture from. The shape above is the documented contract per the project plan and the design spec. Phase 9's integration smoke is the first time real Claude Code emits PreToolUse JSON into our hook. Use the documented shape; the orchestrator-cases.sh fixtures (10 inline `assert` calls) match this shape. **This is documented-not-observed -- the coding agent should note this in the phase summary's Evidence Captured section.**
  - **If not observable**: documented shape is the contract. Move on.

- **Claude Code permission decision JSON shape** (orchestrator emits this on stdout) -- DOCUMENTED, not observed
  - **Consumed by**: Claude Code itself reads this from the hook's stdout.
  - **Expected shape** (per `PROJECT_PLAN.md` Data Schemas section):
    ```json
    {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}
    {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"..."}}
    {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask"}}
    ```
  - **How to capture**: the layer scripts emit exactly this shape; the orchestrator passes through verbatim. We observe it implicitly by capturing layer-script outputs above. The placeholder classifier emits the same shape (with `permissionDecision":"ask"` always).
  - **If not observable**: see above; this is the contract Anthropic publishes in the Claude Code hook docs.

---

## Notes

- The placeholder `__main__.py` is throwaway. Do not over-engineer it (no logging, no error handling, no input validation). Phase 7 replaces the entire file. Minimal wins.
- The orchestrator file uses `exec env PYTHONPATH="$DIR" python3 -m classifier` (NOT `exec python3 -m aegis_classifier`). The plan task 6 step 2 listing has both forms in different places due to a typo; the correct module name is `classifier`. The brief's first constraint flags this explicitly.
- Plan task 6 step 2 also has the trailing classifier invocation as `exec python3 -m aegis_classifier` (no PYTHONPATH). That is also a typo; use `exec env PYTHONPATH="$DIR" python3 -m classifier`. All three classifier invocations in `orchestrator.sh` are identical.
- Use `python3 -m pytest` not `pytest` directly. The shebang and venv handling are simpler that way and matches `pyproject.toml`'s expected invocation.
- Do NOT register the orchestrator into `~/.claude/plugins/aegis/` during this phase. Phase 9's installer handles that. Test exclusively from the dev tree (`/home/tunc/Sync/Programs/aegis`).
- The `mock_classifier` shell function is intentionally placed near the top of the file. Earlier than the dispatch logic. This matches the brief's constraint.
- `set -u` only -- never `set -e`. Layer scripts depend on silent fall-through (empty stdout, exit 0). `set -e` would crash on every fall-through.
- After the phase, write a phase summary at `/home/tunc/Sync/Programs/aegis/docs/agent/project-initiation/summaries/PHASE_03_SUMMARY.md` per project conventions (see `/home/tunc/Sync/Programs/aegis/docs/agent/project-initiation/PROJECT_PLAN.md` "Instructions for Agents" section). Update `STATUS.md`. Capture all Functional QA outputs (commands run + actual stdout/stderr/exit code) in the summary.
