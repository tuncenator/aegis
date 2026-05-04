# AI Agent Quickstart Guide

**Welcome, AI Agent!** This guide will help you navigate and complete your assigned phase efficiently.

---

## Location & Paths

**CRITICAL: Verify your location before starting!**

```bash
pwd  # Should output: /home/tunc/Sync/Programs/aegis
```

### Project Paths

- **Project Root**: `/home/tunc/Sync/Programs/aegis`
- **Feature Docs**: `/home/tunc/Sync/Programs/aegis/docs/agent/project-initiation`

### Path Usage Rules

1. **Stay in project root** - Do NOT `cd` to other directories
2. **All paths are relative to project root** - When you see `lib/bash-gatekeeper.sh`, it means `/home/tunc/Sync/Programs/aegis/lib/bash-gatekeeper.sh`
3. **If confused about location** - Run `pwd` to verify you're in `/home/tunc/Sync/Programs/aegis`
4. **Use relative paths in your work** - Reference files as `lib/bash-gatekeeper.sh` not absolute paths

**Example Path Reference:**
```
Relative path: docs/agent/project-initiation/STATUS.md
Absolute path: /home/tunc/Sync/Programs/aegis/docs/agent/project-initiation/STATUS.md
                ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
                Where pwd should output
```

---

## Your Mission

You are part of a phased development workflow. Your job is to:
1. **Verify your location** (run `pwd` -- should be `/home/tunc/Sync/Programs/aegis`)
2. Identify which phase you're responsible for
3. Gather minimal necessary context
4. Complete your phase according to the plan -- building, verifying, and committing as you go
5. Document your work
6. Update the status for the next agent

---

## File Structure

```
project-root/  <- /home/tunc/Sync/Programs/aegis (where pwd outputs)
+-- docs/
|   +-- agent/
|       +-- project-initiation/   <- Your feature folder
|           +-- QUICKSTART.md              <- You are here
|           +-- PROJECT_PLAN.md            <- Project overview, architecture, cross-cutting
|           +-- STATUS.md                  <- Phase tracker + integrations + deploy config
|           +-- CODEBASE_CONTEXT.md        <- Cumulative codebase knowledge
|           +-- FUNCTIONAL_QA_STRATEGY.md  <- Surface inventory, user loops, anti-patterns
|           +-- PHASE_SUMMARY_TEMPLATE.md  <- Summary template
|           +-- phase_plans/               <- Individual phase plans
|           |   +-- PHASE_01.md
|           |   +-- PHASE_02.md
|           |   +-- ...
|           +-- summaries/                 <- Completed phase summaries
|               +-- PHASE_01_SUMMARY.md
|               +-- PHASE_02_SUMMARY.md
|               +-- ...
+-- docs/superpowers/                      <- Original design + plan (background reading)
|   +-- specs/2026-04-30-aegis-design.md   <- Design spec (source of truth)
|   +-- plans/2026-04-30-aegis.md          <- Detailed 19-task implementation plan
+-- lib/                                   <- Bash decision layers (created Phase 1-2)
+-- classifier/                            <- Python classifier package (created Phase 3-7)
+-- bin/                                   <- aegis CLI (created Phase 8)
+-- commands/                              <- Slash commands (created Phase 8)
+-- rules/                                 <- Vendored Anthropic rule snapshot (created Phase 4)
+-- tests/                                 <- Bash + Python test suites (created Phase 1+)
+-- .claude-plugin/                        <- Plugin manifest (created Phase 1)
+-- orchestrator.sh                        <- The PreToolUse hook entry (created Phase 3)
+-- install.sh                             <- Idempotent installer (created Phase 9)
```

**All paths in this guide are relative to `/home/tunc/Sync/Programs/aegis`**

---

## Your Workflow

### Step 1: Find Your Phase

Read `docs/agent/project-initiation/STATUS.md` to identify:
- Which phase is current (marked as CURRENT)
- Your phase number and name
- Integration settings (Git, Jira, Deployment, Safety Posture)

### Step 2: Get Context

**2a. Read the codebase context** (always, before anything else):
- Read `docs/agent/project-initiation/CODEBASE_CONTEXT.md`
- This contains cumulative knowledge about the codebase from all previous phases
- Use this instead of re-exploring the codebase from scratch
- Only explore further if you need information not covered in this document

**2b. Read recent phase summaries** (up to 2 most recent):
- If you're on Phase 5, read `PHASE_04_SUMMARY.md` and `PHASE_03_SUMMARY.md`
- If you're on Phase 1 or 2, read what's available (or nothing if Phase 1)

**Location**: `docs/agent/project-initiation/summaries/`

### Step 3: Read Your Phase Plan

Open `docs/agent/project-initiation/phase_plans/PHASE_XX.md` where XX is your phase number (zero-padded: 01, 02, ..., 09).

This file contains everything you need for your phase:
- Objective and deliverables
- Detailed requirements
- Dependencies and completion criteria
- Testing requirements

If you also need the big picture (architecture, cross-cutting concerns), read the relevant sections of `docs/agent/project-initiation/PROJECT_PLAN.md` -- but only as needed.

**Do NOT read all phase plan files** -- only read yours.

**Optional reference reading**: The original design spec lives at `docs/superpowers/specs/2026-04-30-aegis-design.md` and the detailed 19-task implementation plan at `docs/superpowers/plans/2026-04-30-aegis.md`. The phase plans are derived from these. Read the relevant tasks (each task in the original plan maps to specific work in your phase) when you want exact source listings or verbatim test fixtures.

### Step 4: Build, Verify, Commit (Repeat)

Follow this cycle for each logical chunk of work in your phase. Do NOT code everything and test at the end -- build incrementally and verify as you go.

#### 4a. Code a Logical Chunk

Implement a coherent piece of functionality (a layer script, a Python module, a function, a test file). Keep chunks small enough to verify independently.

#### 4b. Verify Locally

For every claim you make about your code ("tests pass", "layer returns ALLOW", "function outputs X"), follow this verification gate:

1. **Identify** the command that proves the claim
2. **Run** it fresh -- not from a previous run, not from memory
3. **Read** the full output and check the exit code
4. **Confirm** the output actually proves what you claim

Never claim something works without running the verification command in this session and reading its output. Apply the gate to:

- **Bash layer scripts**: pipe a fixture JSON via stdin and check stdout/exit code. Example: `echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | lib/bash-gatekeeper.sh`
- **Python tests**: `python3 -m pytest tests/python/test_<module>.py -v`. Read the full output.
- **Bash corpus tests**: `tests/bash/run.sh`. Read PASS/FAIL counts.
- **Orchestrator end-to-end**: `AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh` (the env var bypasses the real classifier subprocess; once Phase 7 is done, also test without the env var).
- **Logs**: When a script writes to stderr, read the stderr to confirm log lines look right.

If something is wrong, fix it before continuing -- but follow the debugging protocol below. Do not guess-and-check.

#### When Verification Fails

When a test fails or code doesn't behave as expected, follow this protocol before attempting any fix:

1. **Investigate**: Read the full error output. Don't skim. Trace the failure to its origin -- which file, which line, which value was wrong.
2. **Compare**: Find working code in the same codebase that does something similar. Compare it against your failing code. The difference is usually the bug.
3. **Hypothesize**: Form one specific theory about the root cause. Test it minimally (add a log statement, check an intermediate value) before committing to a fix.
4. **Fix**: Apply a single targeted change. Re-run verification. If it fails again, return to step 1 with the new information -- do not retry the same fix.

Do not make multiple changes at once. One hypothesis, one fix, one verification cycle.

#### 4c. Commit

Stage the changes for this chunk and commit with a descriptive message.

**Format**: `[Phase {N}/9] {verb}: {what changed}`

**Verbs** (lowercase): `add`, `fix`, `update`, `refactor`, `remove`, `docs`

**Examples**:
- `[Phase 1/9] add: project scaffold (.gitignore, plugin manifest, pyproject.toml)`
- `[Phase 2/9] add: bash-hard-ask deterministic ASK layer`
- `[Phase 3/9] add: orchestrator hook with layered pipeline`
- `[Phase 4/9] add: classifier state module with deny counters`
- `[Phase 7/9] fix: malformed-JSON repair re-uses same provider before falling through`

Get {N} from STATUS.md (e.g., "Current Phase: 3 of 9"). Multiple commits per phase is expected and encouraged.

#### 4d. Deploy and Verify on Target (if deployment is enabled)

Deployment is **disabled** for this feature -- Aegis is a local Claude Code plugin installed via `install.sh` to `~/.claude/plugins/aegis/`. There is no remote deploy step. Skip this subsection.

#### 4e. Repeat

Continue the cycle (4a-4c) until all deliverables for your phase are complete.

### Step 5: Document Your Work

**5a. Update the codebase context**:
- Edit `docs/agent/project-initiation/CODEBASE_CONTEXT.md`
- Update the "Last updated by" line at the top to reflect your phase name and today's date
- Add any new files you created (to "Key Files & Modules")
- Add any new APIs, classes, or interfaces you built (to "Important APIs & Interfaces")
- Add any new data models (to "Data Models")
- Update any entries that changed due to your work (renamed files, modified APIs, etc.)
- Remove entries for things that no longer exist
- Keep updates incremental -- do not rewrite sections that are still accurate

**5b. Create your phase summary**:
- **Template**: `docs/agent/project-initiation/PHASE_SUMMARY_TEMPLATE.md`
- **Output location**: `docs/agent/project-initiation/summaries/PHASE_XX_SUMMARY.md`
- **Length**: Keep it concise (~400-500 lines max)

Include:
- What you built
- Files created/modified
- Completion criteria status
- Any challenges or deviations
- Notes for future phases
- **Functional QA Results** (if `Functional: yes`): one entry per Functional QA check from your phase plan, with surface, invocation command, observed outcome (pasted byte-for-byte, not paraphrased), and pass/fail verdict. Reference `docs/agent/project-initiation/FUNCTIONAL_QA_STRATEGY.md` for the project's user loops and verification mechanics.
- **Live Verification Results**: what else you verified during development and how (looser narrative; the structured per-check evidence lives in Functional QA Results above)
- List of all commits made during this phase

### Step 6: Update Status

Edit `docs/agent/project-initiation/STATUS.md`:
1. Mark your phase as Complete
2. Update "Current Phase" to next phase number
3. Update "Phase Name" to next phase name
4. Update "Last Updated" to today's date (YYYY-MM-DD format)

### Step 7: Final Commit and Integration Updates

**Git**: Your code commits are already in the local branch from Step 4c. Now do a final commit for documentation:
1. Stage all doc changes (summary, STATUS.md, CODEBASE_CONTEXT.md, possibly FUNCTIONAL_QA_STRATEGY.md)
2. Commit: `[Phase {N}/9] docs: phase summary and context updates`
3. The branch is `feature/project-initiation`. Push is not configured (no GitHub remote); commits stay local.

**No deployment**: Skip.

**No Jira**: Skip.

### Step 8: Stop

Your work is complete. The next agent will handle the next phase.

---

## Environment Setup

This project uses Python 3.11+ (for `tomllib` from stdlib) and Bash 5+. Python dependency management uses `uv`.

### First-time setup (Phase 1 establishes this):

```bash
# Verify Python and uv are available
python3 --version    # Expect 3.11 or higher
uv --version         # Expect installed
jq --version         # Required for bash hooks

# Phase 1 creates pyproject.toml. After it lands, sync deps:
uv sync               # Creates .venv and installs pytest (and loguru if Phase 1 chose it)
```

### Activation (run once per shell session):

```bash
# uv handles env activation transparently for `uv run` invocations.
# No manual activation needed when using `uv run python ...` or `uv run pytest ...`.
# If you want a traditional venv shell:
source .venv/bin/activate
```

### Common commands for this project:

```bash
# Run all Python tests
uv run python -m pytest tests/python/ -v

# Run a single test module
uv run python -m pytest tests/python/test_state.py -v

# Run bash corpus tests
tests/bash/run.sh

# Run orchestrator end-to-end tests (mocked classifier; safe before Phase 7)
AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh

# Run orchestrator end-to-end tests (real classifier path; only after Phase 7)
unset AEGIS_TEST_MOCK_DECISION
tests/bash/orchestrator-cases.sh

# Smoke test a single layer script
echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | lib/bash-gatekeeper.sh

# Full test suite (used as the verification command at checkpoints)
tests/bash/run.sh && AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh && uv run python -m pytest tests/python/ -v
```

### Notes on dependencies

- The Python classifier targets stdlib only as a hard constraint. The one allowed exception is `loguru` for logging (Phase 1 may swap to stdlib `logging` if dependency surface area is a concern).
- The bash layers depend on `jq` (already required by Claude Code hooks generally) and standard POSIX utilities (`grep`, `sed`).
- The classifier subprocess providers shell out to `gemini` and `claude` CLIs; both are assumed already installed and authenticated on this machine. No SDK-level dependency.

---

## Development Discipline

### Test-First Development

For every behavior you implement: write a failing test first, watch it fail, then write the minimal code to pass it. This is non-negotiable.

1. **RED**: Write test describing expected behavior. Run it. Confirm it fails because the feature is missing (not because of a typo or import error).
2. **GREEN**: Write the simplest code that passes. No extras.
3. **REFACTOR**: Clean up while tests stay green.

**Test commands**:
- Python: `uv run python -m pytest tests/python/test_<module>.py -v`
- Bash: `tests/bash/run.sh`
- Orchestrator: `AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh`

Run after every implementation chunk. If tests fail after your change, debug systematically (see Workflow step 4b) before attempting fixes.

The 19-task plan at `docs/superpowers/plans/2026-04-30-aegis.md` is itself written in TDD style with red/green/commit cadence; follow that cadence within each phase. The phase plan in `phase_plans/PHASE_XX.md` derives its structure from those tasks but groups them by phase.

### Verification Honesty

Before claiming any task is done, run the verification command and read the output. 'Should work' is not evidence. 'Tests likely pass' is not evidence. Run it, read it, report what it actually says.

### Debugging Protocol

When something fails:
1. Read the FULL error (don't skim)
2. Trace backward to the source of the bad value
3. Form ONE hypothesis, test minimally
4. If 3 hypotheses fail: this is architectural, not a bug. Document and escalate.

---

## Project Helpers

This project ships verified helper scripts under `scripts/` that wrap mechanical tasks (Jira, deploy, smoke probes, etc.) so agents don't need to reconstruct them from scratch each phase.

**Coding agents:** consult ONLY the helpers listed in your phase plan's "Helpers Required" section. Do NOT scan this catalog by default -- it exists for reference, for the planner, and for the user. Reaching past your phase plan's allocation usually means the planner under-specified the phase; if you genuinely need a helper that isn't listed, do the work manually this time and record it under your phase summary's "Helper Issues -> Unlisted helpers attempted" subsection.

**Checkpoint agent:** uses deploy/verify-deploy/smoke helpers automatically when configured -- the helper names are in STATUS.md.

No helpers configured for this feature.

---

## Live Verification

**Verify as you build, not just at the end.**

This project uses live verification: every logical chunk of code should be tested against reality before moving on. Do not wait until all deliverables are complete to run the program for the first time.

### Safety Posture

Check `docs/agent/project-initiation/STATUS.md` for the current safety posture.

This project uses CAUTIOUS safety posture. Before performing any write operation to external systems, databases, or services -- even locally -- ASK the user for permission and explain why the operation could be risky. Read-only operations (GET requests, SELECT queries, log reading, running tests) can be performed freely without asking.

### Runtime Context

- **How this runs**: Aegis IS the runtime -- there is no service to start, restart, or reload. Each invocation is a fresh subprocess fired by Claude Code's hook system.
- **Restart after changes**: Not applicable. The next PreToolUse event picks up file changes automatically (Claude Code re-execs the hook). For tests, just re-run the test command.
- **Verify it works**: `tests/bash/run.sh && AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh && uv run python -m pytest tests/python/ -v` (full suite). For ad-hoc smoke: `echo '<fixture-json>' | ./orchestrator.sh` and inspect stdout/stderr/exit code.
- **Never do this**:
  - Never install the developed hook into the live `~/.claude/settings.json` or `~/Sync/.claude/settings.json` while still developing -- that would replace the user's working permission setup. Test by piping fixture JSON via stdin into layer scripts directly.
  - Never let unit tests hit real `gemini` or `claude` CLIs -- mock `subprocess.run` via `monkeypatch`. Live classifier calls are reserved for the Phase 9 end-to-end smoke and are gated by `AEGIS_TEST_LIVE=1`.
  - Never `cp orchestrator.sh ~/.claude/plugins/aegis/` to "test it" -- the install path comes from `install.sh` and is idempotent. If you need to bring up an end-to-end install in this dev tree, use `install.sh` from a clean state and revert afterward.

Always verify against the running system described above. Unit tests are necessary but NOT sufficient to claim a feature works. If you cannot test end-to-end, state that explicitly in your phase summary rather than substituting unit tests.

### What to Verify

The project-specific answer lives in `docs/agent/project-initiation/FUNCTIONAL_QA_STRATEGY.md`. Read it once at the start of the phase. It captures:

- **Surface Inventory** -- what this feature exposes (the PreToolUse hook, the CLI, slash commands, individual layer scripts as testable callables)
- **User Loop** -- the minimal sequence a real user/consumer performs and what they observe
- **Verification Mechanics** -- the concrete harness (stdin fixture pipe, test corpus, pytest, mocked subprocess) needed to perform the loop against the real code
- **Anti-Patterns** -- project-specific traps (mocked tests that bypass the wire format, etc.)
- **Required Harness Deliverables** -- scaffolding the harness needs (vendored bash test runner, pytest config, fixture transcripts)

Your phase plan's "Functional QA" section names the specific checks for THIS phase, derived from the strategy. Run each one against the real surface using the verification mechanics, capture the actual command and actual output byte-for-byte, and record pass/fail in your phase summary's "Functional QA Results" section.

### Write Operation Safety

When you need to test write operations (file creation in user home, ~/.cache, ~/.config, snapshot fetches):

1. **Prefer safe patterns**: Always use `tmp_path` / `tmpdir` fixtures in pytest. Never write to real `~/.cache/aegis/` from a test.
2. **Verify before touching**: Tests that interact with `~/.config/aegis/` or `~/.claude/plugins/aegis/` must monkeypatch the path constants before running.
3. **Never touch the user's actual config**: The starter `~/.config/aegis/aegis.toml` written by `install.sh` already contains the user's trusted orgs/services. Don't run `install.sh` from a test.
4. **If no safe method exists**: Discuss with the user. Explain what you want to test, what the risks are, and ask for guidance.

### Verify Before Coding

If your phase involves interacting with an external API or service:
1. Check CODEBASE_CONTEXT.md first -- the "External Services & APIs" section may have research findings from setup
2. If needed, make a safe read-only call to verify connectivity and current response format
3. THEN write your integration code based on actual observed behavior, not assumptions
4. Do NOT code an entire API client based on training data and then discover the API has changed

For Aegis specifically, the "external" surfaces are the `gemini` and `claude` CLIs. Both are already installed on this machine. If you need to verify their stdout shape (Phase 6 / Phase 9), pipe a tiny prompt and observe -- e.g. `echo "say {\"decision\":\"allow\",\"reason\":\"x\"}" | gemini -m gemini-3-flash-preview -p "echo this verbatim"`.

---

## Context Budget

You have approximately **120k tokens** total (input + output + thinking).

TDD discipline (test-first for every behavior) uses ~30% more tokens than implementation-only. This is budgeted into phase sizing. Don't skip tests to save context.

**Be strategic**:
- Read only what you need
- Follow the workflow above exactly
- Keep summaries concise
- Don't read entire files when you need one function
- Don't read all phase plans when you need one phase
- Don't explore unrelated code

Each phase is designed to fit within one agent session. If you run out of context:
- Note this in your summary
- Document what's incomplete
- Suggest splitting the phase

---

## Important Notes

### Security -- No Credentials in Repository

**CRITICAL: Never store passwords, API keys, tokens, connection strings, or any secrets in repository files.**

- Do NOT hardcode credentials in source code, config files, documentation, or agent framework files
- The starter `~/.config/aegis/aegis.toml` written by `install.sh` includes the user's trusted orgs/services (`ONLAYER`, `Onlayer`, `onlayer.com`, etc.) -- those are not secrets, they are environment hints for the classifier prompt. Still avoid duplicating them into committed code.
- A pre-commit hook is active on this repository to catch accidental credential leaks and to redact `<{LABEL:value}>` markers in agent docs

#### Pre-commit hook block: bypass procedure

Most blocks are real. The hook redacts `<{LABEL:value}>` markers and matches secret-shaped patterns. False positives happen but are not the common case.

**Do NOT bypass with `git commit --no-verify` if any of these are true:**

- The blocked file is under `classifier/`, `lib/`, `bin/`, `commands/`, `rules/`, or any path matching `**/secrets/**`
- The blocked file matches `.env*` (any dotenv variant)
- The matched value looks like a real token (AKIA*, ghp_*, sk_live_*, JWT, private key block, etc.)

If any of the above hold, stop. End your phase with a line naming the blocked file and the pattern (after redaction), so the conductor can surface it to a human. Do NOT bypass.

**Bypass procedure (only when none of the above hold):**

1. Print to your output:
   - **Path**: full path of the blocked file (relative to project root)
   - **Matched pattern**: the value the hook flagged, redacted to `<{LABEL:value}>` form (replace any actual token tail with `***` if you cannot tag it)
   - **Reason it is not a real secret**: one sentence (e.g. "test fixture string in `tests/fixtures/sample-jwt.json`, not used at runtime")
2. Add a `Bypass-reason:` trailer to the commit message body using `git commit --no-verify -m "..." -m "Bypass-reason: <one-line reason>"`. The trailer is what `/spark-status` will count when surfacing bypass usage; commits without the trailer are flagged as unaudited.
3. Commit. The bypass and reason are now in git history for review.

If you bypass without the trailer, the next reviewer (and `/spark-status`) will treat it as an unaudited bypass. Don't.

### Secret Tagging in Documentation

When you need to reference infrastructure-specific values (hostnames, IP addresses, server paths, database names, ports) in agent framework documentation files under `docs/agent/`, use inline tags:

```
<{LABEL:actual_value}>
```

For Aegis, this rarely applies because the project deals with local-only paths and well-known shell commands. The relevant cases are:
- The user's home path (`/home/tunc`) when documenting state file locations -- use `<{HOME:/home/tunc}>` if you need to be explicit, otherwise just write `~`
- Trusted-environment values from `~/.config/aegis/aegis.toml` if you ever copy them into a doc -- use `<{TRUSTED_ORG:ONLAYER}>` etc. (these are not secrets but they identify the user, so apply the redaction discipline)

You always see the real values in your local working copy. Only the committed version is redacted.

### Logging

**Always check logs.** After running code or tests:
1. Check stderr for errors, warnings, or unexpected behavior
2. Check `~/.cache/aegis/decisions.jsonl` (after Phase 7) to see what classifier/layer fired
3. If logs show issues, fix them before proceeding
4. Include relevant log observations in your phase summary

If logging is not yet set up (you are Phase 1), setting it up is a mandatory deliverable -- check your phase plan.

### Phase Boundaries

**Respect phase boundaries.** Do not:
- Work on multiple phases at once
- Skip phases
- Go back and refactor previous phases (unless your phase plan says to)

### Dependencies

If your phase depends on previous phases:
- Check that those phases are marked complete in STATUS.md
- Read their summaries to understand what was built
- Note any blockers in your summary if dependencies are incomplete

### Blockers

If you encounter blockers:
- Document them clearly in your summary
- Mark affected completion criteria as incomplete
- Suggest solutions or next steps
- Do NOT mark your phase as complete if critical items are blocked

---

## Quick Checklist

Before you begin:
- [ ] **FIRST: Run `pwd` and verify you're in `/home/tunc/Sync/Programs/aegis`**
- [ ] Read `docs/agent/project-initiation/STATUS.md` to identify your phase and check safety posture
- [ ] Read `docs/agent/project-initiation/CODEBASE_CONTEXT.md` for codebase knowledge
- [ ] Read `docs/agent/project-initiation/FUNCTIONAL_QA_STRATEGY.md` if your phase has `Functional: yes`
- [ ] Read the 2 most recent phase summaries from `docs/agent/project-initiation/summaries/`
- [ ] Read your phase plan from `docs/agent/project-initiation/phase_plans/PHASE_XX.md`
- [ ] Understand your deliverables and completion criteria

During your work:
- [ ] Stay within your phase boundaries
- [ ] Activate environment before running commands (see Environment Setup section)
- [ ] Build incrementally -- verify each chunk before moving on
- [ ] Check stderr / decisions.jsonl after running code
- [ ] Use `<{LABEL:value}>` for sensitive values in doc files
- [ ] Commit after each verified chunk (multiple commits per phase is fine)
- [ ] Write tests if required (TDD pattern: red, green, refactor)

After completion:
- [ ] Update `docs/agent/project-initiation/CODEBASE_CONTEXT.md` with new discoveries and changes
- [ ] Create phase summary using the template (include Functional QA Results if applicable)
- [ ] Verify all completion criteria are met (or document why not)
- [ ] Update `docs/agent/project-initiation/STATUS.md`
- [ ] Final commit for docs (no push -- no remote configured)
- [ ] Do NOT start the next phase

---

## Ready to Start?

1. Read `docs/agent/project-initiation/STATUS.md`
2. Follow the workflow above
3. Build, verify, commit -- repeat
4. Document and update status

**Good luck, Agent!**

---

*This quickstart is designed for AI agents working in a phased development workflow. For human developers, see the standard project README (created in Phase 9).*
