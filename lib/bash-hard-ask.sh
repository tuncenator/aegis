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
# install tree itself. Reads are untouched; only writes match.
#
# SHAPE: this allowlists the readers, not the writers. The first cut of this
# block enumerated mutators -- tee, cp, mv, rm, ln, install, truncate, touch,
# chmod, chown, shred, sed -i, dd -- and asked when one of them named a
# protected path. That enumeration cannot be finished. `curl -o`, `sort -o`,
# `git restore`, `python3 -c`, rsync, tar -C, perl -i, any wrapper script and
# any interpreter all write files, and every name missing from the list was a
# silent GATEKEEPER-ALLOW straight through the gate. The complement is the
# tractable set: commands that provably CANNOT write to a path handed to them
# are few, stable and auditable. So we enumerate those, and everything else
# that names a protected path asks. A false ASK costs the operator one
# keypress; a miss costs the whole gate, permanently and silently.
#
# The match is lexical on purpose. This layer cannot resolve where a path
# really points -- symlinks, $VARS, the working directory -- so a command that
# merely MENTIONS a protected path asks even when it would have touched
# something else. That over-match is the intended trade, and it is why this
# layer asks rather than denies.
AEGIS_ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
_aegis_root_re=${AEGIS_ROOT//\\/\\\\}
for _m in '.' '[' '*' '^' '$' '(' ')' '+' '?' '{' '|'; do
  _aegis_root_re=${_aegis_root_re//"$_m"/\\$_m}
done

# Both ends of every protected path are pinned to a path-component boundary.
# With no left boundary on `.aegis`, an unrelated /tmp/foo.aegis/x matched;
# with no right boundary on the install root, every sibling sharing its prefix
# (<root>-copy, <root>.bak) matched too. `-` and `.` count as word characters
# here precisely so that those two shapes stay out.
_aegis_lb='(^|[^A-Za-z0-9_.-])'
_aegis_rb='(/|[^A-Za-z0-9_.-]|$)'
_aegis_tail='(\.aegis|\.config/aegis|'"$_aegis_root_re"')'"$_aegis_rb"
_aegis_named="$_aegis_lb$_aegis_tail"

# 1. Redirects. Every bash form that opens a file for writing, enumerated
# whole instead of patched one case at a time:
#   >   >>   >|   N>   N>>   N>|   &>   &>>   >&
# `<`, `<<`, `<<<` and fd duplication (`N>&M`) open nothing for writing and
# are deliberately absent. `>&` was the form that fell through before: it is
# bash's synonym for `&>`, so `printf x >& target` wrote the file with nothing
# in this layer matching. The redirect target is the next word, optionally
# quoted; its leading path components must end on a non-word character so the
# boundary in $_aegis_tail still means "start of a path component".
_aegis_redir_op='([0-9]*|&)>{1,2}[|&]?'
_aegis_redir_target='[[:space:]]*["'"'"']?([^|;&[:space:]"'"'"']*[^A-Za-z0-9_.-])?'
if echo "$CMD" | grep -qE "$_aegis_redir_op$_aegis_redir_target$_aegis_tail"; then
  ask "redirects into Aegis configuration or install tree"
fi

# 2 and 3. Walk the command segment by segment. Skipped entirely unless the
# command mentions Aegis somewhere -- almost none do, and the walk is not free.
if echo "$CMD" | grep -qE '(\.aegis|\.config/aegis|'"$_aegis_root_re"')'; then
  # Commands that cannot write to a path they are given. Anything not on this
  # list is assumed to be able to write; see SHAPE above. `sed` and `awk` are
  # absent on purpose (`sed -i`, awk's `print > "file"`), as are `find`
  # (-delete, -exec), `sort` (-o), `xxd` (-r out) and `echo`/`printf`, whose
  # entire role in the bypass is to feed a redirect.
  _aegis_readers='cat|bat|less|more|head|tail|nl|tac|rev|grep|egrep|fgrep|rg|ag|ack|ls|tree|stat|file|wc|du|diff|cmp|comm|cksum|md5sum|sha1sum|sha224sum|sha256sum|sha384sum|sha512sum|od|hexdump|strings|realpath|readlink|basename|dirname|jq|test'
  # git as a whole writes; a handful of its subcommands do not.
  _aegis_git_readers='status|diff|log|show|blame|ls-files|grep|cat-file|rev-parse|describe|shortlog|reflog'

  _aegis_writer_names=0  # a segment that can write names a protected path
  _aegis_cd_into=0       # a segment cd's into a protected directory
  _aegis_any_writer=0    # any segment other than that cd can write

  # Splitting on shell separators lets each simple command be judged by its
  # own leading word. Over-splitting is harmless: every fragment is still
  # checked. Under-splitting is not, which is why clause 1 above scans the
  # whole string regardless of where the segment boundaries land.
  while IFS= read -r _seg; do
    if [ -z "${_seg//[[:space:]]/}" ]; then continue; fi
    # Leading word, minus env assignments and the usual wrappers, then
    # basenamed and unquoted so /usr/bin/cat and "cat" both read as cat.
    _w=$(printf '%s\n' "$_seg" | sed -E \
      -e 's/^[[:space:]]+//' \
      -e 's/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//' \
      -e 's/^(sudo|command|env|nohup|time|nice|exec|builtin)[[:space:]]+//' \
      -e 's/[[:space:]].*//')
    _w=${_w##*/}
    _w=${_w//[\"\']/}

    _reader=0
    if [ "$_w" = git ]; then
      _sub=$(printf '%s\n' "$_seg" | sed -E 's/^[[:space:]]*//' | awk '{print $2}')
      if printf '%s\n' "$_sub" | grep -qE "^($_aegis_git_readers)$"; then _reader=1; fi
    elif printf '%s\n' "$_w" | grep -qE "^($_aegis_readers)$"; then
      _reader=1
    fi

    if [ "$_w" = cd ] || [ "$_w" = pushd ]; then
      if printf '%s\n' "$_seg" | grep -qE "$_aegis_named"; then _aegis_cd_into=1; fi
      continue
    fi

    if [ "$_reader" = 0 ]; then
      _aegis_any_writer=1
      if printf '%s\n' "$_seg" | grep -qE "$_aegis_named"; then _aegis_writer_names=1; fi
    fi
  done < <(printf '%s\n' "$CMD" | tr ';|&()`' '\n')

  # 2. Something that can write names a protected path.
  if [ "$_aegis_writer_names" = 1 ]; then
    ask "command names Aegis configuration or install tree and can write to it"
  fi

  # 3. `cd` into a protected directory, then write with a relative path. The
  # matching above is lexical, so `cd <install-root> && printf x > lib/foo.sh`
  # never mentions the protected prefix at the point of the write and clauses
  # 1 and 2 both see clean text. Fully resolving shell working-directory
  # semantics here is not tractable; noticing the `cd` is. Once the shell is
  # parked inside a protected directory, one segment that can write is enough
  # -- a pure read tour (`cd .aegis && cat aegis.toml`) still stays silent.
  if [ "$_aegis_cd_into" = 1 ] && [ "$_aegis_any_writer" = 1 ]; then
    ask "changes into Aegis configuration or install tree, then writes"
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
