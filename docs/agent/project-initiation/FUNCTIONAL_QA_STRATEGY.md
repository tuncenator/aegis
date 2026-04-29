# Functional Verification Strategy

> Per-feature artifact. Captures HOW to prove this feature works from a real
> user's perspective in this specific project.
>
> **Living document.** Phases that uncover new surfaces, new harness needs, or
> new anti-patterns update this file before completing.
>
> **Last updated by**: Setup agent - Phase 0 (initial)

---

## Surface Inventory

Aegis exposes the following user-facing surfaces. Each is independently invokable, and the bar for "actually works" differs per surface.

### Surface 1: PreToolUse hook (`orchestrator.sh`)

- **What it is**: A bash script that Claude Code fires on every tool call before the tool runs.
- **Who calls it**: Claude Code itself, via the plugin's PreToolUse registration in `.claude-plugin/plugin.json`.
- **Entry point**: `orchestrator.sh` at the project root. The plugin manifest references it via `${CLAUDE_PLUGIN_ROOT}/orchestrator.sh`.
- **Wire format**: stdin = PreToolUse JSON (`{tool_name, tool_input, cwd, session_id, transcript_path}`); stdout = Claude Code permission decision JSON or empty; exit code = 0 normal, 2 hard-deny.
- **In scope for this feature**: yes. The entire feature is this hook.

### Surface 2: Individual deterministic layer scripts (`lib/bash-*.sh`, `lib/protected-paths.sh`)

- **What they are**: Pure-bash decision scripts that the orchestrator composes into pipelines. Each is also a callable surface in its own right -- the test corpus harness exercises them directly.
- **Who calls them**: The orchestrator, the bash test harness (`tests/bash/run.sh`), and developers running ad-hoc `echo '<json>' | lib/<layer>.sh`.
- **Entry points**: `lib/bash-denylist.sh`, `lib/bash-hard-ask.sh`, `lib/bash-gatekeeper.sh`, `lib/protected-paths.sh`.
- **Wire format**: same stdin shape as the orchestrator (subset of fields each cares about). stdout is either a permission decision JSON fragment or empty; exit code 0 (or 2 for bash-denylist match).
- **In scope**: yes. Phase 1 vendors `bash-gatekeeper.sh` + `bash-denylist.sh`; Phase 2 implements `bash-hard-ask.sh` + `protected-paths.sh`.

### Surface 3: Python classifier (`python3 -m classifier`)

- **What it is**: The slow path. A Python package that the orchestrator pipes the same PreToolUse JSON to when no deterministic layer fired.
- **Who calls it**: Primarily `orchestrator.sh` via subprocess. Also independently invokable via `echo '<json>' | env PYTHONPATH=. python3 -m classifier` for development testing.
- **Entry point**: `classifier/__main__.py`. Phase 3 lands a placeholder; Phase 7 lands the full chain orchestration.
- **Wire format**: stdin = PreToolUse JSON; stdout = Claude Code permission decision JSON (always one of allow/deny/ask -- never silent, since the orchestrator only calls the classifier when no deterministic layer matched).
- **In scope**: yes.

### Surface 4: `bin/aegis` CLI

- **What it is**: A Python script with subcommands for session control and snapshot refresh.
- **Who calls it**: The user (interactively, from a shell), the slash commands (which shell out to it), and tests (with `AEGIS_STATE_DIR` redirected).
- **Entry point**: `bin/aegis`. Subcommands: `status`, `on`, `off`, `refresh-rules`. Phase 8 builds it.
- **Wire format**: argparse. Stdout is human-readable text. Exit code 0 normal, non-zero on error.
- **In scope**: yes.

### Surface 5: Slash commands (`/aegis-on`, `/aegis-off`, `/aegis-status`)

- **What they are**: Markdown command files registered by the plugin manifest. Each shells out to `bin/aegis` with `--session "$CLAUDE_SESSION_ID"`.
- **Who calls them**: The user, by typing `/aegis-on` in Claude Code.
- **Entry points**: `commands/aegis-on.md`, `commands/aegis-off.md`, `commands/aegis-status.md`. Phase 8 builds them.
- **Wire format**: Claude Code's slash command convention -- the markdown body contains a `!`-prefixed shell command line that is executed.
- **In scope**: yes.

**Visual surfaces**: none. Aegis has no UI. `VISUAL_QA_CHECKLIST.md` does not apply.

---

## User Loop

For each surface, the minimal sequence a real user (or downstream consumer) performs and what they observe.

### Loop 1: Routine command, fast path (Surface 1, via Surface 2)

User asks Claude Code to run `ls`. Claude Code emits PreToolUse JSON with `tool_name="Bash"`, `tool_input.command="ls"`. The hook fires `orchestrator.sh`. The pipeline:

1. **Invocation** (what happens at the surface): `echo '{"tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/tmp","session_id":"loop1"}' | ./orchestrator.sh`
2. **Observable outcome**: stdout = `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}`. Exit code 0. No Python startup. No subprocess to gemini/claude. Latency < 50ms.
3. **Why this is the test**: routine commands are >90% of traffic. If they hit the LLM, the project failed its design goal (zero-token fast path).

### Loop 2: Catastrophic command, hard-deny (Surface 1, via Surface 2)

User asks Claude Code to run `rm -rf /`. The pipeline:

1. **Invocation**: `echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | ./orchestrator.sh`
2. **Observable outcome**: stderr contains `bash-denylist: rm -rf targeting root-level path...`. stdout is empty. Exit code 2. Claude Code blocks the tool call.
3. **Why this is the test**: hard-deny is the irreversible-damage gate. It must NEVER be overridable by any later layer or by Claude Code's normal permission system.

### Loop 3: Risky command, hard-ask (Surface 1, via Surface 2)

User asks Claude Code to run `git push --force`. The pipeline:

1. **Invocation**: `echo '{"tool_name":"Bash","tool_input":{"command":"git push --force"}}' | ./orchestrator.sh`
2. **Observable outcome**: stdout = `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"git push with force flag"}}`. Exit code 0. Classifier was NOT called (no Python startup, no subprocess).
3. **Why this is the test**: hard-ask is the "always-prompt-human" carve-out. It must never be lost by reaching the classifier (which might have allowed). The `permissionDecisionReason` field is what Claude Code displays to the user.

### Loop 4: Novel command, classifier slow path (Surface 1, via Surface 3)

User asks Claude Code to run `foobar quux`. No layer matches. Pipeline:

1. **Invocation**: `echo '{"tool_name":"Bash","tool_input":{"command":"foobar quux"},"session_id":"loop4","cwd":"/tmp","transcript_path":""}' | ./orchestrator.sh`
2. **Observable outcome**: stdout is one of the three Claude Code permission decision JSONs (allow/deny/ask). The exact value depends on the classifier; the test asserts it is one of those three (well-formed JSON with `permissionDecision` in the valid set). `~/.cache/aegis/decisions.jsonl` gets a new row with `layer="classifier"` and `model="gemini-3.1-flash-lite-preview"` (or whichever provider in the chain succeeded). Exit code 0.
3. **Why this is the test**: this exercises the slow path end-to-end -- transcript parse, prompt assembly, subprocess invocation, response parse, state update, diag emit. Phase 7's primary verification.

### Loop 5: Protected-path edit (Surface 1, via Surface 2)

User asks Claude Code to write to `/etc/passwd`:

1. **Invocation**: `echo '{"tool_name":"Edit","tool_input":{"file_path":"/etc/passwd"}}' | ./orchestrator.sh`
2. **Observable outcome**: stdout = `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"writes inside /etc"}}`. Exit code 0. Classifier was NOT called.
3. **Why this is the test**: protected-paths must short-circuit the LLM. Letting the LLM decide whether `/etc/passwd` is OK to edit would be a security regression.

### Loop 6: Read-only fast path (Surface 1)

User asks Claude Code to run `Read` on a file:

1. **Invocation**: `echo '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}' | ./orchestrator.sh`
2. **Observable outcome**: stdout = `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}`. Exit code 0. No layer scripts called, no Python startup.
3. **Why this is the test**: Read/Glob/Grep/Todo*/Task* are harmless and must instant-allow. Mirrors Anthropic's own auto-mode behavior.

### Loop 7: Session toggle off (Surface 4 / Surface 5)

User runs `/aegis-off` or `bin/aegis off --session abc123` then triggers another tool call:

1. **Invocation**:
   - `bin/aegis off --session abc123` (CLI surface)
   - then `echo '{"tool_name":"Bash","tool_input":{"command":"foobar"},"session_id":"abc123","cwd":"/tmp"}' | ./orchestrator.sh`
2. **Observable outcomes**:
   - CLI prints `Aegis disabled for session abc123` and writes `~/.cache/aegis/sessions/abc123.json` with `enabled=false, paused_reason="manual"`.
   - Subsequent orchestrator call falls through silently (empty stdout, exit 0) because the classifier saw `enabled=false`. (Note: deterministic bash layers still run -- only the classifier slow path respects `enabled`.) For a novel command that would normally hit the classifier, the orchestrator emits empty stdout and Claude Code reverts to its normal permission prompt.
3. **Why this is the test**: the toggle is the user's emergency brake. It must persist across hook invocations within the same session.

### Loop 8: Session toggle on after auto-pause (Surface 3, Surface 4)

After 3 consecutive denies, the classifier auto-pauses. User runs `/aegis-on`:

1. **Invocation**: trigger 3 denies via classifier mock, then `bin/aegis on --session xyz789`
2. **Observable outcome**: state file `xyz789.json` has `enabled=true, consecutive_denies=0, paused_reason=null`. Subsequent classifier calls work again.
3. **Why this is the test**: auto-pause + manual unpause is the runaway-deny safety net. Must clear consecutive counters on resume.

---

## Verification Mechanics

The minimum harness needed to perform the user loops against the real code in this environment.

### Mechanic 1: Stdin fixture pipe -> bash script

The primary harness for Surfaces 1 and 2. No daemon, no port, no DB -- each invocation is a fresh subprocess. Test like this:

```bash
echo '<fixture-json>' | ./orchestrator.sh         # full pipeline
echo '<fixture-json>' | lib/bash-gatekeeper.sh    # single layer
```

Read stdout and exit code; that is the entire observable outcome. The harness does NOT need a test framework -- a shell script that pipes fixtures and asserts is sufficient.

This mechanic exists already in skeleton form in `~/Sync/Programs/bash-gatekeeper/tests/run.sh`. Phase 2 vendors that harness and extends it to dispatch four corpora to four layer scripts.

### Mechanic 2: Corpus-driven bash regression

`tests/bash/run.sh` reads `tests/bash/corpus/*.txt` (one command per line, `#` comments allowed, trailing `\` for multiline assembly). For each corpus, it pipes JSON to the matching layer script and asserts the expected decision. Output: `passed: N failed: M notices: K`.

Used for: should-allow.txt (gatekeeper must ALLOW), should-deny.txt (denylist must DENY/exit-2), should-ask.txt (hard-ask must ASK), protected-paths.txt (protected-paths must ASK on Edit/Write/NotebookEdit).

### Mechanic 3: End-to-end orchestrator harness

`tests/bash/orchestrator-cases.sh` pipes various PreToolUse JSON shapes through `orchestrator.sh` and asserts the layer dispatch + decision. Uses `AEGIS_TEST_MOCK_DECISION=ask` env to short-circuit the classifier subprocess (otherwise tests would burn `gemini` calls and tokens). Phase 3 builds this.

```bash
AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh
```

After Phase 7 (real classifier exists), running without the env var hits the placeholder Phase 3 classifier (which returns `ask`) -- still safe and meaningful.

### Mechanic 4: Pytest with mocked subprocess

Python tests use `tmp_path`, `monkeypatch.setattr(state, "STATE_DIR", tmp_path)`, and `monkeypatch.setattr(subprocess, "run", MagicMock(...))` to avoid touching real disk locations or invoking real CLIs. Standard pytest discipline.

```bash
uv run python -m pytest tests/python/ -v
```

Per-module test files: `test_state.py`, `test_rules.py`, `test_transcript.py`, `test_prompt.py`, `test_decision.py`, `test_providers.py`, `test_main.py`, `test_diag.py`, `test_cli.py`.

### Mechanic 5: Independent classifier invocation

For Phase 7 development, the full classifier path is independently invokable:

```bash
echo '{"tool_name":"Bash","tool_input":{"command":"foobar"},"session_id":"dev1","cwd":"/tmp","transcript_path":""}' | env PYTHONPATH=. python3 -m classifier
```

This returns a Claude Code permission decision JSON on stdout. Useful for debugging the chain without going through `orchestrator.sh`.

### Mechanic 6: Real CLI smoke (Phase 9 only)

Phase 9 final integration smoke runs the full pipeline against the **real** `gemini` CLI (not mocked). Gated behind `AEGIS_TEST_LIVE=1` so it doesn't burn tokens in CI. Manually run once at end of Phase 9:

```bash
echo '{"tool_name":"Bash","tool_input":{"command":"some novel cmd"},"session_id":"smoke","cwd":"/tmp","transcript_path":""}' | ./orchestrator.sh
tail -1 ~/.cache/aegis/decisions.jsonl
```

Expected: a valid permission decision JSON on stdout (allow/deny/ask), and a JSONL row with `layer="classifier"` and a real `model` value.

### Mechanic 7: CLI subcommand harness

`tests/python/test_cli.py` invokes `bin/aegis` as a subprocess with `AEGIS_STATE_DIR` redirected to `tmp_path`. Asserts state file shape and stdout content.

```python
subprocess.run(["bin/aegis", "off", "--session", "s1"], env={"AEGIS_STATE_DIR": str(tmp_path), ...})
```

### Mechanic 8: Slash command verification (manual, deferred)

Slash command files are markdown wrappers around `bin/aegis`. They cannot be unit-tested directly because they require a running Claude Code session to invoke. Phase 8 verifies via:
1. The plugin manifest references all three command files (`jq . .claude-plugin/plugin.json`).
2. The shell command in each markdown body is the correct invocation.
3. Manual test: install via `install.sh`, restart Claude Code, type `/aegis-status` in a session, observe state output.

The first two are automatable. The third is a one-time manual smoke at the end of Phase 8.

---

## Anti-Patterns

Project-specific verification anti-patterns that would let a bug pass.

### AP1: Importing classifier modules directly and skipping the wire format

Bad: `from classifier import __main__; __main__.main_internal(payload)` -- this bypasses stdin parsing, JSON decode error handling, and the session_id extraction. A bug in stdin handling wouldn't show up.

Good: in `test_main.py`, monkeypatch `sys.stdin` with `io.StringIO(json.dumps(payload))` so the full `main()` function is exercised, including JSON parsing.

### AP2: Real subprocess calls to gemini/claude in unit tests

Bad: letting `test_providers.py` actually invoke `gemini`. This burns tokens, is slow, depends on network, and produces non-deterministic output. The provider tests must verify the subprocess shape (correct argv, correct env, correct stdin), not the actual model response.

Good: `monkeypatch.setattr(subprocess, "run", MagicMock(return_value=fake))`. The fake's `returncode`, `stdout`, `stderr` are explicit. Tests assert the call shape and that `run_with_retry` correctly handles success/timeout/exhaustion.

The only place real CLI calls are allowed: Phase 9 smoke, gated by `AEGIS_TEST_LIVE=1`.

### AP3: Tests that touch real `~/.cache/aegis/` or `~/.config/aegis/`

Bad: `state.save(SessionState(session_id="test"))` without monkeypatch. This pollutes the user's actual session state.

Good: every state-touching test uses `monkeypatch.setattr(state, "STATE_DIR", tmp_path)` BEFORE `load`/`save`. CLI tests pass `AEGIS_STATE_DIR` env var via subprocess `env={...}`.

### AP4: Asserting only exit code for layer scripts

Bad: `lib/bash-hard-ask.sh < fixture.json; [ $? -eq 0 ]` -- this passes whether the script emitted decision JSON or empty (silent fall-through). The bug would be: layer matched correctly but emitted malformed JSON.

Good: capture stdout. Match against `"permissionDecision":"ask"` substring (the corpus runner does this). For silent fall-through tests, assert `stdout` is empty AND exit code is 0.

### AP5: Skipping silent fall-through assertions

Bad: corpus has a `should-ask.txt` line `git push --force`. Test checks "matches give ASK". But there's no test ensuring that lines NOT in the corpus do NOT match (the layer must silently fall through).

Good: include negative cases in `tests/bash/orchestrator-cases.sh`. Examples: `git status` should reach gatekeeper (allow), not hard-ask. `ls` should reach gatekeeper (allow), not denylist. The orchestrator-cases harness explicitly asserts which layer fired by inspecting the decision/exit-code combination.

### AP6: Mocking the snapshot and missing real-world rule volume

Bad: `test_rules.py` always uses a 3-line synthetic snapshot. Production snapshots from `claude auto-mode defaults` are much larger. A bug like "prompt builder truncates the allow list at 100 chars" would pass tests with a 3-line fixture.

Good: at least one test reads the real `rules/snapshot.json` (vendored in Phase 4 by running `claude auto-mode defaults`) and asserts the prompt contains expected sections. If the real snapshot is unavailable (CI without `claude` CLI), use a fixture sized to match production (~50+ rules).

### AP7: Letting `set -e` propagate into pipeline scripts

Bad: a layer script with `set -e` at the top will abort on the first non-zero return inside it (e.g. `grep -q` not matching). This breaks silent fall-through.

Good: layer scripts use `set -u` only. Failures on `grep -q` are intended (no match means no decision); the script's own logic decides when to exit.

### AP8: Forgetting to test the orchestrator's "fall to next layer" behavior

Bad: testing each layer in isolation but not testing that the orchestrator correctly skips a layer that emitted empty stdout and proceeds to the next. The bug would be: orchestrator captures empty stdout but emits it as the decision (Claude Code parses empty as fall-through; the user gets prompted normally instead of going to the classifier).

Good: orchestrator-cases.sh fixtures that test "novel cmd reaches classifier" and "ls reaches gatekeeper, not classifier" verify the dispatch logic explicitly.

### AP9: Installing the in-development hook into the user's live `~/.claude/`

Bad: copying `orchestrator.sh` into `~/.claude/plugins/aegis/` for "easier testing". This is the user's actual machine; a buggy in-progress hook would gate every tool call in every Claude Code session.

Good: test exclusively via `echo '<fixture>' | ./orchestrator.sh` and `tests/bash/run.sh` from the dev tree. Phase 9's final integration smoke runs the same way (no install). The actual install step happens at the very end via `install.sh` and is tested for idempotency only -- not for "did it work in production sessions".

---

## Required Harness Deliverables

### Phase 1 (scaffold + vendor)

- `pyproject.toml` with pytest config -- enables `uv run pytest` and `python3 -m pytest`.
- `classifier/log.py` -- logging setup function (loguru or stdlib logging; Phase 1 picks).
- `.gitignore` -- standard exclusions (`__pycache__`, `.pytest_cache`, `.aegis-cache`, `*.pyc`).
- `lib/bash-gatekeeper.sh` and `lib/bash-denylist.sh` vendored verbatim from existing repos. These are the harness for `should-allow.txt` and `should-deny.txt` corpora.

### Phase 2 (bash deterministic layers + tests)

- `tests/bash/run.sh` -- vendored from `~/Sync/Programs/bash-gatekeeper/tests/run.sh` and adapted to dispatch four corpora to four layer scripts. (The vendored script handles only allow/deny; Phase 2 extends it to also handle ask + protected-paths corpora.)
- `tests/bash/corpus/should-allow.txt` -- vendored from bash-gatekeeper repo (~342 lines).
- `tests/bash/corpus/should-deny.txt` -- combined: vendored from bash-gatekeeper repo (~227 lines) + the Aegis-specific deny patterns from `docs/superpowers/plans/2026-04-30-aegis.md` Task 3 Step 3 (nuclear rm, curl-pipe-sh, AI attribution scrubs).
- `tests/bash/corpus/should-ask.txt` -- new, populated from Task 4 Step 1.
- `tests/bash/corpus/protected-paths.txt` -- new, populated from Task 5 Step 1.
- `tests/bash/corpus/known-not-allowed.txt` -- vendored from bash-gatekeeper, NOTICE-bucket entries.

### Phase 3 (orchestrator + Python skeleton)

- `tests/bash/orchestrator-cases.sh` -- new end-to-end orchestrator harness. Exercises read-only fast path, bash gatekeeper, hard-deny, hard-ask, protected-paths, novel-cmd. Uses `AEGIS_TEST_MOCK_DECISION` env to bypass real classifier.
- `tests/python/conftest.py` -- pytest config that adds the project root to `sys.path` so `from classifier import ...` works.
- `AEGIS_TEST_MOCK_DECISION` mechanism -- built into `orchestrator.sh` itself (a small `mock_classifier` shell function near the top that returns a hardcoded decision when the env var is set).

### Phase 4 (state + rules)

- `rules/snapshot.json` -- fetched once via `claude auto-mode defaults` and committed.
- `rules/snapshot.meta.json` -- `{fetched_at, source, ttl_days}`.
- All state/rules tests use `tmp_path` + `monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", tmp_path / "global.toml")` etc.

### Phase 5 (transcript + prompt + decision)

- `tests/fixtures/transcript.minimal.jsonl` -- 4-entry fixture (no tool_results).
- `tests/fixtures/transcript.with_results.jsonl` -- 5-entry fixture including tool_result blocks (the parser must strip them).

### Phase 6 (providers)

- All provider tests mock `subprocess.run` via `monkeypatch.setattr(subprocess, "run", MagicMock(...))`. No real CLI invocations.

### Phase 7 (main + diag)

- `tests/python/test_main.py` uses fixtures `fake_stdin` and `capture_stdout` (defined in conftest.py or the test file itself) to monkeypatch `sys.stdin` and `sys.stdout`.
- `tests/python/test_diag.py` uses `tmp_path` for the JSONL output target.

### Phase 8 (CLI + slash commands)

- `tests/python/test_cli.py` invokes `bin/aegis` as a subprocess with `AEGIS_STATE_DIR=<tmp_path>` env override.
- Slash command verification: `jq . .claude-plugin/plugin.json` to confirm the `commands` array references all three .md files.

### Phase 9 (install + smoke)

- `install.sh` -- exercised via `./install.sh && ./install.sh` to verify idempotency.
- `AEGIS_TEST_LIVE=1` smoke against real `gemini` -- one manual invocation at end of Phase 9, not part of the default test suite.

---

## How Agents Use This Document

**Setup agent (this run)**: Filled this document from the project description, codebase context, and the existing 19-task plan. The surfaces, loops, mechanics, and anti-patterns are project-specific and concrete.

**Phase planner (during step 7.5)**: Reads this document in full. Derives 3-7 phase-specific functional checks for the phase's "Functional QA" section. Each check references one of the user loops above and names the concrete invocation + observable outcome.

**Coding agent (during phase execution)**: Reads this document plus the phase plan's "Functional QA" section. Runs each check using the verification mechanics. Captures the actual command, the actual output, and a pass/fail verdict in the phase summary's "Functional QA Results" section. Watches for the anti-patterns above.

**Checkpoint agent**: Validates that phase summaries for any phase that ships user-facing behavior include "Functional QA Results" with real surface invocations and outputs. Missing or hand-waved results = checkpoint failure.
