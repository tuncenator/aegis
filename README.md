# Aegis

Self-hosted, LLM-agnostic replacement for Claude Code's `auto` permission
mode. Works on any Claude Code plan, any model, any provider. Anthropic's
gated `auto` mode is never invoked.

## Philosophy

Match auto-mode permissiveness for routine dev work, keep a thin hard floor
for catastrophic operations, surface everything else to the user with the
classifier's reasoning attached.

- **Default ALLOW** for the same categories Anthropic's auto mode allows:
  reads, local file edits within cwd, test runners, build tools, package
  installs from existing manifests, toolchain bootstrap, read-only HTTP,
  pushing to non-default branches, sending creds to their matching API.
- **ASK** for everything ambiguous: writes outside cwd, soft-deny pattern
  matches the user might want, unusual flag combinations, ssh to prod-named
  hosts, force pushes, push to default branch, `curl | shell`, AI
  attribution scrubs in commit messages. The user always has an override.
- **Hard DENY** (no override) is reserved for truly nuclear patterns:
  `rm -rf` on system paths (`/`, `~`, `/etc`, `/var`, `/usr`, ...).
  Everything else flows through ASK.

The classifier itself never produces a hard block. If the LLM thinks
something is bad enough to deny, that surfaces as ASK with the LLM's
reason as the prompt text -- so the user sees *why* the model objected
and can decide. Aegis is advisory; the operator is the final authority.

## Pipeline

```
Bash:
  bash-denylist (hard-deny exit 2)
  -> bash-hard-ask (ASK if matched)
  -> bash-gatekeeper (ALLOW if matched)
  -> classifier (ALLOW or ASK; classifier-deny downgraded to ASK)

Edit / Write / NotebookEdit:
  protected-paths (ASK if /etc, ~/.ssh, etc.)
  -> classifier

Read / Glob / Grep / TodoWrite / TaskCreate / Agent / Task /
WebFetch / WebSearch / TodoWrite:
  ALLOW immediately (no classifier)
```

## Install

```
git clone <this repo>
cd aegis
./install.sh
```

`install.sh` symlinks the `aegis` CLI into `~/.local/bin` and writes a
starter config at `~/.config/aegis/aegis.toml`. The plugin itself loads
through a directory marketplace; register it once inside Claude Code:

```
/plugin marketplace add /absolute/path/to/aegis
/plugin install aegis@aegis
```

Then `/reload-plugins` (or restart Claude Code) so the PreToolUse hook
activates. Verify with `/aegis-status`.

## Configuration

Global config: `~/.config/aegis/aegis.toml`
Per-project overrides: `<repo>/.aegis/aegis.toml`
Per-project deterministic ASK patterns: `<repo>/.aegis/hard-ask.toml`

The starter config sets the classifier provider chain (gemini-flash-lite
-> gemini-flash -> claude-haiku), deny counters, snapshot TTL, transcript
context limits, and trusted-environment hints.

## Toggles

In-session slash commands:
- `/aegis-status` print current state for this session
- `/aegis-off` disable for this session (decisions revert to Claude Code's
  default permission flow)
- `/aegis-on` re-enable

CLI:
- `aegis status [--session ID]`
- `aegis on [--session ID]`
- `aegis off [--session ID]`
- `aegis refresh-rules` (re-fetch the Anthropic rule snapshot)

## Diagnostics

Every decision is logged as one JSONL row to
`~/.cache/aegis/decisions.jsonl` with timestamp, session, tool, layer,
decision, model, latency, and reason. The log records the classifier's
*original* verdict even when the hook output downgraded a deny to ask,
so you can audit what the model actually thought.

## Standalone bash-only mode

Users who want only the deterministic Bash filtering (no LLM stack) can
skip the plugin install and wire their `~/.claude/settings.json`
PreToolUse hooks directly to `lib/bash-gatekeeper.sh` and
`lib/bash-denylist.sh`.

## Development

```bash
uv sync                                                 # python deps
uv run python -m pytest tests/python/ -v                # python tests
tests/bash/run.sh                                       # bash corpus
AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh
```

## Spec

Original design spec (Phase 1, may diverge from current behavior):
[docs/superpowers/specs/2026-04-30-aegis-design.md](docs/superpowers/specs/2026-04-30-aegis-design.md)

See `CHANGELOG.md` for behavioral evolution.
