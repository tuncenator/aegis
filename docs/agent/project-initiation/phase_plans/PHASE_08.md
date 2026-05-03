# Phase 8: bin/aegis CLI + slash commands

**Feature**: project-initiation
**Estimated Context Budget**: ~50k tokens

**Difficulty**: easy
**Visual**: no
**Functional**: yes

**Execution Mode**: sequential
**Batch**: 7

---

## Objective

Build the user-facing toggle surfaces for Aegis: the `bin/aegis` Python CLI (`status`, `on`, `off`, `refresh-rules`) and the three Claude Code slash command files (`/aegis-on`, `/aegis-off`, `/aegis-status`) that wrap the CLI. The CLI imports `classifier.state` (authored by Phase 4) and supports an `AEGIS_STATE_DIR` env override for hermetic tests. The plugin manifest from Phase 1 already references the three command files; this phase creates them.

---

## Deliverables

1. `tests/python/test_cli.py` -- 3 pytest tests against `bin/aegis` invoked as a subprocess with `AEGIS_STATE_DIR` redirected to `tmp_path`.
2. `bin/aegis` -- Python script with shebang, executable (`chmod +x`), argparse subcommands `status`, `on`, `off`, `refresh-rules`. Imports `classifier.state` and honors `AEGIS_STATE_DIR` env.
3. `commands/aegis-on.md` -- slash command wrapper (YAML frontmatter + `!`-prefixed shell line).
4. `commands/aegis-off.md` -- slash command wrapper.
5. `commands/aegis-status.md` -- slash command wrapper.

---

## Detailed Requirements

### Implementation order (strict)

This is a TDD phase. Follow the order exactly:

1. Write `tests/python/test_cli.py` (RED -- tests will fail because `bin/aegis` does not exist yet).
2. Run `python3 -m pytest tests/python/test_cli.py -v` and confirm failure.
3. Write `bin/aegis`.
4. `chmod +x bin/aegis`.
5. Run `python3 -m pytest tests/python/test_cli.py -v` and confirm 3 passed (GREEN).
6. Smoke-run `bin/aegis --help` and `bin/aegis status` (with no `AEGIS_STATE_DIR` set, the latter prints "no active session" against the user's real `~/.cache/aegis/sessions/` if it has files, otherwise "no active session"; do NOT pollute real state -- if you want to be safe, run with `AEGIS_STATE_DIR=/tmp/aegis-smoke bin/aegis status`).
7. Commit (`git add bin/aegis tests/python/test_cli.py && git commit -m "Add aegis CLI: status / on / off / refresh-rules"`).
8. Create the three `commands/aegis-*.md` files.
9. Run `jq . .claude-plugin/plugin.json` and confirm the `commands` array references all three .md files.
10. Commit (`git add commands/ && git commit -m "Add aegis-on / aegis-off / aegis-status slash commands"`).

Do NOT modify `.claude-plugin/plugin.json` -- Phase 1 already wrote the references. This phase only creates the .md files those references point at.

### File 1: `tests/python/test_cli.py`

Write this file verbatim (all 3 tests). It uses `subprocess.run` to invoke `bin/aegis` as a real subprocess, with `AEGIS_STATE_DIR` redirected to `tmp_path`. This guarantees the tests never touch the user's real `~/.cache/aegis/sessions/` (anti-pattern AP3).

```python
import json
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent.parent
CLI = REPO / "bin" / "aegis"


def _run(*args, env=None):
    return subprocess.run([str(CLI), *args], capture_output=True, text=True, env=env)


@pytest.fixture
def isolated_state(tmp_path, monkeypatch):
    monkeypatch.setenv("AEGIS_STATE_DIR", str(tmp_path))
    return tmp_path


def test_status_no_session_returns_message(isolated_state, monkeypatch):
    r = _run("status")
    assert r.returncode == 0
    assert "no session" in r.stdout.lower() or "no active" in r.stdout.lower()


def test_off_then_on_round_trip(isolated_state, monkeypatch):
    monkeypatch.setenv("AEGIS_STATE_DIR", str(isolated_state))
    r = _run("off", "--session", "s1", env={**__import__("os").environ, "AEGIS_STATE_DIR": str(isolated_state)})
    assert r.returncode == 0
    state_file = isolated_state / "s1.json"
    assert state_file.exists()
    obj = json.loads(state_file.read_text())
    assert obj["enabled"] is False

    r = _run("on", "--session", "s1", env={**__import__("os").environ, "AEGIS_STATE_DIR": str(isolated_state)})
    assert r.returncode == 0
    obj = json.loads(state_file.read_text())
    assert obj["enabled"] is True
    assert obj["consecutive_denies"] == 0


def test_status_specific_session(isolated_state, monkeypatch):
    state_file = isolated_state / "s2.json"
    state_file.write_text(json.dumps({
        "session_id": "s2", "enabled": True, "consecutive_denies": 1,
        "total_denies": 3, "paused_reason": None, "last_decision_at": "2026-04-30T00:00:00Z",
    }))
    r = _run("status", "--session", "s2",
             env={**__import__("os").environ, "AEGIS_STATE_DIR": str(isolated_state)})
    assert r.returncode == 0
    assert "enabled" in r.stdout.lower()
    assert "s2" in r.stdout
```

Notes on the tests:
- `REPO = Path(__file__).resolve().parent.parent.parent` resolves to the project root (`/home/tunc/Sync/Programs/aegis`).
- `CLI = REPO / "bin" / "aegis"` is the absolute path to the script. The subprocess invocation requires `bin/aegis` to be `chmod +x` AND to have a `#!/usr/bin/env python3` shebang.
- The first test passes `env=None` (inherits the test process env, which the `monkeypatch.setenv` fixture has populated with `AEGIS_STATE_DIR`). The second and third tests pass an explicit `env={...}` dict because they need the merged result of the parent env plus the redirect; the explicit dict pattern is required when subprocess needs the redirect AND `PATH` from the parent.
- The `_run` helper does NOT pass `env` by default. Test 1 relies on `monkeypatch.setenv` + the implicit env inheritance; tests 2 and 3 pass `env=...` explicitly. Do NOT change this -- it is the exact pattern from the plan.

### File 2: `bin/aegis`

Create the directory `bin/` first if it does not exist (`mkdir -p bin`). Then write the file verbatim:

```python
#!/usr/bin/env python3
"""Aegis CLI: control session state and refresh rule snapshot."""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from classifier import state as st  # noqa: E402

# Allow tests to redirect state directory.
if "AEGIS_STATE_DIR" in os.environ:
    st.STATE_DIR = Path(os.environ["AEGIS_STATE_DIR"])


def _most_recent_session() -> str | None:
    if not st.STATE_DIR.exists():
        return None
    files = list(st.STATE_DIR.glob("*.json"))
    if not files:
        return None
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return files[0].stem


def cmd_status(args: argparse.Namespace) -> int:
    sid = args.session or _most_recent_session()
    if not sid:
        print("no active session")
        return 0
    s = st.load(sid)
    print(f"Session {s.session_id}")
    print(f"  enabled: {s.enabled}")
    print(f"  consecutive_denies: {s.consecutive_denies}")
    print(f"  total_denies: {s.total_denies}")
    print(f"  paused_reason: {s.paused_reason}")
    print(f"  last_decision_at: {s.last_decision_at}")
    return 0


def cmd_on(args: argparse.Namespace) -> int:
    sid = args.session or _most_recent_session()
    if not sid:
        print("no session to enable", file=sys.stderr)
        return 1
    s = st.load(sid)
    s.enabled = True
    s.consecutive_denies = 0
    s.paused_reason = None
    st.save(s)
    print(f"Aegis enabled for session {sid}")
    return 0


def cmd_off(args: argparse.Namespace) -> int:
    sid = args.session or _most_recent_session() or "manual"
    s = st.load(sid)
    s.enabled = False
    s.paused_reason = "manual"
    st.save(s)
    print(f"Aegis disabled for session {sid}")
    return 0


def cmd_refresh_rules(args: argparse.Namespace) -> int:
    snap_path = REPO_ROOT / "rules" / "snapshot.json"
    meta_path = REPO_ROOT / "rules" / "snapshot.meta.json"
    snap_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        r = subprocess.run(["claude", "auto-mode", "defaults"],
                           capture_output=True, text=True, timeout=30)
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        print(f"refresh failed: {e}", file=sys.stderr)
        return 1
    if r.returncode != 0:
        print(f"claude returned {r.returncode}: {r.stderr}", file=sys.stderr)
        return 1
    snap_path.write_text(r.stdout)
    meta_path.write_text(json.dumps({
        "fetched_at": datetime.now(timezone.utc).isoformat(),
        "source": "claude auto-mode defaults",
        "ttl_days": 14,
    }, indent=2))
    print(f"snapshot refreshed: {snap_path}")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(prog="aegis")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("status")
    sp.add_argument("--session"); sp.set_defaults(func=cmd_status)

    sp = sub.add_parser("on")
    sp.add_argument("--session"); sp.set_defaults(func=cmd_on)

    sp = sub.add_parser("off")
    sp.add_argument("--session"); sp.set_defaults(func=cmd_off)

    sp = sub.add_parser("refresh-rules")
    sp.set_defaults(func=cmd_refresh_rules)

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
```

Then `chmod +x bin/aegis`.

Critical implementation details (these are easy to get wrong):

- **Module-level env override**: `if "AEGIS_STATE_DIR" in os.environ: st.STATE_DIR = Path(...)` runs at module load time, BEFORE any `st.load()` or `st.save()` call. This means the redirect happens once per CLI invocation. Tests rely on this -- if you move the assignment inside a function, the redirect won't apply when the subprocess runs.
- **`sys.path.insert(0, str(REPO_ROOT))`**: required because `bin/aegis` is launched as a script (not as a module), so Python's default sys.path does not include the repo root. Inserting it explicitly lets `from classifier import state as st` resolve. `bin/` is a sibling of `classifier/`, so `parent.parent` from the script file points at the repo root.
- **`_most_recent_session()` returns the file STEM** (e.g. `"abc-123"`) not the full filename. `Path.stem` strips the `.json` extension.
- **`cmd_off` falls back to literal `"manual"`** if no session id is available -- this creates a state file at `<state_dir>/manual.json`. Documented behavior; do not change.
- **`cmd_refresh_rules` writes to `rules/snapshot.json` and `rules/snapshot.meta.json`** under the repo root (Phase 4 created this directory and the initial files). Direct `write_text` is fine -- atomic write is overkill because refresh-rules is interactive (user-initiated, not concurrent).
- **Three error paths in `cmd_refresh_rules`**: `FileNotFoundError` (claude CLI not installed), `subprocess.TimeoutExpired` (took longer than 30s), `r.returncode != 0` (claude returned an error). All print to stderr and return 1.

### Files 3-5: slash command markdown files

Create `commands/` directory if it does not exist (`mkdir -p commands`). Then write each file verbatim.

**`commands/aegis-on.md`:**

```markdown
---
description: Re-enable Aegis classifier for the current session
---

Run the Aegis CLI to re-enable Aegis for this session. The session_id is provided
by Claude Code in the slash command context.

!`bin/aegis on --session "$CLAUDE_SESSION_ID"`
```

**`commands/aegis-off.md`:**

```markdown
---
description: Disable Aegis classifier for the current session (decisions revert to manual prompt)
---

Run the Aegis CLI to disable Aegis for this session.

!`bin/aegis off --session "$CLAUDE_SESSION_ID"`
```

**`commands/aegis-status.md`:**

```markdown
---
description: Show Aegis state for the current session
---

Run the Aegis CLI to show current session state.

!`bin/aegis status --session "$CLAUDE_SESSION_ID"`
```

The `!`-prefixed line is the Claude Code slash command convention for executing a shell command. The frontmatter `description` is what shows up in the slash command palette.

---

## Dependencies

**Requires**:
- Phase 4: `classifier/state.py` provides `state.load`, `state.save`, `state.STATE_DIR`, and the `SessionState` dataclass. The CLI imports these directly.
- Phase 1: `.claude-plugin/plugin.json` already references `commands/aegis-on.md`, `commands/aegis-off.md`, `commands/aegis-status.md`. This phase creates those files.

**Enables**:
- Phase 9: `install.sh` symlinks `bin/aegis` into `~/.local/bin` and runs `bin/aegis refresh-rules` if the snapshot file is missing. The end-to-end smoke also depends on the CLI working.

---

## Completion Criteria

- [ ] `tests/python/test_cli.py` exists with the 3 tests verbatim from this plan.
- [ ] `bin/aegis` exists, is executable (`chmod +x`), and has shebang `#!/usr/bin/env python3`.
- [ ] `bin/aegis --help` prints argparse usage text and exits 0.
- [ ] `python3 -m pytest tests/python/test_cli.py -v` reports 3 passed.
- [ ] `commands/aegis-on.md`, `commands/aegis-off.md`, `commands/aegis-status.md` exist with YAML frontmatter `description:` and a `!`-prefixed shell line.
- [ ] `jq . .claude-plugin/plugin.json` succeeds and the `commands` array shows the three .md files (this confirms Phase 1's references resolve).
- [ ] Two commits made: `Add aegis CLI: status / on / off / refresh-rules` and `Add aegis-on / aegis-off / aegis-status slash commands`.
- [ ] No file outside this phase's ownership has been touched -- specifically, `.claude-plugin/plugin.json` was not modified.

---

## Testing Requirements

**Primary**: the 3 unit tests in `tests/python/test_cli.py` cover the CLI's three observable behaviors: status with no session, off-then-on round trip persisting state, status against a pre-seeded session file.

**Out of unit-test scope** (handled by Functional QA below):
- `cmd_refresh_rules` with a mocked subprocess. Optional addition: write a 4th test `test_refresh_rules_mocks_subprocess` that uses `subprocess.run` patching to verify `rules/snapshot.json` and `rules/snapshot.meta.json` are written. If you add this, monkeypatch `bin/aegis` is not directly importable as a module, so this test must also use the subprocess pattern with a fake `claude` on PATH -- which is more work than it's worth. Skip; rely on the manual smoke instead.
- Slash command bodies. They cannot be unit-tested without a running Claude Code session (anti-pattern AP9 forbids installing in-development hooks into the user's live `~/.claude/`). Verify via `jq` (manifest references resolve) and the manual smoke at end of phase.

**Test command:**

```bash
cd /home/tunc/Sync/Programs/aegis
python3 -m pytest tests/python/test_cli.py -v
```

Expected: 3 passed. If any test fails, do not proceed to slash commands -- fix the CLI first.

---

## Functional QA

This phase ships two user-facing surfaces (Surface 4 = `bin/aegis` CLI, Surface 5 = slash commands per `FUNCTIONAL_QA_STRATEGY.md`). The checks below cross-reference Loop 7 (session toggle off) and Loop 8 (session toggle on after auto-pause). Run each check, capture the actual command and stdout/stderr, and paste both into the phase summary's "Functional QA Results" section.

- [ ] **(Surface 4, default-session behavior, Loop 7 setup)** `AEGIS_STATE_DIR=$(mktemp -d) bin/aegis status --session nonexistent` returns exit code 0. Stdout starts with `Session nonexistent` and shows `enabled: True` (the CLI auto-creates a default `SessionState` for unknown ids via `state.load`). Capture full stdout. Confirm the temp dir contains no leftover files (the CLI's `cmd_status` does NOT write to disk -- it only loads).

- [ ] **(Surface 4, off then file shape, Loop 7)** `D=$(mktemp -d) && AEGIS_STATE_DIR=$D bin/aegis off --session test1 && cat $D/test1.json | jq .` exits 0. The JSON contains `"enabled": false`, `"paused_reason": "manual"`, and `"session_id": "test1"`. Stdout from the CLI is `Aegis disabled for session test1`. Capture stdout + the JSON contents.

- [ ] **(Surface 4, on resets counters, Loop 8)** Continuing from check 2 with the same `$D`: `AEGIS_STATE_DIR=$D bin/aegis on --session test1 && cat $D/test1.json | jq .` exits 0. The JSON now has `"enabled": true`, `"paused_reason": null`, `"consecutive_denies": 0`. Stdout from the CLI is `Aegis enabled for session test1`. Capture stdout + the JSON contents.

- [ ] **(Surface 4, refresh-rules with mocked claude)** Cannot be tested deterministically inside this phase without hitting the user's real `claude` CLI (which would burn tokens and depends on network -- anti-pattern AP2). Instead, write a quick ad-hoc check by adding a fake `claude` shim to PATH temporarily:
  ```bash
  D=$(mktemp -d)
  cat > $D/claude <<'EOF'
  #!/bin/sh
  echo '{"allow":[],"soft_deny":[],"environment":[]}'
  EOF
  chmod +x $D/claude
  PATH="$D:$PATH" bin/aegis refresh-rules
  jq . rules/snapshot.json
  jq . rules/snapshot.meta.json
  ```
  Confirm exit code 0, stdout `snapshot refreshed: <path>`, `rules/snapshot.json` matches the shim's stdout, and `rules/snapshot.meta.json` has a fresh `fetched_at` ISO timestamp. **Important**: this overwrites the snapshot Phase 4 vendored. After the check, you may need to `git checkout rules/snapshot.json rules/snapshot.meta.json` to restore the original vendored snapshot. Document this in the phase summary.

- [ ] **(Surface 5, manifest references resolve)** `jq '.commands' .claude-plugin/plugin.json` succeeds and the output contains the three filenames `aegis-on.md`, `aegis-off.md`, `aegis-status.md` (or the equivalent paths Phase 1 used -- `commands/aegis-on.md` etc.). Capture the jq output verbatim.

- [ ] **(Surface 5, slash command body shape)** For each of the three .md files: `head -10 commands/aegis-<name>.md` shows YAML frontmatter (`---` ... `description: ...` ... `---`) followed by a body containing a line beginning with `` !` `` and ending with `` ` ``. Capture each head output. (This is a static check -- the actual slash command can only be exercised in a live Claude Code session, which is deferred to Phase 9.)

**Anti-patterns to watch for** (from `FUNCTIONAL_QA_STRATEGY.md`):
- **AP3 (touching real `~/.cache/aegis/sessions/`)**: every test invocation MUST set `AEGIS_STATE_DIR` to a tmp dir. Smoke tests too. If you ever run `bin/aegis off --session anything` without `AEGIS_STATE_DIR`, you wrote to the user's real state. Mitigation: prefix every smoke command with `AEGIS_STATE_DIR=$(mktemp -d)`.
- **AP2 (real `claude auto-mode defaults` in tests)**: do not write a unit test that calls the real `claude` CLI. The shim trick in Functional QA check 4 is the correct approach. The user's real `claude` is fine to call ONCE manually at end-of-phase to confirm the integration works (treat this as a Phase 9 smoke, not a Phase 8 test).
- **AP9 (installing the in-development hook)**: do not run `install.sh` or symlink `bin/aegis` into `~/.local/bin` from this phase. Phase 9 owns that. This phase only verifies the CLI works in-tree.

---

## External Interfaces Consumed

- **`classifier.state` Python module API** (authored by Phase 4)
  - **Consumed by**: `bin/aegis`. Specifically uses `state.STATE_DIR` (Path), `state.load(session_id) -> SessionState`, `state.save(s: SessionState) -> None`, and the dataclass fields `session_id, enabled, consecutive_denies, total_denies, paused_reason, last_decision_at`.
  - **How to capture**: open a Python REPL inside the repo and run:
    ```bash
    cd /home/tunc/Sync/Programs/aegis
    python3 -c "
    from classifier import state as st
    print('STATE_DIR:', st.STATE_DIR)
    s = st.load('capture-test')
    print('SessionState fields:', s)
    print('Type:', type(s).__name__)
    "
    ```
    Paste the output (the SessionState repr -- field names and default values) into the phase summary's "Evidence Captured" section. This confirms Phase 4 actually exposes the symbols `bin/aegis` imports.
  - **If not observable**: Phase 4 must already be complete (Batch 4, this phase is Batch 7 -- so Phase 4 is done). If `from classifier import state` fails with `ImportError` or `AttributeError`, halt the phase and report -- do not stub the CLI.

- **`claude auto-mode defaults` subcommand stdout** (Anthropic CLI external contract)
  - **Consumed by**: `cmd_refresh_rules` in `bin/aegis`. Captures `r.stdout` verbatim and writes to `rules/snapshot.json`. The shape must match what Phase 4's `rules.load_snapshot` expects: a JSON object with keys `allow`, `soft_deny`, `environment`.
  - **How to capture**: run once manually:
    ```bash
    claude auto-mode defaults | jq keys
    ```
    Paste the output (the top-level key list) into the phase summary's "Evidence Captured" section. Then optionally `claude auto-mode defaults | head -50` for a content sample. **Important**: this command hits Anthropic's rule data and may take a few seconds. Do NOT include real CLI invocations in the unit tests (anti-pattern AP2). One manual capture is enough; tests use the shim trick.
  - **If not observable**: if `claude` CLI is missing or unauthenticated, the CLI's `cmd_refresh_rules` returns 1 with a stderr message. The Phase 4 vendored snapshot remains in place. Document the unavailability in the phase summary; do NOT mock the shape -- Phase 4 already encoded the expected shape.

---

## Notes

- **Where to verify the shebang line works**: `head -1 bin/aegis` should print `#!/usr/bin/env python3`. If you see anything else, the file got corrupted on write -- rewrite it.
- **Why `--session` defaults to most-recent**: matches the design spec (line 282 of the design doc): "With no --session, defaults to the most recently active session." `_most_recent_session()` implements this by scanning `STATE_DIR` and picking the file with the highest mtime.
- **Why `cmd_off` falls back to `"manual"`**: when no session is active and the user runs `aegis off` from a shell (not from a Claude Code slash command), there's no session id to discover. Creating a `manual.json` state file lets the user toggle Aegis off without an active Claude Code session. The next slash command invocation will see the actual `$CLAUDE_SESSION_ID` and write a separate file.
- **`cmd_status` prints all six fields of `SessionState`**: matches the dataclass shape exposed by Phase 4 (`session_id`, `enabled`, `consecutive_denies`, `total_denies`, `paused_reason`, `last_decision_at`). If Phase 4 added or renamed a field, the test `test_status_specific_session` may need adjustment -- but Phase 4's brief and the codebase context lock these six fields.
- **Slash command file naming matches Phase 1's manifest**: Phase 1 wrote `.claude-plugin/plugin.json` referencing `commands/aegis-on.md`, `commands/aegis-off.md`, `commands/aegis-status.md`. If `jq . .claude-plugin/plugin.json` shows different paths, halt and report -- do not rename these files to match without understanding why Phase 1 differs.
- **Plugin format detail**: Claude Code reads `commands/*.md` files via the `commands` array in the manifest. The `!`-prefixed line in the markdown body is shorthand Claude Code recognizes for "execute this shell command." `$CLAUDE_SESSION_ID` is set by Claude Code in the slash-command execution environment; the slash command body is simply a shell line that the runtime evaluates.
- **No emojis, no unicode** in any output strings or in the markdown files (project style guide). Plain ASCII only.
