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


def test_to_hook_output_classifier_deny_downgraded_to_ask():
    """Classifier-emitted DENY surfaces as ASK so the user has an override
    path. The reason still rides in permissionDecisionReason. Hard-deny
    still happens via the deterministic bash-denylist layer (rc=2 exit
    in the orchestrator), which never reaches this code path."""
    d = decision.Decision(decision="deny", reason="force push")
    out = decision.to_hook_output(d)
    parsed = json.loads(out)
    assert parsed["hookSpecificOutput"]["permissionDecision"] == "ask"
    assert parsed["hookSpecificOutput"]["permissionDecisionReason"] == "force push"


def test_to_hook_output_ask_includes_reason():
    """ASK now also surfaces a reason (was previously omitted) so the
    user prompt explains why."""
    d = decision.Decision(decision="ask", reason="looks risky")
    out = decision.to_hook_output(d)
    parsed = json.loads(out)
    assert parsed["hookSpecificOutput"]["permissionDecision"] == "ask"
    assert parsed["hookSpecificOutput"]["permissionDecisionReason"] == "looks risky"


def test_to_hook_output_deny_with_empty_reason_omits_reason():
    d = decision.Decision(decision="deny", reason="")
    out = decision.to_hook_output(d)
    parsed = json.loads(out)
    # Downgraded to ask (per classifier-deny policy); empty reason omitted.
    assert parsed["hookSpecificOutput"]["permissionDecision"] == "ask"
    assert "permissionDecisionReason" not in parsed["hookSpecificOutput"]


def test_to_hook_output_ask_deferred_is_empty():
    """ask_mode="defer": an ASK surfaces as nothing at all. Empty stdout
    with exit 0 is the only hook result that falls through to Claude
    Code's own permission pipeline instead of short-circuiting it."""
    d = decision.Decision(decision="ask", reason="looks risky")
    assert decision.to_hook_output(d, "defer") == ""


def test_to_hook_output_allow_unaffected_by_defer():
    d = decision.Decision(decision="allow", reason="x")
    parsed = json.loads(decision.to_hook_output(d, "defer"))
    assert parsed["hookSpecificOutput"]["permissionDecision"] == "allow"


def test_to_hook_output_prompt_mode_is_the_default():
    d = decision.Decision(decision="ask", reason="r")
    assert decision.to_hook_output(d) == decision.to_hook_output(d, "prompt")


def test_to_hook_output_deny_is_never_deferred():
    """The snapshot's hard_deny section (Data Exfiltration) reaches this
    code as a deny. Deferring it would hand an exfiltration call to the
    native classifier instead of to the operator, so a deny always
    surfaces even in defer mode."""
    d = decision.Decision(decision="deny", reason="Data Exfiltration: creds to pastebin")
    out = decision.to_hook_output(d, "defer")
    assert out != ""
    parsed = json.loads(out)
    assert parsed["hookSpecificOutput"]["permissionDecision"] == "ask"
    assert parsed["hookSpecificOutput"]["permissionDecisionReason"] == \
        "Data Exfiltration: creds to pastebin"


def test_surface_deny_prompts_by_default():
    d = decision.Decision(decision="deny", reason="Data Exfiltration: creds to pastebin")
    out, rc = decision.surface(d, ask_mode="defer", hard_deny_action="prompt")
    assert rc == 0
    assert json.loads(out)["hookSpecificOutput"]["permissionDecision"] == "ask"


def test_surface_deny_blocks_when_configured():
    d = decision.Decision(decision="deny", reason="Data Exfiltration: creds to pastebin")
    out, rc = decision.surface(d, ask_mode="defer", hard_deny_action="block")
    assert rc == 2
    assert out == ""  # stdout is ignored for rc=2; the reason goes to stderr


def test_surface_ask_still_defers():
    d = decision.Decision(decision="ask", reason="unclear")
    assert decision.surface(d, "defer", "block") == ("", 0)


def test_surface_allow_unaffected_by_block():
    d = decision.Decision(decision="allow", reason="ok")
    out, rc = decision.surface(d, "defer", "block")
    assert rc == 0
    assert json.loads(out)["hookSpecificOutput"]["permissionDecision"] == "allow"
