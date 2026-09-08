# Changelog

## 1.2.1 -- 2026-09-08

Documentation only; no behavior change. The README is rewritten against what
the code actually does. Auditing it against the source found 27 stale or false
claims and 18 behaviors documented nowhere.

The largest correction is the framing. Aegis was described as a replacement for
Claude Code's `auto` mode that "never invokes" it. In fact the two compose, and
four paths hand a call to native auto mode: `ask_mode = "defer"`, a disabled
session, a hook error, and any tool family Aegis does not match. The README
already leaned on that fallback when accepting the self-write residual, so it
contradicted itself.

Five figures were added: where Aegis sits relative to auto mode, the measured
traffic split, the layer pipeline, the `ask_mode` / `defer_scope` decision tree,
and what `/aegis-off` actually leaves running.

### Newly documented

- The deny-storm auto-pause, which disables the classifier after 3 consecutive
  or 20 total denies.
- `~/.cache/aegis/errors.jsonl`, the unrotated provider-failure log, and the
  only place chain exhaustion is visible.
- `[classifier] on_exhaustion`, including that `allow` auto-approves every
  classified call during a provider outage.
- `AEGIS_HARD_DENY_ACTION`, and that the live hook honours
  `AEGIS_TEST_MOCK_DECISION`.
- Prior-approval recall, shipped in 1.1.0 and unmentioned since.
- `include_claude_md` defaulting to `true`, so the open repository's own
  `CLAUDE.md` reaches the gate's own prompt unless the operator opts out.
- What leaves the machine on every classified call.
- The `.aegis/hard-ask.toml` format, which is not TOML-parsed.
- The OpenCode plugin rewriting the host's permission config on load.
- `GATEKEEPER_DEBUG=1`.

### Corrected

- Gemini goes through the `google-genai` SDK, not the CLI, and an environment
  variable beats `~/.gemini/.env` rather than the reverse.
- `/aegis-off` disables only the LLM classifier. The four deterministic layers
  keep running, so a disabled session still auto-allows most Bash.
- `aegis status` prints `defer_scope` only under `ask_mode = "defer"`.
- `uv sync` is required, and `aegis status` runs clean over a dead classifier.
- The rule snapshot does mention `/etc` and `/usr`; what it has no rule *keyed*
  on is a system path.
- Aegis is now stricter than the snapshot on pushes to the default branch.
- Hit rates re-measured on a current log. The old "one prompt per 470 calls"
  predates the wider self-write gating in 1.2.0.
- `<cwd>/.aegis/`, not `<repo>/.aegis/`: no loader walks up to the repo root.
- `[logging] level` is parsed and never used.
- The slash commands only work when cwd is the Aegis repo.
- Standalone bash-only mode needs all three Bash layers, not two.

### Known drift, not fixed here

`plugin/.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` still
carry `1.1.0`. They were not bumped for 1.2.0 either, and no release commit has
ever touched them.

## 1.2.0 -- 2026-08-19

Hardens Aegis against being switched off. Nine ways the gate could silently
disappear were found and fixed, most of them reachable from a file checked
into whatever repository the agent has open. Adds `defer_scope`, so handing
the ambiguous middle to Claude Code's native auto mode no longer means giving
up Aegis's own deterministic tripwires.

### Breaking

- **A project `<cwd>/.aegis/aegis.toml` may now only ratchet toward stricter
  values.** Keys outside `[context]`, `snapshot_ttl_days` and the three
  `[behavior]` ratchets are read from the global config only, and a project
  file setting them is silently ignored rather than honoured. If you relied on
  a project config to set the provider chain, counters, logging, state TTL or
  trusted environment, move those to `~/.config/aegis/aegis.toml`. `aegis
  status` names a project config when one is present. See the README's Trust
  model section for the reasoning.

### Security

Found by an adversarial review of the `defer_scope` work. All six were
reproduced before being fixed and are pinned by tests.

- **The project config layer is now untrusted.** `<cwd>/.aegis/aegis.toml`
  used to merge with the same authority as the operator's own global config,
  but it is a file inside whatever repository the agent has open. A
  checked-in project config was a complete bypass: `on_exhaustion = "allow"`
  with a bogus provider chain auto-approved everything, `defer_scope = "all"`
  dropped every deterministic tripwire, and `[environment] trusted_domains`
  widened the exfiltration boundary. A project may now only *ratchet* a
  setting toward its stricter value (`ask_mode = "prompt"`,
  `defer_scope = "classifier"`, `hard_deny_action = "block"`,
  `include_claude_md = false`), move a numeric limit in the safe direction
  only (`last_user_messages` up, `claude_md_max_tokens` down), or set
  `snapshot_ttl_days`, which gates nothing; every other table is global-only.
  `[context]` is no longer settable outright: a project that turned on
  `include_claude_md` was feeding its own repo-controlled `CLAUDE.md` into
  the prompt of the model gating its tool calls. See `PROJECT_KEYS` /
  `PROJECT_RATCHETS` / `PROJECT_LIMITS` in `classifier/rules.py` -- now the
  single definition, since `lib/ask-mode.sh` resolves through that same
  loader rather than parsing the config a second time.
- **`[logging] diag_path` was an arbitrary-file rename-and-overwrite
  primitive.** A project pointing it at any user-writable file, with
  `max_bytes = 1`, made the next tool call rename that file to `<name>.1`
  and replace it with a JSON log row -- silently stripping a global
  `hard_deny_action = "block"` policy, among other things. Rotation is what
  turned the previous append-only behavior destructive. `[logging]` is now
  global-only.
- **A malformed config value failed a hard block open.** `max_bytes = "x"`
  raised inside `diag.emit`, which runs *before* `decision.surface()`, so a
  classifier DENY configured to block exited 1 with empty stdout -- an
  ignored hook error -- instead of 2. Every config value is now type-checked,
  `on_exhaustion` is validated against `allow|deny|ask`, and both the diag
  and prune calls are wrapped so diagnostics can never change a decision.
- **Self-write gating widened, with a measured limit.** The lexical
  protected-path matcher was evaded by quote and backslash splits, variables,
  globs, dot segments, cwd-relative paths, symlinks, and writer modes such as
  `git diff --output`. Fixed here: `git diff/show --output`, redirects issued
  from inside a protected tree (where the cwd supplies the rest of the path,
  the shortest and most natural way to write those files), and Edit/Write
  paths, which are now normalized against their payload cwd and resolved
  through existing symlinks. The classifier also gained an overriding
  self-protection DENY rule for anything that reaches layer 4.

  Twelve obfuscated forms remain uncaught, pinned as RESIDUAL in
  `tests/bash/corpus/aegis-self-write-bypasses.txt` with the reasoning. The
  complete fix was built and measured: restricting `lib/bash-gatekeeper.sh` to
  hard-allow only proven readers caught all twelve, and dropped the hard-allow
  rate on 1854 real commands from 75% to 5%. That puts 950 of every 1000 Bash
  calls on the LLM classifier, roughly 4x the model spend and 16 extra minutes
  of latency per 1000 calls, permanently. It was reverted on blast radius: an
  attacker who lands one of those forms disables Aegis, and Claude Code's
  native auto mode still gates the session, which is exactly what
  `ask_mode = "defer"` already falls through to. A certain, permanent cost was
  not worth closing a narrow path whose worst case is the chosen fallback.
- **The bash config reader no longer reads configuration out of string
  content.** `lib/ask-mode.sh` matched `defer_scope = "all"` inside a
  multi-line TOML string, so the shell layers and Python's `tomllib`
  disagreed about what was gated: `aegis status` reported deterministic asks
  still prompting while the orchestrator silently dropped them. Multi-line
  basic and literal strings are now tracked and skipped, and both keys are
  read in one pass instead of two.
- **Pruning no longer resurrects a disabled session.** The classifier returns
  early for a disabled session without re-saving, so its mtime stops
  advancing the moment it is disabled and it looks stale almost immediately.
  Pruning it reloaded the session as `enabled=True`, undoing `aegis off` and
  the deny-storm auto-pause. Disabled sessions are now never pruned, and the
  unlink re-checks mtime to narrow the race with a concurrent write.
- Rotation takes an `O_EXCL` lock (with a stale-lock escape), so two hooks
  that both observe a full log cannot both rename it and destroy the
  retained generation. A newly created log is mode 0600; rows quote pending
  command text and classifier reasons.
- Test suites unset the provider API keys. Stubbing `HOME` does not on its
  own keep a run offline, because the SDK reads `GEMINI_API_KEY` from the
  environment -- the previous comment claiming otherwise was wrong.

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
- Added `tests/python/test_project_trust.py` (24 cases) pinning the untrusted
  project layer, the behavior ratchet, and config type validation, including
  end-to-end runs of the two reproductions that mattered: the global-config
  overwrite, and the hard block that exited 1.
- Added `tests/bash/self-modification-cases.sh` and its corpus, covering the
  Bash and Edit/Write paths into Aegis's config and install tree.
- `tests/bash/ask-mode-cases.sh` moves its loosening fixtures from project
  configs to stubbed global configs (they are global-only now) and gains four
  cases asserting the project ratchet in both directions.

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
