# Phase 6: Provider chain

**Feature**: project-initiation
**Estimated Context Budget**: ~50k tokens

**Difficulty**: medium
**Visual**: no
**Functional**: no

**Execution Mode**: parallel
**Batch**: 5

---

## Objective

Build the subprocess provider layer for the LLM classifier: shared retry/timeout machinery in `classifier/providers/base.py`, plus two concrete providers (`gemini.py`, `claude.py`) that shell out to the user's `gemini` and `claude` CLIs. All subprocess interaction is mocked in tests; no real CLI calls fire during this phase. The surface this phase produces (`run_with_retry`, `gemini.call`, `claude.call`) is consumed in Phase 7's `_call_provider` dispatch.

---

## Deliverables

1. `classifier/providers/__init__.py` -- package marker with module docstring `"""Classifier provider implementations (gemini CLI, claude CLI)."""`.
2. `classifier/providers/base.py` -- `run_with_retry(spec: ProviderSpec, invoke: Callable[[], subprocess.CompletedProcess]) -> str | None`. Calls `invoke()` up to `max(1, spec.retries)` times. Returns stdout on first success (returncode == 0 AND non-empty stdout). Continues to next attempt on `TimeoutExpired`. Returns `None` immediately on `OSError` (broken environment, not retryable). Returns `None` on exhaustion.
3. `classifier/providers/gemini.py` -- `call(spec: ProviderSpec, system: str, user: str) -> str | None`. Combines prompt as `f"{system}\n\n---\n\n{user}"`. Invokes `subprocess.run(["gemini", "-m", spec.model, "-p", prompt], capture_output=True, text=True, timeout=spec.timeout_s, env=os.environ.copy())` inside the `invoke` closure passed to `run_with_retry`.
4. `classifier/providers/claude.py` -- `call(spec, system, user) -> str | None`. Same prompt format. `env = os.environ.copy(); env["CCSWAP_NORENAME"] = "1"`. Invokes `subprocess.run(["claude", "--model", spec.model, "-p", prompt], capture_output=True, text=True, timeout=spec.timeout_s, env=env)` inside the `invoke` closure.
5. `tests/python/test_providers.py` -- 5 tests, all using `monkeypatch.setattr(subprocess, "run", MagicMock(...))`. Tests verify base behavior (success, retry-then-success, exhaustion, timeout) plus claude-specific env mutation (`CCSWAP_NORENAME=1`).

---

## Detailed Requirements

### Implementation order (literal -- do not reorder)

1. **Verify dependencies**: `classifier/__init__.py` must exist (Phase 3) and `classifier/rules.py` must export `ProviderSpec` dataclass with fields `(provider: str, model: str, retries: int, timeout_s: int)` (Phase 4). Run `python3 -c "from classifier.rules import ProviderSpec; print(ProviderSpec('gemini','m',1,5))"` to confirm. If this fails, stop and report the missing dependency in your phase summary.

2. **Write `tests/python/test_providers.py` first** (RED step). Use the verbatim content from "Test source" below. Run `python3 -m pytest tests/python/test_providers.py -v`. Expected outcome: ImportError on `from classifier.providers import base, gemini, claude`. This confirms the test framework picks up the file and the modules don't yet exist.

3. **Create `classifier/providers/__init__.py`** with the package docstring (one line).

4. **Implement `classifier/providers/base.py`** using the verbatim source listing below.

5. **Implement `classifier/providers/gemini.py`** using the verbatim source listing below.

6. **Implement `classifier/providers/claude.py`** using the verbatim source listing below.

7. **Run tests** (GREEN step): `python3 -m pytest tests/python/test_providers.py -v`. Expected: 5 passed. If any fail, debug -- do NOT modify the tests.

8. **Run the whole python suite** to confirm nothing else broke: `python3 -m pytest tests/python/ -v`. Phases 4 and 5 may also be running in parallel worktrees; in your worktree only Phase 4's classifier/state.py + classifier/rules.py + their tests will be present (Phase 5's tests don't exist yet here). All previously-passing tests must still pass.

9. **Commit** with message `Add gemini and claude classifier providers`. Stage exactly: `classifier/providers/` and `tests/python/test_providers.py`.

### Verbatim source: `classifier/providers/__init__.py`

```python
"""Classifier provider implementations (gemini CLI, claude CLI)."""
```

### Verbatim source: `classifier/providers/base.py`

```python
"""Shared subprocess invocation with retry and timeout."""
from __future__ import annotations

import subprocess
from typing import Callable

from classifier.rules import ProviderSpec


def run_with_retry(
    spec: ProviderSpec,
    invoke: Callable[[], subprocess.CompletedProcess],
) -> str | None:
    """Call invoke() up to spec.retries times. Return stdout on success, None on exhaustion."""
    for _ in range(max(1, spec.retries)):
        try:
            r = invoke()
        except subprocess.TimeoutExpired:
            continue
        except OSError:
            return None
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout
    return None
```

### Verbatim source: `classifier/providers/gemini.py`

```python
"""Gemini CLI provider: subprocess call to `gemini -m MODEL -p PROMPT`."""
from __future__ import annotations

import os
import subprocess

from classifier.providers.base import run_with_retry
from classifier.rules import ProviderSpec


def call(spec: ProviderSpec, system: str, user: str) -> str | None:
    prompt = f"{system}\n\n---\n\n{user}"

    def invoke():
        return subprocess.run(
            ["gemini", "-m", spec.model, "-p", prompt],
            capture_output=True, text=True, timeout=spec.timeout_s,
            env=os.environ.copy(),
        )

    return run_with_retry(spec, invoke)
```

### Verbatim source: `classifier/providers/claude.py`

```python
"""Claude CLI provider: subprocess call to `claude --model MODEL -p PROMPT`.

Sets CCSWAP_NORENAME=1 so a recursive Aegis evaluation of the embedded session
doesn't trigger ccswap's autorename worker. Modeled after ccswap's own _call_claude.
"""
from __future__ import annotations

import os
import subprocess

from classifier.providers.base import run_with_retry
from classifier.rules import ProviderSpec


def call(spec: ProviderSpec, system: str, user: str) -> str | None:
    prompt = f"{system}\n\n---\n\n{user}"
    env = os.environ.copy()
    env["CCSWAP_NORENAME"] = "1"

    def invoke():
        return subprocess.run(
            ["claude", "--model", spec.model, "-p", prompt],
            capture_output=True, text=True, timeout=spec.timeout_s, env=env,
        )

    return run_with_retry(spec, invoke)
```

### Verbatim source: `tests/python/test_providers.py`

```python
import subprocess
from unittest.mock import patch, MagicMock

import pytest

from classifier.providers import base, gemini, claude
from classifier.rules import ProviderSpec


def test_base_invokes_subprocess(monkeypatch):
    fake = MagicMock()
    fake.returncode = 0
    fake.stdout = '{"decision": "allow", "reason": "x"}'
    monkeypatch.setattr(subprocess, "run", MagicMock(return_value=fake))
    spec = ProviderSpec("gemini", "model-x", retries=1, timeout_s=5)
    out = gemini.call(spec, system="sys", user="usr")
    assert "allow" in out


def test_base_retries_on_nonzero_exit(monkeypatch):
    calls = []

    def fake_run(*a, **kw):
        calls.append(1)
        m = MagicMock()
        m.returncode = 0 if len(calls) >= 3 else 1
        m.stdout = '{"decision": "allow", "reason": "ok"}' if m.returncode == 0 else ""
        m.stderr = "transient"
        return m

    monkeypatch.setattr(subprocess, "run", fake_run)
    spec = ProviderSpec("gemini", "m", retries=3, timeout_s=5)
    out = gemini.call(spec, system="s", user="u")
    assert "allow" in out
    assert len(calls) == 3


def test_base_returns_none_on_exhausted(monkeypatch):
    monkeypatch.setattr(subprocess, "run",
                         MagicMock(return_value=MagicMock(returncode=1, stdout="", stderr="err")))
    spec = ProviderSpec("gemini", "m", retries=2, timeout_s=5)
    out = gemini.call(spec, system="s", user="u")
    assert out is None


def test_base_handles_timeout(monkeypatch):
    def boom(*a, **kw):
        raise subprocess.TimeoutExpired("cmd", 1)
    monkeypatch.setattr(subprocess, "run", boom)
    spec = ProviderSpec("gemini", "m", retries=1, timeout_s=1)
    out = gemini.call(spec, system="s", user="u")
    assert out is None


def test_claude_provider_sets_norename_env(monkeypatch):
    captured = {}

    def fake_run(cmd, **kw):
        captured["env"] = kw.get("env", {})
        m = MagicMock()
        m.returncode = 0
        m.stdout = '{"decision":"allow","reason":"x"}'
        return m

    monkeypatch.setattr(subprocess, "run", fake_run)
    spec = ProviderSpec("claude", "claude-haiku-4-5", retries=1, timeout_s=5)
    out = claude.call(spec, system="s", user="u")
    assert out is not None
    assert captured["env"].get("CCSWAP_NORENAME") == "1"
```

### Behavior contract details (read carefully)

- **`spec.retries` is the TOTAL number of attempts**, not "retries on top of one initial try". `max(1, spec.retries)` means `retries=0` still gets one attempt; `retries=2` gets two attempts; `retries=3` gets three attempts.
- **`spec.timeout_s` is per-attempt**, not total. A `retries=3, timeout_s=8` spec can spend up to 24 seconds before exhausting.
- **Success criterion**: `r.returncode == 0 AND r.stdout.strip()` (non-empty after whitespace strip). A returncode-0 with empty stdout is treated as failure and triggers a retry.
- **`TimeoutExpired` is retryable**: catch and `continue` to the next loop iteration. Subsequent iterations get a fresh `subprocess.run` call with a fresh timeout window.
- **`OSError` is not retryable**: return `None` immediately. This catches "binary not found on PATH", "permission denied executing the binary", and similar environmental breakage where retrying cannot help.
- **Other exceptions are not caught**: a programmer error (e.g. a bug in the `invoke` closure raising `TypeError`) propagates to the caller. We do not silence unknown exception types.
- **Prompt format `f"{system}\n\n---\n\n{user}"`**: literal. Two newlines, three hyphens, two newlines. This is the design-spec separator. Both providers use this exact format; do not vary it.
- **`gemini.call` uses `os.environ.copy()` directly**: no env mutation. Passing the parent process env explicitly (rather than letting subprocess inherit it implicitly) is intentional -- it makes test mocks reproducible and matches `claude.call`'s shape.
- **`claude.call` mutates a copy with `CCSWAP_NORENAME=1`**: copy first, then mutate the copy. Never mutate `os.environ` itself.
- **All subprocess invocations are wrapped via `run_with_retry`**: no direct `subprocess.run` outside the `invoke` closure. The closure exists so `run_with_retry` can call it repeatedly without baking subprocess args into base.py.
- **No logging in this phase**: `run_with_retry` does not log, neither does `gemini.call` or `claude.call`. Phase 7 (`__main__.py`) is responsible for any operational logging around provider results. Keep these modules small and pure.

### Edge cases to handle

| Scenario | Expected behavior |
|----------|-------------------|
| `spec.retries == 0` | Loop runs exactly once (`max(1, 0) == 1`). |
| `spec.retries == 1` | Loop runs exactly once. |
| `spec.retries == 3`, all attempts return `returncode=1` | Returns `None`. Three calls to `subprocess.run`. |
| `spec.retries == 3`, attempt 3 returns `returncode=0` with non-empty stdout | Returns stdout. Three calls. |
| `spec.retries == 3`, attempt 1 returns `returncode=0` with non-empty stdout | Returns stdout. ONE call. (Early break.) |
| `spec.retries == 3`, all attempts raise `TimeoutExpired` | Returns `None`. Three calls (each times out). |
| `spec.retries == 3`, attempt 1 raises `TimeoutExpired`, attempt 2 succeeds | Returns stdout. Two calls. |
| `spec.retries == 3`, attempt 1 raises `OSError` | Returns `None`. ONE call. (No retry on OSError.) |
| `r.returncode == 0` but `r.stdout == ""` | Treated as failure; loop continues to next attempt. |
| `r.returncode == 0` but `r.stdout == "   \n  "` (whitespace only) | Treated as failure; loop continues to next attempt. |
| `r.returncode == 0` and `r.stdout == "  hello  \n"` (whitespace around content) | Returns the raw stdout `"  hello  \n"` (untrimmed) -- only the truthiness check uses `.strip()`. |

### Why no logging in providers

Phase 7's `__main__.py` is the place that knows the operational context (session_id, layer name, latency timing). Provider modules are dumb: they invoke a subprocess and return text or `None`. Centralizing logging in `__main__.py` keeps the diag JSONL row coherent (`layer="classifier"`, `model=spec.model`, `latency_ms=...`) and avoids double-logging.

---

## Dependencies

**Requires**:
- Phase 4: `classifier/rules.py` exports the `ProviderSpec` dataclass with fields `(provider: str, model: str, retries: int, timeout_s: int)`. This phase imports it; this phase does NOT modify it.
- Phase 3: `classifier/__init__.py` exists so `from classifier.providers import ...` is resolvable.

**Enables**:
- Phase 7: `classifier/__main__.py` chain orchestration. Phase 7 imports `gemini.call` and `claude.call` and dispatches by `spec.provider` name.

**Parallel sibling**:
- Phase 5: classifier transcript/prompt/decision modules. Independent file ownership; both phases run pytest in their own worktrees with no shared filesystem state, so no contention. No coordination required.

---

## Completion Criteria

- [ ] `classifier/providers/__init__.py` exists with the one-line module docstring.
- [ ] `classifier/providers/base.py` exists with `run_with_retry` matching the verbatim source above.
- [ ] `classifier/providers/gemini.py` exists with `call` matching the verbatim source above.
- [ ] `classifier/providers/claude.py` exists with `call` matching the verbatim source above.
- [ ] `tests/python/test_providers.py` exists with all 5 tests matching the verbatim source above.
- [ ] `python3 -m pytest tests/python/test_providers.py -v` reports 5 passed, 0 failed, 0 errors.
- [ ] `python3 -m pytest tests/python/ -v` reports 0 newly-failing tests in modules outside `test_providers.py`.
- [ ] No real `gemini` or `claude` subprocess was invoked during the test run (subprocess.run is mocked in every test).
- [ ] Files staged in the commit: exactly `classifier/providers/__init__.py`, `classifier/providers/base.py`, `classifier/providers/gemini.py`, `classifier/providers/claude.py`, `tests/python/test_providers.py`. Nothing else.
- [ ] Commit message is `Add gemini and claude classifier providers`.

---

## Testing Requirements

**Test command (primary)**: `python3 -m pytest tests/python/test_providers.py -v`. Expected: 5 passed.

**Test command (full suite)**: `python3 -m pytest tests/python/ -v`. Expected: all previously-passing tests still pass; 5 new tests added by this phase pass.

**Anti-pattern guard**: do NOT use `pytest.mark.skip` or `pytest.mark.xfail` on any test. Every test in `test_providers.py` must execute and pass.

**Anti-pattern guard (AP2 from FUNCTIONAL_QA_STRATEGY.md)**: real subprocess calls to `gemini` or `claude` are forbidden in this phase. Every test must `monkeypatch.setattr(subprocess, "run", ...)` BEFORE calling `gemini.call` or `claude.call`. If you find yourself wanting to "just check that gemini is installed" inside a test, stop -- that goes in the External Interfaces capture step, not in pytest.

**Verification of mocking discipline**: after the test run, `tests/python/test_providers.py` should have exactly 5 occurrences of `monkeypatch.setattr(subprocess, "run"`. Grep:

```bash
grep -c 'monkeypatch.setattr(subprocess, "run"' tests/python/test_providers.py
```

Expected: `5`.

**Test-by-test expectations**:

| Test | Asserts | Calls to subprocess.run |
|------|---------|-------------------------|
| `test_base_invokes_subprocess` | `gemini.call` returns the mocked stdout containing `"allow"`. | 1 (success on first try). |
| `test_base_retries_on_nonzero_exit` | After 2 failures + 1 success, `gemini.call` returns success stdout AND exactly 3 calls were made. | 3. |
| `test_base_returns_none_on_exhausted` | All attempts return returncode=1; `gemini.call` returns `None`. | 2 (retries=2). |
| `test_base_handles_timeout` | `subprocess.run` raises `TimeoutExpired`; `gemini.call` returns `None`. | 1 (retries=1). |
| `test_claude_provider_sets_norename_env` | `claude.call` succeeds; captured env kwarg has `CCSWAP_NORENAME == "1"`. | 1. |

---

## Helpers Required

None. This phase is pure-Python module authoring with mocked subprocess in tests. No SSH, no credential lookup, no log fetching, no cross-service calls. The pytest invocation is a direct command.

---

## External Interfaces Consumed

This phase writes subprocess wrappers around two external CLIs. The tests mock both, so live observation is not strictly required to pass the phase. However, capturing the real CLI shapes is a recommended sanity check before writing the providers, because a wrong CLI flag (`--model` vs `-m`) would not be caught by mocked tests -- the mock only verifies the argv list this phase produces, not whether that argv actually works against the real CLI.

- **`gemini` CLI subprocess shape**
  - **Consumed by**: `classifier/providers/gemini.py` -- specifically the `subprocess.run(["gemini", "-m", spec.model, "-p", prompt], ...)` call.
  - **Expected shape**: `gemini -m <model> -p <prompt>`. Stdout is the model response text. Stderr carries error messages. Exit 0 on success, non-zero on failure (auth missing, model unavailable, rate limit, etc.).
  - **How to capture (recommended sanity check, optional)**:
    ```bash
    gemini -m gemini-3.1-flash-lite-preview -p "respond with a single JSON object {decision:\"allow\",reason:\"test\"}"; echo "exit=$?"
    ```
    Capture: stdout content, stderr if any, exit code. Paste the stdout sample (truncated to the first 500 chars) and exit code into your phase summary's "Evidence Captured" section.
  - **If not observable**: if `gemini` is not installed, not authenticated, or the user opts out of burning a real call, skip the capture and note "gemini CLI not available in this environment; relying on mock-only verification" in the phase summary. The 5 mocked tests are sufficient for pytest. The real-CLI smoke is reserved for Phase 9 under `AEGIS_TEST_LIVE=1`.

- **`claude` CLI subprocess shape**
  - **Consumed by**: `classifier/providers/claude.py` -- specifically the `subprocess.run(["claude", "--model", spec.model, "-p", prompt], ...)` call.
  - **Expected shape**: `claude --model <model> -p <prompt>`. Note the long-form `--model` (NOT `-m` like gemini). Stdout is the model response. Same exit-code semantics as gemini.
  - **How to capture (recommended sanity check, optional)**:
    ```bash
    CCSWAP_NORENAME=1 claude --model claude-haiku-4-5 -p "respond with a single JSON object {decision:\"allow\",reason:\"test\"}"; echo "exit=$?"
    ```
    Set `CCSWAP_NORENAME=1` so the user's ccswap wrapper (if any) doesn't autorename in the middle of a sanity check. Capture stdout truncated to first 500 chars and exit code; paste into phase summary.
  - **If not observable**: same fallback as gemini -- note "claude CLI not available; mock-only verification" and proceed.

**Important**: do NOT write the captured CLI output anywhere except the phase summary. Do not commit captured stdout to the repo. The captures are evidence that the CLI shapes match the planned argv, not test fixtures.

---

## Notes

- The plan task in `docs/superpowers/plans/2026-04-30-aegis.md` (Task 13) is the source of truth for source listings. The verbatim sources above are copy-pasted from there. If you find any discrepancy between this plan and Task 13, follow this plan -- it has been reviewed against the design spec.
- File ownership: this phase owns `classifier/providers/__init__.py`, `classifier/providers/base.py`, `classifier/providers/gemini.py`, `classifier/providers/claude.py`, `tests/python/test_providers.py`. Do not touch any other file. In particular: do NOT modify `classifier/rules.py` (Phase 4 owns it; this phase only imports from it) and do NOT add anything to `classifier/__main__.py` (Phase 7 owns it).
- Phase 5 runs in parallel batch 5 alongside this phase. Phase 5 owns `classifier/transcript.py`, `classifier/prompt.py`, `classifier/decision.py`. Each runs in its own git worktree, so there is no filesystem contention even though both run pytest. If pytest somehow flags an import from a Phase 5 module, that means your test accidentally imported something it shouldn't -- your tests should only import from `classifier.providers.*` and `classifier.rules`.
- The `from __future__ import annotations` at the top of `base.py`, `gemini.py`, `claude.py` is intentional. It defers type annotation evaluation, which lets us use `str | None` syntax cleanly on Python 3.11 without runtime cost. Keep it in every file.
- Do not add a `__main__` guard or `if __name__ == "__main__":` to any provider file. These are library modules, not scripts.
- Do not add additional public functions to any of the four module files. The exact public surface is `run_with_retry` (base), `call` (gemini), `call` (claude), plus the package docstring (`__init__.py`). Phase 7 imports those three names and nothing else.
