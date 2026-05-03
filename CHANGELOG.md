# Changelog

## 1.0.0 -- 2026-05-04

First production release. Aegis now matches Anthropic's auto-mode
permissiveness for routine dev work, keeps a thin hard-deny floor for
catastrophic operations, and routes everything else through user-overridable
ASK.

### Behavior

- **Default ALLOW** for routine dev work. Classifier prompt enumerates the
  same allow categories Anthropic's auto mode uses (local edits in cwd,
  test runners, build tools, package installs from existing manifests,
  toolchain bootstrap, read-only HTTP, pushing to non-default branches).
- **Classifier-deny is downgraded to ASK** in the hook output. The user
  always has an override path on judgement calls. The classifier's
  original verdict is still recorded in `~/.cache/aegis/decisions.jsonl`
  for audit and counter purposes.
- **Hard-deny floor narrowed** to truly nuclear patterns (`rm -rf` on
  system paths). `curl|shell` and AI-attribution scrubs moved to
  bash-hard-ask (overridable ASK).
- **cwd is now passed to the classifier user prompt** so it can reason
  about project-scope rules. Without this, novel commands like
  `./node_modules/.bin/tsc --noEmit` were ASKed because the model
  couldn't tell if the path was in scope.
- **Agent / Task / WebFetch / WebSearch added to the harmless-tool
  fast-path.** Subagent dispatch was generating one ASK prompt per spawn;
  now it auto-allows since the subagent's own tool calls flow back
  through this hook.

### Packaging

- Restructured for the Claude Code marketplace plugin format. The plugin
  now lives in a `plugin/` subdirectory containing a metadata-only
  `.claude-plugin/plugin.json` and `hooks/hooks.json`, with symlinks back
  to the orchestrator and library files at the repo root.
- Added `.claude-plugin/marketplace.json` so the repo can be registered
  with `/plugin marketplace add <path>`.
- `install.sh` cleans up legacy `~/.claude/plugins/aegis` symlinks from
  the pre-marketplace install model and prints the new registration
  commands.

### Initial implementation (was 0.1.0)

Pre-1.0 work delivered the original 9-phase implementation:
deterministic Bash layers (denylist, hard-ask, gatekeeper),
protected-paths layer for Edit/Write, Python classifier with provider
chain (gemini, claude), state module with deny counters and auto-pause,
JSONL diagnostic log, CLI (`aegis status / on / off / refresh-rules`),
slash commands, idempotent installer, full test corpus.
