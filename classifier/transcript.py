"""Transcript JSONL parser.

Reads Claude Code's conversation transcript and produces a structured view
suitable for the classifier prompt:
  - user messages (text only, last N)
  - assistant tool_use blocks (name + input, no results)
  - prior-approval tally: per (tool_name, coarse signature) count of tool_uses
    that the user approved earlier in the session. Each approved-and-succeeded
    tool_use is evidence the user wanted that pattern allowed; the classifier
    uses this to LEAN ALLOW on repeats it would otherwise have ASKed/DENYed.

tool_result entries are stripped from `tool_uses` (hostile content from files
must not reach the classifier prompt). For approval tallying we read only two
metadata bits off the tool_result: is_error flag and a small set of
denial-marker strings. Bodies are never propagated.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class ToolUse:
    name: str
    input: dict[str, Any]


@dataclass
class PriorApproval:
    """A (tool, signature) pair the user approved earlier in this session."""
    tool: str
    signature: str
    count: int


@dataclass
class ParsedTranscript:
    user_messages: list[str] = field(default_factory=list)
    tool_uses: list[ToolUse] = field(default_factory=list)
    prior_approvals: list[PriorApproval] = field(default_factory=list)


# Strings Claude Code injects into tool_result content when the user denies
# an ASK or a tool is otherwise rejected. Treated as failure even if is_error
# is missing.
_DENIAL_MARKERS = (
    "permission denied by user",
    "tool use denied",
    "user rejected",
    "request interrupted",
)


def _user_text(content: Any) -> str | None:
    """Extract plain user text. Returns None for tool_result-only messages."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        texts = [c.get("text", "") for c in content
                 if isinstance(c, dict) and c.get("type") == "text"]
        if texts:
            return " ".join(texts)
        if all(isinstance(c, dict) and c.get("type") == "tool_result" for c in content):
            return None
    return None


def _tool_result_blocks(content: Any) -> list[dict[str, Any]]:
    if not isinstance(content, list):
        return []
    return [c for c in content if isinstance(c, dict) and c.get("type") == "tool_result"]


def _result_failed(block: dict[str, Any]) -> bool:
    if block.get("is_error") is True:
        return True
    body = block.get("content")
    if isinstance(body, str):
        low = body.lower()
        return any(m in low for m in _DENIAL_MARKERS)
    if isinstance(body, list):
        for piece in body:
            if isinstance(piece, dict):
                text = piece.get("text") or ""
                if isinstance(text, str) and any(m in text.lower() for m in _DENIAL_MARKERS):
                    return True
    return False


def _signature(tool: str, tool_input: dict[str, Any]) -> str | None:
    """Coarse signature used to bucket repeating approvals.

    Goal: catch obvious repeats (browser_click anywhere, Bash 'git status'
    variations) without being so specific that minor input drift breaks the
    match. Returns None when we don't want to tally this tool family.
    """
    if not isinstance(tool_input, dict):
        tool_input = {}

    if tool.startswith("mcp__playwright__"):
        return "browser"

    if tool == "Bash":
        cmd = str(tool_input.get("command", "")).strip()
        if not cmd:
            return None
        first = re.split(r"[\s;|&]+", cmd, maxsplit=2)[:2]
        return " ".join(p for p in first if p) or None

    if tool in ("Edit", "Write", "NotebookEdit"):
        path = str(tool_input.get("file_path") or tool_input.get("notebook_path") or "")
        if not path:
            return None
        parent = path.rsplit("/", 1)[0] if "/" in path else ""
        ext = path.rsplit(".", 1)[1].lower() if "." in path.rsplit("/", 1)[-1] else ""
        return f"{parent}|{ext}" if (parent or ext) else None

    if tool.startswith("mcp__"):
        return "mcp"

    return tool or None


def parse(transcript_path: str, last_user_n: int) -> ParsedTranscript:
    p = Path(transcript_path)
    if not p.exists():
        return ParsedTranscript()
    user_msgs: list[str] = []
    tool_uses: list[ToolUse] = []
    pending_by_id: dict[str, ToolUse] = {}
    approved_counts: dict[tuple[str, str], int] = {}

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
                    for res in _tool_result_blocks(content):
                        tu_id = res.get("tool_use_id")
                        tu = pending_by_id.pop(tu_id, None) if tu_id else None
                        if tu is None or _result_failed(res):
                            continue
                        sig = _signature(tu.name, tu.input)
                        if sig is None:
                            continue
                        approved_counts[(tu.name, sig)] = approved_counts.get((tu.name, sig), 0) + 1
                elif etype == "assistant" and isinstance(content, list):
                    for c in content:
                        if isinstance(c, dict) and c.get("type") == "tool_use":
                            tu = ToolUse(name=c.get("name", ""), input=c.get("input", {}))
                            tool_uses.append(tu)
                            tu_id = c.get("id")
                            if tu_id:
                                pending_by_id[tu_id] = tu
    except OSError:
        return ParsedTranscript()

    prior = [PriorApproval(tool=t, signature=s, count=n)
             for (t, s), n in sorted(approved_counts.items(), key=lambda kv: -kv[1])]
    return ParsedTranscript(
        user_messages=user_msgs[-last_user_n:],
        tool_uses=tool_uses,
        prior_approvals=prior,
    )
