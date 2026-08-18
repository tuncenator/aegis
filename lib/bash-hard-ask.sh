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

# Writes to Aegis's own configuration or code -- self-modification of the
# guard. lib/bash-gatekeeper.sh matches on the executable name and does not
# inspect redirections, so it hands an unconditional ALLOW to things like
#
#   printf '%s\n' '[behavior]' 'defer_scope = "all"' > .aegis/aegis.toml
#
# which would switch off every deterministic tripwire (including this file)
# without the classifier ever seeing the policy change. The gatekeeper runs
# AFTER this layer, so catching it here is what makes it stick.
#
# Covered: the project config dir, the global config dir, and the Aegis
# install tree itself. Reads are untouched; only redirects and mutating
# commands match.
AEGIS_ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
_aegis_targets='(\.aegis(/|$)|\.config/aegis(/|$)'"$(printf '|%s' "$(echo "$AEGIS_ROOT" | sed 's/[.[\*^$()+?{|]/\\&/g')")"')'

# 1. Any redirect whose target is one of those paths. The operator forms all
# count: `>`, `>>`, `>|` (noclobber override), and fd-prefixed `2>` / `&>`.
# The target may be quoted. Missing `>|` here meant the plain-`>` case was
# caught while the noclobber form walked straight through.
if echo "$CMD" | grep -qE '[0-9&]*>>?\|?[[:space:]]*["'"'"']?[^|;&[:space:]"'"'"']*'"$_aegis_targets"; then
  ask "redirects into Aegis configuration or install tree"
fi
# 2. Mutating commands naming one of those paths.
if echo "$CMD" | grep -qE '(^|[[:space:];|&()`])(tee|cp|mv|rm|ln|install|truncate|touch|chmod|chown|shred)([[:space:]]+-[^[:space:]]+)*[[:space:]]+[^|;&]*'"$_aegis_targets"; then
  ask "mutating command targets Aegis configuration or install tree"
fi
# 3. In-place editors and dd.
if echo "$CMD" | grep -qE '(^|[[:space:];|&()`])sed[[:space:]]+[^|;&]*-i[^|;&]*'"$_aegis_targets"; then
  ask "in-place edit of Aegis configuration or install tree"
fi
if echo "$CMD" | grep -qE '(^|[[:space:];|&()`])dd[[:space:]]+[^|;&]*of=[^[:space:]]*'"$_aegis_targets"; then
  ask "dd writes to Aegis configuration or install tree"
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
