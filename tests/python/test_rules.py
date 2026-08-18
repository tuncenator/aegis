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


# --- the snapshot loaders are TOTAL ---------------------------------------
#
# load_snapshot runs in classifier/__main__.py before any verdict is
# surfaced, so anything it raises exits the hook 1 with empty stdout -- which
# Claude Code reads as an ignored hook error, silently turning a configured
# hard block into a pass. An interrupted `aegis refresh`, a full disk or a
# truncated checkout is enough to produce every shape below.

@pytest.mark.parametrize("body", [
    '{"allow": [',                 # truncated mid-array
    "not json at all",
    "5",                           # valid JSON, but a scalar where a table goes
    '"a string"',
    "[]",                          # valid JSON, but a list where a table goes
    "",                            # empty file
])
def test_load_snapshot_never_raises_on_malformed_json(tmp_path, monkeypatch, body):
    p = tmp_path / "snapshot.json"
    p.write_text(body)
    monkeypatch.setattr(rules, "SNAPSHOT_PATH", p)
    snap = rules.load_snapshot()
    # Degrades to empty, which only makes the classifier more conservative.
    assert snap.allow == [] and snap.soft_deny == []
    assert snap.environment == [] and snap.hard_deny == []


def test_load_snapshot_never_raises_when_missing(tmp_path, monkeypatch):
    monkeypatch.setattr(rules, "SNAPSHOT_PATH", tmp_path / "gone.json")
    assert rules.load_snapshot().allow == []


def test_load_snapshot_never_raises_on_undecodable_bytes(tmp_path, monkeypatch):
    p = tmp_path / "snapshot.json"
    p.write_bytes(b"\xff\xfe\x00 not utf-8")
    monkeypatch.setattr(rules, "SNAPSHOT_PATH", p)
    assert rules.load_snapshot().allow == []


def test_load_snapshot_drops_non_string_rules(tmp_path, monkeypatch):
    """A scalar rule list would raise in prompt.py; a bare string would
    silently render one rule per CHARACTER. The coercion is all-or-nothing,
    matching what the config layers do with the same helper: a rule list with
    a non-string in it is not trustworthy enough to half-use."""
    p = tmp_path / "snapshot.json"
    p.write_text(json.dumps({
        "allow": "ls -la",              # string, not a list
        "soft_deny": 7,                 # scalar
        "environment": ["E1", 5, None, "E2"],   # mixed
        "hard_deny": {"a": 1},          # table
    }))
    monkeypatch.setattr(rules, "SNAPSHOT_PATH", p)
    snap = rules.load_snapshot()
    assert snap.allow == []
    assert snap.soft_deny == []
    assert snap.environment == []
    assert snap.hard_deny == []


def test_load_snapshot_keeps_a_clean_rule_list(tmp_path, monkeypatch):
    """The coercion must not eat well-formed rules -- pins that the guard
    above is a filter on malformed input, not on everything."""
    p = tmp_path / "snapshot.json"
    p.write_text(json.dumps({
        "allow": ["A1", "A2"], "soft_deny": ["D1"],
        "environment": ["E1"], "hard_deny": ["H1"],
    }))
    monkeypatch.setattr(rules, "SNAPSHOT_PATH", p)
    snap = rules.load_snapshot()
    assert snap.allow == ["A1", "A2"] and snap.soft_deny == ["D1"]
    assert snap.environment == ["E1"] and snap.hard_deny == ["H1"]


@pytest.mark.parametrize("body", ['{"fetched_at": ', "not json", "5", ""])
def test_snapshot_age_days_never_raises_on_malformed_meta(tmp_path, monkeypatch, body):
    p = tmp_path / "snapshot.meta.json"
    p.write_text(body)
    monkeypatch.setattr(rules, "SNAPSHOT_META_PATH", p)
    # inf is what `aegis status` already renders as "stale, refresh it".
    assert rules.snapshot_age_days() == float("inf")


def test_snapshot_age_days_never_raises_on_bad_timestamp(tmp_path, monkeypatch):
    p = tmp_path / "snapshot.meta.json"
    p.write_text(json.dumps({"fetched_at": "not-a-timestamp"}))
    monkeypatch.setattr(rules, "SNAPSHOT_META_PATH", p)
    assert rules.snapshot_age_days() == float("inf")


def test_snapshot_age_days_never_raises_when_key_absent(tmp_path, monkeypatch):
    p = tmp_path / "snapshot.meta.json"
    p.write_text(json.dumps({"source": "x"}))
    monkeypatch.setattr(rules, "SNAPSHOT_META_PATH", p)
    assert rules.snapshot_age_days() == float("inf")


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


def test_project_layer_overrides_only_what_it_is_allowed_to(tmp_path, monkeypatch):
    """The project layer used to override global wholesale. It no longer can:
    it is a file inside the repo the agent has open, so it may only ratchet
    toward safer values. See test_project_trust.py for the full contract;
    this pins the layering shape."""
    g = tmp_path / "global.toml"
    g.write_text('[counters]\nconsecutive_deny_limit = 5\ntotal_deny_limit = 50\n\n'
                 '[context]\nlast_user_messages = 20\nclaude_md_max_tokens = 4000\n')
    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", g)
    proj = tmp_path / "proj"
    (proj / ".aegis").mkdir(parents=True)
    (proj / ".aegis" / "aegis.toml").write_text(
        '[counters]\nconsecutive_deny_limit = 10\n\n'
        '[context]\nlast_user_messages = 3\nclaude_md_max_tokens = 500\n'
    )
    cfg = rules.load_config(project_dir=str(proj))
    assert cfg.consecutive_deny_limit == 5   # counters are global-only
    assert cfg.total_deny_limit == 50        # inherited from global
    assert cfg.last_user_messages == 20      # ratchet: may only raise this
    assert cfg.claude_md_max_tokens == 500   # ratchet: may only lower this


def test_default_config_is_the_safe_end_of_every_setting():
    """load_config falls back to this whenever a layer cannot be merged, so
    it has to stand on its own as a safe configuration."""
    cfg = rules.default_config()
    assert cfg.classifier_chain
    assert cfg.on_exhaustion == "ask"
    assert cfg.ask_mode == "prompt"
    assert cfg.defer_scope == "classifier"


def test_read_toml_never_raises(tmp_path):
    """Undecodable bytes used to raise UnicodeDecodeError straight out of
    Path.read_text, past the old (TOMLDecodeError, OSError) guard."""
    undecodable = tmp_path / "undecodable.toml"
    undecodable.write_bytes(b"\xff\xfe\x00 not utf-8")
    assert rules._read_toml(undecodable) == {}
    assert rules._read_toml(tmp_path / "does-not-exist.toml") == {}
    assert rules._read_toml(tmp_path) == {}            # a directory, not a file


def test_malformed_chain_entries_are_dropped_not_fatal(tmp_path, monkeypatch):
    """`chain = [ 1, 2 ]` used to raise TypeError and a chain entry without a
    provider raised KeyError. A typo costs the operator its providers, never
    the hook its exit code."""
    g = tmp_path / "aegis.toml"
    g.write_text('[classifier]\nchain = [\n'
                 '  1,\n'
                 '  { model = "no-provider-key" },\n'
                 '  { provider = "gemini", model = "m", retries = "x" },\n'
                 ']\n')
    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", g)
    chain = rules.load_config(project_dir=None).classifier_chain
    assert [(p.provider, p.model) for p in chain] == [("gemini", "m")]
    assert chain[0].retries == 1     # wrong-typed retries falls back too


def test_chain_of_only_bad_entries_keeps_the_default(tmp_path, monkeypatch):
    """An empty result must not erase the built-in chain: no providers means
    every call exhausts, and on_exhaustion is not always "ask"."""
    g = tmp_path / "aegis.toml"
    g.write_text('[classifier]\nchain = [ 1, 2 ]\n')
    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", g)
    assert rules.load_config(project_dir=None).classifier_chain


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


def test_hard_deny_action_defaults_to_prompt(tmp_path, monkeypatch):
    monkeypatch.delenv("AEGIS_HARD_DENY_ACTION", raising=False)
    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", tmp_path / "missing.toml")
    assert rules.load_config(project_dir=None).hard_deny_action == "prompt"


def test_hard_deny_action_block_from_config(tmp_path, monkeypatch):
    monkeypatch.delenv("AEGIS_HARD_DENY_ACTION", raising=False)
    g = tmp_path / "aegis.toml"
    g.write_text('[behavior]\nhard_deny_action = "block"\n')
    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", g)
    assert rules.load_config(project_dir=None).hard_deny_action == "block"


def test_hard_deny_action_invalid_value_ignored(tmp_path, monkeypatch):
    monkeypatch.delenv("AEGIS_HARD_DENY_ACTION", raising=False)
    g = tmp_path / "aegis.toml"
    g.write_text('[behavior]\nhard_deny_action = "nuke"\n')
    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", g)
    assert rules.load_config(project_dir=None).hard_deny_action == "prompt"


def test_defer_scope_defaults_to_classifier(tmp_path, monkeypatch):
    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", tmp_path / "missing.toml")
    assert rules.load_config(project_dir=None).defer_scope == "classifier"


def test_defer_scope_from_config(tmp_path, monkeypatch):
    cfgfile = tmp_path / "aegis.toml"
    cfgfile.write_text('[behavior]\nask_mode = "defer"\ndefer_scope = "all"\n')
    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", cfgfile)
    cfg = rules.load_config(project_dir=None)
    assert cfg.ask_mode == "defer"
    assert cfg.defer_scope == "all"


def test_defer_scope_invalid_value_falls_back_to_default(tmp_path, monkeypatch):
    cfgfile = tmp_path / "aegis.toml"
    cfgfile.write_text('[behavior]\ndefer_scope = "sometimes"\n')
    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", cfgfile)
    assert rules.load_config(project_dir=None).defer_scope == "classifier"


def test_defer_scope_env_overrides_config(tmp_path, monkeypatch):
    cfgfile = tmp_path / "aegis.toml"
    cfgfile.write_text('[behavior]\ndefer_scope = "all"\n')
    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", cfgfile)
    monkeypatch.setenv("AEGIS_DEFER_SCOPE", "classifier")
    assert rules.load_config(project_dir=None).defer_scope == "classifier"


def test_project_config_overrides_global_defer_scope(tmp_path, monkeypatch):
    glob = tmp_path / "global.toml"
    glob.write_text('[behavior]\ndefer_scope = "all"\n')
    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", glob)
    proj = tmp_path / "proj"
    (proj / ".aegis").mkdir(parents=True)
    (proj / ".aegis" / "aegis.toml").write_text('[behavior]\ndefer_scope = "classifier"\n')
    assert rules.load_config(str(proj)).defer_scope == "classifier"


def test_log_and_state_housekeeping_defaults(tmp_path, monkeypatch):
    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", tmp_path / "missing.toml")
    cfg = rules.load_config(project_dir=None)
    assert cfg.diag_max_bytes == 32 * 1024 * 1024
    assert cfg.session_ttl_days == 14


def test_log_and_state_housekeeping_from_config(tmp_path, monkeypatch):
    cfgfile = tmp_path / "aegis.toml"
    cfgfile.write_text(
        '[logging]\nmax_bytes = 4096\n\n[state]\nsession_ttl_days = 3\n')
    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", cfgfile)
    cfg = rules.load_config(project_dir=None)
    assert cfg.diag_max_bytes == 4096
    assert cfg.session_ttl_days == 3
