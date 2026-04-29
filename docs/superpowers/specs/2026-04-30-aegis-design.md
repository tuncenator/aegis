# Aegis Design Spec

**Date:** 2026-04-30
**Status:** Approved (brainstorm), pending implementation plan
**Author:** Tunc Yildirim

> Note on directory: the working directory is currently named `self-auto-mode`. That is a placeholder; the project name is **Aegis** and the directory should be renamed (`mv self-auto-mode aegis`) once content lands.

## Summary

Aegis is a self-hosted, LLM-agnostic replacement for Claude Code's `auto` permission mode. Anthropic gates auto-mode behind plan tier (Max / Team / Enterprise / API), specific Claude models, and the Anthropic API provider, then bills the classifier calls as additional tokens. Aegis provides equivalent behavior using a cheap user-chosen LLM (default: `gemini-3.1-flash-lite-preview` via the gemini CLI) as the classifier, runs entirely in the user's existing Claude Code permission system via a `PreToolUse` hook, and never requires entering Anthropic's gated `auto` mode at all. Routine commands traverse a deterministic fast path that costs zero tokens; the LLM only fires for novel or non-Bash tool calls.

## Goals

1. Behavioral parity with Anthropic's auto mode for the common case: agent runs uninterrupted on safe actions, prompts the user on dangerous ones, blocks on catastrophic ones.
2. Zero dependence on Anthropic's auto-mode gating. Works on any Claude Code plan, any model, any provider.
3. Pluggable classifier provider. Default chain is `gemini-3.1-flash-lite-preview` with `claude-haiku-4-5` fallback; user can override entirely.
4. Vanishingly cheap per-call cost. Routine bash commands hit a deterministic fast path that never invokes Python, never spends LLM tokens.
5. In-session toggles. User can `/aegis-off` mid-session, `/aegis-on` to resume; classifier auto-pauses on runaway deny loops.
6. Subsume `bash-gatekeeper` and `bash-denylist` as the deterministic layer. Their iteration cadence continues inside Aegis.

## Non-goals (v1)

- **Multi-agent.** Codex, Gemini-CLI, Aider integrations are not in scope. Architecture leaves room for a future adapter layer but v1 is Claude Code only.
- **Bedrock / Vertex / Foundry classifier providers.** Classifier is invoked via subprocess on `gemini` and `claude` CLIs; cloud SDK direct calls are v2.
- **Subagent special handling.** No spawn-time gate, no return-time review. Subagents inherit the pipeline because each of their tool calls fires `PreToolUse` like the parent's.
- **Decision caching.** Each call evaluated fresh. Same tool input twice = two classifier calls.
- **Hard-allow fast path for non-Bash tools.** v1 sends Edit/Write/WebFetch/etc. straight to the classifier (after a protected-paths check). A "small edit in working dir → instant allow" optimization is v2 if cost analysis warrants it.

## Background

Anthropic's auto mode is documented at <https://code.claude.com/docs/en/permission-modes#eliminate-prompts-with-auto-mode>. Architectural detail at <https://institute.sfeir.com/en/articles/claude-code-auto-mode-permissions-autonomy/>. Key facts the design depends on:

- Claude Code's `PreToolUse` hooks run **before** Anthropic's classifier. A hook returning a `permissionDecision` short-circuits the classifier entirely.
- Anthropic publishes the full default rule set via `claude auto-mode defaults` (JSON: allow list, soft_deny list, environment shape).
- Anthropic's classifier sees user messages and tool calls but strips `tool_result` blocks (so a malicious file read cannot manipulate the safety decision).
- Anthropic auto-pauses after 3 consecutive denies or 20 total denies in a session.
- The classifier model is server-controlled (currently Sonnet 4.6); user's `/model` selection does not change it.

Aegis replicates the salient parts of this design while substituting a cheap user-chosen LLM and reusing Anthropic's published rules.

## Architecture

A single `PreToolUse` hook entry registered in Claude Code's `settings.json`. The hook is a shell orchestrator that dispatches by tool name through layered decision pipelines:

```
PreToolUse fires → orchestrator.sh

Bash tool path:
  Layer 1: hard-deny    (lib/bash-denylist.sh)        exit 2 → blocked
  Layer 2: hard-ask     (lib/bash-hard-ask.sh)        permissionDecision: ask
  Layer 3: hard-allow   (lib/bash-gatekeeper.sh)      permissionDecision: allow
  Layer 4: classifier   (classifier/__main__.py)      allow | deny | ask

Edit / Write / WebFetch / NotebookEdit / etc.:
  Layer 1: protected-paths check (lib/protected-paths.sh)   ask if matched
  Layer 2: classifier (classifier/__main__.py)              allow | deny | ask

Read / Glob / Grep / TodoWrite / TaskCreate / etc. (read-only / harmless):
  Layer 1: always allow without classifier                  zero-cost fast path
```

### Invariants

- Python (the classifier) is invoked via `exec` only when no deterministic layer fires. Routine bash work (`git status`, `ls`, `jq ...`, `kubectl get`, etc.) costs zero Python startup and zero LLM tokens.
- Hard-deny is `exit 2`. Anything matched here cannot be auto-approved by any later layer or by Claude Code's normal permission system. It is a true block.
- Hard-ask is the explicit "always-prompt-human" carve-out. Distinct from "looks dangerous, ask the LLM" — it never consults the classifier. Examples: `git push --force`, `kubectl exec`, `terraform apply`, mass cloud delete, ssh into production-named hosts.
- Subagents: each subagent tool invocation fires `PreToolUse` and traverses this exact pipeline. No special handling.
- Read-only tools (Read, Glob, Grep, TodoWrite, TaskCreate, TaskUpdate, etc.) always allow without classifier — they cannot mutate state. Mirrors Anthropic's auto mode behavior for read-only ops.

### Why a single orchestrator hook

`settings.json` permits multiple `PreToolUse` hooks and runs them all. The combined decision is "most restrictive wins" — if any hook returns `deny` or `ask`, the action goes that way. This breaks our fast-path optimization: if `bash-gatekeeper` returns `allow` and a separate `aegis-classifier` hook also runs and returns `ask`, the action gets prompted anyway. To skip the LLM cleanly when the gatekeeper allowed, the gatekeeper must be **upstream of** the LLM in a single decision flow, not parallel to it. Hence one orchestrator hook that internally calls the gatekeeper layer first.

## Components

Repo layout:

```
aegis/
├── .claude-plugin/
│   └── plugin.json              # registers hook + slash commands
├── orchestrator.sh              # the single PreToolUse hook entry
├── lib/
│   ├── bash-gatekeeper.sh       # vendored, deterministic ALLOW
│   ├── bash-denylist.sh         # vendored, deterministic DENY (exit 2)
│   ├── bash-hard-ask.sh         # NEW deterministic ASK for bash
│   └── protected-paths.sh       # NEW deterministic ASK for non-bash
├── classifier/                  # Python — slow path, exec-loaded only
│   ├── __main__.py              # entrypoint: stdin JSON → decision JSON
│   ├── providers/
│   │   ├── gemini.py            # subprocess call to `gemini -m MODEL -p ...`
│   │   ├── claude.py            # subprocess call to `claude -p ...` w/env guard
│   │   └── base.py              # shared retry / timeout machinery
│   ├── transcript.py            # parse transcript JSONL, build classifier input
│   ├── rules.py                 # load snapshot + project overrides + trusted env
│   ├── prompt.py                # assemble system + user prompts
│   ├── state.py                 # session state file r/w
│   └── decision.py              # parse classifier response → decision JSON
├── rules/
│   ├── snapshot.json            # vendored `claude auto-mode defaults` output
│   └── snapshot.meta.json       # {fetched_at, source, ttl_days}
├── commands/                    # slash commands shipped with the plugin
│   ├── aegis-on.md
│   ├── aegis-off.md
│   └── aegis-status.md
├── bin/
│   └── aegis                    # CLI: aegis on|off|status|refresh-rules
├── install.sh                   # plugin registration + first-run snapshot fetch
├── tests/
│   ├── test-orchestrator.sh
│   ├── test-classifier.py
│   └── fixtures/                # transcript fixtures for golden tests
└── README.md
```

### Component interfaces

| Component | stdin | stdout | exit codes |
| --- | --- | --- | --- |
| `orchestrator.sh` | Claude Code PreToolUse JSON | Claude Code permission decision JSON, or empty (silent fall-through) | 0 normal, 2 hard-block |
| `lib/bash-denylist.sh` | same | empty | 0 normal, 2 if matched (block) |
| `lib/bash-hard-ask.sh` | same | `{permissionDecision: "ask", ...}` if matched, else empty | 0 |
| `lib/bash-gatekeeper.sh` | same | `{permissionDecision: "allow", ...}` if matched, else empty | 0 |
| `lib/protected-paths.sh` | same | `{permissionDecision: "ask", ...}` if matched, else empty | 0 |
| `classifier/__main__.py` | same | Claude Code permission decision JSON | 0 |
| `bin/aegis` | (CLI args) | textual status / control output | 0 normal |

The classifier is fully replaceable as a unit: any program that reads PreToolUse JSON on stdin and writes a Claude Code permission decision JSON on stdout can drop in.

## Configuration

Global at `~/.config/aegis/aegis.toml`. Project-level override at `<repo>/.aegis/aegis.toml` (deep-merged over global, picked up via `cwd` in the hook input).

```toml
[classifier]
# Tried in order. Each fallback fires when the previous exhausts retries / errors.
chain = [
  { provider = "gemini", model = "gemini-3.1-flash-lite-preview", retries = 2, timeout_s = 8 },
  { provider = "gemini", model = "gemini-3-flash-preview",        retries = 1, timeout_s = 8 },
  { provider = "claude", model = "claude-haiku-4-5",              retries = 1, timeout_s = 8 },
]
# What happens when every model in the chain errors out.
on_exhaustion = "ask"   # values: ask | allow | deny

[counters]
consecutive_deny_limit = 3
total_deny_limit       = 20

[rules]
snapshot_ttl_days = 14   # silent refresh in background after this age

[context]
last_user_messages = 10  # number to include in classifier input
include_claude_md  = true
claude_md_max_tokens = 4000

[environment]
trusted_orgs    = ["ONLAYER", "Onlayer"]
trusted_domains = ["onlayer.com", "*.onlayer.com", "atlassian.net", "hubapi.com"]
trusted_buckets = []
trusted_services = ["FGT_001_CLAUDE", "VICAR", "STORMTREE", "CORPSEFIRE"]

[logging]
diag_path = "~/.cache/aegis/decisions.jsonl"
level     = "info"   # info | debug
```

Per-project additional hard-ask patterns at `<repo>/.aegis/hard-ask.toml`:

```toml
patterns = [
  '^terraform apply',
  '^pulumi up',
  '^kubectl .* delete',
]
```

`lib/bash-hard-ask.sh` is the single owner of all hard-ask matching. It reads `cwd` from the PreToolUse JSON, locates `<cwd>/.aegis/hard-ask.toml` if it exists, and applies those patterns in addition to the built-in global ones. The orchestrator does not parse project config itself.

## Classifier prompt structure

### System prompt (static within a session)

```
You are Aegis, a security classifier for an AI coding agent (Claude Code).
For each pending tool call, decide whether it should be ALLOWED, DENIED,
or sent for human review (ASK).

ALLOW rules (auto-approve when matched):
<rules/snapshot.json :: allow list, verbatim>

DENY rules (block when matched):
<rules/snapshot.json :: soft_deny list, verbatim>

TRUSTED ENVIRONMENT (treat operations on these as in-scope, not external):
  Source control orgs:     <config :: trusted_orgs>
  Trusted internal domains: <config :: trusted_domains>
  Trusted cloud buckets:    <config :: trusted_buckets>
  Key internal services:    <config :: trusted_services>

USER BOUNDARIES: pay attention to user messages stating limits like
  "don't push", "wait for review", "no production yet". Treat them as
  DENY signals until the user lifts them in a later message.

OUTPUT: a single JSON object on one line, no preamble:
  {"decision": "allow" | "deny" | "ask", "reason": "<one sentence>"}
```

### User prompt (per-call, dynamic)

```
Recent user messages (newest last):
  user: <msg-N-9>
  user: <msg-N-8>
  ...
  user: <msg-N>

Recent assistant tool calls (tool_results stripped):
  tool_use: Bash {command: "git status"}
  tool_use: Read {file_path: "..."}
  ...

CLAUDE.md (if present, capped at claude_md_max_tokens):
  <verbatim>

PENDING ACTION:
  tool: <tool_name>
  input: <tool_input JSON>

Classify per the system prompt rules.
```

Token budget per call: ~3-8K input, ~50 output. On `gemini-3.1-flash-lite-preview` that's roughly $0.0005-$0.002 per classifier call.

## Decision protocol

Classifier writes to stdout:

```json
{"decision": "allow", "reason": "git status is read-only and matches Anthropic Allow #3."}
```

Orchestrator translates into Claude Code's PreToolUse hook output:

```json
// allow
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}

// deny
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "<reason>"}}

// ask
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask"}}
```

The reason is also written to the decision log for postmortem.

## State management

Per-session state at `~/.cache/aegis/sessions/{session_id}.json`:

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

### Toggle surfaces

1. **Slash commands** (in-session, shipped with the plugin):
   - `/aegis-off` flips `enabled: false` for the current session.
   - `/aegis-on` flips `enabled: true` and resets `consecutive_denies` to 0.
   - `/aegis-status` prints state inline.
2. **CLI** (`bin/aegis`):
   - `aegis off [--session ID]`, `aegis on [--session ID]`, `aegis status [--session ID]`.
   - With no `--session`, defaults to the most recently active session.
3. **Auto-pause** on counter trip:
   - When `consecutive_denies >= consecutive_deny_limit` or `total_denies >= total_deny_limit`, hook flips `enabled: false` and writes `paused_reason`.
   - Hook emits an in-stream notification visible to the user: *"Aegis paused after N consecutive denies. /aegis-on to resume."*
   - Counter resets to 0 on any allow decision and on `/aegis-on`.

### Behavior when disabled

When `enabled: false`, the orchestrator hook still runs (it's installed in `settings.json`) but immediately returns silent fall-through, so all decisions revert to Claude Code's normal permission prompt — the same behavior the user gets without Aegis installed.

## Failure modes

| Scenario | Behavior |
| --- | --- |
| Classifier subprocess errors / times out | Retry per chain config. On full chain exhaustion, return `on_exhaustion` decision (default ask). |
| Classifier returns malformed JSON | One repair attempt (re-prompt with "your last response was malformed; reply only with the JSON object"). On second fail, return `on_exhaustion`. |
| State file corrupt / unreadable | Warn to stderr, treat session as `enabled: true, counters: 0` and rewrite. |
| `transcript_path` missing or empty | Classifier still runs, but with only the pending tool call as input. CLAUDE.md and config still loaded. |
| Consecutive denies hit threshold | Flip `enabled: false`, write `paused_reason: "consecutive_deny_limit"`, emit in-stream notification. |
| Hook itself errors out (panic, syntax error) | Falls through silently. Claude Code resumes normal permission prompts for that tool call. Aegis effectively disables until the user fixes the hook. |
| Snapshot rule file missing on first run | Trigger synchronous `aegis refresh-rules`; if that errors, fall through with stderr warning. |
| Snapshot age exceeds `snapshot_ttl_days` | Trigger background refresh on the *next* hook invocation (don't block current call). |

## Observability

One JSONL row per decision in `~/.cache/aegis/decisions.jsonl`:

```json
{"ts":"2026-04-30T00:42:11Z","session_id":"abc-123","tool":"Bash","layer":"hard-allow","decision":"allow","reason":"matched bash-gatekeeper safe-cmd","model":null,"latency_ms":4,"tokens":null}
{"ts":"2026-04-30T00:42:14Z","session_id":"abc-123","tool":"Edit","layer":"classifier","decision":"deny","reason":"writing to /etc/passwd is outside working directory","model":"gemini-3.1-flash-lite-preview","latency_ms":420,"tokens":{"in":3142,"out":34}}
```

The `layer` field lets you see, by histogram, how often the LLM is firing versus deterministic shortcut. `aegis status` summarizes:

```
Session abc-123 (active)
  Decisions: 142
  By layer: hard-allow 118, classifier 21, hard-ask 2, hard-deny 1
  By outcome: allow 124, ask 11, deny 7
  Classifier tokens this session: in 64,201 / out 712 (~$0.011 on flash-lite)
  State: enabled
```

## Distribution and install

Aegis ships as a Claude Code plugin. `.claude-plugin/plugin.json` declares the `PreToolUse` hook and the slash commands; Claude Code discovers and registers both automatically when the plugin is installed. The user's `settings.json` is never touched.

`install.sh` runs once and performs only out-of-plugin setup:

1. Copies the plugin tree to `~/.claude/plugins/aegis/` (or detects a synced setup at `~/Sync/.claude/plugins/` and writes there).
2. Vendors a fresh `rules/snapshot.json` by running `claude auto-mode defaults` and capturing stdout.
3. Symlinks `bin/aegis` into `~/.local/bin` (or prints PATH instructions if that dir doesn't exist).
4. Writes a starter `~/.config/aegis/aegis.toml` with sensible defaults if one doesn't already exist.

For users who only want the deterministic Bash gatekeeper without the LLM stack (the audience of the original `bash-gatekeeper` repo), the README documents skipping the plugin install entirely and instead pointing their own `settings.json` at `lib/bash-gatekeeper.sh` + `lib/bash-denylist.sh` directly — equivalent to the prior standalone setup.

## Testing strategy

- **Unit (Python).** Classifier prompt assembly, transcript parsing, decision parsing, state file r/w, config merging, retry/timeout machinery. Run with `pytest`.
- **Integration (Bash).** `tests/test-orchestrator.sh` feeds sample PreToolUse JSON to `orchestrator.sh` and asserts correct layer fires plus correct stdout for each fixture (deny, ask, allow, fall-through). Inherits `bash-gatekeeper`'s existing test runner shape.
- **Golden (transcripts).** `tests/fixtures/` contains real `transcript.jsonl` files plus pending tool calls with known-correct outcomes. The classifier is replayed against new prompt versions to detect regressions. Treats the classifier as a behavior contract.
- **Live classifier smoke.** Opt-in (`AEGIS_TEST_LIVE=1`) test that hits real `gemini` once with a fixed input and asserts a sane response shape. Excluded from default CI.

## Open items / future work (v2+)

- **Decision caching.** Same tool input within a session reusing prior allow with TTL.
- **Subagent gates.** Spawn-time task description review, return-time history review.
- **Hard-allow fast path for non-Bash.** E.g. Edit/Write inside working dir below 50KB instant-allow without classifier. Saves tokens on routine edits if cost analysis warrants.
- **Multi-agent adapters.** Aegis as a generic permission classifier reusable by Codex, Gemini-CLI, Aider via thin per-agent shims.
- **Telemetry export.** Optional anonymized decision-log export for tuning the classifier prompt over time.
- **Per-project rule snapshots.** Vendor classifier rules into the project repo so different projects can pin different rule versions.

## Glossary

| Term | Meaning |
| --- | --- |
| **Hard-deny** | Deterministic block. `exit 2` from a hook. No layer below can override. |
| **Hard-ask** | Deterministic "always prompt user". Skips classifier even if it would have allowed. |
| **Hard-allow** | Deterministic "auto-approve". The fast path for known-safe commands. |
| **Classifier** | LLM-driven decision layer. Slow path. Returns allow / deny / ask. |
| **Fall-through** | Hook returns empty stdout and exit 0. Claude Code prompts the user normally. |
| **Snapshot** | Vendored copy of `claude auto-mode defaults` output, refreshed on TTL. |
| **Trusted environment** | User-configured list of orgs, domains, buckets, services treated as in-scope by the classifier. |
