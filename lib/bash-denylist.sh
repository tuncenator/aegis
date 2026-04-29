#!/bin/bash
# PreToolUse hook for Bash: HARD-BLOCK truly nuclear commands.
# Runs alongside bash-gatekeeper.sh. Uses exit 2 (documented blocking error)
# so it overrides any "allow" from the gatekeeper. Intentionally narrow --
# only patterns that have no legitimate use inside Claude Code.

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$CMD" ] && exit 0

block() {
    echo "bash-denylist: $1" >&2
    exit 2
}

# --- Nuclear rm ---
# rm with -r AND -f (combined or separate) targeting /, ~, $HOME, or a
# top-level system dir. Doesn't try to catch every clever variant -- just
# the obvious ones that almost always mean a bug in command construction.
_rm=$(echo "$CMD" | grep -oE '\brm[[:space:]]+[^;|&`()]+' | head -1)
if [ -n "$_rm" ]; then
    _has_r=$(echo "$_rm" | grep -qE '(-[a-zA-Z]*[rR]|--recursive)' && echo y)
    _has_f=$(echo "$_rm" | grep -qE '(-[a-zA-Z]*f|--force)' && echo y)
    if [ "$_has_r" = y ] && [ "$_has_f" = y ]; then
        if echo "$_rm" | grep -qE '[[:space:]](/|/\*|~|~/\*?|\$HOME|\$\{HOME\}|/(etc|var|usr|home|bin|sbin|lib|lib32|lib64|opt|boot|root|srv|mnt|proc|sys|dev)(/\*?)?)([[:space:]]|$)'; then
            block "rm -rf targeting root-level path ($_rm)"
        fi
    fi
fi

# --- curl|wget piped to a shell ---
# Classic untrusted remote execution. No legitimate in-workflow use.
if echo "$CMD" | grep -qE '(curl|wget)[[:space:]][^|]*\|[[:space:]]*(sudo[[:space:]]+)?(sh|bash|zsh|ksh|dash)([[:space:]]|$)'; then
    block "curl/wget piped directly to a shell"
fi

# --- AI attribution scrub ---
# Belt-and-suspenders over the `attribution.commit/pr` setting. Rejects any
# git commit / git tag -m / gh pr|issue create|edit that contains Claude
# co-authorship trailers, the "Generated with Claude Code" tagline, or the
# noreply@anthropic.com email. Scans the whole command string so heredoc
# bodies ("git commit -F -" / "gh pr create --body-file -" patterns) are
# covered too. --body-file <real-path> can't be scanned, not blocked here.
_lower=$(echo "$CMD" | tr '[:upper:]' '[:lower:]')
if echo "$_lower" | grep -qE '(^|[[:space:];|&()`])(git[[:space:]]+(commit|tag|merge)|gh[[:space:]]+(pr|issue)[[:space:]]+(create|edit|comment))'; then
    if echo "$_lower" | grep -qE '(co-authored-by[[:space:]]*:[^\n]*claude|generated[[:space:]]+with[[:space:]]+\[?claude[[:space:]]+code|noreply@anthropic\.com|🤖[[:space:]]*generated[[:space:]]+with)'; then
        block "AI attribution string in commit/PR message (Co-Authored-By / Generated with Claude Code / anthropic.com)"
    fi
fi

exit 0
