#!/usr/bin/env bash
# PreToolUse: deterministic ASK for non-Bash file-writing tools (Edit, Write,
# NotebookEdit) when the file_path matches Anthropic's protected paths or
# our internal additions.
#
# Output: empty (silent) if no match; permissionDecision:ask JSON if matched.

set -u

ASK='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%REASON%"}}'

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only file-writing tools.
case "$TOOL" in
  Edit|Write|NotebookEdit) ;;
  *) exit 0 ;;
esac

PATH_RAW=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$PATH_RAW" ] && exit 0

# Expand ~ for matching.
PATH_EXPANDED="${PATH_RAW/#\~/$HOME}"

ask() {
  local reason="$1"
  local out="${ASK/\%REASON\%/$reason}"
  echo "$out"
  exit 0
}

# Anthropic protected directories
case "$PATH_EXPANDED" in
  */.git/*|*/.git)              ask "writes to .git" ;;
  */.vscode/*|*/.vscode)        ask "writes to .vscode" ;;
  */.idea/*|*/.idea)            ask "writes to .idea" ;;
  */.husky/*|*/.husky)          ask "writes to .husky" ;;
esac

# .claude special: allow .claude/commands, .claude/agents, .claude/skills, .claude/worktrees
case "$PATH_EXPANDED" in
  */.claude/commands/*|*/.claude/agents/*|*/.claude/skills/*|*/.claude/worktrees/*) : ;;
  */.claude/*|*/.claude)        ask "writes to .claude (outside commands/agents/skills/worktrees)" ;;
esac

# Anthropic protected files (exact match on basename for dotfiles in HOME).
case "$PATH_EXPANDED" in
  "$HOME/.gitconfig"|"$HOME/.gitmodules"|"$HOME/.bashrc"|"$HOME/.bash_profile"|"$HOME/.zshrc"|"$HOME/.zprofile"|"$HOME/.profile"|"$HOME/.ripgreprc"|"$HOME/.mcp.json"|"$HOME/.claude.json")
    ask "writes to protected dotfile"
    ;;
esac

# System paths
case "$PATH_EXPANDED" in
  /etc/*|/etc)                  ask "writes inside /etc" ;;
  /usr/bin/*|/usr/sbin/*|/bin/*|/sbin/*) ask "writes inside system binaries" ;;
  /var/log/*)                   ask "writes inside /var/log" ;;
esac

# SSH directory
case "$PATH_EXPANDED" in
  "$HOME/.ssh"/*|/root/.ssh/*) ask "writes inside SSH directory" ;;
esac

exit 0
