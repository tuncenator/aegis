# Phase 9: install.sh + README + integration smoke

**Feature**: project-initiation
**Estimated Context Budget**: ~30k tokens

**Difficulty**: easy
**Visual**: no
**Functional**: yes

**Execution Mode**: sequential
**Batch**: 8

---

## Objective

Ship the idempotent installer, the full README (replacing Phase 1's skeleton), and run the end-to-end integration smoke that proves the entire pipeline (Phases 1-8) works together. This phase produces no new application code -- it ships distribution artifacts and is the project's final acceptance gate before v1 is feature-complete.

The Phase 9 coder is responsible for confirming end-to-end correctness, not just shipping `install.sh` and `README.md`. If any smoke run fails, diagnose and either fix (small change in this phase) or surface as a checkpoint failure for the prior phase.

---

## Deliverables

1. **`install.sh`** at project root: idempotent bash installer with `chmod +x` set. Verbatim source listed in "Detailed Requirements" below.
2. **`README.md`** at project root: full README replacing the Phase 1 skeleton (~5 lines, "## Status: in development."). Verbatim source listed in "Detailed Requirements" below.
3. **Integration smoke runs** (manual verification): seven runs documented in the phase summary's Functional QA Results section. These are NOT added to the project's automated test command.
4. **Spec coverage cross-check**: confirm every row in plan lines 3037-3060 maps to a delivered phase. Document the cross-check verdict in the phase summary.

File ownership: Phase 9 owns `install.sh` and `README.md` (REPLACES Phase 1 skeleton). Phase 9 does NOT modify any other file.

---

## Detailed Requirements

### Step 1: Verify cwd and prior phases

```bash
pwd  # must output: /home/tunc/Sync/Programs/aegis
ls -la .claude-plugin/plugin.json orchestrator.sh lib/bash-denylist.sh lib/bash-hard-ask.sh lib/bash-gatekeeper.sh lib/protected-paths.sh classifier/__main__.py bin/aegis commands/aegis-on.md commands/aegis-off.md commands/aegis-status.md
```

Each file above is a Phase 1-8 deliverable that `install.sh` will link, that `README.md` will reference, or that the integration smoke will exercise. If any are missing, stop and surface a checkpoint failure for the prior phase rather than proceeding.

### Step 2: Write `install.sh` (verbatim from plan Task 18 Step 1)

Write the following to `/home/tunc/Sync/Programs/aegis/install.sh`. Then `chmod +x install.sh`.

```bash
#!/usr/bin/env bash
# Aegis installer.
# Performs only out-of-plugin setup. Hook + slash command registration is
# handled automatically by the Claude Code plugin format (.claude-plugin/plugin.json).

set -e
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Determine plugin install path. Prefer ~/Sync/.claude/plugins for synced setups.
if [ -d "$HOME/Sync/.claude" ]; then
  PLUGIN_BASE="$HOME/Sync/.claude/plugins"
else
  PLUGIN_BASE="$HOME/.claude/plugins"
fi
mkdir -p "$PLUGIN_BASE"

# 2. Copy or symlink the plugin tree.
if [ -L "$PLUGIN_BASE/aegis" ] || [ -d "$PLUGIN_BASE/aegis" ]; then
  echo "aegis plugin already installed at $PLUGIN_BASE/aegis"
else
  ln -s "$DIR" "$PLUGIN_BASE/aegis"
  echo "Linked plugin: $PLUGIN_BASE/aegis -> $DIR"
fi

# 3. Vendor a fresh rule snapshot.
if [ ! -s "$DIR/rules/snapshot.json" ]; then
  echo "Fetching initial rule snapshot..."
  "$DIR/bin/aegis" refresh-rules || echo "warning: refresh-rules failed; proceeding with empty snapshot"
fi

# 4. Symlink the CLI into ~/.local/bin if that dir exists.
if [ -d "$HOME/.local/bin" ]; then
  if [ ! -L "$HOME/.local/bin/aegis" ]; then
    ln -s "$DIR/bin/aegis" "$HOME/.local/bin/aegis"
    echo "Linked CLI: $HOME/.local/bin/aegis -> $DIR/bin/aegis"
  fi
else
  echo "note: ~/.local/bin doesn't exist; add $DIR/bin to PATH yourself or 'mkdir ~/.local/bin && rerun'"
fi

# 5. Write a starter config if missing.
CONFIG_DIR="$HOME/.config/aegis"
if [ ! -f "$CONFIG_DIR/aegis.toml" ]; then
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_DIR/aegis.toml" << 'EOF'
[classifier]
chain = [
  { provider = "gemini", model = "gemini-3.1-flash-lite-preview", retries = 2, timeout_s = 8 },
  { provider = "gemini", model = "gemini-3-flash-preview",        retries = 1, timeout_s = 8 },
  { provider = "claude", model = "claude-haiku-4-5",              retries = 1, timeout_s = 8 },
]
on_exhaustion = "ask"

[counters]
consecutive_deny_limit = 3
total_deny_limit = 20

[rules]
snapshot_ttl_days = 14

[context]
last_user_messages = 10
include_claude_md = true
claude_md_max_tokens = 4000

[environment]
trusted_orgs    = ["ONLAYER", "Onlayer"]
trusted_domains = ["onlayer.com", "*.onlayer.com", "atlassian.net", "hubapi.com"]
trusted_buckets = []
trusted_services = ["FGT_001_CLAUDE", "VICAR", "STORMTREE", "CORPSEFIRE"]

[logging]
diag_path = "~/.cache/aegis/decisions.jsonl"
level = "info"
EOF
  echo "Wrote starter config: $CONFIG_DIR/aegis.toml"
else
  echo "Config already present: $CONFIG_DIR/aegis.toml"
fi

echo
echo "Aegis installed."
echo "Restart Claude Code to load the plugin."
```

After write:

```bash
chmod +x /home/tunc/Sync/Programs/aegis/install.sh
```

**Constraints:**
- The file must use `#!/usr/bin/env bash` and `set -e` + `set -u` exactly as shown.
- Step 1 MUST detect `~/Sync/.claude` first (the user's syncthing setup; documented in CLAUDE.md user identity), only falling back to `~/.claude/plugins` when that directory is absent.
- Every step MUST have a "skip if already present" branch so the second run is fully idempotent.
- The installer MUST NOT modify the user's `~/.claude/settings.json`. The plugin format auto-discovers plugins from `~/.claude/plugins/`.
- The TOML body inside the heredoc MUST be byte-identical to the block above (whitespace, ordering, comma placement). The starter config encodes the user's trusted orgs/services -- changing it changes runtime behavior.

### Step 3: Replace `README.md` (verbatim from plan Task 19 Step 1)

The Phase 1 skeleton is roughly 5 lines (`## Status: in development.`). Overwrite it with the following content. Use the Read tool first to confirm it exists, then Write to replace.

```markdown
# Aegis

Self-hosted, LLM-agnostic replacement for Claude Code's `auto` permission mode.

Aegis runs every tool call through a layered permission pipeline using a
PreToolUse hook. Routine commands traverse a deterministic fast path that costs
zero LLM tokens; the LLM (default: `gemini-3.1-flash-lite-preview`) only fires
for novel or non-Bash actions. Works on any Claude Code plan, any model, any
provider. Anthropic's gated `auto` mode is never invoked.

## Pipeline

```
Bash:   bash-denylist (DENY) -> bash-hard-ask (ASK) -> bash-gatekeeper (ALLOW) -> classifier
Edit/Write/NotebookEdit:  protected-paths (ASK) -> classifier
Read/Glob/Grep/TodoWrite/etc.:  ALLOW (no classifier)
```

## Install

```
git clone <this repo>
cd aegis
./install.sh
```

Then restart Claude Code so the plugin loads.

## Configuration

Global: `~/.config/aegis/aegis.toml`
Per-project: `<repo>/.aegis/aegis.toml`

See [design spec](docs/superpowers/specs/2026-04-30-aegis-design.md) for the
full schema.

## Toggles

In-session:
- `/aegis-on`     re-enable
- `/aegis-off`    disable (decisions revert to manual prompt)
- `/aegis-status` print current state

CLI:
- `aegis status [--session ID]`
- `aegis on [--session ID]`
- `aegis off [--session ID]`
- `aegis refresh-rules`

## Standalone bash-only mode

Users who want only the deterministic Bash filtering (no LLM stack) can skip
the plugin install and point their `~/.claude/settings.json` PreToolUse hooks
at `lib/bash-gatekeeper.sh` and `lib/bash-denylist.sh` directly.

## Development

```bash
# Run all tests
python3 -m pytest tests/python/ -v
tests/bash/run.sh
AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh
```

## Spec

[docs/superpowers/specs/2026-04-30-aegis-design.md](docs/superpowers/specs/2026-04-30-aegis-design.md)
```

**Constraints:**
- The README MUST NOT contain emojis, unicode, or special characters per the user's CLAUDE.md style preferences. Use plain ASCII headings and plain ASCII pipe diagrams. The pipeline arrows MUST be `->` (hyphen + greater-than), NOT unicode arrows.
- The Pipeline section was rewritten from the plan's verbatim source: the original used the unicode arrow character. Replace every `→` with `->` (the Phase 9 brief explicitly bans unicode in this README). The text content above already has this substitution applied -- write it as shown.
- Headings, code fences, and ordering must match the block above exactly. Do not add a "Status" line, badges, or screenshots.
- Note the README is wrapped in a markdown code fence in this plan for display purposes; when writing the file, write only the markdown content (without the wrapping triple-backticks-markdown / closing triple-backticks). The first line of the file must be `# Aegis`, the last line must be `[docs/superpowers/specs/2026-04-30-aegis-design.md](docs/superpowers/specs/2026-04-30-aegis-design.md)`.

### Step 4: Run integration smoke (manual, document in summary)

These seven runs are MANUAL verification; they are NOT added to the project's default test command. Capture the actual command, the actual stdout/stderr, and a pass/fail verdict for each in the phase summary's Functional QA Results section.

#### Smoke 1: full bash corpus

```bash
cd /home/tunc/Sync/Programs/aegis
tests/bash/run.sh
```

**Expected**: final line reports `PASS=<N> FAIL=0` (N is corpus size, see Phase 2). NOTICE counts >0 are acceptable (known-not-allowed bucket); FAIL must be 0.

#### Smoke 2: orchestrator harness with mocked classifier

```bash
cd /home/tunc/Sync/Programs/aegis
AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh
```

**Expected**: `PASS=10 FAIL=0`.

#### Smoke 3: orchestrator harness against real classifier path

```bash
cd /home/tunc/Sync/Programs/aegis
unset AEGIS_TEST_MOCK_DECISION
tests/bash/orchestrator-cases.sh
```

**Expected**: `PASS=10 FAIL=0`. The novel-cmd test case expects `ask` -- which is what the chain returns either via Phase 7's classifier (default chain) or via the `on_exhaustion="ask"` fallback if no provider answers. Either path is correct.

#### Smoke 4: full pytest suite

```bash
cd /home/tunc/Sync/Programs/aegis
uv run python -m pytest tests/python/ -v
```

**Expected**: every test in `tests/python/test_state.py`, `test_rules.py`, `test_transcript.py`, `test_prompt.py`, `test_decision.py`, `test_providers.py`, `test_main.py`, `test_diag.py`, `test_cli.py` passes. Final line: `passed` count > 0, `failed` count = 0.

#### Smoke 5: end-to-end fast path (no LLM)

```bash
cd /home/tunc/Sync/Programs/aegis
echo '{"tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"smoke","cwd":"/tmp","transcript_path":""}' | ./orchestrator.sh
```

**Expected stdout** (exact):

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}
```

**Expected exit code**: 0. **Expected side effect**: `tail -1 ~/.cache/aegis/decisions.jsonl` shows a row with `"layer":"hard-allow"` and `"decision":"allow"`. (The diag layer name comes from the gatekeeper path; verify it is `hard-allow`, not `classifier`.)

#### Smoke 6 (optional, AEGIS_TEST_LIVE=1): real gemini classifier call

```bash
cd /home/tunc/Sync/Programs/aegis
AEGIS_TEST_LIVE=1 echo '{"tool_name":"Bash","tool_input":{"command":"foobar quux"},"session_id":"smoke2","cwd":"/tmp","transcript_path":""}' | ./orchestrator.sh
```

**Expected**: a single line of valid JSON matching one of the three Claude Code permission decision shapes (`permissionDecision` in `{allow, deny, ask}`). Capture the actual JSON and the actual `tail -1 ~/.cache/aegis/decisions.jsonl` row in the summary.

**Skip rule**: this smoke is OPTIONAL. If `command -v gemini` returns non-zero in this environment, or `gemini -m gemini-3.1-flash-lite-preview -p "test"` fails to authenticate, document the skip explicitly in the summary with the failure reason. Do NOT mark the phase failed for missing live infrastructure.

#### Smoke 7: install.sh idempotency

```bash
cd /home/tunc/Sync/Programs/aegis
./install.sh
echo "=== second run ==="
./install.sh
```

**Expected on first run**: lines starting with `Linked plugin:`, `Linked CLI:` (or the `~/.local/bin` skip note), and `Wrote starter config:` -- depending on the system state. Trailing two lines: blank line, then `Aegis installed.`, then `Restart Claude Code to load the plugin.`. Exit code 0.

**Expected on second run**: lines starting with `aegis plugin already installed at` and `Config already present:`. The CLI symlink line is conditional: it prints nothing if `~/.local/bin/aegis` is already a symlink (which it now is). Exit code 0. No `set -e` abort.

**Anti-pattern guard (AP9)**: do NOT install into a hot Claude Code session and observe live behavior. The idempotency check above + the fast-path smoke (Smoke 5) are the bar. After Smoke 7 leaves a working symlink in `~/.claude/plugins/aegis/` or `~/Sync/.claude/plugins/aegis/`, do not perform any further action that depends on Claude Code reloading. Document what got linked where in the summary; that is the deliverable.

### Step 5: Spec coverage cross-check

Re-read `/home/tunc/Sync/Programs/aegis/docs/superpowers/plans/2026-04-30-aegis.md` lines 3037-3063 (the "Spec coverage check" table). For each row, confirm the listed Task is delivered by one of Phases 1-9. Document the verdict in the summary using this mapping (provided as cross-reference; the coder verifies):

| Spec row (plan Task) | Delivered in phase |
| --- | --- |
| Goals 1-6 | Phases 1-9 collectively |
| Architecture pipeline (Task 6) | Phase 3 |
| File structure (Task 1) | Phase 1 |
| `lib/bash-*.sh` vendored (Task 2) | Phase 1 |
| `lib/bash-hard-ask.sh` (Task 4) | Phase 2 |
| `lib/protected-paths.sh` (Task 5) | Phase 2 |
| `classifier/state.py` (Task 8) | Phase 4 |
| `classifier/rules.py` (Task 9) | Phase 4 |
| `classifier/transcript.py` (Task 10) | Phase 5 |
| `classifier/prompt.py` (Task 11) | Phase 5 |
| `classifier/decision.py` (Task 12) | Phase 5 |
| `classifier/providers/{base,gemini,claude}.py` (Task 13) | Phase 6 |
| `classifier/__main__.py` chain (Task 14) | Phase 7 |
| Decision logging (Task 15) | Phase 7 |
| `bin/aegis` CLI (Task 16) | Phase 8 |
| Slash commands (Task 17) | Phase 8 |
| `install.sh` (Task 18) | Phase 9 (this) |
| README (Task 19) | Phase 9 (this) |
| Plugin manifest (Task 1) | Phase 1 |
| Failure modes (Tasks 8, 12, 13, 14) | Phases 4, 5, 6, 7 |
| Trusted environment in classifier prompt (Tasks 9, 11) | Phases 4, 5 |
| Read-only fast path (Task 6) | Phase 3 |

If any row is unimplemented after running through Phases 1-9, surface as a checkpoint failure with the specific row and the missing artifact path.

### Step 6: Commit

```bash
cd /home/tunc/Sync/Programs/aegis
git add install.sh README.md
git commit -m "Phase 9: idempotent installer + full README"
```

Do NOT amend prior commits. Do NOT push.

---

## Dependencies

**Requires**:
- Phase 1: `.claude-plugin/plugin.json`, `pyproject.toml`, vendored `lib/bash-gatekeeper.sh`, `lib/bash-denylist.sh`, the README skeleton this phase replaces
- Phase 2: `lib/bash-hard-ask.sh`, `lib/protected-paths.sh`, `tests/bash/run.sh` and corpora
- Phase 3: `orchestrator.sh`, `tests/bash/orchestrator-cases.sh`, classifier package skeleton
- Phase 4: `rules/snapshot.json` (used by `install.sh` step 3 freshness check), `classifier/state.py`, `classifier/rules.py`
- Phase 5: `classifier/transcript.py`, `classifier/prompt.py`, `classifier/decision.py`
- Phase 6: `classifier/providers/{base,gemini,claude}.py`
- Phase 7: full `classifier/__main__.py`, `classifier/diag.py`, diag-emit wired into `orchestrator.sh`
- Phase 8: `bin/aegis` (used by `install.sh` step 3 and step 4), `commands/aegis-*.md`

**Enables**:
- Project is feature-complete for v1 after this phase. No subsequent phases.

---

## Completion Criteria

- [ ] `install.sh` exists at project root, is `chmod +x`, byte-identical TOML body inside the heredoc to plan Task 18 Step 1.
- [ ] `README.md` at project root replaces the Phase 1 skeleton with the full content listed above. No emojis, no unicode arrows, no special characters.
- [ ] Smoke 1 (`tests/bash/run.sh`) reports `FAIL=0`. Actual output captured in summary.
- [ ] Smoke 2 (`AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh`) reports `PASS=10 FAIL=0`. Actual output captured.
- [ ] Smoke 3 (`unset AEGIS_TEST_MOCK_DECISION; tests/bash/orchestrator-cases.sh`) reports `PASS=10 FAIL=0`. Actual output captured.
- [ ] Smoke 4 (`uv run python -m pytest tests/python/ -v`) all tests pass. Actual final line captured.
- [ ] Smoke 5 (fast-path orchestrator) returns the exact ALLOW JSON; `decisions.jsonl` row has `layer="hard-allow"`. Actual stdout + tail row captured.
- [ ] Smoke 6 (live gemini, AEGIS_TEST_LIVE=1) either passes with a documented decision JSON, or is explicitly skipped with the documented reason.
- [ ] Smoke 7 (`./install.sh && ./install.sh`) completes both runs with exit 0; second run prints `already installed` / `already present` for each pre-existing artifact.
- [ ] Spec coverage cross-check: every row in plan lines 3037-3060 verified against the delivered phases.
- [ ] Single git commit with message `Phase 9: idempotent installer + full README` containing only `install.sh` and `README.md`.
- [ ] Phase summary file at `docs/agent/project-initiation/summaries/PHASE_09_SUMMARY.md` includes the Functional QA Results section with all seven smoke outputs pasted verbatim.
- [ ] `STATUS.md` updated to mark Phase 9 complete.

---

## Testing Requirements

Phase 9 ships no application code that introduces new unit tests. The full project test suite is exercised by Smokes 1-4 above. Per CODEBASE_CONTEXT.md, the project's default test command is:

```bash
tests/bash/run.sh && AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh && uv run python -m pytest tests/python/ -v
```

The Phase 9 smokes layer additional manual checks on top of this command (Smokes 3, 5, 6, 7 are not in the default suite). Smokes 5 and 7 must be re-runnable without polluting state; if they leave artifacts (e.g. a created `~/.local/bin/aegis` symlink), document that in the summary so the user knows the install state.

---

## Functional QA

> Phase 9 is the final integration smoke. It verifies the complete pipeline (Phases 1-8) end-to-end. Every check below is also a Completion Criterion above. The duplication is intentional: Functional QA is the user-facing surface check; Completion Criteria is the artifact + commit check.

For each check: capture the actual command, the actual stdout/stderr, and a pass/fail verdict in the phase summary's Functional QA Results section. If a check fails, diagnose: small fix here, or surface as checkpoint failure for the prior phase that owns the broken artifact.

- [ ] **(Surface 1, Loop 1) Smoke 1: bash corpus regression.** Run `tests/bash/run.sh` from the project root. Expect the final summary line to report `FAIL=0` (any non-zero PASS count, NOTICE count is allowed and logged separately). Paste full stdout into summary.

- [ ] **(Surface 1, Loop 6) Smoke 2: orchestrator harness with mocked classifier.** Run `AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh`. Expect `PASS=10 FAIL=0`. Paste final summary line.

- [ ] **(Surface 1, Loop 4) Smoke 3: orchestrator harness with real classifier path.** Run `unset AEGIS_TEST_MOCK_DECISION; tests/bash/orchestrator-cases.sh`. Expect `PASS=10 FAIL=0`. The novel-cmd test passes because either the Phase 7 classifier returns `ask` from its default chain, or `on_exhaustion="ask"` fallback fires. Paste final summary line and identify which path produced the decision.

- [ ] **(Surfaces 1+2+3+4) Smoke 4: full pytest suite.** Run `uv run python -m pytest tests/python/ -v`. Expect every test from `test_state.py`, `test_rules.py`, `test_transcript.py`, `test_prompt.py`, `test_decision.py`, `test_providers.py`, `test_main.py`, `test_diag.py`, `test_cli.py` to pass. Paste final summary line (`N passed in S.SSs`).

- [ ] **(Surface 1, end-to-end fast path) Smoke 5: orchestrator gatekeeper short-circuit.** Run `echo '{"tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"e2e1","cwd":"/tmp","transcript_path":""}' | ./orchestrator.sh`. Expect stdout exactly: `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}`. Expect exit code 0. Then `tail -1 ~/.cache/aegis/decisions.jsonl` -- expect a JSON row with `"layer":"hard-allow"` and `"decision":"allow"`. Paste both stdout and the tail row.

- [ ] **(Surface 1, end-to-end slow path; optional)** Smoke 6: live classifier. Run `AEGIS_TEST_LIVE=1 echo '{"tool_name":"Bash","tool_input":{"command":"foobar quux"},"session_id":"e2e2","cwd":"/tmp","transcript_path":""}' | ./orchestrator.sh`. Expect a valid Claude Code permission decision JSON on stdout (one of allow/deny/ask) and a `tail -1 ~/.cache/aegis/decisions.jsonl` row with `"layer":"classifier"` and a non-null `"model"` value. If `gemini` CLI is not configured in this environment, document the skip explicitly with the command output that revealed the missing CLI (`command -v gemini` or the gemini error). Paste actual decision JSON and tail row, OR document the skip.

- [ ] **(Distribution) Smoke 7: install.sh idempotency.** Run `./install.sh && echo "=== second run ===" && ./install.sh`. Expect both runs to exit 0. First run prints `Linked plugin:`, `Linked CLI:` (or `~/.local/bin` PATH note), `Wrote starter config:` (or `Config already present:` if the user's machine already has one), then the trailing `Aegis installed.` / `Restart Claude Code to load the plugin.` lines. Second run prints `aegis plugin already installed at` and `Config already present:` for every artifact that the first run created. Paste full stdout from both runs separated by the marker.

- [ ] **(Distribution) Smoke 8 (post-install verification): the linked CLI works.** After Smoke 7, run `~/.local/bin/aegis status` (or `~/Sync/.claude/plugins/aegis/bin/aegis status` if `~/.local/bin` does not exist). Expect human-readable output describing session state (per Phase 8's CLI). Paste actual stdout. This is NOT a live-Claude-Code check; it exercises the symlinked CLI directly per AP9.

**Anti-patterns this phase is especially prone to (from FUNCTIONAL_QA_STRATEGY.md):**

- **AP9: do NOT install into a hot Claude Code session and observe live behavior.** Smokes 5, 7, 8 are the bar. After Smoke 7 leaves the symlink in place, do not trigger any tool call inside an actual Claude Code session as part of phase verification. The symlink presence + idempotency exit codes are the deliverable.
- **AP3: do NOT touch real `~/.cache/aegis/` outside of Smoke 5/6 traces.** The decision-log tail reads in Smokes 5 and 6 are intentional (they are the observable side effect). Do not run `rm ~/.cache/aegis/decisions.jsonl` mid-smoke or otherwise mutate the user's cache.
- **AP2: do NOT run real gemini calls outside Smoke 6.** Smoke 6 is the only place real LLM tokens are spent in this phase. If a smoke fails and tempting to "just try one more gemini call to see what happens" -- diagnose via mocks/dry-run instead.

---

## Helpers Required

This phase has no helper dependencies. The integration smoke is pure shell + the project's own `bin/aegis` CLI.

---

## External Interfaces Consumed

- **Claude Code plugin discovery convention (`~/.claude/plugins/<name>/.claude-plugin/plugin.json`).** Documented in Anthropic's plugin docs and in the project design spec at `docs/superpowers/specs/2026-04-30-aegis-design.md` lines 326-336. The convention is: a directory at `~/.claude/plugins/<name>` with a valid `.claude-plugin/plugin.json` is auto-discovered and loaded on Claude Code start. The user's syncthing setup uses `~/Sync/.claude/plugins/<name>` instead. **Capture not needed**: this phase does not parse the convention; `install.sh` only writes a symlink that matches it. The convention is encoded in the `if [ -d "$HOME/Sync/.claude" ]` branch of step 1.

- **The full project tree built by Phases 1-8.** `install.sh` consumes `bin/aegis` (Phase 8), `rules/snapshot.json` (Phase 4), `.claude-plugin/plugin.json` (Phase 1), `orchestrator.sh` (Phase 3), and the `lib/`, `classifier/`, `commands/`, `tests/` trees by symlinking the project root into `$PLUGIN_BASE/aegis`. **Capture not needed**: the symlink is the consumption; nothing is parsed. Smoke 5 verifies the link works end-to-end by piping through `./orchestrator.sh`.

---

## Notes

- Phase 1 created a 5-line README skeleton (`## Status: in development.`). Step 3 above OVERWRITES it -- this is the intended file ownership transfer. Phase 9 owns README.md from this point on.
- The plan's Task 19 source uses unicode arrow `→` in the Pipeline section. Per CLAUDE.md style preferences (no unicode in user-facing output) and per the Phase 9 brief's explicit instruction, the README written here uses ASCII `->` instead. The substitution has already been applied in the verbatim block above; do not reintroduce the unicode arrow.
- The plan's Self-Review Notes (lines 3009-3033) describe the same end-to-end smokes 5 and 6 above. The Phase 9 brief expanded this into seven smokes (adding bash corpus, orchestrator harness mocked + real, full pytest, install idempotency) for tighter end-to-end verification. The expanded list is the bar.
- Smoke 5 expects `layer="hard-allow"`. This requires Phase 7 to have wired `diag_emit` into `orchestrator.sh` so the gatekeeper-allow exit path writes a JSONL row. If Phase 7 used a different layer label (e.g. `gatekeeper` or `bash-allow`), accept that label and note the deviation in the summary -- but the column must exist with a non-null value.
- The Phase 9 brief explicitly states the project's default test command after this phase is `tests/bash/run.sh && AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh && uv run python -m pytest tests/python/ -v` -- the seven manual smokes are NOT added to that command. Do not modify `pyproject.toml` or any test runner script to include them.
- Idempotency is the install.sh acceptance bar (Smoke 7), not "live Claude Code session validation." If the second run prints any `Linked` / `Wrote` line for an artifact created during the first run, idempotency is broken -- fix the conditional in install.sh and re-run.
- After Phase 9 completes, the project is feature-complete for v1. There are no follow-on phases. Update STATUS.md accordingly.
