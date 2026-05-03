#!/usr/bin/env bash
# PreToolUse: deterministic ASK for Bash commands that always need human review.
# Reads project-level .aegis/hard-ask.toml from cwd and adds those patterns
# to the built-in set.
#
# Output: empty (silent fall-through) if no pattern matches; permissionDecision:ask JSON if matched.

set -u

ASK='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%REASON%"}}'

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
[ "$TOOL" = "Bash" ] || exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$CMD" ] && exit 0

CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

ask() {
  local reason="$1"
  echo "${ASK/\%REASON\%/$reason}"
  exit 0
}

# Force pushes (any flavor of --force, --force-with-lease, -f).
if echo "$CMD" | grep -qE '^[[:space:]]*git[[:space:]]+push[[:space:]].*((--force(-with-lease)?(=[^[:space:]]+)?)|(-[a-zA-Z]*f[a-zA-Z]*([[:space:]]|$)))'; then
  ask "git push with force flag"
fi

# Push to default branches (main, master) explicitly.
if echo "$CMD" | grep -qE '^[[:space:]]*git[[:space:]]+push([[:space:]]+(--[a-zA-Z][a-zA-Z0-9-]*([= ][^ ]+)?))*[[:space:]]+(origin[[:space:]]+)?(main|master)([[:space:]]|$)'; then
  ask "git push to default branch"
fi

# kubectl: exec, delete, apply
if echo "$CMD" | grep -qE '^[[:space:]]*kubectl[[:space:]]+(exec|delete|apply)([[:space:]]|$)'; then
  ask "kubectl mutation (exec/delete/apply)"
fi

# Infrastructure-as-code apply
if echo "$CMD" | grep -qE '^[[:space:]]*(terraform|tofu|pulumi)[[:space:]]+(apply|up)([[:space:]]|$)'; then
  ask "infrastructure-as-code apply"
fi

# Cloud mass deletes
if echo "$CMD" | grep -qE '^[[:space:]]*aws[[:space:]]+s3[[:space:]]+rm[[:space:]].*--recursive'; then
  ask "aws s3 recursive delete"
fi
if echo "$CMD" | grep -qE '^[[:space:]]*gsutil[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*rm[[:space:]].*-r'; then
  ask "gsutil recursive delete"
fi

# Production ssh (host name contains 'prod' or 'production' anywhere)
if echo "$CMD" | grep -qE '^[[:space:]]*ssh[[:space:]]+([a-zA-Z0-9._-]+@)?[a-zA-Z0-9._-]*(prod|production)[a-zA-Z0-9._-]*([[:space:]]|$)'; then
  ask "ssh to production-named host"
fi

# curl/wget piped directly to a shell.
# Classic untrusted remote execution; user gets the override path.
if echo "$CMD" | grep -qE '(curl|wget)[[:space:]][^|]*\|[[:space:]]*(sudo[[:space:]]+)?(sh|bash|zsh|ksh|dash)([[:space:]]|$)'; then
  ask "curl/wget piped directly to a shell"
fi

# AI attribution scrub on git commit / git tag / git merge / gh pr|issue
# create|edit|comment commands. Catches Claude co-authorship trailers,
# the "Generated with Claude Code" tagline, and noreply@anthropic.com.
# Scans the whole command string so heredoc and -F - bodies are covered.
_lower=$(echo "$CMD" | tr '[:upper:]' '[:lower:]')
if echo "$_lower" | grep -qE '(^|[[:space:];|&()`])(git[[:space:]]+(commit|tag|merge)|gh[[:space:]]+(pr|issue)[[:space:]]+(create|edit|comment))'; then
  if echo "$_lower" | grep -qE '(co-authored-by[[:space:]]*:[^\n]*claude|generated[[:space:]]+with[[:space:]]+\[?claude[[:space:]]+code|noreply@anthropic\.com|🤖[[:space:]]*generated[[:space:]]+with)'; then
    ask "AI attribution string in commit/PR message"
  fi
fi

# Project-level patterns from .aegis/hard-ask.toml
if [ -n "$CWD" ] && [ -f "$CWD/.aegis/hard-ask.toml" ]; then
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    if echo "$CMD" | grep -qE "$pat"; then
      ask "matches project hard-ask pattern"
    fi
  done < <(grep -E "^[[:space:]]*'" "$CWD/.aegis/hard-ask.toml" 2>/dev/null | sed -E "s/^[[:space:]]*'([^']*)'.*/\1/")
fi

exit 0
