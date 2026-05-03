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
