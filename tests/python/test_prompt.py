import pytest

from classifier import prompt
from classifier.rules import Config, Snapshot
from classifier.transcript import ParsedTranscript, ToolUse


def _cfg():
    return Config(
        trusted_orgs=["ONLAYER"],
        trusted_domains=["example.com"],
        trusted_services=["VICAR"],
        last_user_messages=10,
        claude_md_max_tokens=200,
    )


def _snap():
    return Snapshot(allow=["AllowRule1", "AllowRule2"],
                     soft_deny=["DenyRule1"], environment=[])


def test_system_prompt_includes_rules_and_env():
    sp = prompt.build_system_prompt(_snap(), _cfg())
    assert "AllowRule1" in sp
    assert "DenyRule1" in sp
    assert "ONLAYER" in sp
    assert "example.com" in sp
    assert "VICAR" in sp
    assert "ALLOW" in sp.upper()
    assert "DENY" in sp.upper()
    assert "ASK" in sp.upper()
    assert "SOFT DENY" in sp.upper()


def test_user_prompt_includes_context_and_pending():
    parsed = ParsedTranscript(
        user_messages=["help me with foo", "now do bar"],
        tool_uses=[ToolUse(name="Bash", input={"command": "ls"})],
    )
    pending = {"tool_name": "Edit", "tool_input": {"file_path": "/etc/x"}}
    up = prompt.build_user_prompt(parsed, pending, claude_md=None, cfg=_cfg())
    assert "help me with foo" in up
    assert "now do bar" in up
    assert "Bash" in up
    assert "command: ls" in up or '"command": "ls"' in up
    assert "Edit" in up
    assert "/etc/x" in up


def test_user_prompt_includes_claude_md_when_configured():
    parsed = ParsedTranscript()
    up = prompt.build_user_prompt(parsed, {"tool_name": "Read", "tool_input": {}},
                                   claude_md="never push to main", cfg=_cfg())
    assert "never push to main" in up


def test_user_prompt_includes_cwd_when_provided():
    parsed = ParsedTranscript()
    up = prompt.build_user_prompt(
        parsed,
        {"tool_name": "Bash", "tool_input": {"command": "./node_modules/.bin/tsc --noEmit"}},
        claude_md=None,
        cfg=_cfg(),
        cwd="/home/x/proj/frontend",
    )
    assert "/home/x/proj/frontend" in up
    assert "cwd:" in up
    assert "Relative paths" in up


def test_user_prompt_omits_cwd_when_absent():
    parsed = ParsedTranscript()
    up = prompt.build_user_prompt(
        parsed,
        {"tool_name": "Bash", "tool_input": {"command": "ls"}},
        claude_md=None,
        cfg=_cfg(),
    )
    assert "cwd:" not in up


def test_user_prompt_caps_claude_md():
    parsed = ParsedTranscript()
    cfg = _cfg()
    cfg.claude_md_max_tokens = 5  # ~20 chars
    huge = "x" * 10000
    up = prompt.build_user_prompt(parsed, {"tool_name": "Read", "tool_input": {}},
                                   claude_md=huge, cfg=cfg)
    # Capped: shouldn't contain the full length
    assert len(up) < 1000
