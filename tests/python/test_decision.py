import json
import pytest

from classifier import decision


def test_parse_valid_allow():
    d = decision.parse_response('{"decision": "allow", "reason": "ok"}')
    assert d.decision == "allow"
    assert d.reason == "ok"


def test_parse_valid_deny():
    d = decision.parse_response('{"decision": "deny", "reason": "force push"}')
    assert d.decision == "deny"


def test_parse_valid_ask():
    d = decision.parse_response('{"decision": "ask", "reason": "looks risky"}')
    assert d.decision == "ask"


def test_parse_with_surrounding_whitespace():
    d = decision.parse_response('  {"decision": "allow", "reason": "x"}\n')
    assert d.decision == "allow"


def test_parse_invalid_json_raises():
    with pytest.raises(decision.DecisionError):
        decision.parse_response("{ this is not json")


def test_parse_invalid_decision_value_raises():
    with pytest.raises(decision.DecisionError):
        decision.parse_response('{"decision": "maybe", "reason": "x"}')


def test_parse_with_codefence_extracts_json():
    d = decision.parse_response('```json\n{"decision":"allow","reason":"x"}\n```')
    assert d.decision == "allow"


def test_to_hook_output_allow():
    d = decision.Decision(decision="allow", reason="x")
    out = decision.to_hook_output(d)
    parsed = json.loads(out)
    assert parsed["hookSpecificOutput"]["permissionDecision"] == "allow"


def test_to_hook_output_deny_includes_reason():
    d = decision.Decision(decision="deny", reason="force push")
    out = decision.to_hook_output(d)
    parsed = json.loads(out)
    assert parsed["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert parsed["hookSpecificOutput"]["permissionDecisionReason"] == "force push"
