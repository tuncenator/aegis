# Phase 04: Classifier state + rules

**Feature**: project-initiation
**Estimated Context Budget**: ~65k tokens

**Difficulty**: medium
**Visual**: no
**Functional**: no

**Execution Mode**: sequential
**Batch**: 4

---

## Objective

Implement the two foundational Python modules of the classifier package:

1. `classifier/state.py` -- per-session JSON state with deny counters and auto-pause logic.
2. `classifier/rules.py` -- layered TOML config loader (built-in defaults < global < project) plus snapshot loader for the vendored `claude auto-mode defaults` output.

Both modules are pure stdlib, fully unit-tested via pytest with `tmp_path` + `monkeypatch`, and consumed by Phases 5, 6, 7, 8 (transcript/prompt/decision/main/CLI). Phase 4 adds no user-facing surface; verification is pytest-only.

This phase also vendors the initial `rules/snapshot.json` and `rules/snapshot.meta.json` artifacts (one-time fetch via `claude auto-mode defaults`).

---

## Deliverables

1. **`classifier/state.py`** -- `SessionState` dataclass + `load`, `save`, `record_decision` functions; module constant `STATE_DIR`.
2. **`classifier/rules.py`** -- `Snapshot`, `ProviderSpec`, `Config` dataclasses + `load_config`, `load_snapshot`, `snapshot_age_days` functions; module constants `SNAPSHOT_PATH`, `SNAPSHOT_META_PATH`, `GLOBAL_CONFIG_PATH`; `_DEFAULT_CHAIN` private list.
3. **`rules/snapshot.json`** -- vendored output of `claude auto-mode defaults` (or placeholder shape if the CLI subcommand is unavailable).
4. **`rules/snapshot.meta.json`** -- `{fetched_at, source, ttl_days}` metadata for the snapshot.
5. **`tests/python/test_state.py`** -- 7 tests covering load defaults, round-trip, allow-resets-consecutive, deny-increments, consecutive-limit pause, total-limit pause, corrupt-file recovery.
6. **`tests/python/test_rules.py`** -- 5 tests covering snapshot load, snapshot age, missing-global-defaults, global-only override, project-overrides-global.

---

## Detailed Requirements

### Implementation order (mandatory)

This phase is medium difficulty, routes to spark-coder-easy (Sonnet 4.6). Treat the spec as literal. Follow this exact sequence:

1. **State module (RED-GREEN-COMMIT)**
   - 1a. Write `tests/python/test_state.py` verbatim from the listing below.
   - 1b. Run `python3 -m pytest tests/python/test_state.py -v`. Expect ImportError or AttributeError on `classifier.state`. This is RED.
   - 1c. Write `classifier/state.py` verbatim from the listing below.
   - 1d. Run `python3 -m pytest tests/python/test_state.py -v`. Expect 7 passed. This is GREEN.
   - 1e. Commit: `git add classifier/state.py tests/python/test_state.py && git commit -m "Add classifier state module with deny counters"`.

2. **Snapshot vendoring**
   - 2a. `mkdir -p rules`
   - 2b. Try to fetch the real Anthropic defaults: `claude auto-mode defaults > rules/snapshot.json`
   - 2c. Validate the output. If it is valid JSON with at least one of the keys `allow`, `soft_deny`, `environment`, keep it. Validation command: `python3 -c "import json; d=json.load(open('rules/snapshot.json')); assert isinstance(d, dict) and ({'allow','soft_deny','environment'} & set(d.keys())), 'invalid'"`.
   - 2d. If validation fails (older `claude` CLI without `auto-mode defaults` subcommand, or empty/non-JSON output), fall back to writing the placeholder shape:
     ```json
     {"allow": [], "soft_deny": [], "environment": []}
     ```
     Document this fact in the phase summary's "Notes" section and mention that `bin/aegis refresh-rules` (Phase 8) can refresh later.
   - 2e. Write `rules/snapshot.meta.json` using the current UTC ISO 8601 timestamp:
     ```bash
     printf '{\n  "fetched_at": "%s",\n  "source": "claude auto-mode defaults",\n  "ttl_days": 14\n}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > rules/snapshot.meta.json
     ```
   - 2f. Verify both files parse: `python3 -c "import json; json.load(open('rules/snapshot.json')); json.load(open('rules/snapshot.meta.json'))"`.

3. **Rules module (RED-GREEN-COMMIT)**
   - 3a. Write `tests/python/test_rules.py` verbatim from the listing below.
   - 3b. Run `python3 -m pytest tests/python/test_rules.py -v`. Expect ImportError on `classifier.rules`. RED.
   - 3c. Write `classifier/rules.py` verbatim from the listing below.
   - 3d. Run `python3 -m pytest tests/python/test_rules.py -v`. Expect 5 passed. GREEN.
   - 3e. Commit: `git add classifier/rules.py rules/ tests/python/test_rules.py && git commit -m "Add rules + config loader with snapshot management"`.

4. **Full Phase-4 test suite**
   - 4a. Run `python3 -m pytest tests/python/ -v` to confirm both new modules and any pre-existing Phase 1-3 tests still pass.

### File 1: `classifier/state.py`

Verbatim source listing (no deviations):

```python
"""Per-session state: enabled flag, deny counters, pause reason.

State is persisted to ~/.cache/aegis/sessions/<session_id>.json so toggles
from CLI / slash commands and counter increments from the classifier loop
share one source of truth.
"""
from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path

STATE_DIR = Path.home() / ".cache" / "aegis" / "sessions"


@dataclass
class SessionState:
    session_id: str
    enabled: bool = True
    consecutive_denies: int = 0
    total_denies: int = 0
    paused_reason: str | None = None
    last_decision_at: str | None = None


def _path(session_id: str) -> Path:
    return STATE_DIR / f"{session_id}.json"


def load(session_id: str) -> SessionState:
    p = _path(session_id)
    if not p.exists():
        return SessionState(session_id=session_id)
    try:
        data = json.loads(p.read_text())
        return SessionState(**{**asdict(SessionState(session_id=session_id)), **data})
    except (json.JSONDecodeError, OSError, TypeError):
        # Corrupt or unreadable: fall back to defaults and rewrite on next save.
        return SessionState(session_id=session_id)


def save(s: SessionState) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    s.last_decision_at = datetime.now(timezone.utc).isoformat()
    tmp = _path(s.session_id).with_suffix(".json.tmp")
    tmp.write_text(json.dumps(asdict(s), indent=2))
    os.replace(tmp, _path(s.session_id))


def record_decision(
    s: SessionState,
    decision: str,
    consecutive_limit: int = 3,
    total_limit: int = 20,
) -> None:
    """Update counters and optionally trip auto-pause. Caller must save() after."""
    if decision == "deny":
        s.consecutive_denies += 1
        s.total_denies += 1
        if s.consecutive_denies >= consecutive_limit:
            s.enabled = False
            s.paused_reason = "consecutive_deny_limit"
        elif s.total_denies >= total_limit:
            s.enabled = False
            s.paused_reason = "total_deny_limit"
    elif decision == "allow":
        s.consecutive_denies = 0
```

Key invariants for the coder:
- The `field` import from dataclasses is unused in this file; leave it in to match the listing exactly (it does not affect behavior). If the project's lint policy strictly forbids unused imports, drop it -- but the test code does not exercise it either way.
- `STATE_DIR` is a module-level `Path` object. Tests monkeypatch this attribute. Do NOT compute the path inside `_path` or `load`/`save` -- always reference `STATE_DIR` so monkeypatch works.
- `record_decision` does NOT call `save`. The caller saves afterwards.
- Corrupt JSON is recovered silently; the test `test_corrupt_file_is_recovered` confirms this.
- `last_decision_at` is set inside `save`, never inside `record_decision` or `load`.
- Atomic write contract: write to `<id>.json.tmp` first, then `os.replace`. Using `Path.with_suffix(".json.tmp")` on a path that already ends in `.json` produces `<id>.json.tmp` (Python's `with_suffix` replaces the LAST suffix; here the path's `.json` becomes `.json.tmp`).

### File 2: `tests/python/test_state.py`

Verbatim source listing:

```python
import json
import time
from pathlib import Path

import pytest

from classifier import state


@pytest.fixture
def tmp_state_dir(tmp_path, monkeypatch):
    monkeypatch.setattr(state, "STATE_DIR", tmp_path)
    return tmp_path


def test_load_missing_returns_default(tmp_state_dir):
    s = state.load("session-1")
    assert s.session_id == "session-1"
    assert s.enabled is True
    assert s.consecutive_denies == 0
    assert s.total_denies == 0
    assert s.paused_reason is None


def test_save_then_load_round_trip(tmp_state_dir):
    s = state.SessionState(session_id="abc", enabled=False, consecutive_denies=2,
                            total_denies=5, paused_reason="manual")
    state.save(s)
    loaded = state.load("abc")
    assert loaded == s


def test_record_decision_allow_resets_consecutive(tmp_state_dir):
    s = state.load("s1")
    s.consecutive_denies = 2
    state.record_decision(s, "allow")
    assert s.consecutive_denies == 0


def test_record_decision_deny_increments(tmp_state_dir):
    s = state.load("s1")
    state.record_decision(s, "deny")
    assert s.consecutive_denies == 1
    assert s.total_denies == 1


def test_record_decision_deny_pauses_at_consecutive_limit(tmp_state_dir):
    s = state.load("s1")
    for _ in range(3):
        state.record_decision(s, "deny", consecutive_limit=3, total_limit=20)
    assert s.enabled is False
    assert s.paused_reason == "consecutive_deny_limit"


def test_record_decision_deny_pauses_at_total_limit(tmp_state_dir):
    s = state.load("s1")
    s.total_denies = 19
    state.record_decision(s, "deny", consecutive_limit=999, total_limit=20)
    assert s.enabled is False
    assert s.paused_reason == "total_deny_limit"


def test_corrupt_file_is_recovered(tmp_state_dir):
    p = tmp_state_dir / "session-bad.json"
    p.write_text("{ this is not json")
    s = state.load("session-bad")
    assert s.session_id == "session-bad"
    assert s.enabled is True
```

Notes for the coder:
- The `time` import is unused; leave it to match the listing.
- The `Path` import is unused; leave it.
- The `tmp_state_dir` fixture monkeypatches `state.STATE_DIR` to `tmp_path`. This is the canonical pattern for state tests.
- `test_save_then_load_round_trip` will fail if `save` mutates `last_decision_at` to a non-equal value vs. `loaded`. This is fine because both `s` (in-memory) and `loaded` (read from disk) end up with the same touched value: `save` touches `s.last_decision_at` before serializing, and `load` deserializes back into a `SessionState` with that same value, so `loaded == s` (dataclass equality compares all fields including `last_decision_at`).

### File 3: `classifier/rules.py`

Verbatim source listing:

```python
"""Configuration and rule snapshot loader.

Layers:
  1. Built-in defaults (this module).
  2. Global config: ~/.config/aegis/aegis.toml
  3. Project config: <cwd>/.aegis/aegis.toml

Project values deep-merge over global, which deep-merges over defaults.
Snapshot lives at <repo>/rules/snapshot.json with metadata at snapshot.meta.json.
"""
from __future__ import annotations

import json
import tomllib
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SNAPSHOT_PATH = REPO_ROOT / "rules" / "snapshot.json"
SNAPSHOT_META_PATH = REPO_ROOT / "rules" / "snapshot.meta.json"
GLOBAL_CONFIG_PATH = Path.home() / ".config" / "aegis" / "aegis.toml"


@dataclass
class Snapshot:
    allow: list[str]
    soft_deny: list[str]
    environment: list[str]


@dataclass
class ProviderSpec:
    provider: str
    model: str
    retries: int = 1
    timeout_s: int = 8


@dataclass
class Config:
    classifier_chain: list[ProviderSpec] = field(default_factory=list)
    on_exhaustion: str = "ask"
    consecutive_deny_limit: int = 3
    total_deny_limit: int = 20
    snapshot_ttl_days: int = 14
    last_user_messages: int = 10
    include_claude_md: bool = True
    claude_md_max_tokens: int = 4000
    trusted_orgs: list[str] = field(default_factory=list)
    trusted_domains: list[str] = field(default_factory=list)
    trusted_buckets: list[str] = field(default_factory=list)
    trusted_services: list[str] = field(default_factory=list)
    diag_path: str = "~/.cache/aegis/decisions.jsonl"
    log_level: str = "info"


_DEFAULT_CHAIN = [
    ProviderSpec("gemini", "gemini-3.1-flash-lite-preview", retries=2, timeout_s=8),
    ProviderSpec("gemini", "gemini-3-flash-preview", retries=1, timeout_s=8),
    ProviderSpec("claude", "claude-haiku-4-5", retries=1, timeout_s=8),
]


def _read_toml(p: Path) -> dict:
    if not p.exists():
        return {}
    try:
        return tomllib.loads(p.read_text())
    except (tomllib.TOMLDecodeError, OSError):
        return {}


def _merge_chain(raw: list[dict]) -> list[ProviderSpec]:
    out = []
    for entry in raw:
        out.append(ProviderSpec(
            provider=entry["provider"],
            model=entry["model"],
            retries=entry.get("retries", 1),
            timeout_s=entry.get("timeout_s", 8),
        ))
    return out


def load_config(project_dir: str | None) -> Config:
    cfg = Config(classifier_chain=list(_DEFAULT_CHAIN))
    layers = [_read_toml(GLOBAL_CONFIG_PATH)]
    if project_dir:
        layers.append(_read_toml(Path(project_dir) / ".aegis" / "aegis.toml"))
    for raw in layers:
        if not raw:
            continue
        cls = raw.get("classifier", {})
        if "chain" in cls:
            cfg.classifier_chain = _merge_chain(cls["chain"])
        if "on_exhaustion" in cls:
            cfg.on_exhaustion = cls["on_exhaustion"]

        cnt = raw.get("counters", {})
        cfg.consecutive_deny_limit = cnt.get("consecutive_deny_limit", cfg.consecutive_deny_limit)
        cfg.total_deny_limit = cnt.get("total_deny_limit", cfg.total_deny_limit)

        rls = raw.get("rules", {})
        cfg.snapshot_ttl_days = rls.get("snapshot_ttl_days", cfg.snapshot_ttl_days)

        ctx = raw.get("context", {})
        cfg.last_user_messages = ctx.get("last_user_messages", cfg.last_user_messages)
        cfg.include_claude_md = ctx.get("include_claude_md", cfg.include_claude_md)
        cfg.claude_md_max_tokens = ctx.get("claude_md_max_tokens", cfg.claude_md_max_tokens)

        env = raw.get("environment", {})
        for k in ("trusted_orgs", "trusted_domains", "trusted_buckets", "trusted_services"):
            if k in env:
                setattr(cfg, k, env[k])

        log = raw.get("logging", {})
        cfg.diag_path = log.get("diag_path", cfg.diag_path)
        cfg.log_level = log.get("level", cfg.log_level)

    return cfg


def load_snapshot() -> Snapshot:
    raw = json.loads(SNAPSHOT_PATH.read_text())
    return Snapshot(
        allow=raw.get("allow", []),
        soft_deny=raw.get("soft_deny", []),
        environment=raw.get("environment", []),
    )


def snapshot_age_days() -> float:
    if not SNAPSHOT_META_PATH.exists():
        return float("inf")
    meta = json.loads(SNAPSHOT_META_PATH.read_text())
    fetched = datetime.fromisoformat(meta["fetched_at"].replace("Z", "+00:00"))
    return (datetime.now(timezone.utc) - fetched).total_seconds() / 86400
```

Key invariants for the coder:
- `REPO_ROOT` resolves to `<aegis_repo>/` (one level up from `classifier/`). This is computed at import time. Tests monkeypatch the derived `SNAPSHOT_PATH` / `SNAPSHOT_META_PATH` / `GLOBAL_CONFIG_PATH` constants, NOT `REPO_ROOT` itself.
- `Snapshot.environment` is typed as `list[str]` per the listing. The on-disk schema is more flexible (could include dicts), but for v1 the loader simply forwards whatever JSON list is there. The dataclass annotation does not enforce element type.
- Layer merge semantics:
  - **Shallow per top-level key**: each key (`classifier`, `counters`, `rules`, `context`, `environment`, `logging`) is processed independently per layer.
  - `classifier.chain` is REPLACED (not appended) when present in a layer.
  - `trusted_*` lists are REPLACED (not appended) when present in a layer.
  - Numeric/string fields use `cnt.get(key, cfg.field)` so absent keys preserve the prior layer's value.
- `load_snapshot` does no caching. Each call re-reads.
- `snapshot_age_days` returns `inf` when meta is missing (signals "definitely refresh"). The fromisoformat hack `.replace("Z", "+00:00")` is required for Python <3.11 compatibility but is harmless on 3.11+; keep it.

### File 4: `tests/python/test_rules.py`

Verbatim source listing:

```python
import json
import tomllib
from pathlib import Path

import pytest

from classifier import rules


@pytest.fixture
def tmp_repo(tmp_path, monkeypatch):
    snap = {"allow": ["A1", "A2"], "soft_deny": ["D1"], "environment": []}
    (tmp_path / "snapshot.json").write_text(json.dumps(snap))
    (tmp_path / "snapshot.meta.json").write_text(json.dumps({
        "fetched_at": "2026-04-30T00:00:00Z",
        "source": "claude auto-mode defaults",
        "ttl_days": 14,
    }))
    monkeypatch.setattr(rules, "SNAPSHOT_PATH", tmp_path / "snapshot.json")
    monkeypatch.setattr(rules, "SNAPSHOT_META_PATH", tmp_path / "snapshot.meta.json")
    return tmp_path


def test_load_snapshot(tmp_repo):
    snap = rules.load_snapshot()
    assert "A1" in snap.allow
    assert "D1" in snap.soft_deny


def test_snapshot_age_days(tmp_repo):
    age = rules.snapshot_age_days()
    assert age >= 0


def test_load_global_config_missing_returns_defaults(tmp_path, monkeypatch):
    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", tmp_path / "missing.toml")
    cfg = rules.load_config(project_dir=None)
    assert cfg.classifier_chain
    assert cfg.consecutive_deny_limit == 3
    assert cfg.total_deny_limit == 20
    assert cfg.on_exhaustion == "ask"


def test_load_config_global_only(tmp_path, monkeypatch):
    g = tmp_path / "aegis.toml"
    g.write_text("""
[classifier]
chain = [
  { provider = "gemini", model = "gemini-3.1-flash-lite-preview", retries = 2, timeout_s = 8 },
]
on_exhaustion = "deny"

[counters]
consecutive_deny_limit = 5
total_deny_limit = 50

[environment]
trusted_orgs = ["MYORG"]
trusted_domains = ["example.com"]
""")
    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", g)
    cfg = rules.load_config(project_dir=None)
    assert cfg.consecutive_deny_limit == 5
    assert cfg.total_deny_limit == 50
    assert cfg.on_exhaustion == "deny"
    assert cfg.trusted_orgs == ["MYORG"]


def test_load_config_project_overrides_global(tmp_path, monkeypatch):
    g = tmp_path / "global.toml"
    g.write_text('[counters]\nconsecutive_deny_limit = 5\ntotal_deny_limit = 50\n')
    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", g)
    proj = tmp_path / "proj"
    (proj / ".aegis").mkdir(parents=True)
    (proj / ".aegis" / "aegis.toml").write_text(
        '[counters]\nconsecutive_deny_limit = 10\n'
    )
    cfg = rules.load_config(project_dir=str(proj))
    assert cfg.consecutive_deny_limit == 10  # project override
    assert cfg.total_deny_limit == 50  # inherited from global
```

Notes:
- The `tomllib` import in the test file is unused; leave it to match the listing.
- The `Path` import is unused; leave it.
- `test_snapshot_age_days` writes a meta with `fetched_at = "2026-04-30T00:00:00Z"`, and asserts `age >= 0`. Today's date is 2026-04-30; the actual age is on the order of fractions of a day or larger (depending on when the test runs). The assertion holds.

### Edge cases and invariants

- **Concurrent save races**: `os.replace` is atomic on POSIX. No locking required.
- **Empty session_id**: not validated. `state.load("")` is legal and produces a SessionState with `session_id=""`. The test corpus does not exercise this; do not add validation.
- **State file with extra keys**: the `**asdict(SessionState(session_id=...)) , **data` merge means extras silently override defaults. If the file contains a key not on the dataclass (e.g. legacy field), `SessionState(**merged)` raises `TypeError` -- which is caught by the `except (json.JSONDecodeError, OSError, TypeError)` clause and fallback returns defaults. So unknown keys self-heal on next save.
- **Missing keys in state file**: if older state files have fewer keys than the current dataclass (forward-compat), the merge with `asdict(SessionState(session_id=...))` provides defaults for the missing fields. Test `test_corrupt_file_is_recovered` is the closest coverage; the missing-keys case is implicit.
- **TOML decoding errors**: `_read_toml` returns `{}` on `TOMLDecodeError` or `OSError`. Tests do not exercise this branch but it must not crash.
- **Project config without global**: `load_config(project_dir=...)` reads global first (gets `{}` if missing), then project. The first layer can be empty.
- **Both files missing**: returns the defaults `Config(classifier_chain=list(_DEFAULT_CHAIN))`.
- **`classifier.chain` deep-merge semantics**: The brief states "classifier.chain is replaced (not appended) when present". The implementation (`if "chain" in cls: cfg.classifier_chain = _merge_chain(cls["chain"])`) matches.
- **`trusted_*` lists**: same replace-on-presence semantic. Implemented via the `for k in (...)` loop.

---

## Dependencies

**Requires**:
- Phase 1: provides `pyproject.toml` (pytest config), `classifier/log.py` (logging module already exists; not used in this phase but the package marker `classifier/__init__.py` must exist).
- Phase 2: provides `tests/bash/run.sh` and corpora (not used in this phase, but they must already exist in the repo).
- Phase 3: provides `classifier/__init__.py` (empty package marker), `classifier/__main__.py` (placeholder), `tests/python/conftest.py` (sys.path setup so `from classifier import ...` works).

**Enables**:
- Phase 5: `classifier/transcript.py`, `classifier/prompt.py`, `classifier/decision.py` import `Snapshot`, `Config`, `ProviderSpec` from `rules`.
- Phase 6: `classifier/providers/*` import `ProviderSpec` from `rules`.
- Phase 7: `classifier/__main__.py` (full version) calls `state.load`, `state.save`, `state.record_decision`, `rules.load_config`, `rules.load_snapshot`, `rules.snapshot_age_days`.
- Phase 8: `bin/aegis` imports `state` directly (uses `AEGIS_STATE_DIR` env var to redirect `state.STATE_DIR`).

---

## Completion Criteria

- [ ] `classifier/state.py` exists and matches the verbatim listing.
- [ ] `classifier/rules.py` exists and matches the verbatim listing.
- [ ] `rules/snapshot.json` exists. Content is either real `claude auto-mode defaults` output OR the `{"allow":[],"soft_deny":[],"environment":[]}` placeholder (and the placeholder choice is documented in the phase summary).
- [ ] `rules/snapshot.meta.json` exists with `{fetched_at, source, ttl_days}` fields.
- [ ] `tests/python/test_state.py` exists and contains all 7 tests verbatim.
- [ ] `tests/python/test_rules.py` exists and contains all 5 tests verbatim.
- [ ] `python3 -m pytest tests/python/test_state.py -v` returns 7 passed.
- [ ] `python3 -m pytest tests/python/test_rules.py -v` returns 5 passed.
- [ ] `python3 -m pytest tests/python/ -v` returns 12+ passed (depending on whether Phase 3 left any tests).
- [ ] Two commits exist:
  - "Add classifier state module with deny counters" (state.py + test_state.py)
  - "Add rules + config loader with snapshot management" (rules.py + rules/ + test_rules.py)
- [ ] No real `~/.cache/aegis/` or `~/.config/aegis/` paths are touched by any test (verify by running tests with `ls ~/.cache/aegis 2>/dev/null` before and after; the directory listing should be unchanged or non-existent).
- [ ] `git status` shows no uncommitted changes after both commits.

---

## Testing Requirements

### Test commands

```bash
# State tests only
python3 -m pytest tests/python/test_state.py -v

# Rules tests only
python3 -m pytest tests/python/test_rules.py -v

# All Python tests (including any from Phase 1-3)
python3 -m pytest tests/python/ -v

# Confirm hermetic behavior: tests must not touch real cache / config dirs
# Before:
ls ~/.cache/aegis 2>/dev/null && echo "PRE: aegis cache exists" || echo "PRE: aegis cache absent"
# Run tests:
python3 -m pytest tests/python/test_state.py tests/python/test_rules.py -v
# After:
ls ~/.cache/aegis 2>/dev/null && echo "POST: aegis cache exists" || echo "POST: aegis cache absent"
# PRE and POST states must match.
```

### Expected results

- `test_state.py`: 7 passed.
- `test_rules.py`: 5 passed.
- No `__pycache__` directories should appear under `~/.cache/aegis/` or `~/.config/aegis/`.
- No `~/.cache/aegis/sessions/*.json` files created by the test run.

### Test isolation invariants

- All state tests use the `tmp_state_dir` fixture which calls `monkeypatch.setattr(state, "STATE_DIR", tmp_path)`.
- All rules tests that touch the global config monkeypatch `rules.GLOBAL_CONFIG_PATH`.
- All rules tests that read snapshots monkeypatch both `rules.SNAPSHOT_PATH` and `rules.SNAPSHOT_META_PATH`.
- Tests must NEVER call `state.save` or `rules.load_snapshot` without monkeypatch active. The provided test code follows this.

### Anti-patterns to avoid

- AP3 from FUNCTIONAL_QA_STRATEGY.md: "Tests that touch real `~/.cache/aegis/` or `~/.config/aegis/`". Every state and rules test in this phase must be hermetic via monkeypatch.

---

## External Interfaces Consumed

- **`claude auto-mode defaults` JSON output shape**
  - **Consumed by**: `rules/snapshot.json` (this phase commits the captured output) and indirectly by `classifier/rules.py::load_snapshot` (Phase 4) and `classifier/prompt.py::build_system_prompt` (Phase 5, which embeds the allow/soft_deny lists into the system prompt).
  - **How to capture**:
    ```bash
    claude auto-mode defaults | head -c 4096
    claude auto-mode defaults | python3 -c "import json,sys; d=json.load(sys.stdin); print('keys:', sorted(d.keys())); print('allow_len:', len(d.get('allow',[]))); print('soft_deny_len:', len(d.get('soft_deny',[]))); print('env_len:', len(d.get('environment',[])))"
    ```
    Paste the captured shape (top-level keys + sample of each list) into the phase summary's "Evidence Captured" section before writing the snapshot file. Verify that the JSON has at least one of `allow`, `soft_deny`, `environment`.
  - **If not observable**: the user's `claude` CLI may not have the `auto-mode defaults` subcommand (older versions). In that case:
    1. Document this in the phase summary's "Evidence Captured" section: paste the exact error or empty output from `claude auto-mode defaults`.
    2. Write the placeholder `{"allow": [], "soft_deny": [], "environment": []}` to `rules/snapshot.json` instead.
    3. Note that Phase 8 `bin/aegis refresh-rules` will retry the fetch once the CLI is upgraded.
    4. Continue with the phase. The placeholder is sufficient for unit tests (which use `tmp_repo` fixtures with synthetic snapshots) and for downstream phases (which read whatever shape is on disk).

---

## Notes

- **Stdlib only**: Python 3.11+ (uses `tomllib`). No external pip dependencies.
- **Forward compatibility for state files**: the `**asdict(default), **data` merge ensures older state files with fewer keys still load without raising. New keys added in v1.x will be initialized to defaults, then overwritten on next save.
- **`field` import in `state.py`**: present in the listing but unused. Keep it for verbatim fidelity unless lint rules forbid; the listing in `docs/superpowers/plans/2026-04-30-aegis.md` Task 8 Step 2 includes it.
- **`tomllib` is stdlib**: do not add a `tomli` shim. Phase 1 already pins Python 3.11+ in `pyproject.toml`.
- **Python typing style**: `str | None` (PEP 604) requires Python 3.10+; combined with the `from __future__ import annotations` header it is safe under 3.9 too, but the project targets 3.11+ so this is moot.
- **Dataclass equality in `test_save_then_load_round_trip`**: `loaded == s` compares all fields. `save` mutates `s.last_decision_at`; `load` reads it back. Both sides equal; assertion holds.
- **Phase 5/6 import pattern**: they use `from classifier.rules import Config, ProviderSpec, Snapshot`. Do not rename these dataclasses or move them out of `rules.py`.
- **Phase 8 `AEGIS_STATE_DIR` env var**: Phase 8 will read `os.environ.get("AEGIS_STATE_DIR")` and set `state.STATE_DIR = Path(value)` before any state operation. This is NOT this phase's responsibility; just be aware the contract exists so tests in Phase 8 can run hermetically.
- **No `__init__.py` for `rules/` directory**: `rules/` is a data directory, not a Python package. Just `snapshot.json` and `snapshot.meta.json`. Do not place an `__init__.py` inside.
- **Git hygiene**: commit `state.py` + `test_state.py` together first; commit `rules.py` + `rules/` + `test_rules.py` together second. Two commits, in that order. The commit messages are specified verbatim above.
- **Verbatim fidelity matters**: when in doubt, copy character-for-character from the listings in this plan. The plan listings are the source of truth derived from `docs/superpowers/plans/2026-04-30-aegis.md` Tasks 8-9 (lines 925-1377).
