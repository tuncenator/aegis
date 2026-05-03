# Phase 6: Provider chain - Summary

**Date Completed:** 2026-04-30
**Actual Token Usage:** ~20k tokens

---

## Objective

Build the subprocess provider layer for the LLM classifier: shared retry/timeout machinery in `classifier/providers/base.py`, plus two concrete providers (`gemini.py`, `claude.py`) that shell out to the `gemini` and `claude` CLIs. All subprocess interaction is mocked in tests; no real CLI calls fire during the test run.

---

## Work Completed

### What Was Built

- `classifier/providers/__init__.py` -- package marker with module docstring
- `classifier/providers/base.py` -- `run_with_retry(spec, invoke)` with retry loop, TimeoutExpired handling (retryable), OSError handling (not retryable), success criterion (returncode==0 AND non-empty stdout)
- `classifier/providers/gemini.py` -- `call(spec, system, user)` invoking `gemini -m MODEL -p PROMPT` via subprocess
- `classifier/providers/claude.py` -- `call(spec, system, user)` invoking `claude --model MODEL -p PROMPT` with `CCSWAP_NORENAME=1` set in env copy
- `tests/python/test_providers.py` -- 5 tests covering all behavior: success, retry-then-success, exhaustion, timeout, claude env mutation

### Files Created

- `classifier/providers/__init__.py` -- package marker
- `classifier/providers/base.py` -- shared retry machinery
- `classifier/providers/gemini.py` -- gemini CLI provider
- `classifier/providers/claude.py` -- claude CLI provider
- `tests/python/test_providers.py` -- 5 provider tests

### Files Modified

- `pyproject.toml` -- added `[dependency-groups] dev = ["pytest>=9.0.3"]` (pytest was missing from the worktree's venv)
- `uv.lock` -- updated after adding pytest dev dep

### Key Design Decisions

- `run_with_retry` uses `max(1, spec.retries)` so `retries=0` still runs once; the loop count is total attempts not extra retries.
- OSError returns `None` immediately (no retry) -- models not on PATH or not executable cannot be fixed by retrying.
- TimeoutExpired continues to next iteration -- next attempt gets a fresh timeout window.
- Raw `r.stdout` is returned (not stripped) when truthy; only `.strip()` is used for the success check to avoid mutating caller's data.
- Both providers build the prompt as `f"{system}\n\n---\n\n{user}"` exactly, no variation.
- `claude.py` copies `os.environ` then mutates the copy; `os.environ` itself is never mutated.
- No logging in provider modules; Phase 7 owns operational logging context (session_id, latency, layer).

---

## Completion Criteria Status

- [x] `classifier/providers/__init__.py` exists with the one-line module docstring.
  Verified: file created, docstring matches spec exactly.
- [x] `classifier/providers/base.py` exists with `run_with_retry` matching the verbatim source.
  Verified: file created verbatim.
- [x] `classifier/providers/gemini.py` exists with `call` matching the verbatim source.
  Verified: file created verbatim.
- [x] `classifier/providers/claude.py` exists with `call` matching the verbatim source.
  Verified: file created verbatim.
- [x] `tests/python/test_providers.py` exists with all 5 tests matching the verbatim source.
  Verified: file created verbatim.
- [x] `python3 -m pytest tests/python/test_providers.py -v` reports 5 passed, 0 failed, 0 errors.
  Verified: see Test Results below.
- [x] `python3 -m pytest tests/python/ -v` reports 0 newly-failing tests.
  Verified: 17 passed (12 prior + 5 new), 0 failures.
- [x] No real gemini or claude subprocess invoked during test run (all mocked).
  Verified: `grep -c 'monkeypatch.setattr(subprocess, "run"' tests/python/test_providers.py` returned 5.
- [x] Files staged in commit: exactly the 5 provider files (plus pyproject.toml + uv.lock for pytest dep).
  Verified: `git status` before commit showed only those 7 files.
- [x] Commit message is `Add gemini and claude classifier providers`.
  Verified: commit created with that exact message.

### Deviations / Incomplete Items

None. `pyproject.toml` and `uv.lock` were also committed because `pytest` was not present as a dev dependency in the worktree (it exists in the main tree but the worktree had a fresh venv). This was a necessary infrastructure addition, not a spec deviation.

---

## Testing

### Tests Written

- `tests/python/test_providers.py`
  - `test_base_invokes_subprocess` -- gemini.call succeeds on first try
  - `test_base_retries_on_nonzero_exit` -- 2 failures then success, confirms 3 calls
  - `test_base_returns_none_on_exhausted` -- all attempts fail, returns None
  - `test_base_handles_timeout` -- TimeoutExpired raised, returns None
  - `test_claude_provider_sets_norename_env` -- CCSWAP_NORENAME=1 in captured env

### Test Results

```
$ uv run python -m pytest tests/python/test_providers.py -v
============================= test session info ==============================
platform linux -- Python 3.13.12, pytest-9.0.3, pluggy-1.6.0
collected 5 items

tests/python/test_providers.py::test_base_invokes_subprocess PASSED      [ 20%]
tests/python/test_providers.py::test_base_retries_on_nonzero_exit PASSED [ 40%]
tests/python/test_providers.py::test_base_returns_none_on_exhausted PASSED [ 60%]
tests/python/test_providers.py::test_base_handles_timeout PASSED         [ 80%]
tests/python/test_providers.py::test_claude_provider_sets_norename_env PASSED [100%]

============================== 5 passed in 0.03s ==============================

$ uv run python -m pytest tests/python/ -v
collected 17 items

tests/python/test_providers.py::test_base_invokes_subprocess PASSED      [  5%]
tests/python/test_providers.py::test_base_retries_on_nonzero_exit PASSED [ 11%]
tests/python/test_providers.py::test_base_returns_none_on_exhausted PASSED [ 17%]
tests/python/test_providers.py::test_base_handles_timeout PASSED         [ 23%]
tests/python/test_providers.py::test_claude_provider_sets_norename_env PASSED [ 29%]
tests/python/test_rules.py::test_load_snapshot PASSED                    [ 35%]
tests/python/test_rules.py::test_snapshot_age_days PASSED                [ 41%]
tests/python/test_rules.py::test_load_global_config_missing_returns_defaults PASSED [ 47%]
tests/python/test_rules.py::test_load_config_global_only PASSED          [ 52%]
tests/python/test_rules.py::test_load_config_project_overrides_global PASSED [ 58%]
tests/python/test_state.py::test_load_missing_returns_default PASSED     [ 64%]
tests/python/test_state.py::test_save_then_load_round_trip PASSED        [ 70%]
tests/python/test_state.py::test_record_decision_allow_resets_consecutive PASSED [ 76%]
tests/python/test_state.py::test_record_decision_deny_increments PASSED  [ 82%]
tests/python/test_state.py::test_record_decision_deny_pauses_at_consecutive_limit PASSED [ 88%]
tests/python/test_state.py::test_record_decision_deny_pauses_at_total_limit PASSED [ 94%]
tests/python/test_state.py::test_corrupt_file_is_recovered PASSED        [100%]

============================== 17 passed in 0.04s ==============================

Mocking discipline check:
$ grep -c 'monkeypatch.setattr(subprocess, "run"' tests/python/test_providers.py
5
```

### Manual Testing

None required. All behavior verified via mocked tests. CLI shapes verified via live sanity checks (see Evidence Captured).

---

## Evidence Captured

### `gemini` CLI subprocess shape

- **How captured**: `gemini -m gemini-3.1-flash-lite-preview -p 'respond with a single JSON object {"decision":"allow","reason":"test"}'; echo "exit=$?"`
- **Captured on**: 2026-04-30 against local gemini CLI
- **Consumed by**: `classifier/providers/gemini.py` -- `subprocess.run(["gemini", "-m", spec.model, "-p", prompt], ...)`
- **Sample**:

  ```
  {"decision":"allow","reason":"test"}
  exit=0
  ```

- **Notes**: `-m` flag confirmed (not `--model`). stdout is plain model text. Exit 0 on success.

### `claude` CLI subprocess shape

- **How captured**: `CCSWAP_NORENAME=1 claude --model claude-haiku-4-5 -p 'respond with a single JSON object {"decision":"allow","reason":"test"}'; echo "exit=$?"`
- **Captured on**: 2026-04-30 against local claude CLI
- **Consumed by**: `classifier/providers/claude.py` -- `subprocess.run(["claude", "--model", spec.model, "-p", prompt], ...)`
- **Sample**:

  ```
  ```json
  {
    "decision": "allow",
    "reason": "test"
  }
  ```
  exit=0
  ```

- **Notes**: `--model` (long form) confirmed, not `-m`. Claude wraps output in markdown code fences when asked for JSON. The `decision.py` parser (Phase 5) must strip code fences. Exit 0 on success.

---

## Helper Issues

None. No helpers were listed for this phase.

---

## Dependencies

### Required by This Phase

- Phase 3: `classifier/__init__.py` exists so `from classifier.providers import ...` resolves.
- Phase 4: `classifier/rules.py` exports `ProviderSpec` dataclass with fields `(provider, model, retries, timeout_s)`.

### Unblocked Phases

- Phase 7: `classifier/__main__.py` chain orchestration can now import `gemini.call` and `claude.call` and dispatch by `spec.provider`.

---

## Codebase Context Updates

- Add `classifier/providers/__init__.py` to Key Files (Phase 6 creation, package marker).
- Add `classifier/providers/base.py` to Key Files (Phase 6 creation, `run_with_retry` shared retry machinery).
- Add `classifier/providers/gemini.py` to Key Files (Phase 6 creation, gemini CLI provider).
- Add `classifier/providers/claude.py` to Key Files (Phase 6 creation, claude CLI provider with CCSWAP_NORENAME).
- Add `tests/python/test_providers.py` to Key Files (Phase 6 creation, 5 mocked subprocess tests).
- Update "To be created in Phase 6" table entries to "Created in Phase 6".
- Note in External Interfaces: claude CLI wraps JSON output in markdown code fences; `decision.py` (Phase 5) must handle this.

## Notes for Future Phases

- Claude CLI wraps JSON in markdown code fences (```json ... ```). `decision.py`'s `parse_response` must strip these. Phase 5 handles this -- the evidence capture here confirms it's needed.
- `run_with_retry` returns raw `r.stdout` (not stripped). Phase 7 should be aware the return value may have leading/trailing whitespace if the model outputs it.
- No logging is done inside any provider module. Phase 7 must wrap provider calls with latency timing and emit to the diag log.

---

**Phase Status:** COMPLETE
