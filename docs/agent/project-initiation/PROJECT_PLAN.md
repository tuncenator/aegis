# Aegis - Project Plan

**Feature/Initiative**: project-initiation
**Type**: New Project
**Created**: 2026-04-30
**Estimated Total Phases**: 9

---

## Project Location

**IMPORTANT: All paths in this document are relative to the project root.**

- **Project Root**: `/home/tunc/Sync/Programs/aegis`
- **Verify with**: `pwd` -> should output `/home/tunc/Sync/Programs/aegis`

When you see a path like `lib/bash-gatekeeper.sh`, it means `/home/tunc/Sync/Programs/aegis/lib/bash-gatekeeper.sh`.

---

## Project Overview

### Purpose

Aegis is a self-hosted, LLM-agnostic replacement for Claude Code's `auto` permission mode. Anthropic gates auto-mode behind plan tier (Max / Team / Enterprise / API), specific Claude models, and the Anthropic API provider, then bills classifier calls as additional tokens. Aegis provides equivalent behavior using a cheap user-chosen LLM (default: `gemini-3.1-flash-lite-preview`) as the classifier, runs entirely in Claude Code's existing permission system via a single `PreToolUse` hook, and never enters Anthropic's gated auto mode at all.

Routine commands traverse a deterministic fast path that costs zero LLM tokens; the LLM only fires for novel or non-Bash tool calls. The deterministic layer subsumes and continues iterating on the existing `bash-gatekeeper` and `bash-denylist` projects at `~/Sync/Programs/bash-gatekeeper`.

### Scope

**In Scope**:
- PreToolUse hook orchestrator (`orchestrator.sh`) with layered dispatch by tool name
- Deterministic bash layers: `bash-denylist.sh` (hard-deny, exit 2), `bash-hard-ask.sh` (always-prompt), `bash-gatekeeper.sh` (hard-allow)
- Deterministic non-bash layer: `protected-paths.sh` (ASK on Edit/Write/NotebookEdit to protected paths)
- Read-only fast path for Read/Glob/Grep/Todo*/Task* (instant ALLOW, no classifier)
- Python LLM classifier with subprocess-based provider chain (gemini CLI, claude CLI)
- Per-session state with deny counters and auto-pause
- Toggle surfaces: slash commands (`/aegis-on`, `/aegis-off`, `/aegis-status`), CLI (`bin/aegis`)
- JSONL decision log for postmortem and metrics
- Vendored Anthropic rule snapshot via `claude auto-mode defaults`, refreshed on TTL
- Idempotent installer that never touches `settings.json` (Claude Code plugin format auto-discovers)

**Out of Scope (v1)**:
- Multi-agent integrations (Codex, Gemini-CLI, Aider) -- adapter layer is v2
- Bedrock / Vertex / Foundry classifier providers -- subprocess-only in v1
- Subagent special handling (spawn-time gate, return-time review)
- Decision caching (each call evaluated fresh)
- Hard-allow fast path for non-Bash tools (Edit/Write go straight to classifier after protected-paths check)

### Success Criteria

- [ ] PreToolUse hook receives JSON via stdin, returns valid Claude Code permission decision JSON or empty (silent fall-through)
- [ ] Routine bash commands (`ls`, `git status`, `jq ...`) traverse deterministic fast path with zero Python startup and zero LLM tokens
- [ ] Hard-deny exits 2 and cannot be overridden by any later layer
- [ ] Hard-ask emits `permissionDecision: ask` without consulting the classifier
- [ ] Classifier slow path returns `{decision, reason}` JSON parsed into Claude Code hook output, with retry across the configured chain
- [ ] Per-session state correctly increments deny counters, auto-pauses at thresholds, resets on allow
- [ ] CLI subcommands (`status`, `on`, `off`, `refresh-rules`) work standalone and via slash commands
- [ ] Full bash test corpus passes (vendored + new ASK + protected-paths buckets)
- [ ] Full pytest suite passes (state, rules, transcript, prompt, decision, providers, main, diag, cli)
- [ ] End-to-end smoke against the hook with real `gemini` invocation produces a valid decision

---

## Architecture Overview

Single `PreToolUse` hook entry registered in Claude Code's plugin manifest (`.claude-plugin/plugin.json`). The hook is `orchestrator.sh`, which dispatches by `tool_name` through layered decision pipelines.

### Key Components

1. **Orchestrator** (`orchestrator.sh`): Single PreToolUse hook entry. Reads JSON on stdin, dispatches by tool name through layered pipelines.
2. **Deterministic bash layers** (`lib/bash-*.sh`): Pure-bash decision scripts that exit 2 (hard-deny) or emit Claude Code permission JSON (hard-ask, hard-allow). Each is independently callable for testing.
3. **Protected paths layer** (`lib/protected-paths.sh`): Pure-bash ASK gate for Edit/Write/NotebookEdit on Anthropic protected paths plus internal additions.
4. **Classifier** (`classifier/`): Python package, exec-loaded only when no deterministic layer fires. Walks a configured provider chain, applies state-aware deny counters, returns Claude Code permission JSON.
5. **Provider implementations** (`classifier/providers/`): Subprocess wrappers for `gemini` and `claude` CLIs with shared retry/timeout machinery.
6. **State management** (`classifier/state.py`): Per-session JSON file under `~/.cache/aegis/sessions/`. Tracks `enabled`, `consecutive_denies`, `total_denies`, `paused_reason`.
7. **CLI** (`bin/aegis`): Surfaces state control (`on`/`off`/`status`) and snapshot refresh (`refresh-rules`).
8. **Slash commands** (`commands/aegis-*.md`): Thin wrappers around the CLI, exposed by the plugin manifest.
9. **Decision log** (`classifier/diag.py` + bash diag emitter): Appends one JSONL row per decision to `~/.cache/aegis/decisions.jsonl` for postmortem and `aegis status` summaries.

### Data Flow

```
Claude Code PreToolUse fires -> orchestrator.sh receives JSON on stdin
                                |
                                +-- read-only tool (Read/Glob/Grep/Todo*) ?
                                |     -> emit ALLOW, exit 0 (zero LLM)
                                |
                                +-- Bash tool ?
                                |     1. lib/bash-denylist.sh   (exit 2 if matched)
                                |     2. lib/bash-hard-ask.sh   (ASK if matched)
                                |     3. lib/bash-gatekeeper.sh (ALLOW if matched)
                                |     4. classifier/__main__    (LLM decision)
                                |
                                +-- Edit/Write/NotebookEdit ?
                                |     1. lib/protected-paths.sh (ASK if matched)
                                |     2. classifier/__main__    (LLM decision)
                                |
                                +-- everything else (WebFetch, Agent, MCP) ?
                                      -> classifier/__main__    (LLM decision)
                                |
                                v
                  Claude Code permission decision JSON on stdout
                  (or exit 2 for hard-deny, or empty for fall-through)
```

### Technology Stack

- **Languages**: Bash 5+, Python 3.11+
- **Bash deps**: jq (already required by Claude Code hooks)
- **Python deps**: stdlib only (`json`, `tomllib`, `subprocess`, `dataclasses`, `pathlib`, `argparse`)
- **Test deps**: pytest (Python), bash test harness vendored from bash-gatekeeper
- **External CLIs invoked**: `gemini` (default classifier), `claude` (fallback + snapshot refresh)
- **Plugin format**: Claude Code plugin manifest (`.claude-plugin/plugin.json`)

---

## Phase Overview

> **Detailed phase plans are in `phase_plans/PHASE_XX.md`.**
> Only read the plan file for your assigned phase to save context.

| Phase | Name | Objective (one line) | Dependencies |
|-------|------|---------------------|--------------|
| 1 | Scaffold + vendor bash + logging | Repo skeleton, plugin manifest, vendor bash-gatekeeper.sh + bash-denylist.sh, set up Python logging + `.gitignore` + `pyproject.toml` | None |
| 2 | Bash deterministic layers + test corpus | Implement bash-hard-ask.sh and protected-paths.sh, copy bash-gatekeeper test harness + corpora, add new corpora for hard-ask and protected-paths | Phase 1 |
| 3 | Orchestrator + Python skeleton | orchestrator.sh dispatch pipeline, classifier package skeleton with placeholder __main__, end-to-end orchestrator tests | Phase 2 |
| 4 | Classifier state + rules | classifier/state.py (deny counters, pause logic), classifier/rules.py (config + snapshot loader, deep merge global/project) | Phase 3 |
| 5 | Classifier transcript + prompt + decision | classifier/transcript.py (strip tool_results), classifier/prompt.py (system + user prompts), classifier/decision.py (parse + format) | Phase 4 |
| 6 | Provider chain | classifier/providers/{base,gemini,claude}.py with retry/timeout machinery and CCSWAP_NORENAME guard | Phase 5 |
| 7 | Classifier main + diag logging | classifier/__main__.py chain orchestration, classifier/diag.py JSONL writer, wire diag into orchestrator.sh deterministic layers | Phase 6 |
| 8 | bin/aegis CLI + slash commands | bin/aegis (status/on/off/refresh-rules), commands/aegis-{on,off,status}.md slash command wrappers | Phase 7 |
| 9 | install.sh + README + integration smoke | Idempotent installer, full README, end-to-end smoke against real gemini, full test suite | Phase 8 |

---

## Phase Dependencies Graph

```
Phase 1 (Scaffold + vendor bash + logging)
    |
    v
Phase 2 (Bash deterministic layers + test corpus)
    |
    v
Phase 3 (Orchestrator + Python skeleton)
    |
    v
Phase 4 (Classifier state + rules)
    |
    v
Phase 5 (Classifier transcript + prompt + decision)
    |
    v
Phase 6 (Provider chain)
    |
    v
Phase 7 (Classifier main + diag logging)
    |
    v
Phase 8 (CLI + slash commands)
    |
    v
Phase 9 (install.sh + README + integration smoke)
```

The chain is largely linear -- each phase consumes interfaces built in the previous one. Some internal parallelism exists within Phase 4 (state.py and rules.py are independent) and Phase 5 (transcript/prompt/decision overlap only via shared dataclasses), but cross-phase parallelism is limited.

---

## Cross-Cutting Concerns

### Code Style

**Bash**:
- `set -u` at top of every script (`set -e` is intentionally avoided in pipeline scripts so a non-match returns silent fall-through)
- One responsibility per script; orchestrator dispatches, layer scripts decide
- All decision JSON emitted via `printf` or here-strings -- never `echo -e`
- Use `jq` for all JSON parsing -- never grep/sed JSON
- No emojis, no unicode, no special characters in user-facing output

**Python**:
- Python 3.11+ (uses `tomllib` from stdlib)
- Type hints for all public function signatures
- Dataclasses for value types (`SessionState`, `Config`, `Snapshot`, `ProviderSpec`, `ParsedTranscript`, `Decision`, `ToolUse`)
- One module per concern (`state.py`, `rules.py`, `transcript.py`, `prompt.py`, `decision.py`, `diag.py`, `__main__.py`)
- Stdlib only -- no external Python dependencies
- Module docstrings explaining purpose; function-level docstrings only when intent isn't obvious from signature

### Error Handling

- **Layer scripts**: silent fall-through (empty stdout, exit 0) on any unrecognized input. Never crash the hook.
- **Hard-deny**: only path that exits 2; reserved for `bash-denylist.sh` matched patterns.
- **Classifier subprocess errors**: caught at provider level, retried per `ProviderSpec.retries`. On exhaustion, fall to next provider in chain.
- **Chain exhaustion**: apply `on_exhaustion` config (default `ask`).
- **Malformed classifier response**: one repair attempt with explicit instruction. On second failure, treat provider as exhausted.
- **Corrupt state file**: warn to stderr, fall back to defaults, rewrite on next save.
- **Missing snapshot**: trigger synchronous `aegis refresh-rules`; on failure, warn to stderr and fall through.

### Logging (MANDATORY)

**Logging is required.** Phase 1 sets up the logging infrastructure as a deliverable.

- **Bash**: stderr with `[aegis]` prefix for diagnostic messages. Never write to stdout (stdout is reserved for the Claude Code permission decision JSON).
- **Python**: `loguru` (the only external Python dep we accept; small enough to vendor or accept as install-time dependency). Configured in Phase 1 via a single setup function in `classifier/log.py`. Logs go to stderr with structured format `[YYYY-MM-DD HH:MM:SS] [level] [module] message`.
- **Decision log** (separate from operational logs): JSONL append to `~/.cache/aegis/decisions.jsonl`. One row per decision, captured by both the bash deterministic layers (via `diag_emit` shell helper) and the Python classifier. Schema: `{ts, session_id, tool, layer, decision, reason, model, latency_ms, tokens}`.

Note: The current spec accepts `loguru` as the Python logger. If Phase 1 finds dependency-management tradeoffs (e.g., user wants stdlib-only), Phase 1 may downgrade to `logging` and document the decision.

### Configuration

- **Global**: `~/.config/aegis/aegis.toml` (created by `install.sh` if missing; starter content includes the user's trusted orgs/services).
- **Per-project override**: `<repo>/.aegis/aegis.toml` (deep-merged over global; located via `cwd` from PreToolUse JSON input).
- **Per-project hard-ask additions**: `<repo>/.aegis/hard-ask.toml` (additional regex patterns appended to the global hard-ask set).
- **Loaded by**: `classifier/rules.py::load_config(project_dir)`. Built-in defaults < global TOML < project TOML.

### Testing Strategy

- **Bash**: corpus-driven harness vendored from `~/Sync/Programs/bash-gatekeeper/tests/run.sh`. One file per layer (`should-allow.txt`, `should-deny.txt`, `should-ask.txt`, `protected-paths.txt`). Plus `tests/bash/orchestrator-cases.sh` for end-to-end orchestrator dispatch.
- **Python**: pytest, one test file per classifier module. Subprocess providers mocked via `monkeypatch.setattr(subprocess, "run", ...)`. State and rules tests use `tmp_path` fixtures redirected via monkeypatch.
- **Golden transcripts**: `tests/fixtures/transcript.*.jsonl` -- real transcript shapes for the parser tests.
- **Integration smoke**: end-of-Phase-9 manual run with real `gemini` to confirm the full pipeline.
- **Test command** (set up in Phase 1): `tests/bash/run.sh && AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh && python3 -m pytest tests/python/ -v`.

---

## Integration Points

### orchestrator.sh <-> deterministic layers

Each layer reads the same PreToolUse JSON on stdin via `echo "$INPUT" | $LIB/<layer>.sh`. Layers either:
- Exit 2 (hard-deny only)
- Emit decision JSON on stdout and exit 0
- Emit empty stdout and exit 0 (silent fall-through)

orchestrator.sh checks output and exit code to decide whether to short-circuit or continue to the next layer.

### orchestrator.sh <-> classifier

When all deterministic layers fall through, the orchestrator pipes the same JSON to `python3 -m classifier`. The classifier reads stdin, walks the provider chain, and writes Claude Code permission JSON on stdout. The orchestrator does not interpret the classifier output -- it just passes through.

### classifier/__main__.py <-> all classifier modules

`__main__` is the only place where the entire classifier pipeline composes:
1. Parse stdin payload
2. `state.load(session_id)`; if `enabled=False`, fall through silently
3. `rules.load_config(cwd)` and `rules.load_snapshot()`
4. `transcript.parse(transcript_path, last_user_n)` 
5. `prompt.build_system_prompt(snap, cfg)` and `prompt.build_user_prompt(parsed, pending, claude_md, cfg)`
6. For each `ProviderSpec` in `cfg.classifier_chain`: call provider, parse response with `decision.parse_response`. On parse failure, attempt one repair. Break on first success.
7. On chain exhaustion: `Decision(decision=cfg.on_exhaustion, reason="classifier chain exhausted")`
8. `state.record_decision(sess, d.decision, ...)` and `state.save(sess)`
9. `diag.emit(...)` 
10. `decision.to_hook_output(d)` written to stdout

### bin/aegis <-> classifier/state.py

CLI imports `classifier.state` directly. Optionally redirects `state.STATE_DIR` via `AEGIS_STATE_DIR` env var (used by tests).

---

## Data Schemas

### PreToolUse JSON (input on stdin to orchestrator.sh)

```json
{
  "session_id": "abc-123",
  "tool_name": "Bash",
  "tool_input": { "command": "git status" },
  "cwd": "/home/user/project",
  "transcript_path": "/path/to/transcript.jsonl"
}
```

### Claude Code permission decision JSON (output on stdout)

```json
{ "hookSpecificOutput": { "hookEventName": "PreToolUse", "permissionDecision": "allow" } }
{ "hookSpecificOutput": { "hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "..." } }
{ "hookSpecificOutput": { "hookEventName": "PreToolUse", "permissionDecision": "ask" } }
```

### Classifier model output (parsed by classifier/decision.py)

```json
{ "decision": "allow|deny|ask", "reason": "<one sentence>" }
```

### Per-session state file (`~/.cache/aegis/sessions/<id>.json`)

```json
{
  "session_id": "abc-123",
  "enabled": true,
  "consecutive_denies": 0,
  "total_denies": 0,
  "paused_reason": null,
  "last_decision_at": "2026-04-30T00:42:11Z"
}
```

### Decision log row (one JSONL line in `~/.cache/aegis/decisions.jsonl`)

```json
{
  "ts": "2026-04-30T00:42:11Z",
  "session_id": "abc-123",
  "tool": "Bash",
  "layer": "hard-allow|hard-ask|hard-deny|protected-paths|read-only|classifier",
  "decision": "allow|deny|ask",
  "reason": "<short string>",
  "model": "<model id or null>",
  "latency_ms": 4,
  "tokens": null
}
```

### Snapshot file (`rules/snapshot.json`, output of `claude auto-mode defaults`)

```json
{
  "allow": ["..."],
  "soft_deny": ["..."],
  "environment": [...]
}
```

---

## Glossary

| Term | Meaning |
|------|---------|
| **Hard-deny** | Deterministic block. `exit 2` from a hook. No layer below can override. |
| **Hard-ask** | Deterministic "always prompt user". Skips classifier even if it would have allowed. |
| **Hard-allow** | Deterministic "auto-approve". The fast path for known-safe commands. |
| **Classifier** | LLM-driven decision layer. Slow path. Returns allow / deny / ask. |
| **Fall-through** | Hook returns empty stdout and exit 0. Claude Code prompts the user normally. |
| **Snapshot** | Vendored copy of `claude auto-mode defaults` output, refreshed on TTL. |
| **Trusted environment** | User-configured list of orgs, domains, buckets, services treated as in-scope by the classifier. |
| **Provider chain** | Ordered list of `ProviderSpec` entries; tried sequentially on retry exhaustion. |
| **Auto-pause** | Disables Aegis for a session after consecutive_denies or total_denies threshold; resumes on `/aegis-on`. |

---

## Future Enhancements (v2+, intentionally deferred)

- Decision caching: same tool input within a session reusing prior allow with TTL.
- Subagent gates: spawn-time task description review, return-time history review.
- Hard-allow fast path for non-Bash: e.g. Edit/Write inside working dir below 50KB instant-allow without classifier.
- Multi-agent adapters: Aegis as a generic permission classifier reusable by Codex, Gemini-CLI, Aider via thin per-agent shims.
- Bedrock / Vertex / Foundry classifier providers via cloud SDKs (currently subprocess-only).
- Telemetry export: optional anonymized decision-log export for tuning the classifier prompt over time.
- Per-project rule snapshots: vendor classifier rules into the project repo so different projects can pin different rule versions.

---

## References

- **Design spec**: `docs/superpowers/specs/2026-04-30-aegis-design.md` (the source of truth for v1 scope and architecture)
- **Implementation plan**: `docs/superpowers/plans/2026-04-30-aegis.md` (19-task TDD-style plan; the spark phase plans are derived from this)
- **Source bash-gatekeeper**: `~/Sync/Programs/bash-gatekeeper/` (vendored verbatim into `lib/`)
- **Anthropic auto mode docs**: <https://code.claude.com/docs/en/permission-modes#eliminate-prompts-with-auto-mode>
- **Architectural reference**: <https://institute.sfeir.com/en/articles/claude-code-auto-mode-permissions-autonomy/>
- **Anthropic rule snapshot source**: `claude auto-mode defaults` (subcommand of `claude` CLI)

---

**Instructions for Agents**:
1. **First**: Run `pwd` and verify you're in `/home/tunc/Sync/Programs/aegis`
2. Read your phase plan from `phase_plans/PHASE_XX.md` (NOT the entire PROJECT_PLAN.md)
3. Check the dependencies to understand what should already exist
4. Follow the detailed requirements exactly
5. Meet all completion criteria before marking phase complete
6. Create your summary in `summaries/PHASE_XX_SUMMARY.md`
7. Update `STATUS.md` when complete

**Remember**: All file paths in this plan are relative to `/home/tunc/Sync/Programs/aegis`

**Context Budget Note**: Each phase targets ~120k total tokens (reading + implementation + thinking + output). Phase plans are individual files to minimize reading overhead. If a phase runs out of context, note it in your summary and suggest splitting.
