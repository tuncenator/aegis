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

ask() {
  local reason="$1"
  local out="${ASK/\%REASON\%/$reason}"
  echo "$out"
  exit 0
}

# Edit and Write name the target `file_path`; NotebookEdit names it
# `notebook_path`. Prefer the schema's real key, while retaining file_path as
# a compatibility fallback for older NotebookEdit payloads.
if [ "$TOOL" = "NotebookEdit" ]; then
  PATH_RAW=$(echo "$INPUT" | jq -r '.tool_input.notebook_path // empty' 2>/dev/null)
  if [ -z "$PATH_RAW" ]; then
    PATH_RAW=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
  fi
else
  PATH_RAW=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
fi
[ -z "$PATH_RAW" ] && exit 0

# Normalize the payload cwd independently of the hook process cwd. Besides
# relative targets, this is needed to interpret /proc/self/cwd as the writer
# process will see it.
CWD_RAW=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD_RAW" ] && CWD_RAW="$PWD"
case "$CWD_RAW" in
  \~)   CWD_EXPANDED="$HOME" ;;
  \~/*) CWD_EXPANDED="$HOME/${CWD_RAW:2}" ;;
  /*)   CWD_EXPANDED="$CWD_RAW" ;;
  *)    CWD_EXPANDED="$PWD/$CWD_RAW" ;;
esac

# Expand HOME, then make relative targets absolute from the cwd carried by the
# hook payload. The hook process can have a different cwd from the tool call.
case "$PATH_RAW" in
  \~)   PATH_EXPANDED="$HOME" ;;
  \~/*) PATH_EXPANDED="$HOME/${PATH_RAW:2}" ;;
  *)    PATH_EXPANDED="$PATH_RAW" ;;
esac
case "$PATH_EXPANDED" in
  /proc/self/cwd|/proc/thread-self/cwd)
    PATH_ABSOLUTE="$CWD_EXPANDED"
    ;;
  /proc/self/cwd/*)
    PATH_ABSOLUTE="$CWD_EXPANDED/${PATH_EXPANDED#/proc/self/cwd/}"
    ;;
  /proc/thread-self/cwd/*)
    PATH_ABSOLUTE="$CWD_EXPANDED/${PATH_EXPANDED#/proc/thread-self/cwd/}"
    ;;
  /*) PATH_ABSOLUTE="$PATH_EXPANDED" ;;
  *)  PATH_ABSOLUTE="$CWD_EXPANDED/$PATH_EXPANDED" ;;
esac

# Keep a lexical candidate and a physical one. The first preserves protection
# for a path spelled inside a protected tree even if a symlink points out. The
# second follows every existing symlink prefix, including a dangling final
# alias, so an alternate name that points into a protected tree also asks.
# -m permits a write target or any suffix after the alias not to exist yet.
if ! PATH_LEXICAL=$(realpath -ms -- "$PATH_ABSOLUTE" 2>/dev/null); then
  ask "cannot normalize write target"
fi
if ! PATH_RESOLVED=$(realpath -m -- "$PATH_ABSOLUTE" 2>/dev/null); then
  ask "cannot resolve write target"
fi

# Resolve the install itself once so plugin and command symlinks cannot make
# the protected root depend on how this hook was invoked.
AEGIS_ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
if ! GLOBAL_AEGIS_ROOT=$(realpath -m -- "$HOME/.config/aegis" 2>/dev/null); then
  ask "cannot resolve global Aegis config"
fi
if ! PROJECT_AEGIS_ROOT=$(realpath -m -- "$CWD_EXPANDED/.aegis" 2>/dev/null); then
  ask "cannot resolve project Aegis config"
fi

check_path() {
  local path="$1"

  # Anthropic protected directories.
  case "$path" in
    */.git/*|*/.git)              ask "writes to .git" ;;
    */.vscode/*|*/.vscode)        ask "writes to .vscode" ;;
    */.idea/*|*/.idea)            ask "writes to .idea" ;;
    */.husky/*|*/.husky)          ask "writes to .husky" ;;
  esac

  # .claude special: allow commands, agents, skills and worktrees.
  case "$path" in
    */.claude/commands/*|*/.claude/agents/*|*/.claude/skills/*|*/.claude/worktrees/*) : ;;
    */.claude/*|*/.claude) ask "writes to .claude (outside commands/agents/skills/worktrees)" ;;
  esac

  # Anthropic protected files (exact match on basename for dotfiles in HOME).
  case "$path" in
    "$HOME/.gitconfig"|"$HOME/.gitmodules"|"$HOME/.bashrc"|"$HOME/.bash_profile"|"$HOME/.zshrc"|"$HOME/.zprofile"|"$HOME/.profile"|"$HOME/.ripgreprc"|"$HOME/.mcp.json"|"$HOME/.claude.json")
      ask "writes to protected dotfile"
      ;;
  esac

  # System paths.
  case "$path" in
    /etc/*|/etc) ask "writes inside /etc" ;;
    /usr/bin/*|/usr/sbin/*|/bin/*|/sbin/*) ask "writes inside system binaries" ;;
    /var/log/*) ask "writes inside /var/log" ;;
  esac

  # Aegis's own configuration and install tree: self-modification of the
  # guard. Project config can only ratchet stricter, but global config and the
  # install tree have no such limit.
  case "$path" in
    */.aegis/*|*/.aegis) ask "writes to project Aegis config" ;;
    "$HOME/.config/aegis"|"$HOME/.config/aegis"/*) ask "writes to global Aegis config" ;;
    "$GLOBAL_AEGIS_ROOT"|"$GLOBAL_AEGIS_ROOT"/*) ask "writes to resolved global Aegis config" ;;
    "$PROJECT_AEGIS_ROOT"|"$PROJECT_AEGIS_ROOT"/*) ask "writes to resolved project Aegis config" ;;
    "$AEGIS_ROOT"|"$AEGIS_ROOT"/*) ask "writes into the Aegis install tree" ;;
  esac

  # SSH directory.
  case "$path" in
    "$HOME/.ssh"|"$HOME/.ssh"/*|/root/.ssh|/root/.ssh/*) ask "writes inside SSH directory" ;;
  esac
}

check_path "$PATH_LEXICAL"
if [ "$PATH_RESOLVED" != "$PATH_LEXICAL" ]; then
  check_path "$PATH_RESOLVED"
fi

exit 0
