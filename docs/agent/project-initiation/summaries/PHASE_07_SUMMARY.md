# Phase 7: Classifier main + diag logging - Summary

**Date Completed:** 2026-04-30
**Completed By:** Agent Phase 7

---

## Objective

Bring the full classifier slow path alive end-to-end. Replace Phase 3's placeholder `classifier/__main__.py` with the real chain orchestrator. Add `classifier/diag.py` as the JSONL writer. Wire a parallel bash diag emitter into `orchestrator.sh` so every deterministic layer appends a row to the same decision log.

---

## Work Completed

### What Was Built

- Full chain orchestrator in `classifier/__main__.py`: stdin parse, state load + early-exit on disabled, rules/snapshot/transcript/prompt assembly, provider chain walk with per-provider repair on malformed response, on_exhaustion fallback, state counter update + save, diag emit, hook output on stdout.
- JSONL decision log writer in `classifier/diag.py`: single `emit()` function, creates parent dirs, appends one JSON row per call.
- `orchestrator.sh` modified: added `SESS` extraction, `diag_emit` shell function, and 5 call sites before deterministic exit points.
- 4 tests in `test_main.py` and 3 tests in `test_diag.py`.

### Files Created

- `classifier/diag.py` - JSONL decision log writer
- `tests/python/test_diag.py` - 3 tests for diag module
- `tests/python/test_main.py` - 4 tests for classifier main

### Files Modified

- `classifier/__main__.py` - REPLACED Phase 3 placeholder with full chain orchestrator
- `orchestrator.sh` - Added `SESS` extraction, `diag_emit` helper, 5 call sites

### Key Design Decisions

- Used `capsys` (pytest built-in) instead of monkeypatching `sys.stdout` with `io.StringIO`. Pytest's own stdout capture mechanism conflicts with direct `sys.stdout` monkeypatching; `capsys` works correctly within pytest's capture framework.
- The `d: decision.Decision | None = None` initializer before the chain-walk loop is defensive: ensures the post-loop `if d is None` check works even if the loop body's try/except branches never bind `d`.
- The bash `diag_emit` hard-deny call site required expanding `[ "$rc" = 2 ] && exit 2` into an `if` block to insert the diag call before exit.

---

## Completion Criteria Status

- [x] `classifier/__main__.py` REPLACES Phase 3 placeholder - Verified: `test_main_first_provider_succeeds` exercises the full chain.
- [x] `classifier/diag.py` exists with correct signature - Verified: `test_emit_writes_jsonl_line` confirms schema.
- [x] `orchestrator.sh` has `diag_emit` helper - Verified: lines 44-60 of orchestrator.sh.
- [x] 5 diag_emit call sites, no call on classifier branch - Verified: lines 65, 76, 83, 90, 105. Lines 95-97, 108-110, 115-116 have no diag_emit.
- [x] `tests/python/test_main.py` passes 4 tests - Verified: `uv run python -m pytest tests/python/test_main.py -v` -- 4 passed.
- [x] `tests/python/test_diag.py` passes 3 tests - Verified: `uv run python -m pytest tests/python/test_diag.py -v` -- 3 passed.
- [x] `tests/bash/run.sh` passes - Verified: `passed: 484 failed: 0 notices: 0`.
- [x] `AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh` passes - Verified: `PASS=10 FAIL=0`.
- [ ] `unset AEGIS_TEST_MOCK_DECISION; tests/bash/orchestrator-cases.sh` - DEVIATION: `PASS=9 FAIL=1`. See Deviations section.
- [x] `uv run python -m pytest tests/python/ -v` passes all 43 tests - Verified: 43 passed.
- [x] Smoke: hard-allow diag row written - Verified: `tail -1 ~/.cache/aegis/decisions.jsonl` shows `layer="hard-allow"`, `decision="allow"`.
- [x] Disabled-session early-exit verified - Verified: `test_main_disabled_session_falls_through` asserts empty stdout and `mock_diag == []`.

### Deviations / Incomplete Items

- **Unmocked orchestrator-cases.sh (1 failure)**: The "novel cmd" test expects `ask` (matching the Phase 3 placeholder which always returned "ask"). With the real classifier, gemini returns "deny" for "foobar quux". The test harness (`orchestrator-cases.sh`, Phase 3 owned) also lacks a `deny-on-stdout-with-exit-0` detection branch in its assert function. This is a pre-existing harness limitation combined with the inherent non-determinism of a real LLM classifier. The mocked test (10/10) is the deterministic regression gate. Cannot fix `orchestrator-cases.sh` per phase boundary constraints.

---

## Testing

### Tests Written

- `tests/python/test_diag.py`
  - test_emit_writes_jsonl_line
  - test_emit_appends
  - test_emit_handles_missing_dir

- `tests/python/test_main.py`
  - test_main_first_provider_succeeds
  - test_main_falls_to_second_provider
  - test_main_on_exhaustion_returns_ask
  - test_main_disabled_session_falls_through

### Test Results

```
$ uv run python -m pytest tests/python/ -v
tests/python/test_decision.py::test_parse_valid_allow PASSED
tests/python/test_decision.py::test_parse_valid_deny PASSED
tests/python/test_decision.py::test_parse_valid_ask PASSED
tests/python/test_decision.py::test_parse_with_surrounding_whitespace PASSED
tests/python/test_decision.py::test_parse_invalid_json_raises PASSED
tests/python/test_decision.py::test_parse_invalid_decision_value_raises PASSED
tests/python/test_decision.py::test_parse_with_codefence_extracts_json PASSED
tests/python/test_decision.py::test_to_hook_output_allow PASSED
tests/python/test_decision.py::test_to_hook_output_deny_includes_reason PASSED
tests/python/test_diag.py::test_emit_writes_jsonl_line PASSED
tests/python/test_diag.py::test_emit_appends PASSED
tests/python/test_diag.py::test_emit_handles_missing_dir PASSED
tests/python/test_main.py::test_main_first_provider_succeeds PASSED
tests/python/test_main.py::test_main_falls_to_second_provider PASSED
tests/python/test_main.py::test_main_on_exhaustion_returns_ask PASSED
tests/python/test_main.py::test_main_disabled_session_falls_through PASSED
tests/python/test_prompt.py::test_system_prompt_includes_rules_and_env PASSED
tests/python/test_prompt.py::test_user_prompt_includes_context_and_pending PASSED
tests/python/test_prompt.py::test_user_prompt_includes_claude_md_when_configured PASSED
tests/python/test_prompt.py::test_user_prompt_caps_claude_md PASSED
tests/python/test_providers.py::test_base_invokes_subprocess PASSED
tests/python/test_providers.py::test_base_retries_on_nonzero_exit PASSED
tests/python/test_providers.py::test_base_returns_none_on_exhausted PASSED
tests/python/test_providers.py::test_base_handles_timeout PASSED
tests/python/test_providers.py::test_claude_provider_sets_norename_env PASSED
tests/python/test_rules.py::test_load_snapshot PASSED
tests/python/test_rules.py::test_snapshot_age_days PASSED
tests/python/test_rules.py::test_load_global_config_missing_returns_defaults PASSED
tests/python/test_rules.py::test_load_config_global_only PASSED
tests/python/test_rules.py::test_load_config_project_overrides_global PASSED
tests/python/test_state.py::test_load_missing_returns_default PASSED
tests/python/test_state.py::test_save_then_load_round_trip PASSED
tests/python/test_state.py::test_record_decision_allow_resets_consecutive PASSED
tests/python/test_state.py::test_record_decision_deny_increments PASSED
tests/python/test_state.py::test_record_decision_deny_pauses_at_consecutive_limit PASSED
tests/python/test_state.py::test_record_decision_deny_pauses_at_total_limit PASSED
tests/python/test_state.py::test_corrupt_file_is_recovered PASSED
tests/python/test_transcript.py::test_parse_minimal_takes_user_messages PASSED
tests/python/test_transcript.py::test_parse_minimal_takes_tool_uses PASSED
tests/python/test_transcript.py::test_parse_strips_tool_results PASSED
tests/python/test_transcript.py::test_parse_respects_last_user_n PASSED
tests/python/test_transcript.py::test_parse_missing_file_returns_empty PASSED
tests/python/test_transcript.py::test_parse_malformed_lines_are_skipped PASSED
============================== 43 passed in 0.05s ==============================
```

```
$ tests/bash/run.sh
passed: 484   failed: 0   notices: 0
```

```
$ AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh
PASS=10 FAIL=0
```

---

## Evidence Captured

### Interfaces Not Observed

No new external interfaces consumed in this phase. All consumed APIs (state, rules, transcript, prompt, decision, providers) were authored in prior phases and observed during those phases.

---

## Functional QA Results

### Check 1: Classifier path end-to-end with mocked provider (Surface 3, Loop 4)

- **Surface**: Surface 3 (Python classifier)
- **Invocation**: `uv run python -m pytest tests/python/test_main.py::test_main_first_provider_succeeds -v`
- **Observed outcome**:

  ```
  tests/python/test_main.py::test_main_first_provider_succeeds PASSED
  ```

  Stdout produced by main(): `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}`
  mock_diag[0]["layer"] == "classifier", len(mock_diag) == 1.

- **Verdict**: pass

### Check 2: Orchestrator routes novel command to real classifier (Surface 1, Loop 4 full pipeline)

- **Surface**: Surface 1 (orchestrator.sh) + Surface 3 (classifier)
- **Invocation**: Deferred to Phase 9.
- **Observed outcome**: N/A
- **Verdict**: deferred. Full integration with orchestrator piping to classifier with provider mocked at subprocess boundary requires test harness modification outside Phase 7's ownership. Phase 9's live smoke covers this.

### Check 3: Classifier writes JSONL row with layer="classifier" (Surface 1, diag side effect)

- **Surface**: Surface 3 (classifier diag emission)
- **Invocation**: Direct Python invocation with mocked provider and captured diag.emit calls.
- **Observed outcome**:

  ```
  PASS: diag row has layer=classifier
  diag row: {"session_id": "fqa3", "tool": "Bash", "layer": "classifier", "decision": "allow", "reason": "ok", "model": "gemini-3.1-flash-lite-preview", "latency_ms": 0}
  ```

- **Verdict**: pass

### Check 4: `ls` triggers hard-allow diag row (Surface 1, diag for deterministic layers)

- **Surface**: Surface 1 (orchestrator.sh)
- **Invocation**: `echo '{"tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"fqa4","cwd":"/tmp"}' | ./orchestrator.sh && tail -1 ~/.cache/aegis/decisions.jsonl`
- **Observed outcome**:

  ```
  {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}
  {"ts": "2026-04-30T07:00:54.610560+00:00", "session_id": "fqa4", "tool": "Bash", "layer": "hard-allow", "decision": "allow", "reason": "bash-gatekeeper matched", "model": null, "latency_ms": 0, "tokens": null}
  ```

- **Verdict**: pass

### Check 5: Disabled-session fall-through (Surface 3, Loop 7)

- **Surface**: Surface 3 (classifier disabled session)
- **Invocation**: `uv run python -m pytest tests/python/test_main.py::test_main_disabled_session_falls_through -v`
- **Observed outcome**:

  ```
  tests/python/test_main.py::test_main_disabled_session_falls_through PASSED
  ```

  Asserts: `capsys.readouterr().out.strip() == ""` and `mock_diag == []`.

- **Verdict**: pass

### Check 6: Chain fallback, first spec None, second succeeds (Surface 3, Loop 4)

- **Surface**: Surface 3 (classifier chain walk)
- **Invocation**: `uv run python -m pytest tests/python/test_main.py::test_main_falls_to_second_provider -v`
- **Observed outcome**:

  ```
  tests/python/test_main.py::test_main_falls_to_second_provider PASSED
  ```

  Asserts: `len(calls) == 2` and `permissionDecision == "deny"`.

- **Verdict**: pass

### Check 7: On-exhaustion behavior, all providers return None (Surface 3)

- **Surface**: Surface 3 (classifier on_exhaustion)
- **Invocation**: `uv run python -m pytest tests/python/test_main.py::test_main_on_exhaustion_returns_ask -v`
- **Observed outcome**:

  ```
  tests/python/test_main.py::test_main_on_exhaustion_returns_ask PASSED
  ```

  Asserts: `permissionDecision == "ask"`.

- **Verdict**: pass

### Anti-Patterns Watched For

- **AP1 (importing classifier modules directly)**: avoided. All test_main tests exercise `main()` through `sys.stdin` monkeypatch + `capsys`, not by calling internal helpers with constructed Decision objects.
- **AP2 (real subprocess calls)**: avoided. `_call_provider` is mocked at the Python function level in all tests. No real gemini/claude CLI invocations.
- **AP3 (touching real ~/.cache/aegis/)**: avoided. All test_main tests use `isolate_state` autouse fixture (`state.STATE_DIR = tmp_path`) and `mock_diag` autouse fixture.
- **AP10 (exec in non-tail)**: preserved. Phase 3's pattern is unchanged: `exec` only at the catch-all tail (line 116).

### Strategy Updates

No strategy updates. All surfaces, harness needs, and anti-patterns were already documented.

---

## Codebase Context Updates

- Updated `classifier/__main__.py` from placeholder to full chain orchestrator. APIs: `main() -> int`, `_call_provider(spec, system, user) -> str | None`, `_read_claude_md(cwd) -> str | None`.
- Added `classifier/diag.py` with `emit(path, *, session_id, tool, layer, decision, reason, model, latency_ms, tokens=None) -> None`.
- Modified `orchestrator.sh`: added `SESS` extraction (line 41), `diag_emit` shell function (lines 44-60), 5 call sites at deterministic exit points.
- Added `tests/python/test_main.py` (4 tests) and `tests/python/test_diag.py` (3 tests). Total Python tests: 43.

---

## Notes for Future Phases

- The unmocked `orchestrator-cases.sh` "novel cmd" test fails (PASS=9 FAIL=1) because the real classifier returns "deny" for "foobar quux" instead of the placeholder's "ask". The test harness also lacks deny-on-stdout detection. Phase 8/9 checkpoint may want to fix the assert function in `orchestrator-cases.sh` to handle deny-with-exit-0 and accept any valid decision for the novel cmd case.
- `capsys` is required for stdout capture in test_main.py (pytest's capture mechanism conflicts with sys.stdout monkeypatching).
- The chain-walk repair path is tested implicitly (first provider returns None, falls to second). Direct malformed-response + repair testing could be added in Phase 9 for completeness.

---

## Integration Points

- `classifier/__main__.py` is called by `orchestrator.sh` via `env PYTHONPATH="$DIR" python3 -m classifier`.
- `classifier/diag.py` is called by `classifier/__main__.py` (classifier layer) and `orchestrator.sh` diag_emit function (deterministic layers).
- Both write to `~/.cache/aegis/decisions.jsonl` with the same JSONL schema.
- Phase 8's `bin/aegis status` will read `decisions.jsonl` for decision history display.
- Phase 9's live smoke will exercise the full pipeline end-to-end.

---

## Security Considerations

- `_read_claude_md` swallows OSError to prevent classifier failure on unreadable files.
- Malformed stdin JSON returns 0 with empty stdout (silent fall-through), preventing error information leakage.
- diag.py uses `os.path.expanduser` for `~` expansion, creating parent dirs with `exist_ok=True`.

---

## Next Steps

**Next Phase:** 8 - bin/aegis CLI + slash commands

**Recommended Actions:**
1. Proceed to Phase 8: build `bin/aegis` CLI with `status`, `on`, `off`, `refresh-rules` subcommands.
2. Consider fixing `orchestrator-cases.sh` assert function to handle deny-on-stdout (currently only detects deny via exit code 2).
