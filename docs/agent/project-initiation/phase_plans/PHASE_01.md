# Phase 1: Scaffold + vendor bash + logging

**Feature**: project-initiation
**Estimated Context Budget**: ~30k tokens

**Difficulty**: easy
**Visual**: no
**Functional**: yes

**Execution Mode**: sequential
**Batch**: 1

---

## Objective

Lay down the Aegis repo skeleton: `.gitignore`, README skeleton, plugin manifest, `pyproject.toml`, the two vendored bash decision scripts (`lib/bash-gatekeeper.sh`, `lib/bash-denylist.sh`), and the Python logging setup (`classifier/log.py`). After this phase the directory tree is callable for the first two surfaces (the gatekeeper and denylist scripts work standalone) and ready for Phase 2 to extend with new layers and a test harness.

This phase corresponds to Tasks 1-2 in `docs/superpowers/plans/2026-04-30-aegis.md`. Treat the verbatim listings in those tasks as the source of truth for file content; this plan adds the logging deliverable, the framework decision, and the smoke verification anti-patterns.

---

## Deliverables

1. `/home/tunc/Sync/Programs/aegis/.gitignore` -- standard Python/test exclusions.
2. `/home/tunc/Sync/Programs/aegis/README.md` -- 5-line skeleton (Phase 9 replaces with the full README).
3. `/home/tunc/Sync/Programs/aegis/.claude-plugin/plugin.json` -- plugin manifest registering the `PreToolUse` hook with matcher `*` pointing at `${CLAUDE_PLUGIN_ROOT}/orchestrator.sh`, plus the three slash command files (forward references; the files are created in Phase 8).
4. `/home/tunc/Sync/Programs/aegis/pyproject.toml` -- minimal Python project config + pytest config (`testpaths`, `pythonpath`); add `loguru` to dependencies if (and only if) loguru is the chosen logging framework (see step 6).
5. `/home/tunc/Sync/Programs/aegis/lib/bash-gatekeeper.sh` -- VERBATIM copy of `/home/tunc/Sync/Programs/bash-gatekeeper/bash-gatekeeper.sh`, executable.
6. `/home/tunc/Sync/Programs/aegis/lib/bash-denylist.sh` -- VERBATIM copy of `/home/tunc/.claude/hooks/bash-denylist.sh`, executable.
7. `/home/tunc/Sync/Programs/aegis/classifier/__init__.py` -- empty file (Python package marker; Phase 3 doesn't need to recreate it).
8. `/home/tunc/Sync/Programs/aegis/classifier/log.py` -- single `setup_logger(level: str = "info") -> Logger` function with module docstring documenting the framework decision (see step 6).

---

## Detailed Requirements

### Step 1: Verify working directory

Run `pwd`. Expected output: `/home/tunc/Sync/Programs/aegis`. If not, abort and ask the user.

### Step 2: Create `.gitignore`

Path: `/home/tunc/Sync/Programs/aegis/.gitignore`

Exact content (newline-terminated):

```
__pycache__/
*.pyc
.pytest_cache/
.aegis-cache/
*.swp
.DS_Store
```

### Step 3: Create `README.md` skeleton

Path: `/home/tunc/Sync/Programs/aegis/README.md`

Exact content (no emojis, no unicode):

```markdown
# Aegis

Self-hosted, LLM-agnostic replacement for Claude Code's `auto` permission mode.

See [design spec](docs/superpowers/specs/2026-04-30-aegis-design.md).

## Status: in development.
```

### Step 4: Create `.claude-plugin/plugin.json`

Path: `/home/tunc/Sync/Programs/aegis/.claude-plugin/plugin.json`

```bash
mkdir -p /home/tunc/Sync/Programs/aegis/.claude-plugin
```

Exact content:

```json
{
  "name": "aegis",
  "version": "0.1.0",
  "description": "LLM-classifier-driven permission mode for Claude Code",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/orchestrator.sh" }
        ]
      }
    ]
  },
  "commands": ["commands/aegis-on.md", "commands/aegis-off.md", "commands/aegis-status.md"]
}
```

The `commands/*.md` paths are forward references. Phase 8 creates those files. The manifest is allowed to reference files that don't exist yet because plugin loading is lazy and we are not installing the plugin in this phase (see Constraints).

### Step 5: Create `pyproject.toml`

Path: `/home/tunc/Sync/Programs/aegis/pyproject.toml`

If you pick loguru (see step 6), use:

```toml
[project]
name = "aegis-classifier"
version = "0.1.0"
description = "Aegis LLM classifier - slow path for permission decisions"
requires-python = ">=3.11"
dependencies = ["loguru>=0.7"]

[tool.pytest.ini_options]
testpaths = ["tests/python"]
pythonpath = ["."]
```

If you pick stdlib `logging`, drop the `loguru` dep:

```toml
[project]
name = "aegis-classifier"
version = "0.1.0"
description = "Aegis LLM classifier - slow path for permission decisions"
requires-python = ">=3.11"
dependencies = []

[tool.pytest.ini_options]
testpaths = ["tests/python"]
pythonpath = ["."]
```

No emojis, no unicode in the description (note: ASCII hyphen, not em dash).

### Step 6: Decide logging framework and create `classifier/log.py`

The framework choice is YOURS to make. The cross-cutting concerns in `PROJECT_PLAN.md` recommend `loguru` (simpler API, structured format out of the box) but allow stdlib `logging` if you want stdlib-only. Document the decision in the module docstring.

Recommended choice: **loguru**. Rationale -- one external dep is acceptable for the convenience; structured stderr format with `[YYYY-MM-DD HH:MM:SS] [level] [module] message` comes for free; level filtering is one line.

Path: `/home/tunc/Sync/Programs/aegis/classifier/__init__.py` -- empty file. Create it first:

```bash
mkdir -p /home/tunc/Sync/Programs/aegis/classifier
touch /home/tunc/Sync/Programs/aegis/classifier/__init__.py
```

Path: `/home/tunc/Sync/Programs/aegis/classifier/log.py`

If you chose **loguru**, exact content:

```python
"""Logging setup for the Aegis classifier.

Framework decision (Phase 1): loguru.
Rationale: simpler API than stdlib `logging`; structured stderr format
with timestamp/level/module out of the box; level filtering is one line.
The cross-cutting concerns in PROJECT_PLAN.md tentatively recommended loguru
and allowed Phase 1 to swap to stdlib `logging`. We keep loguru.

All classifier modules import via:
    from classifier.log import setup_logger
    logger = setup_logger()

Reading the AEGIS_LOG_LEVEL env var (defaults to "info") lets users bump
verbosity without editing code. Logs always go to stderr -- stdout is
reserved for the Claude Code permission decision JSON.
"""

from __future__ import annotations

import os
import sys

from loguru import logger as _logger


def setup_logger(level: str | None = None):
    """Configure the loguru logger to write structured records to stderr.

    Idempotent: removing all handlers before re-adding ensures repeated calls
    do not duplicate output.

    Args:
        level: Optional log level override ("trace"|"debug"|"info"|"warning"|
            "error"|"critical"). Defaults to AEGIS_LOG_LEVEL env var or "info".

    Returns:
        The configured loguru logger.
    """
    resolved_level = (level or os.environ.get("AEGIS_LOG_LEVEL") or "info").upper()
    _logger.remove()
    _logger.add(
        sys.stderr,
        level=resolved_level,
        format="[{time:YYYY-MM-DD HH:mm:ss}] [{level}] [{name}] {message}",
        enqueue=False,
    )
    return _logger
```

If you chose **stdlib logging** instead, exact content:

```python
"""Logging setup for the Aegis classifier.

Framework decision (Phase 1): stdlib `logging`.
Rationale: stdlib-only avoids adding an external dependency; the structured
format is easy enough to configure manually. Loguru would have been simpler
but we accept the small extra ceremony to keep the dependency surface flat.

All classifier modules import via:
    from classifier.log import setup_logger
    logger = setup_logger()

Reading the AEGIS_LOG_LEVEL env var (defaults to "info") lets users bump
verbosity without editing code. Logs always go to stderr -- stdout is
reserved for the Claude Code permission decision JSON.
"""

from __future__ import annotations

import logging
import os
import sys


def setup_logger(level: str | None = None) -> logging.Logger:
    """Configure a stderr-bound logger named 'aegis' with structured format.

    Idempotent: removing existing handlers on the 'aegis' logger before adding
    ensures repeated calls do not duplicate output.

    Args:
        level: Optional log level override ("debug"|"info"|"warning"|"error"|
            "critical"). Defaults to AEGIS_LOG_LEVEL env var or "info".

    Returns:
        The configured logger.
    """
    resolved_level = (level or os.environ.get("AEGIS_LOG_LEVEL") or "info").upper()
    logger = logging.getLogger("aegis")
    logger.setLevel(resolved_level)
    logger.handlers.clear()
    handler = logging.StreamHandler(stream=sys.stderr)
    handler.setLevel(resolved_level)
    handler.setFormatter(
        logging.Formatter(
            fmt="[%(asctime)s] [%(levelname)s] [%(name)s] %(message)s",
            datefmt="%Y-%m-%d %H:%M:%S",
        )
    )
    logger.addHandler(handler)
    logger.propagate = False
    return logger
```

The function signature `setup_logger(level: str | None = None) -> Logger` is the contract that subsequent phases will rely on. Do NOT change the parameter name or default semantics in later phases.

### Step 7: Vendor `lib/bash-gatekeeper.sh`

```bash
mkdir -p /home/tunc/Sync/Programs/aegis/lib
cp /home/tunc/Sync/Programs/bash-gatekeeper/bash-gatekeeper.sh /home/tunc/Sync/Programs/aegis/lib/bash-gatekeeper.sh
chmod +x /home/tunc/Sync/Programs/aegis/lib/bash-gatekeeper.sh
```

Verify it is a regular executable file, NOT a symlink:

```bash
ls -la /home/tunc/Sync/Programs/aegis/lib/bash-gatekeeper.sh
```

Expected: a `-rwxr-xr-x` file, no `->` arrow. File size around 36KB. The first line should be `#!/bin/bash`.

VERBATIM means: do not edit, reformat, add headers, fix typos, or strip comments. The file in `lib/` must be byte-for-byte identical to the source. Verify with:

```bash
diff /home/tunc/Sync/Programs/bash-gatekeeper/bash-gatekeeper.sh /home/tunc/Sync/Programs/aegis/lib/bash-gatekeeper.sh
```

Expected: no output (no diff).

### Step 8: Vendor `lib/bash-denylist.sh`

```bash
cp /home/tunc/.claude/hooks/bash-denylist.sh /home/tunc/Sync/Programs/aegis/lib/bash-denylist.sh
chmod +x /home/tunc/Sync/Programs/aegis/lib/bash-denylist.sh
```

Verify:

```bash
ls -la /home/tunc/Sync/Programs/aegis/lib/bash-denylist.sh
diff /home/tunc/.claude/hooks/bash-denylist.sh /home/tunc/Sync/Programs/aegis/lib/bash-denylist.sh
```

Expected: `-rwxr-xr-x`, no symlink arrow, no diff output. First line `#!/bin/bash`.

### Step 9: Smoke test the vendored layers

Both scripts must work in their new home with no modifications. Run from the project root:

```bash
cd /home/tunc/Sync/Programs/aegis
echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | lib/bash-gatekeeper.sh
```

Expected stdout: `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}` (exact JSON; format may vary slightly across versions but the `permissionDecision:"allow"` substring MUST be present). Exit code 0.

```bash
echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | lib/bash-denylist.sh; echo "exit=$?"
```

Expected: stderr contains a `bash-denylist:` prefixed message describing the match. Stdout is empty. The trailing line prints `exit=2`.

Also run a syntax-only check on each vendored script:

```bash
bash -n /home/tunc/Sync/Programs/aegis/lib/bash-gatekeeper.sh
bash -n /home/tunc/Sync/Programs/aegis/lib/bash-denylist.sh
```

Expected: no output (clean syntax).

### Step 10: Verify Python logging module imports

```bash
cd /home/tunc/Sync/Programs/aegis
python3 -c "from classifier.log import setup_logger; logger = setup_logger(); logger.info('phase 1 logging up')"
```

Expected: a line on stderr matching `[YYYY-MM-DD HH:MM:SS] [INFO] [...] phase 1 logging up`. No tracebacks. If you chose loguru and `pip install loguru` has not yet been run in the environment, run:

```bash
pip install loguru
```

(Or use `uv add loguru` if `uv` is the project's tooling -- the user uses `uv` per `CODEBASE_CONTEXT.md`.) Skip this entirely if you chose stdlib.

### Step 11: Final directory state check

```bash
find /home/tunc/Sync/Programs/aegis -maxdepth 3 -type f -not -path '*/\.git/*' -not -path '*/docs/*' | sort
```

Expected exactly these paths:

```
/home/tunc/Sync/Programs/aegis/.claude-plugin/plugin.json
/home/tunc/Sync/Programs/aegis/.gitignore
/home/tunc/Sync/Programs/aegis/README.md
/home/tunc/Sync/Programs/aegis/classifier/__init__.py
/home/tunc/Sync/Programs/aegis/classifier/log.py
/home/tunc/Sync/Programs/aegis/lib/bash-denylist.sh
/home/tunc/Sync/Programs/aegis/lib/bash-gatekeeper.sh
/home/tunc/Sync/Programs/aegis/pyproject.toml
```

(There may be an additional `.claude/` directory from the existing repo state -- ignore.)

---

## Edge Cases and Things to Watch For

- The vendored scripts MUST remain byte-for-byte identical. Any "harmless" reformatting or comment edits is a defect. Phase 2 will copy the bash-gatekeeper test corpora, which are calibrated against the exact regexes in this script -- silent edits will produce mysterious test failures in Phase 2.
- `chmod +x` is required. Vendoring without execute permission will silently break the orchestrator's pipeline in Phase 3 (the script invocation will fail, producing empty stdout, which the orchestrator treats as silent fall-through, which is the wrong layer behavior).
- The plugin manifest references `commands/aegis-{on,off,status}.md` which do NOT exist yet. This is intentional. Do NOT create empty placeholder files for them in this phase -- Phase 8 owns the slash command files. The manifest reference is a forward declaration only.
- The plugin manifest references `${CLAUDE_PLUGIN_ROOT}/orchestrator.sh` which does NOT exist yet. Phase 3 creates it. Same rule -- do not create a placeholder.
- Do NOT install the plugin into `~/.claude/plugins/` or `~/Sync/.claude/plugins/` during this phase. Installation is Phase 9's job. Anti-pattern AP9 in `FUNCTIONAL_QA_STRATEGY.md` warns that copying an in-development hook into the user's live Claude Code config will gate every tool call in every session with a buggy script.
- The user's CLAUDE.md style guide bans emojis, unicode symbols, em dashes, and en dashes in user-facing text. Your README, pyproject.toml description, and module docstrings must comply (use ASCII hyphens `-`, not `--` as a sentence punctuation, not en/em dashes).
- `pyproject.toml` must use straight quotes (`"`) only. Smart/curly quotes will break TOML parsing. (This is a CLAUDE.md rule that also happens to be a real bug source.)

---

## Dependencies

**Requires**: None. This is the first phase.

**Enables**:
- Phase 2: needs the vendored `lib/bash-gatekeeper.sh` and `lib/bash-denylist.sh` to extend `tests/bash/run.sh` and copy the additional corpora. Also needs the `lib/` directory to exist for `lib/bash-hard-ask.sh` and `lib/protected-paths.sh`.
- Phase 3: needs the plugin manifest in place (Phase 3's `orchestrator.sh` is the file the manifest references) and `classifier/__init__.py` to exist.
- Phase 4-9: every Python module imports `setup_logger` from `classifier/log.py`.

---

## Completion Criteria

- [ ] `pwd` from working dir returns `/home/tunc/Sync/Programs/aegis`.
- [ ] `.gitignore`, `README.md`, `.claude-plugin/plugin.json`, `pyproject.toml` exist with the exact content specified above.
- [ ] `lib/bash-gatekeeper.sh` exists, is executable (`-rwxr-x...`), is NOT a symlink, and `diff` against the source returns no output.
- [ ] `lib/bash-denylist.sh` exists, is executable, is NOT a symlink, and `diff` against the source returns no output.
- [ ] `bash -n lib/bash-gatekeeper.sh` and `bash -n lib/bash-denylist.sh` both exit 0 with no output (syntax clean).
- [ ] `classifier/__init__.py` exists and is empty.
- [ ] `classifier/log.py` exists, has a module docstring naming the chosen framework (loguru or stdlib `logging`) and the rationale, and exports `setup_logger(level: str | None = None)` returning the configured logger.
- [ ] `python3 -c "from classifier.log import setup_logger; setup_logger().info('ok')"` writes one structured line to stderr and exits 0.
- [ ] Smoke check 1 (gatekeeper allow): exit 0, stdout contains `"permissionDecision":"allow"`.
- [ ] Smoke check 2 (denylist deny): exit 2, stderr contains `bash-denylist:` prefix.
- [ ] No file in this phase touches paths owned by Phases 2-9 (no `lib/bash-hard-ask.sh`, no `lib/protected-paths.sh`, no `orchestrator.sh`, no `tests/`, no `bin/`, no `commands/*.md`, no `install.sh`, no `rules/*`).
- [ ] No emojis, unicode symbols, em dashes, or en dashes in any authored content.

---

## Testing Requirements

This phase has no pytest suite of its own (the Python tests start in Phase 3 with `tests/python/conftest.py`). Verification is the smoke checks under "Functional QA" below plus the diff-against-source verifications under Step 7-8.

The pytest config in `pyproject.toml` is set up here so that subsequent phases inherit a working `python3 -m pytest tests/python/` command without needing to author pytest config themselves.

---

## Functional QA

These are the two surface checks for this phase. Both exercise Surface 2 (individual deterministic layer scripts) from `FUNCTIONAL_QA_STRATEGY.md`. Both correspond to the front half of User Loops 1 and 2 (Loop 1 is the routine `ls` ALLOW; Loop 2 is the catastrophic `rm -rf /` DENY) -- in this phase the orchestrator does not yet exist, so we verify the underlying layer scripts directly.

- [ ] **(Surface 2, Loop 1) `lib/bash-gatekeeper.sh` allows `ls`.** Run `cd /home/tunc/Sync/Programs/aegis && echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | lib/bash-gatekeeper.sh; echo "exit=$?"`. Expected stdout: a JSON object containing `"permissionDecision":"allow"`; exit code 0. Paste full stdout and exit code into the phase summary's "Functional QA Results" section.

- [ ] **(Surface 2, Loop 2) `lib/bash-denylist.sh` denies `rm -rf /`.** Run `cd /home/tunc/Sync/Programs/aegis && echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | lib/bash-denylist.sh; echo "exit=$?"`. Expected: stdout empty, stderr contains a `bash-denylist:` prefixed line describing the match (substring `rm -rf` and a phrase like `root-level path` is fine), exit code 2. Paste stderr line and exit code into the phase summary.

### Anti-patterns to watch for in this phase

From `FUNCTIONAL_QA_STRATEGY.md`:

- **AP4 (asserting only exit code for layer scripts)**: do not declare the gatekeeper smoke "passed" just because the script exited 0. The layer must EMIT the allow JSON. Match the `"permissionDecision":"allow"` substring.
- **AP9 (installing the in-development hook)**: do NOT copy the plugin into `~/.claude/plugins/aegis/`. The smoke checks above run the scripts directly from the dev tree, and that is sufficient.
- **AP7 (`set -e` in pipeline scripts)**: this applies to the new layer scripts in Phase 2, not the vendored ones, but verify when you `bash -n` the vendored scripts that they begin `set -u` (not `set -e`). If the source already had `set -e`, leave it alone (verbatim copy is the constraint), and flag it in the phase summary so Phase 2 knows.

---

## Notes

- Logging framework recommendation: pick **loguru**. Set `dependencies = ["loguru>=0.7"]` in `pyproject.toml`. The user is fine with one external Python dep for the convenience.
- Once the plan is implemented, commit with `git add .gitignore README.md .claude-plugin/ pyproject.toml lib/ classifier/ && git commit -m "Phase 1: scaffold + vendor bash + logging"`. (Do NOT use `git add -A` -- the project root has a `docs/` tree from the setup phase that should not be modified by Phase 1's commit. Commit only the files this phase authored.)
- The 19-task implementation plan at `docs/superpowers/plans/2026-04-30-aegis.md` Tasks 1-2 has the exact file content listings; treat that as a cross-reference if anything in this plan looks ambiguous, but this plan is the authoritative source for Phase 1.
- If `pip install loguru` (or `uv add loguru`) fails in the environment, downgrade to stdlib `logging` and update both the `pyproject.toml` (drop the dep) and `classifier/log.py` (use the stdlib variant above). Document the swap in the module docstring and the phase summary.
- Context budget for this phase is ~30k tokens. Reading the required context above plus authoring the eight small files should fit comfortably. If you find yourself approaching budget, stop and flag it in the phase summary -- something has gone wrong (probably accidentally re-reading a large doc).
