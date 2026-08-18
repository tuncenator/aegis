# Changelog

## Unreleased

### Behavior

- **`[behavior] defer_scope`** decides which asks go silent under
  `ask_mode = "defer"`. `"classifier"` (new default) defers only the LLM
  classifier's own ask verdicts; Aegis's deterministic tripwires
  (`lib/bash-hard-ask.sh`, `lib/protected-paths.sh`, the gatekeeper's ask
  exit) still prompt. `"all"` restores the previous behavior where every
  ask deferred.

  This closes a real hole. The auto-mode rule snapshot contains no
  system-path rules at all -- nothing in `allow`, `soft_deny`,
  `hard_deny` or `environment` mentions `/etc`, `/usr/bin` or `~/.ssh` --
  so under the old blanket deferral an `Edit /etc/passwd` was handed to
  the native classifier with no guarantee anything downstream would catch
  it. Measured over 242k real decisions, protected-paths fired 426 times
  and bash-hard-ask 86 times: 0.21% of calls, about one prompt per 470
  tool calls, against 640 classifier asks that deferral is actually
  there to absorb.

  Resolved by `lib/ask-mode.sh` with the same layering as `ask_mode`:
  `AEGIS_DEFER_SCOPE` over project toml over global toml.

### Housekeeping

- **The decision log rotates.** `classifier/diag.py` renames the log to
  `<path>.1` once it crosses `[logging] max_bytes` (default 32 MiB),
  keeping one generation. Unrotated it had reached 70 MB across 242k rows
  in real use. `max_bytes = 0` disables rotation.
- **Per-session state files are pruned.** `[state] session_ttl_days`
  (default 14) drops files untouched for that long. The classifier runs
  this at most once a day, guarded by a `.prune-stamp` in the state
  directory, so it never costs a directory walk in the hook's latency
  path. `aegis prune [--ttl-days N]` forces it. A real install had
  accumulated ~1k files, one per session.
- **One diagnostics path.** `orchestrator.sh` used to inline a Python
  heredoc that hardcoded `~/.cache/aegis/decisions.jsonl`, so
  `[logging] diag_path` governed only the classifier's rows and the
  deterministic layers wrote elsewhere. Both now go through
  `classifier/diagcli.py`.
- **`aegis status` reports the whole picture**: effective `ask_mode`,
  `defer_scope`, `hard_deny_action` and `on_exhaustion`; rule-snapshot
  age against its TTL, flagged when stale; decision-log size against
  `max_bytes`; session-file count. Under `defer` Aegis emits nothing on
  an ask, so this is the only place its behavior is visible.
  `rules.snapshot_age_days()` had no caller before this and the
  `snapshot_ttl_days` setting was parsed and never read, so a stale
  snapshot was silent.
- **`aegis prune`** added.

### Fixed

- **Tests no longer read the developer's own config.** `classifier/rules.py`
  loads `~/.config/aegis/aegis.toml` at classify time, so a machine whose
  operator sets `ask_mode = "defer"` saw 7 genuine failures across the
  Python, orchestrator, and ask-mode suites: the suites assert the
  `"prompt"` default and the machine said defer. `tests/bash/*-cases.sh`
  now stub `HOME` and clear every `AEGIS_*` override; `tests/python/conftest.py`
  does the same and redirects `GLOBAL_CONFIG_PATH` and `STATE_DIR`.
  `tests/bash/ask-mode-cases.sh` in particular could not pass under any
  ambient setting: its defer cases wrote a project toml while its prompt
  cases relied on no config existing, so one group always lost.
- Stale docstring in `classifier/decision.py`: `to_hook_output` still
  claimed the bash denylist was the only hard-block channel, which
  stopped being true when `hard_deny_action = "block"` was added.

### Compatibility

- Added an OpenCode plugin adapter that routes OpenCode permission requests
  through the existing Aegis orchestrator while keeping the Claude Code plugin
  path unchanged.
- Added OpenCode command files and installer symlinks for the global OpenCode
  plugin and command directories. `install.sh` only creates them when
  OpenCode is actually present (`command -v opencode`, or an existing
  `~/.config/opencode`); it used to `mkdir -p` that tree on every machine.

### Verification

- Added Node adapter tests for the OpenCode payload mapping, decision mapping,
  permission config hardening, and plugin hook behavior.
- Added Python tests for `defer_scope` resolution, log rotation, and session
  pruning, plus a `defer_scope` matrix in `tests/bash/ask-mode-cases.sh`.

## 1.1.0 -- 2026-05-20

Adds session memory to the classifier. Aegis used to relitigate every
tool call from scratch -- a tool the user approved 20 times could still
get ASKed on call 21, and the model would sometimes invent a deny
rationale on the second call that contradicted the first call's allow.
This release closes that loop and tightens the model's deny discretion.

### Behavior

- **Prior-approval recall.** The classifier now reads the active
  transcript and tallies, per (tool, coarse signature), the tool_uses
  that already ran in this session without a denial marker. The user
  prompt grows a "User-approved patterns this session" block listing
  the matches; the system prompt grows a PRIOR-APPROVAL RECALL paragraph
  telling the model to LEAN ALLOW when the pending call matches one of
  those patterns. Hard-deny categories still bite regardless of history.
  Signature is family-specific: Playwright collapses to `browser`, Bash
  takes its first two tokens, Edit/Write keys on parent dir + extension,
  other MCP tools collapse to `mcp`. Tool_result bodies are never
  propagated to the prompt (only is_error and a small set of denial
  markers), so the prompt injection surface stays zero.
- **ASK over speculative DENY.** The DENY section of the system prompt
  now explicitly says: use DENY only when the action category itself
  clearly applies to a listed bullet (force push, prod ssh, curl|sh,
  mass deletion, etc.). When suspicion comes from substring
  pattern-matching on a payload-looking value -- a `javascript:` in a
  query parameter, a script-tag-shaped string, an unusual flag -- choose
  ASK instead. The classifier's deny is downgraded to ASK at the hook
  boundary anyway, but the ASK prompt body comes from the model's
  reason text, so framing the model toward ASK produces a more neutral
  prompt the user can actually evaluate.

### Verification

Live measurement against a production conductor session: 10 classifier
denies in 3.5 hours before this branch (9 spurious Playwright "Spark
Conductor shouldn't drive UI" rationale on subagent calls that
legitimately needed Playwright, plus one ambiguous HTTP DELETE), versus
1 deny in the 43 minutes after switching to this branch -- and that one
was a `javascript:alert(1)` substring fired by a spark-tester running an
adversarial Tab URL Injection scenario.

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
