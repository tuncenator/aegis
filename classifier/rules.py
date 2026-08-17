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
    log_level: str = "info"
    ask_mode: str = "prompt"


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
        cfg.log_level = log.get("level", cfg.log_level)

        beh = raw.get("behavior", {})
        if beh.get("ask_mode") in ASK_MODES:
            cfg.ask_mode = beh["ask_mode"]

    # orchestrator.sh resolves ask_mode once and exports it, so the whole
    # pipeline (deterministic layers and this classifier) agrees even when
    # the classifier is reached through a different cwd.
    if os.environ.get("AEGIS_ASK_MODE") in ASK_MODES:
        cfg.ask_mode = os.environ["AEGIS_ASK_MODE"]

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
