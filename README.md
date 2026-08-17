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

By default the classifier never produces a hard block. If the LLM thinks
something is bad enough to deny, that surfaces as ASK with the LLM's
reason as the prompt text -- so the user sees *why* the model objected
and can decide. Aegis is advisory; the operator is the final authority.
(`[behavior] hard_deny_action = "block"` opts out of that and lets a
classifier deny exit 2. Off by default.)

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

### `Bash` allow rule

`install.sh` offers (interactive, default no) to add `"Bash"` to
`permissions.allow` in `~/.claude/settings.json`. This is **load-bearing**:
without it, Claude Code's default-mode prompt fires for every Bash command
not in its built-in safe list, regardless of what the aegis hook returns
(per the [hooks docs](https://code.claude.com/docs/en/hooks-guide):
*"Returning 'allow' skips the interactive prompt but does not override
permission rules. ... If an ask rule matches, the user is still prompted."*).
The documented pattern is to allow `Bash` outright and let the hook
deny/ask the things that need attention.

Risk: if aegis is disabled or fails to load, the rule still applies, so
Bash commands run without prompts. Skip the prompt during install (or
unset by removing the entry) if you want Claude Code's stock prompt as a
backstop.

Non-interactive installs: set `AEGIS_INSTALL_BASH_ALLOW=1` to apply
without prompting, or `=0` to skip.

## Provider Authentication

The default classifier chain uses Gemini as the primary provider. Claude Code
hooks run as non-interactive subprocesses that do **not** inherit your shell
profile env vars (`.bashrc`, `.zshrc`). This means `GEMINI_API_KEY` set in your
shell won't reach the classifier, causing silent failures and chain exhaustion.

**Gemini** (primary): place your API key in `~/.gemini/.env`:
```
GEMINI_API_KEY=<your-key>
```
The Gemini CLI loads this file internally before checking env vars, so it works
regardless of the parent process environment. `install.sh` handles this
automatically if `GEMINI_API_KEY` is in your environment when you run it.

**Claude Haiku** (fallback): authenticates through the existing Claude CLI
login (OAuth/session), not an env var. No extra setup needed. Note that the
default 8s timeout may be too short on some systems (e.g., Termux with proot);
increase `timeout_s` in `aegis.toml` if Haiku times out as fallback.

## Configuration

Global config: `~/.config/aegis/aegis.toml`
Per-project overrides: `<repo>/.aegis/aegis.toml`
Per-project deterministic ASK patterns: `<repo>/.aegis/hard-ask.toml`

The starter config sets the classifier provider chain (gemini-flash-lite
-> gemini-flash -> claude-haiku), deny counters, snapshot TTL, transcript
context limits, and trusted-environment hints.

### `ask_mode`: prompt or defer

```toml
[behavior]
ask_mode = "prompt"   # or "defer"
```

`prompt` (default) is the historical behavior: an ASK verdict is emitted
as `permissionDecision: ask` and Claude Code prompts you.

`defer` emits nothing at all on an ASK -- exit 0, empty stdout. That is
the only hook result that falls through to Claude Code's own permission
pipeline, so its native auto-mode classifier takes the ambiguous middle
instead of interrupting an automated run. A PreToolUse hook that returns
`allow` *or* `ask` short-circuits that pipeline, which is why the ask has
to be dropped rather than rewritten.

Unaffected by this setting:
- hard denies from `lib/bash-denylist.sh` (exit 2) still hard-block;
- allows are still emitted as allows;
- a classifier **deny** verdict is never deferred (see `hard_deny_action`);
- the diagnostic log still records the verdict Aegis reached, so a
  deferred ask is still visible in `~/.cache/aegis/decisions.jsonl`.

What *does* defer: genuine ambiguity. That includes the deterministic
hard-ask patterns (force push, `curl | shell`, ssh to prod-named hosts,
protected paths) and the classifier's own `ask` verdicts.

The mode is resolved once per hook invocation by `orchestrator.sh`
(project toml overrides global toml, and an `AEGIS_ASK_MODE` environment
variable overrides both) and exported so the deterministic layers and the
Python classifier agree.

`defer` hands the ambiguous middle to Anthropic's classifier, which is
laxer than an explicit human prompt. Keep `prompt` if you want to see
every ambiguous call.

### `hard_deny_action`: what a classifier deny does

```toml
[behavior]
hard_deny_action = "prompt"   # or "block"
```

The rule snapshot has a `hard_deny` section (currently one rule, Data
Exfiltration) that the system prompt renders as unconditional. It reaches
the code as a classifier `deny` verdict, and classifier denies have always
been downgraded to ASK so the operator keeps an override. Two consequences
worth being explicit about:

- A deny is **never** deferred, in either `ask_mode`. Handing an
  exfiltration call to the native classifier instead of to you would be
  the wrong failure direction, so `ask_mode = "defer"` does not apply to
  deny verdicts.
- `prompt` (default) keeps the downgrade: you see the model's reason and
  decide. This preserves "Aegis is advisory; the operator is the final
  authority".
- `block` makes the classifier exit 2 instead, Claude Code's hard block,
  with the reason on stderr and no override short of disabling Aegis.
  Note the classifier is an LLM: a false positive under `block` cannot be
  waived in-session.

The system prompt still describes DENY as a hard block. Under the default
`prompt` it is not one; that wording predates this setting.

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
tests/bash/ask-mode-cases.sh                            # ask_mode prompt/defer
```

## Spec

Original design spec (Phase 1, may diverge from current behavior):
[docs/superpowers/specs/2026-04-30-aegis-design.md](docs/superpowers/specs/2026-04-30-aegis-design.md)

See `CHANGELOG.md` for behavioral evolution.
