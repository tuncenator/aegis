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

# Note: curl|shell and AI-attribution scrub patterns moved to bash-hard-ask
# (ASK with override). They are flag-worthy but not catastrophic; the user
# should always have an override path for non-irreversible actions. Only
# truly nuclear patterns (irreversible, no plausible legitimate use) remain
# here as hard-deny.

exit 0
