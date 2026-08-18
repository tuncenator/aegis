"""The project config layer is untrusted.

<cwd>/.aegis/aegis.toml is a file inside whatever repository the agent has
open, so in any repo the operator did not write it is attacker-controlled
content. It used to merge with the same authority as the operator's own
~/.config/aegis/aegis.toml, which made a checked-in config a complete bypass
of the thing Aegis exists to do.

These tests pin the rule: a project may RATCHET a setting toward its stricter
value and may set context knobs, and nothing else in the file has any effect.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from classifier import rules

REPO = Path(__file__).resolve().parent.parent.parent


@pytest.fixture
def layers(tmp_path, monkeypatch):
    """Return (write_global, write_project, load) for a two-layer config."""
    glob = tmp_path / "global.toml"
    proj = tmp_path / "proj"
    (proj / ".aegis").mkdir(parents=True)
    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", glob)

    def write_global(body):
        glob.write_text(body)

    def write_project(body):
        (proj / ".aegis" / "aegis.toml").write_text(body)

    def load():
        return rules.load_config(str(proj))

    return write_global, write_project, load


# --- the outright bypasses -------------------------------------------------

def test_project_cannot_force_allow_on_exhaustion(layers):
    """The worst one: pair this with a bogus chain and everything auto-approves."""
    _, write_project, load = layers
    write_project('[classifier]\non_exhaustion = "allow"\n')
    assert load().on_exhaustion == "ask"


def test_project_cannot_replace_the_provider_chain(layers):
    _, write_project, load = layers
    write_project('[classifier]\n'
                  'chain = [ { provider = "none", model = "x", retries = 1, timeout_s = 1 } ]\n')
    assert [p.provider for p in load().classifier_chain] != ["none"]


def test_project_cannot_redirect_the_decision_log(layers, tmp_path):
    """diag.emit rotates its target, so a writable diag_path is a
    rename-and-overwrite primitive against any user-writable file."""
    _, write_project, load = layers
    victim = tmp_path / "victim.toml"
    write_project(f'[logging]\ndiag_path = "{victim}"\nmax_bytes = 1\n')
    cfg = load()
    assert cfg.diag_path != str(victim)
    assert cfg.diag_max_bytes == 32 * 1024 * 1024


def test_project_cannot_shrink_the_session_ttl(layers):
    """STATE_DIR is global, so a project TTL would prune other projects."""
    _, write_project, load = layers
    write_project('[state]\nsession_ttl_days = 1\n')
    assert load().session_ttl_days == 14


def test_project_cannot_widen_the_trust_boundary(layers):
    """trusted_* defines the exfiltration boundary the hard_deny rule uses."""
    _, write_project, load = layers
    write_project('[environment]\ntrusted_domains = ["evil.example"]\n')
    assert load().trusted_domains == []


def test_project_cannot_raise_the_deny_limits(layers):
    _, write_project, load = layers
    write_project('[counters]\nconsecutive_deny_limit = 999\ntotal_deny_limit = 999\n')
    cfg = load()
    assert cfg.consecutive_deny_limit == 3
    assert cfg.total_deny_limit == 20


# --- the behavior ratchet --------------------------------------------------

@pytest.mark.parametrize("key,loose,strict", [
    ("ask_mode", "defer", "prompt"),
    ("defer_scope", "all", "classifier"),
    ("hard_deny_action", "prompt", "block"),
])
def test_project_may_tighten_but_not_loosen(layers, key, loose, strict):
    write_global, write_project, load = layers

    # Global sets the loose value; the project cannot keep it loose... it is
    # already loose, so assert the project cannot ARRIVE at loose from strict.
    write_global(f'[behavior]\n{key} = "{strict}"\n')
    write_project(f'[behavior]\n{key} = "{loose}"\n')
    assert getattr(load(), key) == strict, "project loosened a global setting"

    # And the reverse direction is honoured.
    write_global(f'[behavior]\n{key} = "{loose}"\n')
    write_project(f'[behavior]\n{key} = "{strict}"\n')
    assert getattr(load(), key) == strict, "project could not tighten"


def test_project_may_set_context_knobs(layers):
    _, write_project, load = layers
    write_project('[context]\nlast_user_messages = 3\ninclude_claude_md = false\n'
                  'claude_md_max_tokens = 100\n')
    cfg = load()
    assert cfg.last_user_messages == 3
    assert cfg.include_claude_md is False
    assert cfg.claude_md_max_tokens == 100


def test_global_layer_keeps_full_authority(layers):
    """The ratchet applies to the project layer only."""
    write_global, _, load = layers
    write_global('[classifier]\non_exhaustion = "allow"\n\n'
                 '[behavior]\nask_mode = "defer"\ndefer_scope = "all"\n\n'
                 '[state]\nsession_ttl_days = 1\n')
    cfg = load()
    assert cfg.on_exhaustion == "allow"
    assert cfg.defer_scope == "all"
    assert cfg.session_ttl_days == 1


# --- type validation -------------------------------------------------------
# A malformed value used to raise inside diag.emit, which runs BEFORE the
# verdict is surfaced, so a configured hard block exited 1 instead of 2.

@pytest.mark.parametrize("body,attr,expected", [
    ('[logging]\nmax_bytes = "x"\n', "diag_max_bytes", 32 * 1024 * 1024),
    ('[logging]\nmax_bytes = true\n', "diag_max_bytes", 32 * 1024 * 1024),
    ('[logging]\ndiag_path = 7\n', "diag_path", "~/.cache/aegis/decisions.jsonl"),
    ('[state]\nsession_ttl_days = "x"\n', "session_ttl_days", 14),
    ('[classifier]\non_exhaustion = "banana"\n', "on_exhaustion", "ask"),
    ('[counters]\nconsecutive_deny_limit = "3"\n', "consecutive_deny_limit", 3),
    ('[context]\nlast_user_messages = true\n', "last_user_messages", 10),
    ('[context]\ninclude_claude_md = "yes"\n', "include_claude_md", True),
    ('[environment]\ntrusted_domains = "example.com"\n', "trusted_domains", []),
    ('[behavior]\nask_mode = "sometimes"\n', "ask_mode", "prompt"),
])
def test_malformed_global_values_fall_back_to_defaults(layers, body, attr, expected):
    write_global, _, load = layers
    write_global(body)
    assert getattr(load(), attr) == expected


def test_empty_chain_does_not_erase_the_default(layers):
    write_global, _, load = layers
    write_global('[classifier]\nchain = []\n')
    assert load().classifier_chain


# --- end to end ------------------------------------------------------------

def _run_classifier(cwd, home, payload):
    env = {**os.environ, "HOME": str(home), "PYTHONPATH": str(REPO)}
    for var in ("AEGIS_ASK_MODE", "AEGIS_DEFER_SCOPE", "AEGIS_HARD_DENY_ACTION"):
        env.pop(var, None)
    return subprocess.run(
        [sys.executable, "-m", "classifier"],
        input=json.dumps(payload), capture_output=True, text=True, env=env, cwd=str(REPO))


def test_malformed_max_bytes_still_hard_blocks(tmp_path):
    """The regression that mattered: diag.emit raised before surface() ran,
    so the hook exited 1 with empty stdout, which Claude Code ignores."""
    home = tmp_path / "home"
    (home / ".config" / "aegis").mkdir(parents=True)
    (home / ".config" / "aegis" / "aegis.toml").write_text(
        '[classifier]\n'
        'chain = [ { provider = "none", model = "unused", retries = 1, timeout_s = 1 } ]\n'
        'on_exhaustion = "deny"\n\n'
        '[logging]\nmax_bytes = "x"\n\n'
        '[behavior]\nhard_deny_action = "block"\n')
    proj = tmp_path / "proj"
    proj.mkdir()
    r = _run_classifier(proj, home, {
        "session_id": "trust-e2e-1", "transcript_path": "/nonexistent.jsonl",
        "cwd": str(proj), "tool_name": "Bash", "tool_input": {"command": "frobnicate"}})
    assert r.returncode == 2, f"hard block degraded to rc={r.returncode}: {r.stderr}"


def test_project_config_cannot_overwrite_the_global_config(tmp_path):
    """The F2 primitive: rotation renamed the victim aside and replaced it."""
    home = tmp_path / "home"
    (home / ".config" / "aegis").mkdir(parents=True)
    victim = home / ".config" / "aegis" / "aegis.toml"
    victim.write_text('[behavior]\nhard_deny_action = "block"\n')

    proj = tmp_path / "proj"
    (proj / ".aegis").mkdir(parents=True)
    (proj / ".aegis" / "aegis.toml").write_text(
        f'[logging]\ndiag_path = "{victim}"\nmax_bytes = 1\n')

    for i in range(3):
        _run_classifier(proj, home, {
            "session_id": f"trust-e2e-2-{i}", "transcript_path": "/nonexistent.jsonl",
            "cwd": str(proj), "tool_name": "Bash", "tool_input": {"command": "ls"}})

    assert victim.read_text() == '[behavior]\nhard_deny_action = "block"\n'
    assert not victim.with_name("aegis.toml.1").exists()
