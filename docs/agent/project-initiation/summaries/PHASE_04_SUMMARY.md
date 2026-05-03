# Phase 04: Classifier state + rules - Summary

**Date Completed:** 2026-04-30
**Completed By:** claude-sonnet-4-6 (agent session)
**Actual Token Usage:** ~35k tokens

---

## Objective

Implement the two foundational Python modules of the classifier package:
1. `classifier/state.py` -- per-session JSON state with deny counters and auto-pause logic.
2. `classifier/rules.py` -- layered TOML config loader (built-in defaults < global < project) plus snapshot loader for the vendored `claude auto-mode defaults` output.

Both modules are pure stdlib, fully unit-tested via pytest with `tmp_path` + `monkeypatch`. Also vendors the initial `rules/snapshot.json` and `rules/snapshot.meta.json`.

---

## Work Completed

### What Was Built

- `classifier/state.py`: `SessionState` dataclass + `load`, `save`, `record_decision` functions; `STATE_DIR` module constant; atomic write via `.tmp` + `os.replace`.
- `classifier/rules.py`: `Snapshot`, `ProviderSpec`, `Config` dataclasses + `load_config`, `load_snapshot`, `snapshot_age_days` functions; module constants; `_DEFAULT_CHAIN` with 3 providers.
- `rules/snapshot.json`: real output from `claude auto-mode defaults` (8 allow entries, 32 soft_deny entries, 5 environment entries).
- `rules/snapshot.meta.json`: `{fetched_at, source, ttl_days}` with UTC timestamp at fetch time.
- `tests/python/test_state.py`: 7 tests verbatim from spec.
- `tests/python/test_rules.py`: 5 tests verbatim from spec.

### Files Created

- `classifier/state.py` -- per-session state with deny counters and auto-pause
- `classifier/rules.py` -- layered config loader with snapshot management
- `rules/snapshot.json` -- real `claude auto-mode defaults` output
- `rules/snapshot.meta.json` -- snapshot metadata with UTC fetch timestamp
- `tests/python/test_state.py` -- 7 state module tests
- `tests/python/test_rules.py` -- 5 rules module tests

### Files Modified

None. No existing files were modified.

### Key Design Decisions

- Verbatim fidelity to spec listings maintained throughout.
- `field` import in `state.py` is unused but kept verbatim per spec.
- `tomllib` and `Path` imports in `test_rules.py` are unused but kept verbatim per spec.
- `time` and `Path` imports in `test_state.py` are unused but kept verbatim per spec.
- All tests use `monkeypatch` on module-level constants; no real `~/.cache/aegis/` or `~/.config/aegis/` paths touched.

---

## Completion Criteria Status

- [x] `classifier/state.py` exists and matches verbatim listing. Verified: file written from spec.
- [x] `classifier/rules.py` exists and matches verbatim listing. Verified: file written from spec.
- [x] `rules/snapshot.json` exists with real content. Verified: `python3 -m pytest` + json.load check; keys `allow`(8), `soft_deny`(32), `environment`(5).
- [x] `rules/snapshot.meta.json` exists with `{fetched_at, source, ttl_days}`. Verified: json.load check passed.
- [x] `tests/python/test_state.py` exists with all 7 tests verbatim. Verified: present.
- [x] `tests/python/test_rules.py` exists with all 5 tests verbatim. Verified: present.
- [x] `python3 -m pytest tests/python/test_state.py -v` returns 7 passed. Verified: command run, output shows 7 passed.
- [x] `python3 -m pytest tests/python/test_rules.py -v` returns 5 passed. Verified: command run, output shows 5 passed.
- [x] `python3 -m pytest tests/python/ -v` returns 12 passed. Verified: command run, output shows 12 passed.
- [x] Two commits exist with correct message format. Verified: git log shows both commits.
- [x] `~/.cache/aegis/` untouched. PRE: aegis cache absent. POST: aegis cache absent. Identical.
- [x] `tests/bash/run.sh` still passes. Verified: `passed: 484 failed: 0`.
- [x] `tests/bash/orchestrator-cases.sh` still passes. Verified: `PASS=10 FAIL=0`.

### Deviations / Incomplete Items

None. Implementation matches spec exactly.

---

## Testing

### Tests Written

- `tests/python/test_state.py`
  - `test_load_missing_returns_default`
  - `test_save_then_load_round_trip`
  - `test_record_decision_allow_resets_consecutive`
  - `test_record_decision_deny_increments`
  - `test_record_decision_deny_pauses_at_consecutive_limit`
  - `test_record_decision_deny_pauses_at_total_limit`
  - `test_corrupt_file_is_recovered`

- `tests/python/test_rules.py`
  - `test_load_snapshot`
  - `test_snapshot_age_days`
  - `test_load_global_config_missing_returns_defaults`
  - `test_load_config_global_only`
  - `test_load_config_project_overrides_global`

### Test Results

```
$ python3 -m pytest tests/python/ -v
============================= test session starts ==============================
platform linux -- Python 3.14.3, pytest-8.4.2, pluggy-1.6.0 -- /usr/sbin/python3
cachedir: .pytest_cache
rootdir: /home/tunc/Sync/Programs/aegis/.claude/worktrees/agent-adee9728244f29698
configfile: pyproject.toml
plugins: typeguard-4.5.1
collecting ... collected 12 items

tests/python/test_rules.py::test_load_snapshot PASSED                    [  8%]
tests/python/test_rules.py::test_snapshot_age_days PASSED                [ 16%]
tests/python/test_rules.py::test_load_global_config_missing_returns_defaults PASSED [ 25%]
tests/python/test_rules.py::test_load_config_global_only PASSED          [ 33%]
tests/python/test_rules.py::test_load_config_project_overrides_global PASSED [ 41%]
tests/python/test_state.py::test_load_missing_returns_default PASSED     [ 50%]
tests/python/test_state.py::test_save_then_load_round_trip PASSED        [ 58%]
tests/python/test_state.py::test_record_decision_allow_resets_consecutive PASSED [ 66%]
tests/python/test_state.py::test_record_decision_deny_increments PASSED  [ 75%]
tests/python/test_state.py::test_record_decision_deny_pauses_at_consecutive_limit PASSED [ 83%]
tests/python/test_state.py::test_record_decision_deny_pauses_at_total_limit PASSED [ 91%]
tests/python/test_state.py::test_corrupt_file_is_recovered PASSED        [100%]

============================== 12 passed in 0.02s ==============================
```

### RED Phase Captures

State module RED:
```
ERROR tests/python/test_state.py
tests/python/test_state.py:7: in <module>
    from classifier import state
E   ImportError: cannot import name 'state' from 'classifier'
```

Rules module RED:
```
ERROR tests/python/test_rules.py
tests/python/test_rules.py:7: in <module>
    from classifier import rules
E   ImportError: cannot import name 'rules' from 'classifier'
```

---

## Evidence Captured

### `claude auto-mode defaults` JSON output shape

- **How captured**: `claude auto-mode defaults > rules/snapshot.json` then `python3 -c "import json; d=json.load(open('rules/snapshot.json')); print('keys:', sorted(d.keys())); ..."`
- **Captured on**: 2026-04-30 against local claude CLI
- **Consumed by**: `classifier/rules.py::load_snapshot` (reads `SNAPSHOT_PATH`), `rules/snapshot.json` (committed artifact)
- **Sample**:

  ```
  keys: ['allow', 'environment', 'soft_deny']
  allow_len: 8
  soft_deny_len: 32
  env_len: 5
  ```

- **Notes**: Real CLI output obtained. No placeholder needed. The CLI has the `auto-mode defaults` subcommand and returns a valid JSON object with all three expected keys.

---

## Helper Issues

No helpers were listed for this phase. No helper issues to report.

---

## Challenges & Solutions

No significant challenges encountered. The spec listings were implemented verbatim and all tests passed on the first GREEN run.

---

## Code Quality

### Formatting
- [x] Code formatted per project conventions (stdlib only, `from __future__ import annotations`, `pathlib.Path` throughout)
- [x] Imports organized per spec (including intentional unused imports per verbatim fidelity requirement)
- [x] Unused imports retained verbatim as specified

### Documentation
- [x] Module-level docstrings present on both modules
- [x] Type annotations on all public function signatures
- [x] `record_decision` has a function docstring explaining the caller-saves contract

---

## Dependencies

### Required by This Phase

- Phase 1: `pyproject.toml`, `classifier/__init__.py`, `classifier/log.py`
- Phase 2: `tests/bash/run.sh` and corpora
- Phase 3: `tests/python/conftest.py` (sys.path setup for `from classifier import ...`)

### Unblocked Phases

- Phase 5: `classifier/transcript.py`, `classifier/prompt.py`, `classifier/decision.py` (import `Snapshot`, `Config`, `ProviderSpec` from `rules`)
- Phase 6: `classifier/providers/*` (import `ProviderSpec` from `rules`)
- Phase 7: `classifier/__main__.py` full version (calls `state.load`, `state.save`, `state.record_decision`, `rules.load_config`, `rules.load_snapshot`)
- Phase 8: `bin/aegis` (imports `state` directly)

---

## Codebase Context Updates

- Move `classifier/state.py` from "To be created in Phase 4" to "Created in Phase 4" table.
- Move `classifier/rules.py` from "To be created in Phase 4" to "Created in Phase 4" table.
- Move `rules/snapshot.json` from "To be created in Phase 4" to "Created in Phase 4" table.
- Move `rules/snapshot.meta.json` from "To be created in Phase 4" to "Created in Phase 4" table.
- Move `tests/python/test_state.py` from "To be created in Phase 4" to "Created in Phase 4" table.
- Move `tests/python/test_rules.py` from "To be created in Phase 4" to "Created in Phase 4" table.
- Add `classifier.state` API table entry (already present in CODEBASE_CONTEXT.md).
- Add `classifier.rules` API table entry (already present in CODEBASE_CONTEXT.md).
- Add note: `rules/snapshot.json` contains real `claude auto-mode defaults` output (8 allow, 32 soft_deny, 5 environment entries) fetched 2026-04-30.

---

## Notes for Future Phases

- `rules/snapshot.json` contains real data fetched from `claude auto-mode defaults`. Phase 8 `bin/aegis refresh-rules` can update it once installed.
- `state.STATE_DIR` is a module-level `Path`. Phase 8 reads `AEGIS_STATE_DIR` env var and sets this attribute to redirect for hermetic CLI test runs.
- `record_decision` does NOT call `save`. The caller always saves afterwards. This is by design (batch-friendly).
- `load_config` layers are additive per top-level TOML key; `classifier.chain` and `trusted_*` lists are replaced (not appended) when present in a layer.

---

## Next Steps

**Next Phase:** Phase 5 -- Transcript + prompt + decision

**Recommended Actions:**
1. Implement `classifier/transcript.py`, `classifier/prompt.py`, `classifier/decision.py`.
2. These modules import `Snapshot`, `Config`, `ProviderSpec` from `classifier.rules` -- those are now available.
3. Phase 4 test fixtures (`tmp_state_dir`, `tmp_repo`) serve as patterns for hermetic monkeypatching.
