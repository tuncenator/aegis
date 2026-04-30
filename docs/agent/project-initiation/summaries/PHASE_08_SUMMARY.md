# Phase 8: bin/aegis CLI + slash commands - Summary

**Date Completed:** 2026-04-30
**Completed By:** claude-sonnet-4-6 (agent-a9fbe2d25db9cef2a)
**Actual Token Usage:** ~20k tokens

---

## Objective

Build the user-facing toggle surfaces for Aegis: the `bin/aegis` Python CLI (`status`, `on`, `off`, `refresh-rules`) and the three Claude Code slash command files (`/aegis-on`, `/aegis-off`, `/aegis-status`) that wrap the CLI. The CLI imports `classifier.state` (authored by Phase 4) and supports an `AEGIS_STATE_DIR` env override for hermetic tests.

---

## Work Completed

### What Was Built

- `tests/python/test_cli.py` (3 pytest tests invoking `bin/aegis` as a real subprocess)
- `bin/aegis` (executable Python CLI with shebang, 4 subcommands, module-level `AEGIS_STATE_DIR` redirect)
- `commands/aegis-on.md`, `commands/aegis-off.md`, `commands/aegis-status.md` (slash command files with YAML frontmatter and `!`-prefixed shell lines)

### Files Created

- `bin/aegis` - Python CLI executable with subcommands: `status`, `on`, `off`, `refresh-rules`
- `tests/python/test_cli.py` - 3 subprocess-based tests with AEGIS_STATE_DIR isolation
- `commands/aegis-on.md` - slash command re-enabling Aegis for current session
- `commands/aegis-off.md` - slash command disabling Aegis for current session
- `commands/aegis-status.md` - slash command showing Aegis state for current session

### Files Modified

None. No files outside phase ownership were touched.

### Key Design Decisions

- Module-level `AEGIS_STATE_DIR` override (`if "AEGIS_STATE_DIR" in os.environ: st.STATE_DIR = Path(...)`) runs at import time, not inside a function, so the redirect applies to every subsequent `st.load()`/`st.save()` call in the same subprocess.
- `sys.path.insert(0, str(REPO_ROOT))` required because `bin/aegis` is launched as a script, not as a module; `parent.parent` from the script file correctly resolves to repo root since `bin/` is a sibling of `classifier/`.
- `cmd_off` falls back to literal `"manual"` session id if no session is available -- documented behavior per spec.
- `_most_recent_session()` returns `Path.stem` (strips `.json`) not the full filename.

---

## Completion Criteria Status

- [x] `tests/python/test_cli.py` exists with the 3 tests verbatim from this plan. Verified: file matches spec exactly.
- [x] `bin/aegis` exists, is executable, and has shebang `#!/usr/bin/env python3`. Verified: `head -1 bin/aegis` prints `#!/usr/bin/env python3`.
- [x] `bin/aegis --help` prints argparse usage text and exits 0. Verified: manual smoke run, exit 0 with usage output.
- [x] `python3 -m pytest tests/python/test_cli.py -v` reports 3 passed. Verified: all 3 passed.
- [x] `commands/aegis-on.md`, `commands/aegis-off.md`, `commands/aegis-status.md` exist with YAML frontmatter and `!`-prefixed shell line. Verified: `head -10` of each file confirms frontmatter and `!` line.
- [x] `jq . .claude-plugin/plugin.json` succeeds and the `commands` array shows the three .md files. Verified: output pasted in QA Results.
- [x] Two commits: `Add aegis CLI: status / on / off / refresh-rules` and `Add aegis-on / aegis-off / aegis-status slash commands`. Verified: `git log` shows both commits.
- [x] No file outside this phase's ownership has been touched. Verified: `.claude-plugin/plugin.json` was not modified.

---

## Testing

### Tests Written

- `tests/python/test_cli.py`
  - `test_status_no_session_returns_message` -- empty state dir returns "no active session"
  - `test_off_then_on_round_trip` -- off writes `enabled: false`, on resets to `enabled: true, consecutive_denies: 0`
  - `test_status_specific_session` -- status reads and prints existing session file fields

### Test Results

```
$ uv run python -m pytest tests/python/test_cli.py -v
============================= test session starts ==============================
platform linux -- Python 3.13.12, pytest-9.0.3, pluggy-1.6.0
collected 3 items

tests/python/test_cli.py::test_status_no_session_returns_message PASSED  [ 33%]
tests/python/test_cli.py::test_off_then_on_round_trip PASSED             [ 66%]
tests/python/test_cli.py::test_status_specific_session PASSED            [100%]

============================== 3 passed in 0.13s ==============================
```

Full suite (46 tests):

```
$ uv run python -m pytest tests/python/ -v
...
46 passed in 0.21s
```

---

## Evidence Captured

### `classifier.state` Python module API

- **How captured**: Read `/classifier/state.py` directly (Phase 4 file).
- **Captured on**: 2026-04-30, commit 4a36c52 (worktree HEAD after checkpoint 4).
- **Consumed by**: `bin/aegis` lines importing `from classifier import state as st`, calling `st.load()`, `st.save()`, `st.STATE_DIR`.
- **Sample**:

  ```python
  STATE_DIR = Path.home() / ".cache" / "aegis" / "sessions"

  @dataclass
  class SessionState:
      session_id: str
      enabled: bool = True
      consecutive_denies: int = 0
      total_denies: int = 0
      paused_reason: str | None = None
      last_decision_at: str | None = None
  ```

- **Notes**: `save()` sets `last_decision_at` to current UTC timestamp before writing. `load()` returns default `SessionState` on missing or corrupt files.

---

## Helper Issues

No helpers were listed for this phase. No helpers invoked.

---

## Functional QA Results

### Check 1: status --session nonexistent returns exit 0 with Session header and enabled: True

- **Surface**: Surface 4 (bin/aegis CLI)
- **Invocation**: `D=$(mktemp -d) && AEGIS_STATE_DIR=$D bin/aegis status --session nonexistent; echo "exit: $?"; ls $D`
- **Observed outcome**:

  ```
  Session nonexistent
    enabled: True
    consecutive_denies: 0
    total_denies: 0
    paused_reason: None
    last_decision_at: None
  exit: 0
  ```

  (ls produced no output -- no leftover files in temp dir)

- **Verdict**: pass

### Check 2: off then file shape

- **Surface**: Surface 4 (bin/aegis CLI)
- **Invocation**: `D=$(mktemp -d) && AEGIS_STATE_DIR=$D bin/aegis off --session test1 && cat $D/test1.json | jq .`
- **Observed outcome**:

  ```
  Aegis disabled for session test1
  {
    "session_id": "test1",
    "enabled": false,
    "consecutive_denies": 0,
    "total_denies": 0,
    "paused_reason": "manual",
    "last_decision_at": "2026-04-30T07:20:31.508200+00:00"
  }
  ```

- **Verdict**: pass

### Check 3: on resets counters

- **Surface**: Surface 4 (bin/aegis CLI)
- **Invocation**: `D=$(mktemp -d) && AEGIS_STATE_DIR=$D bin/aegis off --session test1 > /dev/null && AEGIS_STATE_DIR=$D bin/aegis on --session test1 && cat $D/test1.json | jq .`
- **Observed outcome**:

  ```
  Aegis enabled for session test1
  {
    "session_id": "test1",
    "enabled": true,
    "consecutive_denies": 0,
    "total_denies": 0,
    "paused_reason": null,
    "last_decision_at": "2026-04-30T07:20:37.017442+00:00"
  }
  ```

- **Verdict**: pass

### Check 4: refresh-rules with mocked claude shim

- **Surface**: Surface 4 (bin/aegis CLI)
- **Invocation**:

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

- **Observed outcome**:

  ```
  snapshot refreshed: /home/tunc/Sync/Programs/aegis/.claude/worktrees/agent-a9fbe2d25db9cef2a/rules/snapshot.json
  exit: 0
  {
    "allow": [],
    "soft_deny": [],
    "environment": []
  }
  {
    "fetched_at": "2026-04-30T07:20:43.666742+00:00",
    "source": "claude auto-mode defaults",
    "ttl_days": 14
  }
  ```

  After check: `git checkout rules/snapshot.json rules/snapshot.meta.json` restored Phase 4 vendored snapshot.

- **Verdict**: pass

### Check 5: manifest references resolve

- **Surface**: Surface 5 (slash commands)
- **Invocation**: `jq '.commands' .claude-plugin/plugin.json`
- **Observed outcome**:

  ```json
  [
    "commands/aegis-on.md",
    "commands/aegis-off.md",
    "commands/aegis-status.md"
  ]
  ```

- **Verdict**: pass

### Check 6: slash command body shape

- **Surface**: Surface 5 (slash commands)
- **Invocation**: `for f in aegis-on aegis-off aegis-status; do echo "=== commands/$f.md ==="; head -10 commands/$f.md; done`
- **Observed outcome**:

  ```
  === commands/aegis-on.md ===
  ---
  description: Re-enable Aegis classifier for the current session
  ---

  Run the Aegis CLI to re-enable Aegis for this session. The session_id is provided
  by Claude Code in the slash command context.

  !`bin/aegis on --session "$CLAUDE_SESSION_ID"`
  === commands/aegis-off.md ===
  ---
  description: Disable Aegis classifier for the current session (decisions revert to manual prompt)
  ---

  Run the Aegis CLI to disable Aegis for this session.

  !`bin/aegis off --session "$CLAUDE_SESSION_ID"`
  === commands/aegis-status.md ===
  ---
  description: Show Aegis state for the current session
  ---

  Run the Aegis CLI to show current session state.

  !`bin/aegis status --session "$CLAUDE_SESSION_ID"`
  ```

- **Verdict**: pass

### Anti-Patterns Watched For

- **AP3 (real ~/.cache/aegis/)**: every QA smoke used `AEGIS_STATE_DIR=$(mktemp -d)`. Never ran without it.
- **AP2 (real claude auto-mode defaults)**: refresh-rules QA used a fake shim on PATH, not the real Anthropic CLI.
- **AP9 (installing in-development hook)**: did not run `install.sh` or symlink `bin/aegis` into `~/.local/bin`.

### Strategy Updates

No strategy updates. All surfaces and anti-patterns were already documented in FUNCTIONAL_QA_STRATEGY.md.

---

## Challenges & Solutions

No significant challenges encountered. The phase plan was precise and the implementation was straightforward.

---

## Code Quality

### Formatting
- [x] Code formatted per project conventions (Python 3.11+, `from __future__ import annotations`, type hints on public sigs)
- [x] Imports organized (stdlib then local)
- [x] No unused imports

### Documentation
- [x] Module docstring present in `bin/aegis`
- [x] Type annotations on all public function signatures
- [x] ASCII only, no emojis or unicode

---

## Dependencies

### Required by This Phase

- Phase 4: `classifier/state.py` (SessionState, STATE_DIR, load, save)
- Phase 1: `.claude-plugin/plugin.json` (already references the three command files)

### Unblocked Phases

- Phase 9: `install.sh` symlinks `bin/aegis` into `~/.local/bin` and runs `bin/aegis refresh-rules` if snapshot is missing.

---

## Codebase Context Updates

- Add `bin/aegis` to Key Files: executable Python CLI with subcommands `status`, `on`, `off`, `refresh-rules`. Imports `classifier.state`. Honors `AEGIS_STATE_DIR` env at module load time. `REPO_ROOT` is `Path(__file__).resolve().parent.parent`.
- Add `commands/aegis-on.md`, `commands/aegis-off.md`, `commands/aegis-status.md` to Key Files: Claude Code slash command files with YAML frontmatter and `!`-prefixed shell lines calling `bin/aegis`.
- Add `tests/python/test_cli.py` to Key Files: 3 subprocess-based tests for CLI behavior.
- Update Phase 8 status to COMPLETE in EXECUTION_PLAN.md context.

## Notes for Future Phases

- Phase 9 (`install.sh`): `bin/aegis` is `chmod +x` and has shebang. Symlinking to `~/.local/bin` via `ln -s $(pwd)/bin/aegis ~/.local/bin/aegis` will work. The `refresh-rules` subcommand requires `claude` CLI on PATH; Phase 9 should check for it before running.
- `cmd_refresh_rules` overwrites `rules/snapshot.json` and `rules/snapshot.meta.json` in-place with direct `write_text` (no atomic write). This is intentional for user-initiated refresh; concurrent access is not a concern here.

---

## Next Steps

**Next Phase:** Phase 9 - install.sh

**Recommended Actions:**
1. Implement `install.sh` to symlink `bin/aegis` into `~/.local/bin`.
2. Have `install.sh` run `bin/aegis refresh-rules` if `rules/snapshot.json` is missing.
3. Verify that `claude` CLI is present on PATH before attempting refresh.
