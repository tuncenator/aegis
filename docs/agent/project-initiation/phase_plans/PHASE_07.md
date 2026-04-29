# Phase 7: Classifier main + diag logging

**Feature**: project-initiation
**Estimated Context Budget**: ~90k tokens

**Difficulty**: hard
**Visual**: no
**Functional**: yes

**Execution Mode**: sequential
**Batch**: 6

---

## Objective

Bring the full classifier slow path alive end-to-end. Replace Phase 3's placeholder `classifier/__main__.py` with the real chain orchestrator that walks `cfg.classifier_chain`, applies provider-level repair-on-malformed, updates session counters, persists state, and emits a JSONL diag row. Add `classifier/diag.py` as the JSONL writer. Wire a parallel bash diag emitter into `orchestrator.sh` so every deterministic layer (read-only, hard-deny, hard-ask, hard-allow, protected-paths) appends a row to the same decision log on the same schema. After this phase, `~/.cache/aegis/decisions.jsonl` is the single audit surface for every Aegis decision regardless of which layer fired.

---

## Deliverables

1. **`classifier/__main__.py`** -- REPLACE the Phase 3 placeholder. Full chain orchestration: stdin parse, state load + early-exit on `enabled=False`, rules + snapshot load, transcript parse, prompt assembly, provider chain walk with per-provider repair, on-exhaustion fallback, state counter update + save, diag emit, decision-to-hook-output write to stdout. Includes `_call_provider(spec, system, user) -> str | None` dispatch helper and `_read_claude_md(cwd) -> str | None` helper. Keeps `def main() -> int` and `if __name__ == "__main__": raise SystemExit(main())`.
2. **`classifier/diag.py`** -- NEW. Single public function: `emit(path: str, *, session_id: str, tool: str, layer: str, decision: str, reason: str, model: str | None, latency_ms: int, tokens: dict | None = None) -> None`. Expands `~`, creates parent dir, opens in append mode, writes one `json.dumps(row) + "\n"`. ISO8601 UTC timestamp with `datetime.now(timezone.utc).isoformat()`.
3. **`orchestrator.sh`** -- MODIFY (the ONLY cross-phase file modification in this project). Add `diag_emit` shell helper near the top using a `python3` heredoc. Insert calls to `diag_emit` before each terminating `exit 0` (or before `echo "$out"; exit 0`) for the five deterministic exit points: read-only fast path, bash hard-deny, bash hard-ask, bash hard-allow (gatekeeper), protected-paths. Do NOT touch the classifier-dispatch branch (Python `__main__.py` emits its own diag row). All existing dispatch logic (exit codes, stdout JSON, fall-through) must remain bit-identical.
4. **`tests/python/test_main.py`** -- 4 tests: `test_main_first_provider_succeeds`, `test_main_falls_to_second_provider`, `test_main_on_exhaustion_returns_ask`, `test_main_disabled_session_falls_through`. Uses `fake_stdin` and `capture_stdout` fixtures that monkeypatch `sys.stdin` and `sys.stdout` so `main()` is exercised through its real stdin parse path (NOT by importing internal helpers).
5. **`tests/python/test_diag.py`** -- 3 tests: `test_emit_writes_jsonl_line`, `test_emit_appends`, `test_emit_handles_missing_dir`. All use `tmp_path` for the JSONL target.

---

## Detailed Requirements

### Architectural intent

The classifier slow path is a chain-walk-with-repair: the chain is `cfg.classifier_chain` (a list of `ProviderSpec` from Phase 4's rules), and for each spec we ask the provider for a JSON response. There are TWO failure modes that must NOT be conflated:

- **Provider exhausted** -- `_call_provider` returns `None`. This means Phase 6's `run_with_retry` already burned all retries internally (subprocess timeouts, non-zero returncode, empty stdout). Action: continue to next spec in chain. NO repair attempt. NO state mutation (state counters only fire on a real `Decision`).
- **Malformed response** -- provider returned text but `decision.parse_response(out)` raised `DecisionError`. Action: re-call the SAME provider with `usr_p + "\n\nYour previous reply was not valid. Reply ONLY with the JSON object."`. If repair returns `None` OR also raises `DecisionError`, treat the whole spec as exhausted and continue to next spec in chain.

This distinction matters: a chatty model that returns prose deserves a second shot before we burn the next provider. A timing-out model does not.

State and counters are coupled to the FINAL decision, regardless of how it was produced:

- A successful provider call returns a `Decision` -> `record_decision(sess, d.decision, ...)` updates counters.
- Chain exhaustion creates `Decision(decision=cfg.on_exhaustion, reason="classifier chain exhausted")`. The on-exhaustion decision still goes through `record_decision`. If the user configured `on_exhaustion="deny"`, the exhaustion DOES count toward `consecutive_denies` and `total_denies` (and may auto-pause). Document this in the file-level comment of `__main__.py` so future-you doesn't think exhaustion is a no-op.

The diag emit happens AFTER `state.save(sess)`. This means `latency_ms` includes state I/O, which is realistic for end-to-end measurement and is what the user will tail in `decisions.jsonl`. Don't optimize this -- the spec is intentional.

The disabled-session early-exit must fire BEFORE any heavy work: no transcript parse, no provider calls. State load itself is required (it's the only way to know if disabled), and is cheap (single small JSON read). The early-exit MUST emit empty stdout AND MUST NOT call `diag.emit` -- a paused session is a silent fall-through, and silent fall-throughs do not log. Loop 7 in `FUNCTIONAL_QA_STRATEGY.md` defines this contract.

### Integration points

- **From orchestrator.sh into `python3 -m classifier`**: orchestrator pipes the same PreToolUse JSON it received on stdin to the classifier subprocess. Classifier reads stdin via `sys.stdin.read()`, parses JSON, extracts `session_id`/`cwd`/`tool_name`/`tool_input`/`transcript_path`. Output: classifier writes Claude Code permission JSON on stdout. Orchestrator passes through verbatim.
- **Layer ordering**: orchestrator-side deterministic layers (read-only, bash-denylist, bash-hard-ask, bash-gatekeeper, protected-paths) run first. Only if all fall through silently does orchestrator pipe to `python3 -m classifier`. The classifier never re-runs deterministic layers; it owns the slow path exclusively.
- **Diag schema sharing**: The same row schema is written by both the bash `diag_emit` helper and the Python `diag.emit` function. Schema must match exactly: `{ts, session_id, tool, layer, decision, reason, model, latency_ms, tokens}`. The `model` field is `null` for deterministic layers and a string for the classifier layer. The `latency_ms` field is `0` for deterministic layers (the bash helper does not measure) and the real elapsed ms for the classifier.
- **State module**: classifier `__main__.py` calls `state.load(session_id)`, reads `sess.enabled`, possibly returns early. After a successful or exhausted decision, calls `state.record_decision(sess, d.decision, consecutive_limit=cfg.consecutive_deny_limit, total_limit=cfg.total_deny_limit)`. Then `state.save(sess)`. State is owned by Phase 4; this phase only consumes it.
- **Rules / snapshot**: `cfg = rules.load_config(cwd)` and `snap = rules.load_snapshot()`. `cfg.classifier_chain`, `cfg.on_exhaustion`, `cfg.consecutive_deny_limit`, `cfg.total_deny_limit`, `cfg.last_user_messages`, `cfg.include_claude_md`, `cfg.diag_path` are the fields this phase consumes. Phase 4 owns `Config` and `ProviderSpec` dataclasses.
- **Transcript / prompt**: `parsed = transcript.parse(payload.get("transcript_path", ""), cfg.last_user_messages)` -- if `transcript_path` is empty string, `parse` should return an empty `ParsedTranscript` (Phase 5's contract). `sys_p = prompt.build_system_prompt(snap, cfg)` and `usr_p = prompt.build_user_prompt(parsed, pending, claude_md, cfg)`.
- **Decision**: `decision.parse_response(out) -> Decision` strips fences/prose and validates `decision in {allow, deny, ask}`; raises `DecisionError` on invalid. `decision.to_hook_output(d) -> str` returns the JSON string for stdout (with `permissionDecisionReason` only when `d.decision == "deny"`).
- **Providers**: dispatch by `spec.provider`: `"gemini"` -> `classifier.providers.gemini.call(spec, system, user)`; `"claude"` -> `classifier.providers.claude.call(spec, system, user)`. Both return `str | None`. Unknown provider: return `None` (treat as exhausted).

### Edge cases (HARD phase -- think these through)

- **Empty stdin**: `sys.stdin.read()` returns `""`. Code handles via `if raw.strip() else {}`. Then `payload.get("session_id", "unknown")` etc. -- proceeds with defaults. Decision: `record_decision` runs against the `unknown` session state (a new `SessionState(session_id="unknown", enabled=True)`). Acceptable -- this is best-effort behavior when the orchestrator pipes garbage; a real PreToolUse JSON always has session_id.
- **Malformed stdin JSON**: `json.JSONDecodeError` -> `return 0` with empty stdout. No state mutation. No diag emit. The orchestrator's tooling sees a silent fall-through and Claude Code prompts normally.
- **First provider returns parseable text on retry**: the repair branch SHOULD set `out = repaired`, then `d = parse_response(out)`, then `raw_response = out`, `used_model = spec.model`, `break`. The repair only runs once -- if it also fails, fall to next spec.
- **Repair returns None**: the second `_call_provider` (the repair call) returned None (e.g., repair-call timed out). Treat as `continue` (next spec in chain) -- do NOT try parse on None.
- **Repair returns text that also fails parse**: same -- `continue` (next spec in chain).
- **Multiple specs exhaust in sequence**: the loop completes naturally with `raw_response is None` still. The post-loop block constructs `Decision(decision=cfg.on_exhaustion, reason="classifier chain exhausted")` and `used_model = None`. Counter update runs against this synthetic decision.
- **`cfg.on_exhaustion == "deny"`** with prior `consecutive_denies = 2` and `consecutive_deny_limit = 3`: after `record_decision`, `consecutive_denies` becomes 3 and `enabled` flips to False, `paused_reason = "consecutive_deny_limit"`. The CURRENT request still emits the deny decision on stdout (the pause takes effect on the NEXT request). This is the correct semantics -- record-then-emit, not emit-then-record. Verify the implementation matches.
- **`cfg.on_exhaustion == "allow"`**: counter resets `consecutive_denies = 0` (per `state.record_decision` semantics on allow). Acceptable, by design.
- **Disabled session, but `state.load` returns defaults because the file is corrupt**: `state.load` returns a fresh `SessionState(session_id, enabled=True)`. So a corrupt file resurrects the session. Don't try to "fix" this -- Phase 4's defensive default is the right behavior; an alarming UX would be silently keeping the user's session disabled because their state file got truncated.
- **CLAUDE.md too big**: `cfg.claude_md_max_tokens` exists but `_read_claude_md` reads the whole file. Phase 5's `prompt.build_user_prompt` is responsible for truncation -- `__main__.py` just hands the raw string. If `_read_claude_md` raises `OSError`, swallow and return None (the file may be unreadable but we don't want the classifier to fail).
- **`include_claude_md == False`**: `_read_claude_md` is still called but its result is passed to `build_user_prompt`. Per the spec, `build_user_prompt` checks `cfg.include_claude_md` before embedding. If you want belt-and-suspenders, you can guard the call: `claude_md = _read_claude_md(cwd) if cfg.include_claude_md else None`. Optional. The behavior is identical either way -- pick the one that is more readable.

### File-by-file implementation

#### `classifier/__main__.py` (REPLACE Phase 3 placeholder)

Verbatim from plan Task 14 Step 2 (with the Task 15 Step 3 diag/time additions threaded in -- single combined source listing below):

```python
"""Aegis classifier entrypoint.

Reads PreToolUse JSON on stdin, walks the configured provider chain,
applies state-aware deny counters, writes a Claude Code permission
decision JSON on stdout (or empty for silent fall-through when disabled).

Note: when the chain exhausts and `cfg.on_exhaustion` is "deny", the
synthetic exhaustion decision still flows through state.record_decision,
so it counts toward consecutive/total deny limits and can auto-pause the
session. This is intentional: a runaway chain that always exhausts to
deny should look like a deny-storm to the counters.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path
from typing import Any

from classifier import decision, diag, prompt, rules, state, transcript
from classifier.providers import claude as claude_provider
from classifier.providers import gemini as gemini_provider


def _call_provider(spec: rules.ProviderSpec, system: str, user: str) -> str | None:
    if spec.provider == "gemini":
        return gemini_provider.call(spec, system, user)
    if spec.provider == "claude":
        return claude_provider.call(spec, system, user)
    return None


def _read_claude_md(cwd: str | None) -> str | None:
    if not cwd:
        return None
    p = Path(cwd) / "CLAUDE.md"
    if not p.exists():
        return None
    try:
        return p.read_text()
    except OSError:
        return None


def main() -> int:
    t0 = time.time()
    raw = sys.stdin.read()
    try:
        payload: dict[str, Any] = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        return 0

    session_id = payload.get("session_id", "unknown")
    cwd = payload.get("cwd")
    cfg = rules.load_config(cwd)

    sess = state.load(session_id)
    if not sess.enabled:
        # Silent fall-through; let Claude Code prompt the user normally.
        # Do NOT emit diag -- silent fall-throughs are not logged.
        return 0

    snap = rules.load_snapshot()
    parsed = transcript.parse(payload.get("transcript_path", ""), cfg.last_user_messages)
    pending = {"tool_name": payload.get("tool_name"), "tool_input": payload.get("tool_input", {})}

    sys_p = prompt.build_system_prompt(snap, cfg)
    usr_p = prompt.build_user_prompt(parsed, pending, _read_claude_md(cwd), cfg)

    raw_response: str | None = None
    used_model: str | None = None
    d: decision.Decision | None = None
    for spec in cfg.classifier_chain:
        out = _call_provider(spec, sys_p, usr_p)
        if out is None:
            continue
        # Try parse; if malformed, attempt one repair on this provider.
        try:
            d = decision.parse_response(out)
        except decision.DecisionError:
            repair_user = usr_p + "\n\nYour previous reply was not valid. Reply ONLY with the JSON object."
            out = _call_provider(spec, sys_p, repair_user)
            if out is None:
                continue
            try:
                d = decision.parse_response(out)
            except decision.DecisionError:
                continue
        raw_response = out
        used_model = spec.model
        break

    if raw_response is None or d is None:
        # Chain exhausted: apply on_exhaustion behavior.
        d = decision.Decision(decision=cfg.on_exhaustion, reason="classifier chain exhausted")

    # Update counters and persist state.
    state.record_decision(
        sess,
        d.decision,
        consecutive_limit=cfg.consecutive_deny_limit,
        total_limit=cfg.total_deny_limit,
    )
    state.save(sess)

    diag.emit(
        cfg.diag_path,
        session_id=session_id,
        tool=payload.get("tool_name", "?"),
        layer="classifier",
        decision=d.decision,
        reason=d.reason,
        model=used_model,
        latency_ms=int((time.time() - t0) * 1000),
    )

    sys.stdout.write(decision.to_hook_output(d))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

Note the `d: decision.Decision | None = None` initializer -- this is a defensive add (not in the plan source) so that if the loop exits after a `try` block raised but before binding `d` in scope, the post-loop check still works. The plan source binds `d` only inside the loop body; without the initializer the `if raw_response is None` branch is fine but a static type checker complains. Add the initializer.

#### `classifier/diag.py` (NEW)

Verbatim from plan Task 15 Step 2:

```python
"""Decision log writer (JSONL append).

Schema for each row:
    {ts, session_id, tool, layer, decision, reason, model, latency_ms, tokens}

This schema MUST match the bash diag_emit helper in orchestrator.sh so
postmortem tooling sees a uniform stream regardless of which layer wrote
the row.
"""
from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path


def emit(
    path: str,
    *,
    session_id: str,
    tool: str,
    layer: str,
    decision: str,
    reason: str,
    model: str | None,
    latency_ms: int,
    tokens: dict | None = None,
) -> None:
    target = Path(os.path.expanduser(path))
    target.parent.mkdir(parents=True, exist_ok=True)
    row = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "session_id": session_id,
        "tool": tool,
        "layer": layer,
        "decision": decision,
        "reason": reason,
        "model": model,
        "latency_ms": latency_ms,
        "tokens": tokens,
    }
    with target.open("a") as f:
        f.write(json.dumps(row) + "\n")
```

#### `orchestrator.sh` (MODIFY -- add helper + 5 call sites)

The Phase 3 orchestrator is intact; do not rewrite it. Make two kinds of edits:

1. **Add the `diag_emit` shell helper near the top of the script** (after the `set -u` line and any initial constants, before the dispatch logic). Verbatim from plan Task 15 Step 4:

```bash
# Diag emitter for deterministic layers. Calls a python one-liner.
diag_emit() {
  local layer="$1" decision="$2" reason="$3" sess="$4" tool="$5"
  python3 - "$sess" "$tool" "$layer" "$decision" "$reason" <<'PY'
import sys, json, os, datetime, pathlib
sess, tool, layer, decision, reason = sys.argv[1:]
target = pathlib.Path(os.path.expanduser("~/.cache/aegis/decisions.jsonl"))
target.parent.mkdir(parents=True, exist_ok=True)
row = {
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "session_id": sess, "tool": tool, "layer": layer,
    "decision": decision, "reason": reason, "model": None,
    "latency_ms": 0, "tokens": None,
}
with target.open("a") as f:
    f.write(json.dumps(row) + "\n")
PY
}
```

Argument order is `layer decision reason sess tool`. This is the contract. Don't reorder.

2. **Insert `diag_emit` calls before each of the 5 deterministic exit points.** The Phase 3 orchestrator already extracts `$INPUT` (the stdin JSON) and `$TOOL` (`jq -r '.tool_name'`). For session_id, extract once near the top: `SESS=$(echo "$INPUT" | jq -r '.session_id // "unknown"')` -- if the existing orchestrator already does this, reuse it. Otherwise add it.

The 5 call sites:

| # | Layer / dispatch case | layer arg | decision arg | reason arg | When to extract reason |
|---|----------------------|-----------|--------------|------------|------------------------|
| 1 | Read-only fast path (`Read|Glob|Grep|Todo*|Task*`) | `read-only` | `allow` | `harmless tool` | Static |
| 2 | Bash hard-deny matched (before `exit 2`) | `hard-deny` | `deny` | `bash-denylist matched` | Static |
| 3 | Bash hard-ask matched (before `echo "$out"; exit 0`) | `hard-ask` | `ask` | `$(echo "$out" \| jq -r '.hookSpecificOutput.permissionDecisionReason // "hard-ask matched"')` | Extract from layer's stdout JSON |
| 4 | Bash hard-allow / gatekeeper matched | `hard-allow` | `allow` | `bash-gatekeeper matched` | Static |
| 5 | Protected-paths matched | `protected-paths` | `ask` | `$(echo "$out" \| jq -r '.hookSpecificOutput.permissionDecisionReason // "protected path"')` | Extract from layer's stdout JSON |

Each `diag_emit` call goes IMMEDIATELY BEFORE the existing terminal action (`exit 0`, `exit 2`, `echo "$out"; exit 0`). Do NOT replace the existing action. Example for the read-only fast path (the orchestrator from Phase 3 likely has something like):

```bash
case "$TOOL" in
  Read|Glob|Grep|TodoWrite|TaskCreate|TaskUpdate|TaskList|TaskGet|TaskOutput|TaskStop)
    emit_allow
    ;;
esac
```

becomes:

```bash
case "$TOOL" in
  Read|Glob|Grep|TodoWrite|TaskCreate|TaskUpdate|TaskList|TaskGet|TaskOutput|TaskStop)
    diag_emit "read-only" "allow" "harmless tool" "$SESS" "$TOOL"
    emit_allow
    ;;
esac
```

For the bash hard-ask case, the existing layer dispatch produces `$out` containing the layer's JSON. Pass the captured reason:

```bash
out=$(echo "$INPUT" | "$LIB/bash-hard-ask.sh")
if [ -n "$out" ]; then
  reason=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // "hard-ask matched"')
  diag_emit "hard-ask" "ask" "$reason" "$SESS" "$TOOL"
  echo "$out"
  exit 0
fi
```

Same shape for protected-paths.

For bash hard-deny (layer exits 2), the orchestrator detects `$? -eq 2` after the layer pipe. Insert diag_emit between the exit-code check and `exit 2`:

```bash
echo "$INPUT" | "$LIB/bash-denylist.sh"
rc=$?
if [ "$rc" -eq 2 ]; then
  diag_emit "hard-deny" "deny" "bash-denylist matched" "$SESS" "$TOOL"
  exit 2
fi
```

**Constraint**: do NOT add a diag_emit call on the classifier dispatch branch. The Python classifier emits its own row via `diag.emit`. Adding a bash-side row would double-log the slow path.

**Constraint**: do NOT alter stdout, exit codes, or fall-through semantics. The diag_emit calls are pure side-effect appends to `~/.cache/aegis/decisions.jsonl`. Phase 3's tests in `tests/bash/orchestrator-cases.sh` assert stdout and exit code patterns; those must still pass after this modification (with `AEGIS_TEST_MOCK_DECISION=ask`).

### Step-by-step implementation order

1. Read `classifier/__main__.py` (the Phase 3 placeholder) to confirm the package layout.
2. Read `classifier/state.py`, `classifier/rules.py`, `classifier/transcript.py`, `classifier/prompt.py`, `classifier/decision.py`, `classifier/providers/gemini.py`, `classifier/providers/claude.py` to confirm the consumed APIs match the contracts above.
3. Read `orchestrator.sh` (Phase 3) end-to-end to locate the 5 dispatch sites and confirm the `$INPUT`, `$TOOL`, `$LIB`, `$out`, exit-code patterns.
4. Write `tests/python/test_diag.py` (3 failing tests). Run pytest -- expect ImportError on `classifier.diag`.
5. Implement `classifier/diag.py`. Re-run pytest -- expect 3 passed.
6. Write `tests/python/test_main.py` (4 failing tests). Run pytest -- expect AttributeError on `_call_provider` (the placeholder doesn't define it).
7. Replace `classifier/__main__.py` with the full implementation. Re-run pytest -- expect 4 passed.
8. Modify `orchestrator.sh`: add `diag_emit` helper near the top, then add the 5 diag_emit call sites.
9. Run the bash regression: `tests/bash/run.sh` (must still PASS=10 FAIL=0 or whatever Phase 2 set), `AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh` (must still PASS=10 FAIL=0 from Phase 3).
10. Run the full Python suite: `uv run python -m pytest tests/python/ -v`. All prior phase tests plus the new ones must pass.
11. Manually exercise the diag side effect: `echo '{"tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"smoke","cwd":"/tmp"}' | ./orchestrator.sh && tail -1 ~/.cache/aegis/decisions.jsonl` -- expect a row with `"layer":"hard-allow"` and `"decision":"allow"`. (This writes to the user's real `~/.cache/aegis/decisions.jsonl`; it's a one-shot smoke that the user requested be verified end-to-end. Acceptable.)

---

## Dependencies

**Requires**:
- Phase 1: pyproject.toml, classifier/log.py, .gitignore (project skeleton).
- Phase 2: bash deterministic layers (lib/bash-denylist.sh, lib/bash-hard-ask.sh, lib/bash-gatekeeper.sh, lib/protected-paths.sh) -- the orchestrator dispatches into these and we wrap their exit points with diag_emit.
- Phase 3: orchestrator.sh skeleton with layer dispatch logic; classifier/__main__.py placeholder we will replace; tests/bash/orchestrator-cases.sh harness.
- Phase 4: classifier/state.py (`SessionState`, `load`, `save`, `record_decision`, `STATE_DIR`); classifier/rules.py (`Config`, `ProviderSpec`, `Snapshot`, `load_config`, `load_snapshot`); rules/snapshot.json + snapshot.meta.json.
- Phase 5: classifier/transcript.py (`parse`, `ParsedTranscript`); classifier/prompt.py (`build_system_prompt`, `build_user_prompt`); classifier/decision.py (`parse_response`, `to_hook_output`, `Decision`, `DecisionError`).
- Phase 6: classifier/providers/gemini.py (`call`); classifier/providers/claude.py (`call`).

**Enables**:
- Phase 8: bin/aegis CLI -- this phase finalizes the slow-path schema; the CLI's `aegis status` will read both state files and decisions.jsonl rows in the same shape.
- Phase 9: install.sh + integration smoke -- the Phase 9 live smoke against real `gemini` proves the chain wired together by this phase actually works end-to-end with a real model response.

---

## Completion Criteria

- [ ] `classifier/__main__.py` REPLACES the Phase 3 placeholder with the full chain orchestrator (chain walk + repair + on_exhaustion + state coupling + diag emit).
- [ ] `classifier/diag.py` exists with the `emit(path, *, session_id, tool, layer, decision, reason, model, latency_ms, tokens=None) -> None` signature.
- [ ] `orchestrator.sh` has `diag_emit` helper added near the top.
- [ ] 5 diag_emit call sites added before the deterministic-layer exit points (read-only, hard-deny, hard-ask, hard-allow, protected-paths). NO call site added on the classifier dispatch branch.
- [ ] `tests/python/test_main.py` passes: 4 tests, all green.
- [ ] `tests/python/test_diag.py` passes: 3 tests, all green.
- [ ] `tests/bash/run.sh` still passes the Phase 2 corpus (no regression).
- [ ] `AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh` still passes (PASS=10 FAIL=0 or the count Phase 3 set).
- [ ] `uv run python -m pytest tests/python/ -v` passes all tests across all phases.
- [ ] Smoke: `echo '{"tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"smoke","cwd":"/tmp"}' | ./orchestrator.sh && tail -1 ~/.cache/aegis/decisions.jsonl` writes a JSONL row with `layer="hard-allow"` and `decision="allow"`.
- [ ] Disabled-session early-exit verified: a paused state file produces empty stdout and NO diag row (assert via test_main.py).

---

## Testing Requirements

### `tests/python/test_main.py` (verbatim from plan Task 14 Step 1)

```python
import io
import json
from unittest.mock import patch

import pytest

from classifier import __main__ as main_mod


@pytest.fixture
def fake_stdin(monkeypatch):
    def _set(payload: dict):
        monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))
    return _set


@pytest.fixture
def capture_stdout(monkeypatch):
    buf = io.StringIO()
    monkeypatch.setattr("sys.stdout", buf)
    return buf


def test_main_first_provider_succeeds(monkeypatch, fake_stdin, capture_stdout, tmp_path):
    monkeypatch.setattr(main_mod, "_call_provider",
                         lambda spec, sys_p, usr_p: '{"decision":"allow","reason":"ok"}'
                         if spec.provider == "gemini" else None)
    fake_stdin({"tool_name": "Bash", "tool_input": {"command": "ls"}, "session_id": "s1"})
    rc = main_mod.main()
    assert rc == 0
    out = json.loads(capture_stdout.getvalue())
    assert out["hookSpecificOutput"]["permissionDecision"] == "allow"


def test_main_falls_to_second_provider(monkeypatch, fake_stdin, capture_stdout):
    calls = []
    def stub(spec, sys_p, usr_p):
        calls.append(spec.provider)
        if len(calls) == 1:
            return None
        return '{"decision":"deny","reason":"r"}'
    monkeypatch.setattr(main_mod, "_call_provider", stub)
    fake_stdin({"tool_name": "Bash", "tool_input": {"command": "ls"}, "session_id": "s2"})
    rc = main_mod.main()
    assert rc == 0
    out = json.loads(capture_stdout.getvalue())
    assert out["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert len(calls) == 2


def test_main_on_exhaustion_returns_ask(monkeypatch, fake_stdin, capture_stdout):
    monkeypatch.setattr(main_mod, "_call_provider", lambda *a, **kw: None)
    fake_stdin({"tool_name": "Bash", "tool_input": {"command": "ls"}, "session_id": "s3"})
    rc = main_mod.main()
    assert rc == 0
    out = json.loads(capture_stdout.getvalue())
    assert out["hookSpecificOutput"]["permissionDecision"] == "ask"


def test_main_disabled_session_falls_through(monkeypatch, fake_stdin, capture_stdout, tmp_path):
    from classifier import state
    monkeypatch.setattr(state, "STATE_DIR", tmp_path)
    s = state.SessionState(session_id="paused", enabled=False, paused_reason="manual")
    state.save(s)
    fake_stdin({"tool_name": "Bash", "tool_input": {"command": "x"}, "session_id": "paused"})
    rc = main_mod.main()
    assert rc == 0
    # When disabled, classifier emits empty (silent fall-through)
    assert capture_stdout.getvalue().strip() == ""
```

Note: AP1 mitigation -- tests monkeypatch `sys.stdin` and exercise `main()` end-to-end, NOT internal helpers. AP3 mitigation -- the disabled-session test redirects `state.STATE_DIR` to `tmp_path`. The first three tests don't redirect STATE_DIR, but they only rely on `state.load` returning `enabled=True` defaults -- no on-disk pollution because the session_id `s1`/`s2`/`s3` is unique-per-test and the test's record_decision writes to the user's real STATE_DIR. **This is a Phase 7 test-ordering concern**: monkeypatch `state.STATE_DIR` to `tmp_path` in ALL FOUR test_main tests, not just the disabled one. Add `monkeypatch.setattr(state, "STATE_DIR", tmp_path)` at the top of each test (or use a shared fixture). The plan source omitted this; add it.

Updated test fixture pattern (recommended):

```python
@pytest.fixture(autouse=True)
def isolate_state(tmp_path, monkeypatch):
    from classifier import state
    monkeypatch.setattr(state, "STATE_DIR", tmp_path)
    return tmp_path
```

This fixture autouses for every test in the file, eliminating cross-test contamination of `~/.cache/aegis/sessions/`. Also redirect the diag path so tests don't pollute `~/.cache/aegis/decisions.jsonl`. The cleanest way: monkeypatch `cfg.diag_path` indirectly by patching `rules.load_config` to return a Config with `diag_path = str(tmp_path / "decisions.jsonl")`, OR monkeypatch `diag.emit` to a no-op for tests that don't care about diag.

For the 4 main tests above, monkeypatch `diag.emit` to a recording mock so we can assert what got logged without touching disk:

```python
@pytest.fixture(autouse=True)
def mock_diag(monkeypatch):
    from classifier import diag
    calls = []
    def fake_emit(path, **kw):
        calls.append(kw)
    monkeypatch.setattr(diag, "emit", fake_emit)
    return calls
```

Then `test_main_disabled_session_falls_through` can additionally assert `assert mock_diag == []` (no diag for silent fall-through).

### `tests/python/test_diag.py` (verbatim from plan Task 15 Step 1)

```python
import json
from pathlib import Path

import pytest

from classifier import diag


@pytest.fixture
def tmp_log(tmp_path):
    return tmp_path / "decisions.jsonl"


def test_emit_writes_jsonl_line(tmp_log):
    diag.emit(str(tmp_log), session_id="s1", tool="Bash", layer="hard-allow",
              decision="allow", reason="ok", model=None, latency_ms=4)
    lines = tmp_log.read_text().strip().splitlines()
    assert len(lines) == 1
    obj = json.loads(lines[0])
    assert obj["session_id"] == "s1"
    assert obj["layer"] == "hard-allow"
    assert obj["decision"] == "allow"
    assert "ts" in obj


def test_emit_appends(tmp_log):
    diag.emit(str(tmp_log), session_id="s1", tool="Bash", layer="hard-allow",
              decision="allow", reason="x", model=None, latency_ms=4)
    diag.emit(str(tmp_log), session_id="s1", tool="Edit", layer="classifier",
              decision="deny", reason="protected", model="gemini-x", latency_ms=420)
    lines = tmp_log.read_text().strip().splitlines()
    assert len(lines) == 2


def test_emit_handles_missing_dir(tmp_path):
    target = tmp_path / "subdir" / "decisions.jsonl"
    diag.emit(str(target), session_id="s", tool="Bash", layer="classifier",
              decision="allow", reason="x", model="m", latency_ms=10)
    assert target.exists()
```

### Verification command (full regression)

```bash
tests/bash/run.sh && \
  AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh && \
  uv run python -m pytest tests/python/ -v
```

All three must succeed. If any fails, do NOT mark the phase complete -- diagnose, fix, re-run.

---

## Functional QA

The 7 phase-specific checks below are derived from Loops 1, 4, 7, 8 of `FUNCTIONAL_QA_STRATEGY.md`. Each names the surface, exact invocation, and exact observable outcome. Mark each pass/fail in the phase summary; paste the actual stdout for any non-trivial check.

- [ ] **(Surface 3, Loop 4) Classifier path end-to-end with mocked provider.** `echo '{"tool_name":"Bash","tool_input":{"command":"foobar quux"},"session_id":"fqa1","cwd":"/tmp","transcript_path":""}' | env PYTHONPATH=. python3 -m classifier` -- with `_call_provider` mocked at the module level via a temporary monkeypatch in a pytest run (NOT a real subprocess), assert stdout is valid Claude Code permission JSON with `permissionDecision in {allow, deny, ask}`. The 4 tests in `test_main.py` collectively cover this; capture the stdout from `test_main_first_provider_succeeds` into the summary.

- [ ] **(Surface 1, Loop 4, full pipeline) Orchestrator routes novel command to real classifier (provider mocked).** Run a fixture through orchestrator with `AEGIS_TEST_MOCK_DECISION` UNSET. Add a pytest case in `test_main.py` (or a separate integration test) that invokes orchestrator.sh as a subprocess with stdin = the novel-cmd JSON, with the gemini/claude provider modules monkeypatched at the subprocess.run layer to return a synthetic JSON response. Assert orchestrator's stdout contains the expected decision JSON. If this is too heavy for Phase 7, document and defer the real orchestrator-classifier glue test to Phase 9's smoke -- but DO test the classifier-side invariants in test_main.py.

- [ ] **(Surface 1, diag side effect, classifier layer) Classifier writes a JSONL row with `layer="classifier"`.** Test in `test_main.py`: configure `cfg.diag_path` to a tmp path (via patching `rules.load_config`), drive a successful provider mock through `main()`, then assert `tmp_path/"decisions.jsonl"` has exactly one line and it parses as JSON with `layer == "classifier"`, `decision in {allow, deny, ask}`, and `model == "gemini-3.1-flash-lite-preview"` (or whichever spec's model the mock simulated success for).

- [ ] **(Surface 1, diag for deterministic layers) `ls` triggers a `hard-allow` diag row.** Run: `echo '{"tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"fqa4","cwd":"/tmp"}' | ./orchestrator.sh && tail -1 ~/.cache/aegis/decisions.jsonl`. Expected tail: a JSONL row with `"layer":"hard-allow"`, `"decision":"allow"`, `"reason":"bash-gatekeeper matched"`, `"session_id":"fqa4"`, `"tool":"Bash"`. Capture the actual line into the summary. (This touches the user's real `~/.cache/aegis/decisions.jsonl`; that's intentional for the smoke. The test_diag.py tests use `tmp_path` so unit tests don't pollute.)

- [ ] **(Surface 3, Loop 7, disabled-session fall-through) Paused session emits empty stdout and NO diag row.** Test in `test_main.py`: pre-seed state file with `enabled=false, paused_reason="manual"`, drive `main()`, assert `rc == 0`, `stdout == ""`, AND `mock_diag` recorded zero calls. This is the silent-fall-through invariant; if any diag row gets written for a paused session, the test must fail.

- [ ] **(Surface 3, Loop 4 chain fallback) First spec returns None, second spec succeeds.** Test in `test_main.py` (`test_main_falls_to_second_provider`): assert both providers were tried in order AND the second's decision is in stdout. Capture `calls = ["gemini", "gemini"]` (or the actual chain ordering -- depends on `_DEFAULT_CHAIN` from rules.py: gemini-flash-lite, gemini-flash, claude-haiku) and assert.

- [ ] **(Surface 3, on_exhaustion behavior) All providers return None, fall back to `cfg.on_exhaustion` (default "ask").** Test in `test_main.py` (`test_main_on_exhaustion_returns_ask`): mock `_call_provider` to always return None, assert stdout is the on-exhaustion decision JSON (ask), AND assert state.record_decision was called with `decision="ask"` (not deny). Use a state inspection: `state.load("s3")` after main returns, assert `consecutive_denies == 0` (since "ask" doesn't increment, and the ask-on-exhaustion is treated like any other ask).

### Anti-patterns to watch for in this phase

- **AP1 (importing classifier directly bypasses stdin parse)**: `test_main.py` MUST exercise `main()` through monkeypatched `sys.stdin`, not by calling internal helpers like `_call_provider` directly with constructed `Decision` objects. The `fake_stdin` fixture is the only correct entry point.
- **AP2 (real subprocess to gemini/claude in tests)**: NO test in this phase invokes the real `gemini` or `claude` CLIs. The provider chain is mocked at the `_call_provider` boundary (which is a Python function), not at the `subprocess.run` boundary (that level is Phase 6's concern). If a test starts importing `classifier.providers.gemini` and patching `subprocess.run`, that's leakage from Phase 6 -- Phase 7 tests work above the provider abstraction.
- **AP3 (touching real ~/.cache/aegis/)**: `test_main.py` MUST autouse a fixture that sets `state.STATE_DIR = tmp_path` and mocks `diag.emit`. The plan-source tests omit this for tests 1-3; ADD the autouse fixture so the user's real state and decisions log are never touched by unit tests.
- **AP6 (tiny snapshot fixtures)**: this phase doesn't directly test snapshot assembly, but `_call_provider` is fed a `sys_p` and `usr_p` built from the real `rules.load_config` and `rules.load_snapshot`. If the test mocks `_call_provider` and ignores its inputs (which the tests above do), AP6 doesn't apply at this layer. AP6 belongs to Phase 5's prompt tests. Note in the summary: prompt assembly in `__main__.py` is exercised against the real Phase 4 snapshot via `rules.load_snapshot()`, so a Phase 4 snapshot rebuild that breaks the prompt-builder shape would surface here.

---

## External Interfaces Consumed

This phase consumes interfaces authored by Phases 4, 5, 6, and the Anthropic-defined PreToolUse JSON. List each below with capture instructions; paste captured samples into the phase summary's "Evidence Captured" section before writing types or mocks.

- **PreToolUse JSON shape arriving on stdin (authored by Anthropic / Claude Code, documented in PROJECT_PLAN.md "Data Schemas")**
  - **Consumed by**: `classifier/__main__.py::main()` -- reads `session_id`, `cwd`, `tool_name`, `tool_input`, `transcript_path`.
  - **How to capture**: the canonical sample is in `PROJECT_PLAN.md` Data Schemas section. Phase 3 already exercised this via `tests/bash/orchestrator-cases.sh`; the harness fixtures encode the shape. Run `grep -A 5 "tool_input" tests/bash/orchestrator-cases.sh | head -40` to see real fixtures used by orchestrator tests.
  - **If not observable**: PreToolUse JSON is fully documented in the PROJECT_PLAN.md schema; use that as the canonical reference. No live capture needed.

- **Per-session state file format (`~/.cache/aegis/sessions/<id>.json`, authored by Phase 4)**
  - **Consumed by**: `classifier/__main__.py` via `state.load(session_id)`, `state.record_decision(...)`, `state.save(sess)`.
  - **How to capture**: invoke `state.save(state.SessionState(session_id="capture"))` in a Python REPL with `state.STATE_DIR=tmp` and `cat tmp/capture.json`. Or read Phase 4's `tests/python/test_state.py` fixtures.
  - **If not observable**: the dataclass definition in `classifier/state.py` is the source of truth. Read that file directly.

- **Snapshot file format (`rules/snapshot.json`, authored by Phase 4 via `claude auto-mode defaults`)**
  - **Consumed by**: `classifier/__main__.py` via `rules.load_snapshot()` -- passed into `prompt.build_system_prompt`.
  - **How to capture**: `cat rules/snapshot.json | jq 'keys'` -- expect `["allow", "soft_deny", "environment"]`. For a top-level shape sample, `cat rules/snapshot.json | jq '{allow_count: (.allow | length), deny_count: (.soft_deny | length), env_count: (.environment | length)}'`.
  - **If not observable**: if `rules/snapshot.json` doesn't exist (Phase 4 didn't run yet), the phase is blocked. Verify Phase 4 completion before starting this phase.

- **Provider chain output text shape (authored by Phase 6, parsed by `decision.parse_response`)**
  - **Consumed by**: `_call_provider` returns `str | None`; the body of `main()` immediately passes successful return values through `decision.parse_response`.
  - **How to capture**: invoke `gemini -m gemini-3.1-flash-lite-preview -p "Reply with this JSON exactly: {\"decision\":\"allow\",\"reason\":\"test\"}"` once and capture the raw stdout. Note: real models often wrap JSON in code fences (` ```json\n...\n``` `) or add prose. Phase 5's `decision.parse_response` is responsible for stripping; this phase consumes the raw text and trusts the parser. Document the captured raw text in the summary even though the test mocks bypass it.
  - **If not observable**: if `gemini` CLI is not authenticated in this environment, defer real shape capture to Phase 9's live smoke. Use Phase 6's mock fixtures as the canonical raw-text shape for Phase 7's tests.

- **`Config` and `ProviderSpec` dataclass shape (authored by Phase 4)**
  - **Consumed by**: `classifier/__main__.py` reads `cfg.classifier_chain`, `cfg.on_exhaustion`, `cfg.consecutive_deny_limit`, `cfg.total_deny_limit`, `cfg.last_user_messages`, `cfg.include_claude_md`, `cfg.diag_path`.
  - **How to capture**: `python3 -c "from classifier.rules import load_config; cfg = load_config(None); print(cfg)"` to see the merged default Config. Paste the output in the summary.
  - **If not observable**: read `classifier/rules.py` directly for the dataclass field list and defaults.

---

## Notes

- The `d: decision.Decision | None = None` initializer in `main()` is a defensive add over the plan-source listing. Without it, type checkers complain on the `if raw_response is None or d is None` line. Functionally equivalent.
- The orchestrator modification adds a side effect (~/.cache/aegis/decisions.jsonl writes) that DID NOT exist before. Phase 3's `orchestrator-cases.sh` does not assert against this file, so the existing tests still pass. After Phase 7, a future test could verify the diag-row schema for each layer, but that's optional.
- Latency measurement: `t0 = time.time()` is set at the very top of `main()` (right after entering the function). `latency_ms` is `int((time.time() - t0) * 1000)`. This includes stdin read, JSON parse, state load, rules load, snapshot load, transcript parse, prompt build, provider chain walk, parse, state save -- the full critical path. That's the right number to measure.
- The bash `diag_emit` always sets `latency_ms=0`. This is intentional: the deterministic layers complete in milliseconds and measuring them through a python3 heredoc would pay more startup cost than the layer itself takes. The diag stream is for decisions; the latency field for deterministic rows is just a placeholder.
- The disabled-session early-exit returns 0 with empty stdout. If a future enhancement wants to log disabled-session events too, that's a separate diag layer (e.g., `layer="disabled-fallthrough"`). Not in scope for this phase.
- Repair attempt is single-shot and same-provider only. We do NOT propagate the repaired user prompt to subsequent providers in the chain -- each provider gets the original `usr_p`. This is by design: a repair is "give this provider one more chance with explicit instructions"; if that doesn't work, the next provider gets a clean shot at the original prompt.
- `cfg.on_exhaustion` legal values are `"ask"`, `"allow"`, `"deny"`. The Phase 4 `Config` dataclass defaults to `"ask"`. If a future user puts an invalid value in their TOML and `Config` doesn't validate, the synthetic `Decision(decision=cfg.on_exhaustion, ...)` is malformed, and `decision.to_hook_output(d)` may emit garbage. Phase 4 owns config validation; this phase trusts it. Document this assumption in the summary.
- After this phase, the project's success criterion "Classifier slow path returns `{decision, reason}` JSON parsed into Claude Code hook output, with retry across the configured chain" from the PROJECT_PLAN.md is met. The "End-to-end smoke against the hook with real `gemini` invocation produces a valid decision" criterion is Phase 9's responsibility.
