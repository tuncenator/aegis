import json
import tomllib
from pathlib import Path

import pytest

from classifier import rules


@pytest.fixture
def tmp_repo(tmp_path, monkeypatch):
    snap = {"allow": ["A1", "A2"], "soft_deny": ["D1"], "environment": ["E1"],
            "hard_deny": ["H1"]}
    (tmp_path / "snapshot.json").write_text(json.dumps(snap))
    (tmp_path / "snapshot.meta.json").write_text(json.dumps({
        "fetched_at": "2026-04-30T00:00:00Z",
        "source": "claude auto-mode defaults",
        "ttl_days": 14,
    }))
    monkeypatch.setattr(rules, "SNAPSHOT_PATH", tmp_path / "snapshot.json")
    monkeypatch.setattr(rules, "SNAPSHOT_META_PATH", tmp_path / "snapshot.meta.json")
    return tmp_path


def test_load_snapshot(tmp_repo):
    snap = rules.load_snapshot()
    assert "A1" in snap.allow
    assert "D1" in snap.soft_deny
    assert "E1" in snap.environment
    assert "H1" in snap.hard_deny


def test_load_snapshot_without_hard_deny_defaults_empty(tmp_path, monkeypatch):
    """Older snapshots predate the hard_deny section."""
    p = tmp_path / "snapshot.json"
    p.write_text(json.dumps({"allow": [], "soft_deny": [], "environment": []}))
    monkeypatch.setattr(rules, "SNAPSHOT_PATH", p)
    assert rules.load_snapshot().hard_deny == []


def test_real_snapshot_has_all_four_sections():
    """Guards the shipped rules/snapshot.json against a partial refresh."""
    snap = rules.load_snapshot()
    assert snap.allow and snap.soft_deny and snap.environment and snap.hard_deny


def test_snapshot_age_days(tmp_repo):
    age = rules.snapshot_age_days()
    assert age >= 0


def test_load_global_config_missing_returns_defaults(tmp_path, monkeypatch):
    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", tmp_path / "missing.toml")
    cfg = rules.load_config(project_dir=None)
    assert cfg.classifier_chain
    assert cfg.consecutive_deny_limit == 3
    assert cfg.total_deny_limit == 20
    assert cfg.on_exhaustion == "ask"


def test_load_config_global_only(tmp_path, monkeypatch):
    g = tmp_path / "aegis.toml"
    g.write_text("""
[classifier]
chain = [
  { provider = "gemini", model = "gemini-3.1-flash-lite-preview", retries = 2, timeout_s = 8 },
]
on_exhaustion = "deny"

[counters]
consecutive_deny_limit = 5
total_deny_limit = 50

[environment]
trusted_orgs = ["MYORG"]
trusted_domains = ["example.com"]
""")
    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", g)
    cfg = rules.load_config(project_dir=None)
    assert cfg.consecutive_deny_limit == 5
    assert cfg.total_deny_limit == 50
    assert cfg.on_exhaustion == "deny"
    assert cfg.trusted_orgs == ["MYORG"]


def test_load_config_project_overrides_global(tmp_path, monkeypatch):
    g = tmp_path / "global.toml"
    g.write_text('[counters]\nconsecutive_deny_limit = 5\ntotal_deny_limit = 50\n')
    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", g)
    proj = tmp_path / "proj"
    (proj / ".aegis").mkdir(parents=True)
    (proj / ".aegis" / "aegis.toml").write_text(
        '[counters]\nconsecutive_deny_limit = 10\n'
    )
    cfg = rules.load_config(project_dir=str(proj))
    assert cfg.consecutive_deny_limit == 10  # project override
    assert cfg.total_deny_limit == 50  # inherited from global


def test_ask_mode_defaults_to_prompt(tmp_path, monkeypatch):
    monkeypatch.delenv("AEGIS_ASK_MODE", raising=False)
    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", tmp_path / "missing.toml")
    assert rules.load_config(project_dir=None).ask_mode == "prompt"


def test_ask_mode_defer_from_global_config(tmp_path, monkeypatch):
    monkeypatch.delenv("AEGIS_ASK_MODE", raising=False)
    g = tmp_path / "aegis.toml"
    g.write_text('[behavior]\nask_mode = "defer"\n')
    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", g)
    assert rules.load_config(project_dir=None).ask_mode == "defer"


def test_ask_mode_project_overrides_global(tmp_path, monkeypatch):
    monkeypatch.delenv("AEGIS_ASK_MODE", raising=False)
    g = tmp_path / "global.toml"
    g.write_text('[behavior]\nask_mode = "defer"\n')
    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", g)
    proj = tmp_path / "proj"
    (proj / ".aegis").mkdir(parents=True)
    (proj / ".aegis" / "aegis.toml").write_text('[behavior]\nask_mode = "prompt"\n')
    assert rules.load_config(project_dir=str(proj)).ask_mode == "prompt"


def test_ask_mode_invalid_value_ignored(tmp_path, monkeypatch):
    monkeypatch.delenv("AEGIS_ASK_MODE", raising=False)
    g = tmp_path / "aegis.toml"
    g.write_text('[behavior]\nask_mode = "yolo"\n')
    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", g)
    assert rules.load_config(project_dir=None).ask_mode == "prompt"


def test_ask_mode_env_var_wins(tmp_path, monkeypatch):
    """orchestrator.sh resolves the mode once and exports it, so the
    classifier agrees with the deterministic layers."""
    g = tmp_path / "aegis.toml"
    g.write_text('[behavior]\nask_mode = "prompt"\n')
    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", g)
    monkeypatch.setenv("AEGIS_ASK_MODE", "defer")
    assert rules.load_config(project_dir=None).ask_mode == "defer"
