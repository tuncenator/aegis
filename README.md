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

`install.sh` symlinks the `aegis` CLI into `~/.local/bin` and writes a starter
config at `~/.config/aegis/aegis.toml`. The plugin itself is loaded through a
directory marketplace; register it once inside Claude Code:

```
/plugin marketplace add /absolute/path/to/aegis
/plugin install aegis@aegis
```

Then restart Claude Code so the PreToolUse hook activates.

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
