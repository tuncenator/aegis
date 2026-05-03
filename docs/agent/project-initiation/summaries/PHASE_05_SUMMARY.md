# Phase 05: Classifier transcript + prompt + decision - Summary

**Date Completed:** 2026-04-30
**Completed By:** agent-aa5722a802577932e
**Actual Token Usage:** ~40k tokens

---

## Objective

Implement three internal classifier modules for the LLM slow path: `transcript.py` (JSONL parser stripping tool_results), `prompt.py` (system + user prompt builders), and `decision.py` (model output parser + hook output formatter). Plus two JSONL fixtures and 19 unit tests (6+4+9).

---

## Work Completed

### What Was Built

- `classifier/transcript.py`: `ToolUse` + `ParsedTranscript` dataclasses, `_user_text` helper, `parse(transcript_path, last_user_n)`. Strips tool_result-only user messages so hostile file content cannot manipulate the classifier prompt.
- `classifier/prompt.py`: `SYSTEM_TEMPLATE` (with doubled braces on JSON output line), `build_system_prompt(snap, cfg)`, `_approx_token_cap(text, max_tokens)`, `build_user_prompt(parsed, pending, claude_md, cfg)`.
- `classifier/decision.py`: `VALID` set, `DecisionError` exception, `Decision` dataclass, `_FENCE_RE` regex, `parse_response(text)`, `to_hook_output(d)`. Handles bare JSON, fenced JSON, prose-prefixed JSON. `permissionDecisionReason` only on deny + non-empty reason.
- `tests/fixtures/transcript.minimal.jsonl`: 4-entry fixture (no tool_result blocks).
- `tests/fixtures/transcript.with_results.jsonl`: 5-entry fixture with one tool_result block.
- `tests/python/test_transcript.py`: 6 tests.
- `tests/python/test_prompt.py`: 4 tests.
- `tests/python/test_decision.py`: 9 tests.

### Files Created

- `classifier/transcript.py` -- JSONL transcript parser
- `classifier/prompt.py` -- system + user prompt builders
- `classifier/decision.py` -- model output parser and hook formatter
- `tests/fixtures/transcript.minimal.jsonl` -- 4-entry fixture
- `tests/fixtures/transcript.with_results.jsonl` -- 5-entry fixture with tool_result
- `tests/python/test_transcript.py` -- 6 transcript tests
- `tests/python/test_prompt.py` -- 4 prompt tests
- `tests/python/test_decision.py` -- 9 decision tests

### Files Modified

- `pyproject.toml` -- `pytest` added as dev dependency (was missing from prior phases; `uv add --dev pytest` resolved it)

### Key Design Decisions

- Per-module red-green-commit cadence: each ImportError confirmed before implementing the module.
- `_user_text` returns `None` for tool_result-only content lists; security-critical path that prevents prompt injection via prior Read results.
- `SYSTEM_TEMPLATE` uses `str.format` with `{{}}` doubled braces for the JSON output example to avoid `KeyError`.
- `_approx_token_cap` uses 4 chars per token as a rough estimate, truncates with `... [truncated]` suffix.
- `to_hook_output` omits `permissionDecisionReason` for allow and ask, includes it only for deny with non-empty reason.

---

## Completion Criteria Status

- [x] `tests/fixtures/transcript.minimal.jsonl` exists with 4 entries -- verified: file written, read confirmed.
- [x] `tests/fixtures/transcript.with_results.jsonl` exists with 5 entries -- verified: file written, read confirmed.
- [x] `classifier/transcript.py` implements all required exports -- verified: 6 passed.
- [x] `tests/python/test_transcript.py` contains all 6 tests -- verified: 6 passed.
- [x] `uv run python -m pytest tests/python/test_transcript.py -v` -> 6 passed.
- [x] `classifier/prompt.py` implements all required exports -- verified: 4 passed.
- [x] `tests/python/test_prompt.py` contains all 4 tests -- verified: 4 passed.
- [x] `uv run python -m pytest tests/python/test_prompt.py -v` -> 4 passed.
- [x] `classifier/decision.py` implements all required exports -- verified: 9 passed.
- [x] `tests/python/test_decision.py` contains all 9 tests -- verified: 9 passed.
- [x] `uv run python -m pytest tests/python/test_decision.py -v` -> 9 passed.
- [x] Three commits with exact messages -- verified: git log shows all three.
- [x] Full suite `uv run python -m pytest tests/python/ -v` -> 31 passed (12 Phase 4 + 19 Phase 5).
- [x] `tests/bash/run.sh` -> passed: 484, failed: 0, notices: 0.
- [x] `AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh` -> PASS=10 FAIL=0.
- [x] No edits to files outside ownership list.

---

## Testing

### Tests Written

- `tests/python/test_transcript.py`:
  - test_parse_minimal_takes_user_messages
  - test_parse_minimal_takes_tool_uses
  - test_parse_strips_tool_results
  - test_parse_respects_last_user_n
  - test_parse_missing_file_returns_empty
  - test_parse_malformed_lines_are_skipped

- `tests/python/test_prompt.py`:
  - test_system_prompt_includes_rules_and_env
  - test_user_prompt_includes_context_and_pending
  - test_user_prompt_includes_claude_md_when_configured
  - test_user_prompt_caps_claude_md

- `tests/python/test_decision.py`:
  - test_parse_valid_allow
  - test_parse_valid_deny
  - test_parse_valid_ask
  - test_parse_with_surrounding_whitespace
  - test_parse_invalid_json_raises
  - test_parse_invalid_decision_value_raises
  - test_parse_with_codefence_extracts_json
  - test_to_hook_output_allow
  - test_to_hook_output_deny_includes_reason

### Test Results

```
$ uv run python -m pytest tests/python/ -v
============================= test session starts ==============================
platform linux -- Python 3.13.12, pytest-9.0.3, pluggy-1.6.0
collected 31 items

tests/python/test_decision.py::test_parse_valid_allow PASSED
tests/python/test_decision.py::test_parse_valid_deny PASSED
tests/python/test_decision.py::test_parse_valid_ask PASSED
tests/python/test_decision.py::test_parse_with_surrounding_whitespace PASSED
tests/python/test_decision.py::test_parse_invalid_json_raises PASSED
tests/python/test_decision.py::test_parse_invalid_decision_value_raises PASSED
tests/python/test_decision.py::test_parse_with_codefence_extracts_json PASSED
tests/python/test_decision.py::test_to_hook_output_allow PASSED
tests/python/test_decision.py::test_to_hook_output_deny_includes_reason PASSED
tests/python/test_prompt.py::test_system_prompt_includes_rules_and_env PASSED
tests/python/test_prompt.py::test_user_prompt_includes_context_and_pending PASSED
tests/python/test_prompt.py::test_user_prompt_includes_claude_md_when_configured PASSED
tests/python/test_prompt.py::test_user_prompt_caps_claude_md PASSED
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

============================== 31 passed in 0.03s ==============================

$ tests/bash/run.sh
passed: 484   failed: 0   notices: 0

$ AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh
PASS=10 FAIL=0
```

---

## Evidence Captured

### Interfaces Not Observed

This phase is purely internal (stdlib parsers, string builders, dataclasses). No external HTTP, DB, or third-party interfaces were consumed. No evidence capture required.

---

## Helper Issues

No helpers were listed for this phase. No helper issues encountered.

### Unlisted helpers attempted

- **What you needed**: `pytest` was missing from `pyproject.toml` dev dependencies. Prior phases ran `uv run python -m pytest` against a `.venv` that had it installed; this worktree's fresh `.venv` did not.
- **What you did instead**: `uv add --dev pytest` (inline, one-shot).
- **Helper that would have helped**: n/a -- this is a setup gap, not a mechanical phase task.

---

## Challenges & Solutions

### Challenge 1: pytest missing from worktree venv

`uv run python -m pytest` reported "No module named pytest" on first run. Prior phases used the same command but the worktree's `.venv` was freshly created without dev deps.

**Solution:** `uv add --dev pytest`. Added pytest 9.0.3 plus transitive deps (iniconfig, packaging, pluggy, pygments).

---

## Codebase Context Updates

- Add `classifier/transcript.py` to Key Files table under "Created in Phase 5": JSONL parser, exports `ToolUse`, `ParsedTranscript`, `parse`.
- Add `classifier/prompt.py` to Key Files table under "Created in Phase 5": prompt builders, exports `SYSTEM_TEMPLATE`, `build_system_prompt`, `_approx_token_cap`, `build_user_prompt`.
- Add `classifier/decision.py` to Key Files table under "Created in Phase 5": decision parser + formatter, exports `VALID`, `DecisionError`, `Decision`, `_FENCE_RE`, `parse_response`, `to_hook_output`.
- Add `tests/fixtures/transcript.minimal.jsonl` and `tests/fixtures/transcript.with_results.jsonl` to Key Files.
- Add `tests/python/test_transcript.py`, `tests/python/test_prompt.py`, `tests/python/test_decision.py` to Key Files.
- Update "To be created in Phase 5" rows to "Created in Phase 5".
- Note in pyproject.toml entry: pytest added as dev dependency in Phase 5.
- Update Build / test commands total: 31 Python tests (was 12).

## Notes for Future Phases

- Phase 7 (`__main__.py`) imports: `transcript.parse`, `transcript.ParsedTranscript`, `prompt.build_system_prompt`, `prompt.build_user_prompt`, `decision.parse_response`, `decision.to_hook_output`, `decision.Decision`, `decision.DecisionError`. All exported.
- `to_hook_output` does NOT carry `permissionDecisionReason` for ask or allow -- only for deny with non-empty reason. Phase 7 must not assume the field is always present.
- `parse` returns empty `ParsedTranscript` for missing or unreadable files (no exception raised). Phase 7 can call it unconditionally.
- `_approx_token_cap` is a rough 4-chars-per-token estimate. Not a hard token counter. Sufficient for CLAUDE.md truncation.
