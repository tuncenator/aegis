"""Configuration and rule snapshot loader.

Layers:
  1. Built-in defaults (this module).
  2. Global config: ~/.config/aegis/aegis.toml
  3. Project config: <cwd>/.aegis/aegis.toml

Project values deep-merge over global, which deep-merges over defaults.
Snapshot lives at <repo>/rules/snapshot.json with metadata at snapshot.meta.json.
"""
from __future__ import annotations

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
    if not p.exists():
        return {}
    try:
        return tomllib.loads(p.read_text())
    except (tomllib.TOMLDecodeError, OSError):
        return {}


def _merge_chain(raw: list[dict]) -> list[ProviderSpec]:
    out = []
    for entry in raw:
        out.append(ProviderSpec(
            provider=entry["provider"],
            model=entry["model"],
            retries=entry.get("retries", 1),
            timeout_s=entry.get("timeout_s", 15),
        ))
    return out


def load_config(project_dir: str | None) -> Config:
    cfg = Config(classifier_chain=list(_DEFAULT_CHAIN))
    layers = [_read_toml(GLOBAL_CONFIG_PATH)]
    if project_dir:
        layers.append(_read_toml(Path(project_dir) / ".aegis" / "aegis.toml"))
    for raw in layers:
        if not raw:
            continue
        cls = raw.get("classifier", {})
        if "chain" in cls:
            cfg.classifier_chain = _merge_chain(cls["chain"])
        if "on_exhaustion" in cls:
            cfg.on_exhaustion = cls["on_exhaustion"]

        cnt = raw.get("counters", {})
        cfg.consecutive_deny_limit = cnt.get("consecutive_deny_limit", cfg.consecutive_deny_limit)
        cfg.total_deny_limit = cnt.get("total_deny_limit", cfg.total_deny_limit)

        rls = raw.get("rules", {})
        cfg.snapshot_ttl_days = rls.get("snapshot_ttl_days", cfg.snapshot_ttl_days)

        ctx = raw.get("context", {})
        cfg.last_user_messages = ctx.get("last_user_messages", cfg.last_user_messages)
        cfg.include_claude_md = ctx.get("include_claude_md", cfg.include_claude_md)
        cfg.claude_md_max_tokens = ctx.get("claude_md_max_tokens", cfg.claude_md_max_tokens)

        env = raw.get("environment", {})
        for k in ("trusted_orgs", "trusted_domains", "trusted_buckets", "trusted_services"):
            if k in env:
                setattr(cfg, k, env[k])

        log = raw.get("logging", {})
        cfg.diag_path = log.get("diag_path", cfg.diag_path)
        cfg.diag_max_bytes = log.get("max_bytes", cfg.diag_max_bytes)
        cfg.log_level = log.get("level", cfg.log_level)

        stt = raw.get("state", {})
        cfg.session_ttl_days = stt.get("session_ttl_days", cfg.session_ttl_days)

        beh = raw.get("behavior", {})
        if beh.get("ask_mode") in ASK_MODES:
            cfg.ask_mode = beh["ask_mode"]
        if beh.get("defer_scope") in DEFER_SCOPES:
            cfg.defer_scope = beh["defer_scope"]
        if beh.get("hard_deny_action") in HARD_DENY_ACTIONS:
            cfg.hard_deny_action = beh["hard_deny_action"]

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
    raw = json.loads(SNAPSHOT_PATH.read_text())
    return Snapshot(
        allow=raw.get("allow", []),
        soft_deny=raw.get("soft_deny", []),
        environment=raw.get("environment", []),
        hard_deny=raw.get("hard_deny", []),
    )


def snapshot_age_days() -> float:
    if not SNAPSHOT_META_PATH.exists():
        return float("inf")
    meta = json.loads(SNAPSHOT_META_PATH.read_text())
    fetched = datetime.fromisoformat(meta["fetched_at"].replace("Z", "+00:00"))
    return (datetime.now(timezone.utc) - fetched).total_seconds() / 86400
