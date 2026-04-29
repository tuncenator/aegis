#!/bin/bash
# PreToolUse hook for the Bash tool.
# Consolidates all Bash permission logic in one place:
#   1. Auto-approve safe local commands (replaces settings.json allow list)
#   2. Auto-approve read-only cloud commands (AWS, GCP)
#   3. Everything else falls through to user prompt
#
# Exit behavior (PreToolUse hooks):
#   exit 0 + permissionDecision "allow" on stdout = auto-approve
#   exit 0 + permissionDecision "ask"   on stdout = fall through to user prompt
#   exit 2 = blocking error (NOT fall-through)

ASK='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask"}}'
ALLOW='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'

# Debug trace -- enable by setting GATEKEEPER_DEBUG=1.  Every decision point
# emits one line to stderr so callers (notably the /gatekeeper skill) can
# read the rejection reason without re-deriving it from the script.
dbg() { [ -n "${GATEKEEPER_DEBUG:-}" ] && printf 'GK: %s\n' "$*" >&2; return 0; }

# Resolve the gatekeeper repo root from the hook's own location.  The hook
# is installed as a symlink (~/.claude/hooks/bash-gatekeeper.sh -> repo),
# so `readlink -f` walks the symlink to the real file inside the clone.
# Used by is_safe_cmd to allow this repo's test runner by absolute path
# without hardcoding /home/<user>/... into the script.
GATEKEEPER_REPO=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$CMD" ]; then
  dbg "decision: skip (no command in payload)"
  exit 0
fi
dbg "input: $CMD"

# ---------------------------------------------------------------------------
# is_db_write -- returns 0 if the database command contains write operations,
# 1 otherwise (appears read-only).  Checked against the full command string.
# ---------------------------------------------------------------------------
is_db_write() {
  local cmd="$1"
  # Strip leading whitespace so indented commands hit the env-var stripper below.
  cmd="${cmd#"${cmd%%[![:space:]]*}"}"
  # Strip leading env-var assignments (e.g. PGPASSWORD=xxx psql ...).
  while [[ "$cmd" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    local _next
    _next=$(echo "$cmd" | sed -E 's/^[A-Za-z_][A-Za-z0-9_]*=[^ ]*[ ]+//')
    # No progress (e.g. bare "FOO=bar" with no trailing command) -- stop.
    [ "$_next" = "$cmd" ] && break
    cmd="$_next"
  done
  local base
  base=$(echo "$cmd" | awk '{print $1}')
  # Strip directory prefix so /usr/bin/psql matches psql etc.
  base="${base##*/}"

  case "$base" in
    mongosh)
      # MongoDB write methods: .insertOne(, .drop(, .updateMany(, etc.
      if echo "$cmd" | grep -qEi '\.(insert|insertOne|insertMany|update|updateOne|updateMany|delete|deleteOne|deleteMany|remove|drop|dropDatabase|createCollection|createIndex|dropIndex|dropIndexes|replaceOne|bulkWrite|rename|save|findAndModify|findOneAndUpdate|findOneAndReplace|findOneAndDelete)\s*\('; then
        dbg "is_db_write: mongosh write method matched"
        return 0
      fi
      ;;
    psql)
      # Strip SQL comments (-- to EOL, /* ... */) so write-keywords inside
      # comments don't cause false positives.
      local _sql
      _sql=$(echo "$cmd" | sed -E 's|--[^\n]*||g' | sed -E ':a;s|/\*[^*]*\*+([^/*][^*]*\*+)*/||;ta')
      if echo "$_sql" | grep -qEi '\b(INSERT|UPDATE|DELETE|DROP|CREATE|ALTER|TRUNCATE|GRANT|REVOKE|VACUUM|REINDEX|COPY)\b'; then
        dbg "is_db_write: psql write keyword matched"
        return 0
      fi
      ;;
    mysql|mariadb)
      local _sql
      _sql=$(echo "$cmd" | sed -E 's|--[^\n]*||g; s|#[^\n]*||g' | sed -E ':a;s|/\*[^*]*\*+([^/*][^*]*\*+)*/||;ta')
      if echo "$_sql" | grep -qEi '\b(INSERT|UPDATE|DELETE|DROP|CREATE|ALTER|TRUNCATE|GRANT|REVOKE|REPLACE\s+INTO|LOAD\s+DATA|RENAME)\b'; then
        dbg "is_db_write: mysql/mariadb write keyword matched"
        return 0
      fi
      ;;
    sqlite3)
      local _sql
      _sql=$(echo "$cmd" | sed -E 's|--[^\n]*||g' | sed -E ':a;s|/\*[^*]*\*+([^/*][^*]*\*+)*/||;ta')
      if echo "$_sql" | grep -qEi '\b(INSERT|UPDATE|DELETE|DROP|CREATE|ALTER|VACUUM|REPLACE)\b'; then
        dbg "is_db_write: sqlite3 write keyword matched"
        return 0
      fi
      ;;
    redis-cli)
      if echo "$cmd" | grep -qEi '\b(SET|SETNX|SETEX|PSETEX|MSET|MSETNX|DEL|UNLINK|FLUSHDB|FLUSHALL|EXPIRE|EXPIREAT|PEXPIRE|PERSIST|RENAME|RENAMENX|LPUSH|RPUSH|LPOP|RPOP|LSET|LINSERT|LTRIM|SADD|SREM|SPOP|SMOVE|ZADD|ZREM|ZINCRBY|HSET|HSETNX|HMSET|HDEL|APPEND|INCR|INCRBY|INCRBYFLOAT|DECR|DECRBY|RPOPLPUSH|LMOVE|RESTORE|SWAPDB|EVAL|EVALSHA)\b'; then
        dbg "is_db_write: redis-cli write command matched"
        return 0
      fi
      ;;
  esac

  return 1
}

# ---------------------------------------------------------------------------
# wrapper_flags_with_value -- space-padded list of flags that take a separate
# argument (rather than inline =value or bundled short-flag value), keyed by
# transparent-wrapper name.  Used by strip_wrapper_args.
# ---------------------------------------------------------------------------
wrapper_flags_with_value() {
  case "$1" in
    timeout)  echo " -s --signal -k --kill-after " ;;
    nice)     echo " -n --adjustment " ;;
    ionice)   echo " -c --class -n --classdata -p --pid -u --uid " ;;
    stdbuf)   echo " -i -o -e --input --output --error " ;;
    env)      echo " -u --unset -C --chdir -S --split-string " ;;
    taskset)  echo " -c --cpu-list -p --pid " ;;
    chrt)     echo " -p --pid " ;;
    exec)     echo " -a " ;;
    *)        echo "" ;;
  esac
}

# ---------------------------------------------------------------------------
# strip_wrapper_args -- strip a transparent wrapper command (time, timeout,
# nice, nohup, stdbuf, env, ...) and its leading argument tokens, returning
# the inner command so the caller can recurse.  Handles short/long flags,
# flags that take a separate value, numeric/duration args, cpu-lists, and
# env-style VAR=val tokens.  Unusual forms may fall through to user prompt.
# ---------------------------------------------------------------------------
strip_wrapper_args() {
  local cmd="$1"
  local wrapper="$2"
  local value_flags
  value_flags=$(wrapper_flags_with_value "$wrapper")
  cmd=$(echo "$cmd" | sed -E "s/^${wrapper}[[:space:]]+//")
  while true; do
    local first
    first=$(echo "$cmd" | awk '{print $1}')
    [ -z "$first" ] && break
    # Flag token (short or long)
    if [[ "$first" == -* && "$first" != "-" ]]; then
      local has_inline_value=false
      [[ "$first" == *=* ]] && has_inline_value=true
      cmd=$(echo "$cmd" | sed -E 's/^[^[:space:]]+[[:space:]]*//')
      if [ "$has_inline_value" = false ] && [[ "$value_flags" == *" $first "* ]]; then
        cmd=$(echo "$cmd" | sed -E 's/^[^[:space:]]+[[:space:]]*//')
      fi
      continue
    fi
    # Numeric / duration (5s, 2m) / cpu-list (0,1 / 0-3) / size (512k)
    if [[ "$first" =~ ^[0-9]+([.,-][0-9]+)*[smhdSMHDkmgKMG]?$ ]]; then
      cmd=$(echo "$cmd" | sed -E 's/^[^[:space:]]+[[:space:]]*//')
      continue
    fi
    # env VAR=val token
    if [ "$wrapper" = "env" ] && [[ "$first" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      cmd=$(echo "$cmd" | sed -E 's/^[^[:space:]]+[[:space:]]*//')
      continue
    fi
    break
  done
  echo "$cmd"
}

# ---------------------------------------------------------------------------
# is_safe_cmd -- returns 0 if a single (non-compound) command is safe to
# auto-approve, 1 otherwise.  Handles base-command lookups, subcommand
# checks for gh/docker/kubectl/acli, git patterns, and venv activation.
# ---------------------------------------------------------------------------
is_safe_cmd() {
  local cmd="$1"
  cmd=$(echo "$cmd" | sed 's/^ *//; s/ *$//')
  [ -z "$cmd" ] && return 0

  # Strip leading env-var assignments (FOO=bar BAZ=qux cmd ...) so that
  # base-command and subcommand extraction sees the real command.
  while [[ "$cmd" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    local _next
    _next=$(echo "$cmd" | sed -E 's/^[A-Za-z_][A-Za-z0-9_]*=[^ ]*[ ]+//')
    # No progress (e.g. bare "FOO=bar" with no trailing command) -- stop.
    [ "$_next" = "$cmd" ] && break
    cmd="$_next"
  done

  # Standalone `export VAR=value [VAR2=value2 ...]` -- bash keyword form of
  # env-var assignment with no trailing command.  Functionally a no-op from
  # the gatekeeper's perspective, mirroring the inline FOO=bar stripper above.
  if [[ "$cmd" =~ ^export([[:space:]]+[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*)+[[:space:]]*$ ]]; then
    dbg "is_safe_cmd: matched standalone export VAR=value"
    return 0
  fi

  # Gatekeeper repo's own test runner -- matched by literal path so a
  # generic `run.sh` in unrelated repos doesn't auto-allow.  Covers both
  # the relative form (skill `cd`s into the repo first) and the absolute
  # form resolved from this hook's own install location.
  case "$cmd" in
    "./tests/run.sh"|"./tests/run.sh "*|"tests/run.sh"|"tests/run.sh "*)
      dbg "is_safe_cmd: matched gatekeeper repo test runner (relative path)"
      return 0 ;;
    "$GATEKEEPER_REPO/tests/run.sh"|"$GATEKEEPER_REPO/tests/run.sh "*)
      dbg "is_safe_cmd: matched gatekeeper repo test runner (absolute path)"
      return 0 ;;
    "bash tests/run.sh"|"bash tests/run.sh "*|"bash ./tests/run.sh"|"bash ./tests/run.sh "*)
      dbg "is_safe_cmd: matched gatekeeper repo test runner (bash + relative path)"
      return 0 ;;
    "bash $GATEKEEPER_REPO/tests/run.sh"|"bash $GATEKEEPER_REPO/tests/run.sh "*)
      dbg "is_safe_cmd: matched gatekeeper repo test runner (bash + absolute path)"
      return 0 ;;
  esac

  local base
  base=$(echo "$cmd" | awk '{print $1}')
  # Strip directory prefix so /usr/bin/grep matches grep etc.
  base="${base##*/}"
  dbg "is_safe_cmd: base=$base"

  # Transparent command wrappers -- strip wrapper + its args, recurse on inner.
  case "$base" in
    time|timeout|nice|ionice|nohup|stdbuf|unbuffer|env|command|exec|setsid|taskset|chrt)
      local _rest
      _rest=$(strip_wrapper_args "$cmd" "$base")
      if [ -z "$_rest" ] || [ "$_rest" = "$cmd" ]; then
        dbg "is_safe_cmd: wrapper '$base' failed to strip args (unusual form)"
        return 1
      fi
      dbg "is_safe_cmd: stripped wrapper '$base', recursing on '$_rest'"
      is_safe_cmd "$_rest"
      return $?
      ;;
  esac

  case "$base" in
    # Safe read-only / informational / text-filter commands
    cd|ls|cat|echo|printf|pwd|grep|rg|tree|head|tail|wc|stat|file|du|df|curl|wget|which|type|env|printenv|id|whoami|hostname|uname|date|uptime|free|lsblk|lsusb|lspci|lscpu|lsmod|lshw|dmesg|ip|ss|dig|nslookup|host|ping|traceroute|whois|jq|yq|column|sort|uniq|diff|comm|less|more|realpath|dirname|basename|readlink|sha256sum|md5sum|base64|xxd|hexdump|sed|awk|tr|cut|rev|fmt|fold|nl|tac|strings|ps|top|htop|pgrep|pstree|lsof|inxi|bash-gatekeeper.sh|true|false|test|\[|sleep)
      dbg "is_safe_cmd: matched safe read-only/text-filter base ($base)"
      return 0 ;;
    find)
      dbg "is_safe_cmd: find, checking for destructive flags (-delete/-exec/-execdir)"
      if echo "$cmd" | grep -qE -- '-(delete|exec|execdir)\b'; then
        dbg "is_safe_cmd: find with destructive flag -> reject"
        return 1
      fi
      dbg "is_safe_cmd: find (read-only, no destructive flags)"
      return 0 ;;
    # Browsers (headless screenshot / UI testing)
    chromium|chromium-browser|google-chrome|google-chrome-stable)
      dbg "is_safe_cmd: matched browser base ($base)"
      return 0 ;;
    # Package managers / dev tools (read-only or safe operations)
    npm|npx|yarn|pnpm|pip|pip3|uv|cargo|go|rustup|node|python|python3|ruby|php|java|javac|dotnet|make|cmake|ninja)
      dbg "is_safe_cmd: matched package-manager/dev-tool base ($base)"
      return 0 ;;
    # Database clients -- read-only only, write ops fall through to user prompt
    psql|mariadb|mysql|mongosh|sqlite3|redis-cli)
      if is_db_write "$cmd"; then
        dbg "is_safe_cmd: db client '$base' contains write op -> reject"
        return 1
      fi
      dbg "is_safe_cmd: db client '$base' is read-only"
      return 0 ;;
    # Testing / linting
    pytest|ruff|eslint|prettier|mypy|flake8|black|isort|shellcheck|hadolint)
      dbg "is_safe_cmd: matched testing/linting base ($base)"
      return 0 ;;
    # Gemini CLI
    gemini)
      dbg "is_safe_cmd: matched gemini"
      return 0 ;;
    # Conclave -- all binaries, all subcommands
    conclave|conclave-init|conclave-index|conclave-brief)
      dbg "is_safe_cmd: matched conclave binary ($base)"
      return 0 ;;
    # Docker (read-only)
    docker)
      local docker_sub
      docker_sub=$(echo "$cmd" | awk '{print $2}')
      case "$docker_sub" in
        ps|images|logs|inspect|stats|top|port|diff|history|version|info|network|volume|compose)
          dbg "is_safe_cmd: matched docker read-only sub=$docker_sub"
          return 0 ;;
      esac
      dbg "is_safe_cmd: docker sub='$docker_sub' not in read-only verbs"
      ;;
    # Kubectl (read-only)
    kubectl)
      local kube_sub
      kube_sub=$(echo "$cmd" | awk '{print $2}')
      case "$kube_sub" in
        get|describe|logs|top|explain|api-resources|api-versions|cluster-info|config|version)
          dbg "is_safe_cmd: matched kubectl read-only sub=$kube_sub"
          return 0 ;;
      esac
      dbg "is_safe_cmd: kubectl sub='$kube_sub' not in read-only verbs"
      ;;
    # journalctl (read-only -- block --vacuum-*, --rotate, --flush, --sync,
    # --relinquish-var, --smart-relinquish-var, --update-catalog, --setup-keys)
    journalctl)
      if echo "$cmd" | grep -qE -- '(^|[[:space:]])--(vacuum-(size|time|files)|rotate|flush|sync|relinquish-var|smart-relinquish-var|update-catalog|setup-keys)([=[:space:]]|$)'; then
        dbg "is_safe_cmd: journalctl destructive flag -> reject"
      else
        dbg "is_safe_cmd: matched journalctl read-only"
        return 0
      fi
      ;;
    # systemctl (read-only verbs only -- never start/stop/enable/disable/etc.)
    systemctl)
      local sctl_sub
      sctl_sub=$(echo "$cmd" | awk '{print $2}')
      case "$sctl_sub" in
        status|show|cat|help|list-units|list-unit-files|list-timers|list-sockets|list-jobs|list-machines|list-dependencies|list-automounts|list-paths|is-active|is-enabled|is-failed|get-default)
          dbg "is_safe_cmd: matched systemctl read-only sub=$sctl_sub"
          return 0 ;;
      esac
      dbg "is_safe_cmd: systemctl sub='$sctl_sub' not in read-only verbs"
      ;;
    # restic -- read-only verbs only.  Destructive verbs (init/backup/forget/
    # prune/restore/copy/migrate/repair/rebuild-index/recover/unlock/tag/
    # generate/key/options) fall through to user prompt.
    restic)
      local restic_sub
      restic_sub=$(echo "$cmd" | awk '{print $2}')
      case "$restic_sub" in
        ls|snapshots|cat|find|stats|diff|dump|check|list|version|help)
          dbg "is_safe_cmd: matched restic read-only sub=$restic_sub"
          return 0 ;;
      esac
      dbg "is_safe_cmd: restic sub='$restic_sub' not in read-only verbs"
      ;;
    # crontab -- only `crontab -l` is read-only; -e/-r/<file> all mutate
    crontab)
      # Allowed forms: `crontab -l`, `crontab -u USER -l`, `crontab -l -u USER`
      if echo "$cmd" | grep -qE '^crontab[[:space:]]+(-u[[:space:]]+[A-Za-z_][A-Za-z0-9_-]*[[:space:]]+)?-l([[:space:]]+-u[[:space:]]+[A-Za-z_][A-Za-z0-9_-]*)?[[:space:]]*$'; then
        dbg "is_safe_cmd: matched crontab read-only (-l)"
        return 0
      fi
      dbg "is_safe_cmd: crontab form not recognised as read-only (-l)"
      ;;
    # GitHub CLI (read-only)
    gh)
      local gh_sub gh_verb
      gh_sub=$(echo "$cmd" | awk '{print $2}')
      gh_verb=$(echo "$cmd" | awk '{print $3}')
      case "$gh_sub" in
        status|auth)
          dbg "is_safe_cmd: matched gh sub=$gh_sub"
          return 0 ;;
        repo|pr|issue|release|run|workflow|gist|project|label|variable|secret|cache|ruleset|codespace)
          case "$gh_verb" in
            list|view|status|diff|checks|ls|watch|download)
              dbg "is_safe_cmd: matched gh sub=$gh_sub verb=$gh_verb"
              return 0 ;;
          esac
          dbg "is_safe_cmd: gh sub=$gh_sub verb='$gh_verb' not in {list|view|status|diff|checks|ls|watch|download}"
          ;;
        search)
          dbg "is_safe_cmd: matched gh search"
          return 0 ;;
        api)
          if ! echo "$cmd" | grep -qEi -- '--method[= ](POST|PUT|PATCH|DELETE)|-X[= ]?(POST|PUT|PATCH|DELETE)'; then
            dbg "is_safe_cmd: matched gh api (no write method)"
            return 0
          fi
          dbg "is_safe_cmd: gh api uses write method -> reject"
          ;;
        *)
          dbg "is_safe_cmd: gh sub='$gh_sub' not in allowlist"
          ;;
      esac
      ;;
    # SSH / SFTP
    ssh|sftp|scp)
      dbg "is_safe_cmd: matched ssh/sftp/scp ($base)"
      return 0 ;;
    # Atlassian CLI (read-only)
    acli)
      local acli_sub acli_obj acli_verb
      acli_sub=$(echo "$cmd" | awk '{print $2}')
      acli_obj=$(echo "$cmd" | awk '{print $3}')
      acli_verb=$(echo "$cmd" | awk '{print $4}')
      if [ "$acli_sub" = "jira" ]; then
        case "$acli_obj" in
          board)
            case "$acli_verb" in
              get|list-projects)
                dbg "is_safe_cmd: matched acli jira board $acli_verb"
                return 0 ;;
            esac
            dbg "is_safe_cmd: acli jira board verb='$acli_verb' not in {get|list-projects}"
            ;;
          workitem)
            case "$acli_verb" in
              search|view)
                dbg "is_safe_cmd: matched acli jira workitem $acli_verb"
                return 0 ;;
              comment)
                local acli_comment_verb
                acli_comment_verb=$(echo "$cmd" | awk '{print $5}')
                if [ "$acli_comment_verb" = "list" ]; then
                  dbg "is_safe_cmd: matched acli jira workitem comment list"
                  return 0
                fi
                dbg "is_safe_cmd: acli jira workitem comment verb='$acli_comment_verb' not 'list'"
                ;;
            esac
            ;;
          *)
            dbg "is_safe_cmd: acli jira obj='$acli_obj' not in {board|workitem}"
            ;;
        esac
      else
        dbg "is_safe_cmd: acli sub='$acli_sub' not 'jira'"
      fi
      ;;
    # GAM Google Workspace admin (read-only verbs)
    gam)
      local gam_sub
      gam_sub=$(echo "$cmd" | awk '{print $2}')
      case "$gam_sub" in
        info|print|show|report|check|version|showsections)
          dbg "is_safe_cmd: matched gam sub=$gam_sub (read-only)"
          return 0 ;;
        user|users)
          local gam_verb
          gam_verb=$(echo "$cmd" | awk '{print $4}')
          case "$gam_verb" in
            info|print|show|report|check)
              dbg "is_safe_cmd: matched gam $gam_sub <entity> $gam_verb (read-only)"
              return 0 ;;
          esac
          dbg "is_safe_cmd: gam $gam_sub <entity> verb='$gam_verb' not in {info|print|show|report|check}"
          ;;
      esac
      dbg "is_safe_cmd: gam sub='$gam_sub' not in read-only allowlist"
      ;;
  esac

  # Git -- strip global pre-subcommand flags (-C <path>, -c key=val,
  # --git-dir=..., --work-tree=..., --no-pager, -P) so the subcommand
  # regexes below match e.g. `git -C /path show ...`.
  local git_cmd="$cmd"
  if [ "$base" = "git" ]; then
    git_cmd=$(echo "$cmd" | sed -E 's/^git([[:space:]]+(-C[[:space:]]+[^[:space:]]+|-c[[:space:]]+[^[:space:]]+|--git-dir=[^[:space:]]+|--work-tree=[^[:space:]]+|--no-pager|-P))+/git/')
  fi

  # Git -- read-only subcommands
  if echo "$git_cmd" | grep -qE '^git (status|log|diff|show|branch|tag|remote|stash list|rev-parse|ls-files|ls-tree|shortlog|blame|reflog|describe|config --get|config --list|config -l)'; then
    dbg "is_safe_cmd: matched git read-only subcommand"
    return 0
  fi

  # Git config read: `git config [--global|--local|--system|--worktree|--file=...] <key>`
  # with no value argument (anchored $ prevents matching writes).
  if echo "$git_cmd" | grep -qE '^git config( (--global|--local|--system|--worktree|--file=[^ ]+))* [A-Za-z][A-Za-z0-9._-]+$'; then
    dbg "is_safe_cmd: matched git config read"
    return 0
  fi

  # Git -- safe write operations
  if echo "$git_cmd" | grep -qE '^git (add|commit|checkout|switch|merge|rebase|pull|fetch|stash|cherry-pick|restore|reset)'; then
    dbg "is_safe_cmd: matched git safe-write subcommand"
    return 0
  fi

  if [ "$base" = "git" ]; then
    dbg "is_safe_cmd: git subcommand not in read-only / config-read / safe-write regexes"
  fi

  # Source + activate (virtualenv) -- supports both `source` and `.` shorthand
  if echo "$cmd" | grep -qE '^(source|\.) .*(venv|env).*/activate'; then
    dbg "is_safe_cmd: matched source venv/activate"
    return 0
  fi

  # Any python (bare name or path) invoked as `-m pytest ...`
  if echo "$cmd" | grep -qE '^\S*python[0-9.]*[[:space:]]+-m[[:space:]]+pytest([[:space:]]|$)'; then
    dbg "is_safe_cmd: matched python -m pytest"
    return 0
  fi

  dbg "is_safe_cmd: no rule matched -> reject"
  return 1
}

# --- Handle heredoc commands ---
# Heredoc bodies are stdin data, not shell commands.  For compound-safety
# analysis we only need the shell command line (the first line).  However,
# write-detection (is_db_write) must still see the full heredoc body since
# that's where the actual DB statements live.
# Handles quoted (<<'EOF', <<"EOF"), unquoted (<<EOF), and <<- variants.
FULL_CMD="$CMD"
if [[ "$CMD" == *$'\n'* ]] && echo "$CMD" | head -1 | grep -qE '<<-?\s*'"'"'?"?[A-Za-z_][A-Za-z0-9_]*"?'"'"'?'; then
  dbg "heredoc detected -- scanning body for DB writes"
  # Check for DB writes against the full command (including heredoc body).
  # Flatten to one line so is_db_write can extract the base command properly.
  if is_db_write "$(echo "$FULL_CMD" | tr '\n' ' ')"; then
    dbg "decision: ASK (heredoc body contains DB write)"
    echo "$ASK"
    exit 0
  fi
  CMD=$(echo "$CMD" | head -1)
  dbg "heredoc body clean -- analysing first line only: $CMD"
fi

# Collapse backslash-newline line continuations.  In shell, `\<newline>` is
# pure whitespace -- without this normalization, a single logical command
# split across lines looks like a multi-line compound command and the
# segment walker treats each continuation line (which starts with a flag)
# as a standalone command that no rule matches.
if [[ "$CMD" == *$'\\\n'* ]]; then
  CMD=$(printf '%s' "$CMD" | sed -E ':a;N;$!ba;s/\\\n[[:space:]]*/ /g')
  dbg "normalized backslash-newline continuations: $CMD"
fi

# --- Check if command is compound ---
IS_COMPOUND=false
HAS_SUBSHELL=false

# Subshell / command substitution -- these embed arbitrary commands that
# can't be safely analysed by splitting on operators.  Neutralize quoted
# strings first so backticks / $(...) inside quoted args (e.g. sed 's/`/x/')
# don't trigger the gate as false positives.  Then strip shell comments
# (# to EOL, when # is at start-of-line or after whitespace) so backticks
# or $(...) inside a comment line don't trigger the gate either -- bash
# never executes comment bodies, and the segment loop already skips
# comment-only segments.
#
# Pre-pass: protect backslash-escaped quotes so they don't mis-pair the
# neutralizer regex.  Collapse \\ first (so a literal backslash followed
# by a real quote-opener like `\\'` doesn't look like an escaped quote),
# then replace \' (from $'...') and \" (from "...") with a placeholder.
_cmd_noquotes=$(printf '%s' "$CMD" | sed -E 's/\\\\/__BS__/g' | sed -E 's/\\['"'"'"]/__ESCQ__/g' | sed -z -E "s/'[^']*'/__Q__/g" | sed -z -E 's/"[^"]*"/__Q__/g')
_cmd_noquotes=$(printf '%s' "$_cmd_noquotes" | sed -E 's/(^|[[:space:]])#.*$//')
if echo "$_cmd_noquotes" | grep -qE '`|\$\(|<\(|>\(' ; then
  HAS_SUBSHELL=true
  IS_COMPOUND=true
  dbg "compound: yes (subshell / command substitution)"
fi

# Shell operators: &&, ||, ;, |, &
if echo "$CMD" | grep -qE '&&|\|\||[;&|]' ; then
  if [ "$IS_COMPOUND" = false ]; then
    dbg "compound: yes (shell operator)"
  fi
  IS_COMPOUND=true
fi

# Multi-line commands are compound (newlines act like ; in shell)
if [[ "$CMD" == *$'\n'* ]]; then
  if [ "$IS_COMPOUND" = false ]; then
    dbg "compound: yes (multi-line)"
  fi
  IS_COMPOUND=true
fi

if [ "$IS_COMPOUND" = false ]; then
  dbg "compound: no"
fi

# --- Simple (non-compound) commands ---
if [ "$IS_COMPOUND" = false ]; then
  if is_safe_cmd "$CMD"; then
    dbg "decision: ALLOW (is_safe_cmd matched)"
    echo "$ALLOW"
    exit 0
  fi
fi

# --- Compound commands: auto-approve known safe patterns ---
# Commands with subshell expansion (backticks, $(), <(), >()) embed arbitrary
# commands that we can't reliably extract by splitting on operators, so we
# never auto-approve them -- they always fall through to user prompt.
if [ "$IS_COMPOUND" = true ] && [ "$HAS_SUBSHELL" = false ]; then
  # uv run / pipx run patterns
  if echo "$CMD" | grep -qE '^(uv run|pipx run) (ruff|pytest|python|mypy|black|isort|conclave-init|conclave)'; then
    dbg "decision: ALLOW (uv/pipx run shortcut)"
    echo "$ALLOW"
    exit 0
  fi
  # source venv && tool
  if echo "$CMD" | grep -qE '^source .*(venv|env).*/activate && (ruff|pytest|python|mypy|black|isort)'; then
    dbg "decision: ALLOW (source venv && tool shortcut)"
    echo "$ALLOW"
    exit 0
  fi

  # General compound safety: auto-approve if every segment is a safe command.
  # Split on compound operators, but first neutralize quoted strings so that
  # operators inside quotes (e.g. awk '{a; b}' or sed 's/|/x/') are not
  # treated as shell operators.
  ALL_SAFE=true
  # Replace single-quoted and double-quoted content with placeholders before splitting
  # Use sed -z to handle multi-line quoted strings (e.g. mongosh --eval '...')
  # Pre-pass: protect backslash-escaped quotes (\' inside $'...', \" inside "...")
  # so they don't mis-pair the regex below.  Collapse \\ first so `\\'` (literal
  # backslash + real quote-opener) is not mistaken for an escaped quote.
  _neutralized=$(printf '%s' "$CMD" | sed -E 's/\\\\/__BS__/g' | sed -E 's/\\['"'"'"]/__ESCQ__/g' | sed -z -E "s/'[^']*'/__Q__/g" | sed -z -E 's/"[^"]*"/__Q__/g')
  # Strip shell redirections before splitting so that 2>&1 etc. don't
  # cause false splits on the & operator.  The target character class
  # excludes shell separators (; | & < > ( )) so e.g. `2>/dev/null;` keeps
  # the trailing `;` for the segment splitter -- otherwise adjacent
  # segments fuse into one and fail is_safe_cmd as a malformed command.
  _neutralized=$(echo "$_neutralized" | sed -E 's/[0-9]*>&[0-9]+//g; s/[0-9]*>>[^ ;|&<>()]*//g; s/[0-9]*>[^ ;|&<>()]*//g; s/[0-9]*<[^ ;|&<>()]*//g' | tr -s ' ')
  dbg "compound: walking segments"
  _seg_n=0
  while IFS= read -r _segment; do
    # Trim whitespace, strip redirections (2>&1, >/dev/null, 2>/dev/null, etc.)
    _segment=$(echo "$_segment" | sed 's/^ *//; s/ *$//' | sed -E 's/[0-9]*>&[0-9]+//g; s/[0-9]*>>[^ ]*//g; s/[0-9]*>[^ ]*//g; s/[0-9]*<[^ ]*//g' | tr -s ' ' | sed 's/^ *//; s/ *$//')
    # Strip grouping parens so `(cmd && other)` splits into clean segments.
    # Safe because each segment still has to pass is_safe_cmd individually --
    # parens only change grouping/execution order, not which commands run.
    _segment=$(echo "$_segment" | sed -E 's/^\(+[[:space:]]*//; s/[[:space:]]*\)+$//')
    [ -z "$_segment" ] && continue
    case "$_segment" in \#*) continue ;; esac
    _seg_n=$((_seg_n + 1))
    dbg "  seg $_seg_n: '$_segment'"
    if ! is_safe_cmd "$_segment"; then
      dbg "  seg $_seg_n unsafe -> abort segment walk"
      ALL_SAFE=false
      break
    fi
    dbg "  seg $_seg_n safe"
  done < <(echo "$_neutralized" | sed 's/&&/\n/g' | sed 's/||/\n/g' | sed 's/&/\n/g' | sed 's/|/\n/g' | sed 's/;/\n/g')

  if [ "$ALL_SAFE" = true ]; then
    dbg "decision: ALLOW (all segments safe)"
    echo "$ALLOW"
    exit 0
  fi
fi

if [ "$IS_COMPOUND" = true ] && [ "$HAS_SUBSHELL" = true ]; then
  dbg "compound + subshell: never auto-approved via segment walk; trying cloud/pipeline rules"
fi

# --- AWS ---
# Strip leading env-var assignments (AWS_PROFILE=foo aws ...), then all
# --flag and --flag=value tokens, then check the remaining positional
# tokens for: aws <service> <read-only-verb>
CMD_NOENV="$CMD"
while [[ "$CMD_NOENV" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
  _next=$(echo "$CMD_NOENV" | sed -E 's/^[A-Za-z_][A-Za-z0-9_]*=[^ ]*[ ]+//')
  [ "$_next" = "$CMD_NOENV" ] && break
  CMD_NOENV="$_next"
done
AWS_STRIPPED=$(echo "$CMD_NOENV" | sed -E 's/--[a-zA-Z0-9_-]+([ =][^ ]*)?//g' | tr -s ' ')

if echo "$AWS_STRIPPED" | grep -qE '^aws [a-z0-9-]+ (describe|list|get|head)-'; then
  dbg "decision: ALLOW (AWS read-only verb describe|list|get|head-)"
  echo "$ALLOW"
  exit 0
fi

if echo "$AWS_STRIPPED" | grep -qE '^aws s3 ls'; then
  dbg "decision: ALLOW (aws s3 ls)"
  echo "$ALLOW"
  exit 0
fi

if echo "$AWS_STRIPPED" | grep -qE '^aws sts get-caller-identity'; then
  dbg "decision: ALLOW (aws sts get-caller-identity)"
  echo "$ALLOW"
  exit 0
fi

# --- GCP gcloud ---
GCLOUD_STRIPPED=$(echo "$CMD_NOENV" | sed -E 's/--[a-zA-Z0-9_-]+([ =][^ ]*)?//g' | tr -s ' ')

if echo "$GCLOUD_STRIPPED" | grep -qE '^gcloud .+ (describe|list|get|get-iam-policy)( |$)'; then
  dbg "decision: ALLOW (gcloud read-only verb describe|list|get|get-iam-policy)"
  echo "$ALLOW"
  exit 0
fi

if echo "$GCLOUD_STRIPPED" | grep -qE '^gcloud (config list|config get|info|auth list|projects list|projects describe)'; then
  dbg "decision: ALLOW (gcloud config/info/auth/projects read-only)"
  echo "$ALLOW"
  exit 0
fi

# --- GCP gsutil / gcloud storage ---
if echo "$GCLOUD_STRIPPED" | grep -qE '^(gsutil|gcloud storage) (ls|cat|stat)'; then
  dbg "decision: ALLOW (gsutil/gcloud storage ls|cat|stat)"
  echo "$ALLOW"
  exit 0
fi

# --- GCP bq ---
if echo "$GCLOUD_STRIPPED" | grep -qE '^bq (show|ls)'; then
  dbg "decision: ALLOW (bq show|ls)"
  echo "$ALLOW"
  exit 0
fi

# --- FortiGate read-only SSH session (sshpass heredoc) ---
# Pattern from /fortigate skill:
#   sshpass -p '...' ssh ... FGT_001_CLAUDE ... << 'EOF' | sed ... | sed ...
#   <fortigate CLI commands>
#   EOF
# The SSH user is read-only in practice. Belt-and-suspenders: also verify
# every non-empty heredoc line is a read-only verb (get / show / diagnose /
# execute log ...), and every post-sshpass pipe segment is a safe filter.
_first=$(echo "$FULL_CMD" | head -1)
if echo "$_first" | grep -qE '^[[:space:]]*sshpass[[:space:]]' && \
   echo "$_first" | grep -qE '[[:space:]]FGT_001_CLAUDE([[:space:]]|$)' && \
   echo "$_first" | grep -qE '<<-?[[:space:]]*'"'"'?"?[A-Za-z_][A-Za-z0-9_]*"?'"'"'?'; then
  _fg_safe=true

  # First line: every pipe segment after the sshpass one must pass is_safe_cmd.
  _first_neutralized=$(printf '%s' "$_first" | sed -z -E "s/'[^']*'/__Q__/g" | sed -z -E 's/"[^"]*"/__Q__/g')
  _seg_idx=0
  while IFS= read -r _seg; do
    _seg_idx=$((_seg_idx+1))
    _seg=$(echo "$_seg" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed -E 's/[0-9]*>&[0-9]+//g; s/[0-9]*>>[^ ]*//g; s/[0-9]*>[^ ]*//g' | tr -s ' ')
    [ -z "$_seg" ] && continue
    [ "$_seg_idx" = 1 ] && continue   # the sshpass+ssh+heredoc segment
    if ! is_safe_cmd "$_seg"; then
      _fg_safe=false
      break
    fi
  done < <(echo "$_first_neutralized" | sed 's/|/\n/g')

  # Reject any non-whitespace content AFTER the EOF terminator -- that would
  # be an unchecked shell command outside the heredoc.
  if [ "$_fg_safe" = true ]; then
    _after_eof=$(echo "$FULL_CMD" | awk 'after {print} /^[[:space:]]*EOF[[:space:]]*$/ {after=1}')
    if echo "$_after_eof" | grep -qE '[^[:space:]]'; then
      _fg_safe=false
    fi
  fi

  # Heredoc body (lines 2..EOF-marker): only read-only fortigate verbs allowed.
  if [ "$_fg_safe" = true ]; then
    _body=$(echo "$FULL_CMD" | sed -n '2,$p' | sed -n '/^[[:space:]]*EOF[[:space:]]*$/q;p')
    while IFS= read -r _line; do
      _t=$(echo "$_line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      [ -z "$_t" ] && continue
      case "$_t" in
        get\ *|show\ *|diagnose\ *|"execute log "*) ;;
        *) _fg_safe=false; break ;;
      esac
    done <<<"$_body"
  fi

  if [ "$_fg_safe" = true ]; then
    dbg "decision: ALLOW (FortiGate read-only sshpass heredoc)"
    echo "$ALLOW"
    exit 0
  else
    dbg "FortiGate pattern matched but failed safety checks (heredoc verb / post-EOF / pipe segment)"
  fi
fi

# --- HubSpot API pipelines (read-only PAT token) ---
# pat-eu1-... has only *.read scopes, so any api.hubapi.com call is read-only
# regardless of HTTP method (POSTs here hit /search, /batch/read, /graphql).
# Auto-approve the skill's multi-step data-fetch pipelines (curl + /tmp +
# python3 + sleep + if/then) even when they contain subshells, provided:
#   - every http(s) URL targets api.hubapi.com
#   - every > / >> redirect writes to /tmp or /dev/null
#   - no destructive shell tokens appear (rm, sudo, eval, nc, ssh, etc.)
if echo "$FULL_CMD" | grep -qE 'api\.hubapi\.com|(^|[[:space:];|&()`$])hs[[:space:]]+(GET|POST)[[:space:]]'; then
  _hs_safe=true

  # Destructive / exfil commands as standalone shell tokens.
  if echo "$FULL_CMD" | grep -qE '(^|[[:space:];|&()`$])(rm|mv|cp|dd|mkfs|shred|chmod|chown|sudo|doas|eval|exec|kill|killall|nc|ncat|socat|ssh|scp|sftp|rsync)([[:space:];|&()<>]|$)'; then
    _hs_safe=false
  fi

  # Piping into a shell / interpreter.
  if [ "$_hs_safe" = true ] && echo "$FULL_CMD" | grep -qE '\|[[:space:]]*(sh|bash|zsh|ksh|fish|ash|dash|perl|php|ruby)([[:space:]]|$)'; then
    _hs_safe=false
  fi

  # Redirect targets: allow only /tmp/*, /dev/null, /dev/stdout, /dev/stderr, &N.
  if [ "$_hs_safe" = true ]; then
    while IFS= read -r _tgt; do
      [ -z "$_tgt" ] && continue
      _path=$(echo "$_tgt" | sed -E 's/^>+[[:space:]]*//')
      case "$_path" in
        /tmp/*|/dev/null|/dev/stdout|/dev/stderr|\&[0-9]*) ;;
        *) _hs_safe=false; break ;;
      esac
    done < <(echo "$FULL_CMD" | grep -oE '>>?[[:space:]]*[^[:space:]|;&<>()`]+')
  fi

  # Every http(s) URL must be api.hubapi.com.
  if [ "$_hs_safe" = true ]; then
    while IFS= read -r _url; do
      [ -z "$_url" ] && continue
      case "$_url" in
        https://api.hubapi.com*|http://api.hubapi.com*) ;;
        *) _hs_safe=false; break ;;
      esac
    done < <(echo "$FULL_CMD" | grep -oE "https?://[^[:space:]\"'\`)]+")
  fi

  if [ "$_hs_safe" = true ]; then
    dbg "decision: ALLOW (HubSpot api.hubapi.com pipeline)"
    echo "$ALLOW"
    exit 0
  else
    dbg "HubSpot pattern matched but failed safety checks (destructive token / non-tmp redirect / non-hubapi URL / pipe-into-shell)"
  fi
fi

# --- Conclave local pipelines ---
# Brief-history / manifest bookkeeping runs jq + date + tail + echo pipelines
# that write to .conclave/*.  Allow these even when compound/subshelled,
# provided:
#   - command references .conclave/ somewhere
#   - no destructive / exfil tokens appear
#   - no network calls (http(s) URLs)
#   - no pipe-into-shell
#   - every > / >> redirect targets .conclave/*, /tmp/*, /dev/null, or &N
if echo "$FULL_CMD" | grep -qE '(^|[[:space:]=/"'"'"'])(\.conclave/|conclave-reports/)'; then
  _cv_safe=true

  if echo "$FULL_CMD" | grep -qE '(^|[[:space:];|&()`$])(rm|mv|cp|dd|mkfs|shred|chmod|chown|sudo|doas|eval|kill|killall|nc|ncat|socat|ssh|scp|sftp|rsync|curl|wget)([[:space:];|&()<>]|$)'; then
    _cv_safe=false
  fi

  if [ "$_cv_safe" = true ] && echo "$FULL_CMD" | grep -qE '\|[[:space:]]*(sh|bash|zsh|ksh|fish|ash|dash|perl|php|ruby)([[:space:]]|$)'; then
    _cv_safe=false
  fi

  if [ "$_cv_safe" = true ] && echo "$FULL_CMD" | grep -qE 'https?://'; then
    _cv_safe=false
  fi

  if [ "$_cv_safe" = true ]; then
    while IFS= read -r _tgt; do
      [ -z "$_tgt" ] && continue
      _path=$(echo "$_tgt" | sed -E 's/^>+[[:space:]]*//')
      case "$_path" in
        .conclave/*|conclave-reports/*|/tmp/*|/dev/null|/dev/stdout|/dev/stderr|\&[0-9]*) ;;
        *) _cv_safe=false; break ;;
      esac
    done < <(echo "$FULL_CMD" | grep -oE '>>?[[:space:]]*[^[:space:]|;&<>()`]+')
  fi

  if [ "$_cv_safe" = true ]; then
    dbg "decision: ALLOW (Conclave .conclave/ local pipeline)"
    echo "$ALLOW"
    exit 0
  else
    dbg "Conclave pattern matched but failed safety checks (destructive token / network / non-allowed redirect / pipe-into-shell)"
  fi
fi

# Not a recognized safe command -- exit silently so the normal permission
# system handles it (preserves "always allow X:*" session prompts).
dbg "decision: silent fall-through (no rule matched -- ask user)"
exit 0
