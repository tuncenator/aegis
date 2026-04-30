# Phase 3: Orchestrator + Python Skeleton - Summary

**Date Completed:** 2026-04-30
**Completed By:** claude-sonnet-4-6 (agent-afc4e3286841bbf9c)
**Actual Token Usage:** ~40k tokens

---

## Objective

Build the single PreToolUse hook entry (`orchestrator.sh`) that dispatches by `tool_name` through the layered decision pipelines authored in Phases 1-2 (bash-denylist, bash-hard-ask, bash-gatekeeper, protected-paths) and finally to the Python classifier. Land an end-to-end orchestrator test harness. Land a placeholder Python classifier package whose `__main__` returns `{"permissionDecision":"ask"}`.

---

## Work Completed

### What Was Built

- `orchestrator.sh`: PreToolUse hook entry dispatching by tool_name through read-only fast path, Bash pipeline (4 layers), Edit/Write/NotebookEdit pipeline (2 layers), and catch-all to classifier
- `tests/bash/orchestrator-cases.sh`: 10-assertion end-to-end harness covering all dispatch paths
- `classifier/__init__.py`: module docstring marking the package
- `classifier/__main__.py`: placeholder returning ASK JSON on any input
- `tests/python/conftest.py`: sys.path setup so pytest can import classifier

### Files Created

- `orchestrator.sh` -- PreToolUse hook entry, executable
- `tests/bash/orchestrator-cases.sh` -- end-to-end orchestrator harness, executable
- `classifier/__init__.py` -- module docstring (replaced empty file from Phase 1)
- `classifier/__main__.py` -- placeholder entrypoint
- `tests/python/conftest.py` -- pytest sys.path configuration

### Files Modified

- `orchestrator.sh` (created, then fixed): removed unused `CLASSIFIER` variable (shellcheck SC2034), changed non-tail classifier invocations from `exec`-in-pipeline to plain subprocess + explicit `exit 0`
- `tests/bash/orchestrator-cases.sh` (created, then fixed): broadened grep patterns to match `json.dump` whitespace (`"permissionDecision": "ask"` with space after colon)

### Key Design Decisions

1. **exec-in-pipeline fix**: the spec mandates `echo "$INPUT" | exec env PYTHONPATH="$DIR" python3 -m classifier` but this pattern only correctly terminates the orchestrator at the script's tail position. Inside an `if` or `case` block, `exec` in a pipeline replaces only the right side of the pipeline's subshell; the orchestrator's main shell continues past the `if` block and hits the catch-all, invoking the classifier twice. Fixed: use plain subprocess + `exit 0` for the two non-tail invocations; keep `exec` only at the true tail (catch-all line 81). The tail `exec` saves a fork and is correct there.

2. **grep whitespace matching**: the spec's harness grep `'"permissionDecision":"ask"'` (compact, no space) does not match `json.dump` output `"permissionDecision": "ask"` (space after colon). Fixed the grep to use `-E '"permissionDecision"[[:space:]]*:[[:space:]]*"ask"'` which matches both formats. This maintains the harness's ability to work with both the compact layer-script output AND the json.dump classifier output.

3. **pytest exit 5**: `python3 -m pytest tests/python/ -v` exits 5 ("no tests collected"), not 0. Pytest convention: exit 5 means "no tests ran", not an error. The spec says "runs without errors" -- exit 5 is not an error in pytest semantics. Not changed; Phase 4 will add real tests which resolve this.

---

## Completion Criteria Status

- [x] `orchestrator.sh` created at the project root, executable. Verified: `ls -la orchestrator.sh` shows `-rwxr-xr-x`, `head -2 orchestrator.sh` shows `set -u` on line 2.
- [x] `tests/bash/orchestrator-cases.sh` created, executable. Verified: `ls -la tests/bash/orchestrator-cases.sh` shows `-rwxr-xr-x`.
- [x] `classifier/__init__.py` created with module docstring. Verified: file contains `"""Aegis classifier package -- slow path for permission decisions."""`.
- [x] `classifier/__main__.py` placeholder created. Verified: direct smoke produces expected ASK JSON.
- [x] `tests/python/conftest.py` created. Verified: REPO_ROOT resolves to project root.
- [x] `AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh` reports `PASS=10 FAIL=0`. Verified: output `PASS=10 FAIL=0`, exit 0.
- [x] `unset AEGIS_TEST_MOCK_DECISION; tests/bash/orchestrator-cases.sh` reports `PASS=10 FAIL=0`. Verified: output `PASS=10 FAIL=0`, exit 0.
- [x] `tests/bash/run.sh` reports all corpora passing. Verified: `passed: 484   failed: 0   notices: 0`.
- [x] `python3 -m pytest tests/python/ -v` runs without errors. Verified: "no tests ran in 0.00s", exit 5 (no-tests-collected, not an error).
- [x] Classifier placeholder direct smoke produces expected JSON. Verified: `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask"}}`, exit 0.
- [x] All 7 Functional QA checks captured below.
- [x] Phase summary saved.

### Deviations

1. Non-tail `exec`-in-pipeline replaced with plain subprocess + `exit 0` (spec had a bug: exec inside a pipeline in a non-tail position causes double invocation).
2. Harness grep broadened to match json.dump whitespace (spec grep pattern was narrower than the classifier's output format).
3. `CLASSIFIER` variable removed (unused, flagged by shellcheck lint-on-write hook).

---

## Testing

### Tests Written

- `tests/bash/orchestrator-cases.sh`: 10 assertions covering all dispatch paths

### Test Results

```
$ AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh
PASS=10 FAIL=0

$ unset AEGIS_TEST_MOCK_DECISION; tests/bash/orchestrator-cases.sh
PASS=10 FAIL=0

$ tests/bash/run.sh 2>/dev/null | tail -3
----
passed: 484   failed: 0   notices: 0

$ python3 -m pytest tests/python/ -v
============================= test session starts ==============================
platform linux -- Python 3.14.3, pytest-8.4.2, pluggy-1.6.0
cachedir: .pytest_cache
rootdir: /home/tunc/Sync/Programs/aegis/.claude/worktrees/agent-afc4e3286841bbf9c
configfile: pyproject.toml
plugins: typeguard-4.5.1
collecting ... collected 0 items

============================ no tests ran in 0.00s =============================
exit=5
```

---

## Evidence Captured

### lib/bash-denylist.sh -- exit code + stderr contract

- **How captured**: `echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | lib/bash-denylist.sh; echo "rc=$?"`
- **Captured on**: 2026-04-30 against local worktree at commit 99e920f
- **Consumed by**: `orchestrator.sh` line 52-54 (rc=$? + exit 2 propagation)
- **Sample**:

  ```
  bash-denylist: rm -rf targeting root-level path (rm -rf /)
  rc=2
  ```

- **Notes**: stdout is empty (diagnostic goes to stderr). rc=2 on match, rc=0 on no-match.

### lib/bash-hard-ask.sh -- decision JSON contract

- **How captured**: `echo '{"tool_name":"Bash","tool_input":{"command":"git push --force"}}' | lib/bash-hard-ask.sh; echo "rc=$?"`
- **Captured on**: 2026-04-30 against local worktree
- **Consumed by**: `orchestrator.sh` line 57-58 (out=$(...) pattern)
- **Sample**:

  ```
  {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"git push with force flag"}}
  rc=0
  ```

- **Notes**: compact JSON (no spaces after colons). Exit 0 always.

### lib/bash-gatekeeper.sh -- decision JSON contract

- **How captured**: `echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | lib/bash-gatekeeper.sh; echo "rc=$?"`
- **Captured on**: 2026-04-30 against local worktree
- **Consumed by**: `orchestrator.sh` line 61-62
- **Sample**:

  ```
  {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}
  rc=0
  ```

### lib/protected-paths.sh -- decision JSON contract

- **How captured**: `echo '{"tool_name":"Edit","tool_input":{"file_path":"/etc/passwd"}}' | lib/protected-paths.sh; echo "rc=$?"`
- **Captured on**: 2026-04-30 against local worktree
- **Consumed by**: `orchestrator.sh` line 72-73
- **Sample**:

  ```
  {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"writes inside /etc"}}
  rc=0
  ```

### Interfaces Not Observed

- **PreToolUse JSON shape from Claude Code**: no live Claude Code session available. Used documented contract from PROJECT_PLAN.md. The shape `{"session_id":"...","tool_name":"Bash","tool_input":{...},"cwd":"...","transcript_path":"..."}` is the documented contract. First real observation will happen in Phase 9 integration smoke.
- **Claude Code permission decision JSON shape**: observed implicitly by capturing layer-script outputs above. The shape matches what Claude Code's hook docs specify.

---

## Helper Issues

No helpers were listed for this phase (all mechanics were inline). No helper failures.

---

## Functional QA Results

### Check 1: Routine command, fast path via gatekeeper

- **Surface**: Surface 1 (`orchestrator.sh`)
- **Invocation**: `echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | /home/tunc/Sync/Programs/aegis/.claude/worktrees/agent-afc4e3286841bbf9c/orchestrator.sh`
- **Observed outcome**:

  ```
  {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}
  exit=0
  ```

- **Verdict**: pass

### Check 2: Catastrophic command, hard-deny

- **Surface**: Surface 1 (`orchestrator.sh`)
- **Invocation**: `echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | /home/tunc/Sync/Programs/aegis/.claude/worktrees/agent-afc4e3286841bbf9c/orchestrator.sh`
- **Observed outcome**:

  ```
  stdout: (empty)
  stderr: bash-denylist: rm -rf targeting root-level path (rm -rf /)
  exit=2
  ```

- **Verdict**: pass

### Check 3: Risky command, hard-ask

- **Surface**: Surface 1 (`orchestrator.sh`)
- **Invocation**: `echo '{"tool_name":"Bash","tool_input":{"command":"git push --force"}}' | /home/tunc/Sync/Programs/aegis/.claude/worktrees/agent-afc4e3286841bbf9c/orchestrator.sh`
- **Observed outcome**:

  ```
  {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"git push with force flag"}}
  exit=0
  ```

- **Verdict**: pass. Reason mentions force flag. No Python process invoked (gatekeeper layer fires first; hard-ask fires before gatekeeper).

### Check 4: Protected-path edit

- **Surface**: Surface 1 (`orchestrator.sh`)
- **Invocation**: `echo '{"tool_name":"Edit","tool_input":{"file_path":"/etc/passwd"}}' | /home/tunc/Sync/Programs/aegis/.claude/worktrees/agent-afc4e3286841bbf9c/orchestrator.sh`
- **Observed outcome**:

  ```
  {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"writes inside /etc"}}
  exit=0
  ```

- **Verdict**: pass. Reason references /etc. No classifier invoked.

### Check 5: Read-only fast path

- **Surface**: Surface 1 (`orchestrator.sh`)
- **Invocation**: `echo '{"tool_name":"Read","tool_input":{"file_path":"/x"}}' | /home/tunc/Sync/Programs/aegis/.claude/worktrees/agent-afc4e3286841bbf9c/orchestrator.sh`
- **Observed outcome**:

  ```
  {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}
  exit=0
  ```

- **Verdict**: pass. No layer scripts invoked; emit_allow fires immediately.

### Check 6: Full orchestrator harness (mocked + non-mocked)

- **Surface**: Surface 1 (`orchestrator.sh`) via `tests/bash/orchestrator-cases.sh`
- **Invocation (mocked)**: `AEGIS_TEST_MOCK_DECISION=ask /home/tunc/Sync/Programs/aegis/.claude/worktrees/agent-afc4e3286841bbf9c/tests/bash/orchestrator-cases.sh`
- **Observed outcome (mocked)**:

  ```
  PASS=10 FAIL=0
  exit=0
  ```

- **Invocation (non-mocked)**: `unset AEGIS_TEST_MOCK_DECISION; /home/tunc/Sync/Programs/aegis/.claude/worktrees/agent-afc4e3286841bbf9c/tests/bash/orchestrator-cases.sh`
- **Observed outcome (non-mocked)**:

  ```
  PASS=10 FAIL=0
  exit=0
  ```

- **Verdict**: pass (both modes).

### Check 7: Placeholder classifier direct invocation

- **Surface**: Surface 3 (`python3 -m classifier`)
- **Invocation**: `echo '{"tool_name":"WebFetch","tool_input":{"url":"https://x"}}' | env PYTHONPATH=/home/tunc/Sync/Programs/aegis/.claude/worktrees/agent-afc4e3286841bbf9c python3 -m classifier`
- **Observed outcome**:

  ```
  {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask"}}exit=0
  ```

- **Verdict**: pass. Output matches `json.dump` whitespace format (spaces after colons). No trailing newline. Exit 0.

### Anti-Patterns Watched For

- **AP7 (set -e in orchestrator)**: used `set -u` only. Verified: `head -3 orchestrator.sh` shows `set -u` on line 2, no `set -e`.
- **AP8 (forgetting fall-to-next-layer test)**: test 10 ("novel cmd") exercises fall-through from denylist (silent) -> hard-ask (silent) -> gatekeeper (silent) -> classifier. Present and passing.
- **AP9 (installing hook into ~/.claude/)**: did not register into `~/.claude/plugins/` or `~/Sync/.claude/plugins/`. Tested exclusively from dev tree via `echo '...' | ./orchestrator.sh`.
- **AP1 (importing classifier directly in tests)**: no Python tests added this phase; placeholder verified via subprocess invocation only.
- **AP4 (asserting only exit code)**: harness asserts both decision (parsed from stdout) AND exit code for each case.

### Strategy Updates

One new anti-pattern discovered this phase, not in the strategy doc:

**AP10 -- exec-in-pipeline inside non-tail blocks**: using `echo "$INPUT" | exec env ... python3 -m classifier` inside an `if` or `case` block causes double invocation. The `exec` replaces only the pipeline's right-side subshell; the orchestrator's main shell continues past the block and hits the catch-all. Only use `exec` at the true script tail position. Workaround: plain subprocess + explicit `exit 0` for non-tail classifier invocations.

---

## Challenges & Solutions

### Challenge 1: exec-in-pipeline double invocation

The spec mandated identical `echo "$INPUT" | exec env PYTHONPATH="$DIR" python3 -m classifier` for all three classifier invocations. This works correctly at the script tail but causes double-execution when used inside an `if` block -- exec replaces the pipeline subshell, not the orchestrator's main shell, which then continues to the catch-all.

**Solution:** Used plain `env PYTHONPATH="$DIR" python3 -m classifier` + `exit 0` for the two non-tail invocations. Kept `exec` only at the true tail (catch-all). Noted deviation in this summary.

### Challenge 2: grep pattern vs json.dump whitespace mismatch

The spec's harness grep `'"permissionDecision":"ask"'` (compact) doesn't match the placeholder classifier's `json.dump` output `"permissionDecision": "ask"` (space after colon). Both formats are valid JSON but the grep was too strict.

**Solution:** Broadened grep to use `-E '"permissionDecision"[[:space:]]*:[[:space:]]*"ask"'`. This matches both compact (layer scripts) and json.dump (classifier) output formats.

---

## Code Quality

### Formatting
- [x] Code formatted per project conventions
- [x] Imports organized
- [x] No unused imports or variables (shellcheck caught `CLASSIFIER` variable, removed)

### Documentation
- [x] Module docstrings present on Python files
- [x] Inline comments in orchestrator.sh explain pipeline structure

### Linting

```
shellcheck triggered on write (lint-on-write.sh hook):
- SC2034: CLASSIFIER appears unused -- fixed by removing the variable
Final: no shellcheck warnings
```

---

## Dependencies

### Required by This Phase

- Phase 1: `lib/bash-denylist.sh`, `lib/bash-gatekeeper.sh`, `classifier/__init__.py`, `pyproject.toml`
- Phase 2: `lib/bash-hard-ask.sh`, `lib/protected-paths.sh`, `tests/bash/run.sh`

### Unblocked Phases

- Phase 4: `tests/python/conftest.py` makes classifier importable from pytest; `tests/python/` directory exists
- Phase 5-6: same; placeholder `__main__.py` lets downstream tests run end-to-end
- Phase 7: `orchestrator.sh` and `classifier/__main__.py` are in place for modification/replacement

---

## Codebase Context Updates

- Move `orchestrator.sh` from "To be created in Phase 3" to "Created in Phase 3" section
- Move `tests/bash/orchestrator-cases.sh` from "To be created" to "Created"
- Move `classifier/__main__.py` from "To be created" to "Created"
- Move `tests/python/conftest.py` from "To be created" to "Created"
- Update `classifier/__init__.py` note: "replaced empty file from Phase 1 with module docstring"
- Add note in Bash dispatch section: non-tail classifier invocations use plain subprocess + exit 0 (not exec) to avoid double-invocation bug
- Add AP10 to patterns section: exec-in-pipeline only correct at true script tail
- Add env vars section entry: `AEGIS_TEST_MOCK_DECISION` -- now active (mock_classifier function in orchestrator.sh honors it)
- Update build/test commands: orchestrator harness now runnable in both mock and non-mock modes

---

## Notes for Future Phases

- Phase 7 replaces `classifier/__main__.py` entirely. The placeholder is intentionally minimal; do not add logging, error handling, or validation.
- Phase 7 also modifies `orchestrator.sh` to add `diag_emit`. The two non-tail classifier invocations now use `exit 0` after the subprocess; Phase 7's diag_emit calls should go before those `exit 0` lines.
- The harness grep pattern uses `-E` for extended regex (`[[:space:]]*`). If the harness is ported to systems without `-E` support, use `grep -P` or rewrite with `awk`.
- `tests/python/` directory created this phase. Phase 4 adds first real pytest tests there.
- pytest exits 5 ("no tests collected") until Phase 4. This is expected behavior, not an error.

---

## Next Steps

**Next Phase:** Phase 4 -- Classifier State + Rules

**Recommended Actions:**
1. Implement `classifier/state.py` (SessionState dataclass, load/save/record_decision)
2. Implement `classifier/rules.py` (Config, Snapshot, load_config, load_snapshot)
3. Add `tests/python/test_state.py` and `tests/python/test_rules.py`
4. Vendor `rules/snapshot.json` from `claude auto-mode defaults`

---

**Phase Status:** COMPLETE
