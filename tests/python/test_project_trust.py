"""The project config layer is untrusted.

<cwd>/.aegis/aegis.toml is a file inside whatever repository the agent has
open, so in any repo the operator did not write it is attacker-controlled
content. It used to merge with the same authority as the operator's own
~/.config/aegis/aegis.toml, which made a checked-in config a complete bypass
of the thing Aegis exists to do.

These tests pin the rule: a project may RATCHET a setting toward its stricter
value, and nothing else in the file has any effect. They also pin the other
half of the contract -- that a malformed project file is INERT rather than
fatal, because config loading runs before the verdict is surfaced and an
exception there exits the hook 1, which Claude Code ignores.
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
    """Return (write_global, write_project, load) for a two-layer config.

    Either writer takes str or bytes; the bytes form is how the undecodable
    -file cases below are expressed, since a config path an attacker controls
    need not hold UTF-8 at all.
    """
    glob = tmp_path / "global.toml"
    proj = tmp_path / "proj"
    (proj / ".aegis").mkdir(parents=True)
    monkeypatch.setattr(rules, "GLOBAL_CONFIG_PATH", glob)

    def _write(path, body):
        if isinstance(body, bytes):
            path.write_bytes(body)
        else:
            path.write_text(body)

    def write_global(body):
        _write(glob, body)

    def write_project(body):
        _write(proj / ".aegis" / "aegis.toml", body)

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


# --- the context ratchet ---------------------------------------------------
# [context] used to be settable outright, on the reasoning that context only
# ever helps the classifier. Two of its keys do the opposite in a project's
# hands, so they ratchet too: toward less repo-controlled text in the prompt
# and more of the user's own words.

def test_project_cannot_turn_on_claude_md_inclusion(layers):
    """The prompt-injection surface: a project turning this on feeds its own
    CLAUDE.md -- prose the repo controls -- into the prompt of the model that
    is deciding whether to allow the tool call."""
    write_global, write_project, load = layers
    write_global('[context]\ninclude_claude_md = false\n')
    write_project('[context]\ninclude_claude_md = true\n')
    assert load().include_claude_md is False


def test_project_may_turn_off_claude_md_inclusion(layers):
    """False is the safe end, so that direction is honoured."""
    write_global, write_project, load = layers
    write_global('[context]\ninclude_claude_md = true\n')
    write_project('[context]\ninclude_claude_md = false\n')
    assert load().include_claude_md is False


def test_project_cannot_starve_the_classifier_of_transcript(layers):
    """0 strips the messages where the user already said 'do not push'."""
    write_global, write_project, load = layers
    write_global('[context]\nlast_user_messages = 10\n')
    write_project('[context]\nlast_user_messages = 0\n')
    assert load().last_user_messages == 10


def test_project_may_ask_for_more_transcript(layers):
    write_global, write_project, load = layers
    write_global('[context]\nlast_user_messages = 10\n')
    write_project('[context]\nlast_user_messages = 25\n')
    assert load().last_user_messages == 25


def test_project_cannot_raise_the_claude_md_cap(layers):
    """The cap bounds how much repo-controlled text reaches the prompt, so a
    project may only tighten it."""
    write_global, write_project, load = layers
    write_global('[context]\nclaude_md_max_tokens = 4000\n')
    write_project('[context]\nclaude_md_max_tokens = 100000\n')
    assert load().claude_md_max_tokens == 4000


def test_project_may_lower_the_claude_md_cap(layers):
    write_global, write_project, load = layers
    write_global('[context]\nclaude_md_max_tokens = 4000\n')
    write_project('[context]\nclaude_md_max_tokens = 100\n')
    assert load().claude_md_max_tokens == 100


def test_project_may_set_the_snapshot_ttl(layers):
    """The one key still settable outright: `aegis status` prints a staleness
    flag from it and no decision reads it."""
    _, write_project, load = layers
    write_project('[rules]\nsnapshot_ttl_days = 3\n')
    assert load().snapshot_ttl_days == 3


def test_a_project_file_that_says_nothing_changes_nothing(layers):
    """The ratchets are evaluated on every load, against whatever the global
    layer left in place. A key the project never mentions must come out
    indistinguishable from one it set to the value already in force."""
    write_global, write_project, load = layers
    write_global('[context]\ninclude_claude_md = true\nlast_user_messages = 5\n'
                 'claude_md_max_tokens = 200\n')
    write_project('# this project has opinions about nothing\n')
    cfg = load()
    assert cfg.include_claude_md is True
    assert cfg.last_user_messages == 5
    assert cfg.claude_md_max_tokens == 200


def test_wrong_typed_project_context_values_do_not_clobber_global(layers):
    write_global, write_project, load = layers
    write_global('[context]\ninclude_claude_md = true\nlast_user_messages = 5\n')
    write_project('[context]\ninclude_claude_md = "yes"\nlast_user_messages = "many"\n')
    cfg = load()
    assert cfg.include_claude_md is True
    assert cfg.last_user_messages == 5


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


# --- a malformed config must be inert, never fatal -------------------------
# Type-checking values was only half the job: the SHAPE of a config could
# still raise. `context = 1` is legal TOML (a bare key, not a table), so
# raw.get("context") returned an int and the .get() on it raised
# AttributeError; a project file of arbitrary bytes raised UnicodeDecodeError
# out of Path.read_text. Both escaped load_config, which runs before the
# verdict is surfaced, so the hook exited 1 with empty stdout -- an ignored
# hook error, i.e. the whole gate silently disappearing.

MALFORMED = [
    pytest.param("context = 1\n", id="scalar-where-context-table-goes"),
    pytest.param("behavior = 1\n", id="scalar-where-behavior-table-goes"),
    pytest.param("rules = 1\n", id="scalar-where-rules-table-goes"),
    pytest.param("classifier = 1\n", id="scalar-where-classifier-table-goes"),
    pytest.param("logging = 1\ncounters = 1\nstate = 1\nenvironment = 1\n",
                 id="scalars-where-the-trusted-tables-go"),
    pytest.param("[classifier]\nchain = [ 1, 2 ]\n", id="chain-of-scalars"),
    pytest.param('[classifier]\nchain = [ { model = "m" } ]\n',
                 id="chain-entry-without-provider"),
    pytest.param("[behavior\n", id="truncated-table-header"),
    pytest.param(b"\xff\xfe[context]\n", id="undecodable-bytes"),
    pytest.param(b"\x00\x00\x00\x00", id="nul-bytes"),
]


@pytest.mark.parametrize("body", MALFORMED)
def test_malformed_project_config_is_ignored_not_fatal(layers, body):
    """An untrusted file is the one an attacker can shape deliberately, so a
    bad one must cost the project its ratchet and nothing else: the operator's
    own layer has to survive it intact."""
    write_global, write_project, load = layers
    write_global('[behavior]\nhard_deny_action = "block"\n\n'
                 '[counters]\nconsecutive_deny_limit = 7\n')
    write_project(body)
    cfg = load()  # must not raise
    assert cfg.hard_deny_action == "block", "global layer lost to a bad project file"
    assert cfg.consecutive_deny_limit == 7
    assert cfg.classifier_chain


@pytest.mark.parametrize("body", MALFORMED)
def test_malformed_global_config_degrades_to_defaults(layers, body):
    """Operator error rather than an attack, but it must still not raise."""
    write_global, _, load = layers
    write_global(body)
    cfg = load()  # must not raise
    assert cfg.classifier_chain
    assert cfg.on_exhaustion == "ask"
    assert cfg.ask_mode == "prompt"


def test_a_project_layer_that_explodes_is_dropped_whole(layers, monkeypatch):
    """Backstop for a merge bug rather than a config shape: a half-merged
    project layer is not allowed to exist, so the merge runs on a copy and
    only replaces the config once it has finished."""
    write_global, write_project, load = layers
    write_global('[behavior]\nhard_deny_action = "block"\n')
    write_project('[context]\nlast_user_messages = 25\n')
    real = rules._apply_layer

    def boom(cfg, raw, trusted):
        if not trusted:
            cfg.last_user_messages = 25   # half-merged, then dies
            raise RuntimeError("merge bug")
        return real(cfg, raw, trusted)

    monkeypatch.setattr(rules, "_apply_layer", boom)
    cfg = load()
    assert cfg.hard_deny_action == "block"
    assert cfg.last_user_messages == 10, "a half-merged project layer survived"


def test_a_global_layer_that_explodes_falls_back_to_defaults(layers, monkeypatch):
    """Merge order decides what a half-merged global config keeps, so the
    partial result is discarded: `on_exhaustion = "allow"` must not be able
    to outlive the hardening that was meant to follow it."""
    write_global, _, load = layers
    write_global('[classifier]\non_exhaustion = "allow"\n')

    def boom(cfg, raw, trusted):
        cfg.on_exhaustion = "allow"
        raise RuntimeError("merge bug")

    monkeypatch.setattr(rules, "_apply_layer", boom)
    assert load().on_exhaustion == "ask", "a half-merged global config survived"


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


def _blocking_home(tmp_path):
    """A global config whose chain always exhausts to a hard block, so any
    rc other than 2 from _run_classifier means the gate was lost."""
    home = tmp_path / "home"
    (home / ".config" / "aegis").mkdir(parents=True)
    (home / ".config" / "aegis" / "aegis.toml").write_text(
        '[classifier]\n'
        'chain = [ { provider = "none", model = "unused", retries = 1, timeout_s = 1 } ]\n'
        'on_exhaustion = "deny"\n\n'
        '[behavior]\nhard_deny_action = "block"\n')
    return home


@pytest.mark.parametrize("body", [
    pytest.param(None, id="baseline-no-project-config"),
    pytest.param("context = 1\n", id="scalar-where-context-table-goes"),
    pytest.param("behavior = 1\n", id="scalar-where-behavior-table-goes"),
    pytest.param(b"\xff\xfe[context]\n", id="undecodable-bytes"),
])
def test_malformed_project_config_still_hard_blocks(tmp_path, body):
    """The fail-open, end to end. rc=1 is a traceback Claude Code reads as an
    ignored hook error, so a repo could delete the operator's hard block by
    checking in three bytes of broken TOML."""
    home = _blocking_home(tmp_path)
    proj = tmp_path / "proj"
    (proj / ".aegis").mkdir(parents=True)
    if body is not None:
        p = proj / ".aegis" / "aegis.toml"
        p.write_bytes(body) if isinstance(body, bytes) else p.write_text(body)

    r = _run_classifier(proj, home, {
        "session_id": "trust-e2e-malformed", "transcript_path": "/nonexistent.jsonl",
        "cwd": str(proj), "tool_name": "Bash", "tool_input": {"command": "frobnicate"}})
    assert r.returncode == 2, f"hard block degraded to rc={r.returncode}: {r.stderr}"
    assert r.stdout == "", "rc=2 must carry no permission decision on stdout"


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


# --- the pre-verdict window ------------------------------------------------
# Everything main() touches before decision.surface() runs is a fail-open
# surface: an exception there exits the hook 1 with empty stdout, which Claude
# Code reads as an ignored hook error. The config file was hardened first; the
# files next door were not. All of these are checked into a repository.

def _hard_block_home(tmp_path):
    home = tmp_path / "home"
    (home / ".config" / "aegis").mkdir(parents=True)
    (home / ".config" / "aegis" / "aegis.toml").write_text(
        '[classifier]\n'
        'chain = [ { provider = "none", model = "unused", retries = 1, timeout_s = 1 } ]\n'
        'on_exhaustion = "deny"\n\n'
        '[behavior]\nhard_deny_action = "block"\n')
    return home


@pytest.mark.parametrize("body,label", [
    (b"# notes \xe7\xff\xfe\n", "invalid-utf8"),
    (b"\xff\xfe", "bom-only-garbage"),
    (b"\x00\x00\x00", "nul-bytes"),
    (b"", "empty"),
])
def test_undecodable_claude_md_still_hard_blocks(tmp_path, body, label):
    """One 0xE7 byte in a checked-in CLAUDE.md used to turn layer 4 off for the
    whole repo: Path.read_text raised UnicodeDecodeError, which is not an
    OSError, so it escaped main()."""
    home = _hard_block_home(tmp_path)
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "CLAUDE.md").write_bytes(body)
    r = _run_classifier(proj, home, {
        "session_id": f"claudemd-{label}", "transcript_path": "/nonexistent.jsonl",
        "cwd": str(proj), "tool_name": "Bash", "tool_input": {"command": "frobnicate"}})
    assert r.returncode == 2, f"{label}: rc={r.returncode} stderr={r.stderr[:400]}"


def test_undecodable_transcript_still_hard_blocks(tmp_path):
    home = _hard_block_home(tmp_path)
    proj = tmp_path / "proj"
    proj.mkdir()
    tr = proj / "transcript.jsonl"
    tr.write_bytes(b'{"type":"user","message":{"content":"hi \xe7\xff"}}\n')
    r = _run_classifier(proj, home, {
        "session_id": "transcript-badutf8", "transcript_path": str(tr),
        "cwd": str(proj), "tool_name": "Bash", "tool_input": {"command": "frobnicate"}})
    assert r.returncode == 2, f"rc={r.returncode} stderr={r.stderr[:400]}"


def test_claude_md_is_not_read_when_disabled(tmp_path):
    """include_claude_md = false is meant to keep repo-controlled prose out of
    the gate's prompt. It was checked downstream only, so the file was still
    read -- the setting kept the text out of the prompt but not the repo's
    bytes out of the process."""
    from classifier import __main__ as main_mod
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "CLAUDE.md").write_text("project instructions")
    assert main_mod._read_claude_md(str(proj), True) == "project instructions"
    assert main_mod._read_claude_md(str(proj), False) is None
