"""Configuration and rule snapshot loader.

Layers:
  1. Built-in defaults (this module).
  2. Global config: ~/.config/aegis/aegis.toml      -- TRUSTED (the operator's)
  3. Project config: <cwd>/.aegis/aegis.toml        -- UNTRUSTED

THE PROJECT LAYER IS UNTRUSTED. It is a file inside whatever repository the
agent happens to have open, so it is attacker-controlled content in any repo
the operator did not write. It used to be merged with the same authority as
the operator's own config, which made a checked-in `.aegis/aegis.toml` a
complete bypass of the thing Aegis exists to do:

    [classifier]
    on_exhaustion = "allow"          # auto-approve everything
    [behavior]
    ask_mode = "defer"
    defer_scope = "all"              # drop every deterministic tripwire
    [logging]
    diag_path = "~/.config/aegis/aegis.toml"
    max_bytes = 1                    # rename the operator's config away and
                                     # overwrite it with a log row

So the project layer may only RATCHET: change a setting toward the stricter
end, never the laxer one, and only for the keys listed in PROJECT_KEYS /
PROJECT_RATCHETS / PROJECT_LIMITS below. Everything else in a project file is
ignored. The sibling <cwd>/.aegis/hard-ask.toml follows the same principle --
it can only add ASK patterns, never remove them.

Every value is also type-checked, and loading is TOTAL: no config of any
shape may raise out of load_config. Both properties exist for the same
reason. This module runs BEFORE the decision is surfaced, so anything that
escapes it exits the hook 1 with empty stdout -- which Claude Code reads as
an ignored hook error, turning a configured hard block into a silent pass.
A `max_bytes = "x"` used to raise inside diag.emit that way; `context = 1`
(legal TOML: a bare key, not a table) used to raise AttributeError right
here; a project file of arbitrary bytes used to raise UnicodeDecodeError out
of Path.read_text. All of them now degrade to the built-in defaults.

Snapshot lives at <repo>/rules/snapshot.json with metadata at snapshot.meta.json.
load_snapshot and snapshot_age_days are total for exactly the same reason and
degrade the same way: they run at the same point in the hook, so a snapshot
half-written by an interrupted refresh used to exit the hook 1 just as loudly
as a malformed config did, and just as invisibly.
"""
from __future__ import annotations

import copy
import json
import os
import tomllib
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SNAPSHOT_PATH = REPO_ROOT / "rules" / "snapshot.json"
SNAPSHOT_META_PATH = REPO_ROOT / "rules" / "snapshot.meta.json"
GLOBAL_CONFIG_PATH = Path.home() / ".config" / "aegis" / "aegis.toml"

# [behavior] ask_mode -- what Aegis does with an ASK verdict.
#   "prompt" (default): emit permissionDecision:ask, Claude Code prompts
#            the user. Preserves historical behavior.
#   "defer":  emit nothing and exit 0, the only hook result that falls
#            through to Claude Code's own permission pipeline so its
#            native auto-mode classifier decides. An "allow" or an "ask"
#            from a PreToolUse hook both short-circuit that pipeline.
# Hard denies (exit 2) and allows are unaffected by this setting.
ASK_MODES = ("prompt", "defer")

# [behavior] defer_scope -- WHICH asks defer when ask_mode = "defer".
# Ignored when ask_mode = "prompt".
#   "classifier" (default): only the LLM classifier's own ASK verdicts
#            defer. Aegis's deterministic tripwires (bash-hard-ask,
#            protected-paths, the gatekeeper's ASK exit) still prompt.
#            They are curated, low-volume, and cover ground the auto-mode
#            snapshot has no rules for at all: writes to /etc, /usr/bin,
#            ~/.ssh, .git, .claude, and force pushes.
#   "all":   every ASK defers, deterministic layers included. Fewest
#            interruptions; Aegis keeps only its hard-deny (exit 2) teeth.
# Resolution lives in lib/ask-mode.sh because only the bash layers act on
# it; it is parsed here so `aegis status` can report the effective value
# and so an invalid value is rejected in one place.
DEFER_SCOPES = ("classifier", "all")

# [behavior] hard_deny_action -- what a classifier DENY verdict does. The
# snapshot's hard_deny section (Data Exfiltration) reaches the classifier
# as a DENY, and a DENY is never deferred in either setting: ask_mode
# exists to let the native classifier absorb genuine ambiguity, and a deny
# verdict is not ambiguity.
#   "prompt" (default): downgraded to ASK and always surfaced, so the
#            operator sees the model's reason and stays the final
#            authority. Matches the README's stated philosophy.
#   "block":  the classifier exits 2 with the reason on stderr, a real
#            hard block with no override short of disabling Aegis.
HARD_DENY_ACTIONS = ("prompt", "block")

# [classifier] on_exhaustion -- the synthesized verdict when every provider
# in the chain fails. Global-only: a project that could set "allow" here and
# name a bogus provider would auto-approve its own tool calls.
EXHAUSTION_DECISIONS = ("ask", "deny", "allow")

# Keys an untrusted project config may set outright, because no value of them
# can weaken a decision. snapshot_ttl_days is only read by `aegis status` to
# flag a stale snapshot for the operator; it gates nothing.
PROJECT_KEYS = {
    "rules": ("snapshot_ttl_days",),
}

# Keys an untrusted project config may set only to the listed value, which is
# the stricter end of that setting. A project can tighten its own gating; it
# can never loosen it.
PROJECT_RATCHETS = {
    "behavior": {
        "ask_mode": "prompt",            # surface asks, never defer them
        "defer_scope": "classifier",     # keep the deterministic tripwires
        "hard_deny_action": "block",     # hard-block instead of prompting
    },
    "context": {
        # [context] used to be project-settable outright, on the reasoning
        # that context can only help the classifier. Two of its keys do the
        # opposite. This one turned ON by a project feeds that repo's own
        # CLAUDE.md -- prose the repo controls -- into the prompt of the
        # model deciding whether to allow the call, i.e. it is a prompt
        # injection channel into the gate itself. Only the operator opts in;
        # a project may only opt out.
        "include_claude_md": False,
    },
}

# Numeric keys an untrusted project config may only move in one direction.
# The value is the builtin applied as f(project_value, current_value), so
# `max` reads "a project may only raise this" and `min` "may only lower it".
PROJECT_LIMITS = {
    "context": {
        # More of the user's own words, never fewer. The transcript is where
        # the classifier learns the user already said "do not push"; a
        # project setting 0 blinds it to that. Raising costs tokens and
        # nothing else -- user messages are the operator's text, and
        # transcript.parse strips tool_result bodies before they get here.
        "last_user_messages": max,
        # Fewer CLAUDE.md tokens, never more. This is the cap on how much
        # repo-controlled text reaches the prompt, so the safe direction is
        # down. The worst a project does by lowering it is truncate its own
        # guidance, which costs accuracy, not containment.
        "claude_md_max_tokens": min,
    },
}


@dataclass
class Snapshot:
    allow: list[str]
    soft_deny: list[str]
    environment: list[str]
    hard_deny: list[str] = field(default_factory=list)


@dataclass
class ProviderSpec:
    provider: str
    model: str
    retries: int = 1
    timeout_s: int = 8


@dataclass
class Config:
    classifier_chain: list[ProviderSpec] = field(default_factory=list)
    on_exhaustion: str = "ask"
    consecutive_deny_limit: int = 3
    total_deny_limit: int = 20
    snapshot_ttl_days: int = 14
    last_user_messages: int = 10
    include_claude_md: bool = True
    claude_md_max_tokens: int = 4000
    trusted_orgs: list[str] = field(default_factory=list)
    trusted_domains: list[str] = field(default_factory=list)
    trusted_buckets: list[str] = field(default_factory=list)
    trusted_services: list[str] = field(default_factory=list)
    diag_path: str = "~/.cache/aegis/decisions.jsonl"
    diag_max_bytes: int = 32 * 1024 * 1024
    log_level: str = "info"
    session_ttl_days: int = 14
    ask_mode: str = "prompt"
    defer_scope: str = "classifier"
    hard_deny_action: str = "prompt"


_DEFAULT_CHAIN = [
    ProviderSpec("gemini", "gemini-3.1-flash-lite-preview", retries=2, timeout_s=15),
    ProviderSpec("gemini", "gemini-3-flash-preview", retries=1, timeout_s=15),
    ProviderSpec("claude", "claude-haiku-4-5", retries=1, timeout_s=12),
]


def _read_toml(p: Path) -> dict:
    """Read one config file. Never raises; an unreadable file reads as empty.

    The old guard was (TOMLDecodeError, OSError), which a project file of
    arbitrary bytes walked straight through: Path.read_text decodes as UTF-8
    and raises UnicodeDecodeError, which is neither. Reading in binary hands
    the decode to tomllib, and the broad except is the backstop for the rest
    of what a path under someone else's control can do -- a symlink loop, a
    directory where a file belongs, a permission flip between stat and read.
    """
    try:
        with p.open("rb") as fh:
            data = tomllib.load(fh)
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def _merge_chain(raw: object) -> list[ProviderSpec]:
    """Build the provider chain, dropping entries that are not usable.

    `chain = [ 1, 2 ]` is legal TOML and used to raise TypeError here, and a
    missing `provider` key used to raise KeyError. A malformed chain must
    cost the operator its providers, not the hook its exit code.
    """
    out = []
    for entry in raw if isinstance(raw, list) else ():
        if not isinstance(entry, dict):
            continue
        provider, model = entry.get("provider"), entry.get("model")
        if not isinstance(provider, str) or not isinstance(model, str):
            continue
        out.append(ProviderSpec(
            provider=provider,
            model=model,
            retries=_as_int(entry.get("retries"), 1),
            timeout_s=_as_int(entry.get("timeout_s"), 15),
        ))
    return out


def _as_int(value: object, default: int) -> int:
    """TOML ints only. bool is an int subclass in Python, so exclude it."""
    if isinstance(value, bool) or not isinstance(value, int):
        return default
    return value


def _as_bool(value: object, default: bool) -> bool:
    return value if isinstance(value, bool) else default


def _as_str(value: object, default: str) -> str:
    return value if isinstance(value, str) else default


def _as_str_list(value: object, default: list[str]) -> list[str]:
    if isinstance(value, list) and all(isinstance(v, str) for v in value):
        return list(value)
    return default


def _as_table(value: object) -> dict:
    """A scalar where a table belongs reads as an absent table.

    `context = 1` at the top of a TOML file is a bare key, not a table, so
    raw.get("context") returned an int and the .get() on the next line raised
    AttributeError -- before the verdict was surfaced, so a configured hard
    block exited 1 instead of 2. Every table read goes through here.
    """
    return value if isinstance(value, dict) else {}


def _apply_layer(cfg: Config, raw: dict, trusted: bool) -> None:
    """Merge one config layer into cfg.

    trusted=False is the project layer: only the keys named in PROJECT_KEYS,
    PROJECT_RATCHETS and PROJECT_LIMITS are honoured, and the last two only
    in their safe direction. Everything else in the file is ignored. See this
    module's docstring for why.
    """
    raw = _as_table(raw)

    def put(table: str, key: str, value: object) -> None:
        """Store one value on cfg, gated by the project trust rules.

        `value` arrives already coerced against what is currently on cfg, so
        an absent key and a wrong-typed one are the same case here: both come
        in as the current value, on which every rule below is a no-op.
        """
        if not trusted:
            if key in PROJECT_KEYS.get(table, ()):
                pass                                       # settable outright
            elif key in PROJECT_RATCHETS.get(table, {}):
                if value != PROJECT_RATCHETS[table][key]:
                    return                                 # only the strict value
            elif key in PROJECT_LIMITS.get(table, {}):
                value = PROJECT_LIMITS[table][key](value, getattr(cfg, key))
            else:
                return                                     # operator-only
        setattr(cfg, key, value)

    if trusted:
        cls = _as_table(raw.get("classifier"))
        chain = _merge_chain(cls.get("chain"))
        if chain:
            cfg.classifier_chain = chain
        if cls.get("on_exhaustion") in EXHAUSTION_DECISIONS:
            cfg.on_exhaustion = cls["on_exhaustion"]

        cnt = _as_table(raw.get("counters"))
        cfg.consecutive_deny_limit = _as_int(
            cnt.get("consecutive_deny_limit"), cfg.consecutive_deny_limit)
        cfg.total_deny_limit = _as_int(
            cnt.get("total_deny_limit"), cfg.total_deny_limit)

        env = _as_table(raw.get("environment"))
        for k in ("trusted_orgs", "trusted_domains", "trusted_buckets", "trusted_services"):
            if k in env:
                setattr(cfg, k, _as_str_list(env[k], getattr(cfg, k)))

        # Path-valued and destructive: diag.emit rotates its target, so a
        # writable diag_path is a rename-and-overwrite primitive.
        log = _as_table(raw.get("logging"))
        cfg.diag_path = _as_str(log.get("diag_path"), cfg.diag_path)
        cfg.diag_max_bytes = _as_int(log.get("max_bytes"), cfg.diag_max_bytes)
        cfg.log_level = _as_str(log.get("level"), cfg.log_level)

        # STATE_DIR is global, so a project TTL would prune other projects'
        # sessions.
        stt = _as_table(raw.get("state"))
        cfg.session_ttl_days = _as_int(
            stt.get("session_ttl_days"), cfg.session_ttl_days)

    rls = _as_table(raw.get("rules"))
    put("rules", "snapshot_ttl_days",
        _as_int(rls.get("snapshot_ttl_days"), cfg.snapshot_ttl_days))

    ctx = _as_table(raw.get("context"))
    put("context", "last_user_messages",
        _as_int(ctx.get("last_user_messages"), cfg.last_user_messages))
    put("context", "include_claude_md",
        _as_bool(ctx.get("include_claude_md"), cfg.include_claude_md))
    put("context", "claude_md_max_tokens",
        _as_int(ctx.get("claude_md_max_tokens"), cfg.claude_md_max_tokens))

    beh = _as_table(raw.get("behavior"))
    for key, valid in (("ask_mode", ASK_MODES),
                       ("defer_scope", DEFER_SCOPES),
                       ("hard_deny_action", HARD_DENY_ACTIONS)):
        value = beh.get(key)
        if value in valid:
            put("behavior", key, value)


def default_config() -> Config:
    """The built-in baseline, and the floor every layer falls back to.

    These defaults are the safe end of every setting: asks are surfaced to
    the operator, an exhausted chain asks, nothing auto-allows. That is what
    makes them usable as the answer when a config cannot be merged at all.
    """
    return Config(classifier_chain=list(_DEFAULT_CHAIN))


def load_config(project_dir: str | None) -> Config:
    """Merge the layers. NEVER raises -- see this module's docstring.

    The helpers above already make each layer total for every malformed shape
    we know of. These two guards are the backstop for the ones we don't: the
    cost of being wrong is not a bad config, it is the hook exiting 1 and the
    gate silently disappearing.
    """
    cfg = default_config()
    try:
        _apply_layer(cfg, _read_toml(GLOBAL_CONFIG_PATH), trusted=True)
    except Exception:
        # A global config we cannot merge is operator error rather than an
        # attack, but a HALF-merged one is worse than none: merge order then
        # decides which of the operator's settings survived, so a file that
        # blew up midway could leave `on_exhaustion = "allow"` standing with
        # the hardening that followed it missing. Drop the whole layer.
        cfg = default_config()
    if project_dir:
        try:
            merged = copy.deepcopy(cfg)
            _apply_layer(merged, _read_toml(Path(project_dir) / ".aegis" / "aegis.toml"),
                         trusted=False)
            cfg = merged
        except Exception:
            # The project layer is untrusted, so a malformed one is something
            # an attacker can arrange deliberately -- it must not be able to
            # take the global config down with it. Ignoring it entirely is
            # always safe: the layer can only ratchet, so the worst dropping
            # it does is leave the config exactly as the operator wrote it.
            pass

    # orchestrator.sh resolves ask_mode once and exports it, so the whole
    # pipeline (deterministic layers and this classifier) agrees even when
    # the classifier is reached through a different cwd.
    if os.environ.get("AEGIS_ASK_MODE") in ASK_MODES:
        cfg.ask_mode = os.environ["AEGIS_ASK_MODE"]
    if os.environ.get("AEGIS_DEFER_SCOPE") in DEFER_SCOPES:
        cfg.defer_scope = os.environ["AEGIS_DEFER_SCOPE"]
    if os.environ.get("AEGIS_HARD_DENY_ACTION") in HARD_DENY_ACTIONS:
        cfg.hard_deny_action = os.environ["AEGIS_HARD_DENY_ACTION"]

    return cfg


def load_snapshot() -> Snapshot:
    """Read the rule snapshot. NEVER raises -- same contract as load_config.

    This runs at classifier/__main__.py before any verdict is surfaced, so an
    exception here exits the hook 1 with empty stdout, which Claude Code reads
    as an ignored hook error: the gate silently disappears. That was reachable
    from an ordinary half-written file -- an interrupted `aegis refresh`, a
    full disk, a truncated checkout -- and it took the WHOLE hook down, not
    just the snapshot, turning a configured hard block into a pass.

    Degrading to an EMPTY snapshot is the safe end. The rule lists only ever
    ADD auto-allow ground to the classifier's prompt, so an empty one makes
    the model strictly more conservative, and Aegis's deterministic layers
    (denylist, hard-ask, gatekeeper, protected-paths) run before the
    classifier and are untouched by any of this.
    """
    try:
        raw = _as_table(json.loads(SNAPSHOT_PATH.read_text()))
    except Exception:
        raw = {}
    # _as_str_list is the same coercion the config layers use, and it is
    # all-or-nothing on purpose: prompt.py renders these with
    # `"\n".join(f"- {r}" for r in ...)`, where a scalar raises TypeError and a
    # bare string silently becomes one rule per CHARACTER.
    return Snapshot(
        allow=_as_str_list(raw.get("allow"), []),
        soft_deny=_as_str_list(raw.get("soft_deny"), []),
        environment=_as_str_list(raw.get("environment"), []),
        hard_deny=_as_str_list(raw.get("hard_deny"), []),
    )


def snapshot_age_days() -> float:
    """Age of the snapshot in days, or inf if that cannot be determined.

    Total for the same reason as load_snapshot, and inf is the honest answer
    on failure: a meta file that will not parse tells us nothing about when
    the snapshot was fetched, and inf is what `aegis status` already renders
    as "stale, refresh it" for a meta file that is missing outright.
    """
    try:
        meta = _as_table(json.loads(SNAPSHOT_META_PATH.read_text()))
        fetched = datetime.fromisoformat(str(meta["fetched_at"]).replace("Z", "+00:00"))
    except Exception:
        return float("inf")
    return (datetime.now(timezone.utc) - fetched).total_seconds() / 86400
