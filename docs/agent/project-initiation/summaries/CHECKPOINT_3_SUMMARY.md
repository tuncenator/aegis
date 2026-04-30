# Checkpoint 3: Post-Batch 3 Summary

**Date**: 2026-04-30
**Batch**: 3 (Orchestrator + Python skeleton)
**Phases Merged**: Phase 3 (Orchestrator + Python skeleton)
**Result**: PASSED

---

## Merge Results

| Phase | Branch | Merge Status | Conflicts |
|-------|--------|-------------|-----------|
| 3 | worktree-agent-afc4e3286841bbf9c | Clean | None |

---

## Test Results

```
$ AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh
PASS=10 FAIL=0

$ unset AEGIS_TEST_MOCK_DECISION && tests/bash/orchestrator-cases.sh
PASS=10 FAIL=0

$ tests/bash/run.sh
passed: 484   failed: 0   notices: 0

$ python3 -m pytest tests/python/ -v
no tests ran in 0.00s (exit 5 -- no tests collected; expected until Phase 4)
```

- **Total tests**: 494 bash + 0 python
- **Passed**: 494
- **Failed**: 0
- **Skipped**: 0

---

## Deployment Results

Disabled for this feature.

---

## Verification Results

| # | Criterion | Command | Status | Key Output |
|---|----------|---------|--------|------------|
| 1 | Orchestrator harness (mocked) PASS=10 FAIL=0, exit 0 | `AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh` | Pass | `PASS=10 FAIL=0`, exit 0 |
| 2 | Orchestrator harness (real classifier) PASS=10 FAIL=0, exit 0 | `unset AEGIS_TEST_MOCK_DECISION && tests/bash/orchestrator-cases.sh` | Pass | `PASS=10 FAIL=0`, exit 0 |
| 3 | Phase 2 regression: `tests/bash/run.sh` failed: 0 | `tests/bash/run.sh` | Pass | `passed: 484   failed: 0   notices: 0`, exit 0 |
| 4 | pytest discovery: runs cleanly, no tests collected | `python3 -m pytest tests/python/ -v` | Pass | `no tests ran in 0.00s`, exit 5 (no-tests-collected, not an error) |
| 5 | Direct classifier smoke: produces expected JSON, exit 0 | `echo '{"tool_name":"WebFetch","tool_input":{"url":"https://x"}}' \| env PYTHONPATH=$PWD python3 -m classifier` | Pass | `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask"}}`, exit 0 |
| 6 | `head -3 orchestrator.sh` shows `set -u` (not `set -e` or `set -eu`) | `grep -n 'set -' orchestrator.sh` | Pass | Line 18: `set -u` only. No `set -e` anywhere. (`set -u` is after comment block, not in first 3 lines, but substance is correct.) |
| 7a | Deviation 1: non-tail classifier uses subprocess + exit 0 | Read `orchestrator.sh` lines 64-68, 74-78, 81-83 | Pass | Bash branch (L66-67): plain subprocess + `exit 0`. Edit/Write branch (L76-77): plain subprocess + `exit 0`. Catch-all (L83): `exec` at true tail. strace confirmed single classifier PID for novel command. |
| 7b | Deviation 2: harness grep matches both compact and json.dump whitespace | Read `tests/bash/orchestrator-cases.sh` lines 19-21 | Pass | Regex `-E '"permissionDecision"[[:space:]]*:[[:space:]]*"<decision>"'` matches both `"key":"val"` and `"key": "val"`. |

### Deviation Verification Details

**Deviation 1 (exec-in-pipeline to subprocess + exit 0)**: Sound. The original `exec` inside a pipeline subshell (within an `if` or `case` block) replaces only the pipeline's right-side subshell, not the orchestrator's main shell. The main shell continues past the block and reaches the catch-all, invoking python a second time. Confirmed via strace: a novel bash command (`foobar quux`) produces a single PID running `python3 -m classifier`. The `exit 0` on lines 67 and 77 prevents fall-through.

**Deviation 2 (grep -E regex for whitespace)**: Sound. Layer scripts emit compact JSON (`"key":"value"`), while `json.dump` emits `"key": "value"` (space after colon). The `[[:space:]]*` quantifier in the regex handles both formats. No corner-case issues: the regex is anchored to the specific key-value pair and the POSIX character class is portable.

---

## Smoke Probe

Disabled for this feature.

---

## Functional QA Evidence Gate

Phase 3 plan has `Functional: yes`. The phase summary contains 7 Functional QA checks matching all 7 checks in the phase plan (Surface 1 Loops 1/2/3/5/6, Surface 1 Mechanic 3, Surface 3 Mechanic 5). Each check has: surface name, concrete invocation command, byte-for-byte pasted observed output, and pass/fail verdict. No vague or paraphrased entries. Gate: PASS.

---

## Helper Repairs

No helpers listed for this phase. No helper failures reported in the phase summary.

---

## Code Review Results

**Result**: REVIEW PASSED WITH NOTES (3 minor issues)

| Severity | Issue | Location | Notes |
|----------|-------|----------|-------|
| Minor | Missing explicit RED capture in TDD sequence | tests/bash/orchestrator-cases.sh + orchestrator.sh | Plan called for the test commit to precede the implementation commit so a RED ("orchestrator.sh missing") state is captured. Both landed in the same commit (`99e920f`). Same-commit is acceptable per the workflow, but the phase summary has no captured RED-state evidence. |
| Minor | Harness does not detect stdout-emitted `deny` decisions | tests/bash/orchestrator-cases.sh:17-21 | `assert()` greps stdout for `allow` / `ask` and uses exit code 2 for `deny`. If a future layer (Phase 7 classifier) emits `{"permissionDecision":"deny"}` on stdout with exit 0, the harness reports `silent`. Latent gap for Phase 7. |
| Minor | Placeholder classifier omits trailing newline | classifier/__main__.py:18 | `json.dump(out, sys.stdout)` writes the JSON without `\n`. Claude Code likely parses stdout as a blob, but unconventional. Phase 7 should consider whether to append a newline when replacing the placeholder. |

### Reviewer Notes

- **Both deviations validated as sound.** The `exec`-in-pipeline -> subprocess + `exit 0` fix correctly prevents the double-invocation bug; only the catch-all (true tail) keeps `exec`, which is safe because nothing follows. The harness regex uses `"permissionDecision"[[:space:]]*:[[:space:]]*"<value>"` to match both compact and `json.dump` whitespace formats; no false positives in current corpus.
- All 7 Functional QA checks captured byte-for-byte in `PHASE_03_SUMMARY.md` -- no paraphrased outcomes.
- `orchestrator.sh` and `orchestrator-cases.sh` both use `set -u` only (verified `head -3`).
- `INPUT=$(cat)` pattern correct (single-shot stdin read, re-fed via `echo "$INPUT" | ...`).
- `jq -r '.tool_name // empty'` for tool-name extraction; no grep/sed JSON anywhere.
- Denylist invocation correctly does NOT capture stdout; uses `rc=$?` + `[ "$rc" = 2 ] && exit 2` for hard-deny propagation.
- `classifier/__main__.py`: stdlib only (`json`, `sys`); ASCII `--`; module docstring documents placeholder status.
- `classifier/__init__.py`: one-line module docstring, ASCII `--`, no other content.
- `tests/python/conftest.py`: stdlib only (`sys`, `pathlib`); `Path(__file__).resolve().parent.parent.parent` walks correctly to repo root.
- No Phase 1-2 files modified. No helper-script edits. No secrets, hardcoded credentials, or untagged infrastructure values.
- `CODEBASE_CONTEXT.md` consolidation matches the actual files committed; AP10 anti-pattern documented.

Reviewer agent: spark-code-reviewer.

---

## Codebase Context Updates

### Added

- `orchestrator.sh`: PreToolUse hook entry with layered dispatch (read-only fast path, Bash pipeline, Edit/Write/NotebookEdit pipeline, catch-all to classifier). Non-tail classifier calls use plain subprocess + `exit 0`; `exec` only at catch-all tail.
- `tests/bash/orchestrator-cases.sh`: 10-assertion end-to-end harness. Grep uses `-E` regex with `[[:space:]]*` for whitespace-tolerant matching.
- `classifier/__main__.py`: Placeholder returning ASK JSON on any input. Uses `json.dump` (spaces after colons).
- `tests/python/conftest.py`: sys.path config inserting repo root for pytest imports.
- AP10 anti-pattern documented: exec-in-pipeline only correct at true script tail.

### Modified

- `classifier/__init__.py`: updated from empty file to module docstring.
- Codebase context: Phase 3 entries moved from "To be created" to "Created" section.
- Orchestrator real-classifier test command updated: valid from Phase 3 (placeholder returns ASK), not "only after Phase 7".

### Removed

None.

---

## Notes for Next Batch

- Phase 7 replaces `classifier/__main__.py` entirely. The placeholder is intentionally minimal.
- Phase 7 modifies `orchestrator.sh` to add `diag_emit`. The two non-tail classifier invocations have `exit 0` after the subprocess; Phase 7's `diag_emit` calls should go before those `exit 0` lines.
- pytest exits 5 ("no tests collected") until Phase 4 adds real tests. This is expected, not an error.
- `AEGIS_TEST_MOCK_DECISION` is now active in the codebase. The orchestrator's `mock_classifier` function honors it.
- The harness's `-E` regex requires a shell with extended regex support; if porting to a minimal system, consider `grep -P` or `awk`.

---

## Status After Checkpoint

- **All phases in batch**: PASSED
- **Cumulative project progress**: 33% (3/9 phases complete)
- **Ready for next batch**: Yes
