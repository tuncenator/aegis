from pathlib import Path

from classifier import transcript

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"


def test_parse_minimal_takes_user_messages():
    parsed = transcript.parse(str(FIXTURES / "transcript.minimal.jsonl"), last_user_n=10)
    assert parsed.user_messages == ["hello", "run ls"]


def test_parse_minimal_takes_tool_uses():
    parsed = transcript.parse(str(FIXTURES / "transcript.minimal.jsonl"), last_user_n=10)
    assert any(t.name == "Bash" and t.input["command"] == "ls" for t in parsed.tool_uses)


def test_parse_strips_tool_results():
    parsed = transcript.parse(str(FIXTURES / "transcript.with_results.jsonl"), last_user_n=10)
    # tool_result entries must not appear as user messages or anywhere
    assert "On branch main" not in " ".join(parsed.user_messages)
    assert all("tool_result" not in str(t.input).lower() for t in parsed.tool_uses)


def test_parse_respects_last_user_n():
    # transcript.with_results.jsonl has 2 user messages (the tool_result one is excluded)
    parsed = transcript.parse(str(FIXTURES / "transcript.with_results.jsonl"), last_user_n=1)
    assert parsed.user_messages == ["now push"]


def test_parse_missing_file_returns_empty():
    parsed = transcript.parse("/nonexistent/path.jsonl", last_user_n=10)
    assert parsed.user_messages == []
    assert parsed.tool_uses == []


def test_parse_malformed_lines_are_skipped():
    p = FIXTURES / "test.bad.jsonl"
    p.write_text('not json\n{"type":"user","message":{"content":"ok"}}\nalso bad\n')
    try:
        parsed = transcript.parse(str(p), last_user_n=10)
        assert parsed.user_messages == ["ok"]
    finally:
        p.unlink()
