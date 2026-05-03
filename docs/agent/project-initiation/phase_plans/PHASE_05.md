# Phase 5: Classifier transcript + prompt + decision

**Feature**: project-initiation
**Estimated Context Budget**: ~75k tokens

**Difficulty**: medium
**Visual**: no
**Functional**: no

**Execution Mode**: parallel
**Batch**: 5

---

## Objective

Implement the three internal classifier modules that build the LLM-side of the slow path:

1. `classifier/transcript.py` -- a JSONL parser that reads a Claude Code transcript and produces a structured `ParsedTranscript` (user messages + assistant `tool_use` blocks). It MUST strip `tool_result` entries: hostile content read from files via prior tool results must not flow into the classifier prompt.
2. `classifier/prompt.py` -- builders for the classifier system prompt (static within session) and the per-call user prompt.
3. `classifier/decision.py` -- parser for the model's text output (handles bare JSON, fenced JSON, and prose-prefixed JSON) plus a formatter that converts `Decision` to Claude Code hook output JSON.

This phase is internal-only (no user-facing surface lights up here). Phase 7 wires these modules together in `classifier/__main__.py`. The 19 unit tests in this phase verify behavior end-to-end at the module boundary.

---

## Deliverables

1. **`classifier/transcript.py`** -- exports `ToolUse`, `ParsedTranscript` dataclasses and `parse(transcript_path: str, last_user_n: int) -> ParsedTranscript`. Strips `tool_result` blocks from user messages. Handles missing files (returns empty `ParsedTranscript`). Skips malformed JSONL lines.
2. **`classifier/prompt.py`** -- exports `SYSTEM_TEMPLATE` (str), `build_system_prompt(snap: Snapshot, cfg: Config) -> str`, `_approx_token_cap(text, max_tokens) -> str`, `build_user_prompt(parsed: ParsedTranscript, pending: dict, claude_md: str | None, cfg: Config) -> str`. Imports `Snapshot` and `Config` from Phase 4's `classifier.rules`.
3. **`classifier/decision.py`** -- exports `VALID` set, `DecisionError` exception, `Decision` dataclass, `_FENCE_RE` regex, `parse_response(text: str) -> Decision`, `to_hook_output(d: Decision) -> str`.
4. **`tests/python/test_transcript.py`** -- 6 tests covering happy path, tool_result stripping, `last_user_n` cap, missing file, malformed lines.
5. **`tests/python/test_prompt.py`** -- 4 tests covering system prompt content, user prompt content, optional CLAUDE.md inclusion, CLAUDE.md cap.
6. **`tests/python/test_decision.py`** -- 9 tests covering valid allow/deny/ask, surrounding whitespace, invalid JSON, invalid decision value, code fence extraction, and hook output formatting.
7. **`tests/fixtures/transcript.minimal.jsonl`** -- 4-entry fixture (no `tool_result` blocks).
8. **`tests/fixtures/transcript.with_results.jsonl`** -- 5-entry fixture including a `tool_result` block (must be stripped by parser).

---

## Detailed Requirements

### Implementation order

The natural dependency order is **transcript -> prompt -> decision**:

- `transcript.py` is independent of any other Phase 5 module.
- `prompt.py` imports `Snapshot` and `Config` from `classifier.rules` (Phase 4) AND imports `ParsedTranscript`, `ToolUse` from `classifier.transcript` (this phase). So `transcript.py` must exist before `prompt.py`.
- `decision.py` is independent of every other module (only imports stdlib).

Use **per-module red-green-commit cadence**:

1. Create the two transcript fixtures.
2. Write `tests/python/test_transcript.py`. Run -> expect ImportError (red).
3. Implement `classifier/transcript.py`. Run -> expect 6 passed (green). Commit.
4. Write `tests/python/test_prompt.py`. Run -> expect ImportError (red).
5. Implement `classifier/prompt.py`. Run -> expect 4 passed (green). Commit.
6. Write `tests/python/test_decision.py`. Run -> expect ImportError (red).
7. Implement `classifier/decision.py`. Run -> expect 9 passed (green). Commit.
8. Final full-suite run: `uv run python -m pytest tests/python/ -v` -> all prior phases' tests still pass plus your 19.

This gives three commits. Do not batch the implementations together.

### Step 1: Create fixture transcripts

Create `tests/fixtures/` if it doesn't exist (Phase 4 tests don't use it, so this is your responsibility).

`tests/fixtures/transcript.minimal.jsonl` -- 4 lines, JSONL (one JSON object per line, no trailing newline-only blanks):

```jsonl
{"type":"user","message":{"content":"hello"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}
{"type":"user","message":{"content":"run ls"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}
```

`tests/fixtures/transcript.with_results.jsonl` -- 5 lines:

```jsonl
{"type":"user","message":{"content":"check stuff"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git status"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"On branch main\nnothing to commit"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"clean tree"}]}}
{"type":"user","message":{"content":"now push"}}
```

These fixtures are stable -- never overwritten by tests at runtime. The malformed-lines test uses a separate scratch file (`tests/fixtures/test.bad.jsonl`) that it creates and deletes within the test.

### Step 2: Write `tests/python/test_transcript.py`

Verbatim from plan Task 10 Step 2:

```python
from pathlib import Path

import pytest

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
```

Run: `uv run python -m pytest tests/python/test_transcript.py -v` -> expect ImportError.

### Step 3: Implement `classifier/transcript.py`

Verbatim from plan Task 10 Step 3:

```python
"""Transcript JSONL parser.

Reads Claude Code's conversation transcript and produces a structured view
suitable for the classifier prompt:
  - user messages (text only, last N)
  - assistant tool_use blocks (name + input, no results)

tool_result entries are stripped so hostile content read from files cannot
manipulate the classifier.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class ToolUse:
    name: str
    input: dict[str, Any]


@dataclass
class ParsedTranscript:
    user_messages: list[str] = field(default_factory=list)
    tool_uses: list[ToolUse] = field(default_factory=list)


def _user_text(content: Any) -> str | None:
    """Extract plain user text. Returns None for tool_result-only messages."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        # Mixed content: keep text parts; if only tool_result blocks, return None.
        texts = [c.get("text", "") for c in content
                 if isinstance(c, dict) and c.get("type") == "text"]
        if texts:
            return " ".join(texts)
        # If list has only tool_result blocks, this is not a true user message.
        if all(isinstance(c, dict) and c.get("type") == "tool_result" for c in content):
            return None
    return None


def parse(transcript_path: str, last_user_n: int) -> ParsedTranscript:
    p = Path(transcript_path)
    if not p.exists():
        return ParsedTranscript()
    user_msgs: list[str] = []
    tool_uses: list[ToolUse] = []
    try:
        with p.open() as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                etype = entry.get("type")
                msg = entry.get("message", {})
                content = msg.get("content")
                if etype in ("user", "human"):
                    text = _user_text(content)
                    if text:
                        user_msgs.append(text)
                elif etype == "assistant" and isinstance(content, list):
                    for c in content:
                        if isinstance(c, dict) and c.get("type") == "tool_use":
                            tool_uses.append(ToolUse(
                                name=c.get("name", ""),
                                input=c.get("input", {}),
                            ))
    except OSError:
        return ParsedTranscript()
    return ParsedTranscript(
        user_messages=user_msgs[-last_user_n:],
        tool_uses=tool_uses,
    )
```

Run: `uv run python -m pytest tests/python/test_transcript.py -v` -> expect 6 passed.

Commit: `git add classifier/transcript.py tests/python/test_transcript.py tests/fixtures/` then `git commit -m "Add transcript parser stripping tool_results"`.

### Step 4: Write `tests/python/test_prompt.py`

Verbatim from plan Task 11 Step 1:

```python
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
    assert "ALLOWED" in sp.upper()
    assert "DENIED" in sp.upper()
    assert "ASK" in sp.upper()


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


def test_user_prompt_caps_claude_md():
    parsed = ParsedTranscript()
    cfg = _cfg()
    cfg.claude_md_max_tokens = 5  # ~20 chars
    huge = "x" * 10000
    up = prompt.build_user_prompt(parsed, {"tool_name": "Read", "tool_input": {}},
                                   claude_md=huge, cfg=cfg)
    # Capped: shouldn't contain the full length
    assert len(up) < 1000
```

Note: the test relies on `Config` accepting kwargs `trusted_orgs`, `trusted_domains`, `trusted_services`, `last_user_messages`, `claude_md_max_tokens`, and on `Config.include_claude_md` defaulting to `True` (since the test for CLAUDE.md inclusion doesn't override it). It also relies on `Config.trusted_buckets` defaulting to an empty list (since `_cfg()` doesn't set it but `build_system_prompt` reads it). These defaults are Phase 4's responsibility -- if any are missing, raise the issue in your phase summary and STOP. Do not edit Phase 4 files.

Run: `uv run python -m pytest tests/python/test_prompt.py -v` -> expect ImportError.

### Step 5: Implement `classifier/prompt.py`

Verbatim from plan Task 11 Step 2:

```python
"""Classifier prompt assembly: system prompt (static within session) +
user prompt (per call)."""
from __future__ import annotations

import json
from typing import Any

from classifier.rules import Config, Snapshot
from classifier.transcript import ParsedTranscript

SYSTEM_TEMPLATE = """You are Aegis, a security classifier for an AI coding agent (Claude Code).
For each pending tool call, decide whether it should be ALLOWED, DENIED,
or sent for human review (ASK).

ALLOW rules (auto-approve when matched):
{allow_rules}

DENY rules (block when matched):
{deny_rules}

TRUSTED ENVIRONMENT (treat operations on these as in-scope, not external):
  Source control orgs:      {orgs}
  Trusted internal domains: {domains}
  Trusted cloud buckets:    {buckets}
  Key internal services:    {services}

USER BOUNDARIES: pay attention to user messages stating limits like
  "don't push", "wait for review", "no production yet". Treat them as
  DENY signals until the user lifts them in a later message.

OUTPUT: a single JSON object on one line, no preamble, no commentary:
  {{"decision": "allow" | "deny" | "ask", "reason": "<one sentence>"}}
"""


def build_system_prompt(snap: Snapshot, cfg: Config) -> str:
    return SYSTEM_TEMPLATE.format(
        allow_rules="\n".join(f"- {r}" for r in snap.allow),
        deny_rules="\n".join(f"- {r}" for r in snap.soft_deny),
        orgs=", ".join(cfg.trusted_orgs) or "(none)",
        domains=", ".join(cfg.trusted_domains) or "(none)",
        buckets=", ".join(cfg.trusted_buckets) or "(none)",
        services=", ".join(cfg.trusted_services) or "(none)",
    )


def _approx_token_cap(text: str, max_tokens: int) -> str:
    """Rough char-based cap: 1 token ~ 4 chars."""
    cap = max_tokens * 4
    if len(text) <= cap:
        return text
    return text[:cap] + "\n... [truncated]"


def build_user_prompt(
    parsed: ParsedTranscript,
    pending: dict[str, Any],
    claude_md: str | None,
    cfg: Config,
) -> str:
    parts = ["Recent user messages (newest last):"]
    for m in parsed.user_messages:
        parts.append(f"  user: {m}")

    parts.append("")
    parts.append("Recent assistant tool calls (tool_results stripped):")
    for t in parsed.tool_uses[-20:]:
        parts.append(f"  tool_use: {t.name} {json.dumps(t.input)}")

    if claude_md and cfg.include_claude_md:
        parts.append("")
        parts.append("CLAUDE.md (capped):")
        parts.append(_approx_token_cap(claude_md, cfg.claude_md_max_tokens))

    parts.append("")
    parts.append("PENDING ACTION:")
    parts.append(f"  tool: {pending.get('tool_name', '?')}")
    parts.append(f"  input: {json.dumps(pending.get('tool_input', {}))}")
    parts.append("")
    parts.append("Classify per the system prompt rules.")
    return "\n".join(parts)
```

Critical detail: `SYSTEM_TEMPLATE` uses Python `str.format`. The OUTPUT example line `{{"decision": ...}}` uses doubled braces so the formatter produces literal `{"decision": ...}` in the rendered string. Single braces in that line would be interpreted as a format placeholder and crash with `KeyError`.

Run: `uv run python -m pytest tests/python/test_prompt.py -v` -> expect 4 passed.

Commit: `git add classifier/prompt.py tests/python/test_prompt.py` then `git commit -m "Add classifier prompt builder"`.

### Step 6: Write `tests/python/test_decision.py`

Verbatim from plan Task 12 Step 1:

```python
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
```

Run: `uv run python -m pytest tests/python/test_decision.py -v` -> expect ImportError.

### Step 7: Implement `classifier/decision.py`

Verbatim from plan Task 12 Step 2:

```python
"""Parse classifier model output and format Claude Code hook responses."""
from __future__ import annotations

import json
import re
from dataclasses import dataclass

VALID = {"allow", "deny", "ask"}


class DecisionError(Exception):
    pass


@dataclass
class Decision:
    decision: str
    reason: str


_FENCE_RE = re.compile(r"```(?:json)?\s*(.*?)\s*```", re.DOTALL)


def parse_response(text: str) -> Decision:
    s = text.strip()
    if not s:
        raise DecisionError("empty response")
    # Strip code fence if present.
    m = _FENCE_RE.search(s)
    if m:
        s = m.group(1).strip()
    # Try to find a top-level JSON object if the model added prose.
    if not s.startswith("{"):
        brace = s.find("{")
        if brace >= 0:
            s = s[brace:]
    try:
        obj = json.loads(s)
    except json.JSONDecodeError as e:
        raise DecisionError(f"invalid JSON: {e}") from e
    d = obj.get("decision")
    if d not in VALID:
        raise DecisionError(f"invalid decision value: {d!r}")
    return Decision(decision=d, reason=str(obj.get("reason", "")))


def to_hook_output(d: Decision) -> str:
    payload = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": d.decision,
        }
    }
    if d.decision == "deny" and d.reason:
        payload["hookSpecificOutput"]["permissionDecisionReason"] = d.reason
    return json.dumps(payload)
```

Critical detail (per design spec lines 244-255 and the brief): `to_hook_output` adds `permissionDecisionReason` ONLY when `d.decision == "deny"` AND `d.reason` is non-empty. Allow and ask never carry `permissionDecisionReason` here. The bash hard-ask layer carries its own reason because it inserts the field directly into the JSON template; the classifier's own ask path does not.

Run: `uv run python -m pytest tests/python/test_decision.py -v` -> expect 9 passed.

Commit: `git add classifier/decision.py tests/python/test_decision.py` then `git commit -m "Add classifier decision parser and hook output formatter"`.

### Step 8: Final verification

Run the full Python suite to confirm no Phase 4 tests broke:

```bash
uv run python -m pytest tests/python/ -v
```

Expected: all Phase 4 tests pass + your 19 new tests pass (6 transcript + 4 prompt + 9 decision). Total Python tests at this point should be Phase 4 count + 19.

Bash tests should still pass too. Spot-check:

```bash
tests/bash/run.sh
AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh
```

Both should pass unchanged -- this phase touched no bash files.

---

## Edge Cases to Handle Explicitly

### `transcript.parse`

- **Missing file**: `Path(transcript_path).exists()` is False -> return `ParsedTranscript()` (empty defaults). Test: `test_parse_missing_file_returns_empty`.
- **Empty path string** (Phase 7 may pass `""` if the PreToolUse JSON has no `transcript_path`): treat same as missing file. `Path("").exists()` returns False, so the code path is identical.
- **Malformed JSONL lines**: catch `json.JSONDecodeError` per line and `continue`. Test: `test_parse_malformed_lines_are_skipped`.
- **Empty lines** in the JSONL: stripped via `line = line.strip(); if not line: continue`. No test for this directly, but the malformed-lines test exercises that the parser doesn't blow up on bad inputs.
- **`OSError` reading the file** (permission denied, suddenly unreadable): wrap the `with p.open()` block in `try/except OSError` and return empty. No explicit test, but the wrapper protects against silent breakage in production.
- **`message.content` is a string** (older transcript shape): `_user_text` handles this case directly with `isinstance(content, str)`. Used by `transcript.minimal.jsonl` (the `"hello"` and `"run ls"` and `"check stuff"` and `"now push"` entries).
- **`message.content` is a list of mixed `text` and `tool_result` blocks**: `_user_text` keeps the text parts, joins with space, returns the joined string (so a user message that includes both text and a tool_result keeps the text). Test exercises this implicitly via the mixed `transcript.with_results.jsonl` shapes.
- **`message.content` is a list of `tool_result` blocks ONLY**: `_user_text` returns `None`, the message is dropped, security-critical. Test: `test_parse_strips_tool_results`.
- **`message.content` is something else entirely** (e.g. `None` or a dict): `_user_text` returns `None` via the fall-through `return None` at the bottom.
- **Assistant message with `content` not a list** (old shape): the `elif etype == "assistant" and isinstance(content, list)` guard skips it.
- **Assistant content blocks that aren't `tool_use`**: the inner `if isinstance(c, dict) and c.get("type") == "tool_use"` guard ignores them. Test: `test_parse_minimal_takes_tool_uses` -- the minimal fixture has both a `text` block and a `tool_use` block; only the `tool_use` lands.
- **`type` is `"human"` instead of `"user"`**: handled by `etype in ("user", "human")` -- both shapes accepted.
- **`last_user_n` cap**: `user_msgs[-last_user_n:]` slice. If `last_user_n=0`, returns empty; if `last_user_n` exceeds count, returns all. Test: `test_parse_respects_last_user_n` (n=1 keeps only the last).

### `prompt.build_system_prompt`

- **Empty `trusted_orgs`/`trusted_domains`/`trusted_buckets`/`trusted_services`**: `", ".join([]) or "(none)"` -> renders `(none)`.
- **Empty `snap.allow`/`snap.soft_deny`**: `"\n".join(f"- {r}" for r in [])` -> renders empty string. The system prompt section header still appears but the bulleted list is empty. This is acceptable -- in production the snapshot will always have rules.
- **Format placeholder mismatch**: if the template has a placeholder that `format()` doesn't supply, you get `KeyError`. The doubled-brace OUTPUT line is the only escape-hatch -- DO NOT add literal `{}` elsewhere without doubling them.

### `prompt.build_user_prompt`

- **Empty `parsed.user_messages`**: the "Recent user messages" header still prints but no `user: ...` lines follow.
- **Empty `parsed.tool_uses`**: same -- header prints, no `tool_use: ...` lines.
- **`tool_uses` longer than 20**: capped via `parsed.tool_uses[-20:]`. No explicit test, but the slice protects against runaway transcripts.
- **`claude_md=None`**: skip the CLAUDE.md block entirely.
- **`claude_md=""` (empty string)**: `if claude_md` is False -> skip the block. Acceptable.
- **`cfg.include_claude_md=False`**: skip the block even if `claude_md` is non-empty.
- **`cfg.claude_md_max_tokens` is small** (e.g. 5 -> ~20 chars): `_approx_token_cap` truncates at `5*4 = 20` chars and appends `"\n... [truncated]"`. Test: `test_user_prompt_caps_claude_md` (passes 10000 chars with cap=5, asserts total prompt < 1000 chars).
- **`pending` missing `tool_name` or `tool_input`**: `pending.get("tool_name", "?")` and `pending.get("tool_input", {})` provide safe defaults.
- **`pending.tool_input` non-serializable** (shouldn't happen in practice): `json.dumps(pending.get('tool_input', {}))` will raise `TypeError`. Acceptable -- this is a programmer error from the orchestrator; let it crash loudly.

### `decision.parse_response`

- **Empty string** or whitespace-only: `s = text.strip(); if not s: raise DecisionError("empty response")`.
- **Bare JSON**: starts with `{`, parses directly. Tests: `test_parse_valid_allow`, `test_parse_valid_deny`, `test_parse_valid_ask`.
- **JSON with leading/trailing whitespace**: stripped by `text.strip()`. Test: `test_parse_with_surrounding_whitespace`.
- **Code-fenced JSON**: `_FENCE_RE` matches both ` ```json ... ``` ` and ` ``` ... ``` `. Test: `test_parse_with_codefence_extracts_json`.
- **Prose-prefixed JSON**: `if not s.startswith("{"):` finds the first `{` and slices. No explicit positive test, but covered by the implementation.
- **Invalid JSON syntax**: `json.JSONDecodeError` -> `raise DecisionError(...) from e`. Test: `test_parse_invalid_json_raises`.
- **Valid JSON but `decision` field is not in `VALID`**: `raise DecisionError(f"invalid decision value: {d!r}")`. Test: `test_parse_invalid_decision_value_raises`.
- **Missing `reason` field**: `obj.get("reason", "")` defaults to empty string. Acceptable per design (allow/ask don't carry reason through to_hook_output anyway).
- **Missing `decision` field**: `obj.get("decision")` is `None`, `None not in VALID` -> raises `DecisionError`.
- **`decision` field is non-string** (e.g. int): `d not in VALID` is True -> raises `DecisionError`.

### `decision.to_hook_output`

- **Allow**: payload contains `permissionDecision: "allow"`, no `permissionDecisionReason`. Test: `test_to_hook_output_allow`.
- **Deny with reason**: payload contains `permissionDecisionReason: "<reason>"`. Test: `test_to_hook_output_deny_includes_reason`.
- **Deny with empty reason**: condition `d.decision == "deny" and d.reason` is False (empty reason is falsy) -> no `permissionDecisionReason`. No explicit test; acceptable behavior per the brief (empty reason gives no field rather than an empty-string field).
- **Ask**: payload contains `permissionDecision: "ask"`, no `permissionDecisionReason`. No explicit test for this branch, but the implementation matches the brief: classifier's ask doesn't carry reason; the bash hard-ask layer emits its own reason inline.

---

## Integration Points

### Imports from Phase 4 (`classifier.rules`)

`classifier/prompt.py` imports `Config` and `Snapshot` from `classifier.rules`. Phase 4 owns those dataclasses; this phase consumes them. The `_cfg()` helper in `test_prompt.py` constructs a `Config` with kwargs `trusted_orgs`, `trusted_domains`, `trusted_services`, `last_user_messages`, `claude_md_max_tokens`. Phase 4's `Config` MUST accept these kwargs. The `_cfg()` helper does not pass `trusted_buckets` or `include_claude_md`; therefore Phase 4's `Config` MUST default `trusted_buckets=[]` and `include_claude_md=True`. If Phase 4 didn't ship those defaults, your tests fail at construction time. Stop and report in your phase summary -- do not modify Phase 4 code.

### Imports within Phase 5

- `classifier/prompt.py` imports `ParsedTranscript`, `ToolUse` from `classifier.transcript`. Build `transcript.py` first.
- `classifier/decision.py` is independent of `transcript.py` and `prompt.py`. Build it last in this phase, but its order relative to the others doesn't matter for correctness.

### Consumed by Phase 7 (`classifier/__main__.py`)

Phase 7 wires these three modules together. Your modules must expose exactly the symbols listed in Codebase Context's "Important APIs & Interfaces" section:

- `transcript.parse(transcript_path: str, last_user_n: int) -> ParsedTranscript`
- `transcript.ToolUse`, `transcript.ParsedTranscript`
- `prompt.build_system_prompt(snap: Snapshot, cfg: Config) -> str`
- `prompt.build_user_prompt(parsed: ParsedTranscript, pending: dict, claude_md: str | None, cfg: Config) -> str`
- `decision.Decision`, `decision.DecisionError`
- `decision.parse_response(text: str) -> Decision`
- `decision.to_hook_output(d: Decision) -> str`

Match these signatures EXACTLY. Phase 7's coder will fail if the names or signatures drift.

### File ownership

Phase 5 owns these files, and ONLY these files:

- `classifier/transcript.py`
- `classifier/prompt.py`
- `classifier/decision.py`
- `tests/python/test_transcript.py`
- `tests/python/test_prompt.py`
- `tests/python/test_decision.py`
- `tests/fixtures/transcript.minimal.jsonl`
- `tests/fixtures/transcript.with_results.jsonl`

Do NOT touch:

- `classifier/__init__.py`, `classifier/__main__.py` (Phase 3 placeholder; Phase 7 replaces)
- `classifier/state.py`, `classifier/rules.py` (Phase 4)
- `classifier/log.py` (Phase 1)
- `classifier/providers/*` (Phase 6 -- runs in parallel with you in batch 5; both work in separate worktrees so no filesystem conflict)
- Any `lib/*.sh`, `orchestrator.sh`, bash tests, plugin manifest, pyproject.toml

---

## Dependencies

**Requires**:
- Phase 1: `classifier/__init__.py` (package marker), `pyproject.toml` (so `uv run python -m pytest` works), `classifier/log.py` (not directly imported by your modules but the package must remain importable).
- Phase 3: `tests/python/conftest.py` -- pytest config that adds the project root to `sys.path` so `from classifier import transcript` resolves.
- Phase 4: `classifier/rules.py` exposing `Config` and `Snapshot` dataclasses with the kwargs and defaults described in Integration Points.

**Enables**:
- Phase 7: `classifier/__main__.py` chain orchestration imports your `parse`, `build_system_prompt`, `build_user_prompt`, `parse_response`, `to_hook_output`, and the `Decision` / `DecisionError` symbols.

---

## Completion Criteria

- [ ] `tests/fixtures/transcript.minimal.jsonl` exists with 4 entries matching the brief.
- [ ] `tests/fixtures/transcript.with_results.jsonl` exists with 5 entries matching the brief.
- [ ] `classifier/transcript.py` implements `ToolUse`, `ParsedTranscript`, `_user_text`, `parse` per the verbatim source above.
- [ ] `tests/python/test_transcript.py` contains all 6 tests from Task 10 Step 2.
- [ ] `uv run python -m pytest tests/python/test_transcript.py -v` -> 6 passed.
- [ ] `classifier/prompt.py` implements `SYSTEM_TEMPLATE`, `build_system_prompt`, `_approx_token_cap`, `build_user_prompt` per the verbatim source above. Doubled braces in `SYSTEM_TEMPLATE` for the `{"decision": ...}` line.
- [ ] `tests/python/test_prompt.py` contains all 4 tests from Task 11 Step 1.
- [ ] `uv run python -m pytest tests/python/test_prompt.py -v` -> 4 passed.
- [ ] `classifier/decision.py` implements `VALID`, `DecisionError`, `Decision`, `_FENCE_RE`, `parse_response`, `to_hook_output` per the verbatim source above. `to_hook_output` adds `permissionDecisionReason` ONLY for deny + non-empty reason.
- [ ] `tests/python/test_decision.py` contains all 9 tests from Task 12 Step 1.
- [ ] `uv run python -m pytest tests/python/test_decision.py -v` -> 9 passed.
- [ ] Three commits made (one per module + tests + applicable fixtures), with messages exactly matching the plan tasks ("Add transcript parser stripping tool_results", "Add classifier prompt builder", "Add classifier decision parser and hook output formatter").
- [ ] Final full-suite run `uv run python -m pytest tests/python/ -v` shows all Phase 4 tests still passing plus your 19 new tests passing.
- [ ] Final spot-check: `tests/bash/run.sh && AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh` still both pass (you didn't break anything in bash territory).
- [ ] No edits to files outside the ownership list.

---

## Testing Requirements

### Test commands (in order)

Per-module while iterating:

```bash
uv run python -m pytest tests/python/test_transcript.py -v
uv run python -m pytest tests/python/test_prompt.py -v
uv run python -m pytest tests/python/test_decision.py -v
```

Full Python suite at end of phase:

```bash
uv run python -m pytest tests/python/ -v
```

Bash sanity check at end of phase (should be unchanged from Phase 4):

```bash
tests/bash/run.sh
AEGIS_TEST_MOCK_DECISION=ask tests/bash/orchestrator-cases.sh
```

### What the 19 tests cover

Transcript (6):
1. `test_parse_minimal_takes_user_messages` -- happy-path user-message extraction.
2. `test_parse_minimal_takes_tool_uses` -- happy-path tool_use extraction.
3. `test_parse_strips_tool_results` -- security: hostile tool_result content does not appear in the output.
4. `test_parse_respects_last_user_n` -- the cap at the parser layer works.
5. `test_parse_missing_file_returns_empty` -- missing-file fallback.
6. `test_parse_malformed_lines_are_skipped` -- robustness against bad JSONL.

Prompt (4):
1. `test_system_prompt_includes_rules_and_env` -- system template renders rules + trusted env.
2. `test_user_prompt_includes_context_and_pending` -- user prompt has user msgs, tool_uses, pending action.
3. `test_user_prompt_includes_claude_md_when_configured` -- CLAUDE.md inclusion.
4. `test_user_prompt_caps_claude_md` -- CLAUDE.md cap.

Decision (9):
1. `test_parse_valid_allow` -- happy path allow.
2. `test_parse_valid_deny` -- happy path deny.
3. `test_parse_valid_ask` -- happy path ask.
4. `test_parse_with_surrounding_whitespace` -- strip whitespace.
5. `test_parse_invalid_json_raises` -- DecisionError on bad JSON.
6. `test_parse_invalid_decision_value_raises` -- DecisionError on `"maybe"`.
7. `test_parse_with_codefence_extracts_json` -- handles ` ```json ... ``` ` wrapper.
8. `test_to_hook_output_allow` -- formatter for allow.
9. `test_to_hook_output_deny_includes_reason` -- formatter for deny.

### Anti-patterns to avoid

From `FUNCTIONAL_QA_STRATEGY.md`, these apply even though this phase is `Functional: no`:

- **AP3**: Do not write to real `~/.cache/aegis/` or `~/.config/aegis/`. None of these tests touch state, but if you decide to add ad-hoc smoke scripts, redirect via `tmp_path` or env vars.
- **AP6**: The 4 prompt tests use a synthetic 2-rule snapshot. Don't replace this with a 3-line synthetic and call it a day -- the fixture is intentionally minimal but the tests assert the right substring presence. Phase 4 ships a real `rules/snapshot.json` and Phase 7's classifier consumes it; the prompt builder's behavior is unit-tested at the synthetic level here, and integration-tested at Phase 7+9.

---

## External Interfaces Consumed

- **Claude Code transcript JSONL format**
  - **Consumed by**: `classifier/transcript.py::parse` and `_user_text`. The fixtures `tests/fixtures/transcript.minimal.jsonl` and `tests/fixtures/transcript.with_results.jsonl` encode the assumed shape.
  - **How to capture**: real Claude Code transcripts live at `~/.claude/projects/<encoded-project-path>/<session-id>.jsonl`. Run:
    ```bash
    ls -1t ~/.claude/projects/ | head -1 | xargs -I{} ls -1t ~/.claude/projects/{}/ | head -1 | xargs -I{} ls -1t ~/.claude/projects/$(ls -1t ~/.claude/projects/ | head -1)/{} 2>/dev/null
    head -10 "$(ls -1t ~/.claude/projects/$(ls -1t ~/.claude/projects/ | head -1)/*.jsonl 2>/dev/null | head -1)"
    ```
    or simpler:
    ```bash
    find ~/.claude/projects -name '*.jsonl' -printf '%T@ %p\n' | sort -n | tail -1 | awk '{print $2}' | xargs head -10
    ```
    Look for: top-level `type` field (`"user"` | `"assistant"` | possibly others to ignore), `message.content` either a string OR a list of `{type: "text"|"tool_use"|"tool_result", ...}` blocks.
  - **If not observable**: the bundled fixtures encode the documented shape. Use them as the authoritative spec for this phase. The first time real transcripts diverge from this shape will be Phase 9 smoke -- if they do, file a follow-up phase for `transcript.py` adjustments.
  - **What to paste into your phase summary**: the first 5-10 lines of one real transcript (sanitized -- no secrets) under "Evidence Captured", confirming `type`, `message`, `content`, and content-block `type` fields match the parser's assumptions.

- **Classifier model output text shape** -- contract: `{"decision": "allow|deny|ask", "reason": "<sentence>"}` on one line, possibly wrapped in code fences or prefixed with prose.
  - **Consumed by**: `classifier/decision.py::parse_response`. The 9 tests cover bare JSON, fenced JSON, prose-prefix, whitespace, invalid JSON, invalid decision value.
  - **How to capture**: Phase 5 only handles parsing, not invocation. The contract is documented in design spec lines 234-256 and the system prompt enforces it. Observation deferred to Phase 9 smoke.
  - **If not observable**: contract documented; observation deferred to Phase 9 smoke. No action required in this phase.
  - **What to paste into your phase summary**: a one-line note "Classifier output contract documented in design spec; real-model observation deferred to Phase 9 smoke. Parser tested against synthetic shapes covering bare/fenced/prose-prefix variants."

---

## Notes

- **Stdlib only**. The project allows `loguru` per Phase 1's choice, but your three modules need only `json`, `re`, `dataclasses`, `pathlib`, `typing` -- all stdlib.
- **`from __future__ import annotations`**. All three modules use this for clean `str | None` style annotations under Python 3.11. Required.
- **Doubled braces in `SYSTEM_TEMPLATE`**. The line `{{"decision": "allow" | "deny" | "ask", "reason": "<one sentence>"}}` produces literal `{"decision": ...}` in the rendered string. Single braces would crash with `KeyError("decision")` because Python's `str.format` would try to look up a `decision` placeholder.
- **`to_hook_output` does NOT carry reason for ask**. Per design spec lines 244-255 and the brief, only deny carries `permissionDecisionReason` through the classifier's formatter. The bash hard-ask layer emits its own ask + reason JSON inline (Phase 2's territory). When the classifier returns ask, it's a "needs human input" signal -- Claude Code prompts the user using its default messaging.
- **Security property is the strip**. `transcript.parse` MUST strip `tool_result` entries. The test `test_parse_strips_tool_results` is the gate. If a clever refactor removes `_user_text`'s `all(... type == "tool_result")` check, hostile content from prior tool reads can leak into the classifier prompt and manipulate the decision. Don't change that branch without rerunning the security test.
- **Parallel batch 5**. Phase 6 runs at the same time as you, in a separate worktree. Both phases run pytest. There is no filesystem contention because each worktree is a clone. There is no shared external service. No mitigation needed beyond the worktree isolation that the conductor sets up.
- **Three commits**. One per module + applicable tests + fixtures. Match the commit messages exactly:
  - `Add transcript parser stripping tool_results`
  - `Add classifier prompt builder`
  - `Add classifier decision parser and hook output formatter`
- **Phase summary**. After completing all three modules and all 19 tests pass, write your summary to `docs/agent/project-initiation/summaries/PHASE_05_SUMMARY.md` per the project conventions. Include: the captured real-transcript sample (sanitized) under "Evidence Captured", the `pytest -v` final output, the three commit hashes.
